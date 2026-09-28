local M = {}

local state_mod = require("seijaku.state")
local index = require("seijaku.index")
local paths = require("seijaku.paths")
local util = require("seijaku.util")
local picker = require("seijaku.picker")
local calendar = require("seijaku.calendar")

local tag_selector_ns = vim.api.nvim_create_namespace("seijaku_tag_selector")
local active_tag_selector = nil
local tag_highlights = {}
local tag_glyph_highlights = {}
local tag_highlight_colors = {}
local default_notebook_icon = "■"
local tag_icon = ""

local function tag_display_icon(tag)
	return index.get_tag_icon(tag) or tag_icon
end

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

	return string.format("note_%s%s%s_%s_%s", parts.year, parts.month, parts.day, time, random)
end

function M.note_relative_path(note_id)
	local parts = util.date_parts()

	return paths.join("notes", parts.year, parts.month, parts.day, note_id .. ".md")
end

function M.select_tags(initial_tags, callback)
	if active_tag_selector and not active_tag_selector.closed then
		active_tag_selector.close()
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
		title = " tags · enter toggle · a add · r icon ",
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
				lines[line] = string.format("  %s %s", selected[tag] and tag_display_icon(tag) or " ", tag)
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
		local height = math.min(#lines, math.max(1, vim.o.lines - 4))
		vim.api.nvim_win_set_config(win, {
			relative = "editor",
			row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
			col = math.max(0, math.floor((vim.o.columns - width) / 2)),
			width = math.min(width, math.max(1, vim.o.columns - 4)),
			height = height,
			style = "minimal",
			border = "rounded",
			title = " tags · enter toggle · a add · r icon ",
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

	local function edit_icon()
		local tag = selector.tags[vim.api.nvim_win_get_cursor(win)[1]]
		if not tag then
			return
		end
		picker.input({
			title = " tag icon · optional ",
			default = tag_display_icon(tag),
			allow_empty = true,
		}, function(icon)
			if icon == nil then
				return
			end
			local ok, err = index.set_tag_icon(tag, icon ~= "" and icon or false)
			if not ok then
				vim.notify("seijaku: " .. tostring(err), vim.log.levels.ERROR)
				return
			end
			show_list(tag)
		end)
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
	vim.keymap.set("n", "r", edit_icon, opts)
	vim.keymap.set("n", "<CR>", toggle_current, opts)
	vim.keymap.set("n", "q", close, opts)
	vim.keymap.set("n", "<Esc>", finish, opts)
	vim.keymap.set("n", "<C-c>", close, opts)

	show_list()
	return win, buf
end

local function interpolate(text, values)
	return tostring(text or ""):gsub("{([%w_]+)}", function(key)
		return tostring(values[key] or "")
	end)
end

local function template_lines(note, opts)
	local templates = ((state_mod.get().config.notes or {}).templates or {})
	local template = templates[note.template_id or "blank"]
	local values = {
		title = note.title,
		template = note.template_id or "blank",
		notebook = note.notebook_id and (index.get_notebook(note.notebook_id) or {}).name or "",
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

-- Note attributes live exclusively in the index.  Older vaults may still
-- contain a generated metadata block; remove it once, never recreate it.
local legacy_metadata_start = "<!-- seijaku:metadata:start -->"
local legacy_metadata_end = "<!-- seijaku:metadata:end -->"

local function strip_legacy_metadata(lines)
	local first, last
	for line, text in ipairs(lines) do
		if text == legacy_metadata_start then
			first = line
		elseif first and text == legacy_metadata_end then
			last = line
			break
		end
	end
	if not first or not last then
		return lines, false
	end

	local cleaned = {}
	for line = 1, first - 1 do
		table.insert(cleaned, lines[line])
	end
	if lines[last + 1] == "" and cleaned[#cleaned] == "" then
		last = last + 1
	end
	for line = last + 1, #lines do
		table.insert(cleaned, lines[line])
	end
	return cleaned, true
end

function M.clean_legacy_metadata(note, bufnr, opts)
	if not note or not note.file then
		return false
	end
	opts = opts or {}
	local abs_path = paths.join(state_mod.get().vault_dir, note.file)
	bufnr = bufnr or vim.fn.bufnr(abs_path, false)

	if bufnr and bufnr >= 0 and vim.api.nvim_buf_is_valid(bufnr) then
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local cleaned, changed = strip_legacy_metadata(lines)
		if not changed then
			return true
		end
		local was_modified = vim.bo[bufnr].modified
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, cleaned)
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
	local cleaned, changed = strip_legacy_metadata(lines)
	if changed then
		util.write_file(abs_path, cleaned)
	end
	return true
end

local function template_choices()
	local templates = ((state_mod.get().config.notes or {}).templates or {})
	local keys = {}
	for key in pairs(templates) do
		if type(key) == "string" and key ~= "" and not key:find("[`%c]") then
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	local result = {}
	for _, key in ipairs(keys) do
		if key == "blank" then
			table.insert(result, 1, { value = key, label = "Blank", icon = "·" })
		else
			table.insert(result, { value = key, label = key:gsub("^%l", string.upper), icon = "◇" })
		end
	end
	return result
end

local function commit_note(opts, template_id, notebook_id, tags, title)
	title = vim.trim(tostring(title or ""))
	if title == "" or title:find("[%c]") then
		util.notify("note title must be a single non-empty line", vim.log.levels.ERROR)
		return nil
	end
	local state = state_mod.get()
	local templates = ((state.config.notes or {}).templates or {})
	if opts.calendar_date and not calendar.parse(opts.calendar_date) then
		util.notify("invalid calendar date: " .. tostring(opts.calendar_date), vim.log.levels.ERROR)
		return nil
	end
	if templates[template_id] == nil then
		util.notify("unknown template: " .. tostring(template_id), vim.log.levels.ERROR)
		return nil
	end
	if notebook_id and not index.get_notebook(notebook_id) then
		util.notify("notebook no longer exists: " .. tostring(notebook_id), vim.log.levels.ERROR)
		return nil
	end
	local normalized_tags, seen = {}, {}
	for _, value in ipairs(tags or {}) do
		local tag = vim.trim(tostring(value)):lower()
		if tag:find("[`,%c]") then
			util.notify("invalid tag: " .. tag, vim.log.levels.ERROR)
			return nil
		end
		if tag ~= "" and not seen[tag] then
			table.insert(normalized_tags, tag)
			seen[tag] = true
		end
	end
	table.sort(normalized_tags)

	local note_id, rel_path, abs_path
	repeat
		note_id = M.generate_id()
		rel_path = M.note_relative_path(note_id)
		abs_path = paths.join(state.vault_dir, rel_path)
	until not index.get_note(note_id) and vim.fn.filereadable(abs_path) == 0
	local now = util.now()
	local note = {
		id = note_id,
		title = title,
		file = rel_path,
		created_at = now,
		updated_at = now,
		template_id = template_id,
		notebook_id = notebook_id or nil,
		calendar_date = opts.calendar_date,
		targets = {},
		tags = normalized_tags,
		pinned = false,
	}
	local ok, body = pcall(template_lines, note, opts)
	if not ok then
		util.notify("template failed: " .. tostring(body), vim.log.levels.ERROR)
		return nil
	end
	local initial_lines = { "# " .. title, "" }
	vim.list_extend(initial_lines, body)
	util.write_file(abs_path, initial_lines)
	index.add_note(note, { defer_save = true })
	if opts.target_path then
		local attached, attach_err = index.attach(note_id, opts.target_path, opts.target_type, { defer_save = true })
		if not attached then
			util.notify("target association failed: " .. tostring(attach_err), vim.log.levels.WARN)
		end
	end
	local saved, save_err = index.save_sync()
	if not saved then
		util.notify("note saved to disk but index update failed: " .. tostring(save_err), vim.log.levels.ERROR)
		return nil
	end
	if opts.open ~= false then
		local sidebar_ok, sidebar = pcall(require, "seijaku.sidebar")
		local opened_in_sidebar = sidebar_ok and sidebar.open_preview(note_id, { force = true, focus = true, reopen = true })
		if not opened_in_sidebar then
			M.open(note_id)
		end
	end
	if opts.on_created then
		opts.on_created(note)
	end
	refresh_sidebar()
	return note
end

function M.create(opts)
	opts = opts or {}
	-- A note attached anywhere below a notebook's working directory belongs to
	-- that notebook by default.  An explicitly supplied notebook still wins.
	local inferred_notebook_id = nil
	if opts.notebook_id == nil and opts.target_path then
		local notebook = index.notebook_for_target_path(opts.target_path)
		inferred_notebook_id = notebook and notebook.id or nil
	end
	if opts.prompt == false then
		local notebook_id = opts.notebook_id ~= nil and opts.notebook_id or inferred_notebook_id
		return commit_note(opts, opts.template_id or "blank", notebook_id, opts.tags, opts.title)
	end
	return picker.note_form({
		title = opts.title,
		template_id = opts.template_id or "blank",
		notebook_id = opts.notebook_id ~= nil and opts.notebook_id or inferred_notebook_id,
		target_path = opts.target_path,
		tags = opts.tags,
		templates = template_choices(),
		notebooks = index.list_notebooks(),
		available_tags = index.list_tags(),
		tag_color = index.get_tag_color,
		create_notebook = function(name, path, icon, color)
			return index.create_notebook({ name = name, path = path, icon = icon, color = color })
		end,
	}, function(values)
		if not values then
			return
		end
		local request = vim.deepcopy(opts)
		request.title = values.title
		request.template_id = values.template_id
		request.notebook_id = values.notebook_id
		request.tags = values.tags
		request.target_path = values.target_path ~= "" and paths.normalize(values.target_path) or nil
		if values.target_path ~= "" and not request.target_path then
			util.notify("invalid target path: " .. tostring(values.target_path), vim.log.levels.ERROR)
			return
		end
		request.target_type = request.target_path and paths.target_type(request.target_path) or nil
		-- Keep the automatic choice in sync if the target was picked or changed
		-- inside the composer. A manual notebook selection always takes priority.
		if opts.notebook_id == nil and values.notebook_id == inferred_notebook_id and request.target_path then
			local notebook = index.notebook_for_target_path(request.target_path)
			request.notebook_id = notebook and notebook.id or nil
		end
		commit_note(request, request.template_id, request.notebook_id, request.tags, request.title)
	end)
end

function M.create_global()
	return M.create({})
end

function M.create_for_target(target_path, target_type)
	return M.create({ target_path = target_path, target_type = target_type })
end

function M.create_for_path(target_path)
	local normalized = paths.normalize(target_path)

	if not normalized then
		util.notify("invalid path: " .. tostring(target_path), vim.log.levels.ERROR)
		return
	end

	return M.create_for_target(normalized, paths.target_type(normalized))
end

function M.manage_notebooks()
	local choices = {}
	for _, notebook in ipairs(index.list_notebooks()) do
		table.insert(choices, {
			value = notebook.id,
			label = notebook.name .. (notebook.path and ("  " .. notebook.path) or ""),
			icon = notebook.icon or default_notebook_icon,
			color = notebook.color,
		})
	end
	table.insert(choices, { value = "new", label = "New notebook", icon = "+" })

	return picker.select(choices, { title = " notebooks " }, function(choice)
		if not choice then
			return
		end
		if choice.value == "new" then
			picker.input({ title = " notebook name " }, function(name)
				if not name then
					return
				end
				picker.browse_path("", function(path)
					if path == nil then
						return
					end
					picker.input({ title = " notebook icon · optional ", default = default_notebook_icon, allow_empty = true }, function(icon)
						if icon == nil then
							return
						end
						picker.input({ title = " notebook color · #RRGGBB · optional ", allow_empty = true }, function(color)
							if color == nil then
								return
							end
							local notebook, err = index.create_notebook({
								name = name,
								path = path ~= "" and path or nil,
								icon = icon ~= "" and icon or nil,
								color = color ~= "" and color or nil,
							})
							if not notebook then
								util.notify("notebook: " .. tostring(err), vim.log.levels.ERROR)
								return
							end
							refresh_sidebar()
						end)
					end)
				end)
			end)
			return
		end

		local notebook = index.get_notebook(choice.value)
		if not notebook then
			return
		end
		picker.select({
			{ value = "open", label = "Open working directory", icon = "↗" },
			{ value = "edit", label = "Edit name and directory", icon = "◇" },
			{ value = "delete", label = "Delete notebook", icon = "×" },
		}, { title = " " .. notebook.name .. " " }, function(action)
			if not action then
				return
			end
			if action.value == "open" then
				if not notebook.path then
					util.notify("notebook has no working directory", vim.log.levels.INFO)
					return
				end
				local ok, oil = pcall(require, "oil")
				if not ok then
					util.notify("oil.nvim is not available", vim.log.levels.WARN)
					return
				end
				local opened, err = pcall(oil.open, notebook.path)
				if not opened then
					util.notify("failed to open notebook directory: " .. tostring(err), vim.log.levels.ERROR)
				end
			elseif action.value == "edit" then
				picker.input({ title = " notebook name ", default = notebook.name }, function(name)
					if not name then
						return
					end
					picker.browse_path(notebook.path or "", function(path)
						if path == nil then
							return
						end
						picker.input({
							title = " notebook icon · optional ",
							default = notebook.icon or "",
							allow_empty = true,
						}, function(icon)
							if icon == nil then
								return
							end
							picker.input({ title = " notebook color · #RRGGBB ", default = notebook.color or "" }, function(color)
								if not color then
									return
								end
								local ok, err = index.update_notebook(notebook.id, {
									name = name,
									path = path ~= "" and path or false,
									icon = icon ~= "" and icon or false,
									color = color,
								})
								if not ok then
									util.notify("notebook: " .. tostring(err), vim.log.levels.ERROR)
									return
								end
								refresh_sidebar()
							end)
						end)
					end)
				end)
			elseif action.value == "delete" then
				if
					vim.fn.confirm(
						"Delete notebook '" .. notebook.name .. "'? Notes stay intact.",
						"&Delete\n&Cancel",
						2
					) ~= 1
				then
					return
				end
				local ok, err = index.delete_notebook(notebook.id)
				if not ok then
					util.notify("notebook: " .. tostring(err), vim.log.levels.ERROR)
					return
				end
				refresh_sidebar()
			end
		end)
	end)
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
	M.clean_legacy_metadata(note)
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
