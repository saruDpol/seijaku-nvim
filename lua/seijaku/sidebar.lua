local M = {}

local state_mod = require("seijaku.state")
local index = require("seijaku.index")
local notes = require("seijaku.notes")
local todos = require("seijaku.todos")
local context = require("seijaku.context")
local paths = require("seijaku.paths")
local calendar = require("seijaku.calendar")

local refresh_timer = nil
local highlight_ns = vim.api.nvim_create_namespace("seijaku_sidebar")

local note_type_groups = {
	general = "SeijakuNoteGeneral",
	diary = "SeijakuNoteDiary",
	meeting = "SeijakuNoteMeeting",
	desc = "SeijakuNoteDescription",
}

local note_type_icons = {
	general = "·",
	diary = "◷",
	meeting = "○",
	desc = "≡",
}

local function note_type(note)
	local value = note and note.note_type or "general"
	return note_type_groups[value] and value or "general"
end

local function sidebar_state()
	return state_mod.get().sidebar
end

local function is_valid_win(win)
	return win and vim.api.nvim_win_is_valid(win)
end

local function is_valid_buf(buf)
	return buf and vim.api.nvim_buf_is_valid(buf)
end

local function normal_windows_in_current_tab()
	local result = {}

	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if is_valid_win(win) and vim.api.nvim_win_get_config(win).relative == "" then
			table.insert(result, win)
		end
	end

	return result
end

local function selected_item()
	local sidebar = sidebar_state()

	if not is_valid_win(sidebar.win) then
		return nil
	end

	local line = vim.api.nvim_win_get_cursor(sidebar.win)[1]
	return sidebar.line_items[line]
end

local function selected_calendar_note_item()
	local sidebar = sidebar_state()

	if not is_valid_win(sidebar.calendar_notes_win) then
		return nil
	end

	local line = vim.api.nvim_win_get_cursor(sidebar.calendar_notes_win)[1]
	return sidebar.calendar_notes_items[line]
end

local function set_sidebar_options(buf)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "seijaku"
	vim.bo[buf].modifiable = false
end

local function with_modifiable(buf, callback)
	vim.bo[buf].modifiable = true
	callback()
	vim.bo[buf].modifiable = false
end

local function sidebar_width()
	local sidebar = sidebar_state()

	if is_valid_win(sidebar.win) then
		return vim.api.nvim_win_get_width(sidebar.win)
	end

	local configured = state_mod.get().config.sidebar.width
	if type(configured) == "number" then
		return configured
	end

	return math.max(1, math.floor(vim.o.columns / 3))
end

local function display_width(text)
	return vim.fn.strdisplaywidth(text or "")
end

local function center(text, width)
	text = text or ""
	width = width or sidebar_width()

	local padding = math.max(0, math.floor((width - display_width(text)) / 2))
	return string.rep(" ", padding) .. text
end

local function truncate_left(text, width)
	text = tostring(text or "")
	width = width or sidebar_width()

	if display_width(text) <= width then
		return text
	end

	local marker = "..."
	local available = math.max(1, width - display_width(marker))
	local result = text

	while result ~= "" and display_width(result) > available do
		result = vim.fn.strcharpart(result, 1)
	end

	return marker .. result
end

local function truncate_right(text, width)
	text = tostring(text or "")
	if display_width(text) <= width then
		return text
	end

	local marker = "..."
	local available = math.max(1, width - display_width(marker))
	local result = text
	while result ~= "" and display_width(result) > available do
		result = vim.fn.strcharpart(result, 0, vim.fn.strchars(result) - 1)
	end

	return result .. marker
end

