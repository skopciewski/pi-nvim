local M = {}

local function join(...) return (table.concat({ ... }, "/"):gsub("/+", "/")) end

local function find_root(directory)
  while directory do
    if vim.uv.fs_stat(join(directory, ".git")) then return directory end
    local parent = vim.fs.dirname(directory)
    if parent == directory then break end
    directory = parent
  end
end

local function absolute(path)
  if type(path) ~= "string" or path:sub(1, 1) ~= "/" then return nil end
  return vim.fs.normalize(path, { expand_env = false })
end

function M.canonical(path, depth)
  depth = depth or 0
  path = absolute(path)
  if not path or depth > 40 then return nil end
  local suffix = {}
  local ancestor = path
  while ancestor do
    local real = vim.uv.fs_realpath(ancestor)
    if real then
      if #suffix == 0 then return vim.fs.normalize(real, { expand_env = false }) end
      return join(real, unpack(suffix))
    end
    local link = vim.uv.fs_readlink(ancestor)
    if link then
      local target = absolute(link)
      if not target then
        local parent = M.canonical(vim.fs.dirname(ancestor), depth + 1)
        if not parent then return nil end
        target = join(parent, link)
      end
      local resolved = M.canonical(target, depth + 1)
      return resolved and join(resolved, unpack(suffix))
    end
    table.insert(suffix, 1, vim.fs.basename(ancestor))
    local parent = vim.fs.dirname(ancestor)
    if parent == ancestor then break end
    ancestor = parent
  end
  return path
end

function M.within(root, path)
  if not root or not path then return false end
  return root == "/" or path == root or path:sub(1, #root + 1) == root .. "/"
end

function M.project_root(cwd)
  cwd = M.canonical(cwd)
  return find_root(cwd) or cwd
end

function M.session_roots(socket, info, global_dir, discovery_root)
  local address = absolute(socket) or join(vim.uv.cwd(), socket)
  local directory = vim.fs.dirname(absolute(address))
  local candidate = M.canonical(vim.fs.dirname(directory))
  local marker_root = candidate and find_root(candidate)
  local shared_checkout = candidate ~= "/" and (candidate == discovery_root or marker_root == candidate)
  local remote_root = absolute(info.projectRoot)
  if directory ~= absolute(global_dir) and vim.fs.basename(directory) == "tmp" and shared_checkout then
    local local_root = candidate
    if not remote_root then
      local advertised = absolute(info.socket)
      local advertised_dir = advertised and vim.fs.dirname(advertised)
      if advertised_dir and vim.fs.basename(advertised_dir) == "tmp" then
        remote_root = vim.fs.dirname(advertised_dir)
      elseif M.within(local_root, absolute(info.cwd)) then
        remote_root = local_root
      end
    end
    return local_root, remote_root
  end

  local cwd = absolute(info.cwd)
  remote_root = remote_root or (cwd and M.project_root(cwd))
  return remote_root and M.canonical(remote_root), remote_root
end

function M.capture_source(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype == "" and absolute(name) then return { file = name } end
  return { label = name == "" and "(unnamed buffer)" or "(buffer: " .. name .. ")" }
end

function M.file_reference(file, session)
  if type(file) == "table" then
    if file.label then return file.label end
    file = file.file
  end
  if file == "" then return "(unnamed buffer)" end
  local path = M.canonical(file)
  if not path then return nil, "Cannot resolve a local file path for this buffer" end
  if not session.local_root or not session.remote_root then
    return nil,
      "Cannot determine checkout paths for this pi session; use a manifest in the shared <checkout>/tmp directory"
  end
  if not M.within(session.local_root, path) then
    return nil, "File is outside the selected pi session's checkout: " .. file
  end
  local relative = path:sub(#session.local_root + (session.local_root == "/" and 1 or 2))
  if relative == "" then return session.remote_root end
  return join(session.remote_root, relative)
end

return M
