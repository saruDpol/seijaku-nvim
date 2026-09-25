local M = {}

local state_mod = require("seijaku.state")
local index = require("seijaku.index")
local paths = require("seijaku.paths")
local util = require("seijaku.util")

local metadata_start = "<!-- seijaku:metadata:start -->"
local metadata_end = "<!-- seijaku:metadata:end -->"
local note_type_ns = vim.api.nvim_create_namespace("seijaku_note_type_selector")
local tag_selector_ns = vim.api.nvim_create_namespace("seijaku_tag_selector")
local active_note_type_selector = nil
local active_tag_selector = nil
local tag_highlights = {}
local tag_glyph_highlights = {}
local tag_highlight_colors = {}
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
  if active_tag_selector and not active_tag_selector.closed then
    active_tag_selector.close()
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
    vim.keymap.set("i", "<CR>", submit, input_opts)
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

function M.select_tags(initial_tags, callback)
  if active_tag_selector and not active_tag_selector.closed then
    active_tag_selector.close()
  end
  if active_note_type_selector then
    close_note_type_selector(active_note_type_selector)
  end

  local selected = {}
  local available = {}
  local function add_tag(value, is_selected)
    local tag = vim.trim(tostring(value or "")):lower()
    if tag == "" then
      return
    end
    available[tag] = true
    if is_selected then
      selected[tag] = true
    end
  end
  for _, tag in ipairs(index.list_tags()) do
    add_tag(tag, false)
  end
  for _, tag in ipairs(initial_tags or {}) do
    add_tag(tag, true)
  end

  local origin_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false

  local width = 34
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - 8) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = math.min(width, math.max(1, vim.o.columns - 4)),
    height = 1,
    style = "minimal",
    border = "rounded",
    title = " tags · enter toggle · a add ",
    title_pos = "center",
    zindex = 60,
  })
  vim.wo[win].cursorline = true
  vim.wo[win].winhighlight =
    "Normal:SeijakuPickerNormal,FloatBorder:SeijakuBrand,FloatTitle:SeijakuBrand,CursorLine:SeijakuPickerCursor"

  local selector = {
    buf = buf,
    win = win,
    origin_win = origin_win,
    closed = false,
    tags = {},
  }

  local function close()
    if selector.closed then
      return
    end
    selector.closed = true
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.cmd, "stopinsert")
      pcall(vim.api.nvim_win_close, win, true)
    end
    if vim.api.nvim_win_is_valid(origin_win) then
      pcall(vim.api.nvim_set_current_win, origin_win)
    end
    if active_tag_selector == selector then
      active_tag_selector = nil
    end
  end
  selector.close = close
  active_tag_selector = selector

  local function sorted_tags()
    local result = vim.tbl_keys(available)
    table.sort(result)
    return result
  end

  local show_list
  show_list = function(preferred)
    if selector.closed or not vim.api.nvim_win_is_valid(win) then
      return
    end
    pcall(vim.cmd, "stopinsert")
    selector.tags = sorted_tags()
    local lines = {}
    if #selector.tags == 0 then
      lines = { "  no tags · press a to add" }
    else
      for line, tag in ipairs(selector.tags) do
        lines[line] = string.format("  %s %s", selected[tag] and "■" or " ", tag)
      end
    end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "seijaku-tags"
    vim.api.nvim_buf_clear_namespace(buf, tag_selector_ns, 0, -1)
    for line, tag in ipairs(selector.tags) do
      if selected[tag] then
        vim.api.nvim_buf_set_extmark(buf, tag_selector_ns, line - 1, 0, {
          end_col = #lines[line],
          hl_group = M.tag_highlight(tag),
          priority = 100,
        })
      end
    end
    vim.api.nvim_win_set_config(win, {
      relative = "editor",
      row = math.max(0, math.floor((vim.o.lines - #lines) / 2) - 1),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      width = math.min(width, math.max(1, vim.o.columns - 4)),
      height = #lines,
      style = "minimal",
      border = "rounded",
      title = " tags · enter toggle · a add ",
      title_pos = "center",
      zindex = 60,
    })
    local target_line = 1
    if preferred then
      for line, tag in ipairs(selector.tags) do
        if tag == preferred then
          target_line = line
          break
        end
      end
    end
    pcall(vim.api.nvim_win_set_cursor, win, { target_line, 0 })
  end

  local function finish()
    local result = vim.tbl_keys(selected)
    table.sort(result)
    close()
    callback(result)
  end

  local function toggle_current()
    local tag = selector.tags[vim.api.nvim_win_get_cursor(win)[1]]
    if not tag then
      return
    end
    selected[tag] = not selected[tag] or nil
    show_list(tag)
  end

  local function add_new()
    vim.api.nvim_buf_clear_namespace(buf, tag_selector_ns, 0, -1)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    vim.bo[buf].filetype = "seijaku-tag-input"
    vim.api.nvim_win_set_config(win, {
      relative = "editor",
      row = math.max(0, math.floor((vim.o.lines - 1) / 2) - 1),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      width = math.min(width, math.max(1, vim.o.columns - 4)),
      height = 1,
      style = "minimal",
      border = "rounded",
      title = " new tag ",
      title_pos = "center",
      zindex = 60,
    })
    local function submit()
      local tag = vim.trim(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""):lower()
      if tag == "" then
        return
      end
      if tag:find("[`,%c]") then
        vim.notify("seijaku: tags cannot contain commas, backticks or control characters", vim.log.levels.WARN)
        return
      end
      add_tag(tag, true)
      show_list(tag)
    end
    local input_opts = { buffer = buf, silent = true, nowait = true }
    vim.keymap.set("i", "<CR>", submit, input_opts)
    vim.keymap.set("i", "<Esc>", function()
      show_list()
    end, input_opts)
    vim.cmd("startinsert")
  end

  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "j", function()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    vim.api.nvim_win_set_cursor(win, { math.min(#vim.api.nvim_buf_get_lines(buf, 0, -1, false), line + 1), 0 })
  end, opts)
  vim.keymap.set("n", "k", function()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    vim.api.nvim_win_set_cursor(win, { math.max(1, line - 1), 0 })
  end, opts)
  vim.keymap.set("n", "<Down>", "j", opts)
  vim.keymap.set("n", "<Up>", "k", opts)
  vim.keymap.set("n", "a", add_new, opts)
  vim.keymap.set("n", "<CR>", toggle_current, opts)
  vim.keymap.set("n", "q", close, opts)
  vim.keymap.set("n", "<Esc>", finish, opts)
  vim.keymap.set("n", "<C-c>", close, opts)

  show_list()
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

  if note.tags and #note.tags > 0 then
    local tags = {}
    for _, tag in ipairs(note.tags) do
      table.insert(tags, "`" .. tostring(tag) .. "`")
    end
    table.insert(lines, "> Tags: " .. table.concat(tags, ", "))
  end

  if note.pinned then
    table.insert(lines, "> Pinned: `true`")
  end

  table.insert(lines, metadata_end)
  return lines
end

local function interpolate(text, values)
  return tostring(text or ""):gsub("{([%w_]+)}", function(key)
    return tostring(values[key] or "")
  end)
end

local function template_lines(note, opts)
  local templates = ((state_mod.get().config.notes or {}).templates or {})
  local template = templates[note.note_type or "general"]
  local values = {
    title = note.title,
    type = note.note_type,
    date = tostring(note.created_at or ""):match("^%d%d%d%d%-%d%d%-%d%d") or "",
    calendar_date = note.calendar_date or "",
    target = opts.target_path or "",
    target_name = opts.target_path and paths.basename(opts.target_path) or "",
  }

  if type(template) == "function" then
    template = template(vim.deepcopy(note), vim.deepcopy(values))
  end
  if type(template) == "string" then
    template = vim.split(template, "\n", { plain = true })
  end
  if type(template) ~= "table" then
    return {}
  end

  local result = {}
  for _, line in ipairs(template) do
    table.insert(result, (interpolate(line, values)))
  end
  return result
end

local function metadata_range(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil, nil
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local first, last
  for line, text in ipairs(lines) do
    if text == metadata_start then
      first = line
    elseif first and text == metadata_end then
      last = line
      break
    end
  end
  return first, last
end

local function ensure_tag_highlight(tag)
  local color = index.get_tag_color(tag)
  if not color then
    return
  end
  local hash = vim.fn.sha256(tag):sub(1, 12)
  local group = tag_highlights[tag] or "SeijakuTagBg_" .. hash
  local glyph_group = tag_glyph_highlights[tag] or "SeijakuTagGlyph_" .. hash
  if tag_highlight_colors[tag] ~= color then
    vim.api.nvim_set_hl(0, group, { fg = "#faf8f2", bg = color, bold = true })
    vim.api.nvim_set_hl(0, glyph_group, { fg = color, bg = "NONE", bold = true })
    tag_highlight_colors[tag] = color
  end
  tag_highlights[tag] = group
  tag_glyph_highlights[tag] = glyph_group
end

function M.define_tag_highlights()
  tag_highlight_colors = {}
  for _, tag in ipairs(index.list_tags()) do
    ensure_tag_highlight(tag)
  end
end

function M.tag_highlight(tag)
  ensure_tag_highlight(tag)
  return tag_highlights[tag] or "SeijakuTag"
end

function M.tag_glyph_highlight(tag)
  ensure_tag_highlight(tag)
  return tag_glyph_highlights[tag] or "SeijakuTag"
end

function M.metadata_foldtext()
  local note = index.get_note_for_file(vim.api.nvim_buf_get_name(0))
  local lines = vim.api.nvim_buf_get_lines(0, vim.v.foldstart - 1, vim.v.foldend, false)
  local target = nil
  local tags = nil
  local pinned = nil
  for _, line in ipairs(lines) do
    local target_value = line:match("^> Target:%s*`([^`]+)`")
    if target_value then
      target = target_value
    end
    local pinned_value = line:match("^> Pinned:%s*`([^`]+)`")
    if pinned_value then
      pinned = pinned_value == "true"
    end
    local tag_line = line:match("^> Tags:%s*(.*)$")
    if tag_line then
      tags = {}
      for tag in tag_line:gmatch("`([^`]+)`") do
        table.insert(tags, tag)
      end
    end
  end

  local label = target and target ~= "global" and paths.basename(target) or note and note.title
    or vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t:r")
  tags = tags or note and note.tags or {}
  if pinned == nil then
    pinned = note and note.pinned == true or false
  end
  local chunks = { { " " .. tostring(label) .. " ", "SeijakuMetadataFile" } }
  if pinned then
    table.insert(chunks, { " pinned ", "SeijakuPinnedBlock" })
  end
  for _, tag in ipairs(tags or {}) do
    table.insert(chunks, { " " .. tag .. " ", tag_highlights[tag] or "SeijakuTag" })
  end
  return chunks
end

function M.apply_metadata_fold(win, opts)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local editor = state_mod.get().config.editor or {}
  if editor.fold_metadata == false then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local first, last = metadata_range(buf)
  if not first or not last or last <= first then
    return false
  end
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, first - 1, last, false)) do
    local tag_line = line:match("^> Tags:%s*(.*)$")
    for tag in (tag_line or ""):gmatch("`([^`]+)`") do
      ensure_tag_highlight(tag)
    end
  end

  opts = opts or {}
  vim.api.nvim_win_call(win, function()
    vim.wo.foldmethod = "manual"
    vim.wo.foldenable = true
    vim.wo.foldtext = "v:lua.require('seijaku.notes').metadata_foldtext()"

    local window_highlights = {}
    for _, entry in ipairs(vim.split(vim.wo.winhighlight, ",", { plain = true, trimempty = true })) do
      if not entry:match("^Folded:") then
        table.insert(window_highlights, entry)
      end
    end
    table.insert(window_highlights, "Folded:SeijakuMetadataFold")
    vim.wo.winhighlight = table.concat(window_highlights, ",")

    if opts.reset == false and not opts.replace and vim.fn.foldlevel(first) > 0 then
      if opts.close ~= false then
        vim.cmd(string.format("silent! %dfoldclose", first))
        local cursor = vim.api.nvim_win_get_cursor(0)
        if cursor[1] >= first and cursor[1] <= last then
          local target = math.min(last + 1, vim.api.nvim_buf_line_count(buf))
          while target < vim.api.nvim_buf_line_count(buf)
              and vim.api.nvim_buf_get_lines(buf, target - 1, target, false)[1] == "" do
            target = target + 1
          end
          vim.api.nvim_win_set_cursor(0, { math.max(1, target), 0 })
        end
      end
      return
    end

    if opts.reset ~= false then
      vim.cmd("silent! normal! zE")
    elseif opts.replace then
      local cursor = vim.api.nvim_win_get_cursor(0)
      pcall(vim.api.nvim_win_set_cursor, 0, { first, 0 })
      vim.cmd("silent! normal! zD")
      pcall(vim.api.nvim_win_set_cursor, 0, cursor)
    end
    vim.cmd(string.format("silent! %d,%dfold", first, last))
    if opts.close ~= false then
      vim.cmd(string.format("silent! %dfoldclose", first))
      local cursor = vim.api.nvim_win_get_cursor(0)
      if cursor[1] >= first and cursor[1] <= last then
        local target = math.min(last + 1, vim.api.nvim_buf_line_count(buf))
        while target < vim.api.nvim_buf_line_count(buf)
            and vim.api.nvim_buf_get_lines(buf, target - 1, target, false)[1] == "" do
          target = target + 1
        end
        vim.api.nvim_win_set_cursor(0, { math.max(1, target), 0 })
      end
    end
  end)
  return true
end

function M.toggle_metadata(win)
  win = win or vim.api.nvim_get_current_win()
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local first, last = metadata_range(vim.api.nvim_win_get_buf(win))
  if not first or not last then
    return false
  end
  vim.api.nvim_win_call(win, function()
    if vim.fn.foldclosed(first) == -1 then
      vim.cmd(string.format("silent! %d,%dfold", first, last))
      vim.cmd(string.format("silent! %dfoldclose", first))
    else
      vim.cmd(string.format("silent! %dfoldopen", first))
    end
  end)
  return true
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
  for _, tag in ipairs(note.tags or {}) do
    ensure_tag_highlight(tag)
  end
  local abs_path = paths.join(state_mod.get().vault_dir, note.file)
  bufnr = bufnr or vim.fn.bufnr(abs_path, false)

  if bufnr and bufnr >= 0 and vim.api.nvim_buf_is_valid(bufnr) then
    local was_modified = vim.bo[bufnr].modified
    local first, last = metadata_range(bufnr)
    local generated = metadata_lines(note)
    local changed = false
    if first and last then
      local current = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
      if not vim.deep_equal(current, generated) then
        vim.api.nvim_buf_set_lines(bufnr, first - 1, last, false, generated)
        changed = true
      end
    else
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, with_metadata(lines, note))
      changed = true
    end

    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
      if vim.api.nvim_win_is_valid(win) then
        M.apply_metadata_fold(win, { reset = false, replace = changed })
      end
    end

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
        target_path = opts.target_path,
        target_type = opts.target_type,
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
      pinned = false,
    }

    local initial_lines = {}
    vim.list_extend(initial_lines, metadata_lines(note))
    table.insert(initial_lines, "")
    table.insert(initial_lines, "# " .. title)
    table.insert(initial_lines, "")
    vim.list_extend(initial_lines, template_lines(note, opts))
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
  M.apply_metadata_fold(win)
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
