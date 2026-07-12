local M = {}

local state_mod = require("seijaku.state")
local index = require("seijaku.index")
local notes = require("seijaku.notes")
local context = require("seijaku.context")
local paths = require("seijaku.paths")

local refresh_timer = nil
local highlight_ns = vim.api.nvim_create_namespace("seijaku_sidebar")

local function sidebar_state()
	return state_mod.get().sidebar
end

local function is_valid_win(win)
	return win and vim.api.nvim_win_is_valid(win)
end

local function is_valid_buf(buf)
	return buf and vim.api.nvim_buf_is_valid(buf)
end

local function selected_item()
	local sidebar = sidebar_state()

	if not is_valid_win(sidebar.win) then
		return nil
	end

	local line = vim.api.nvim_win_get_cursor(sidebar.win)[1]
	return sidebar.line_items[line]
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
	local right = "seijaku"
	local gap = math.max(1, width - display_width(left) - display_width(right))
	local mode = sidebar_state().mode
	local mode_labels = {
		mode == "all" and sidebar_state().all_sort or "all",
		mode == "directory" and tostring(title or ".") or "dir",
		"agenda",
	}
	local active_index = mode == "all" and 1 or mode == "directory" and 2 or 3
	local available_active = math.max(
		3,
		width
			- display_width(mode_labels[active_index == 1 and 2 or 1])
			- display_width(mode_labels[active_index == 3 and 2 or 3])
			- 2
	)
	mode_labels[active_index] = truncate_left(mode_labels[active_index], available_active)
	local mode_space = math.max(
		2,
		width - display_width(mode_labels[1]) - display_width(mode_labels[2]) - display_width(mode_labels[3])
	)
	local mode_gap_left = math.floor(mode_space / 2)
	local mode_gap_right = mode_space - mode_gap_left
	local mode_text = mode_labels[1]
		.. string.rep(" ", mode_gap_left)
		.. mode_labels[2]
		.. string.rep(" ", mode_gap_right)
		.. mode_labels[3]
	local active_start = active_index == 1 and 0
		or active_index == 2 and #mode_labels[1] + mode_gap_left
		or #mode_text - #mode_labels[3]

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

local function apply_highlights()
	local sidebar = sidebar_state()

	if not is_valid_buf(sidebar.buf) then
		return
	end

	vim.api.nvim_buf_clear_namespace(sidebar.buf, highlight_ns, 0, -1)
	vim.api.nvim_set_hl(0, "SeijakuHeader", { bold = true })
	vim.api.nvim_set_hl(0, "SeijakuBrand", { fg = "#769267", ctermfg = 108, bold = false })
	vim.api.nvim_set_hl(0, "SeijakuModeActive", { fg = "#9f3434", ctermfg = 217, bold = true })
	vim.api.nvim_set_hl(0, "SeijakuSubheader", { link = "Comment" })
	vim.api.nvim_set_hl(0, "SeijakuHelp", { link = "Comment" })
	vim.api.nvim_set_hl(0, "SeijakuSection", { link = "Title" })
	vim.api.nvim_set_hl(0, "SeijakuTarget", { link = "Comment" })
	vim.api.nvim_set_hl(0, "SeijakuNote", { link = "Function" })

	local highlight_by_kind = {
		subheader = "SeijakuSubheader",
		rule = "SeijakuHelp",
		help = "SeijakuHelp",
		section = "SeijakuSection",
		target = "SeijakuTarget",
		folder = "SeijakuTarget",
		date = "SeijakuTarget",
	}

	for line, item in pairs(sidebar.line_items or {}) do
		local group = item and highlight_by_kind[item.kind]

		if group then
			vim.api.nvim_buf_set_extmark(sidebar.buf, highlight_ns, line - 1, 0, {
				line_hl_group = group,
				priority = 100,
			})
		end

		if item and (item.kind == "modes" or item.kind == "submodes") then
			vim.api.nvim_buf_set_extmark(sidebar.buf, highlight_ns, line - 1, 0, {
				end_col = #sidebar.lines[line],
				hl_group = "SeijakuSubheader",
				hl_mode = "replace",
				priority = 100,
			})
			vim.api.nvim_buf_set_extmark(sidebar.buf, highlight_ns, line - 1, item.active_start, {
				end_col = item.active_end,
				hl_group = "SeijakuModeActive",
				hl_mode = "replace",
				priority = 110,
			})
		end

		if item and item.kind == "header" then
			vim.api.nvim_buf_set_extmark(sidebar.buf, highlight_ns, line - 1, 0, {
				end_col = #sidebar.lines[line],
				hl_group = "SeijakuHeader",
				hl_mode = "replace",
				priority = 100,
			})
			vim.api.nvim_buf_set_extmark(sidebar.buf, highlight_ns, line - 1, item.brand_start, {
				end_col = item.brand_end,
				hl_group = "SeijakuBrand",
				hl_mode = "replace",
				priority = 110,
			})
		end

		if item and item.kind == "note" then
			vim.api.nvim_buf_set_extmark(sidebar.buf, highlight_ns, line - 1, 0, {
				end_col = #sidebar.lines[line],
				hl_group = "SeijakuNote",
				hl_mode = "replace",
				priority = 100,
			})
		end

		if item and item.kind == "note" and item.target_start then
			vim.api.nvim_buf_set_extmark(sidebar.buf, highlight_ns, line - 1, item.target_start, {
				end_col = item.target_end,
				hl_group = "SeijakuTarget",
				hl_mode = "replace",
				priority = 110,
			})
		end
	end
