-- Headless tests for sending current-buffer diagnostics.
-- Run from the repo root: nvim --clean --headless -l tests/diagnostics_spec.lua

vim.opt.runtimepath:prepend(vim.fn.getcwd())
local pi = require("pi-nvim")
local failures, passed = 0, 0
local messages, notifications, buffers = {}, {}, {}
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.cmd.cd(root)

local namespace = vim.api.nvim_create_namespace("pi_nvim_diagnostics_test")
local other_namespace = vim.api.nvim_create_namespace("pi_nvim_other_diagnostics_test")
local severity = vim.diagnostic.severity
local original_prompt = pi.prompt
local original_send_raw = pi.send_raw

local function eq(expected, actual, what)
  if not vim.deep_equal(expected, actual) then
    error(string.format("%s: expected %s, got %s", what or "value", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local session = { local_root = root, remote_root = root }
local function capture_prompt(message)
  if type(message) == "function" then
    local text, err = message(session)
    assert(text, err)
    message = text
  end
  table.insert(messages, message)
end

vim.notify = function(message, level)
  table.insert(notifications, { message = message, level = level })
end
vim.ui.input = function()
  error("Sending diagnostics must not open an input dialog")
end
-- Keep setup's autoreload timer from scanning real pi sessions during tests.
pi.get_socket_path = function() return nil end
pi.setup({ set_default_keymaps = false })

local function buffer(name)
  local buf = vim.api.nvim_create_buf(true, false)
  table.insert(buffers, buf)
  if name then vim.api.nvim_buf_set_name(buf, name) end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "first line", "second line", "third line" })
  vim.bo[buf].modified = false
  return buf
end

local function fresh()
  vim.diagnostic.reset()
  for _, buf in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
  end
  buffers, messages, notifications = {}, {}, {}
  pi.prompt = capture_prompt
  pi.send_raw = original_send_raw
  local buf = buffer(root .. "/example.lua")
  vim.api.nvim_set_current_buf(buf)
  return buf
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

test(":PiSendDiagnostics sends all severities and namespaces from only the current buffer", function()
  local buf = fresh()
  local other = buffer(root .. "/other.lua")
  vim.diagnostic.set(namespace, other, {
    { lnum = 0, col = 0, message = "Other buffer diagnostic" },
  })
  vim.diagnostic.set(namespace, buf, {
    { lnum = 2, col = 0, severity = severity.HINT, message = "Hint" },
    { lnum = 1, col = 3, severity = severity.WARN, source = "lint", code = "W001", message = "Warning" },
    { lnum = 0, col = 0, severity = severity.ERROR, source = "lua_ls", code = 123, message = "Error" },
  })
  vim.diagnostic.set(other_namespace, buf, {
    { lnum = 1, col = 0, severity = severity.INFO, message = "Information" },
  })

  vim.cmd.PiSendDiagnostics()

  eq({ table.concat({
    "Diagnostics for " .. root .. "/example.lua:",
    "1:1 ERROR [lua_ls 123]: Error",
    "2:1 INFO: Information",
    "2:4 WARN [lint W001]: Warning",
    "3:1 HINT: Hint",
  }, "\n") }, messages, "sent message")
  eq(nil, package.loaded["pi-nvim.ui"], "Pi dialog not loaded")
end)

test("an empty current buffer does not send another buffer's diagnostics", function()
  fresh()
  local other = buffer(root .. "/other.lua")
  vim.diagnostic.set(namespace, other, { { lnum = 0, message = "Other buffer diagnostic" } })

  vim.cmd.PiSendDiagnostics()

  eq({}, messages, "nothing sent")
  eq({ { message = "No diagnostics in current buffer", level = vim.log.levels.INFO } }, notifications, "notification")
end)

test("missing or empty metadata is omitted and numeric code zero is preserved", function()
  local buf = fresh()
  vim.diagnostic.set(namespace, buf, {
    { lnum = 0, message = "No metadata" },
    { lnum = 1, source = "lint", message = "Source only" },
    { lnum = 2, source = "", code = 0, message = "Code only" },
    { lnum = 2, col = 1, source = "", code = "", message = "Empty metadata" },
  })

  pi.send_diagnostics()

  eq(table.concat({
    "Diagnostics for " .. root .. "/example.lua:",
    "1:1 ERROR: No metadata",
    "2:1 ERROR [lint]: Source only",
    "3:1 ERROR [0]: Code only",
    "3:2 ERROR: Empty metadata",
  }, "\n"), messages[1], "metadata formatting")
end)

test("diagnostics at the same position are sorted by severity then message", function()
  local buf = fresh()
  vim.diagnostic.set(namespace, buf, {
    { lnum = 0, col = 0, severity = severity.WARN, message = "Warning" },
    { lnum = 0, col = 0, severity = severity.ERROR, message = "Z error" },
    { lnum = 0, col = 0, severity = severity.ERROR, message = "A error" },
  })

  pi.send_diagnostics()

  eq(table.concat({
    "Diagnostics for " .. root .. "/example.lua:",
    "1:1 ERROR: A error",
    "1:1 ERROR: Z error",
    "1:1 WARN: Warning",
  }, "\n"), messages[1], "ordering")
end)

test("multiline diagnostic messages are preserved and indented", function()
  local buf = fresh()
  vim.diagnostic.set(namespace, buf, {
    { lnum = 0, message = "Type mismatch\nExpected number\nGot string" },
  })

  pi.send_diagnostics()

  eq("Diagnostics for " .. root .. "/example.lua:\n1:1 ERROR: Type mismatch\n  Expected number\n  Got string", messages[1], "multiline message")
end)

test("unnamed buffers can send diagnostics", function()
  fresh()
  local buf = buffer()
  vim.api.nvim_set_current_buf(buf)
  vim.diagnostic.set(namespace, buf, { { lnum = 0, message = "Unnamed buffer diagnostic" } })

  pi.send_diagnostics()

  eq("Diagnostics for (unnamed buffer):\n1:1 ERROR: Unnamed buffer diagnostic", messages[1], "unnamed buffer")
end)

test("unsaved changes are identified without including buffer contents", function()
  local buf = fresh()
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "unsaved buffer contents" })
  vim.diagnostic.set(namespace, buf, { { lnum = 0, message = "Unsaved diagnostic" } })

  pi.send_diagnostics()

  eq(table.concat({
    "Diagnostics for " .. root .. "/example.lua:",
    "These diagnostics are from a buffer with unsaved changes.",
    "1:1 ERROR: Unsaved diagnostic",
  }, "\n"), messages[1], "unsaved buffer")
  eq(true, vim.bo[buf].modified, "buffer not saved automatically")
  eq(0, vim.fn.filereadable(root .. "/example.lua"), "no file written")
end)

test("the command uses the existing prompt transport", function()
  local buf = fresh()
  vim.diagnostic.set(namespace, buf, { { lnum = 0, message = "Transport diagnostic" } })
  local payload
  pi.prompt = original_prompt
  pi.send_raw = function(message, callback)
    payload = type(message) == "function" and message(session) or message
    callback(nil, { ok = true })
  end

  vim.cmd.PiSendDiagnostics()

  eq({ type = "prompt", message = "Diagnostics for " .. root .. "/example.lua:\n1:1 ERROR: Transport diagnostic" }, payload, "prompt payload")
end)

vim.diagnostic.reset()
for _, buf in ipairs(buffers) do
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
end
vim.cmd.cd(vim.fn.fnamemodify(root, ":h"))
vim.fn.delete(root, "rf")
print(string.format("\n%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)
