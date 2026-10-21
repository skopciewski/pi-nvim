local M = {}

--- Session discovery contract (shared with the pi extension):
--- each pi session listens on `<dir>/<hash>-<pid>-<random>.sock` and writes a
--- JSON manifest `<socket>.info` ({ socket, cwd, pid, startedAt })
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
--- @field set_default_keymaps boolean|nil  Whether to create the default <leader>p mappings (default: true)
M.config = {
  socket_path = nil,
  set_default_keymaps = true,
}

--- @param opts pi_nvim.Config|nil
function M.setup(opts)
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
  vim.api.nvim_create_user_command("PiSend", function()
    M.prompt()
  end, { desc = "Send a prompt to pi" })

  vim.api.nvim_create_user_command("PiSendFile", function()
    M.send_file()
  end, { desc = "Send current file to pi with a prompt" })

  vim.api.nvim_create_user_command("PiSendSelection", function()
    M.send_selection()
  end, { range = true, desc = "Send visual selection to pi with a prompt" })

  vim.api.nvim_create_user_command("PiSendBuffer", function()
    M.send_buffer()
  end, { desc = "Send entire buffer to pi with a prompt" })

  vim.api.nvim_create_user_command("PiSendDiagnostics", function()
    M.send_diagnostics()
  end, { desc = "Send current buffer diagnostics to pi" })

  vim.api.nvim_create_user_command("Pi", function(args)
    local ui = require("pi-nvim.ui")
    local selection = nil
    if args.range == 2 then
      selection = ui.capture_selection()
    end
    ui.open({ selection = selection })
  end, { range = true, desc = "Open pi send dialog" })

  if M.config.set_default_keymaps then
    -- Default keymap: <leader>p in normal and visual mode
    vim.keymap.set("n", "<leader>p", ":Pi<CR>", { silent = true, desc = "Send to pi" })
    vim.keymap.set("v", "<leader>p", ":Pi<CR>", { silent = true, desc = "Send selection to pi" })
  end

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
  return vim.fs.root(cwd, ".git") or cwd
end

--- @param root string
--- @param path string|nil
--- @return boolean
local function within(root, path)
  return path ~= nil and (path == root or path:sub(1, #root + 1) == root .. "/")
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
--- @field pid integer|nil
--- @field started_at string|nil
--- @field mtime number

--- Read the sessions registered in dir whose socket file exists.
--- @param dir string
--- @return pi_nvim.Session[]
local function read_sessions(dir)
  local sessions = {}
  if not vim.uv.fs_stat(dir) then return sessions end
  for name, kind in vim.fs.dir(dir) do
    if kind == "file" and name:sub(-10) == ".sock.info" then
      local socket = dir .. "/" .. name:sub(1, -6)
      local stat = vim.uv.fs_stat(socket)
      if stat and stat.type == "socket" then
        local read_ok, lines = pcall(vim.fn.readfile, dir .. "/" .. name)
        local parse_ok, info = false, nil
        if read_ok and lines[1] then
          parse_ok, info = pcall(vim.json.decode, lines[1])
        end
        if parse_ok and type(info) == "table" then
          -- Fields of the wrong type are dropped; a session without a cwd
          -- never matches a project in the global directory.
          table.insert(sessions, {
            socket = socket,
            cwd = typed(info.cwd, "string"),
            pid = typed(info.pid, "number"),
            started_at = typed(info.startedAt, "string"),
            mtime = stat.mtime.sec + stat.mtime.nsec / 1e9,
          })
        end
      end
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
    if within(root, session.cwd) then return session.socket end
  end
  return nil
end

--- Resolve the socket path to use.
--- Priority: config.socket_path > :PiSessions pin > project discovery.
--- Cheap when nothing changed: a few stat calls, no directory scan.
--- @return string|nil
function M.get_socket_path()
  if M.config.socket_path then
    return M.config.socket_path
  end

  if M.state.pinned then
    if vim.uv.fs_stat(M.state.pinned) then return M.state.pinned end
    M.state.pinned = nil
  end

  local cwd = vim.uv.cwd()
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

--- Send a raw JSON message to the pi socket and call cb with the parsed response.
--- @param msg table
--- @param cb fun(err: string|nil, response: table|nil)|nil
--- @param _retried boolean|nil  internal: a failed connect is retried once
function M.send_raw(msg, cb, _retried)
  local sock_path = M.get_socket_path()
  if not sock_path then
    local err = "No pi session found. Is pi running with pi-nvim extension?"
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
        -- Always forget the failed socket; retry with a new lookup only once.
        if forget(sock_path, err, before_connect) and not _retried then
          M.send_raw(msg, cb, true)
          return
        end
        vim.notify("Failed to connect to pi: " .. err, vim.log.levels.ERROR)
        if cb then cb(err, nil) end
      end)
      return
    end

    local payload = vim.json.encode(msg) .. "\n"
    client:write(payload)

    local buf = ""
    client:read_start(function(read_err, data)
      if read_err then
        client:close()
        vim.schedule(function()
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
            if ok and resp then
              if cb then cb(nil, resp) end
            else
              if cb then cb("Invalid response from pi", nil) end
            end
          end)
        end
      else
        -- EOF
        client:close()
      end
    end)
  end)
end

