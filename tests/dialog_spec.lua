-- Unified dialog: command -> floating UI -> real Unix socket.
-- Run: nvim --clean --headless -l tests/dialog_spec.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local pi = require("pi-nvim")
local uv = vim.uv
local failures, passed = 0, 0
local notifications, servers, connections, buffers, directories = {}, {}, {}, {}, {}
local base, root, source
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
      if buf ~= prompt then
        return vim.api.nvim_buf_get_lines(buf, 0, -1, false), vim.api.nvim_win_get_width(win), win
      end
    end
  end
  error("missing info bubble")
end

local function cleanup()
  while input() do
    vim.api.nvim_buf_set_lines(input(), 0, -1, false, { "" })
    key("<Esc>")
  end
  vim.cmd("stopinsert")
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

local function fresh(lines)
  cleanup()
  vim.o.columns = 160
  base = vim.fn.tempname()
  table.insert(directories, base)
  root = base .. "/checkout"
  vim.fn.mkdir(root .. "/.git", "p")
  vim.fn.mkdir(root .. "/tmp", "p")
  vim.fn.mkdir(base .. "/global", "p")
  pi._global_dir = base .. "/global"
  pi.state = { pinned = nil, cache = nil }
  pi.config.socket_path = nil
  notifications = {}
  vim.cmd.cd(root)
  source = vim.api.nvim_create_buf(true, false)
  table.insert(buffers, source)
  vim.api.nvim_set_current_buf(source)
  vim.api.nvim_buf_set_name(source, root .. "/example.lua")
  vim.api.nvim_buf_set_lines(source, 0, -1, false, lines or { "local first = 1", "local second = 2", "return first + second" })
  vim.bo[source].filetype = "lua"
  -- A previous test may have cancelled with a draft and no dialog left open.
  -- Clear it through the same public UI a user would use.
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd.PiSelection()
  vim.api.nvim_buf_set_lines(assert(input()), 0, -1, false, { "" })
  key("<Esc>")
  notifications = {}
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
end

local function session(name, opts)
  opts = opts or {}
  local socket = (opts.directory or root .. "/tmp") .. "/" .. (name or "aaaaaaaaaaaa-1-000001") .. ".sock"
  local received, awaiting = {}, {}
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
          if opts.defer then
            table.insert(awaiting, conn)
          else
            conn:write(opts.response or '{"ok":true}\n')
          end
        end
      elseif not conn:is_closing() then conn:close() end
    end)
  end))
  table.insert(servers, server)
  vim.fn.writefile({ vim.json.encode(opts.metadata or {
    socket = "/remote/checkout/tmp/" .. vim.fs.basename(socket),
    projectRoot = "/remote/checkout",
    cwd = opts.cwd or "/remote/checkout",
    pid = 42,
    startedAt = "2026-10-21T07:23:09.000+09:00",
  }) }, socket .. ".info")
  local function respond(response)
    local conn = assert(table.remove(awaiting, 1), "request awaiting a response")
    if response == false then
      conn:close()
    else
      conn:write(response or opts.response or '{"ok":true}\n')
    end
  end
  return received, socket, server, respond
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
  eq(source, vim.api.nvim_get_current_buf(), "focus stays in Neovim's source buffer")
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

test("current line opens the unified preview and an empty prompt inserts", function()
  fresh()
  local received = session()
  vim.cmd.PiSelection()
  eq({ " File: example.lua", " Context: selection, 1 lines (2-2)", " Session: /remote/checkout [pid 42, 07:23] auto" }, info(), "info bubble")
  send()
  delivered(received, "insert", "/remote/checkout/example.lua lines 2-2:\n```lua\nlocal second = 2\n```")
end)

test("a trimmed multiline prompt submits the unchanged selection format", function()
  fresh()
  local received = session()
  vim.cmd.PiSelection()
  -- Both source text and metadata belong to the snapshot at open time.
  vim.api.nvim_buf_set_lines(source, 1, 2, false, { "changed later" })
  vim.bo[source].filetype = "text"
  send("  Explain this\ncarefully  ")
  delivered(received, "prompt", "Explain this\ncarefully\n\nFrom /remote/checkout/example.lua lines 2-2:\n```lua\nlocal second = 2\n```")
end)

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end

local function selection_request(received, text, first, last)
  send()
  delivered(received, "insert", string.format("/remote/checkout/example.lua lines %d-%d:\n```lua\n%s\n```", first, last, text))
end

for _, case in ipairs({
  { name = "characterwise", keys = "vjl", text = "lpha\nbra", first = 1, last = 2 },
  { name = "linewise", keys = "Vj", text = "alpha\nbravo", first = 1, last = 2 },
  { name = "blockwise", keys = "<C-v>jl", text = "lp\nra", first = 1, last = 2 },
  { name = "reverse characterwise", keys = "vkh", text = "pha\nbrav", first = 1, last = 2, reverse = true },
}) do
  for _, mapping in ipairs({ ":PiSelection<CR>", "<Cmd>PiSelection<CR>" }) do
    test(case.name .. " selection through visual mapping " .. mapping, function()
      fresh({ "alpha", "bravo", "charlie" })
      local received = session()
      vim.keymap.set("x", "Q", mapping, { silent = true })
      vim.api.nvim_win_set_cursor(0, case.reverse and { 2, 3 } or { 1, 1 })
      feed(case.keys .. "Q")
      eq("pi-nvim-prompt", vim.bo.filetype, "mapping opens prompt")
      assert(not vim.fn.mode():match("^[vV\022]"), "visual mode left before opening")
      eq(" Context: selection, 2 lines (1-2)", info()[2], "normalized region preview")
      selection_request(received, case.text, case.first, case.last)
    end)
  end
end

test("an explicit nonvisual two-line range uses whole lines", function()
  fresh()
  local received = session()
  vim.cmd("2,3PiSelection")
  selection_request(received, "local second = 2\nreturn first + second", 2, 3)
end)

test("a one-line range uses whole lines even when visual marks cover it", function()
  fresh({ "alpha", "bravo", "charlie" })
  local received = session()
  vim.api.nvim_win_set_cursor(0, { 2, 1 })
  feed("vl<Esc>")
  vim.cmd("2PiSelection")
  selection_request(received, "bravo", 2, 2)
end)

