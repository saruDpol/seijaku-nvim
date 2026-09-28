local M = {}

local active = nil
local color_ns = vim.api.nvim_create_namespace("seijaku_picker_colors")
local default_notebook_icon = "■"
local tag_icon = ""

local function display_width(value)
  return vim.fn.strdisplaywidth(value or "")
end

local function popup_width(lines, minimum)
  local width = minimum or 24
  for _, line in ipairs(lines) do
    width = math.max(width, display_width(line) + 2)
  end
  return math.min(width, math.max(1, vim.o.columns - 4))
end

local function truncate(text, width)
  if display_width(text) <= width then
    return text
  end
  local kept = ""
  for index = 0, vim.fn.strchars(text) - 1 do
    local char = vim.fn.strcharpart(text, index, 1)
    if display_width(kept .. char .. "…") > width then
      break
    end
    kept = kept .. char
  end
  return kept .. "…"
end

local function popup_config(width, height, title)
  return {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
    zindex = 60,
  }
end

local function close(picker)
  if not picker or picker.closed then
    return
  end
  picker.closed = true
  if picker.win and vim.api.nvim_win_is_valid(picker.win) then
    if vim.api.nvim_get_current_win() == picker.win then
      pcall(vim.cmd, "stopinsert")
    end
    pcall(vim.api.nvim_win_close, picker.win, true)
  end
  if picker.origin_win and vim.api.nvim_win_is_valid(picker.origin_win) then
    pcall(vim.api.nvim_set_current_win, picker.origin_win)
  end
  if active == picker then
    active = nil
  end
end

local function open(lines, title, width, height)
  if active then
    close(active)
  end
  vim.api.nvim_set_hl(0, "SeijakuPickerNormal", { bg = "NONE" })
  vim.api.nvim_set_hl(0, "SeijakuPickerCursor", { bg = "NONE", bold = true })
  local origin_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local win = vim.api.nvim_open_win(buf, true, popup_config(width, height, title))
  vim.wo[win].winhighlight =
    "Normal:SeijakuPickerNormal,FloatBorder:SeijakuBrand,FloatTitle:SeijakuBrand,CursorLine:SeijakuPickerCursor"
  local picker = { win = win, buf = buf, origin_win = origin_win, closed = false }
  active = picker
  return picker
end

local function color_group(color)
  if type(color) ~= "string" or not color:match("^#%x%x%x%x%x%x$") then
    return nil
  end
  local group = "SeijakuPickerColor_" .. color:sub(2)
  vim.api.nvim_set_hl(0, group, { fg = color, bg = "NONE" })
  return group
end

