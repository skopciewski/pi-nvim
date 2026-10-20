-- Headless tests for pi-nvim session discovery.
-- Run from the repo root: nvim --clean --headless -l tests/discovery_spec.lua

vim.opt.runtimepath:prepend(vim.fn.getcwd())
local uv = vim.uv

local failures, passed = 0, 0
local notifications = {}
vim.notify = function(msg, level)
  table.insert(notifications, { msg = msg, level = level })
end

local function eq(expected, actual, what)
  if not vim.deep_equal(expected, actual) then
    error(string.format("%s: expected %s, got %s", what or "value", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local servers = {}

--- Start a real socket server answering every line with a pong.
local function serve(path)
  local server = assert(uv.new_pipe(false))
  assert(server:bind(path))
  server:listen(8, function()
    local conn = assert(uv.new_pipe(false))
    server:accept(conn)
    conn:read_start(function(_, data)
      if data then
        conn:write('{"ok":true,"type":"pong"}\n')
      else
        conn:close()
      end
    end)
  end)
  table.insert(servers, server)
  return server
end

--- Leave a socket file nobody listens on, like a crashed pi.
--- (libuv unlinks the bound path on close, so bind elsewhere and rename.)
local function stale(path)
  local server = assert(uv.new_pipe(false))
  assert(server:bind(path .. ".bind"))
  server:listen(1, function() end)
  assert(uv.fs_rename(path .. ".bind", path))
  server:close()
end

local function manifest(path, cwd, pid)
  vim.fn.writefile({ vim.json.encode({ socket = "/container/view/" .. vim.fs.basename(path), cwd = cwd, pid = pid, startedAt = "2026-10-20T18:32:52.171Z" }) }, path .. ".info")
end

--- Ensure distinct mtimes so "newest" is deterministic.
local function tick()
  vim.wait(20)
end

local function ping()
  local result
  require("pi-nvim").send_raw({ type = "ping" }, function(err, resp)
    result = { err = err, resp = resp }
  end)
  assert(vim.wait(2000, function() return result ~= nil end), "ping timed out")
  return result
end

local root, global
local function fresh()
  for _, server in ipairs(servers) do
    if not server:is_closing() then server:close() end
  end
  servers = {}
  vim.wait(10)
  local base = vim.fn.tempname()
  root = base .. "/proj"
  global = base .. "/global"
  vim.fn.mkdir(root .. "/.git", "p")
  vim.fn.mkdir(root .. "/lua/sub", "p")
  vim.fn.mkdir(global, "p")
  package.loaded["pi-nvim"] = nil
  local pi = require("pi-nvim")
  pi._global_dir = global
  notifications = {}
  vim.cmd.cd(root)
  return pi
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

test("project tmp/ wins over a matching global session", function()
  local pi = fresh()
  vim.fn.mkdir(root .. "/tmp")
  local g = global .. "/aaaaaaaaaaaa-1.sock"
  serve(g); manifest(g, root, 1)
  tick()
  local l = root .. "/tmp/bbbbbbbbbbbb-2.sock"
  serve(l); manifest(l, root, 2)
  eq(l, pi.get_socket_path(), "socket")
end)

test("newest session in tmp/ wins, regardless of its cwd", function()
  local pi = fresh()
  vim.fn.mkdir(root .. "/tmp")
  local old = root .. "/tmp/aaaaaaaaaaaa-1.sock"
  serve(old); manifest(old, root, 1)
  tick()
  local new = root .. "/tmp/bbbbbbbbbbbb-2.sock"
  serve(new); manifest(new, root .. "/lua", 2)
  eq(new, pi.get_socket_path(), "socket")
end)

test("connect address comes from the manifest location, not its socket field", function()
  local pi = fresh()
  vim.fn.mkdir(root .. "/tmp")
  local l = root .. "/tmp/aaaaaaaaaaaa-1.sock"
  serve(l); manifest(l, root, 1)
  eq(l, pi.get_socket_path(), "socket")
  eq({ ok = true, type = "pong" }, ping().resp, "response")
end)

test("empty tmp/ falls back to a global session inside the project", function()
  local pi = fresh()
  vim.fn.mkdir(root .. "/tmp")
  local g = global .. "/aaaaaaaaaaaa-1.sock"
  serve(g); manifest(g, root .. "/lua", 1)
  eq(g, pi.get_socket_path(), "socket")
end)

test("global sessions of other projects are never chosen automatically", function()
  local pi = fresh()
  local other = global .. "/aaaaaaaaaaaa-1.sock"
  serve(other); manifest(other, root .. "-other", 1)
  eq(nil, pi.get_socket_path(), "socket")
end)

test("project root is the git root when nvim runs in a subdirectory", function()
  local pi = fresh()
  vim.fn.mkdir(root .. "/tmp")
  vim.cmd.cd(root .. "/lua/sub")
  local l = root .. "/tmp/aaaaaaaaaaaa-1.sock"
  serve(l); manifest(l, root, 1)
  eq(l, pi.get_socket_path(), "socket")
end)

test("project root falls back to cwd without a git repository", function()
  local pi = fresh()
  local plain = vim.fn.tempname()
  vim.fn.mkdir(plain .. "/tmp", "p")
  vim.cmd.cd(plain)
  local l = plain .. "/tmp/aaaaaaaaaaaa-1.sock"
  serve(l); manifest(l, plain, 1)
  eq(l, pi.get_socket_path(), "socket")
end)

test("sockets without a manifest and manifests without a socket are ignored", function()
  local pi = fresh()
  vim.fn.mkdir(root .. "/tmp")
  serve(root .. "/tmp/aaaaaaaaaaaa-1.sock")
  manifest(root .. "/tmp/bbbbbbbbbbbb-2.sock", root, 2)
  vim.fn.writefile({ "{not json" }, root .. "/tmp/cccccccccccc-3.sock.info")
  serve(root .. "/tmp/cccccccccccc-3.sock")
  eq(nil, pi.get_socket_path(), "socket")
end)

test("lookups are cached until cwd or a session directory changes", function()
  local pi = fresh()
  vim.fn.mkdir(root .. "/tmp")
  eq(nil, pi.get_socket_path(), "no session yet")
  eq(nil, pi.get_socket_path(), "still none")
  eq(1, pi._stats.scans, "scans after repeated misses")
  local l = root .. "/tmp/aaaaaaaaaaaa-1.sock"
  serve(l); manifest(l, root, 1)
  eq(l, pi.get_socket_path(), "new session picked up")
  eq(l, pi.get_socket_path(), "cached")
  eq(2, pi._stats.scans, "scans after a change")
  tick()
  local g = global .. "/bbbbbbbbbbbb-2.sock"
  serve(g); manifest(g, root, 2)
  eq(l, pi.get_socket_path(), "global change rescans, tmp/ still wins")
  eq(3, pi._stats.scans, "scans after a global change")
  vim.cmd.cd(root .. "/lua")
  pi.get_socket_path()
  eq(4, pi._stats.scans, "scans after :cd")
end)

test("a refused socket is removed and the next session is used", function()
  local pi = fresh()
  vim.fn.mkdir(root .. "/tmp")
  local alive = root .. "/tmp/aaaaaaaaaaaa-1.sock"
  serve(alive); manifest(alive, root, 1)
  tick()
  local dead = root .. "/tmp/bbbbbbbbbbbb-2-a1b2c3.sock"
  stale(dead); manifest(dead, root, 2)
  eq(dead, pi.get_socket_path(), "newest (dead) chosen first")
  local result = ping()
  eq({ ok = true, type = "pong" }, result.resp, "response after retry")
  eq(nil, uv.fs_stat(dead), "stale socket removed")
  eq(nil, uv.fs_stat(dead .. ".info"), "stale manifest removed")
  eq(alive, pi.get_socket_path(), "socket after cleanup")
  eq({}, notifications, "no error shown")
end)

test("legacy <hash>-<pid> names are cleaned up as well", function()
  local pi = fresh()
  vim.fn.mkdir(root .. "/tmp")
  local dead = root .. "/tmp/bbbbbbbbbbbb-2.sock"
  stale(dead); manifest(dead, root, 2)
  ping()
  eq(nil, uv.fs_stat(dead), "stale socket removed")
  eq(nil, uv.fs_stat(dead .. ".info"), "stale manifest removed")
end)

test("a failed retry still cleans up and leaves nothing cached", function()
  local pi = fresh()
  vim.fn.mkdir(root .. "/tmp")
  local older = root .. "/tmp/aaaaaaaaaaaa-1-000001.sock"
  stale(older); manifest(older, root, 1)
  tick()
  local newer = root .. "/tmp/bbbbbbbbbbbb-2-000002.sock"
  stale(newer); manifest(newer, root, 2)
  eq("ECONNREFUSED", ping().err, "error after one retry")
  eq(nil, uv.fs_stat(newer), "first stale socket removed")
  eq(nil, uv.fs_stat(older), "second stale socket removed")
  eq(nil, uv.fs_stat(older .. ".info"), "second stale manifest removed")
  eq(nil, pi.state.cache, "cache cleared")
  eq(nil, pi.get_socket_path(), "nothing left to find")
end)

test("a socket replaced after the refusal is not removed", function()
  local pi = fresh()
  vim.fn.mkdir(root .. "/tmp")
  local path = root .. "/tmp/aaaaaaaaaaaa-1-000001.sock"
  stale(path); manifest(path, root, 1)
  -- Replace the dead socket with a live one between the refused connect and
  -- the scheduled cleanup.
  local schedule = vim.schedule
  vim.schedule = function(fn)
    vim.schedule = schedule
    schedule(function()
      os.remove(path)
      serve(path)
      fn()
    end)
  end
  eq({ ok = true, type = "pong" }, ping().resp, "retry reaches the replacement")
  vim.schedule = schedule
  eq("socket", (uv.fs_stat(path) or {}).type, "replacement kept")
  assert(uv.fs_stat(path .. ".info"), "manifest kept")
end)

test("manifests with wrongly typed fields neither crash nor match", function()
  local pi = fresh()
  local g = global .. "/aaaaaaaaaaaa-1-000001.sock"
  serve(g)
  vim.fn.writefile({ vim.json.encode({ cwd = 17, pid = "x", startedAt = 17 }) }, g .. ".info")
  eq(nil, pi.get_socket_path(), "socket")
  local shown
  vim.ui.select = function(items) shown = items end
  pi.list_sessions()
  eq({ "○ ? [pid ?]" }, shown, "items")
end)

test("files not named by the extension are never removed", function()
  local pi = fresh()
  vim.fn.mkdir(root .. "/tmp")
  local foreign = root .. "/tmp/other.sock"
  stale(foreign); manifest(foreign, root, 1)
  local result = ping()
  eq("ECONNREFUSED", result.err, "error")
  assert(uv.fs_stat(foreign), "foreign socket kept")
  assert(uv.fs_stat(foreign .. ".info"), "foreign manifest kept")
end)

test("config.socket_path is used as-is and never cleaned up", function()
  local pi = fresh()
  vim.fn.mkdir(root .. "/tmp")
  local l = root .. "/tmp/aaaaaaaaaaaa-1.sock"
  serve(l); manifest(l, root, 1)
  local fixed = root .. "/tmp/bbbbbbbbbbbb-2.sock"
  stale(fixed)
  pi.config.socket_path = fixed
  eq(fixed, pi.get_socket_path(), "socket")
  eq("ECONNREFUSED", ping().err, "no retry with discovery")
  assert(uv.fs_stat(fixed), "override socket kept")
end)

test(":PiSessions lists all sessions and pins the choice until it fails", function()
  local pi = fresh()
  vim.fn.mkdir(root .. "/tmp")
  local mine = root .. "/tmp/aaaaaaaaaaaa-1.sock"
  serve(mine); manifest(mine, root, 1)
  local other = global .. "/bbbbbbbbbbbb-2.sock"
  local other_server = serve(other); manifest(other, "/elsewhere", 2)
  local shown
  vim.ui.select = function(items, _, on_choice)
    shown = items
    on_choice(items[2], 2)
  end
  pi.list_sessions()
  eq({ "● " .. root .. " [pid 1 started 18:32]", "○ /elsewhere [pid 2 started 18:32]" }, shown, "items")
  eq(other, pi.state.pinned, "pinned")
  eq(other, pi.get_socket_path(), "pinned wins over discovery")
  eq(nil, pi.config.socket_path, "config untouched")
  -- The pinned session dies without cleanup: the pin is dropped and discovery resumes.
  other_server:close()
  vim.wait(10)
  stale(other)
  eq({ ok = true, type = "pong" }, ping().resp, "response after retry")
  eq(nil, pi.state.pinned, "pin cleared")
  eq(mine, pi.get_socket_path(), "back to discovery")
end)

test("a refused pin is dropped even when its files must be kept", function()
  local pi = fresh()
  vim.fn.mkdir(root .. "/tmp")
  local foreign = root .. "/tmp/other.sock"
  stale(foreign); manifest(foreign, root, 2)
  tick()
  local mine = root .. "/tmp/aaaaaaaaaaaa-1.sock"
  serve(mine); manifest(mine, root, 1)
  pi.state.pinned = foreign
  eq({ ok = true, type = "pong" }, ping().resp, "response after retry")
  eq(nil, pi.state.pinned, "pin cleared")
  assert(uv.fs_stat(foreign), "foreign socket kept")
end)

test("a pin whose socket disappeared is dropped on lookup", function()
  local pi = fresh()
  pi.state.pinned = root .. "/tmp/gone.sock"
  eq(nil, pi.get_socket_path(), "socket")
  eq(nil, pi.state.pinned, "pin cleared")
end)

print(string.format("\n%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)