test("two-line range colliding with visual marks uses the exact old region", function()
  fresh({ "alpha", "bravo", "charlie" })
  local received = session()
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  feed("vjl<Esc>")
  vim.cmd("1,2PiSelection")
  selection_request(received, "lpha\nbra", 1, 2)
end)

test("empty current line warns without opening a dialog", function()
  fresh({ "alpha", "", "charlie" })
  local received = session()
  vim.cmd.PiSelection()
  eq(nil, input(), "no dialog")
  eq({}, received, "no request")
  eq({ { message = "Empty selection", level = vim.log.levels.WARN } }, notifications, "empty warning")
end)

for _, origin in ipairs({ "config", "pinned", "auto" }) do
  test("session preview reports the " .. origin .. " origin", function()
    fresh()
    local received, socket = session()
    if origin == "config" then pi.config.socket_path = socket end
    if origin == "pinned" then pi.state.pinned = socket end
    vim.cmd.PiSelection()
    eq(" Session: /remote/checkout [pid 42, 07:23] " .. origin, info()[3], "session preview")
    selection_request(received, "local second = 2", 2, 2)
  end)
end

test("config wins over a pin and discovery", function()
  fresh()
  local other, pinned = session()
  local received, configured = session("bbbbbbbbbbbb-2-000002", { cwd = "/configured" })
  pi.state.pinned = pinned
  pi.config.socket_path = configured
  vim.cmd.PiSelection()
  eq(" Session: /configured [pid 42, 07:23] config", info()[3], "configured preview")
  selection_request(received, "local second = 2", 2, 2)
  eq({}, other, "pin received nothing")
end)

test("missing metadata uses question marks and still opens", function()
  fresh()
  local _, socket = session("custom", { metadata = { startedAt = "not-a-time" } })
  pi.config.socket_path = socket
  vim.cmd.PiSelection()
  eq(" Session: ? [pid ?, ?] config", info()[3], "unknown fields")
end)

test("malformed ISO times and empty cwd are unknown", function()
  fresh()
  local _, socket = session("custom", { metadata = { cwd = "", startedAt = "2026-10-21T28:75:00Z" } })
  pi.config.socket_path = socket
  vim.cmd.PiSelection()
  eq(" Session: ? [pid ?, ?] config", info()[3], "invalid fields")
end)

test("a configured path without a manifest shows unknown metadata", function()
  fresh()
  local _, socket = session("custom")
  vim.fn.delete(socket .. ".info")
  pi.config.socket_path = socket
  vim.cmd.PiSelection()
  eq(" Session: ? [pid ?, ?] config", info()[3], "no manifest")
end)

test("session cwd is left truncated by display cells, retaining its longest tail", function()
  fresh()
  local saved_columns = vim.o.columns
  vim.o.columns = 144
  local cwd = "/" .. string.rep("界", 45) .. "/leaf"
  session(nil, { cwd = cwd })
  vim.cmd.PiSelection()
  local lines, width = info()
  local suffix = " [pid 42, 07:23] auto"
  local available = width - vim.fn.strdisplaywidth(" Session: …" .. suffix .. "/leaf")
  local count = math.floor(available / 2)
  eq(" Session: …" .. string.rep("界", count) .. "/leaf" .. suffix, lines[3], "longest fitting cwd tail")
  assert(vim.fn.strdisplaywidth(lines[3]) <= width, "preview fits bubble")
  key("<Esc>")
  vim.o.columns = saved_columns
end)

test("very narrow previews cut at the end when even an ellipsis cannot fit", function()
  fresh()
  local saved_columns = vim.o.columns
  vim.o.columns = 30
  session(nil, { cwd = "/a/long/path" })
  vim.cmd.PiSelection()
  local lines, width = info()
  eq(" Session: … [pi", lines[3], "cut session line")
  eq(15, width, "narrow bubble width")
  assert(vim.fn.strdisplaywidth(lines[3]) <= width, "narrow preview fits")
  key("<Esc>")
  vim.o.columns = saved_columns
end)

test("delivery uses the displayed pinned checkout and its captured metadata", function()
  fresh()
  local other = session()
  local foreign = base .. "/foreign"
  vim.fn.mkdir(foreign .. "/.git", "p")
  vim.fn.mkdir(foreign .. "/tmp", "p")
  local received, socket = session("bbbbbbbbbbbb-2-000002", { directory = foreign .. "/tmp", metadata = {
    projectRoot = "/remote/pinned", cwd = "/remote/pinned", pid = 99,
  } })
  vim.api.nvim_buf_set_name(source, foreign .. "/example.lua")
  pi.state.pinned = socket
  vim.cmd.PiSelection()
  eq(" Session: /remote/pinned [pid 99, ?] pinned", info()[3], "pinned preview")
  -- Same socket means same identity, not a new target. Use the displayed snapshot.
  vim.fn.writefile({ vim.json.encode({ projectRoot = "/remote/changed", cwd = "/remote/changed" }) }, socket .. ".info")
  send()
  delivered(received, "insert", "/remote/pinned/example.lua lines 2-2:\n```lua\nlocal second = 2\n```")
  eq({}, other, "discovery target received nothing")
end)

test("a changed socket refreshes the preview without delivering until another Enter", function()
  fresh()
  local original, first = session()
  local replacement, second = session("bbbbbbbbbbbb-2-000002", { cwd = "/replacement" })
  pi.state.pinned = first
  vim.cmd.PiSelection()
  local prompt = input()
  pi.state.pinned = second
  send("  keep this  ")
  vim.wait(30)
  eq({}, original, "original received nothing")
  eq({}, replacement, "replacement received nothing yet")
  eq(prompt, input(), "dialog remains open")
  eq({ "  keep this  " }, vim.api.nvim_buf_get_lines(prompt, 0, -1, false), "prompt retained")
  eq(" Session: /replacement [pid 42, 07:23] pinned", info()[3], "replacement preview")
  eq({ { message = "pi target changed, press Enter to send", level = vim.log.levels.WARN } }, notifications, "target-change warning")
  notifications = {}
  send()
  delivered(replacement, "prompt", "keep this\n\nFrom /remote/checkout/example.lua lines 2-2:\n```lua\nlocal second = 2\n```")
end)

