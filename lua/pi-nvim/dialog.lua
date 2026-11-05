local M = {}
local paths = require("pi-nvim.paths")

-- Shared by every dialog context, and intentionally never persisted to disk.
local draft = ""
local draft_version = 0
local active_close

local function store_draft(text)
  draft = text
  -- Even an identical value or an empty close is a newer user decision.
  draft_version = draft_version + 1
  return draft_version
end

-- Local name relative to cwd; virtual buffers keep their full buffer name.
local function display_name()
  return vim.bo.buftype == "" and vim.fn.expand("%:.") or vim.api.nvim_buf_get_name(0)
end

--- Capture a reference to the current file; nil when the buffer has no real file.
function M.capture_file()
  local source = paths.capture_source(0)
  if not source.file then
    vim.notify("No file open", vim.log.levels.WARN)
    return nil
  end
  return { kind = "file", source = source, name = display_name() }
end

--- Capture the whole buffer now, so later edits cannot change what is sent.
function M.capture_buffer()
  return {
    kind = "buffer",
    source = paths.capture_source(0),
    name = display_name(),
    text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"),
    line_count = vim.api.nvim_buf_line_count(0),
    ft = vim.bo.filetype,
  }
end

--- Capture and format the current buffer's diagnostics now, so the dialog
--- sends exactly what it announced; nil when there are none.
function M.capture_diagnostics()
  local buf = vim.api.nvim_get_current_buf()
  local diagnostics = vim.diagnostic.get(buf)
  if #diagnostics == 0 then
    vim.notify("No diagnostics in current buffer", vim.log.levels.INFO)
    return nil
  end

  table.sort(diagnostics, function(a, b)
    if a.lnum ~= b.lnum then return a.lnum < b.lnum end
    if a.col ~= b.col then return a.col < b.col end
    if a.severity ~= b.severity then return a.severity < b.severity end
    return a.message < b.message
  end)

  local lines = {}
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

  return {
    kind = "diagnostics",
    source = paths.capture_source(buf),
    name = display_name(),
    text = table.concat(lines, "\n"),
    count = #diagnostics,
  }
end

--- Capture context before opening a floating window changes the current buffer.
function M.capture_selection(args)
  local start_pos, end_pos, region_type
  local mark_start, mark_end = vim.fn.getpos("'<"), vim.fn.getpos("'>")
  local mode = vim.fn.mode()
  if args.range == 2 and args.line1 == mark_start[2] and args.line2 == mark_end[2] then
    start_pos, end_pos, region_type = mark_start, mark_end, vim.fn.visualmode()
  elseif args.range == 0 and (mode == "v" or mode == "V" or mode == "\022") then
    start_pos, end_pos, region_type = vim.fn.getpos("v"), vim.fn.getpos("."), mode
  end

  local first, last, lines
  if start_pos then
    lines = vim.fn.getregion(start_pos, end_pos, { type = region_type })
    first, last = math.min(start_pos[2], end_pos[2]), math.max(start_pos[2], end_pos[2])
  else
    first = args.range == 0 and vim.fn.line(".") or args.line1
    last = args.range == 0 and first or args.line2
    lines = vim.api.nvim_buf_get_lines(0, first - 1, last, false)
  end
  -- <Cmd> leaves Visual mode active. Exit synchronously, before switching buffers.
  if mode == "v" or mode == "V" or mode == "\022" then
    vim.cmd.normal({ args = { "\027" }, bang = true })
  end
  local text = table.concat(lines, "\n")
  if text == "" then
    vim.notify("Empty selection", vim.log.levels.WARN)
    return nil
  end
  return {
    kind = "selection",
    source = paths.capture_source(0),
    source_buf = vim.api.nvim_get_current_buf(),
    name = display_name(),
    text = text,
    start_line = first,
    end_line = last,
    ft = vim.bo.filetype,
  }
end

local NO_SESSION = "No pi session found. Start pi with the pi-nvim extension and create <checkout>/tmp before starting pi in a container."

local function resolve_target()
  local pi = require("pi-nvim")
  local target = pi.get_session()
  local origin = pi.config.socket_path and "config"
    or (target and pi.state.pinned == target.socket and "pinned" or "auto")
  return target, origin
end

-- Keep whole characters and measure terminal cells, not UTF-8 bytes.
local function cut_at_end(text, width)
  while vim.fn.strdisplaywidth(text) > width do
    text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
  end
  return text
end

