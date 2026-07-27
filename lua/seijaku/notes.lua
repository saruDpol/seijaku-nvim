local M = {}

local state_mod = require("seijaku.state")
local index = require("seijaku.index")
local paths = require("seijaku.paths")
local util = require("seijaku.util")

local metadata_start = "<!-- seijaku:metadata:start -->"
local metadata_end = "<!-- seijaku:metadata:end -->"
local note_type_ns = vim.api.nvim_create_namespace("seijaku_note_type_selector")
local active_note_type_selector = nil
local note_types = {
  { value = "general", label = "General", icon = "·", highlight = "SeijakuNoteGeneral" },
  { value = "diary", label = "Diary", icon = "◷", highlight = "SeijakuNoteDiary" },
  { value = "meeting", label = "Meeting", icon = "○", highlight = "SeijakuNoteMeeting" },
  { value = "desc", label = "Description", icon = "≡", highlight = "SeijakuNoteDescription" },
  { value = "todo", label = "Todo", icon = "□", highlight = "SeijakuTodoOpen" },
}

local function refresh_sidebar()
  local ok, sidebar = pcall(require, "seijaku.sidebar")

  if ok then
    sidebar.refresh()
  end
end

function M.generate_id()
  local parts = util.date_parts()
  local time = os.date("%H%M%S")
  local random = util.random_hex(6)

  return string.format(
    "note_%s%s%s_%s_%s",
    parts.year,
    parts.month,
    parts.day,
    time,
    random
  )
end

function M.note_relative_path(note_id)
  local parts = util.date_parts()

  return paths.join(
    "notes",
    parts.year,
    parts.month,
    parts.day,
    note_id .. ".md"
  )
end

local function close_note_type_selector(selector)
  if not selector or selector.closed then
    return
  end
  selector.closed = true

  if selector.win and vim.api.nvim_win_is_valid(selector.win) then
    if vim.api.nvim_get_current_win() == selector.win then
      pcall(vim.cmd, "stopinsert")
    end
    pcall(vim.api.nvim_win_close, selector.win, true)
  end
  if selector.origin_win and vim.api.nvim_win_is_valid(selector.origin_win) then
    pcall(vim.api.nvim_set_current_win, selector.origin_win)
  end
  if active_note_type_selector == selector then
    active_note_type_selector = nil
  end
end