local no_session = "No pi session found. Start pi with the pi-nvim extension and create <checkout>/tmp before starting pi in a container."
for _, configured in ipairs({ false, true }) do
  test("no session opens an honest preview and Enter does not deliver, configured=" .. tostring(configured), function()
    fresh()
    if configured then
      session()
      pi.config.socket_path = root .. "/missing.sock"
    end
    vim.cmd.PiSelection()
    eq(" Session: none", info()[3], "no-session preview")
    send("keep my prompt")
    eq(" Session: none", info()[3], "still no target")
    eq({ "keep my prompt" }, vim.api.nvim_buf_get_lines(input(), 0, -1, false), "prompt kept")
    eq({ { message = no_session, level = vim.log.levels.ERROR } }, notifications, "one no-session error")
  end)
end

test("none to some requires a preview-only Enter before delivery", function()
  fresh()
  vim.cmd.PiSelection()
  eq(" Session: none", info()[3], "initial none")
  local received = session()
  send()
  vim.wait(30)
  eq({}, received, "new target not sent automatically")
  eq(" Session: /remote/checkout [pid 42, 07:23] auto", info()[3], "new target preview")
  eq({ { message = "pi target changed, press Enter to send", level = vim.log.levels.WARN } }, notifications, "one change warning")
  notifications = {}
  selection_request(received, "local second = 2", 2, 2)
end)

test("some to none refreshes without sending", function()
  fresh()
  local received, socket = session()
  pi.config.socket_path = socket
  vim.cmd.PiSelection()
  vim.fn.delete(socket)
  send("keep this")
  eq(" Session: none", info()[3], "target disappeared")
  eq({ "keep this" }, vim.api.nvim_buf_get_lines(input(), 0, -1, false), "disappeared target keeps prompt")
  eq({}, received, "no request")
  eq({ { message = no_session, level = vim.log.levels.ERROR } }, notifications, "one no-session error")
end)

test("a refused pinned socket never falls back to the live discovery target", function()
  fresh()
  local received, live = session()
  local _, dead, server = session("bbbbbbbbbbbb-2-000002", { cwd = "/dead" })
  assert(uv.fs_rename(dead, dead .. ".retained"))
  server:close()
  vim.wait(10)
  assert(uv.fs_rename(dead .. ".retained", dead))
  assert(uv.fs_utime(dead, 100, 100))
  assert(uv.fs_utime(live, 200, 200))
  pi.state.pinned = dead
  vim.cmd.PiSelection()
  send("keep this")
  assert(vim.wait(2000, function() return #notifications > 0 end), "connection failure timed out")
  eq({}, received, "live fallback received nothing")
  eq({ { message = "Failed to connect to pi: ECONNREFUSED", level = vim.log.levels.ERROR } }, notifications, "one delivery failure")
  eq({ "keep this" }, vim.api.nvim_buf_get_lines(input(), 0, -1, false), "prompt retained")
  eq(" Session: /remote/checkout [pid 42, 07:23] auto", info()[3], "preview refreshed after failure")
end)

local function highlighted_lines()
  local result = {}
  for _, ns in pairs(vim.api.nvim_get_namespaces()) do
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(source, ns, 0, -1, { details = true })) do
      if mark[4].hl_group == "Visual" then table.insert(result, mark[2] + 1) end
    end
  end
  table.sort(result)
  return result
end

for _, cancel in ipairs({ "<Esc>", "<C-c>" }) do
  test(cancel .. " closes both bubbles and clears current-line highlighting", function()
    fresh()
    local received = session()
    local windows = #vim.api.nvim_list_wins()
    vim.cmd.PiSelection()
    eq({ 2 }, highlighted_lines(), "current line highlighted")
    eq(windows + 2, #vim.api.nvim_list_wins(), "two bubbles")
    local prompt = input()
    key(cancel)
    eq(nil, input(), "dialog closed")
    eq(false, vim.api.nvim_buf_is_valid(prompt), "prompt buffer removed")
    eq(windows, #vim.api.nvim_list_wins(), "both bubbles closed")
    eq({}, highlighted_lines(), "highlight removed")
    eq({}, received, "cancelling never delivers")
  end)
end

test("explicit selection highlights every source line until successful delivery", function()
  fresh()
  local received = session()
  vim.cmd("1,3PiSelection")
  eq({ 1, 2, 3 }, highlighted_lines(), "range highlighted")
  selection_request(received, "local first = 1\nlocal second = 2\nreturn first + second", 1, 3)
  eq({}, highlighted_lines(), "successful delivery clears highlight")
end)

test("Tab has no local binding in either mode", function()
  fresh()
  session()
  vim.cmd.PiSelection()
  for _, mode in ipairs({ "i", "n" }) do
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(input(), mode)) do
      assert(mapping.lhs ~= "<Tab>" and mapping.lhs ~= "<C-I>", "no buffer-local Tab binding in " .. mode)
    end
  end
end)

test("focus loss closes the dialog and removes selection highlighting", function()
  fresh()
  local received = session()
  vim.cmd.PiSelection()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == source then vim.api.nvim_set_current_win(win); break end
  end
  assert(vim.wait(1000, function() return not input() end), "focus loss did not close dialog")
  eq({}, highlighted_lines(), "focus loss clears highlight")
  eq({}, received, "focus loss never delivers")
end)

for _, mode in ipairs({ "insert", "submit" }) do
  test("named virtual buffer preserves its full label for " .. mode, function()
    fresh()
    local received = session()
    vim.bo[source].buftype = "nofile"
    vim.api.nvim_buf_set_name(source, root .. "/Scratch")
    vim.cmd.PiSelection()
    eq(" File: " .. root .. "/Scratch", info()[1], "full virtual name, not relative path")
    send(mode == "submit" and "Explain" or nil)
    local header = "(buffer: " .. root .. "/Scratch) lines 2-2:\n```lua\nlocal second = 2\n```"
    delivered(received, mode == "submit" and "prompt" or "insert", mode == "submit" and "Explain\n\nFrom " .. header or header)
  end)
end

test("terminal buffers retain their label and terminal text", function()
  fresh()
  local received = session()
  local term = vim.api.nvim_create_buf(false, true)
  table.insert(buffers, term)
  local channel = vim.api.nvim_open_term(term, {})
  vim.api.nvim_buf_set_name(term, "term://test:pi")
  vim.api.nvim_set_current_buf(term)
  source = term
  vim.api.nvim_chan_send(channel, "terminal output\r\n")
  vim.wait(20)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd.PiSelection()
  eq(" File: term://test:pi", info()[1], "terminal info label")
  send()
  delivered(received, "insert", "(buffer: term://test:pi) lines 1-1:\n```\nterminal output\n```")
end)

test("unnamed buffers display no file and deliver the unnamed-buffer label", function()
  fresh()
  local received = session()
  vim.api.nvim_buf_set_name(source, "")
  vim.cmd.PiSelection()
  eq(" File: (no file)", info()[1], "unnamed preview")
  send()
  delivered(received, "insert", "(unnamed buffer) lines 2-2:\n```lua\nlocal second = 2\n```")
end)

test("the dialog starts in insert mode when opened through a normal mapping", function()
  fresh()
  local received = session()
  vim.keymap.set("n", "Q", "<Cmd>PiSelection<CR>")
  feed("Qhello")
  eq({ "hello" }, vim.api.nvim_buf_get_lines(input(), 0, -1, false), "typing goes into prompt")
  send()
  delivered(received, "prompt", "hello\n\nFrom /remote/checkout/example.lua lines 2-2:\n```lua\nlocal second = 2\n```")
end)

test("prompt grows by display cells and caps its multiline height", function()
  fresh()
  session()
  vim.cmd.PiSelection()
  local prompt, win = input()
  vim.api.nvim_buf_set_lines(prompt, 0, -1, false, { string.rep("界", 30) })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = prompt })
  eq(1, vim.api.nvim_win_get_height(win), "wide characters fitting one display row")
  vim.api.nvim_buf_set_lines(prompt, 0, -1, false, { "1", "2", "3", "4", "5", "6", "7", "8" })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = prompt })
  eq(6, vim.api.nvim_win_get_height(win), "maximum six rows")
