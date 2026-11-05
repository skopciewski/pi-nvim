-- :PiDiagnostics: diagnostics -> unified dialog -> real Unix socket.
-- Run from the repo root: nvim --clean --headless -l tests/diagnostics_spec.lua

vim.opt.runtimepath:prepend(vim.fn.getcwd())
local pi = require("pi-nvim")
local uv = vim.uv
local failures, passed = 0, 0
local notifications, servers, connections, buffers, directories = {}, {}, {}, {}, {}
local root, source

local namespace = vim.api.nvim_create_namespace("pi_nvim_diagnostics_test")
local other_namespace = vim.api.nvim_create_namespace("pi_nvim_other_diagnostics_test")
local severity = vim.diagnostic.severity
local REF = "/remote/checkout/example.lua"

vim.notify = function(message, level)
  table.insert(notifications, { message = message, level = level })
end
pi.setup()

local function eq(expected, actual, what)
  if not vim.deep_equal(expected, actual) then
    error(string.format("%s: expected %s, got %s", what or "value", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function input()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == "pi-nvim-prompt" then return buf, win end
  end
end

local function key(lhs)
  local _, win = input()
  assert(win, "dialog is open")
  vim.api.nvim_set_current_win(win)
  local mapping = vim.fn.maparg(lhs, "i", false, true)
  assert(mapping.callback, "dialog mapping " .. lhs)
  mapping.callback()
end

local function info()
  local prompt = input()
  assert(prompt, "dialog is open")
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      local buf = vim.api.nvim_win_get_buf(win)
      if buf ~= prompt then return vim.api.nvim_buf_get_lines(buf, 0, -1, false) end
    end
  end
  error("missing info bubble")
end

local function close_dialogs()
  while input() do
    vim.api.nvim_buf_set_lines(input(), 0, -1, false, { "" })
    key("<Esc>")
  end
  vim.cmd("stopinsert")
end

local function cleanup()
  close_dialogs()
  vim.diagnostic.reset()
  for _, handles in ipairs({ connections, servers }) do
    for _, handle in ipairs(handles) do
      if not handle:is_closing() then handle:close() end
    end
  end
  connections, servers = {}, {}
  for _, buf in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
  end
  buffers = {}
  vim.cmd.cd("/tmp")
  vim.wait(10)
  for _, directory in ipairs(directories) do vim.fn.delete(directory, "rf") end
  directories = {}
end

local function buffer(name)
  local buf = vim.api.nvim_create_buf(true, false)
  table.insert(buffers, buf)
  if name then vim.api.nvim_buf_set_name(buf, name) end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "first line", "second line", "third line" })
  vim.bo[buf].modified = false
  return buf
end

local function fresh()
  cleanup()
  vim.o.columns = 160
  local base = vim.fn.tempname()
  table.insert(directories, base)
  root = base .. "/checkout"
  vim.fn.mkdir(root .. "/.git", "p")
  vim.fn.mkdir(root .. "/tmp", "p")
  vim.fn.mkdir(base .. "/global", "p")
  pi._global_dir = base .. "/global"
  pi.state = { pinned = nil, cache = nil }
  pi.config.socket_path = nil
  vim.cmd.cd(root)
  source = buffer(root .. "/example.lua")
  vim.api.nvim_set_current_buf(source)
  -- Clear a draft left by an earlier test through the public UI.
  vim.cmd.PiPrompt()
  close_dialogs()
  notifications = {}
  return source
end

local function session()
  local socket = root .. "/tmp/aaaaaaaaaaaa-1-000001.sock"
  local received = {}
  local server = assert(uv.new_pipe(false))
  assert(server:bind(socket))
  assert(server:listen(8, function()
    local conn = assert(uv.new_pipe(false))
    assert(server:accept(conn))
    table.insert(connections, conn)
    local pending = ""
    conn:read_start(function(err, data)
      assert(not err, err)
      if data then
        pending = pending .. data
        local newline = pending:find("\n")
        if newline then
          table.insert(received, vim.json.decode(pending:sub(1, newline - 1)))
          conn:read_stop()
          conn:write('{"ok":true}\n')
        end
      elseif not conn:is_closing() then conn:close() end
    end)
  end))
  table.insert(servers, server)
  vim.fn.writefile({ vim.json.encode({
    socket = "/remote/checkout/tmp/" .. vim.fs.basename(socket),
    projectRoot = "/remote/checkout",
    cwd = "/remote/checkout",
    pid = 42,
    startedAt = "2026-10-21T07:23:09.000+09:00",
  }) }, socket .. ".info")
  return received, socket
end

local function send(prompt)
  if prompt then vim.api.nvim_buf_set_lines(assert(input()), 0, -1, false, vim.split(prompt, "\n")) end
  key("<CR>")