function M.select(items, opts, callback)
  opts = opts or {}
  if #items == 0 then
    callback(nil)
    return nil
  end
  local lines = {}
  for number, item in ipairs(items) do
    local number_label = number <= 9 and tostring(number) or "·"
    lines[number] = string.format("  %s  %s %s", number_label, item.icon or "·", item.label or item.value or "")
  end
  local width = popup_width(lines, opts.min_width or 26)
  for line, value in ipairs(lines) do
    lines[line] = truncate(value, width - 1)
  end
  local height = math.min(#lines, math.max(1, vim.o.lines - 4))
  local picker = open(lines, opts.title or " select ", width, height)
  vim.wo[picker.win].cursorline = true
  vim.bo[picker.buf].filetype = "seijaku-picker"
  if opts.initial_value ~= nil then
    for line, item in ipairs(items) do
      if item.value == opts.initial_value then
        vim.api.nvim_win_set_cursor(picker.win, { line, 0 })
        break
      end
    end
  end

  for line, item in ipairs(items) do
    local group = item.highlight or color_group(item.color)
    if group then
      vim.api.nvim_buf_set_extmark(picker.buf, color_ns, line - 1, 0, {
        end_col = #lines[line],
        hl_group = group,
        priority = 100,
      })
    end
  end

  local function choose(number)
    if picker.closed or not items[number] then
      return
    end
    local item = items[number]
    close(picker)
    vim.schedule(function()
      callback(item)
    end)
  end
  local function cancel()
    close(picker)
    vim.schedule(function()
      callback(nil)
    end)
  end
  local function move(direction)
    if picker.closed then
      return
    end
    local line = vim.api.nvim_win_get_cursor(picker.win)[1]
    vim.api.nvim_win_set_cursor(picker.win, { ((line - 1 + direction) % #items) + 1, 0 })
  end
  local map_opts = { buffer = picker.buf, silent = true, nowait = true }
  vim.keymap.set("n", "j", function() move(1) end, map_opts)
  vim.keymap.set("n", "k", function() move(-1) end, map_opts)
  vim.keymap.set("n", "<Down>", function() move(1) end, map_opts)
  vim.keymap.set("n", "<Up>", function() move(-1) end, map_opts)
  vim.keymap.set("n", "<CR>", function()
    choose(vim.api.nvim_win_get_cursor(picker.win)[1])
  end, map_opts)
  for number = 1, math.min(9, #items) do
    local selected = number
    vim.keymap.set("n", tostring(number), function() choose(selected) end, map_opts)
  end
  vim.keymap.set("n", "<Esc>", cancel, map_opts)
  vim.keymap.set("n", "q", cancel, map_opts)
  vim.keymap.set("n", "<C-c>", cancel, map_opts)
  return picker.win, picker.buf
end

function M.input(opts, callback)
  opts = opts or {}
  local default = tostring(opts.default or "")
  local width = popup_width({ default }, opts.min_width or 30)
  local picker = open({ default }, opts.title or " title ", width, 1)
  vim.wo[picker.win].cursorline = false
  vim.wo[picker.win].wrap = false
  vim.bo[picker.buf].modifiable = true
  vim.bo[picker.buf].filetype = "seijaku-picker-input"
  pcall(vim.api.nvim_win_set_cursor, picker.win, { 1, #default })

  local function finish(accepted)
    if picker.closed then
      return
    end
    local value = accepted and vim.trim(vim.api.nvim_buf_get_lines(picker.buf, 0, 1, false)[1] or "") or nil
    if accepted and value == "" and not opts.allow_empty then
      return
    end
    close(picker)
    vim.schedule(function()
      callback(value)
    end)
  end
  local map_opts = { buffer = picker.buf, silent = true, nowait = true }
  vim.keymap.set("i", "<CR>", function() finish(true) end, map_opts)
  vim.keymap.set("n", "<CR>", function() finish(true) end, map_opts)
  vim.keymap.set("i", "<Esc>", function() finish(false) end, map_opts)
  vim.keymap.set("n", "<Esc>", function() finish(false) end, map_opts)
  vim.keymap.set("i", "<C-c>", function() finish(false) end, map_opts)
  vim.cmd("startinsert!")
  return picker.win, picker.buf
end

-- A temporary filesystem navigator used by the note form's path field.  It
-- deliberately does not replace the active picker, so closing it returns to
-- the exact composer state the user left behind.
function M.browse_path(initial, callback)
  local origin = vim.api.nvim_get_current_win()
  local function normalize_directory(path)
    local normalized = vim.fn.fnamemodify(path, ":p")
    return normalized == "/" and normalized or normalized:gsub("/$", "")
  end

  local directory = normalize_directory(initial ~= "" and initial or vim.loop.cwd())
  if vim.fn.isdirectory(directory) == 0 then
    directory = normalize_directory(vim.fn.fnamemodify(directory, ":h"))
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "nofile", "wipe", false
  local width = math.min(70, math.max(38, vim.o.columns - 4))
  local win = vim.api.nvim_open_win(buf, true, popup_config(width, 3, " choose path "))
  vim.wo[win].cursorline = true
  vim.wo[win].winhighlight =
    "Normal:SeijakuPickerNormal,FloatBorder:SeijakuBrand,FloatTitle:SeijakuBrand,CursorLine:SeijakuPickerCursor"
  local entries = {}

  local function finish(value)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_win_is_valid(origin) then
      vim.api.nvim_set_current_win(origin)
    end
    callback(value)
  end

  local function render()
    local names = vim.fn.readdir(directory)
    table.sort(names, function(a, b)
      local a_dir = vim.fn.isdirectory(directory .. "/" .. a) == 1
      local b_dir = vim.fn.isdirectory(directory .. "/" .. b) == 1
      if a_dir ~= b_dir then
        return a_dir
      end
      return a < b
    end)
    entries = {
      { label = ".", path = directory, directory = true },
      { label = "..", path = vim.fn.fnamemodify(directory, ":h"), directory = true },
    }
    for _, name in ipairs(names) do
      local path = directory == "/" and ("/" .. name) or (directory .. "/" .. name)
      table.insert(entries, { label = name, path = path, directory = vim.fn.isdirectory(path) == 1 })
    end
    local lines = {}
    for line, entry in ipairs(entries) do
      lines[line] = "  " .. entry.label
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_win_set_config(win, popup_config(
      width,
      math.min(#lines, math.max(3, vim.o.lines - 6)),
      " path · h parent · l open dir · enter select · esc cancel "
    ))
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
  end

  local function select_current()
    local entry = entries[vim.api.nvim_win_get_cursor(win)[1]]
    if not entry then return end
    finish(entry.path)
  end

  local function enter_directory()
    local entry = entries[vim.api.nvim_win_get_cursor(win)[1]]
    if not entry or not entry.directory then return end
    directory = normalize_directory(entry.path)
    render()
  end
  local map_opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", select_current, map_opts)
  vim.keymap.set("n", "l", enter_directory, map_opts)
  vim.keymap.set("n", "h", function()
    directory = normalize_directory(vim.fn.fnamemodify(directory, ":h"))
    render()
  end, map_opts)
  vim.keymap.set("n", "<Esc>", function() finish(nil) end, map_opts)
  vim.keymap.set("n", "q", function() finish(nil) end, map_opts)
  render()
  return win, buf
end

-- A single-window note composer. Sub-views (single choice, tags and text
-- input) reuse the same floating buffer rather than opening a chain of
-- independent prompts.
function M.note_form(opts, callback)
  opts = opts or {}
  if active then
    close(active)
  end

  local values = {
    title = tostring(opts.title or ""),
    template_id = opts.template_id or "blank",
    notebook_id = opts.notebook_id or nil,
    target_path = opts.target_path or "",
    tags = vim.deepcopy(opts.tags or {}),
  }
  local width = math.min(math.max(opts.width or 48, 36), math.max(1, vim.o.columns - 4))
  local origin_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  local win = vim.api.nvim_open_win(buf, true, popup_config(width, 8, " new note "))
  vim.wo[win].cursorline = true
  vim.wo[win].winhighlight =
    "Normal:SeijakuPickerNormal,FloatBorder:SeijakuBrand,FloatTitle:SeijakuBrand,CursorLine:SeijakuPickerCursor"
  local form = { buf = buf, win = win, origin_win = origin_win, closed = false, view = "form" }
  active = form

  local function form_close(cancelled)
    if form.closed then
      return
    end
    close(form)
    if cancelled then
      vim.schedule(function()
        callback(nil)
      end)
    end
  end

  local function notebook_by_id(id)
    for _, notebook in ipairs(opts.notebooks or {}) do
      if notebook.id == id then
        return notebook
      end
    end
  end

  local function template_label(id)
    for _, template in ipairs(opts.templates or {}) do
      if template.value == id then
        return template.label or id
      end
    end
    return id or "blank"
  end

  local function select_notebook_template(notebook)
    if not notebook then
      return
    end
    local name = tostring(notebook.name or ""):lower():gsub("s$", "")
    if name == "" then
      return
    end
    for _, template in ipairs(opts.templates or {}) do
      local value = tostring(template.value or ""):lower():gsub("s$", "")
      local label = tostring(template.label or ""):lower():gsub("s$", "")
      if name == value or name == label then
        values.template_id = template.value
        return
      end
    end
  end

  local function set_lines(lines, title, cursor)
    if form.closed or not vim.api.nvim_win_is_valid(win) then
      return
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, color_ns, 0, -1)
    vim.api.nvim_win_set_config(win, popup_config(width, math.min(#lines, math.max(1, vim.o.lines - 4)), title))
    if cursor then
      pcall(vim.api.nvim_win_set_cursor, win, cursor)
    end
  end

  local render_form
  local cycle_notebook

  local function clear_mode_maps()
    local keys = { "j", "k", "<Down>", "<Up>", "<CR>", "<Esc>", "<C-c>", "q", "a" }
    for _, mode in ipairs({ "n", "i" }) do
      for _, key in ipairs(keys) do
        pcall(vim.keymap.del, mode, key, { buffer = buf })
      end
    end
  end

  local function map_form()
    clear_mode_maps()
    local map_opts = { buffer = buf, silent = true, nowait = true }
    local function move(direction)
      local line = vim.api.nvim_win_get_cursor(win)[1]
      local count = math.max(1, #vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      vim.api.nvim_win_set_cursor(win, { ((line - 1 + direction) % count) + 1, 0 })
    end
    vim.keymap.set("n", "j", function() move(1) end, map_opts)
    vim.keymap.set("n", "k", function() move(-1) end, map_opts)
    vim.keymap.set("n", "<Down>", function() move(1) end, map_opts)
    vim.keymap.set("n", "<Up>", function() move(-1) end, map_opts)
    vim.keymap.set("n", "<Esc>", function() form_close(true) end, map_opts)
    vim.keymap.set("n", "q", function() form_close(true) end, map_opts)
    vim.keymap.set("n", "<C-c>", function() form_close(true) end, map_opts)
	vim.keymap.set("n", "h", function()
		if vim.api.nvim_win_get_cursor(win)[1] == 3 then
			cycle_notebook(-1)
		end
	end, map_opts)
	vim.keymap.set("n", "l", function()
		if vim.api.nvim_win_get_cursor(win)[1] == 3 then
			cycle_notebook(1)
		end
	end, map_opts)
  end

  local function show_input(title, value, allow_empty, done)
    form.view = "input"
    clear_mode_maps()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { tostring(value or "") })
    vim.api.nvim_win_set_config(win, popup_config(width, 1, title))
    vim.wo[win].cursorline = false
    pcall(vim.api.nvim_win_set_cursor, win, { 1, #tostring(value or "") })
    local input_opts = { buffer = buf, silent = true, nowait = true }
    local function return_to_form()
      pcall(vim.cmd, "stopinsert")
      if vim.api.nvim_buf_is_valid(buf) then
        vim.bo[buf].modifiable = false
      end
      render_form()
    end
    local function submit()
      local result = vim.trim(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "")
      if result == "" and not allow_empty then
        return
      end
      pcall(vim.cmd, "stopinsert")
      vim.bo[buf].modifiable = false
      done(result)
    end
    vim.keymap.set("i", "<CR>", submit, input_opts)
    vim.keymap.set("n", "<CR>", submit, input_opts)
    vim.keymap.set("i", "<Esc>", return_to_form, input_opts)
    vim.keymap.set("n", "<Esc>", return_to_form, input_opts)
    vim.keymap.set("i", "<C-c>", return_to_form, input_opts)
    vim.cmd("startinsert!")
  end

  local function show_choices(kind, entries, selected, on_select)
    form.view = kind
    clear_mode_maps()
    local lines = {}
    for line, entry in ipairs(entries) do
      lines[line] = string.format("  %s %s", entry.icon or "·", entry.label or entry.value or "")
    end
    set_lines(lines, " " .. kind .. " ", { 1, 0 })
    vim.wo[win].cursorline = true
    for line, entry in ipairs(entries) do
      local group = entry.highlight or color_group(entry.color)
      if group then
        vim.api.nvim_buf_set_extmark(buf, color_ns, line - 1, 0, {
          end_col = #lines[line], hl_group = group, priority = 100,
        })
      end
      if entry.value == selected then
        pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
      end
    end
    local map_opts = { buffer = buf, silent = true, nowait = true }
    local function move(direction)
      local line = vim.api.nvim_win_get_cursor(win)[1]
      vim.api.nvim_win_set_cursor(win, { ((line - 1 + direction) % #entries) + 1, 0 })
    end
    vim.keymap.set("n", "j", function() move(1) end, map_opts)
    vim.keymap.set("n", "k", function() move(-1) end, map_opts)
    vim.keymap.set("n", "<Down>", function() move(1) end, map_opts)
    vim.keymap.set("n", "<Up>", function() move(-1) end, map_opts)
    vim.keymap.set("n", "<CR>", function()
      local entry = entries[vim.api.nvim_win_get_cursor(win)[1]]
      if entry then
        on_select(entry)
      end
    end, map_opts)
    vim.keymap.set("n", "<Esc>", render_form, map_opts)
    vim.keymap.set("n", "q", render_form, map_opts)
  end

  local function show_tags()
    local selected = {}
    for _, tag in ipairs(values.tags) do
      selected[tag] = true
    end
    local available = {}
    for _, tag in ipairs(opts.available_tags or {}) do
      available[tag] = true
    end
    for tag in pairs(selected) do
      available[tag] = true
    end
    local function sorted()
      local tags = vim.tbl_keys(available)
      table.sort(tags)
      return tags
    end
    local tags = sorted()
    local function render(preferred)
      clear_mode_maps()
      tags = sorted()
      local lines = {}
      if #tags == 0 then
        lines = { "  no tags · a add" }
      else
        for line, tag in ipairs(tags) do
          lines[line] = string.format("  %s %s", selected[tag] and tag_icon or " ", tag)
        end
      end
      set_lines(lines, " tags · enter toggle · a add ", { 1, 0 })
      vim.wo[win].cursorline = true
      for line, tag in ipairs(tags) do
        local color = opts.tag_color and opts.tag_color(tag) or nil
        if selected[tag] and color then
          vim.api.nvim_buf_set_extmark(buf, color_ns, line - 1, 0, {
            end_col = #lines[line], hl_group = color_group(color), priority = 100,
          })
        end
        if tag == preferred then
          pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
        end
      end
      local map_opts = { buffer = buf, silent = true, nowait = true }
      local function move(direction)
        local line = vim.api.nvim_win_get_cursor(win)[1]
        vim.api.nvim_win_set_cursor(win, { math.max(1, math.min(#lines, line + direction)), 0 })
      end
      vim.keymap.set("n", "j", function() move(1) end, map_opts)
      vim.keymap.set("n", "k", function() move(-1) end, map_opts)
      vim.keymap.set("n", "<Down>", function() move(1) end, map_opts)
      vim.keymap.set("n", "<Up>", function() move(-1) end, map_opts)
      vim.keymap.set("n", "<CR>", function()
        local tag = tags[vim.api.nvim_win_get_cursor(win)[1]]
        if tag then
          selected[tag] = not selected[tag] or nil
          render(tag)
        end
      end, map_opts)
      vim.keymap.set("n", "a", function()
        show_input(" new tag ", "", false, function(tag)
          tag = tag:lower()
          if tag:find("[`,%c]") then
            vim.notify("seijaku: invalid tag", vim.log.levels.WARN)
            render()
            return
          end
          available[tag], selected[tag] = true, true
          render(tag)
        end)
      end, map_opts)
      vim.keymap.set("n", "<Esc>", function()
        values.tags = vim.tbl_keys(selected)
        table.sort(values.tags)
        render_form()
      end, map_opts)
      vim.keymap.set("n", "q", function()
        values.tags = vim.tbl_keys(selected)
        table.sort(values.tags)
        render_form()
      end, map_opts)
    end
    form.view = "tags"
    render()
  end

  cycle_notebook = function(direction)
	local choices = { false }
	for _, notebook in ipairs(opts.notebooks or {}) do
		table.insert(choices, notebook.id)
	end
	local current = 1
	for line, value in ipairs(choices) do
		if value == (values.notebook_id or false) then
			current = line
			break
		end
	end
	values.notebook_id = choices[((current - 1 + direction) % #choices) + 1] or nil
	select_notebook_template(notebook_by_id(values.notebook_id))
	render_form()
	pcall(vim.api.nvim_win_set_cursor, win, { 3, 0 })
  end

  render_form = function()
    if form.closed then
      return
    end
    form.view = "form"
    local notebook = notebook_by_id(values.notebook_id)
    local tags = #values.tags > 0 and table.concat(values.tags, ", ") or "—"
    set_lines({
      "  title       " .. (values.title ~= "" and values.title or "—"),
      "  template    " .. template_label(values.template_id),
      "  notebook    " .. (notebook and ((notebook.icon or default_notebook_icon) .. " " .. notebook.name) or "—"),
      "  directory   " .. (values.target_path ~= "" and values.target_path or "—"),
      "  tags        " .. tags,
      "  create note",
    }, " new note · enter edit · esc cancel ", { 1, 0 })
    vim.wo[win].cursorline = true
    map_form()
    local map_opts = { buffer = buf, silent = true, nowait = true }
    vim.keymap.set("n", "<CR>", function()
      local line = vim.api.nvim_win_get_cursor(win)[1]
      if line == 1 then
        show_input(" note title ", values.title, false, function(value)
          values.title = value
          render_form()
        end)
      elseif line == 2 then
        show_choices("template", opts.templates or {}, values.template_id, function(entry)
          values.template_id = entry.value
          render_form()
        end)
      elseif line == 3 then
        local choices = { { value = false, label = "No notebook", icon = "·" } }
        for _, notebook_item in ipairs(opts.notebooks or {}) do
          table.insert(choices, { value = notebook_item.id, label = notebook_item.name, icon = notebook_item.icon or default_notebook_icon, color = notebook_item.color })
        end
        table.insert(choices, { value = "new", label = "New notebook", icon = "+" })
        show_choices("notebook", choices, values.notebook_id or false, function(entry)
          if entry.value ~= "new" then
            values.notebook_id = entry.value or nil
			select_notebook_template(notebook_by_id(values.notebook_id))
            render_form()
            return
          end
			show_input(" notebook name ", "", false, function(name)
				M.browse_path("", function(path)
					if path == nil then
						path = ""
					end
					show_input(" notebook icon · optional ", default_notebook_icon, true, function(icon)
						show_input(" notebook color · #RRGGBB · optional ", "", true, function(color)
							local notebook_item, err = opts.create_notebook(
								name,
								path ~= "" and path or nil,
								icon ~= "" and icon or nil,
								color ~= "" and color or nil
							)
							if not notebook_item then
								vim.notify("seijaku: " .. tostring(err), vim.log.levels.ERROR)
							else
								table.insert(opts.notebooks, notebook_item)
								values.notebook_id = notebook_item.id
								select_notebook_template(notebook_item)
							end
							render_form()
						end)
					end)
				end)
			end)
        end)
      elseif line == 4 then
        M.browse_path(values.target_path, function(path)
          if path then
            values.target_path = path
          end
          render_form()
        end)
      elseif line == 5 then
        show_tags()
      else
        if vim.trim(values.title) == "" then
          vim.notify("seijaku: title is required", vim.log.levels.WARN)
          return
        end
        form_close(false)
        vim.schedule(function()
          callback(values)
        end)
      end
    end, map_opts)
  end

  render_form()
  return win, buf
end

return M
