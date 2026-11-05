-- Public delivery API tests against real Unix sockets.
-- Run from the repo root: nvim --clean --headless -l tests/delivery_spec.lua

vim.opt.runtimepath:prepend(vim.fn.getcwd())
local pi = require("pi-nvim")
local uv = vim.uv
local failures, passed = 0, 0
local servers, connections, notifications, directories = {}, {}, {}, {}
local base, root
vim.notify = function(message, level)
  table.insert(notifications, { message = message, level = level })
end

local function eq(expected, actual, what)
  if not vim.deep_equal(expected, actual) then
    error(string.format("%s: expected %s, got %s", what or "value", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function cleanup()
  for _, handles in ipairs({ connections, servers }) do
    for _, handle in ipairs(handles) do
      if not handle:is_closing() then handle:close() end
    end
  end
  connections, servers = {}, {}
  vim.cmd.cd("/tmp")
  vim.wait(10)
  for _, directory in ipairs(directories) do vim.fn.delete(directory, "rf") end
  directories = {}
end

local function fresh()
  cleanup()
  base = vim.fn.tempname()
  table.insert(directories, base)
  root = base .. "/checkout"
  vim.fn.mkdir(root .. "/.git", "p")
  vim.fn.mkdir(root .. "/tmp", "p")
  vim.fn.mkdir(base .. "/global", "p")
  pi._global_dir = base .. "/global"
  pi.config.socket_path = nil
  pi.state = { pinned = nil, cache = nil }
  notifications = {}
  vim.cmd.cd(root)
end

local function serve(socket, response)
  local received = {}
  local server = assert(uv.new_pipe(false))
  assert(server:bind(socket))
  assert(server:listen(8, function()
    local conn = assert(uv.new_pipe(false))
    assert(server:accept(conn))
    table.insert(connections, conn)
    if response == "reset" then
      -- Close with the request still unread to provoke a real ECONNRESET.
      local timer = assert(uv.new_timer())
      table.insert(connections, timer)
      timer:start(20, 0, function()
        timer:close()
        conn:close()
      end)
      return
    end
    local pending = ""
    conn:read_start(function(err, data)
      assert(not err, err)
      if data then
        pending = pending .. data
        local newline = pending:find("\n")
        if newline then
          table.insert(received, vim.json.decode(pending:sub(1, newline - 1)))
          conn:read_stop()
          if response == false then
            conn:close()
          else
            conn:write(response or '{"ok":true}\n')
          end
        end
      elseif not conn:is_closing() then
        conn:close()
      end
    end)
  end))
  table.insert(servers, server)
  return received
end

local function stale(socket)
  local server = assert(uv.new_pipe(false))
  assert(server:bind(socket .. ".bind"))
  assert(server:listen(1, function() end))
  assert(uv.fs_rename(socket .. ".bind", socket))
  server:close()
  vim.wait(10)
end

local function manifest(socket, remote_root)
  vim.fn.writefile({ vim.json.encode({
    socket = remote_root .. "/tmp/" .. vim.fs.basename(socket),
    cwd = remote_root,
    projectRoot = remote_root,
    pid = 1,
    startedAt = "2026-10-21T07:00:00.000Z",
  }) }, socket .. ".info")
end

local function deliver(start)
  local result, calls = nil, 0
  start(function(err, response)
    calls = calls + 1
    result = { err = err, response = response }
  end)
  assert(vim.wait(2000, function() return result ~= nil end), "delivery timed out")
  vim.wait(20)
  eq(1, calls, "one result callback")
  return result
end

local function notified(message, level)
  eq({ { message = message, level = level or vim.log.levels.INFO } }, notifications, "exactly one notification")
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. "\n     " .. tostring(err))
  end
end

for _, case in ipairs({
  { name = "default submit", request_type = "prompt", notification = "Sent to pi" },
  { name = "explicit submit", mode = "submit", request_type = "prompt", notification = "Sent to pi" },
  { name = "insert", mode = "insert", request_type = "insert", notification = "Inserted into pi editor" },
}) do
  test(case.name .. " sends the corresponding request and reports success once", function()
    fresh()
    local socket = root .. "/tmp/aaaaaaaaaaaa-1-000001.sock"
    local received = serve(socket)
    manifest(socket, "/remote/checkout")
    local result = deliver(function(callback)
      pi.prompt("Explain this", callback, { mode = case.mode })
    end)
    eq({ response = { ok = true } }, result, "successful result")
    eq({ { type = case.request_type, message = "Explain this" } }, received, "wire request")
    notified(case.notification)
  end)
end

test("file-context delivery forwards insert mode and maps references for the target", function()
  fresh()
  local socket = root .. "/tmp/aaaaaaaaaaaa-1-000001.sock"
  local received = serve(socket)
  manifest(socket, "/remote/checkout")
  local result = deliver(function(callback)
    pi.send_file_context(root .. "/example.lua", function(reference)
      return reference
    end, callback, { mode = "insert" })
  end)
  eq({ response = { ok = true } }, result, "successful result")
  eq({ { type = "insert", message = "/remote/checkout/example.lua" } }, received, "mapped insert")
  notified("Inserted into pi editor")
end)

test("bound delivery uses the pinned target snapshot, not discovery or refreshed metadata", function()
  fresh()
  local discovered = root .. "/tmp/aaaaaaaaaaaa-1-000001.sock"
  local other_received = serve(discovered)
  manifest(discovered, "/remote/current")
  eq(discovered, pi.get_socket_path(), "discovery winner")

  local foreign = base .. "/foreign"
  vim.fn.mkdir(foreign .. "/.git", "p")
  vim.fn.mkdir(foreign .. "/tmp", "p")
  local socket = foreign .. "/tmp/bbbbbbbbbbbb-2-000002.sock"
  local bound_received = serve(socket)
  manifest(socket, "/remote/pinned")
  pi.state.pinned = socket
  local bound = assert(pi.get_session())
  -- A bound delivery must use the displayed snapshot even if runtime state changes.
  pi.state.pinned = nil
  manifest(socket, "/remote/changed-after-binding")
  local result = deliver(function(callback)
    pi.send_file_context(foreign .. "/example.lua", function(reference)
      return "File: " .. reference
    end, callback, { session = bound, mode = "insert" })
  end)
  eq({ response = { ok = true } }, result, "successful bound delivery")
  eq({ { type = "insert", message = "File: /remote/pinned/example.lua" } }, bound_received, "bound message")
  eq({}, other_received, "discovery winner received nothing")
  notified("Inserted into pi editor")
end)

for _, name in ipairs({ "bbbbbbbbbbbb-2-000002.sock", "custom.sock" }) do
  test("refused bound delivery never falls back and still cleans up: " .. name, function()
    fresh()
    local alive = root .. "/tmp/aaaaaaaaaaaa-1-000001.sock"
    local received = serve(alive)
    manifest(alive, "/remote/alive")
    eq(alive, pi.get_socket_path(), "discovery cache primed")
    assert(pi.state.cache, "cache populated")
    local dead = root .. "/tmp/" .. name
    stale(dead)
    manifest(dead, "/remote/dead")
    -- Discovery must prefer the live session, even if the dead socket is retained.
    -- Otherwise an incorrect retry could reconnect to dead and escape detection.
    assert(uv.fs_utime(dead, 100, 100))
    assert(uv.fs_utime(alive, 200, 200))
    pi.state.pinned = dead
    local bound = assert(pi.get_session())
    local result = deliver(function(callback)
      pi.prompt("Do not redirect", callback, { session = bound })
    end)
    eq("ECONNREFUSED", result.err, "bound connection refused")
    eq(nil, result.response, "no response")
    eq({}, received, "no fallback request")
    eq(nil, pi.state.pinned, "refused pin cleared")
    eq(nil, pi.state.cache, "discovery cache invalidated")
    if name == "custom.sock" then
      assert(uv.fs_stat(dead), "unowned socket kept")
      assert(uv.fs_stat(dead .. ".info"), "unowned manifest kept")
    else
      eq(nil, uv.fs_stat(dead), "owned stale socket removed")
      eq(nil, uv.fs_stat(dead .. ".info"), "owned stale manifest removed")
    end
    notified("Failed to connect to pi: ECONNREFUSED", vim.log.levels.ERROR)
    eq(alive, pi.get_socket_path(), "next independent lookup prefers the live session")
  end)
end

test("refused bound cleanup retains an unowned socket for later independent discovery", function()
  fresh()
  local alive = root .. "/tmp/aaaaaaaaaaaa-1-000001.sock"
  local received = serve(alive)
  manifest(alive, "/remote/alive")
  eq(alive, pi.get_socket_path(), "discovery cache primed")
  local dead = root .. "/tmp/custom.sock"
  stale(dead)
  manifest(dead, "/remote/dead")
  assert(uv.fs_utime(alive, 100, 100))
  assert(uv.fs_utime(dead, 200, 200))
  pi.state.pinned = dead
  local bound = assert(pi.get_session())
  local result = deliver(function(callback)
    pi.prompt("Do not redirect", callback, { session = bound })
  end)
  eq("ECONNREFUSED", result.err, "bound connection refused")
  eq(nil, result.response, "no response")
  eq(nil, pi.state.pinned, "refused pin cleared")
  eq(nil, pi.state.cache, "discovery cache invalidated")
  assert(uv.fs_stat(dead), "unowned socket kept")
  assert(uv.fs_stat(dead .. ".info"), "unowned manifest kept")
  eq({}, received, "live session received nothing")
  notified("Failed to connect to pi: ECONNREFUSED", vim.log.levels.ERROR)
  eq(dead, pi.get_socket_path(), "a later lookup can rediscover the retained newest socket")
end)

test("unbound insert retries once and rebuilds references for the replacement", function()
  fresh()
  local alive = root .. "/tmp/aaaaaaaaaaaa-1-000001.sock"
  local received = serve(alive)
  manifest(alive, "/remote/replacement")
  local dead = root .. "/tmp/bbbbbbbbbbbb-2-000002.sock"
  stale(dead)
  manifest(dead, "/remote/original")
  pi.state.pinned = dead
  local result = deliver(function(callback)
    pi.send_file_context(root .. "/example.lua", function(reference)
      return reference
    end, callback, { mode = "insert" })
  end)
  eq({ response = { ok = true } }, result, "retry result")
  eq({ { type = "insert", message = "/remote/replacement/example.lua" } }, received, "rebuilt insert")
  notified("Inserted into pi editor")
end)

for _, mode in ipairs({ "submit", "insert" }) do
  test(mode .. " rejection is reported once by delivery", function()
    fresh()
    local socket = root .. "/tmp/aaaaaaaaaaaa-1-000001.sock"
    local received = serve(socket, '{"ok":false,"error":"Unknown command type: insert"}\n')
    manifest(socket, "/remote/checkout")
    local result = deliver(function(callback)
      pi.prompt("Keep my prompt", callback, { mode = mode })
    end)
    eq("pi error: Unknown command type: insert", result.err, "rejected result")
    eq({ ok = false, error = "Unknown command type: insert" }, result.response, "rejection response")
    eq(1, #received, "one request, without retry")
    notified(result.err, vim.log.levels.ERROR)
  end)
end

for _, case in ipairs({
  { name = "malformed JSON", response = "not-json\n", err = "Invalid response from pi" },
  { name = "non-object JSON", response = "123\n", err = "Invalid response from pi" },
  { name = "closed connection", response = false, err = "pi closed the connection without a response" },
  { name = "read failure", response = "reset", err = "ECONNRESET", notification = "Failed to read from pi: ECONNRESET" },
}) do
  test(case.name .. " is reported once by delivery", function()
    fresh()
    local socket = root .. "/tmp/aaaaaaaaaaaa-1-000001.sock"
    serve(socket, case.response)
    manifest(socket, "/remote/checkout")
    local result = deliver(function(callback)
      pi.prompt("Explain this", callback, { mode = "insert" })
    end)
    eq({ err = case.err }, result, "transport error result")
    notified(case.notification or case.err, vim.log.levels.ERROR)
  end)
end

test("a missing configured path reports no session exactly once", function()
  fresh()
  pi.config.socket_path = root .. "/missing.sock"
  local result = deliver(function(callback) pi.prompt("Explain this", callback) end)
  local err = "No pi session found. Start pi with the pi-nvim extension and create <checkout>/tmp before starting pi in a container."
  eq({ err = err }, result, "no-session result")
  notified(err, vim.log.levels.ERROR)
end)

test("an overlong existing configured path reports the length error exactly once", function()
  fresh()
  pi.config.socket_path = root .. "/" .. string.rep("x", 107)
  vim.fn.writefile({}, pi.config.socket_path)
  local result = deliver(function(callback) pi.prompt("Explain this", callback) end)
  local err = "pi socket path exceeds the 107-byte Unix socket limit on the Neovim side: " .. pi.config.socket_path
  eq({ err = err }, result, "overlong-path result")
  notified(err, vim.log.levels.ERROR)
end)

test("a disappeared bound target reports a connect error rather than resolving another session", function()
  fresh()
  local socket = root .. "/tmp/aaaaaaaaaaaa-1-000001.sock"
  local received = serve(socket)
  manifest(socket, "/remote/checkout")
  local result = deliver(function(callback)
    pi.prompt("Do not redirect", callback, { session = { socket = root .. "/gone.sock" } })
  end)
  assert(result.err and result.err:match("^ENOENT"), vim.inspect(result))
  eq(nil, result.response, "no response")
  eq({}, received, "discovery winner untouched")
  notified("Failed to connect to pi: " .. result.err, vim.log.levels.ERROR)
end)

test("an incompatible bound checkout reports its reference error exactly once", function()
  fresh()
  local socket = base .. "/global/aaaaaaaaaaaa-1-000001.sock"
  local received = serve(socket)
  manifest(socket, "/unrelated/checkout")
  pi.config.socket_path = socket
  local bound = assert(pi.get_session())
  local result = deliver(function(callback)
    pi.send_file_context(root .. "/example.lua", function(reference) return reference end,
      callback, { session = bound })
  end)
  eq("File is outside the selected pi session's checkout: " .. root .. "/example.lua", result.err, "reference error")
  eq({}, received, "no request with an invalid reference")
  notified(result.err, vim.log.levels.ERROR)
end)

test("only the first response line completes delivery", function()
  fresh()
  local socket = root .. "/tmp/aaaaaaaaaaaa-1-000001.sock"
  local received = serve(socket, '{"ok":true}\n{"ok":false,"error":"second response"}\n')
  manifest(socket, "/remote/checkout")
  local result = deliver(function(callback) pi.prompt("Explain this", callback) end)
  eq({ response = { ok = true } }, result, "first response wins")
  eq(1, #received, "one request")
  notified("Sent to pi")
end)

cleanup()
print(string.format("\n%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)