function M.select_note_type(opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = {}
  end
  opts = opts or {}

  if active_note_type_selector then
    close_note_type_selector(active_note_type_selector)
  end
  local origin_win = vim.api.nvim_get_current_win()

  local lines = {}
  for index_in_list, item in ipairs(note_types) do
    lines[index_in_list] = string.format("  %d  %s  %s", index_in_list, item.icon, item.label)
  end

  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.max(22, math.min(width + 3, math.max(1, vim.o.columns - 4)))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "seijaku-note-type"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local height = #lines
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " new item ",
    title_pos = "center",
    zindex = 60,
  })

  vim.wo[win].cursorline = true
  vim.wo[win].winhighlight =
    "Normal:SeijakuPickerNormal,FloatBorder:SeijakuBrand,FloatTitle:SeijakuBrand,CursorLine:SeijakuPickerCursor"
  vim.wo[win].winblend = 0

  for line, item in ipairs(note_types) do
    vim.api.nvim_buf_set_extmark(buf, note_type_ns, line - 1, 0, {
      end_col = #lines[line],
      hl_group = item.highlight,
      priority = 100,
    })
  end

  local selector = {
    buf = buf,
    win = win,
    origin_win = origin_win,
    closed = false,
  }
  active_note_type_selector = selector

  local function show_title_input(item)
    if selector.closed or not vim.api.nvim_win_is_valid(win) then
      return
    end

    local default = opts.title_for_type
    if type(default) == "function" then
      default = default(item.value)
    end
    default = tostring(default or "note-")

    vim.api.nvim_buf_clear_namespace(buf, note_type_ns, 0, -1)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { default })
    vim.bo[buf].filetype = "seijaku-note-title"
    local function submit()
      if selector.closed or not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      local title = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
      if not title or title:match("^%s*$") then
        return
      end
      close_note_type_selector(selector)
      vim.schedule(function()
        callback(item.value, title)
      end)
    end

    vim.api.nvim_win_set_config(win, {
      relative = "editor",
      row = math.max(0, math.floor((vim.o.lines - 1) / 2) - 1),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      width = width,
      height = 1,
      style = "minimal",
      border = "rounded",
      title = " item name ",
      title_pos = "center",
      zindex = 60,
    })
    vim.wo[win].cursorline = false
    vim.wo[win].winhighlight = string.format(
      "Normal:%s,FloatBorder:SeijakuBrand,FloatTitle:SeijakuBrand",
      item.highlight
    )
    vim.wo[win].wrap = false
    pcall(vim.api.nvim_win_set_cursor, win, { 1, #default })

    local input_opts = { buffer = buf, silent = true, nowait = true }
    vim.keymap.set({ "n", "i" }, "<CR>", submit, input_opts)
    vim.keymap.set("i", "<Esc>", function()
      close_note_type_selector(selector)
    end, input_opts)
    vim.keymap.set("i", "<C-c>", function()
      close_note_type_selector(selector)
    end, input_opts)
    vim.cmd("startinsert!")
  end

  local function move(delta)
    if selector.closed or not vim.api.nvim_win_is_valid(win) then
      return
    end
    local line = vim.api.nvim_win_get_cursor(win)[1] + delta
    if line < 1 then
      line = #note_types
    elseif line > #note_types then
      line = 1
    end
    vim.api.nvim_win_set_cursor(win, { line, 0 })
  end

  local function finish(choice)
    local item = note_types[choice]
    if not item or selector.closed then
      return
    end
    show_title_input(item)
  end

  local keymap_opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "j", function()
    move(1)
  end, keymap_opts)
  vim.keymap.set("n", "<Down>", function()
    move(1)
  end, keymap_opts)
  vim.keymap.set("n", "k", function()
    move(-1)
  end, keymap_opts)
  vim.keymap.set("n", "<Up>", function()
    move(-1)
  end, keymap_opts)
  vim.keymap.set("n", "<CR>", function()
    finish(vim.api.nvim_win_get_cursor(win)[1])
  end, keymap_opts)
  for index_in_list = 1, #note_types do
    local choice = index_in_list
    vim.keymap.set("n", tostring(choice), function()
      finish(choice)
    end, keymap_opts)
  end
  vim.keymap.set("n", "<Esc>", function()
    close_note_type_selector(selector)
  end, keymap_opts)
  vim.keymap.set("n", "<C-c>", function()
    close_note_type_selector(selector)
  end, keymap_opts)
  vim.keymap.set("n", "q", function()
    close_note_type_selector(selector)
  end, keymap_opts)

  if opts.initial_type then
    for _, item in ipairs(note_types) do
      if item.value == opts.initial_type then
        show_title_input(item)
        break
      end
    end
  end

  return win, buf
end

function M.input_title(item_type, default, callback)
  return M.select_note_type({
    initial_type = item_type,
    title_for_type = function()
      return default or ""
    end,
  }, function(_, title)
    callback(title)
  end)
end

local function default_title_for_type(note_type, opts)
  if note_type == "todo" then
    return ""
  end

  if note_type == "diary" then
    return "diary"
  end

  local associated_file = nil
  if opts.target_path and opts.target_type == "file" then
    associated_file = paths.basename(opts.target_path)
  end

  if note_type == "meeting" then
    return "meeting-" .. (associated_file or "")
  end

  if note_type == "desc" then
    return "desc-" .. (associated_file or "")
  end

  if opts.title and opts.title ~= "Untitled" then
    return opts.title
  end
  return "note-"
end

local function prompt_note(default, opts, callback)
  M.select_note_type({
    initial_type = default,
    title_for_type = function(note_type)
      return default_title_for_type(note_type, opts)
    end,
  }, callback)
end

local function metadata_lines(note)
  local lines = {
    metadata_start,
    "> Type: `" .. tostring(note.note_type or "general") .. "`",
    "> Created: `" .. tostring(note.created_at or "") .. "`",
    "> Updated: `" .. tostring(note.updated_at or "") .. "`",
  }

  if note.targets and #note.targets > 0 then
    for _, target in ipairs(note.targets) do
      table.insert(lines, "> Target: `" .. tostring(target.path or "") .. "`")
    end
  else
    table.insert(lines, "> Target: `global`")
  end

  if note.calendar_date then
    table.insert(lines, "> Date: `" .. tostring(note.calendar_date) .. "`")
  end

  table.insert(lines, metadata_end)
  return lines
end

local function with_metadata(lines, note)
  local start_line = nil
  local end_line = nil

  for line, text in ipairs(lines) do
    if text == metadata_start then
      start_line = line
    elseif start_line and text == metadata_end then
      end_line = line
      break
    end
  end

  local generated = metadata_lines(note)

  if start_line and end_line then
    local result = {}

    for line = 1, start_line - 1 do
      table.insert(result, lines[line])
    end
    vim.list_extend(result, generated)
    for line = end_line + 1, #lines do
      table.insert(result, lines[line])
    end

    return result
  end

  local result = {}
  local insert_after = lines[1] and lines[1]:match("^# ") and 1 or 0

  for line = 1, insert_after do
    table.insert(result, lines[line])
  end
  table.insert(result, "")
  vim.list_extend(result, generated)
  table.insert(result, "")
  for line = insert_after + 1, #lines do
    if not (line == insert_after + 1 and lines[line] == "") then
      table.insert(result, lines[line])
    end
  end

  return result
end

function M.sync_metadata(note, bufnr, opts)
  if not note or not note.file then
    return false
  end

  opts = opts or {}
  local abs_path = paths.join(state_mod.get().vault_dir, note.file)
  bufnr = bufnr or vim.fn.bufnr(abs_path, false)

  if bufnr and bufnr >= 0 and vim.api.nvim_buf_is_valid(bufnr) then
    local was_modified = vim.bo[bufnr].modified
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local updated_lines = with_metadata(lines, note)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, updated_lines)

    if not was_modified and opts.write ~= false then
      vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("silent noautocmd write")
      end)
    end

    return true
  end

  if vim.fn.filereadable(abs_path) == 0 then
    return false
  end

  local lines = vim.fn.readfile(abs_path)
  util.write_file(abs_path, with_metadata(lines, note))
  return true