end)

test("an empty visual region warns and leaves visual mode without opening", function()
  fresh({ "alpha", "", "charlie" })
  local received = session()
  vim.keymap.set("x", "Q", "<Cmd>PiSelection<CR>")
  feed("vQ")
  eq(nil, input(), "no empty dialog")
  eq({}, received, "no empty delivery")
  eq({ { message = "Empty selection", level = vim.log.levels.WARN } }, notifications, "one empty warning")
  assert(not vim.fn.mode():match("^[vV\022]"), "visual mode exited")
end)

test("multibyte characterwise selection does not split UTF-8 characters", function()
  fresh({ "a界bc", "d界ef", "last" })
  local received = session()
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  vim.keymap.set("x", "Q", "<Cmd>PiSelection<CR>")
  feed("vjlQ")
  selection_request(received, "界bc\nd界e", 1, 2)
end)

test("a long file name cannot wrap and obscure the displayed target", function()
  fresh()
  session()
  vim.api.nvim_buf_set_name(source, root .. "/" .. string.rep("long-directory/", 12) .. "example.lua")
  vim.cmd.PiSelection()
  local _, _, win = info()
  eq(3, vim.api.nvim_win_text_height(win, {}).all, "exactly three visible info rows")
  eq(3, vim.api.nvim_win_call(win, function() return vim.fn.line("w$") end), "Session row is visible")
end)

test("a narrow bubble still displays all three info lines", function()
  fresh()
  vim.o.columns = 30
  session()
  vim.cmd.PiSelection()
  local _, _, win = info()
  eq(3, vim.api.nvim_win_text_height(win, {}).all, "no info wrapping")
  eq(3, vim.api.nvim_win_call(win, function() return vim.fn.line("w$") end), "target remains visible")
end)

for _, timestamp in ipairs({ "2026-99-99T07:23:09Z", "2026-02-29T07:23:09Z", "2026-10-21T07:23:99Z", "2026-10-21T07:23:09garbage" }) do
  test("an unparseable ISO start time shows ?, " .. timestamp, function()
    fresh()
    local _, socket = session("custom", { metadata = { startedAt = timestamp } })
    pi.config.socket_path = socket
    vim.cmd.PiSelection()
    eq(" Session: ? [pid ?, ?] config", info()[3], "invalid ISO field")
  end)
end

for _, prompt in ipairs({ "", "Explain" }) do
  test("real Enter key dispatch delivers " .. (prompt == "" and "insert" or "submit"), function()
    fresh()
    local received = session()
    vim.keymap.set("n", "Q", "<Cmd>PiSelection<CR>")
    feed("Q" .. prompt .. "<CR>")
    local header = "/remote/checkout/example.lua lines 2-2:\n```lua\nlocal second = 2\n```"
    delivered(received, prompt == "" and "insert" or "prompt", prompt == "" and header or prompt .. "\n\nFrom " .. header)
  end)
end

for _, cancel in ipairs({ "<Esc>", "<C-c>" }) do
  test("real " .. cancel .. " key dispatch cancels from insert mode", function()
    fresh()
    local received = session()
    vim.keymap.set("n", "Q", "<Cmd>PiSelection<CR>")
    feed("Qunsent" .. cancel)
    eq(nil, input(), "cancel closes dialog")
    eq({}, received, "cancel does not deliver")
    eq({}, highlighted_lines(), "cancel clears highlighting")
  end)
end

for _, mapping in ipairs({ ":PiSelection<CR>", "<Cmd>PiSelection<CR>" }) do
  test("single-line characterwise region through " .. mapping, function()
    fresh({ "alpha", "bravo", "charlie" })
    local received = session()
    vim.keymap.set("x", "Q", mapping)
    vim.api.nvim_win_set_cursor(0, { 2, 1 })
    feed("vlQ")
    selection_request(received, "ra", 2, 2)
  end)
end