local function start_time(iso)
  local y, mo, d, h, mi, s, rest = (iso or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$")
  if not y then return "?" end
  local year, month, day = tonumber(y), tonumber(mo), tonumber(d)
  local leap = year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
  local days = { 31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if not days[month] or day < 1 or day > days[month]
    or tonumber(h) > 23 or tonumber(mi) > 59 or tonumber(s) > 59 then
    return "?"
  end
  local zone = rest:gsub("^%.%d+", "")
  if zone ~= "" and zone ~= "Z" then
    local zh, zm = zone:match("^[+-](%d%d):(%d%d)$")
    if not zh or tonumber(zh) > 23 or tonumber(zm) > 59 then return "?" end
  end
  return h .. ":" .. mi
end

local function session_line(target, origin, width)
  if not target then return cut_at_end(" Session: none", width) end
  local cwd = target.cwd and target.cwd ~= "" and target.cwd or "?"
  local time = start_time(target.started_at)
  local prefix = " Session: "
  local suffix = string.format(" [pid %s, %s] %s", target.pid or "?", time, origin)
  if vim.fn.strdisplaywidth(prefix .. cwd .. suffix) <= width then return prefix .. cwd .. suffix end
  if vim.fn.strdisplaywidth(prefix .. "…" .. suffix) > width then
    return cut_at_end(prefix .. "…" .. suffix, width)
  end
  while vim.fn.strdisplaywidth(prefix .. "…" .. cwd .. suffix) > width do
    cwd = vim.fn.strcharpart(cwd, 1)
  end
  return prefix .. "…" .. cwd .. suffix
end

--- Open the unified dialog with a context descriptor captured at command time.
function M.open(context)
  -- Float creation skips autocmds, so focus loss alone cannot close a replaced
  -- dialog. Save its prompt before reading the draft for the new one.
  if active_close then active_close() end
  local pi = require("pi-nvim")
  local selection = context.kind == "selection" and context or nil
  local source_buf = context.source_buf
  local target, origin = resolve_target()
  local file_info, context_info
  if context.kind == "prompt" then
    file_info, context_info = "File: not attached", "Context: prompt only"
  else
    file_info = "File: " .. (context.name ~= "" and context.name or "(no file)")
    if context.kind == "file" then
      context_info = "Context: file reference"
    elseif context.kind == "buffer" then
      context_info = string.format("Context: buffer, %d lines", context.line_count)
    elseif context.kind == "diagnostics" then
      context_info = string.format("Context: diagnostics, %d items", context.count)
    else
      local n = select(2, context.text:gsub("\n", "")) + 1
      context_info = string.format("Context: selection, %d lines (%d-%d)", n, context.start_line, context.end_line)
    end
  end
  -- Layout
  local width = math.min(72, math.floor(vim.o.columns * 0.5))
  local info_height = 3
  local max_input_height = 6
  local gap = 0 -- no gap between bubbles
  local top_row = math.floor((vim.o.lines - (info_height + 2 + gap + max_input_height + 2)) / 2)
  local col = math.floor((vim.o.columns - width - 2) / 2)

  -- Accent highlights
  local accent_hl = vim.api.nvim_get_hl(0, { name = "Function", link = false })
  local normal_hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local accent_fg = accent_hl.fg
  vim.api.nvim_set_hl(0, "PiNvimBorder", { fg = accent_fg, bg = normal_hl.bg })
  vim.api.nvim_set_hl(0, "PiNvimTitle", { fg = accent_fg, bg = normal_hl.bg })


  -- Top bubble: info
  local info_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[info_buf].buftype = "nofile"
  vim.api.nvim_buf_set_lines(info_buf, 0, -1, false, {
    " " .. file_info,
    " " .. context_info,
    session_line(target, origin, width),
  })
  vim.bo[info_buf].modifiable = false

  local info_win = vim.api.nvim_open_win(info_buf, false, {
    relative = "editor",
    width = width,
    height = info_height,
    row = top_row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " pi ",
    title_pos = "center",
    zindex = 50,
    noautocmd = true,
    focusable = false,
  })
  vim.wo[info_win].winhl = "NormalFloat:Normal,FloatBorder:PiNvimBorder,FloatTitle:PiNvimTitle"
  vim.wo[info_win].cursorline = false
  -- File/context may be long, but must never wrap over the target preview.
  vim.wo[info_win].wrap = false

  -- Bottom bubble: prompt input
  local input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[input_buf].buftype = "nofile"
  vim.bo[input_buf].filetype = "pi-nvim-prompt"
  local initial_lines = vim.split(draft, "\n")
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, initial_lines)

  local input_row = top_row + info_height + 2 + gap -- +2 for info border
  local input_win = vim.api.nvim_open_win(input_buf, true, {
    relative = "editor",
    width = width,
    height = 1,
    row = input_row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " prompt ",
    title_pos = "center",
    zindex = 50,
    noautocmd = true,
  })
  vim.wo[input_win].winhl = "NormalFloat:Normal,FloatBorder:PiNvimBorder,FloatTitle:PiNvimTitle"
  vim.wo[input_win].wrap = true

  -- Resize the input window to fit content (1..max_input_height rows)
  local function resize_input()
    if not vim.api.nvim_win_is_valid(input_win) then return end
    local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
    -- Count visual rows (each buffer line may wrap across multiple display rows)
    local visual_rows = 0
    for _, line in ipairs(lines) do
      -- A blank line still takes 1 row
      visual_rows = visual_rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
    end
    local new_height = math.max(1, math.min(max_input_height, visual_rows))
    vim.api.nvim_win_set_height(input_win, new_height)
    -- Scroll so the cursor line is always visible (bottom of window)
    local cursor_line = vim.api.nvim_win_get_cursor(input_win)[1]
    local top_line = math.max(1, cursor_line - new_height + 1)
    vim.api.nvim_win_call(input_win, function()
      vim.fn.winrestview({ topline = top_line })
    end)
  end

  vim.api.nvim_win_set_cursor(input_win, { #initial_lines, #initial_lines[#initial_lines] })
  resize_input()

  -- Highlight the visual selection in the source buffer while the dialog is open
  local sel_ns = nil
  if selection and vim.api.nvim_buf_is_valid(source_buf) then
    sel_ns = vim.api.nvim_create_namespace("pi_nvim_selection")
    for lnum = selection.start_line, selection.end_line do
      vim.api.nvim_buf_add_highlight(source_buf, sel_ns, "Visual", lnum - 1, 0, -1)
    end
  end

  -- Start in insert mode
  vim.cmd("noautocmd startinsert!")

  local closed = false
  local in_flight = false
  local closed_prompt, closed_draft_version

  local function read_prompt()
    return vim.fn.trim(table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n"))
  end

  local function close(delivered)
    if closed then return end
    closed_prompt = read_prompt()
    closed_draft_version = store_draft(delivered and "" or closed_prompt)
    closed = true
    active_close = nil
    if vim.api.nvim_get_current_buf() == input_buf then
      vim.cmd("noautocmd stopinsert")
    end
    -- Remove selection highlight from source buffer
    if sel_ns and vim.api.nvim_buf_is_valid(source_buf) then
      vim.api.nvim_buf_clear_namespace(source_buf, sel_ns, 0, -1)
    end
    pcall(vim.api.nvim_win_close, input_win, true)
    pcall(vim.api.nvim_win_close, info_win, true)
    pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, info_buf, { force = true })
  end

  active_close = close

  local function refresh_target(latest, latest_origin)
    target, origin = latest, latest_origin
    if closed then return end
    vim.bo[info_buf].modifiable = true
    vim.api.nvim_buf_set_lines(info_buf, 2, 3, false, { session_line(target, origin, width) })
    vim.bo[info_buf].modifiable = false
  end

  local function send()
    if closed or in_flight then return end
    local prompt_text = read_prompt()
    if context.kind == "prompt" and prompt_text == "" then
      vim.notify("Nothing to send", vim.log.levels.WARN)
      return
    end
    local latest, latest_origin = resolve_target()
    if not latest or not target or latest.socket ~= target.socket then
      refresh_target(latest, latest_origin)
      if latest then
        vim.notify("pi target changed, press Enter to send", vim.log.levels.WARN)
      else
        vim.notify(NO_SESSION, vim.log.levels.ERROR)
      end
      return
    end
    in_flight = true
    local function on_result(err)
      in_flight = false
      if closed then
        -- Only this dialog's own draft may be changed by its late result.
        -- A later close or successful delivery, even empty, supersedes it.
        if closed_draft_version == draft_version then
          store_draft(err and closed_prompt or "")
        end
      elseif not err then
        close(true)
      else
        refresh_target(resolve_target())
      end
    end
    local opts = { mode = prompt_text == "" and "insert" or "submit", session = target }
    if context.kind == "prompt" then
      pi.prompt(prompt_text, on_result, opts)
    else
      pi.send_file_context(context.source, function(reference)
        if context.kind == "file" then
          if prompt_text == "" then return reference end
          return "File: " .. reference .. "\n\n" .. prompt_text
        end
        if context.kind == "diagnostics" then
          local text = "Diagnostics for " .. reference .. ":\n" .. context.text
          if prompt_text == "" then return text end
          return prompt_text .. "\n\n" .. text
        end
        if context.kind == "buffer" then
          local block = string.format("```%s\n%s\n```", context.ft, context.text)
          if prompt_text == "" then return reference .. ":\n" .. block end
          return prompt_text .. "\n\nFile: " .. reference .. "\n" .. block
        end
        local header = string.format("%s lines %d-%d:", reference, context.start_line, context.end_line)
        local block = string.format("```%s\n%s\n```", context.ft, context.text)
        if prompt_text == "" then return header .. "\n" .. block end
        return prompt_text .. "\n\nFrom " .. header .. "\n" .. block
      end, on_result, opts)
    end
  end

  local kopts = { buffer = input_buf, noremap = true, silent = true }

  vim.keymap.set("i", "<CR>", send, kopts)
  vim.keymap.set({ "i", "n" }, "<Esc>", close, kopts)
  vim.keymap.set({ "i", "n" }, "<C-c>", close, kopts)
  -- Resize window as text is typed
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = input_buf,
    callback = resize_input,
  })

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = input_buf,
    once = true,
    callback = function()
      vim.schedule(close)
    end,
  })
end

return M