local function compact_path(path, width)
	path = tostring(path or "")

	if path == "" then
		return ""
	end

	local cwd = state_mod.get().root_dir or paths.normalize(vim.loop.cwd())
	local normalized = paths.normalize(path)

	if cwd and normalized and paths.inside_dir(normalized, cwd) then
		if normalized == cwd then
			path = "."
		else
			path = normalized:sub(#cwd + 2)
		end
	end

	return truncate_left(path, width)
end

local function project_path(path, width)
	path = tostring(path or "")

	if path == "" then
		return ""
	end

	local root = state_mod.get().root_dir or paths.normalize(vim.loop.cwd())
	local normalized = paths.normalize(path)

	if root and normalized and paths.inside_dir(normalized, root) then
		local root_name = paths.basename(root)

		if normalized == root then
			return truncate_left(root_name, width)
		end

		return truncate_left(root_name .. "/" .. normalized:sub(#root + 2), width)
	end

	return compact_path(path, width)
end

local function target_name(target_path)
	local basename = paths.basename(target_path)
	local target_type = paths.target_type(target_path)

	if basename == "" then
		basename = compact_path(target_path, math.max(8, sidebar_width() - 2))
	end

	return basename
end

local function add_header(lines, line_items, title)
	local start = #lines + 1
	local width = sidebar_width()
	local rule = string.rep("─", width)
	local left = "静寂"
	local mode = sidebar_state().mode
	local right = "seijaku"
	if mode == "all" then
		right = string.format("sort %s | filter %s", sidebar_state().all_sort, sidebar_state().all_filter)
	elseif mode == "todo" then
		right = "filter " .. tostring(sidebar_state().todo_filter or "all")
	elseif mode == "calendar" then
		right = "[/] month  t today"
	end
	right = truncate_right(right, math.max(8, width - display_width(left) - 1))
	local gap = math.max(1, width - display_width(left) - display_width(right))
	local mode_labels = {
		mode == "all" and sidebar_state().all_sort or "all",
		mode == "directory" and tostring(title or ".") or "dir",
		"todo",
		"cal",
	}
	local active_index = mode == "all" and 1 or mode == "directory" and 2 or mode == "todo" and 3 or 4
	local inactive_width = 0
	for index_in_list, label in ipairs(mode_labels) do
		if index_in_list ~= active_index then
			inactive_width = inactive_width + display_width(label)
		end
	end
	local available_active = math.max(3, width - inactive_width - (#mode_labels - 1))
	mode_labels[active_index] = truncate_left(mode_labels[active_index], available_active)
	local labels_width = 0
	for _, label in ipairs(mode_labels) do
		labels_width = labels_width + display_width(label)
	end
	local mode_space = math.max(#mode_labels - 1, width - labels_width)
	local base_gap = math.floor(mode_space / (#mode_labels - 1))
	local extra = mode_space % (#mode_labels - 1)
	local parts = {}
	local active_start = 0
	local byte_length = 0
	for index_in_list, label in ipairs(mode_labels) do
		if index_in_list == active_index then
			active_start = byte_length
		end
		table.insert(parts, label)
		byte_length = byte_length + #label
		if index_in_list < #mode_labels then
			local gap = base_gap + (index_in_list <= extra and 1 or 0)
			table.insert(parts, string.rep(" ", gap))
			byte_length = byte_length + gap
		end
	end
	local mode_text = table.concat(parts)

	table.insert(lines, left .. string.rep(" ", gap) .. right)
	table.insert(lines, rule)
	table.insert(lines, mode_text)
	table.insert(lines, "")

	line_items[start] = {
		kind = "header",
		brand_start = #left + gap,
		brand_end = #left + gap + #right,
	}
	line_items[start + 1] = { kind = "rule" }
	line_items[start + 2] = {
		kind = "modes",
		active_start = active_start,
		active_end = active_start + #mode_labels[active_index],
	}
	line_items[#lines] = { kind = "spacer" }
end

local function apply_highlights(buf, lines, line_items)
	local sidebar = sidebar_state()
	buf = buf or sidebar.buf
	lines = lines or sidebar.lines
	line_items = line_items or sidebar.line_items

	if not is_valid_buf(buf) then
		return
	end

	vim.api.nvim_buf_clear_namespace(buf, highlight_ns, 0, -1)
	vim.api.nvim_set_hl(0, "SeijakuHeader", { bold = true })
	vim.api.nvim_set_hl(0, "SeijakuBrand", { fg = "#769267", ctermfg = 108, bold = false })
	vim.api.nvim_set_hl(0, "SeijakuModeActive", { fg = "#9f3434", ctermfg = 217, bold = true })
	vim.api.nvim_set_hl(0, "SeijakuSubheader", { link = "Comment" })
	vim.api.nvim_set_hl(0, "SeijakuHelp", { link = "Comment" })
	vim.api.nvim_set_hl(0, "SeijakuSection", { link = "Title" })
	vim.api.nvim_set_hl(0, "SeijakuTarget", { link = "Comment" })
	vim.api.nvim_set_hl(0, "SeijakuMissingTarget", { link = "DiagnosticWarn" })
	vim.api.nvim_set_hl(0, "SeijakuNote", { link = "Function" })
	vim.api.nvim_set_hl(0, "SeijakuNoteGeneral", { fg = "#286b8c", ctermfg = 24 })
	vim.api.nvim_set_hl(0, "SeijakuNoteDiary", { fg = "#a67c00", ctermfg = 136 })
	vim.api.nvim_set_hl(0, "SeijakuNoteMeeting", { fg = "#b44a1d", ctermfg = 130 })
	vim.api.nvim_set_hl(0, "SeijakuNoteDescription", { fg = "#527f45", ctermfg = 65 })
	vim.api.nvim_set_hl(0, "SeijakuCalendarMonth", { fg = "#769267", ctermfg = 108 })
	vim.api.nvim_set_hl(0, "SeijakuCalendarToday", { link = "DiagnosticInfo" })
	vim.api.nvim_set_hl(0, "SeijakuCalendarSelected", { fg = "#9f3434", ctermfg = 217, bold = true })
	vim.api.nvim_set_hl(0, "SeijakuCalendarHasNotes", { link = "Function" })
	vim.api.nvim_set_hl(0, "SeijakuTodoOpen", { fg = "#c05f7e", ctermfg = 168 })
	vim.api.nvim_set_hl(0, "SeijakuTodoClosed", { fg = "#66645f", ctermfg = 242 })
	vim.api.nvim_set_hl(0, "SeijakuTodoStrike", { fg = "#66645f", ctermfg = 242, strikethrough = true })
	vim.api.nvim_set_hl(0, "SeijakuDateToday", {
		fg = "#9f3434",
		ctermfg = 203,
		bold = false,
	})

	local highlight_by_kind = {
		subheader = "SeijakuSubheader",
		rule = "SeijakuHelp",
		help = "SeijakuHelp",
		section = "SeijakuSection",
		target = "SeijakuTarget",
		folder = "SeijakuTarget",
		date = "SeijakuTarget",
		calendar_month = "SeijakuCalendarMonth",
		calendar_weekdays = "SeijakuSubheader",
	}

	for line, item in pairs(line_items or {}) do
		local group = item and highlight_by_kind[item.kind]

		if item and item.kind == "date" and item.is_today then
			group = "SeijakuDateToday"
		end

		if item and item.missing_target then
			group = "SeijakuMissingTarget"
		end

		if group then
			vim.api.nvim_buf_set_extmark(buf, highlight_ns, line - 1, 0, {
				line_hl_group = group,
				priority = 100,
			})
		end

		if item and (item.kind == "modes" or item.kind == "submodes") then
			vim.api.nvim_buf_set_extmark(buf, highlight_ns, line - 1, 0, {
				end_col = #lines[line],
				hl_group = "SeijakuSubheader",
				hl_mode = "replace",
				priority = 100,
			})
			vim.api.nvim_buf_set_extmark(buf, highlight_ns, line - 1, item.active_start, {
				end_col = item.active_end,
				hl_group = "SeijakuModeActive",
				hl_mode = "replace",
				priority = 110,
			})
		end

		if item and item.kind == "header" then
			vim.api.nvim_buf_set_extmark(buf, highlight_ns, line - 1, 0, {
				end_col = #lines[line],
				hl_group = "SeijakuHeader",
				hl_mode = "replace",
				priority = 100,
			})
			vim.api.nvim_buf_set_extmark(buf, highlight_ns, line - 1, item.brand_start, {
				end_col = item.brand_end,
				hl_group = "SeijakuBrand",
				hl_mode = "replace",
				priority = 110,
			})
		end

		if item and item.kind == "note" then
			vim.api.nvim_buf_set_extmark(buf, highlight_ns, line - 1, 0, {
				end_col = #lines[line],
				hl_group = note_type_groups[item.note_type] or note_type_groups.general,
				hl_mode = "replace",
				priority = 100,
			})
		end

		if item and item.kind == "todo" then
			vim.api.nvim_buf_set_extmark(buf, highlight_ns, line - 1, 0, {
				end_col = #lines[line],
				hl_group = item.completed and "SeijakuTodoClosed" or "SeijakuTodoOpen",
				hl_mode = "replace",
				priority = 100,
			})
			if item.completed and item.text_end and item.text_end > 0 then
				vim.api.nvim_buf_set_extmark(buf, highlight_ns, line - 1, 0, {
					end_col = item.text_end,
					hl_group = "SeijakuTodoStrike",
					hl_mode = "replace",
					priority = 110,
				})
			end
		end

		if item and item.kind == "note" and item.target_start then
			vim.api.nvim_buf_set_extmark(buf, highlight_ns, line - 1, item.target_start, {
				end_col = item.target_end,
				hl_group = item.missing_target and "SeijakuMissingTarget" or "SeijakuTarget",
				hl_mode = "replace",
				priority = 110,
			})
		end

		if item and item.kind == "calendar_week" then
			local today = calendar.today()
			local today_key = calendar.format(today.year, today.month, today.day)

			for _, cell in ipairs(item.cells or {}) do
				local group_name = cell.has_notes and "SeijakuCalendarHasNotes" or nil
				if cell.date == today_key then
					group_name = "SeijakuCalendarToday"
				end
				if cell.date == sidebar.calendar_date then
					group_name = "SeijakuCalendarSelected"
				end

				if group_name then
					vim.api.nvim_buf_set_extmark(buf, highlight_ns, line - 1, cell.start_col, {
						end_col = cell.end_col,
						hl_group = group_name,
						hl_mode = "replace",
						priority = cell.date == sidebar.calendar_date and 130 or 120,
					})
				end
			end
		end
	end
end

local function note_line(note)
	local title = note.title or note.id
	local target_count = #(note.targets or {})
	local icon = note_type_icons[note_type(note)]

	if target_count > 0 then
		return string.format("%s %s [%d]", icon, title, target_count)
	end

	return icon .. " " .. title
end

local function all_note_line(note)
	local width = sidebar_width()
	local left = "   " .. note_type_icons[note_type(note)] .. " " .. tostring(note.title or note.id)
	local first_target = note.targets and note.targets[1]

	if not first_target or not first_target.path then
		return truncate_right(left, width)
	end

	local right = paths.basename(first_target.path)
	local missing_target = not paths.exists(first_target.path)
	if missing_target then
		right = "! " .. right
	end
	right = truncate_left(right, math.max(8, width - 18))
	local left_width = math.max(12, width - display_width(right) - 1)
	left = truncate_right(left, left_width)
	local gap = math.max(1, width - display_width(left) - display_width(right))
	local line = left .. string.rep(" ", gap) .. right
	local target_start = #left + gap

	return line, target_start, target_start + #right, missing_target
end

local function path_icon(target_path, target_type)
	if target_type == "directory" then
		return "󰉋 "
	end

	local ok, devicons = pcall(require, "nvim-web-devicons")
	if ok then
		local name = paths.basename(target_path)
		local extension = vim.fn.fnamemodify(name, ":e")
		local icon = devicons.get_icon(name, extension, { default = true })
		if icon then
			return icon
		end
	end

	return "󰈔 "
end

local function target_label(target_path)
	local target_type = paths.target_type(target_path)
	local width = math.max(8, sidebar_width() - 2)
	local label = truncate_left(target_name(target_path), width)
	local missing = not paths.exists(target_path)

	if missing then
		return "! " .. label, true
	end
	return path_icon(target_path, target_type) .. " " .. label, false
end

function M.render_all()
	local state = state_mod.get()
	local limit = state.config.sidebar.all_mode_limit or 500
	local all_notes = index.list_notes()
	local has_any_notes = #all_notes > 0
	local lines = {}
	local line_items = {}

	local today = calendar.today()
	local today_key = calendar.format(today.year, today.month, today.day)

	local filter = note_type_groups[sidebar_state().all_filter] and sidebar_state().all_filter or "all"
	sidebar_state().all_filter = filter
	add_header(lines, line_items, "すべて")

	if filter ~= "all" then
		all_notes = vim.tbl_filter(function(note)
			return note_type(note) == filter
		end, all_notes)
	end

	if sidebar_state().all_sort == "date" then
		table.sort(all_notes, function(a, b)
			local a_date = tostring(index.calendar_date(a) or "")
			local b_date = tostring(index.calendar_date(b) or "")
			if a_date == b_date then
				return tostring(a.updated_at or "") > tostring(b.updated_at or "")
			end
			return a_date > b_date
		end)
	elseif sidebar_state().all_sort == "created" then
		table.sort(all_notes, function(a, b)
			return tostring(a.created_at or "") > tostring(b.created_at or "")
		end)
	end

	if #all_notes == 0 then
		table.insert(lines, has_any_notes and "No notes for this filter" or "No notes yet")
	else
		local current_date = nil
		for i, note in ipairs(all_notes) do
			if i > limit then
				table.insert(lines, "")
				table.insert(lines, string.format("Showing %d of %d notes", limit, #all_notes))
				break
			end

			if sidebar_state().all_sort == "date" or sidebar_state().all_sort == "created" then
				local note_date
				if sidebar_state().all_sort == "date" then
					note_date = index.calendar_date(note)
				else
					note_date = tostring(note.created_at or ""):match("^%d%d%d%d%-%d%d%-%d%d")
				end
				note_date = note_date or "Unknown date"
				if note_date ~= current_date then
					current_date = note_date
					table.insert(lines, " " .. note_date)
					line_items[#lines] = {
						kind = "date",
						is_today = note_date == today_key,
					}
				end
			end

			local line, target_start, target_end, missing_target = all_note_line(note)
			table.insert(lines, line)
			line_items[#lines] = {
				kind = "note",
				note_id = note.id,
				note_type = note_type(note),
				target_start = target_start,
				target_end = target_end,
				missing_target = missing_target,
			}
		end
	end

	return lines, line_items
end

local function split_word_by_width(word, width)
	local chunks = {}
	local current = ""
	for char_index = 0, vim.fn.strchars(word) - 1 do
		local char = vim.fn.strcharpart(word, char_index, 1)
		if current ~= "" and display_width(current .. char) > width then
			table.insert(chunks, current)
			current = char
		else
			current = current .. char
		end
	end
	if current ~= "" then
		table.insert(chunks, current)
	end
	return chunks
end

local function wrap_text(text, width)
	width = math.max(1, width)
	local result = {}
	local current = ""
	for word in tostring(text or ""):gmatch("%S+") do
		local pieces = display_width(word) > width and split_word_by_width(word, width) or { word }
		for _, piece in ipairs(pieces) do
			local candidate = current == "" and piece or (current .. " " .. piece)
			if current ~= "" and display_width(candidate) > width then
				table.insert(result, current)
				current = piece
			else
				current = candidate
			end
		end
	end
	if current ~= "" then
		table.insert(result, current)
	end
	return #result > 0 and result or { "" }
end

local function todo_lines(todo)
	local width = sidebar_width()
	local timestamp = todo.completed_at or todo.created_at
	local date = tostring(timestamp or ""):match("^(%d%d%d%d%-%d%d%-%d%d)") or "unknown"
	local metadata = (todo.completed_at and "closed " or "created ") .. date
	local icon = todo.completed_at and "■" or "□"
	local prefix = "   " .. icon .. " "
	local indent = string.rep(" ", display_width(prefix))
	local chunks = wrap_text(todo.text, math.max(1, width - display_width(prefix)))
	local result = {}

	for chunk_index, chunk in ipairs(chunks) do
		local base = (chunk_index == 1 and prefix or indent) .. chunk
		table.insert(result, {
			text = base,
			text_end = #base,
		})
	end

	local last = result[#result]
	local gap = width - display_width(last.text) - display_width(metadata)
	if gap >= 1 then
		last.text = last.text .. string.rep(" ", gap) .. metadata
	else
		table.insert(result, {
			text = string.rep(" ", math.max(0, width - display_width(metadata))) .. metadata,
			text_end = nil,
		})
	end

	return result
end

function M.render_todos()
	local lines = {}
	local line_items = {}
	local all_todos = index.list_todos()
	local filter = sidebar_state().todo_filter
	if filter ~= "open" and filter ~= "closed" then
		filter = "all"
	end
	sidebar_state().todo_filter = filter
	if filter ~= "all" then
		all_todos = vim.tbl_filter(function(todo)
			return filter == "closed" and todo.completed_at ~= nil or filter == "open" and todo.completed_at == nil
		end, all_todos)
	end
	local current_date = nil

	add_header(lines, line_items, "todo")
	if #all_todos == 0 then
		table.insert(lines, filter == "all" and "No todos yet" or ("No " .. filter .. " todos"))
		line_items[#lines] = { kind = "help" }
		return lines, line_items
	end

	for _, todo in ipairs(all_todos) do
		local date = index.todo_date(todo) or "Unknown date"
		if date ~= current_date then
			current_date = date
			table.insert(lines, " " .. date)
			line_items[#lines] = { kind = "date" }
		end
		for _, rendered in ipairs(todo_lines(todo)) do
			table.insert(lines, rendered.text)
			line_items[#lines] = {
				kind = "todo",
				todo_id = todo.id,
				completed = todo.completed_at ~= nil,
				text_end = rendered.text_end,
			}
		end
	end

	return lines, line_items
end

function M.render_directory()
	local sidebar = sidebar_state()
	local ctx = context.get_current()
	local dir = ctx and ctx.directory or nil
	local current_target = ctx and ctx.target_path or nil
	local current_type = ctx and ctx.target_type or nil
	local line_items = {}
	local lines = {}

	sidebar.current_dir = dir
	sidebar.current_target = current_target

	add_header(lines, line_items, current_target and project_path(current_target, sidebar_width()) or "いま")

	if not current_target then
		table.insert(lines, "No current target")
		return lines, line_items
	end

	local target_paths = {}

	if current_type == "directory" then
		local grouped = index.get_notes_for_tree(current_target)
		for target_path, _ in pairs(grouped) do
			table.insert(target_paths, target_path)
		end
	else
		target_paths = { current_target }
	end

	if #target_paths == 0 then
		table.insert(lines, current_type == "file" and "No notes for this file" or "No notes for this directory")
		return lines, line_items
	end

	table.sort(target_paths)

	local shown = 0
	local function append_target(target_path, depth)
		local target_notes = index.get_notes_for_target(target_path)

		if #target_notes > 0 then
			local target_indent = " " .. string.rep("  ", depth)

			shown = shown + 1
			local label, missing_target = target_label(target_path)
			table.insert(lines, target_indent .. label)
			line_items[#lines] = {
				kind = "target",
				target_path = target_path,
				missing_target = missing_target,
			}

			table.sort(target_notes, function(a, b)
				return tostring(a.updated_at or "") > tostring(b.updated_at or "")
			end)

			for _, note in ipairs(target_notes) do
				table.insert(lines, target_indent .. "  " .. note_line(note))
				line_items[#lines] = {
					kind = "note",
					note_id = note.id,
					note_type = note_type(note),
					target_path = target_path,
				}
			end
		end
	end

	if current_type ~= "directory" then
		append_target(current_target, 0)
	else
		local tree = { children = {}, target_path = nil }

		for _, target_path in ipairs(target_paths) do
			local relative = paths.relative_to(current_target, target_path) or ""

			if relative == "" then
				tree.target_path = target_path
			else
				local node = tree
				local current_path = current_target

				for _, part in ipairs(vim.split(relative, "/", { plain = true, trimempty = true })) do
					current_path = paths.join(current_path, part)
					node.children[part] = node.children[part]
						or {
							children = {},
							path = current_path,
							target_path = nil,
						}
					node = node.children[part]
				end

				node.target_path = target_path
			end
		end

		local function append_notes(target_path, indent)
			local target_notes = index.get_notes_for_target(target_path)
			table.sort(target_notes, function(a, b)
				return tostring(a.updated_at or "") > tostring(b.updated_at or "")
			end)

			for _, note in ipairs(target_notes) do
				table.insert(lines, indent .. note_line(note))
				line_items[#lines] = {
					kind = "note",
					note_id = note.id,
					note_type = note_type(note),
					target_path = target_path,
				}
			end
		end

		if tree.target_path then
			shown = shown + 1
			append_notes(tree.target_path, " ")
		end

		local function render_nodes(node, depth)
			local names = vim.tbl_keys(node.children)
			table.sort(names)

			for _, name in ipairs(names) do
				local child = node.children[name]
				local indent = " " .. string.rep("  ", depth)
				local label, missing_target = target_label(child.path)
				table.insert(lines, indent .. label)
				line_items[#lines] = {
					kind = child.target_path and "target" or "folder",
					target_path = child.target_path,
					missing_target = missing_target,
				}

				if child.target_path then
					shown = shown + 1
					append_notes(child.target_path, indent .. "  ")
				end

				render_nodes(child, depth + 1)
			end
		end

		render_nodes(tree, 0)
	end

	if shown == 0 then
		table.insert(lines, current_type == "directory" and "No notes for this directory" or "No notes for this file")
	end

	return lines, line_items
end

local function calendar_cell(label, width)
	label = tostring(label or "")
	local remaining = math.max(0, width - display_width(label))
	local left = math.floor(remaining / 2)
	return string.rep(" ", left) .. label .. string.rep(" ", remaining - left)
end

local function close_preview_window()
	local sidebar = sidebar_state()

	if is_valid_win(sidebar.preview_win) then
		vim.api.nvim_win_close(sidebar.preview_win, true)
	end
	if sidebar.preview_buf then
		sidebar.note_bufs[sidebar.preview_buf] = nil
	end

	sidebar.preview_win = nil
	sidebar.preview_buf = nil
	sidebar.preview_note_id = nil
end

local function managed_note_windows()
	local sidebar = sidebar_state()
	local result = {}
	local seen = {}

	local function add(win)
		if is_valid_win(win) and not seen[win] then
			seen[win] = true
			table.insert(result, win)
		end
	end

	add(sidebar.win)
	add(sidebar.preview_win)
	for _, win in ipairs(sidebar.note_wins or {}) do
		add(win)
	end

	table.sort(result, function(a, b)
		return vim.api.nvim_win_get_position(a)[1] < vim.api.nvim_win_get_position(b)[1]
	end)
	return result
end

local function standalone_vertical()
	return sidebar_state().layout_mode == "standalone_vertical"
end

local function configured_sidebar_width()
	local configured = state_mod.get().config.sidebar.width
	if type(configured) == "number" then
		return configured
	end
	return math.max(44, math.min(56, math.floor(vim.o.columns / 3)))
end

local function managed_window_set()
	local sidebar = sidebar_state()
	local managed = {}
	for _, win in ipairs(managed_note_windows()) do
		managed[win] = true
	end
	if is_valid_win(sidebar.calendar_notes_win) then
		managed[sidebar.calendar_notes_win] = true
	end
	return managed
end

local function is_empty_scratch_window(win)
	if not is_valid_win(win) then
		return false
	end
	local buf = vim.api.nvim_win_get_buf(win)
	return vim.api.nvim_buf_get_name(buf) == "" and vim.bo[buf].buftype == "" and not vim.bo[buf].modified
end

local function external_windows()
	local managed = managed_window_set()
	local result = {}
	for _, win in ipairs(normal_windows_in_current_tab()) do
		if not managed[win] then
			table.insert(result, win)
		end
	end
	return result
end

local function has_meaningful_external_window()
	for _, win in ipairs(external_windows()) do
		if not is_empty_scratch_window(win) then
			return true
		end
	end
	return false
end

local function standalone_note_windows()
	local sidebar = sidebar_state()
	local result = {}
	local seen = {}
	local function add(win)
		if is_valid_win(win) and not seen[win] then
			seen[win] = true
			table.insert(result, win)
		end
	end
	add(sidebar.preview_win)
	for _, win in ipairs(sidebar.note_wins or {}) do
		add(win)
	end
	return result
end

local function move_note_window_to_standalone(win)
	if not is_valid_win(win) then
		return
	end
	pcall(vim.api.nvim_win_call, win, function()
		vim.cmd("wincmd H")
	end)
end

local function resize_standalone_layout()
	local sidebar = sidebar_state()
	if not standalone_vertical() or not is_valid_win(sidebar.win) then
		return
	end

	vim.wo[sidebar.win].winfixwidth = true
	pcall(vim.api.nvim_win_set_width, sidebar.win, configured_sidebar_width())

	local note_wins = standalone_note_windows()
	if #note_wins == 0 then
		return
	end

	local total_width = 0
	for _, win in ipairs(note_wins) do
		vim.wo[win].winfixwidth = false
		total_width = total_width + vim.api.nvim_win_get_width(win)
	end
	local width = math.max(1, math.floor(total_width / #note_wins))
	for index_in_row, win in ipairs(note_wins) do
		if index_in_row < #note_wins then
			pcall(vim.api.nvim_win_set_width, win, width)
		end
	end
end

local function activate_standalone_layout()
	local sidebar = sidebar_state()
	if state_mod.get().config.sidebar.standalone_layout ~= "vertical" then
		return false
	end
	if has_meaningful_external_window() then
		return false
	end

	sidebar.layout_mode = "standalone_vertical"
	for _, win in ipairs(standalone_note_windows()) do
		move_note_window_to_standalone(win)
	end
	resize_standalone_layout()
	return true
end

local function rebalance_normal_layout()
	local sidebar = sidebar_state()
	if standalone_vertical() then
		resize_standalone_layout()
		return
	end
	if sidebar.mode == "calendar" then
		return
	end

	local wins = managed_note_windows()
	if #wins < 2 then
		return
	end

	local total_height = 0
	for _, win in ipairs(wins) do
		vim.wo[win].winfixheight = false
		total_height = total_height + vim.api.nvim_win_get_height(win)
	end

	local height = math.max(1, math.floor(total_height / #wins))
	for index_in_column, win in ipairs(wins) do
		if index_in_column < #wins then
			pcall(vim.api.nvim_win_set_height, win, height)
		end
	end
end

local function adopt_additional_preview()
	local sidebar = sidebar_state()
	local valid = {}
	for _, win in ipairs(sidebar.note_wins or {}) do
		if is_valid_win(win) then
			table.insert(valid, win)
		end
	end
	sidebar.note_wins = valid

	if is_valid_win(sidebar.preview_win) then
		return true
	end
	if sidebar.mode == "calendar" then
		return false
	end

	if sidebar.preview_buf then
		sidebar.note_bufs[sidebar.preview_buf] = nil
		sidebar.preview_buf = nil
	end

	local adopted = table.remove(valid)

	if not adopted then
		return false
	end

	sidebar.note_wins = valid
	sidebar.preview_win = adopted
	sidebar.preview_buf = vim.api.nvim_win_get_buf(adopted)
	local note = index.get_note_for_file(vim.api.nvim_buf_get_name(sidebar.preview_buf))
	sidebar.preview_note_id = note and note.id or nil
	sidebar.note_bufs[sidebar.preview_buf] = true
	notes.apply_window_options(adopted)
	return true
end

function M.reconcile_note_windows()
	local sidebar = sidebar_state()
	if not sidebar.open then
		return
	end

	adopt_additional_preview()
	if not standalone_vertical() then
		activate_standalone_layout()
	end
	rebalance_normal_layout()
end

local function close_calendar_notes_window()
	local sidebar = sidebar_state()

	if is_valid_win(sidebar.calendar_notes_win) then
		if vim.api.nvim_get_current_win() == sidebar.calendar_notes_win and is_valid_win(sidebar.win) then
			vim.api.nvim_set_current_win(sidebar.win)
		end
		vim.api.nvim_win_close(sidebar.calendar_notes_win, true)
	end

	sidebar.calendar_notes_win = nil
	if is_valid_win(sidebar.win) then
		vim.wo[sidebar.win].winfixheight = false
	end
end

local function ensure_calendar_notes_window()
	local sidebar = sidebar_state()

	if is_valid_win(sidebar.calendar_notes_win) or not is_valid_win(sidebar.win) then
		return
	end

	if not is_valid_buf(sidebar.calendar_notes_buf) then
		sidebar.calendar_notes_buf = vim.api.nvim_create_buf(false, true)
		set_sidebar_options(sidebar.calendar_notes_buf)
	end

	local current_win = vim.api.nvim_get_current_win()
	vim.api.nvim_set_current_win(sidebar.win)
	vim.cmd("belowright split")
	sidebar.calendar_notes_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(sidebar.calendar_notes_win, sidebar.calendar_notes_buf)
	vim.wo[sidebar.calendar_notes_win].number = false
	vim.wo[sidebar.calendar_notes_win].relativenumber = false
	vim.wo[sidebar.calendar_notes_win].signcolumn = "no"
	vim.wo[sidebar.calendar_notes_win].wrap = false
	vim.wo[sidebar.calendar_notes_win].winfixheight = false
	M.setup_calendar_notes_mappings(sidebar.calendar_notes_buf)

	if is_valid_win(current_win) then
		vim.api.nvim_set_current_win(current_win)
	end
end

function M.render_calendar()
	local sidebar = sidebar_state()
	local selected = calendar.parse(sidebar.calendar_date) or calendar.today()
	sidebar.calendar_date = calendar.format(selected.year, selected.month, selected.day)

	local lines = {}
	local line_items = {}
	local width = sidebar_width()
	local counts = index.get_calendar_counts(selected.year, selected.month)

	add_header(lines, line_items, "cal")
	table.insert(lines, center(string.format("%04d-%02d", selected.year, selected.month), width))
	line_items[#lines] = { kind = "calendar_month" }

	local cell_width = math.max(4, math.floor(width / 7))
	local grid_width = cell_width * 7
	local margin = math.max(0, math.floor((width - grid_width) / 2))
	local weekdays = { "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" }
	local weekday_line = string.rep(" ", margin)
	for _, name in ipairs(weekdays) do
		weekday_line = weekday_line .. calendar_cell(name, cell_width)
	end
	table.insert(lines, weekday_line)
	line_items[#lines] = { kind = "calendar_weekdays" }

	local first_weekday = calendar.weekday(selected.year, selected.month, 1)
	local days = calendar.days_in_month(selected.year, selected.month)
	-- Always render the maximum Gregorian month footprint. Shorter months keep
	-- their trailing cells empty so changing month never resizes the panel.
	local weeks = 6

	for week = 1, weeks do
		local line = string.rep(" ", margin)
		local cells = {}

		for weekday = 1, 7 do
			local day = (week - 1) * 7 + weekday - first_weekday + 1
			local start_col = #line

			if day >= 1 and day <= days then
				local date = calendar.format(selected.year, selected.month, day)
				local label = tostring(day) .. (counts[date] and "•" or "")
				line = line .. calendar_cell(label, cell_width)
				table.insert(cells, {
					date = date,
					has_notes = counts[date] ~= nil,
					start_col = start_col,
					end_col = #line,
				})

				if date == sidebar.calendar_date then
					sidebar.calendar_cursor = {
						line = #lines + 1,
						col = start_col + math.floor(cell_width / 2),
					}
				end
			else
				line = line .. string.rep(" ", cell_width)
			end
		end

		table.insert(lines, line)
		line_items[#lines] = { kind = "calendar_week", cells = cells }
	end

	return lines, line_items
end

function M.render_calendar_notes()
	local sidebar = sidebar_state()
	local date = sidebar.calendar_date
	local day_notes = index.get_notes_for_calendar_date(date)
	local day_todos = index.get_todos_for_calendar_date(date)
	local lines = {}
	local line_items = {}

	if #day_notes == 0 and #day_todos == 0 then
		table.insert(lines, "No items for this day")
		line_items[#lines] = { kind = "help" }
	else
		for _, note in ipairs(day_notes) do
			local line, target_start, target_end, missing_target = all_note_line(note)
			table.insert(lines, line)
			line_items[#lines] = {
				kind = "note",
				note_id = note.id,
				note_type = note_type(note),
				target_start = target_start,
				target_end = target_end,
				missing_target = missing_target,
			}
		end
		for _, todo in ipairs(day_todos) do
			for _, rendered in ipairs(todo_lines(todo)) do
				table.insert(lines, rendered.text)
				line_items[#lines] = {
					kind = "todo",
					todo_id = todo.id,
					completed = todo.completed_at ~= nil,
					text_end = rendered.text_end,
				}
			end
		end
	end

	return lines, line_items
end

local function reset_panel_views()
	local sidebar = sidebar_state()

	for _, win in ipairs({ sidebar.win, sidebar.calendar_notes_win }) do
		if is_valid_win(win) then
			pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
			vim.api.nvim_win_call(win, function()
				vim.cmd("normal! zt")
			end)
		end
	end
end

function M.set_mode(mode)
	if mode == "agenda" then
		mode = "calendar"
	end
	if mode ~= "all" and mode ~= "directory" and mode ~= "todo" and mode ~= "calendar" then
		return false
	end

	local sidebar = sidebar_state()
	if mode == "calendar" then
		sidebar.mode = mode
		ensure_calendar_notes_window()
	else
		close_calendar_notes_window()
		sidebar.mode = mode
	end

	M.refresh()
	M.sync_mode_preview(true)
	rebalance_normal_layout()
	reset_panel_views()
	return true
end

function M.toggle_mode()
	local sidebar = sidebar_state()

	if sidebar.mode == "all" then
		M.set_mode("directory")
	elseif sidebar.mode == "directory" then
		M.set_mode("todo")
	elseif sidebar.mode == "todo" then
		M.set_mode("calendar")
	else
		M.set_mode("all")
	end
end

function M.toggle_all_sort()
	local sidebar = sidebar_state()
	if sidebar.mode ~= "all" then
		return
	end

	if sidebar.all_sort == "date" then
		sidebar.all_sort = "updated"
	elseif sidebar.all_sort == "updated" then
		sidebar.all_sort = "created"
	else
		sidebar.all_sort = "date"
	end
	M.refresh()
end

function M.toggle_all_filter()
	local sidebar = sidebar_state()
	if sidebar.mode == "todo" then
		local filters = { "all", "open", "closed" }
		local current = vim.fn.index(filters, sidebar.todo_filter)
		sidebar.todo_filter = filters[((current + 1) % #filters) + 1]
		M.refresh()
		return
	end
	if sidebar.mode ~= "all" then
		return
	end

	local filters = { "all", "general", "diary", "meeting", "desc" }
	local current = vim.fn.index(filters, sidebar.all_filter)
	sidebar.all_filter = filters[((current + 1) % #filters) + 1]
	M.refresh()
	M.sync_mode_preview(true)
end

function M.refresh()
	local sidebar = sidebar_state()

	if not sidebar.open or not is_valid_buf(sidebar.buf) then
		return
	end

	local lines, line_items
	local selected_todo_id = nil
	if sidebar.mode == "todo" then
		local selected = selected_item()
		selected_todo_id = selected and selected.kind == "todo" and selected.todo_id or nil
	end

	if sidebar.mode == "directory" then
		lines, line_items = M.render_directory()
	elseif sidebar.mode == "todo" then
		lines, line_items = M.render_todos()
	elseif sidebar.mode == "calendar" then
		ensure_calendar_notes_window()
		lines, line_items = M.render_calendar()
	else
		lines, line_items = M.render_all()
	end

	sidebar.lines = lines
	sidebar.line_items = line_items

	with_modifiable(sidebar.buf, function()
		vim.api.nvim_buf_set_lines(sidebar.buf, 0, -1, false, lines)
	end)

	apply_highlights()

	if selected_todo_id and sidebar.mode == "todo" and is_valid_win(sidebar.win) then
		for line, item in ipairs(line_items) do
			if item.kind == "todo" and item.todo_id == selected_todo_id then
				pcall(vim.api.nvim_win_set_cursor, sidebar.win, { line, 0 })
				break
			end
		end
	end

	if sidebar.mode == "calendar" and is_valid_win(sidebar.win) then
		-- The calendar uses a fixed six-week grid and remains protected when the
		-- day list or preview is split.
		pcall(vim.api.nvim_win_set_height, sidebar.win, math.max(1, #lines))
		vim.wo[sidebar.win].winfixheight = true
	end

	if sidebar.mode == "calendar" and is_valid_buf(sidebar.calendar_notes_buf) then
		local selected = selected_calendar_note_item()
		local selected_kind = selected and selected.kind or nil
		local selected_id = selected_kind == "note" and selected.note_id
			or selected_kind == "todo" and selected.todo_id
			or nil
		local note_lines, note_items = M.render_calendar_notes()
		sidebar.calendar_notes_lines = note_lines
		sidebar.calendar_notes_items = note_items

		with_modifiable(sidebar.calendar_notes_buf, function()
			vim.api.nvim_buf_set_lines(sidebar.calendar_notes_buf, 0, -1, false, note_lines)
		end)
		apply_highlights(sidebar.calendar_notes_buf, note_lines, note_items)

		if is_valid_win(sidebar.calendar_notes_win) then
			local selected_line = nil
			for line, item in ipairs(note_items) do
				local item_id = item.kind == "note" and item.note_id or item.kind == "todo" and item.todo_id or nil
				if item.kind == selected_kind and item_id == selected_id then
					selected_line = line
					break
				end
			end

			if not selected_line then
				for line, item in ipairs(note_items) do
					if item.kind == "note" or item.kind == "todo" then
						selected_line = line
						break
					end
				end
			end

			pcall(vim.api.nvim_win_set_cursor, sidebar.calendar_notes_win, { selected_line or 1, 0 })
		end

		if is_valid_win(sidebar.win) and sidebar.calendar_cursor then
			pcall(vim.api.nvim_win_set_cursor, sidebar.win, {
				sidebar.calendar_cursor.line,
				sidebar.calendar_cursor.col,
			})
		end

		M.sync_calendar_preview()
	end
end

function M.schedule_refresh()
	local state = state_mod.get()
	local delay = state.config.sidebar.debounce_ms or 150

	if refresh_timer then
		refresh_timer:stop()
		refresh_timer:close()
		refresh_timer = nil
	end

	refresh_timer = vim.loop.new_timer()
	refresh_timer:start(
		delay,
		0,
		vim.schedule_wrap(function()
			M.refresh()
		end)
	)
end

function M.open()
	local state = state_mod.get()
	local sidebar = state.sidebar

	if is_valid_win(sidebar.win) then
		sidebar.open = true
		M.refresh()
		return
	end

	local current_win = vim.api.nvim_get_current_win()
	sidebar.source_win = current_win
	context.get_current()
	vim.wo[current_win].winfixwidth = false

	if not is_valid_buf(sidebar.buf) then
		sidebar.buf = vim.api.nvim_create_buf(false, true)
		set_sidebar_options(sidebar.buf)
	end

	local position = state.config.sidebar.position or "right"
	if position == "left" then
		vim.cmd("topleft vsplit")
	else
		vim.cmd("botright vsplit")
	end

	sidebar.win = vim.api.nvim_get_current_win()
	sidebar.open = true

	vim.api.nvim_win_set_buf(sidebar.win, sidebar.buf)
	if type(state.config.sidebar.width) == "number" then
		vim.api.nvim_win_set_width(sidebar.win, state.config.sidebar.width)
	else
		local natural_width = vim.api.nvim_win_get_width(sidebar.win)
		local bounded_width = math.max(44, math.min(56, natural_width))
		vim.api.nvim_win_set_width(sidebar.win, bounded_width)
	end
	vim.wo[sidebar.win].number = false
	vim.wo[sidebar.win].relativenumber = false
	vim.wo[sidebar.win].signcolumn = "no"
	vim.wo[sidebar.win].wrap = false
	vim.wo[sidebar.win].winfixwidth = false

	sidebar.layout_mode = "docked"
	sidebar.standalone_host_win = nil
	if state.config.sidebar.standalone_layout == "vertical" and not has_meaningful_external_window() then
		sidebar.layout_mode = "standalone_vertical"
		for _, win in ipairs(external_windows()) do
			if is_empty_scratch_window(win) then
				sidebar.standalone_host_win = win
				break
			end
		end
	end

	M.setup_mappings(sidebar.buf)
	M.refresh()

	for line, item in pairs(sidebar.line_items) do
		if item.kind == "note" then
			vim.api.nvim_win_set_cursor(sidebar.win, { line, 0 })
			M.preview_selected()
			break
		end
	end
	rebalance_normal_layout()

	if is_valid_win(current_win) then
		vim.api.nvim_set_current_win(current_win)
	end
end

function M.close()
	local sidebar = sidebar_state()

	close_preview_window()

	for _, win in ipairs(sidebar.note_wins or {}) do
		if is_valid_win(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	sidebar.note_wins = {}
	sidebar.note_bufs = {}
	close_calendar_notes_window()

	if is_valid_win(sidebar.win) then
		vim.wo[sidebar.win].winfixwidth = false
		local normal_wins = normal_windows_in_current_tab()

		if #normal_wins == 1 and normal_wins[1] == sidebar.win then
			local empty_buf = vim.api.nvim_create_buf(true, false)
			vim.api.nvim_win_set_buf(sidebar.win, empty_buf)
			vim.api.nvim_set_current_win(sidebar.win)
		else
			vim.api.nvim_win_close(sidebar.win, true)
		end
	end

	sidebar.open = false
	sidebar.win = nil
	sidebar.source_win = nil
	sidebar.layout_mode = "docked"
	sidebar.standalone_host_win = nil
end

local function load_note_in_window(note_id, win)
	local note = index.get_note(note_id)
	if not note or not is_valid_win(win) then
		return nil, nil
	end

	local abs_path = paths.join(state_mod.get().vault_dir, note.file)
	local buf = vim.fn.bufadd(abs_path)
	vim.fn.bufload(buf)
	vim.api.nvim_win_set_buf(win, buf)
	notes.apply_window_options(win)
	return win, buf
end

local function open_note_in_sidebar(note_id, source_win, opts)
	local sidebar = sidebar_state()
	opts = opts or {}
	source_win = source_win or sidebar.win

	if not is_valid_win(source_win) then
		return nil, nil
	end

	if standalone_vertical() and opts.preview and is_valid_win(sidebar.standalone_host_win) then
		local host = sidebar.standalone_host_win
		sidebar.standalone_host_win = nil
		return load_note_in_window(note_id, host)
	end

	vim.api.nvim_set_current_win(source_win)
	notes.open(note_id)
	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_win_get_buf(win)
	if standalone_vertical() then
		move_note_window_to_standalone(win)
		resize_standalone_layout()
	end
	return win, buf
end

function M.open_preview(note_id, opts)
	opts = opts or {}
	local sidebar = sidebar_state()
	if not sidebar.open or not is_valid_win(sidebar.win) then
		return false
	end

	adopt_additional_preview()

	if not opts.force and not is_valid_win(sidebar.preview_win) and sidebar.preview_note_id then
		return false
	end

	if note_id == sidebar.preview_note_id and is_valid_win(sidebar.preview_win) then
		if opts.focus then
			vim.api.nvim_set_current_win(sidebar.preview_win)
		end
		return true
	end

	local note = index.get_note(note_id)
	if not note then
		return false
	end

	if is_valid_win(sidebar.preview_win) then
		local abs_path = paths.join(state_mod.get().vault_dir, note.file)
		local buf = vim.fn.bufadd(abs_path)
		vim.fn.bufload(buf)
		vim.api.nvim_win_set_buf(sidebar.preview_win, buf)
		sidebar.preview_buf = buf
	else
		local source_win = sidebar.mode == "calendar" and sidebar.calendar_notes_win or sidebar.win
		local win, buf = open_note_in_sidebar(note_id, source_win, { preview = true })
		if not win then
			return false
		end
		sidebar.preview_win = win
		sidebar.preview_buf = buf
	end

	sidebar.preview_note_id = note_id
	sidebar.note_bufs[sidebar.preview_buf] = true
	notes.apply_window_options(sidebar.preview_win)
	if opts.focus and is_valid_win(sidebar.preview_win) then
		vim.api.nvim_set_current_win(sidebar.preview_win)
	elseif is_valid_win(sidebar.win) then
		vim.api.nvim_set_current_win(sidebar.win)
	end
	return true
end

function M.preview_calendar_note_selected()
	local item = selected_calendar_note_item()

	if not item or item.kind ~= "note" then
		return
	end

	local current_win = vim.api.nvim_get_current_win()
	M.open_preview(item.note_id)

	if is_valid_win(current_win) then
		vim.api.nvim_set_current_win(current_win)
	end
end

function M.sync_calendar_preview(force)
	local sidebar = sidebar_state()
	local selected = selected_calendar_note_item()
	if selected and selected.kind == "todo" then
		return
	end
	local preview_note = selected and selected.kind == "note" and selected or nil

	if not preview_note then
		for line = 1, #(sidebar.calendar_notes_lines or {}) do
			local item = sidebar.calendar_notes_items[line]
			if item and item.kind == "note" then
				preview_note = item
				break
			end
		end
	end

	if not preview_note then
		-- An empty calendar day has no replacement for the dynamic preview.
		-- Keep the current note and window so navigating dates never collapses
		-- or rebuilds the surrounding layout.
		return
	end

	local current_win = vim.api.nvim_get_current_win()
	M.open_preview(preview_note.note_id, { force = force == true })

	if is_valid_win(current_win) then
		vim.api.nvim_set_current_win(current_win)
	end
end

function M.sync_mode_preview(force)
	local sidebar = sidebar_state()

	if sidebar.mode == "todo" then
		return
	end

	if sidebar.mode == "calendar" then
		M.sync_calendar_preview(force)
		return
	end

	local first_note = nil
	for line = 1, #(sidebar.lines or {}) do
		local item = sidebar.line_items[line]
		if item and item.kind == "note" then
			first_note = item
			break
		end
	end

	if not first_note then
		if standalone_vertical() then
			-- Empty directory/all views must not consume a managed note column.
			-- Keeping the current preview also prevents successive mode cycles
			-- from promoting and then closing each additional note one by one.
			return
		end
		if
			is_valid_win(sidebar.preview_win)
			and (not is_valid_buf(sidebar.preview_buf) or not vim.bo[sidebar.preview_buf].modified)
		then
			close_preview_window()
		end
		return
	end

	local current_win = vim.api.nvim_get_current_win()
	M.open_preview(first_note.note_id, { force = force == true })

	if is_valid_win(current_win) then
		vim.api.nvim_set_current_win(current_win)
	end
end

function M.preview_selected()
	local item = selected_item()
	if not item or item.kind ~= "note" then
		return
	end

	M.open_preview(item.note_id)
end

function M.toggle()
	local sidebar = sidebar_state()

	if sidebar.open and is_valid_win(sidebar.win) then
		M.close()
	else
		M.open()
	end
end

function M.handle_enter()
	local sidebar = sidebar_state()

	if sidebar.mode == "calendar" then
		if is_valid_win(sidebar.calendar_notes_win) then
			vim.api.nvim_set_current_win(sidebar.calendar_notes_win)
			for line = 1, #(sidebar.calendar_notes_lines or {}) do
				local item = sidebar.calendar_notes_items[line]
				if item and (item.kind == "note" or item.kind == "todo") then
					vim.api.nvim_win_set_cursor(sidebar.calendar_notes_win, { line, 0 })
					break
				end
			end
		end
		return
	end

	local item = selected_item()
	if item and item.kind == "todo" then
		local ok, err = todos.toggle(item.todo_id)
		if not ok then
			vim.notify("seijaku: " .. tostring(err or "failed to toggle todo"), vim.log.levels.ERROR)
			return
		end
		M.refresh()
		return
	end

	if item and item.kind == "note" then
		if not is_valid_win(sidebar.preview_win) then
			sidebar.preview_note_id = nil
			M.preview_selected()
			return
		end

		local note_win, note_buf = open_note_in_sidebar(item.note_id)
		if note_win ~= sidebar.win and is_valid_win(note_win) then
			sidebar.note_wins = sidebar.note_wins or {}
			table.insert(sidebar.note_wins, note_win)

			sidebar.note_bufs = sidebar.note_bufs or {}
			sidebar.note_bufs[note_buf] = true
			rebalance_normal_layout()
		end

		if is_valid_win(sidebar.win) then
			vim.api.nvim_set_current_win(sidebar.win)
		end
	end
end

function M.handle_create()
	if sidebar_state().mode == "todo" then
		todos.create({ on_created = M.refresh })
		return
	end
	notes.create({
		title = "Untitled",
		calendar_date = sidebar_state().mode == "calendar" and sidebar_state().calendar_date or nil,
		on_created = function()
			M.refresh()
		end,
	})
end

function M.handle_create_todo_for_calendar()
	if sidebar_state().mode ~= "calendar" then
		return
	end
	todos.create({
		calendar_date = sidebar_state().calendar_date,
		on_created = M.refresh,
	})
end

function M.handle_create_for_context()
	if sidebar_state().mode == "todo" then
		M.handle_create()
		return
	end
	local ctx = context.get_association_target()

	if not ctx or not ctx.target_path then
		vim.notify("seijaku: no current filesystem target found", vim.log.levels.WARN)
		return
	end

	notes.create({
		title = paths.basename(ctx.target_path) or "Untitled",
		target_path = ctx.target_path,
		target_type = ctx.target_type,
		calendar_date = sidebar_state().mode == "calendar" and sidebar_state().calendar_date or nil,
		on_created = function()
			M.refresh()
		end,
	})
end

local function rename_item(item)
	if not item then
		return
	end
	if item.kind == "todo" then
		return todos.rename(item.todo_id)
	end
	if item.kind ~= "note" then
		return
	end

	local note = index.get_note(item.note_id)
	if not note then
		return
	end

	vim.ui.input({
		prompt = "New title: ",
		default = note.title or "",
	}, function(input)
		if not input or input == "" then
			return
		end

		notes.rename(item.note_id, input)
		M.refresh()
	end)
end

function M.handle_rename()
	return rename_item(selected_item())
end

function M.handle_calendar_rename()
	return rename_item(selected_calendar_note_item())
end

local function delete_item(item)
	if not item then
		return
	end
	if item.kind == "todo" then
		local todo = index.get_todo(item.todo_id)
		local text = todo and todo.text or item.todo_id
		local choice = vim.fn.confirm("Delete todo '" .. text .. "'?", "&Yes\n&No", 2)
		if choice ~= 1 then
			return
		end
		local ok, err = todos.delete(item.todo_id)
		if not ok then
			vim.notify("seijaku: " .. tostring(err or "failed to delete todo"), vim.log.levels.ERROR)
			return
		end
		M.refresh()
		return
	end
	if item.kind ~= "note" then
		return
	end

	local note = index.get_note(item.note_id)
	local title = note and note.title or item.note_id

	local choice = vim.fn.confirm("Delete note '" .. title .. "'?", "&Yes\n&No", 2)
	if choice ~= 1 then
		return
	end

	notes.delete(item.note_id)
	M.refresh()
end

function M.handle_delete()
	return delete_item(selected_item())
end

function M.handle_calendar_delete()
	return delete_item(selected_calendar_note_item())
end

function M.handle_detach_current()
	local item = selected_item()

	if not item or item.kind ~= "note" then
		return
	end

	local ctx = context.get_association_target()
	local target_path = item.target_path or (ctx and ctx.target_path) or nil
	if not target_path then
		vim.notify("seijaku: no target to detach from this note", vim.log.levels.WARN)
		return
	end

	local ok = index.detach(item.note_id, target_path)
	if not ok then
		vim.notify("seijaku: failed to detach path", vim.log.levels.ERROR)
		return
	end

	vim.notify("seijaku: detached path")
	M.refresh()
end

function M.handle_live_grep()
	require("seijaku.search").live_grep()
end

function M.calendar_move_days(amount)
	local sidebar = sidebar_state()
	local selected = calendar.parse(sidebar.calendar_date) or calendar.today()
	local result = calendar.add_days(selected, amount)
	sidebar.calendar_date = calendar.format(result.year, result.month, result.day)
	M.refresh()
end

function M.calendar_move_months(amount)
	local sidebar = sidebar_state()
	local selected = calendar.parse(sidebar.calendar_date) or calendar.today()
	local result = calendar.add_months(selected, amount)
	sidebar.calendar_date = calendar.format(result.year, result.month, result.day)
	M.refresh()
end

function M.calendar_today()
	local today = calendar.today()
	sidebar_state().calendar_date = calendar.format(today.year, today.month, today.day)
	M.refresh()
end

function M.calendar_month_edge(last)
	local sidebar = sidebar_state()
	local selected = calendar.parse(sidebar.calendar_date) or calendar.today()
	selected.day = last and calendar.days_in_month(selected.year, selected.month) or 1
	sidebar.calendar_date = calendar.format(selected.year, selected.month, selected.day)
	M.refresh()
end

function M.handle_calendar_note_enter()
	local item = selected_calendar_note_item()

	if item and item.kind == "todo" then
		local ok, err = todos.toggle(item.todo_id)
		if not ok then
			vim.notify("seijaku: " .. tostring(err or "failed to toggle todo"), vim.log.levels.ERROR)
			return
		end
		M.refresh()
		return
	end

	if item and item.kind == "note" then
		M.open_preview(item.note_id, { force = true, focus = true })
	end
end

function M.handle_calendar_clear_date()
	local item = selected_calendar_note_item()

	if not item or item.kind ~= "note" then
		return
	end

	local ok, err = index.set_calendar_date(item.note_id, nil)
	if not ok then
		vim.notify("seijaku: " .. tostring(err or "failed to clear calendar date"), vim.log.levels.ERROR)
		return
	end

	vim.notify("seijaku: calendar date cleared")
	M.refresh()
end

local function calendar_or_normal(callback, normal_key)
	if sidebar_state().mode == "calendar" then
		callback()
	elseif normal_key then
		vim.cmd("normal! " .. normal_key)
	end
end

function M.setup_calendar_notes_mappings(buf)
	local opts = {
		buffer = buf,
		silent = true,
		nowait = true,
	}

	vim.keymap.set("n", "<CR>", M.handle_calendar_note_enter, opts)
	vim.keymap.set("n", "a", M.handle_create_for_context, opts)
	vim.keymap.set("n", "n", M.handle_create, opts)
	vim.keymap.set("n", "T", M.handle_create_todo_for_calendar, opts)
	vim.keymap.set("n", "x", M.handle_calendar_clear_date, opts)
	vim.keymap.set("n", "r", M.handle_calendar_rename, opts)
	vim.keymap.set("n", "dd", M.handle_calendar_delete, opts)
	vim.keymap.set("n", "<Tab>", M.toggle_mode, opts)
	vim.keymap.set("n", "R", M.refresh, opts)

	vim.api.nvim_create_autocmd("CursorMoved", {
		buffer = buf,
		callback = function()
			vim.schedule(M.preview_calendar_note_selected)
		end,
	})
end

function M.setup_mappings(buf)
	local opts = {
		buffer = buf,
		silent = true,
		nowait = true,
	}

	vim.keymap.set("n", "<CR>", M.handle_enter, opts)
	vim.keymap.set("n", "n", M.handle_create, opts)
	vim.keymap.set("n", "T", M.handle_create_todo_for_calendar, opts)
	vim.keymap.set("n", "a", M.handle_create_for_context, opts)
	vim.keymap.set("n", "x", M.handle_detach_current, opts)
	vim.keymap.set("n", "r", M.handle_rename, opts)
	vim.keymap.set("n", "dd", M.handle_delete, opts)
	vim.keymap.set("n", "<Tab>", M.toggle_mode, opts)
	vim.keymap.set("n", "s", M.toggle_all_sort, opts)
	vim.keymap.set("n", "f", M.toggle_all_filter, opts)
	vim.keymap.set("n", "/", M.handle_live_grep, opts)
	vim.keymap.set("n", "R", M.refresh, opts)
	vim.keymap.set("n", "h", function()
		calendar_or_normal(function()
			M.calendar_move_days(-1)
		end, "h")
	end, opts)
	vim.keymap.set("n", "l", function()
		calendar_or_normal(function()
			M.calendar_move_days(1)
		end, "l")
	end, opts)
	vim.keymap.set("n", "k", function()
		calendar_or_normal(function()
			M.calendar_move_days(-7)
		end, "k")
	end, opts)
	vim.keymap.set("n", "j", function()
		calendar_or_normal(function()
			M.calendar_move_days(7)
		end, "j")
	end, opts)
	vim.keymap.set("n", "<Left>", function()
		calendar_or_normal(function()
			M.calendar_move_days(-1)
		end, "h")
	end, opts)
	vim.keymap.set("n", "<Right>", function()
		calendar_or_normal(function()
			M.calendar_move_days(1)
		end, "l")
	end, opts)
	vim.keymap.set("n", "<Up>", function()
		calendar_or_normal(function()
			M.calendar_move_days(-7)
		end, "k")
	end, opts)
	vim.keymap.set("n", "<Down>", function()
		calendar_or_normal(function()
			M.calendar_move_days(7)
		end, "j")
	end, opts)
	vim.keymap.set("n", "[", function()
		calendar_or_normal(function()
			M.calendar_move_months(-1)
		end)
	end, opts)
	vim.keymap.set("n", "]", function()
		calendar_or_normal(function()
			M.calendar_move_months(1)
		end)
	end, opts)
	vim.keymap.set("n", "t", function()
		calendar_or_normal(M.calendar_today)
	end, opts)
	vim.keymap.set("n", "gg", function()
		calendar_or_normal(function()
			M.calendar_month_edge(false)
		end, "gg")
	end, opts)
	vim.keymap.set("n", "G", function()
		calendar_or_normal(function()
			M.calendar_month_edge(true)
		end, "G")
	end, opts)

	vim.api.nvim_create_autocmd("CursorMoved", {
		buffer = buf,
		callback = function()
			vim.schedule(M.preview_selected)
		end,
	})
end

return M
