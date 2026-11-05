local M = {}
local paths = require("pi-nvim.paths")

--- Session discovery contract (shared with the pi extension):
--- each pi session listens on `<dir>/<hash>-<pid>-<random>.sock` and writes a
--- JSON manifest `<socket>.info` ({ socket, cwd, projectRoot, pid, startedAt })
--- next to it. `<dir>` is `<project root>/tmp` when that directory exists,
--- otherwise the global directory below. The project root is the nearest
--- ancestor of the cwd containing `.git`, falling back to the cwd.
M._global_dir = "/tmp/pi-nvim-sockets"

--- Runtime state (not configuration).
--- pinned: socket chosen explicitly in :PiSessions
--- cache:  last discovery result, valid while cwd and directory mtimes match
M.state = { pinned = nil, cache = nil }

--- Test hook: number of full directory scans performed.
M._stats = { scans = 0 }

--- Socket names written by the pi extension: current `<hash>-<pid>-<random>`
--- and upstream/older `<hash>-<pid>`. Only these are ever deleted.
local OWNED_SOCKET_PATTERNS = { "^%x+%-%d+%-%x+%.sock$", "^%x+%-%d+%.sock$" }

--- @param path string
--- @return boolean
local function owned_socket_name(path)
  local name = vim.fs.basename(path)
  for _, pattern in ipairs(OWNED_SOCKET_PATTERNS) do
    if name:match(pattern) then return true end
  end
  return false
end

--- @generic T
--- @param value any
--- @param kind `T`
--- @return T|nil
local function typed(value, kind)
  if type(value) == kind then return value end
  return nil
end

--- @class pi_nvim.Config
--- @field socket_path string|nil  Fixed socket path; disables discovery (default: nil)
M.config = {
  socket_path = nil,
}

--- @param opts pi_nvim.Config|nil
function M.setup(opts)
  for option in pairs(opts or {}) do
    if option ~= "socket_path" then error("Unknown pi-nvim option: " .. tostring(option)) end
  end
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- Auto-reload buffers when files are changed externally (e.g. by pi agent).
  -- Only polls when a pi session is reachable. Respects existing autoread setting.
  if not vim.o.autoread then
    vim.o.autoread = true
  end
  local reload_timer = vim.uv.new_timer()
  reload_timer:start(0, 1000, vim.schedule_wrap(function()
    if M.get_socket_path() then
      pcall(vim.cmd, "silent! checktime")
    end
  end))

  -- Commands
  vim.api.nvim_create_user_command("PiSelection", function(args)
    local dialog = require("pi-nvim.dialog")
    local context = dialog.capture_selection(args)
    if context then dialog.open(context) end
  end, { range = true, desc = "Insert or submit a selection to the displayed pi session" })

  vim.api.nvim_create_user_command("PiFile", function()
    local dialog = require("pi-nvim.dialog")
    local context = dialog.capture_file()
    if context then dialog.open(context) end
  end, { desc = "Insert or submit a file reference to the displayed pi session" })

  vim.api.nvim_create_user_command("PiBuffer", function()
    local dialog = require("pi-nvim.dialog")
    dialog.open(dialog.capture_buffer())
  end, { desc = "Insert or submit the whole buffer to the displayed pi session" })

  vim.api.nvim_create_user_command("PiDiagnostics", function()
    local dialog = require("pi-nvim.dialog")
    local context = dialog.capture_diagnostics()
    if context then dialog.open(context) end
  end, { desc = "Insert or submit current buffer diagnostics to the displayed pi session" })

  vim.api.nvim_create_user_command("PiPrompt", function()
    require("pi-nvim.dialog").open({ kind = "prompt" })
  end, { desc = "Submit a prompt without file context to the displayed pi session" })

  vim.api.nvim_create_user_command("PiPing", function()
    M.ping()
  end, { desc = "Ping the pi session" })

  vim.api.nvim_create_user_command("PiSessions", function()
    M.list_sessions()
  end, { desc = "List running pi sessions" })
end

--- @param cwd string
--- @return string
local function project_root(cwd)
  return paths.project_root(cwd)
end