end

function M.create(opts)
  opts = opts or {}

  prompt_note(opts.note_type, opts, function(note_type, title)
    if note_type == "todo" then
      require("seijaku.todos").create({
        text = title,
        calendar_date = opts.calendar_date,
        on_created = opts.on_created,
      })
      return
    end

    local state = state_mod.get()
    local note_id = M.generate_id()
    local rel_path = M.note_relative_path(note_id)
    local abs_path = paths.join(state.vault_dir, rel_path)
    local now = util.now()

    local note = {
      id = note_id,
      title = title,
      file = rel_path,
      created_at = now,
      updated_at = now,
      note_type = note_type,
      calendar_date = opts.calendar_date,
      targets = {},
      tags = {},
    }

    local initial_lines = {}
    vim.list_extend(initial_lines, metadata_lines(note))
    table.insert(initial_lines, "")
    table.insert(initial_lines, "# " .. title)
    table.insert(initial_lines, "")
    util.write_file(abs_path, initial_lines)

    index.add_note(note, { defer_save = true })

    if opts.target_path then
      index.attach(note_id, opts.target_path, opts.target_type, { defer_save = true })
    end

    index.save_sync()

    if opts.open ~= false then
      local sidebar_ok, sidebar = pcall(require, "seijaku.sidebar")
      local opened_in_sidebar = sidebar_ok and sidebar.open_preview(note_id, {
        force = true,
        focus = true,
      })

      if not opened_in_sidebar then
        M.open(note_id)
      end
    end

    if opts.on_created then
      opts.on_created(note)
    end

    refresh_sidebar()
  end)
end

function M.create_global()
  return M.create({
    title = "note-",
  })
end

function M.create_for_target(target_path, target_type)
  local title = paths.basename(target_path) or "note-"

  return M.create({
    title = title,
    target_path = target_path,
    target_type = target_type,
  })
end

function M.create_for_path(target_path)
  local normalized = paths.normalize(target_path)

  if not normalized then
    util.notify("invalid path: " .. tostring(target_path), vim.log.levels.ERROR)
    return
  end

  return M.create_for_target(normalized, paths.target_type(normalized))
end

function M.apply_window_options(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  local editor = state_mod.get().config.editor or {}
  local wrap = editor.wrap ~= false

  vim.wo[win].wrap = wrap
  vim.wo[win].linebreak = wrap and editor.linebreak ~= false
  vim.wo[win].breakindent = wrap and editor.breakindent ~= false
end

function M.open(note_id)
  local state = state_mod.get()
  local note = index.get_note(note_id)

  if not note then
    util.notify("note not found: " .. tostring(note_id), vim.log.levels.ERROR)
    return
  end

  local abs_path = paths.join(state.vault_dir, note.file)
  local cmd = state.config.editor.open_cmd or "vsplit"

  vim.cmd(cmd .. " " .. vim.fn.fnameescape(abs_path))
  M.apply_window_options(vim.api.nvim_get_current_win())
end

function M.rename(note_id, new_title)
  local note = index.get_note(note_id)

  if not note then
    return false
  end

  note.title = new_title
  note.updated_at = util.now()

  index.mark_dirty_sync(note)
  M.sync_metadata(note)
  refresh_sidebar()

  return true
end

function M.delete(note_id)
  local state = state_mod.get()
  local note = index.get_note(note_id)

  if not note then
    return false
  end

  local abs_path = paths.join(state.vault_dir, note.file)

  if vim.fn.filereadable(abs_path) == 1 then
    vim.fn.delete(abs_path)
  end

  index.delete_note(note_id)
  refresh_sidebar()

  return true
end

return M