end

local function delivered(received, request_type, message)
  assert(vim.wait(2000, function() return not input() end), "delivery did not close dialog: " .. vim.inspect(notifications))
  eq({ { type = request_type, message = message } }, received, "wire request")
  eq({ { message = request_type == "insert" and "Inserted into pi editor" or "Sent to pi", level = vim.log.levels.INFO } },
    notifications, "single delivery notification")
end

--- Open :PiDiagnostics in the current buffer and insert with an empty prompt.
local function inserted(received, message)
  vim.cmd.PiDiagnostics()
  send()
  delivered(received, "insert", message)
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

test(":PiDiagnostics shows the item count and an empty prompt inserts the diagnostics", function()
  local buf = fresh()
  local received = session()
  vim.diagnostic.set(namespace, buf, {
    { lnum = 1, col = 3, severity = severity.WARN, message = "Warning" },
    { lnum = 0, col = 0, severity = severity.ERROR, message = "Error" },
  })

  vim.cmd.PiDiagnostics()

  eq({ " File: example.lua", " Context: diagnostics, 2 items", " Session: /remote/checkout [pid 42, 07:23] auto" },
    info(), "info bubble")
  send()
  delivered(received, "insert", "Diagnostics for " .. REF .. ":\n1:1 ERROR: Error\n2:4 WARN: Warning")
  eq(buf, vim.api.nvim_get_current_buf(), "focus returns to the source buffer")
end)

test("a typed prompt submits the prompt, a blank line, then the insert text", function()
  local buf = fresh()
  local received = session()
  vim.diagnostic.set(namespace, buf, { { lnum = 2, col = 1, severity = severity.HINT, message = "Hint" } })

  vim.cmd.PiDiagnostics()
  send("  Fix only this\none  ")

  delivered(received, "prompt", "Fix only this\none\n\nDiagnostics for " .. REF .. ":\n3:2 HINT: Hint")
end)

test("diagnostics are captured when the dialog opens", function()
  local buf = fresh()
  local received = session()
  vim.diagnostic.set(namespace, buf, { { lnum = 0, message = "At open" } })

  vim.cmd.PiDiagnostics()
  vim.diagnostic.set(namespace, buf, { { lnum = 1, message = "Later" }, { lnum = 2, message = "Later too" } })
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "edited after open" })
  send()

  delivered(received, "insert", "Diagnostics for " .. REF .. ":\n1:1 ERROR: At open")
end)

test("no diagnostics in the current buffer notifies and does not open, ignoring other buffers", function()
  fresh()
  local received = session()
  local other = buffer(root .. "/other.lua")
  vim.diagnostic.set(namespace, other, { { lnum = 0, message = "Other buffer diagnostic" } })

  vim.cmd.PiDiagnostics()

  eq(nil, input(), "dialog not opened")
  eq({ { message = "No diagnostics in current buffer", level = vim.log.levels.INFO } }, notifications, "notification")
  vim.wait(50)
  eq({}, received, "nothing sent")
end)

test("all severities and namespaces of only the current buffer are sorted by position", function()
  local buf = fresh()
  local received = session()
  local other = buffer(root .. "/other.lua")
  vim.diagnostic.set(namespace, other, { { lnum = 0, col = 0, message = "Other buffer diagnostic" } })
  vim.diagnostic.set(namespace, buf, {
    { lnum = 2, col = 0, severity = severity.HINT, message = "Hint" },
    { lnum = 1, col = 3, severity = severity.WARN, source = "lint", code = "W001", message = "Warning" },
    { lnum = 0, col = 0, severity = severity.ERROR, source = "lua_ls", code = 123, message = "Error" },
  })
  vim.diagnostic.set(other_namespace, buf, { { lnum = 1, col = 0, severity = severity.INFO, message = "Information" } })

  inserted(received, table.concat({
    "Diagnostics for " .. REF .. ":",
    "1:1 ERROR [lua_ls 123]: Error",
    "2:1 INFO: Information",
    "2:4 WARN [lint W001]: Warning",
    "3:1 HINT: Hint",
  }, "\n"))
end)

test("missing or empty metadata is omitted and numeric code zero is preserved", function()
  local buf = fresh()
  local received = session()
  vim.diagnostic.set(namespace, buf, {
    { lnum = 0, message = "No metadata" },
    { lnum = 1, source = "lint", message = "Source only" },
    { lnum = 2, source = "", code = 0, message = "Code only" },
    { lnum = 2, col = 1, source = "", code = "", message = "Empty metadata" },
  })

  inserted(received, table.concat({
    "Diagnostics for " .. REF .. ":",
    "1:1 ERROR: No metadata",
    "2:1 ERROR [lint]: Source only",
    "3:1 ERROR [0]: Code only",
    "3:2 ERROR: Empty metadata",
  }, "\n"))
end)