end

local function note_line(note)
	local title = note.title or note.id
	local target_count = #(note.targets or {})

	if target_count > 0 then
		return string.format(" %s [%d]", title, target_count)
	end

	return " " .. title
end

local function all_note_line(note)
	local width = sidebar_width()
	local left = "    " .. tostring(note.title or note.id)
	local first_target = note.targets and note.targets[1]

	if not first_target or not first_target.path then
		return truncate_right(left, width)
	end

	local right = paths.basename(first_target.path)
	right = truncate_left(right, math.max(4, math.floor(width * 0.4)))
	local left_width = math.max(4, width - display_width(right) - 1)
	left = truncate_right(left, left_width)
	local gap = math.max(1, width - display_width(left) - display_width(right))
	local line = left .. string.rep(" ", gap) .. right
	local target_start = #left + gap

	return line, target_start, target_start + #right
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

	return path_icon(target_path, target_type) .. " " .. label
end

function M.render_all()
	local state = state_mod.get()
	local limit = state.config.sidebar.all_mode_limit or 500
	local all_notes = index.list_notes()
	local lines = {}
	local line_items = {}

	add_header(lines, line_items, "すべて")

	if sidebar_state().all_sort == "date" then
		table.sort(all_notes, function(a, b)
			return tostring(a.created_at or "") > tostring(b.created_at or "")
		end)
	end

	if #all_notes == 0 then
		table.insert(lines, "No notes yet")
	else
		local current_date = nil
		for i, note in ipairs(all_notes) do
			if i > limit then
				table.insert(lines, "")
				table.insert(lines, string.format("Showing %d of %d notes", limit, #all_notes))
				break
			end

			if sidebar_state().all_sort == "date" then
				local note_date = tostring(note.created_at or ""):match("^%d%d%d%d%-%d%d%-%d%d") or "Unknown date"
				if note_date ~= current_date then
					current_date = note_date
					table.insert(lines, " " .. note_date)
					line_items[#lines] = { kind = "date" }
				end
			end

			local line, target_start, target_end = all_note_line(note)
			table.insert(lines, line)
			line_items[#lines] = {
				kind = "note",
				note_id = note.id,
				target_start = target_start,
				target_end = target_end,
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
			table.insert(lines, target_indent .. target_label(target_path))
			line_items[#lines] = {
				kind = "target",
				target_path = target_path,
			}

			table.sort(target_notes, function(a, b)
				return tostring(a.updated_at or "") > tostring(b.updated_at or "")
			end)

			for _, note in ipairs(target_notes) do
				table.insert(lines, target_indent .. "  " .. note_line(note))
				line_items[#lines] = {
					kind = "note",
					note_id = note.id,
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
				table.insert(lines, indent .. target_label(child.path))
				line_items[#lines] = {
					kind = child.target_path and "target" or "folder",
					target_path = child.target_path,
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

function M.render_agenda()
	local lines = {}
	local line_items = {}
	add_header(lines, line_items, "agenda")
	table.insert(lines, "Agenda coming soon")
	return lines, line_items
end

function M.set_mode(mode)
	if mode ~= "all" and mode ~= "directory" and mode ~= "agenda" then
		return false
	end

	sidebar_state().mode = mode
	M.refresh()
	return true
end

function M.toggle_mode()
	local sidebar = sidebar_state()

	if sidebar.mode == "all" then
		M.set_mode("directory")
	elseif sidebar.mode == "directory" then
		M.set_mode("agenda")
	else
		M.set_mode("all")
	end
end

function M.toggle_all_sort()
	local sidebar = sidebar_state()
	if sidebar.mode ~= "all" then
		return
	end

	sidebar.all_sort = sidebar.all_sort == "date" and "updated" or "date"
	M.refresh()
end

function M.refresh()
	local sidebar = sidebar_state()

	if not sidebar.open or not is_valid_buf(sidebar.buf) then
		return
	end

	local lines, line_items

	if sidebar.mode == "directory" then
		lines, line_items = M.render_directory()
	elseif sidebar.mode == "agenda" then
		lines, line_items = M.render_agenda()
	else
		lines, line_items = M.render_all()
	end

	sidebar.lines = lines
	sidebar.line_items = line_items

	with_modifiable(sidebar.buf, function()
		vim.api.nvim_buf_set_lines(sidebar.buf, 0, -1, false, lines)
	end)

	apply_highlights()
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

	if not is_valid_buf(sidebar.buf) then
		sidebar.buf = vim.api.nvim_create_buf(false, true)
		set_sidebar_options(sidebar.buf)
	end

	local position = state.config.sidebar.position or "right"
	if position == "left" then
		vim.cmd("topleft vertical new")
	else
		vim.cmd("botright vertical new")
	end

	sidebar.win = vim.api.nvim_get_current_win()
	sidebar.open = true

	vim.api.nvim_win_set_buf(sidebar.win, sidebar.buf)
	if type(state.config.sidebar.width) == "number" then
		vim.api.nvim_win_set_width(sidebar.win, state.config.sidebar.width)
	else
		local natural_width = vim.api.nvim_win_get_width(sidebar.win)
		local bounded_width = math.max(40, math.min(52, natural_width))
		vim.api.nvim_win_set_width(sidebar.win, bounded_width)
	end
	vim.wo[sidebar.win].number = false
	vim.wo[sidebar.win].relativenumber = false
	vim.wo[sidebar.win].signcolumn = "no"
	vim.wo[sidebar.win].wrap = false
	vim.wo[sidebar.win].winfixwidth = false

	M.setup_mappings(sidebar.buf)
	M.refresh()

	for line, item in pairs(sidebar.line_items) do
		if item.kind == "note" then
			vim.api.nvim_win_set_cursor(sidebar.win, { line, 0 })
			M.preview_selected()
			break
		end
	end

	if is_valid_win(current_win) then
		vim.api.nvim_set_current_win(current_win)
	end
end

function M.close()
	local sidebar = sidebar_state()

	if is_valid_win(sidebar.preview_win) then
		vim.api.nvim_win_close(sidebar.preview_win, true)
	end

	for _, win in ipairs(sidebar.note_wins or {}) do
		if is_valid_win(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	sidebar.note_wins = {}
	sidebar.note_bufs = {}
	sidebar.preview_win = nil
	sidebar.preview_buf = nil
	sidebar.preview_note_id = nil

	if is_valid_win(sidebar.win) then
		vim.api.nvim_win_close(sidebar.win, true)
	end

	sidebar.open = false
	sidebar.win = nil
end

local function open_note_in_sidebar(note_id)
	local sidebar = sidebar_state()

	if not is_valid_win(sidebar.win) then
		return nil, nil
	end

	vim.api.nvim_set_current_win(sidebar.win)
	notes.open(note_id)
	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_win_get_buf(win)
	return win, buf
end

function M.open_preview(note_id, opts)
	opts = opts or {}
	local sidebar = sidebar_state()
	if not sidebar.open or not is_valid_win(sidebar.win) then
		return false
	end

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
		local win, buf = open_note_in_sidebar(note_id)
		if not win then
			return false
		end
		sidebar.preview_win = win
		sidebar.preview_buf = buf
	end

	sidebar.preview_note_id = note_id
	sidebar.note_bufs[sidebar.preview_buf] = true
	if opts.focus and is_valid_win(sidebar.preview_win) then
		vim.api.nvim_set_current_win(sidebar.preview_win)
	elseif is_valid_win(sidebar.win) then
		vim.api.nvim_set_current_win(sidebar.win)
	end
	return true
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
	local item = selected_item()

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
		end

		if is_valid_win(sidebar.win) then
			vim.api.nvim_set_current_win(sidebar.win)
		end
	end
end

function M.handle_create()
	notes.create({
		title = "Untitled",
		on_created = function()
			M.refresh()
		end,
	})
end

function M.handle_create_for_context()
	local ctx = context.get_current()

	if not ctx or not ctx.target_path then
		vim.notify("seijaku: no current filesystem target found", vim.log.levels.WARN)
		return
	end

	notes.create({
		title = paths.basename(ctx.target_path) or "Untitled",
		target_path = ctx.target_path,
		target_type = ctx.target_type,
		on_created = function()
			M.refresh()
		end,
	})
end

function M.handle_rename()
	local item = selected_item()

	if not item or item.kind ~= "note" then
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

function M.handle_delete()
	local item = selected_item()

	if not item or item.kind ~= "note" then
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

function M.handle_detach_current()
	local item = selected_item()

	if not item or item.kind ~= "note" then
		return
	end

	local ctx = context.get_current()
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

function M.setup_mappings(buf)
	local opts = {
		buffer = buf,
		silent = true,
		nowait = true,
	}

	vim.keymap.set("n", "<CR>", M.handle_enter, opts)
	vim.keymap.set("n", "n", M.handle_create, opts)
	vim.keymap.set("n", "a", M.handle_create_for_context, opts)
	vim.keymap.set("n", "x", M.handle_detach_current, opts)
	vim.keymap.set("n", "r", M.handle_rename, opts)
	vim.keymap.set("n", "dd", M.handle_delete, opts)
	vim.keymap.set("n", "<Tab>", M.toggle_mode, opts)
	vim.keymap.set("n", "s", M.toggle_all_sort, opts)
	vim.keymap.set("n", "R", M.refresh, opts)

	vim.api.nvim_create_autocmd("CursorMoved", {
		buffer = buf,
		callback = function()
			vim.schedule(M.preview_selected)
		end,
	})
end

return M