test("normal no-range command ignores stale visual marks", function()
  fresh({ "alpha", "bravo", "charlie" })
  local received = session()
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  feed("vjl<Esc>")
  vim.api.nvim_win_set_cursor(0, { 3, 2 })
  vim.cmd.PiSelection()
  selection_request(received, "charlie", 3, 3)
end)

test("a two-line range differing from existing marks uses whole lines", function()
  fresh({ "alpha", "bravo", "charlie" })
  local received = session()
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  feed("vjl<Esc>")
  vim.cmd("2,3PiSelection")
  selection_request(received, "bravo\ncharlie", 2, 3)
end)

-- Ticket 04: draft lifecycle. Reset through the UI, not module internals.
local function prompt_lines()
  return vim.api.nvim_buf_get_lines(assert(input()), 0, -1, false)
end

local function write_prompt(text)
  vim.api.nvim_buf_set_lines(assert(input()), 0, -1, false, vim.split(text, "\n"))
end

local function clear_draft()
  if not input() then vim.cmd.PiSelection() end
  write_prompt("")
  key("<Esc>")
end

local function lose_focus()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == source then vim.api.nvim_set_current_win(win); break end
  end
  assert(vim.wait(1000, function() return not input() end), "focus loss did not close dialog")
end

for _, cancel in ipairs({ "<Esc>", "<C-c>", "focus loss" }) do
  test(cancel .. " preserves a trimmed multiline draft in the next dialog", function()
    fresh()
    local received = session()
    vim.cmd.PiSelection()
    write_prompt("  first line\nsecond line  ")
    if cancel == "focus loss" then lose_focus() else key(cancel) end
    vim.cmd.PiSelection()
    eq({ "first line", "second line" }, prompt_lines(), "restored trimmed draft")
    local _, win = input()
    eq(2, vim.api.nvim_win_get_height(win), "restored draft sizes prompt immediately")
    eq({ 2, 11 }, vim.api.nvim_win_get_cursor(win), "cursor at end of draft")
    eq({}, received, "cancelling never sends")
    clear_draft()
  end)
end

test("closing with whitespace clears a previous draft", function()
  fresh()
  session()
  vim.cmd.PiSelection()
  write_prompt("old draft")
  key("<Esc>")
  vim.cmd.PiSelection()
  eq({ "old draft" }, prompt_lines(), "draft available before clearing")
  write_prompt("  \n  ")
  key("<C-c>")
  vim.cmd.PiSelection()
  eq({ "" }, prompt_lines(), "empty close clears draft")
end)

for _, prompt in ipairs({ "", "delivered prompt" }) do
  test("successful " .. (prompt == "" and "insert" or "submit") .. " clears the draft", function()
    fresh()
    local received = session()
    vim.cmd.PiSelection()
    write_prompt("previous draft")
    key("<Esc>")
    vim.cmd.PiSelection()
    eq({ "previous draft" }, prompt_lines(), "old draft restored")
    send(prompt)
    local header = "/remote/checkout/example.lua lines 2-2:\n```lua\nlocal second = 2\n```"
    delivered(received, prompt == "" and "insert" or "prompt", prompt == "" and header or prompt .. "\n\nFrom " .. header)
    vim.cmd.PiSelection()
    eq({ "" }, prompt_lines(), "successful delivery clears draft")
  end)
end

