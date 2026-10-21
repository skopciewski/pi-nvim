-- Headless tests for session-scoped file references and real prompt delivery.
-- Run from the repo root: nvim --clean --headless -l tests/context_spec.lua

vim.opt.runtimepath:prepend(vim.fn.getcwd())
local pi = require("pi-nvim")
local paths = require("pi-nvim.paths")
local ui = require("pi-nvim.ui")
local uv = vim.uv
local failures, passed = 0, 0
local notifications, servers, connections, buffers, directories = {}, {}, {}, {}, {}
local base, root, remote, received
local namespace = vim.api.nvim_create_namespace("pi_context_test")
local original_input = vim.ui.input
local original_visualmode = vim.fn.visualmode
vim.notify = function(message, level) table.insert(notifications, { message = message, level = level }) end
pi.setup({ set_default_keymaps = false })

local function eq(expected, actual, what)
  if not vim.deep_equal(expected, actual) then
    error(string.format("%s: expected %s, got %s", what or "value", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function serve(socket, response)
  local server = assert(uv.new_pipe(false))
  assert(server:bind(socket))
  server:listen(8, function()
    local conn = assert(uv.new_pipe(false))
    server:accept(conn)
    table.insert(connections, conn)
    local pending = ""
    conn:read_start(function(err, data)
      assert(not err, err)
      if data then
        pending = pending .. data
        local newline = pending:find("\n")
        if newline then
          table.insert(received, vim.json.decode(pending:sub(1, newline - 1)))
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
  end)
  table.insert(servers, server)
  return server
end

local function manifest(socket, remote_root, cwd, legacy)
  vim.fn.writefile({
    vim.json.encode({
      socket = remote_root .. "/tmp/" .. vim.fs.basename(socket),
      cwd = cwd or remote_root,
      projectRoot = not legacy and remote_root or nil,
      pid = 1,
      startedAt = "2026-10-21T07:00:00.000Z",
    }),
  }, socket .. ".info")
end

local function buffer(file)
  local buf = vim.api.nvim_create_buf(true, false)
  table.insert(buffers, buf)
  if file then vim.api.nvim_buf_set_name(buf, file) end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local first = 1", "local second = 2", "return first + second" })
  vim.bo[buf].filetype = "lua"
  vim.bo[buf].modified = false
  return buf
end

local function cleanup()
  if vim.bo.filetype == "pi-nvim-prompt" then
    local cancel = vim.fn.maparg("<Esc>", "i", false, true).callback
    if cancel then cancel() end
  end
  vim.cmd("stopinsert")
  for _, conn in ipairs(connections) do
    if not conn:is_closing() then conn:close() end
  end
  for _, server in ipairs(servers) do
    if not server:is_closing() then server:close() end
  end
  connections, servers = {}, {}
  vim.diagnostic.reset()
  for _, buf in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
  end
  buffers = {}
  vim.cmd.cd("/tmp")
  vim.wait(10)
  for _, directory in ipairs(directories) do
    vim.fn.delete(directory, "rf")
  end
  directories = {}
end

local function fresh(same_paths, no_session)
  cleanup()
  base = vim.fn.tempname()
  table.insert(directories, base)
  root = base .. "/checkout"
  remote = same_paths and root or "/mnt/agent-share/project/worktrees/feature-a"
  vim.fn.mkdir(root .. "/.git", "p")
  vim.fn.mkdir(root .. "/src", "p")
  vim.fn.mkdir(root .. "/tmp", "p")
  vim.fn.mkdir(base .. "/global", "p")
  pi._global_dir = base .. "/global"
  pi.state = { pinned = nil, cache = nil }
  pi.config.socket_path = nil
  received, notifications = {}, {}
  vim.ui.input = function(_, callback) callback("Explain this") end
  vim.fn.visualmode = function() return "V" end
  vim.cmd.cd(root)
  local buf = buffer(root .. "/src/example.lua")
  vim.api.nvim_set_current_buf(buf)
  if not no_session then
    local socket = root .. "/tmp/aaaaaaaaaaaa-1-000001.sock"
    serve(socket)
    manifest(socket, remote, remote .. "/src")
  end
  return buf
end

local function delivered()
  assert(
    vim.wait(2000, function()
      local last = notifications[#notifications]
      return last and (last.message == "Sent to pi" or last.level == vim.log.levels.ERROR)
    end),
    "prompt timed out"
  )
  eq(1, #received, "one prompt delivered: " .. vim.inspect(notifications))
  eq("prompt", received[1].type, "request type")
  return received[1].message
end

local function rejected(fragment)
  vim.wait(20)
  eq({}, received, "no prompt delivered")
  local last = notifications[#notifications]
  assert(last and last.level == vim.log.levels.ERROR, "expected an error: " .. vim.inspect(notifications))
  assert(last.message:find(fragment, 1, true), last.message)
end

local function dialog_send(prompt, send_buffer, selection)
  ui.open({ selection = selection })
  local input_buf = vim.api.nvim_get_current_buf()
  eq("pi-nvim-prompt", vim.bo[input_buf].filetype, "dialog input")
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { prompt })
  if send_buffer then vim.fn.maparg("<Tab>", "i", false, true).callback() end
  vim.fn.maparg("<CR>", "i", false, true).callback()
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

test("PiSendFile uses the selected session's absolute path when mount paths differ", function()
  fresh()
  vim.cmd.PiSendFile()
  eq("File: " .. remote .. "/src/example.lua\n\nExplain this", delivered(), "file message")
end)

test("identical host and pi paths use the same mapping", function()
  fresh(true)
  vim.cmd.PiSendFile()
  eq("File: " .. root .. "/src/example.lua\n\nExplain this", delivered(), "identity mapping")
end)

test("PiSendBuffer maps the file and preserves buffer contents", function()
  fresh()
  vim.cmd.PiSendBuffer()
  eq(
    "Explain this\n\nFile: "
      .. remote
      .. "/src/example.lua\n```lua\nlocal first = 1\nlocal second = 2\nreturn first + second\n```",
    delivered(),
    "buffer message"
  )
end)

test("PiSendSelection maps the file and preserves the selected line range", function()
  local buf = fresh()
  vim.api.nvim_buf_set_mark(buf, "<", 1, 0, {})
  vim.api.nvim_buf_set_mark(buf, ">", 2, 0, {})
  vim.cmd.PiSendSelection()
  eq(
    "Explain this\n\nFrom " .. remote .. "/src/example.lua lines 1-2:\n```lua\nlocal first = 1\nlocal second = 2\n```",
    delivered(),
    "selection message"
  )
end)

test("PiSendDiagnostics maps the file in a real JSON prompt", function()
  local buf = fresh()
  vim.diagnostic.set(
    namespace,
    buf,
    { { lnum = 1, col = 3, source = "test", code = "E1", message = "Example\nDetails" } }
  )
  vim.cmd.PiSendDiagnostics()
  eq(
    "Diagnostics for " .. remote .. "/src/example.lua:\n2:4 ERROR [test E1]: Example\n  Details",
    delivered(),
    "diagnostics message"
  )
end)

test("Pi's file-only dialog uses the same mapped reference", function()
  fresh()
  dialog_send("", false)
  eq("Look at this file: " .. remote .. "/src/example.lua", delivered(), "dialog file message")
end)

test("Pi's send-buffer option uses the same mapped reference", function()
  fresh()
  dialog_send("Explain", true)
  eq(
    "Explain\n\nFile: "
      .. remote
      .. "/src/example.lua\n```lua\nlocal first = 1\nlocal second = 2\nreturn first + second\n```",
    delivered(),
    "dialog buffer message"
  )
end)

test("Pi's visual selection uses the same mapped reference", function()
  local buf = fresh()
  vim.api.nvim_buf_set_mark(buf, "<", 1, 0, {})
  vim.api.nvim_buf_set_mark(buf, ">", 2, 0, {})
  local selection = assert(ui.capture_selection())
  eq(root .. "/src/example.lua", selection.file, "captured absolute source")
  dialog_send("Explain", false, selection)
  eq(
    "Explain\n\nFrom " .. remote .. "/src/example.lua lines 1-2:\n```lua\nlocal first = 1\nlocal second = 2\n```",
    delivered(),
    "dialog selection message"
  )
end)

test("Pi without a named file can still send a plain prompt", function()
  fresh()
  vim.api.nvim_set_current_buf(buffer())
  dialog_send("A plain question", false)
  eq("A plain question", delivered(), "plain prompt")
end)

test("changing buffers while entering a prompt preserves the original file reference", function()
  fresh()
  local callback
  vim.ui.input = function(_, cb) callback = cb end
  pi.send_buffer()
  vim.api.nvim_set_current_buf(buffer(root .. "/other.lua"))
  callback("Explain")
  local message = delivered()
  assert(message:find(remote .. "/src/example.lua", 1, true), message)
  assert(not message:find("other.lua", 1, true), message)
end)

test("cwd and lcd subdirectories do not change the checkout-relative reference", function()
  fresh()
  vim.cmd.lcd(root .. "/src")
  pi.send_file()
  eq("File: " .. remote .. "/src/example.lua\n\nExplain this", delivered(), "subdirectory mapping")
  eq(root, paths.project_root(vim.fn.getcwd()), "checkout root")
end)

test("worktrees use the .git file as their root marker", function()
  fresh()
  vim.fn.delete(root .. "/.git", "rf")
  vim.fn.writefile({ "gitdir: /unavailable/main/.git/worktrees/feature-a" }, root .. "/.git")
  vim.cmd.cd(root .. "/src")
  pi.send_file()
  eq("File: " .. remote .. "/src/example.lua\n\nExplain this", delivered(), "worktree mapping")
end)

test("legacy manifests infer the remote root from their advertised root/tmp socket", function()
  fresh()
  local socket = root .. "/tmp/aaaaaaaaaaaa-1-000001.sock"
  manifest(socket, remote, remote .. "/src", true)
  pi.send_file()
  eq("File: " .. remote .. "/src/example.lua\n\nExplain this", delivered(), "legacy mapping")
end)

test("retry rebuilds the message for the replacement session's remote root", function()
  fresh()
  vim.wait(20)
  local dead = root .. "/tmp/bbbbbbbbbbbb-2-000002.sock"
  local server = assert(uv.new_pipe(false))
  assert(server:bind(dead .. ".bind"))
  server:listen(1, function() end)
  assert(uv.fs_rename(dead .. ".bind", dead))
  server:close()
  local discarded_remote = "/mnt/another-container/checkout"
  manifest(dead, discarded_remote)
  local references = {}
  pi.send_file_context(root .. "/src/example.lua", function(reference)
    table.insert(references, reference)
    return "File: " .. reference
  end)
  eq("File: " .. remote .. "/src/example.lua", delivered(), "retry target")
  eq({ discarded_remote .. "/src/example.lua", remote .. "/src/example.lua" }, references, "rebuilt references")
  eq(nil, uv.fs_stat(dead), "stale socket removed")
end)

test("pinning a different checkout rejects files outside that target", function()
  fresh()
  local foreign = base .. "/foreign"
  vim.fn.mkdir(foreign .. "/tmp", "p")
  local socket = foreign .. "/tmp/bbbbbbbbbbbb-2-000002.sock"
  serve(socket)
  manifest(socket, "/mnt/foreign")
  pi.state.pinned = socket
  pi.send_file()
  rejected("outside the selected pi session's checkout")
end)

test("a similarly named sibling directory is not inside the selected checkout", function()
  fresh()
  vim.fn.mkdir(root .. "-other", "p")
  vim.api.nvim_set_current_buf(buffer(root .. "-other/example.lua"))
  pi.send_buffer()
  rejected("outside the selected pi session's checkout")
end)

test("symlinks to files outside the checkout are rejected", function()
  fresh()
  vim.fn.writefile({ "external" }, base .. "/external.lua")
  assert(uv.fs_symlink(base .. "/external.lua", root .. "/src/link.lua"))
  vim.api.nvim_set_current_buf(buffer(root .. "/src/link.lua"))
  pi.send_file()
  rejected("outside the selected pi session's checkout")
end)

test("dangling symlinks to missing files outside the checkout are rejected", function()
  fresh()
  assert(uv.fs_symlink(base .. "/missing.lua", root .. "/src/link.lua"))
  vim.api.nvim_buf_set_name(0, root .. "/src/link.lua")
  pi.send_file()
  rejected("outside the selected pi session's checkout")
end)

test("relative dangling symlinks resolve from their physical parent, not an alias inside the checkout", function()
  fresh()
  local outside = base .. "/outside/dir"
  vim.fn.mkdir(outside, "p")
  assert(uv.fs_symlink(outside, root .. "/alias"))
  assert(uv.fs_symlink("../missing.lua", outside .. "/dangling.lua"))
  vim.api.nvim_buf_set_name(0, root .. "/alias/dangling.lua")
  pi.send_file()
  rejected("outside the selected pi session's checkout")
end)

test("an unsaved file below a symlinked checkout directory maps correctly", function()
  fresh()
  local alias = base .. "/alias"
  assert(uv.fs_symlink(root, alias))
  vim.api.nvim_set_current_buf(buffer(alias .. "/src/new.lua"))
  pi.send_file()
  eq("File: " .. remote .. "/src/new.lua\n\nExplain this", delivered(), "symlink mapping")
end)

test("the selected session root, not the file's nested repository root, anchors references", function()
  fresh()
  vim.fn.mkdir(root .. "/src/.git", "p")
  pi.send_file()
  eq("File: " .. remote .. "/src/example.lua\n\nExplain this", delivered(), "nested repository file")
end)

test("a global session in the same path namespace uses an absolute reference", function()
  fresh(true, true)
  local socket = pi._global_dir .. "/aaaaaaaaaaaa-1-000001.sock"
  serve(socket)
  manifest(socket, root, root .. "/src")
  pi.send_file()
  eq("File: " .. root .. "/src/example.lua\n\nExplain this", delivered(), "global session")
end)

test("a global nested checkout is not selected just because its cwd is below the project", function()
  fresh(true, true)
  vim.fn.mkdir(root .. "/src/.git", "p")
  local socket = pi._global_dir .. "/aaaaaaaaaaaa-1-000001.sock"
  serve(socket)
  manifest(socket, root .. "/src")
  pi.send_file()
  rejected("No pi session found")
end)

test("a fixed socket without a manifest rejects file context but still supports plain prompts", function()
  fresh(true, true)
  local socket = base .. "/custom.sock"
  serve(socket)
  pi.config.socket_path = socket
  pi.send_file()
  rejected("Cannot determine checkout paths")
  notifications = {}
  pi.prompt("Plain prompt")
  eq("Plain prompt", delivered(), "custom raw prompt")
end)

test("a terminal named pi does not steal context from the selected socket", function()
  fresh()
  local source = vim.api.nvim_get_current_buf()
  local term = vim.api.nvim_create_buf(false, true)
  table.insert(buffers, term)
  local channel = vim.api.nvim_open_term(term, {})
  vim.api.nvim_buf_set_name(term, "term://test:pi")
  vim.b[term].terminal_job_id = channel
  pi.send_file()
  eq("File: " .. remote .. "/src/example.lua\n\nExplain this", delivered(), "socket target")
  eq(source, vim.api.nvim_get_current_buf(), "focus unchanged")
end)

test("literal dollar signs in existing file names are never expanded", function()
  fresh()
  local original = vim.env.PI_NVIM_ROUTE
  vim.env.PI_NVIM_ROUTE = "/incorrect/expansion"
  local file = root .. "/src/$PI_NVIM_ROUTE.lua"
  vim.fn.writefile({ "return 1" }, file)
  vim.api.nvim_buf_set_name(0, file)
  pi.send_file()
  eq("File: " .. remote .. "/src/$PI_NVIM_ROUTE.lua\n\nExplain this", delivered(), "literal file path")
  vim.env.PI_NVIM_ROUTE = original
end)

for _, legacy in ipairs({ false, true }) do
  test(
    "literal dollar signs in checkout roots survive discovery and mapping (legacy: " .. tostring(legacy) .. ")",
    function()
      local buf = fresh(false, true)
      local original = vim.env.PI_NVIM_CHECKOUT
      vim.env.PI_NVIM_CHECKOUT = "incorrect-expansion"
      local renamed = base .. "/$PI_NVIM_CHECKOUT"
      assert(uv.fs_rename(root, renamed))
      root = renamed
      remote = "/mnt/agent-share/$PI_NVIM_CHECKOUT/worktrees/feature-a"
      vim.api.nvim_set_current_dir(root)
      vim.api.nvim_buf_set_name(buf, root .. "/src/example.lua")
      local socket = root .. "/tmp/aaaaaaaaaaaa-1-000001.sock"
      serve(socket)
      manifest(socket, remote, remote .. "/src", legacy)
      pi.send_file()
      eq("File: " .. remote .. "/src/example.lua\n\nExplain this", delivered(), "literal checkout roots")
      vim.env.PI_NVIM_CHECKOUT = original
    end
  )
end

test("a custom socket in an unrelated tmp directory does not invent a root pairing", function()
  fresh(true, true)
  local custom = base .. "/custom/tmp"
  vim.fn.mkdir(custom, "p")
  local socket = custom .. "/custom.sock"
  serve(socket)
  manifest(socket, root)
  pi.config.socket_path = socket
  pi.send_file()
  eq("File: " .. root .. "/src/example.lua\n\nExplain this", delivered(), "custom identity reference")
  local local_root, remote_root = paths.session_roots("/tmp/custom.sock", { projectRoot = root }, pi._global_dir, root)
  eq(root, local_root, "system tmp is not a checkout")
  eq(root, remote_root, "custom root metadata")
end)

test("a terminal selection is sent as buffer text, not a fake file reference", function()
  fresh()
  local term = vim.api.nvim_create_buf(false, true)
  table.insert(buffers, term)
  local channel = vim.api.nvim_open_term(term, {})
  vim.api.nvim_buf_set_name(term, "term://test:pi")
  vim.api.nvim_set_current_buf(term)
  vim.api.nvim_chan_send(channel, "terminal output\r\n")
  vim.wait(20)
  vim.api.nvim_buf_set_mark(term, "<", 1, 0, {})
  vim.api.nvim_buf_set_mark(term, ">", 1, 0, {})
  pi.send_selection()
  local message = delivered()
  assert(message:find("(buffer: term://test:pi) lines 1-1", 1, true), message)
  assert(message:find("terminal output", 1, true), message)
end)

test("named scratch buffers are labeled, never mapped onto a checkout file", function()
  fresh()
  local scratch = buffer("Scratch")
  vim.bo[scratch].buftype = "nofile"
  vim.api.nvim_set_current_buf(scratch)
  pi.send_buffer()
  local message = delivered()
  assert(message:find("(buffer: " .. root .. "/Scratch)", 1, true), message)
  assert(not message:find(remote .. "/Scratch", 1, true), message)
end)

test("virtual buffer diagnostics retain a buffer label", function()
  fresh()
  local virtual = buffer("fugitive://virtual/source")
  vim.bo[virtual].buftype = "nofile"
  vim.api.nvim_set_current_buf(virtual)
  vim.diagnostic.set(namespace, virtual, { { lnum = 0, message = "Virtual diagnostic" } })
  pi.send_diagnostics()
  eq(
    "Diagnostics for (buffer: fugitive://virtual/source):\n1:1 ERROR: Virtual diagnostic",
    delivered(),
    "virtual diagnostics"
  )
end)

test("PiSendFile does not pretend a virtual buffer is a file", function()
  fresh()
  local virtual = buffer("fugitive://virtual/source")
  vim.bo[virtual].buftype = "nofile"
  vim.api.nvim_set_current_buf(virtual)
  pi.send_file()
  eq({}, received, "nothing sent")
  eq({ { message = "No file open", level = vim.log.levels.WARN } }, notifications, "file warning")
end)

test("Pi's dialog can send virtual buffer contents", function()
  fresh()
  local virtual = buffer("fugitive://virtual/source")
  vim.bo[virtual].buftype = "nofile"
  vim.api.nvim_set_current_buf(virtual)
  dialog_send("Explain", true)
  local message = delivered()
  assert(message:find("File: (buffer: fugitive://virtual/source)", 1, true), message)
  assert(message:find("local first = 1", 1, true), message)
end)

test("Pi's dialog sends a plain question from a virtual buffer when no contents are selected", function()
  fresh()
  local virtual = buffer("fugitive://virtual/source")
  vim.bo[virtual].buftype = "nofile"
  vim.api.nvim_set_current_buf(virtual)
  dialog_send("A plain question", false)
  eq("A plain question", delivered(), "virtual plain prompt")
end)

test("Pi's dialog preserves a rejected prompt and can retry after changing the target", function()
  fresh()
  local foreign = base .. "/foreign"
  vim.fn.mkdir(foreign .. "/.git", "p")
  vim.fn.mkdir(foreign .. "/tmp", "p")
  vim.api.nvim_set_current_buf(buffer(foreign .. "/outside.lua"))
  dialog_send("Keep this prompt", false)
  rejected("outside the selected pi session's checkout")
  eq("pi-nvim-prompt", vim.bo.filetype, "dialog remains open")
  eq({ "Keep this prompt" }, vim.api.nvim_buf_get_lines(0, 0, -1, false), "prompt preserved")
  local socket = foreign .. "/tmp/bbbbbbbbbbbb-2-000002.sock"
  serve(socket)
  manifest(socket, "/mnt/foreign")
  pi.state.pinned = socket
  notifications = {}
  vim.fn.maparg("<CR>", "i", false, true).callback()
  eq("File: /mnt/foreign/outside.lua\n\nKeep this prompt", delivered(), "retry preserved prompt")
end)

test("Pi's dialog retains its prompt if the socket closes without a response", function()
  fresh(false, true)
  local socket = root .. "/tmp/aaaaaaaaaaaa-1-000001.sock"
  serve(socket, false)
  manifest(socket, remote)
  dialog_send("Keep this prompt", false)
  assert(
    vim.wait(2000, function()
      local last = notifications[#notifications]
      return last and last.message == "pi closed the connection without a response"
    end),
    "EOF error timed out"
  )
  eq("pi-nvim-prompt", vim.bo.filetype, "dialog remains open")
  eq({ "Keep this prompt" }, vim.api.nvim_buf_get_lines(0, 0, -1, false), "prompt preserved on EOF")
end)

test("Pi's dialog retains its prompt if pi rejects the message", function()
  fresh(false, true)
  local socket = root .. "/tmp/aaaaaaaaaaaa-1-000001.sock"
  serve(socket, '{"ok":false,"error":"Not accepted"}\n')
  manifest(socket, remote)
  dialog_send("Keep this prompt", false)
  assert(
    vim.wait(2000, function()
      local last = notifications[#notifications]
      return last and last.message == "pi error: Not accepted"
    end),
    "rejection timed out"
  )
  eq("pi-nvim-prompt", vim.bo.filetype, "dialog remains open")
  eq({ "Keep this prompt" }, vim.api.nvim_buf_get_lines(0, 0, -1, false), "prompt preserved on rejection")
end)

test("a retry that selects an incompatible checkout rejects the file instead of leaking a reference", function()
  fresh()
  local foreign = base .. "/foreign"
  vim.fn.mkdir(foreign .. "/.git", "p")
  vim.fn.mkdir(foreign .. "/tmp", "p")
  vim.api.nvim_set_current_buf(buffer(foreign .. "/outside.lua"))
  local dead = foreign .. "/tmp/bbbbbbbbbbbb-2-000002.sock"
  local server = assert(uv.new_pipe(false))
  assert(server:bind(dead .. ".bind"))
  server:listen(1, function() end)
  assert(uv.fs_rename(dead .. ".bind", dead))
  server:close()
  manifest(dead, "/mnt/foreign")
  pi.state.pinned = dead
  pi.send_file()
  assert(vim.wait(2000, function() return pi.state.pinned == nil and #notifications > 0 end), "retry timed out")
  rejected("outside the selected pi session's checkout")
end)

test("host-side overlong socket paths get a clear error before connecting", function()
  fresh(true, true)
  pi.config.socket_path = "/" .. string.rep("x", 107)
  pi.prompt("Plain prompt")
  rejected("107-byte Unix socket limit on the Neovim side")
end)

cleanup()
vim.ui.input = original_input
vim.fn.visualmode = original_visualmode
print(string.format("\n%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)