test("diagnostics at the same position are sorted by severity then message", function()
  local buf = fresh()
  local received = session()
  vim.diagnostic.set(namespace, buf, {
    { lnum = 0, col = 0, severity = severity.WARN, message = "Warning" },
    { lnum = 0, col = 0, severity = severity.ERROR, message = "Z error" },
    { lnum = 0, col = 0, severity = severity.ERROR, message = "A error" },
  })

  inserted(received, "Diagnostics for " .. REF .. ":\n1:1 ERROR: A error\n1:1 ERROR: Z error\n1:1 WARN: Warning")
end)

test("multiline diagnostic messages are preserved and indented", function()
  local buf = fresh()
  local received = session()
  vim.diagnostic.set(namespace, buf, { { lnum = 0, message = "Type mismatch\nExpected number\nGot string" } })

  inserted(received, "Diagnostics for " .. REF .. ":\n1:1 ERROR: Type mismatch\n  Expected number\n  Got string")
end)

test("unsaved changes add the note without including buffer contents or saving", function()
  local buf = fresh()
  local received = session()
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "unsaved buffer contents" })
  vim.diagnostic.set(namespace, buf, { { lnum = 0, message = "Unsaved diagnostic" } })

  vim.cmd.PiDiagnostics()
  send("Why?")

  delivered(received, "prompt", table.concat({
    "Why?",
    "",
    "Diagnostics for " .. REF .. ":",
    "These diagnostics are from a buffer with unsaved changes.",
    "1:1 ERROR: Unsaved diagnostic",
  }, "\n"))
  eq(true, vim.bo[buf].modified, "buffer not saved automatically")
  eq(0, vim.fn.filereadable(root .. "/example.lua"), "no file written")
end)

test("an empty prompt inserts the unsaved note after the header", function()
  local buf = fresh()
  local received = session()
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "unsaved buffer contents" })
  vim.diagnostic.set(namespace, buf, { { lnum = 0, message = "Unsaved diagnostic" } })

  inserted(received, table.concat({
    "Diagnostics for " .. REF .. ":",
    "These diagnostics are from a buffer with unsaved changes.",
    "1:1 ERROR: Unsaved diagnostic",
  }, "\n"))
end)

for _, prompt in ipairs({ "", "keep me" }) do
  test("a configured socket without manifest metadata rejects the reference ("
    .. (prompt == "" and "insert" or "submit") .. ") and keeps the dialog", function()
    local buf = fresh()
    local received, socket = session()
    vim.fn.delete(socket .. ".info")
    pi.config.socket_path = socket
    vim.diagnostic.set(namespace, buf, { { lnum = 0, message = "Needs a reference" } })

    vim.cmd.PiDiagnostics()
    send(prompt)
    vim.wait(30)

    eq({}, received, "no invented reference delivered")
    eq({ { message = "Cannot determine checkout paths for this pi session; use a manifest in the shared <checkout>/tmp directory",
      level = vim.log.levels.ERROR } }, notifications, "reference error reported once")
    eq({ prompt }, vim.api.nvim_buf_get_lines(assert(input(), "dialog stays open"), 0, -1, false), "prompt kept")
    close_dialogs()
  end)
end

test("unnamed buffers show no file and deliver the unnamed-buffer label", function()
  fresh()
  local received = session()
  local buf = buffer()
  vim.api.nvim_set_current_buf(buf)
  vim.diagnostic.set(namespace, buf, { { lnum = 0, message = "Unnamed buffer diagnostic" } })

  vim.cmd.PiDiagnostics()

  eq({ " File: (no file)", " Context: diagnostics, 1 items" }, vim.list_slice(info(), 1, 2), "info lines")
  send()
  delivered(received, "insert", "Diagnostics for (unnamed buffer):\n1:1 ERROR: Unnamed buffer diagnostic")
end)

test("virtual buffers keep their buffer label", function()
  fresh()
  local received = session()
  local buf = buffer("scratch://notes")
  vim.bo[buf].buftype = "nofile"
  vim.api.nvim_set_current_buf(buf)
  vim.diagnostic.set(namespace, buf, { { lnum = 1, message = "Virtual diagnostic" } })

  vim.cmd.PiDiagnostics()

  eq(" File: scratch://notes", info()[1], "file line")
  send("Explain")
  delivered(received, "prompt", "Explain\n\nDiagnostics for (buffer: scratch://notes):\n2:1 ERROR: Virtual diagnostic")
end)

cleanup()
print(string.format("\n%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)