--- Send a prompt string to pi.
--- @param message string|nil  If nil, prompts the user for input
function M.prompt(message)
  if message then
    -- Check for a running pi terminal buffer
    local term_buf = nil
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "terminal" then
        local name = vim.api.nvim_buf_get_name(buf)
        -- Match ":pi" or ":pi " at the end/middle of the term name
        if name:lower():match(":pi$") or name:lower():match(":pi%s") then
          term_buf = buf
          break
        end
      end
    end

    if term_buf then
      local id = vim.b[term_buf].terminal_job_id
      if id then
        -- Focus or open the terminal window
        local win = vim.fn.bufwinid(term_buf)
        if win ~= -1 then
          vim.api.nvim_set_current_win(win)
        else
          vim.cmd("botright split")
          vim.api.nvim_win_set_buf(0, term_buf)
        end

        -- Send via bracketed paste to handle newlines correctly, and append \r to submit
        local payload = "\x1b[200~" .. message .. "\x1b[201~\r"
        vim.api.nvim_chan_send(id, payload)
        vim.cmd("startinsert")
        
        vim.notify("Sent to pi terminal buffer", vim.log.levels.INFO)
        return
      end
    end

    M.send_raw({ type = "prompt", message = message }, function(err, resp)
      if err then return end
      if resp and resp.ok then
        vim.notify("Sent to pi", vim.log.levels.INFO)
      else
        vim.notify("pi error: " .. (resp and resp.error or "unknown"), vim.log.levels.ERROR)
      end
    end)
  else
    vim.ui.input({ prompt = "Pi prompt: " }, function(input)
      if input and input ~= "" then
        M.prompt(input)
      end
    end)
  end
end

--- Send the current file path with optional prompt.
function M.send_file()
  local file = vim.fn.expand("%:p")
  if file == "" then
    vim.notify("No file open", vim.log.levels.WARN)
    return
  end

  vim.ui.input({ prompt = "Pi prompt (file: " .. vim.fn.expand("%:.") .. "): " }, function(input)
    if not input then return end

    local message
    if input == "" then
      message = string.format("Look at this file: %s", file)
    else
      message = string.format("File: %s\n\n%s", file, input)
    end
    M.prompt(message)
  end)
end

--- Send the visual selection with a prompt.
function M.send_selection()
  -- Get the visual selection
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local lines = vim.fn.getregion(start_pos, end_pos, { type = vim.fn.visualmode() })
  local selection = table.concat(lines, "\n")

  if selection == "" then
    vim.notify("Empty selection", vim.log.levels.WARN)
    return
  end

  local file = vim.fn.expand("%:.")
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  local ft = vim.bo.filetype

  vim.ui.input({ prompt = "Pi prompt (selection): " }, function(input)
    if not input then return end

    local header = string.format("%s lines %d-%d", file, start_line, end_line)
    local message
    if input == "" then
      message = string.format("Look at this code from %s:\n\n```%s\n%s\n```", header, ft, selection)
    else
      message = string.format("%s\n\nFrom %s:\n```%s\n%s\n```", input, header, ft, selection)
    end
    M.prompt(message)
  end)
end

--- Send the entire buffer contents with a prompt.
function M.send_buffer()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local content = table.concat(lines, "\n")
  local file = vim.fn.expand("%:.")
  local ft = vim.bo.filetype

  vim.ui.input({ prompt = "Pi prompt (buffer): " }, function(input)
    if not input then return end

    local message
    if input == "" then
      message = string.format("Look at this file %s:\n\n```%s\n%s\n```", file, ft, content)
    else
      message = string.format("%s\n\nFile: %s\n```%s\n%s\n```", input, file, ft, content)
    end
    M.prompt(message)
  end)
end

--- Send all current buffer diagnostics without opening a dialog.
function M.send_diagnostics()
  local buf = vim.api.nvim_get_current_buf()
  local diagnostics = vim.diagnostic.get(buf)
  if #diagnostics == 0 then
    vim.notify("No diagnostics in current buffer", vim.log.levels.INFO)
    return
  end

  table.sort(diagnostics, function(a, b)
    if a.lnum ~= b.lnum then return a.lnum < b.lnum end
    if a.col ~= b.col then return a.col < b.col end
    if a.severity ~= b.severity then return a.severity < b.severity end
    return a.message < b.message
  end)

  local file = vim.api.nvim_buf_get_name(buf)
  file = file ~= "" and vim.fn.fnamemodify(file, ":.") or "(unnamed buffer)"
  local lines = { "Diagnostics for " .. file .. ":" }
  if vim.bo[buf].modified then
    table.insert(lines, "These diagnostics are from a buffer with unsaved changes.")
  end

  for _, diagnostic in ipairs(diagnostics) do
    local details = {}
    if diagnostic.source and diagnostic.source ~= "" then
      table.insert(details, diagnostic.source)
    end
    if diagnostic.code ~= nil and tostring(diagnostic.code) ~= "" then
      table.insert(details, tostring(diagnostic.code))
    end
    local origin = #details > 0 and " [" .. table.concat(details, " ") .. "]" or ""
    table.insert(lines, string.format("%d:%d %s%s: %s",
      diagnostic.lnum + 1,
      diagnostic.col + 1,
      vim.diagnostic.severity[diagnostic.severity],
      origin,
      (diagnostic.message:gsub("\n", "\n  "))
    ))
  end

  M.prompt(table.concat(lines, "\n"))
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
  local root = project_root(vim.uv.cwd())
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