local function await_request(received)
  assert(vim.wait(2000, function() return #received > 0 end), "request did not reach test socket")
end

test("Enter while a request is in flight is ignored even when the target changes", function()
  fresh()
  local received, socket, _, respond = session(nil, { defer = true })
  local other, replacement = session("bbbbbbbbbbbb-2-000002", { cwd = "/replacement" })
  pi.state.pinned = socket
  vim.cmd.PiSelection()
  send("once only")
  await_request(received)
  pi.state.pinned = replacement
  key("<CR>")
  key("<CR>")
  vim.wait(30)
  eq(1, #received, "one original request")
  eq({}, other, "no request to new target")
  eq({}, notifications, "second Enter does not warn or notify")
  eq(" Session: /remote/checkout [pid 42, 07:23] pinned", info()[3], "in-flight preview unchanged")
  respond()
  delivered(received, "prompt", "once only\n\nFrom /remote/checkout/example.lua lines 2-2:\n```lua\nlocal second = 2\n```")
end)

for _, outcome in ipairs({ "success", "failure" }) do
  for _, cancel in ipairs({ "<Esc>", "<C-c>", "focus loss" }) do
    test(outcome .. " after " .. cancel .. " touches no UI and " .. (outcome == "success" and "clears" or "keeps") .. " the draft", function()
      fresh()
      local received, _, _, respond = session(nil, { defer = true })
      vim.cmd.PiSelection()
      local old_prompt = input()
      send("  sent snapshot  ")
      await_request(received)
      -- Closing keeps the latest edited text, not just the submitted snapshot.
      write_prompt("  edited while waiting\nstill unsent  ")
      if cancel == "focus loss" then lose_focus() else key(cancel) end
      eq(false, vim.api.nvim_buf_is_valid(old_prompt), "closed prompt deleted before response")
      local windows, bufs = vim.api.nvim_list_wins(), vim.api.nvim_list_bufs()
      vim.v.errmsg = ""
      respond(outcome == "failure" and '{"ok":false,"error":"rejected"}\n' or nil)
      assert(vim.wait(2000, function() return #notifications > 0 end), "response callback timed out")
      eq(windows, vim.api.nvim_list_wins(), "callback leaves windows alone")
      eq(bufs, vim.api.nvim_list_bufs(), "callback leaves buffers alone")
      eq("", vim.v.errmsg, "no callback errors on deleted UI")
      eq(nil, input(), "callback does not reopen dialog")
      eq({ { message = outcome == "failure" and "pi error: rejected" or "Sent to pi",
        level = outcome == "failure" and vim.log.levels.ERROR or vim.log.levels.INFO } }, notifications, "one delivery notification")
      eq(1, #received, "closing never cancels or resends written request")
      vim.cmd.PiSelection()
      eq(outcome == "failure" and { "edited while waiting", "still unsent" } or { "" }, prompt_lines(), "draft after late callback")
      clear_draft()
    end)
  end
end

for _, outcome in ipairs({ "success", "failure" }) do
  test("late " .. outcome .. " leaves a newly opened dialog untouched", function()
    fresh()
    local received, _, _, respond = session(nil, { defer = true })
    vim.cmd.PiSelection()
    send("first dialog")
    await_request(received)
    key("<Esc>")
    vim.cmd.PiSelection()
    write_prompt("editing a new dialog")
    local prompt, win = input()
    local preview = info()
    respond(outcome == "failure" and '{"ok":false,"error":"late failure"}\n' or nil)
    assert(vim.wait(2000, function() return #notifications > 0 end), "response callback timed out")
    eq(prompt, input(), "new dialog stays open")
    eq(win, vim.api.nvim_get_current_win(), "focus unchanged")
    eq({ "editing a new dialog" }, prompt_lines(), "new prompt unchanged")
    eq(preview, info(), "new preview unchanged")
    clear_draft()
  end)
end


for _, case in ipairs({
  { name = "pi rejection", response = '{"ok":false,"error":"try again"}\n', message = "pi error: try again" },
  { name = "invalid response", response = 'not json\n', message = "Invalid response from pi" },
  { name = "closed connection", response = false, message = "pi closed the connection without a response" },
}) do
  for _, target_state in ipairs({ "same", "changed", "none" }) do
    test(case.name .. " keeps the prompt and refreshes the " .. target_state .. " target for retry", function()
      fresh()
      local original, socket, _, respond = session(nil, { defer = true })
      pi.config.socket_path = socket
      vim.cmd.PiSelection()
      send("  retry this\nwithout retyping  ")
      await_request(original)
      local replacement
      if target_state == "changed" then
        local next_socket
        replacement, next_socket = session("bbbbbbbbbbbb-2-000002", { cwd = "/replacement" })
        pi.config.socket_path = next_socket
      elseif target_state == "none" then
        pi.config.socket_path = root .. "/missing.sock"
      end
      respond(case.response)
      assert(vim.wait(2000, function() return #notifications > 0 end), "failure callback timed out")
      eq({ "  retry this", "without retyping  " }, prompt_lines(), "untrimmed prompt retained in open dialog")
      eq({ { message = case.message, level = vim.log.levels.ERROR } }, notifications, "only delivery reports failure")
      local preview = target_state == "none" and " Session: none"
        or " Session: " .. (target_state == "changed" and "/replacement" or "/remote/checkout") .. " [pid 42, 07:23] config"
      eq(preview, info()[3], "preview re-resolved after failure")
      eq(1, #original, "failure does not resend automatically")
      if replacement then eq({}, replacement, "replacement awaits next Enter") end
      notifications = {}
      if target_state == "none" then
        send()
        eq({ { message = no_session, level = vim.log.levels.ERROR } }, notifications, "retry with no session stays open")
        eq({ "  retry this", "without retyping  " }, prompt_lines(), "no-session retry keeps prompt")
        clear_draft()
      else
        send()
        local expected = "retry this\nwithout retyping\n\nFrom /remote/checkout/example.lua lines 2-2:\n```lua\nlocal second = 2\n```"
        if target_state == "same" then
          assert(vim.wait(2000, function() return #original == 2 end), "retry did not send")
          eq({ type = "prompt", message = expected }, original[2], "retry on same socket")
          table.remove(original, 1)
          respond()
        end
        delivered(replacement or original, "prompt", expected)
      end
    end)
  end
end

local function open_prompt_only()
  vim.cmd.PiPrompt()
end

for _, has_session in ipairs({ false, true }) do
  test("an empty prompt-only context warns and stays open, session=" .. tostring(has_session), function()
    fresh()
    local received = has_session and session() or {}
    open_prompt_only()
    local prompt = input()
    write_prompt("  \n  ")
    key("<CR>")
    vim.wait(30)
    eq(prompt, input(), "empty prompt stays open")
    eq({ "  ", "  " }, prompt_lines(), "empty prompt text retained")
    eq({}, received, "nothing sent")
    eq({ { message = "Nothing to send", level = vim.log.levels.WARN } }, notifications, "one empty-prompt warning")
    clear_draft()
  end)
end

test("a draft crosses context kinds and prompt-only delivery clears it", function()
  fresh()
  local received, socket = session("custom")
  vim.fn.delete(socket .. ".info")
  pi.config.socket_path = socket
  vim.cmd.PiSelection()
  write_prompt("  selection draft\nsecond line  ")
  key("<Esc>")
  open_prompt_only()
  eq({ "selection draft", "second line" }, prompt_lines(), "selection draft restored without file context")
  eq(" File: not attached", info()[1], "no attached file")
  eq(" Context: prompt only", info()[2], "prompt-only preview")
  write_prompt("  prompt-only draft  ")
  key("<C-c>")
  vim.cmd.PiSelection()
  eq({ "prompt-only draft" }, prompt_lines(), "prompt-only draft restored in selection")
  key("<Esc>")
  open_prompt_only()
  send()
  delivered(received, "prompt", "prompt-only draft")
  vim.cmd.PiSelection()
  eq({ "" }, prompt_lines(), "prompt-only success clears shared draft")
end)

-- Draft writes, including deliberate clears, supersede older delivery callbacks.
for _, outcome in ipairs({ "success", "failure" }) do
  for _, action in ipairs({ "new prompt", "same prompt", "empty close", "insert success", "submit success" }) do
    test("late " .. outcome .. " cannot overwrite a newer " .. action, function()
      fresh()
      local original, socket, _, respond = session(nil, { defer = true })
      pi.config.socket_path = socket
      vim.cmd.PiSelection()
      send("first draft")
      await_request(original)
      key("<Esc>")

      local expected
      if action == "insert success" or action == "submit success" then
        local replacement, next_socket = session("bbbbbbbbbbbb-2-000002")
        pi.config.socket_path = next_socket
        vim.cmd.PiSelection()
        local prompt = action == "submit success" and "new delivered prompt" or ""
        send(prompt)
        local header = "/remote/checkout/example.lua lines 2-2:\n```lua\nlocal second = 2\n```"
        delivered(replacement, prompt == "" and "insert" or "prompt", prompt == "" and header or prompt .. "\n\nFrom " .. header)
        expected = { "" }
      else
        -- Draft ownership is shared across context kinds, not tied to a file.
        open_prompt_only()
        local prompt = action == "empty close" and "  \n  "
          or action == "same prompt" and "first draft" or "  newer draft\nkeep this  "
        write_prompt(prompt)
        key("<Esc>")
        expected = action == "empty close" and { "" }
          or action == "same prompt" and { "first draft" } or { "newer draft", "keep this" }
      end

      -- The older request still completes and reports its outcome exactly once.
      notifications = {}
      local windows, bufs = vim.api.nvim_list_wins(), vim.api.nvim_list_bufs()
      vim.v.errmsg = ""
      respond(outcome == "failure" and '{"ok":false,"error":"late failure"}\n' or nil)
      assert(vim.wait(2000, function() return #notifications > 0 end), "older result timed out")
      eq({ { message = outcome == "failure" and "pi error: late failure" or "Sent to pi",
        level = outcome == "failure" and vim.log.levels.ERROR or vim.log.levels.INFO } }, notifications, "single older delivery notification")
      eq(windows, vim.api.nvim_list_wins(), "late callback leaves windows alone")
      eq(bufs, vim.api.nvim_list_bufs(), "late callback leaves buffers alone")
      eq("", vim.v.errmsg, "no callback errors on closed UI")
      eq(1, #original, "older delivery is not resent or cancelled")
      open_prompt_only()
      eq(expected, prompt_lines(), "newer draft decision survives older result")
      clear_draft()
    end)
  end
end

local function dialog_count()
  local count = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "pi-nvim-prompt" then count = count + 1 end
  end
  return count
end

test("opening a second dialog closes the first and restores its unsent prompt", function()
  fresh()
  session()
  local windows = #vim.api.nvim_list_wins()
  vim.cmd.PiSelection()
  write_prompt("  first unsent prompt  ")
  local old_prompt = input()
  vim.cmd.PiSelection()
  eq(1, dialog_count(), "only one active dialog")
  eq(false, vim.api.nvim_buf_is_valid(old_prompt), "previous prompt deleted")
  eq(windows + 2, #vim.api.nvim_list_wins(), "no orphaned info bubble")
  eq({ "first unsent prompt" }, prompt_lines(), "previous prompt saved before replacement opens")
  clear_draft()
end)

for _, outcome in ipairs({ "success", "failure" }) do
  test("opening a second dialog during delivery protects its draft from older " .. outcome, function()
    fresh()
    local received, socket, _, respond = session(nil, { defer = true })
    pi.config.socket_path = socket
    local windows = #vim.api.nvim_list_wins()
    vim.cmd.PiSelection()
    send("older request")
    await_request(received)
    local old_prompt = input()
    -- Run a public command while still in A's prompt, without manually closing A.
    vim.cmd.PiSelection()
    eq(1, dialog_count(), "previous dialog closes synchronously")
    eq(false, vim.api.nvim_buf_is_valid(old_prompt), "old in-flight prompt deleted")
    eq(windows + 2, #vim.api.nvim_list_wins(), "exactly one pair of bubbles")
    write_prompt("newer replacement draft")
    key("<Esc>")
    respond(outcome == "failure" and '{"ok":false,"error":"late failure"}\n' or nil)
    assert(vim.wait(2000, function() return #notifications > 0 end), "older result timed out")
    eq(1, #received, "replacement never cancels or resends request")
    eq(windows, #vim.api.nvim_list_wins(), "late result leaves closed windows alone")
    open_prompt_only()
    eq({ "newer replacement draft" }, prompt_lines(), "replacement draft survives old callback")
    clear_draft()
  end)
end

test("an ignored older failure cannot take ownership from a newer identical pending draft", function()
  fresh()
  local received, _, _, respond = session(nil, { defer = true })
  vim.cmd.PiSelection()
  send("same pending prompt")
  await_request(received)
  key("<Esc>")
  vim.cmd.PiSelection()
  send()
  assert(vim.wait(2000, function() return #received == 2 end), "second request timed out")
  key("<Esc>")
  respond('{"ok":false,"error":"older failure"}\n')
  assert(vim.wait(2000, function() return #notifications == 1 end), "older failure timed out")
  respond()
  assert(vim.wait(2000, function() return #notifications == 2 end), "newer success timed out")
  eq({ { message = "pi error: older failure", level = vim.log.levels.ERROR },
    { message = "Sent to pi", level = vim.log.levels.INFO } }, notifications, "both delivery outcomes reported once")
  open_prompt_only()
  eq({ "" }, prompt_lines(), "newer success still owns and clears its draft")
  clear_draft()
end)

-- Ticket 05: :PiPrompt, :PiFile and :PiBuffer.
test(":PiPrompt shows no attached file and submits only the prompt text", function()
  fresh()
  local received = session()
  vim.cmd.PiPrompt()
  eq({ " File: not attached", " Context: prompt only", " Session: /remote/checkout [pid 42, 07:23] auto" }, info(), "info bubble")
  send("  What is new?\nThanks  ")
  delivered(received, "prompt", "What is new?\nThanks")
end)

test(":PiPrompt is accepted by a configured socket without manifest metadata", function()
  fresh()
  local received, socket = session("custom")
  vim.fn.delete(socket .. ".info")
  pi.config.socket_path = socket
  vim.cmd.PiPrompt()
  eq(" Session: ? [pid ?, ?] config", info()[3], "unknown metadata")
  send("plain question")
  delivered(received, "prompt", "plain question")
end)

test(":PiPrompt opens without any pi session", function()
  fresh()
  vim.cmd.PiPrompt()
  eq(" Session: none", info()[3], "no session preview")
end)

for _, prompt in ipairs({ "", "  Explain this file\nbriefly  " }) do
  test(":PiFile " .. (prompt == "" and "inserts the file reference" or "submits the file reference with a prompt"), function()
    fresh()
    local received = session()
    vim.cmd.PiFile()
    eq({ " File: example.lua", " Context: file reference", " Session: /remote/checkout [pid 42, 07:23] auto" }, info(), "info bubble")
    eq({}, highlighted_lines(), "a file reference highlights no lines")
    send(prompt)
    if prompt == "" then
      delivered(received, "insert", "/remote/checkout/example.lua")
    else
      delivered(received, "prompt", "File: /remote/checkout/example.lua\n\nExplain this file\nbriefly")
    end
  end)
end

for _, case in ipairs({
  { name = "an unnamed buffer", setup = function() vim.api.nvim_buf_set_name(source, "") end },
  { name = "a virtual buffer", setup = function()
    vim.bo[source].buftype = "nofile"
    vim.api.nvim_buf_set_name(source, root .. "/Scratch")
  end },
  { name = "a terminal buffer", setup = function()
    local term = vim.api.nvim_create_buf(false, true)
    table.insert(buffers, term)
    vim.api.nvim_open_term(term, {})
    vim.api.nvim_set_current_buf(term)
  end },
}) do
  test(":PiFile in " .. case.name .. " warns and does not open", function()
    fresh()
    local received = session()
    case.setup()
    vim.cmd.PiFile()
    eq(nil, input(), "no dialog")
    eq({}, received, "no request")
    eq({ { message = "No file open", level = vim.log.levels.WARN } }, notifications, "no-file warning")
  end)
end

for _, command in ipairs({ "PiFile", "PiBuffer" }) do
  test(":" .. command .. " rejects a configured socket without manifest metadata and keeps the prompt", function()
    fresh()
    local received, socket = session("custom")
    vim.fn.delete(socket .. ".info")
    pi.config.socket_path = socket
    vim.cmd[command]()
    send("keep me")
    vim.wait(30)
    eq({}, received, "no invented reference delivered")
    eq({ { message = "Cannot determine checkout paths for this pi session; use a manifest in the shared <checkout>/tmp directory",
      level = vim.log.levels.ERROR } }, notifications, "reference error reported once")
    eq({ "keep me" }, prompt_lines(), "dialog stays open with the prompt")
    clear_draft()
  end)
end

local whole_buffer = "```lua\nlocal first = 1\nlocal second = 2\nreturn first + second\n```"

for _, prompt in ipairs({ "", "  Review\nthis buffer  " }) do
  test(":PiBuffer " .. (prompt == "" and "inserts" or "submits") .. " the contents captured at open", function()
    fresh()
    local received = session()
    vim.cmd.PiBuffer()
    eq({ " File: example.lua", " Context: buffer, 3 lines", " Session: /remote/checkout [pid 42, 07:23] auto" }, info(), "info bubble")
    eq({}, highlighted_lines(), "a buffer context highlights no lines")
    vim.api.nvim_buf_set_lines(source, 0, -1, false, { "changed later" })
    vim.bo[source].filetype = "text"
    send(prompt)
    if prompt == "" then
      delivered(received, "insert", "/remote/checkout/example.lua:\n" .. whole_buffer)
    else
      delivered(received, "prompt", "Review\nthis buffer\n\nFile: /remote/checkout/example.lua\n" .. whole_buffer)
    end
  end)
end

for _, case in ipairs({
  { name = "virtual", file = function() return root .. "/Scratch" end, label = function() return "(buffer: " .. root .. "/Scratch)" end,
    setup = function() vim.bo[source].buftype = "nofile"; vim.api.nvim_buf_set_name(source, root .. "/Scratch") end },
  { name = "unnamed", file = function() return "(no file)" end, label = function() return "(unnamed buffer)" end,
    setup = function() vim.api.nvim_buf_set_name(source, "") end },
}) do
  for _, prompt in ipairs({ "", "Explain" }) do
    test(":PiBuffer in a " .. case.name .. " buffer uses its label for " .. (prompt == "" and "insert" or "submit"), function()
      fresh()
      local received = session()
      case.setup()
      vim.cmd.PiBuffer()
      eq(" File: " .. case.file(), info()[1], "preview label")
      send(prompt)
      if prompt == "" then
        delivered(received, "insert", case.label() .. ":\n" .. whole_buffer)
      else
        delivered(received, "prompt", "Explain\n\nFile: " .. case.label() .. "\n" .. whole_buffer)
      end
    end)
  end
end

for _, prompt in ipairs({ "", "Explain" }) do
  test(":PiBuffer label context is accepted by a configured socket without manifest, " .. (prompt == "" and "insert" or "submit"), function()
    fresh()
    local received, socket = session("custom")
    vim.fn.delete(socket .. ".info")
    pi.config.socket_path = socket
    vim.api.nvim_buf_set_name(source, "")
    vim.cmd.PiBuffer()
    send(prompt)
    if prompt == "" then
      delivered(received, "insert", "(unnamed buffer):\n" .. whole_buffer)
    else
      delivered(received, "prompt", "Explain\n\nFile: (unnamed buffer)\n" .. whole_buffer)
    end
  end)
end

for _, case in ipairs({
  { name = "an empty buffer", lines = { "" }, count = 1, block = "```lua\n\n```" },
  { name = "a trailing empty line", lines = { "a", "b", "" }, count = 3, block = "```lua\na\nb\n\n```" },
}) do
  test(":PiBuffer keeps " .. case.name .. " exactly", function()
    fresh()
    vim.api.nvim_buf_set_lines(source, 0, -1, false, case.lines)
    local received = session()
    vim.cmd.PiBuffer()
    eq(" Context: buffer, " .. case.count .. " lines", info()[2], "line count")
    send()
    delivered(received, "insert", "/remote/checkout/example.lua:\n" .. case.block)
  end)
end

test(":PiFile outside the session checkout reports once and keeps the prompt", function()
  fresh()
  local received = session()
  vim.api.nvim_buf_set_name(source, base .. "/outside.lua")
  vim.cmd.PiFile()
  send("keep me")
  vim.wait(30)
  eq({}, received, "no reference outside the checkout")
  eq({ { message = "File is outside the selected pi session's checkout: " .. base .. "/outside.lua",
    level = vim.log.levels.ERROR } }, notifications, "outside-checkout error reported once")
  eq({ "keep me" }, prompt_lines(), "dialog stays open with the prompt")
  clear_draft()
end)

cleanup()
print(string.format("\n%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)