--- @param root string
--- @param path string|nil
--- @return boolean
local function within(root, path)
  return paths.within(root, path)
end

--- @param path string
--- @return string
local function mtime_key(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then return "-" end
  return stat.mtime.sec .. "." .. stat.mtime.nsec
end

--- Changes whenever a session is added to or removed from either directory.
--- @param root string
--- @return string
local function fingerprint(root)
  return mtime_key(root .. "/tmp") .. "|" .. mtime_key(M._global_dir)
end

--- @class pi_nvim.Session
--- @field socket string   Connect address (derived from where the manifest was found)
--- @field cwd string|nil
--- @field project_root string|nil
--- @field local_root string|nil
--- @field remote_root string|nil
--- @field pid integer|nil
--- @field started_at string|nil
--- @field mtime number|nil

local function read_session(socket)
  local stat = vim.uv.fs_stat(socket)
  if not stat or stat.type ~= "socket" then return nil end
  local read_ok, lines = pcall(vim.fn.readfile, socket .. ".info")
  if not read_ok or not lines[1] then return nil end
  local parse_ok, info = pcall(vim.json.decode, lines[1])
  if not parse_ok or type(info) ~= "table" then return nil end
  local root = typed(info.projectRoot, "string")
  if root and root:sub(1, 1) ~= "/" then root = nil end
  local local_root, remote_root = paths.session_roots(socket, info, M._global_dir, project_root(vim.fn.getcwd()))
  return {
    socket = socket,
    cwd = typed(info.cwd, "string"),
    project_root = root and vim.fs.normalize(root, { expand_env = false }),
    local_root = local_root,
    remote_root = remote_root,
    pid = typed(info.pid, "number"),
    started_at = typed(info.startedAt, "string"),
    mtime = stat.mtime.sec + stat.mtime.nsec / 1e9,
  }
end

--- Read the sessions registered in dir whose socket file exists.
--- @param dir string
--- @return pi_nvim.Session[]
local function read_sessions(dir)
  local sessions = {}
  local scan = vim.uv.fs_scandir(dir)
  if not scan then return sessions end
  while true do
    local name, kind = vim.uv.fs_scandir_next(scan)
    if not name then break end
    if kind == "file" and name:sub(-10) == ".sock.info" then
      local session = read_session(dir .. "/" .. name:sub(1, -6))
      if session then table.insert(sessions, session) end
    end
  end
  table.sort(sessions, function(a, b) return a.mtime > b.mtime end)
  return sessions
end

--- Find the session for this project: the newest one in `<root>/tmp`,
--- otherwise the newest global one whose cwd lies inside the project.
--- @param root string
--- @return string|nil
local function discover(root)
  M._stats.scans = M._stats.scans + 1
  local local_sessions = read_sessions(root .. "/tmp")
  if local_sessions[1] then return local_sessions[1].socket end
  for _, session in ipairs(read_sessions(M._global_dir)) do
    if session.project_root then
      if paths.canonical(session.project_root) == root then return session.socket end
    elseif within(root, paths.canonical(session.cwd)) then
      return session.socket
    end
  end
  return nil
end

--- Resolve the socket path to use.
--- Priority: config.socket_path > :PiSessions pin > project discovery.
--- Cheap when nothing changed: a few stat calls, no directory scan.
--- @return string|nil
function M.get_socket_path()
  if M.config.socket_path then
    if vim.uv.fs_stat(M.config.socket_path) then return M.config.socket_path end
    return nil
  end

  if M.state.pinned then
    if vim.uv.fs_stat(M.state.pinned) then return M.state.pinned end
    M.state.pinned = nil
  end

  local cwd = paths.canonical(vim.fn.getcwd())
  local cache = M.state.cache
  if cache and cache.cwd == cwd and cache.fingerprint == fingerprint(cache.root) then
    return cache.socket
  end

  local root = project_root(cwd)
  -- Fingerprint before scanning so a change during the scan invalidates the result.
  local fp = fingerprint(root)
  local socket = discover(root)
  M.state.cache = { cwd = cwd, root = root, fingerprint = fp, socket = socket }
  return socket
end

--- @return pi_nvim.Session|nil
function M.get_session()
  local socket = M.get_socket_path()
  if not socket then return nil end
  return read_session(socket) or { socket = socket }
end

--- Drop a socket that failed to connect so the next lookup rediscovers.
--- A refused connection means nobody listens: remove the leftover files of a
--- crashed session, but only names written by the pi extension and only if
--- the path still holds the very socket that refused (not a replacement).
--- @param socket string
--- @param err string
--- @param refused uv.fs_stat.result|nil  stat of socket taken before connecting
--- @return boolean retry  Whether another lookup may yield a different socket
local function forget(socket, err, refused)
  if socket == M.config.socket_path then return false end
  if err:match("^ECONNREFUSED") and refused and owned_socket_name(socket) then
    local now = vim.uv.fs_stat(socket)
    -- Inode numbers are reused immediately on some filesystems, so the
    -- change time (ns) is compared as well.
    if
      now
      and now.type == "socket"
      and now.dev == refused.dev
      and now.ino == refused.ino
      and now.ctime.sec == refused.ctime.sec
      and now.ctime.nsec == refused.ctime.nsec
    then
      os.remove(socket)
      os.remove(socket .. ".info")
    end
  end
  if M.state.pinned == socket then M.state.pinned = nil end
  M.state.cache = nil
  return true
end

--- @param msg table|fun(session: pi_nvim.Session): table|nil, string|nil
--- @param cb fun(err: string|nil, response: table|nil)|nil
--- @param opts pi_nvim.DeliveryOptions
--- @param retried boolean|nil
local function send_raw(msg, cb, opts, retried)
  local session = opts.session or M.get_session()
  if not session then
    local err = "No pi session found. Start pi with the pi-nvim extension and create <checkout>/tmp before starting pi in a container."
    vim.notify(err, vim.log.levels.ERROR)
    if cb then cb(err, nil) end
    return
  end

  local sock_path = session.socket
  local request, build_err = msg, nil
  if type(msg) == "function" then request, build_err = msg(session) end
  if not request then
    local err = build_err or "Nothing to send"
    vim.notify(err, vim.log.levels.ERROR)
    if cb then cb(err, nil) end
    return
  end
  if #sock_path > 107 then
    local err = "pi socket path exceeds the 107-byte Unix socket limit on the Neovim side: " .. sock_path
    vim.notify(err, vim.log.levels.ERROR)
    if cb then cb(err, nil) end
    return
  end

  local client = vim.uv.new_pipe(false)
  if not client then
    local err = "Failed to create pipe"
    vim.notify(err, vim.log.levels.ERROR)
    if cb then cb(err, nil) end
    return
  end

  local before_connect = vim.uv.fs_stat(sock_path)
  client:connect(sock_path, function(err)
    if err then
      client:close()
      vim.schedule(function()
        -- Cleanup applies to bound targets too, but they must never be redirected.
        local retry = forget(sock_path, err, before_connect)
        if retry and not opts.session and not retried then
          send_raw(msg, cb, opts, true)
          return
        end
        vim.notify("Failed to connect to pi: " .. err, vim.log.levels.ERROR)
        if cb then cb(err, nil) end
      end)
      return
    end

    local payload = vim.json.encode(request) .. "\n"
    client:write(payload)

    local buf = ""
    client:read_start(function(read_err, data)
      if read_err then
        client:close()
        vim.schedule(function()
          vim.notify("Failed to read from pi: " .. read_err, vim.log.levels.ERROR)
          if cb then cb(read_err, nil) end
        end)
        return
      end
      if data then
        buf = buf .. data
        local nl = buf:find("\n")
        if nl then
          local line = buf:sub(1, nl - 1)
          client:read_stop()
          client:close()
          vim.schedule(function()
            local ok, resp = pcall(vim.json.decode, line)
            if ok and type(resp) == "table" then
              if cb then cb(nil, resp) end
            else
              vim.notify("Invalid response from pi", vim.log.levels.ERROR)
              if cb then cb("Invalid response from pi", nil) end
            end
          end)
        end
      else
        client:close()
        vim.schedule(function()
          local err = "pi closed the connection without a response"
          vim.notify(err, vim.log.levels.ERROR)
          if cb then cb(err, nil) end
        end)
      end
    end)
  end)
end

--- Send a raw JSON message to the pi socket and call cb with the parsed response.
--- @param msg table|fun(session: pi_nvim.Session): table|nil, string|nil
--- @param cb fun(err: string|nil, response: table|nil)|nil
--- @param opts pi_nvim.DeliveryOptions|nil  Only session applies to raw requests
function M.send_raw(msg, cb, opts)
  send_raw(msg, cb, opts or {})
end

--- @class pi_nvim.DeliveryOptions
--- @field mode "submit"|"insert"|nil  Submit by default; insert appends to pi's editor
--- @field session pi_nvim.Session|nil  Deliver only to this target, without retry

--- Deliver a message through the selected session's socket.
--- @param message string|fun(session: pi_nvim.Session): string|nil, string|nil
--- @param on_result fun(err: string|nil, response: table|nil)|nil
--- @param opts pi_nvim.DeliveryOptions|nil
function M.prompt(message, on_result, opts)
  assert(type(message) == "string" or type(message) == "function", "pi-nvim.prompt requires a message")
  opts = opts or {}
  local inserting = opts.mode == "insert"
  local request_type = inserting and "insert" or "prompt"
  local request = { type = request_type, message = message }
  if type(message) == "function" then
    request = function(session)
      local text, err = message(session)
      if not text then return nil, err end
      return { type = request_type, message = text }
    end
  end
  M.send_raw(request, function(err, resp)
    if not err then
      if resp and resp.ok then
        vim.notify(inserting and "Inserted into pi editor" or "Sent to pi", vim.log.levels.INFO)
      else
        err = "pi error: " .. (resp and resp.error or "unknown")
        vim.notify(err, vim.log.levels.ERROR)
      end
    end
    if on_result then on_result(err, resp) end
  end, opts)
end

--- Build file context after selecting the target, including on connection retries.
--- @param opts pi_nvim.DeliveryOptions|nil
function M.send_file_context(source, build_message, on_result, opts)
  M.prompt(function(session)
    local reference, err = paths.file_reference(source, session)
    if not reference then return nil, err end
    return build_message(reference)
  end, on_result, opts)
end

--- Ping the pi session to check connectivity.
function M.ping()
  M.send_raw({ type = "ping" }, function(err, resp)
    if err then
      vim.notify("Pi not reachable: " .. err, vim.log.levels.ERROR)
    elseif resp and resp.type == "pong" then
      vim.notify("Pi is alive! ✓", vim.log.levels.INFO)
    else
      vim.notify("Unexpected response from pi", vim.log.levels.WARN)
    end
  end)
end

--- List all running pi sessions (this project's tmp/ and the global
--- directory, any project) and pin the chosen one.
function M.list_sessions()
  local root = project_root(vim.fn.getcwd())
  local sessions, seen = {}, {}
  for _, dir in ipairs({ root .. "/tmp", M._global_dir }) do
    for _, session in ipairs(read_sessions(dir)) do
      if not seen[session.socket] then
        seen[session.socket] = true
        table.insert(sessions, session)
      end
    end
  end

  if #sessions == 0 then
    vim.notify("No pi sessions found", vim.log.levels.INFO)
    return
  end

  local items = {}
  local current = M.get_socket_path()
  for _, s in ipairs(sessions) do
    local marker = (current == s.socket) and "●" or "○"
    -- Parse ISO 8601 "2026-03-01T14:10:09.123Z" down to "14:10"
    local h, mi = (s.started_at or ""):match("T(%d+):(%d+)")
    local time_str = h and string.format(" started %s:%s", h, mi) or ""
    table.insert(items, string.format("%s %s [pid %s%s]", marker, s.cwd or "?", s.pid or "?", time_str))
  end

  vim.ui.select(items, { prompt = "Pi sessions:" }, function(choice, idx)
    if not choice or not idx then return end
    local session = sessions[idx]
    if session then
      M.state.pinned = session.socket
      vim.notify(string.format("Connected to pi at %s [pid %s]", session.cwd or "?", session.pid or "?"), vim.log.levels.INFO)
    end
  end)
end

return M
