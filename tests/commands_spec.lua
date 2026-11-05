-- Headless tests for the plugin's public commands and setup contract.
-- Run from the repo root: nvim --clean --headless -l tests/commands_spec.lua

vim.opt.runtimepath:prepend(vim.fn.getcwd())
local pi = require("pi-nvim")
local failures, passed = 0, 0

local function eq(expected, actual, what)
  if not vim.deep_equal(expected, actual) then
    error(string.format("%s: expected %s, got %s", what or "value", vim.inspect(expected), vim.inspect(actual)), 2)
  end
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

pi.setup()

test("setup exposes only the new context commands, sessions and ping", function()
  local commands = {}
  for name in pairs(vim.api.nvim_get_commands({ builtin = false })) do
    if name:match("^Pi") then table.insert(commands, name) end
  end
  table.sort(commands)
  eq({ "PiBuffer", "PiDiagnostics", "PiFile", "PiPing", "PiPrompt", "PiSelection", "PiSessions" }, commands,
    "public command set, without legacy aliases")
end)

test("setup installs no default leader-p mapping in normal or visual mode", function()
  for _, mode in ipairs({ "n", "x", "s" }) do
    eq({}, vim.fn.maparg("<leader>p", mode, false, true), "no default mapping in " .. mode)
  end
end)

test("setup preserves user mappings", function()
  for _, mode in ipairs({ "n", "x" }) do
    vim.keymap.set(mode, "<leader>p", "<Nop>", { desc = "User mapping" })
  end
  pi.setup()
  for _, mode in ipairs({ "n", "x" }) do
    local mapping = vim.fn.maparg("<leader>p", mode, false, true)
    eq("<Nop>", mapping.rhs, "user mapping in " .. mode)
    eq("User mapping", mapping.desc, "user mapping description in " .. mode)
    vim.keymap.del(mode, "<leader>p")
  end
end)

test("setup accepts socket_path as its only option", function()
  pi.setup({ socket_path = "/tmp/pi-nvim-configured.sock" })
  eq({ socket_path = "/tmp/pi-nvim-configured.sock" }, pi.config, "configuration")
end)

for _, option in ipairs({ "set_default_keymaps", "unknown_option" }) do
  test("setup rejects unsupported option " .. option .. " without changing configuration", function()
    local before = vim.deepcopy(pi.config)
    local ok, err = pcall(pi.setup, { [option] = false })
    eq(false, ok, "unsupported configuration rejected")
    assert(tostring(err):find(option, 1, true), "error names the unsupported option: " .. tostring(err))
    eq(before, pi.config, "configuration unchanged")
  end)
end

test("legacy Lua send helpers are no longer public", function()
  for _, name in ipairs({ "send_file", "send_selection", "send_buffer", "send_diagnostics" }) do
    eq(nil, pi[name], "removed public helper " .. name)
  end
end)

test("the legacy dialog module is no longer available", function()
  local loaded = pcall(require, "pi-nvim.ui")
  eq(false, loaded, "legacy dialog removed, not retained as an alias")
end)

test("the public prompt function requires a message instead of opening an input", function()
  -- Cancel the old interactive input so this regression test can run red headlessly.
  vim.fn.feedkeys(vim.keycode("<Esc>"), "t")
  local ok, err = pcall(pi.prompt)
  eq(false, ok, "missing message rejected")
  assert(tostring(err):find("requires a message", 1, true), "clear missing-message error: " .. tostring(err))
end)

print(string.format("\n%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)
