local M = {}

local state_mod = require("seijaku.state")
local index = require("seijaku.index")
local notes = require("seijaku.notes")
local context = require("seijaku.context")
local paths = require("seijaku.paths")
local calendar = require("seijaku.calendar")
local layout = require("seijaku.layout")
local picker = require("seijaku.picker")
local target_status = require("seijaku.target_status")

local refresh_timer = nil
local calendar_day_timer = nil
local layout_rebalance_timer = nil
local stop_calendar_day_timer
local apply_calendar_day_input
local append_note_card
local highlight_ns = vim.api.nvim_create_namespace("seijaku_sidebar")
local selection_ns = vim.api.nvim_create_namespace("seijaku_sidebar_selection")
local highlights_defined = false
local notebook_hl_cache = {}
local tag_hl_cache = {}
local default_notebook_icon = "■"
local tag_icon = ""
local no_filter_icon = "○"
local no_filter_active_icon = "●"

local function no_filter_display_icon(selected)
	return selected and no_filter_active_icon or no_filter_icon
end

local function notebook_display_icon(notebook)
	local icon = notebook and notebook.icon or nil
	return type(icon) == "string" and icon ~= "" and icon or default_notebook_icon
end

local function tag_display_icon(tag)
	return index.get_tag_icon(tag) or tag_icon
end

local palettes = {
	muted = {
		brand = "#769267",
		brand_cterm = 108,
		active = "#9f3434",
		active_cterm = 131,
		pinned = "#a67c00",
		pinned_cterm = 136,
		closed = "#66645f",
		closed_cterm = 242,
		subtle = "#757575",
		subtle_cterm = 243,
	},
	vivid = {
		brand = "#88ac76",
		brand_cterm = 108,
		active = "#cc5555",
		active_cterm = 167,
		pinned = "#d0a02b",
		pinned_cterm = 178,
		closed = "#77746f",
		closed_cterm = 243,
		subtle = "#666a70",
		subtle_cterm = 242,
	},
}

local card_role_groups = {
	title = "SeijakuNote",
	meta = "SeijakuMuted",
	book = "SeijakuMuted",
	target = "SeijakuTarget",
	tags = "SeijakuMuted",
}

local pin_icon = " "

local function sidebar_state()
	return state_mod.get().sidebar
end

local is_valid_win = layout.is_valid_win

local function is_valid_buf(buf)
	return buf and vim.api.nvim_buf_is_valid(buf)
end

local function sidebar_tabpage(sidebar)
	if not is_valid_win(sidebar.win) then
		return nil
	end
	return vim.api.nvim_win_get_tabpage(sidebar.win)
end

local function focus_sidebar_tab(sidebar, win)
	local tab = sidebar_tabpage(sidebar)
	if not tab or not vim.api.nvim_tabpage_is_valid(tab) then
		return false
	end
	if vim.api.nvim_get_current_tabpage() ~= tab then
		vim.api.nvim_set_current_tabpage(tab)
	end
	if is_valid_win(win) then
		vim.api.nvim_set_current_win(win)
	end
	return true
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

local function preferred_sidebar_width()
	local configured = state_mod.get().config.sidebar.width
	if type(configured) == "number" then
		return configured
	end
	-- Keep the sidebar stable while toggling the calendar.  Twenty-eight
	-- columns also gives the calendar its seven four-column cells.
	return 28
end

local function preferred_preview_width()
	local configured = state_mod.get().config.sidebar.preview_width
	if type(configured) == "number" then
		-- Fractions are proportions of the editor width (0.2 = 20%);
		-- values >= 1 remain absolute column counts for backwards compatibility.
		local columns = configured > 0 and configured < 1 and vim.o.columns * configured or configured
		return math.max(5, math.floor(columns))
	end
	-- Keep the original full-layout proportion unless the user explicitly
	-- overrides it. This leaves a genuinely usable Markdown editor by default.
	return math.max(20, math.floor(vim.o.columns * 0.30))
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
	local chars = vim.fn.strchars(text)
	local low, high = 0, chars
	while low < high do
		local count = math.floor((low + high + 1) / 2)
		local candidate = vim.fn.strcharpart(text, chars - count, count)
		if display_width(candidate) <= available then
			low = count
		else
			high = count - 1
		end
	end

	return marker .. vim.fn.strcharpart(text, chars - low, low)
end

local function truncate_right(text, width)
	text = tostring(text or "")
	if display_width(text) <= width then
		return text
	end

	local marker = "..."
	local available = math.max(1, width - display_width(marker))
	local chars = vim.fn.strchars(text)
	local low, high = 0, chars
	while low < high do
		local count = math.floor((low + high + 1) / 2)
		local candidate = vim.fn.strcharpart(text, 0, count)
		if display_width(candidate) <= available then
			low = count
		else
			high = count - 1
		end
	end

	return vim.fn.strcharpart(text, 0, low) .. marker
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

local function add_header(lines, line_items)
	local start = #lines + 1
	local sidebar = sidebar_state()
	local query = vim.trim(sidebar.title_filter or "")
	table.insert(lines, query)

	line_items[start] = {
		kind = "header",
		search_start = 0,
		search_end = #query,
		empty_search = query == "",
	}
end

function M.define_highlights()
	notebook_hl_cache = {}
	tag_hl_cache = {}
	local appearance = (state_mod.get().config or {}).appearance or {}
	local preset = appearance.palette or "auto"
	if preset == "auto" then
		preset = vim.o.background == "light" and "muted" or "vivid"
	end
	local palette = vim.deepcopy(palettes[preset] or palettes.vivid)
	palette = vim.tbl_extend("force", palette, appearance.colors or {})
	vim.api.nvim_set_hl(0, "SeijakuHeader", { bold = false })
	vim.api.nvim_set_hl(0, "SeijakuHeaderState", { fg = palette.active, ctermfg = palette.active_cterm, bold = true })
	vim.api.nvim_set_hl(0, "SeijakuBrand", { link = "Normal" })
	vim.api.nvim_set_hl(0, "SeijakuModeActive", { fg = palette.active, ctermfg = palette.active_cterm, bold = true })
	vim.api.nvim_set_hl(0, "SeijakuMuted", { fg = palette.subtle, ctermfg = palette.subtle_cterm, italic = false })
	vim.api.nvim_set_hl(0, "SeijakuSelectorAll", { fg = "#a8a8a8", ctermfg = 248, bold = false })
	vim.api.nvim_set_hl(0, "SeijakuDivider", { fg = "#2b2d31", ctermfg = 236, blend = 85, nocombine = true })
	vim.api.nvim_set_hl(0, "SeijakuSubheader", { link = "SeijakuMuted" })
	vim.api.nvim_set_hl(0, "SeijakuHelp", { link = "SeijakuMuted" })
	vim.api.nvim_set_hl(0, "SeijakuSection", { link = "Title" })
	vim.api.nvim_set_hl(0, "SeijakuTarget", { fg = "#d47761", ctermfg = 173 })
	vim.api.nvim_set_hl(0, "SeijakuMissingTarget", { link = "DiagnosticWarn" })
	vim.api.nvim_set_hl(0, "SeijakuNote", { link = "Normal" })
	vim.api.nvim_set_hl(0, "SeijakuCalendarMonth", { fg = palette.brand, ctermfg = palette.brand_cterm })
	vim.api.nvim_set_hl(
		0,
		"SeijakuCalendarNoteDate",
		{ fg = palette.active, ctermfg = palette.active_cterm, bold = true }
	)
	vim.api.nvim_set_hl(0, "SeijakuCalendarToday", { link = "DiagnosticInfo" })
	vim.api.nvim_set_hl(
		0,
		"SeijakuCalendarSelected",
		{ fg = palette.active, ctermfg = palette.active_cterm, bold = true }
	)
	vim.api.nvim_set_hl(0, "SeijakuSelectorSelected", {
		fg = "#ffffff",
		bg = palette.brand,
		bold = true,
	})
	vim.api.nvim_set_hl(0, "SeijakuSelectorAllSelected", {
		fg = palette.active,
		ctermfg = palette.active_cterm,
		bg = "NONE",
		bold = true,
	})
	vim.api.nvim_set_hl(0, "SeijakuPickerSelected", {
		fg = palette.brand,
		ctermfg = palette.brand_cterm,
		bold = true,
	})
	vim.api.nvim_set_hl(0, "SeijakuCalendarHasNotes", { link = "Function" })
	vim.api.nvim_set_hl(0, "SeijakuPinned", { fg = palette.pinned, ctermfg = palette.pinned_cterm, bold = true })
	vim.api.nvim_set_hl(0, "SeijakuPinnedBlock", { fg = "#faf8f2", bg = palette.pinned, bold = true })
	vim.api.nvim_set_hl(0, "SeijakuMetadataFile", { fg = "#faf8f2", bg = palette.closed, bold = true })
	vim.api.nvim_set_hl(0, "SeijakuTag", { fg = palette.brand, ctermfg = palette.brand_cterm, bold = true })
	vim.api.nvim_set_hl(0, "SeijakuMetadataFold", { fg = palette.closed, ctermfg = palette.closed_cterm, bg = "NONE" })
	vim.api.nvim_set_hl(0, "SeijakuPickerNormal", { bg = "NONE" })
	vim.api.nvim_set_hl(0, "SeijakuPickerCursor", { bg = "NONE", bold = true })
	notes.define_tag_highlights()
	highlights_defined = true
end

local function apply_highlights(buf, lines, line_items)
	local sidebar = sidebar_state()
	buf = buf or sidebar.buf
	lines = lines or sidebar.lines
	line_items = line_items or sidebar.line_items

	if not is_valid_buf(buf) then
		return
	end

	if not highlights_defined then
		M.define_highlights()
	end
	vim.api.nvim_buf_clear_namespace(buf, highlight_ns, 0, -1)

	local highlight_by_kind = {
		subheader = "SeijakuSubheader",
		rule = "SeijakuHelp",
		divider = "SeijakuDivider",
		sort_indicator = "SeijakuMuted",
		help = "SeijakuHelp",
		section = "SeijakuSection",
		target = "SeijakuTarget",
		folder = "SeijakuTarget",
		calendar_month = "SeijakuCalendarMonth",
		calendar_note_date = "SeijakuCalendarNoteDate",
		calendar_weekdays = "SeijakuSubheader",
	}

	for line, item in pairs(line_items or {}) do
		local group = item and highlight_by_kind[item.kind]

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
			if item.search_end > item.search_start then
				vim.api.nvim_buf_set_extmark(buf, highlight_ns, line - 1, item.search_start, {
					end_col = item.search_end,
					hl_group = "SeijakuHeaderState",
					hl_mode = "combine",
					priority = 120,
				})
			end
			if item.empty_search then
				vim.api.nvim_buf_set_extmark(buf, highlight_ns, line - 1, 0, {
					virt_text = { { "⌕ search notes", "SeijakuMuted" } },
					virt_text_pos = "overlay",
					priority = 120,
				})
			end
			vim.api.nvim_buf_set_extmark(buf, highlight_ns, line - 1, 0, {
				virt_text = { { "静寂", "SeijakuBrand" } },
				virt_text_pos = "right_align",
				priority = 130,
			})
		end

		if item and item.kind == "note" and item.card_role then
			vim.api.nvim_buf_set_extmark(buf, highlight_ns, line - 1, 0, {
				end_col = #lines[line],
				hl_group = item.missing_target and "SeijakuMissingTarget" or card_role_groups[item.card_role],
				hl_mode = "combine",
				priority = 100,
			})
			if item.pin_start then
				vim.api.nvim_buf_set_extmark(buf, highlight_ns, line - 1, item.pin_start, {
					end_col = item.pin_end,
					hl_group = "SeijakuPinned",
					hl_mode = "combine",
					priority = 120,
				})
			end
			if item.project_start and item.project_color and item.project_color:match("^#%x%x%x%x%x%x$") then
				local book_group = "SeijakuNotebookGlyph_" .. item.project_color:sub(2)
				if not notebook_hl_cache[book_group] then
					vim.api.nvim_set_hl(0, book_group, { fg = item.project_color, bg = "NONE", bold = true })
					notebook_hl_cache[book_group] = true
				end
				vim.api.nvim_buf_set_extmark(buf, highlight_ns, line - 1, item.project_start, {
					end_col = item.project_end,
					hl_group = book_group,
					hl_mode = "combine",
					priority = 110,
				})
			end
			for _, range in ipairs(item.tag_ranges or {}) do
				vim.api.nvim_buf_set_extmark(buf, highlight_ns, line - 1, range.start_col, {
					end_col = range.end_col,
					hl_group = range.tag and notes.tag_glyph_highlight(range.tag) or "SeijakuTag",
					hl_mode = "replace",
					priority = 120,
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

		if item and item.kind == "note" and item.calendar_start then
			vim.api.nvim_buf_set_extmark(buf, highlight_ns, line - 1, item.calendar_start, {
				end_col = item.calendar_end,
				hl_group = "SeijakuCalendarNoteDate",
				hl_mode = "combine",
				priority = 120,
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

local function update_card_selection(buf, win, items)
	if not is_valid_buf(buf) then
		return
	end
	vim.api.nvim_buf_clear_namespace(buf, selection_ns, 0, -1)
	if not is_valid_win(win) then
		return
	end
	local line = vim.api.nvim_win_get_cursor(win)[1]
	local selected = items and items[line]
	if not selected or selected.kind ~= "note" or not selected.card_role then
		return
	end
	local first, last = line, line
	while first > 1 and items[first - 1] and items[first - 1].note_id == selected.note_id do
		first = first - 1
	end
	while items[last + 1] and items[last + 1].note_id == selected.note_id do
		last = last + 1
	end
	for card_line = first, last do
		vim.api.nvim_buf_set_extmark(buf, selection_ns, card_line - 1, 0, {
			line_hl_group = "CursorLine",
			priority = 80,
		})
	end
end

local function update_visible_card_selection()
	local sidebar = sidebar_state()
	update_card_selection(sidebar.buf, sidebar.win, sidebar.line_items)
	if sidebar.mode == "calendar" then
		update_card_selection(sidebar.calendar_notes_buf, sidebar.calendar_notes_win, sidebar.calendar_notes_items)
	elseif is_valid_buf(sidebar.calendar_notes_buf) then
		vim.api.nvim_buf_clear_namespace(sidebar.calendar_notes_buf, selection_ns, 0, -1)
	end
end

local function append_note_dividers(lines, line_items, count)
	local rule = string.rep("─", math.max(1, sidebar_width()))
	for _ = 1, count or 1 do
		table.insert(lines, rule)
		line_items[#lines] = { kind = "divider" }
	end
end

local function append_sort_indicator(lines, line_items)
	local sort = sidebar_state().all_sort or "updated"
	table.insert(lines, "· " .. sort)
	line_items[#lines] = { kind = "sort_indicator" }
end

local function note_matches_search(note, query)
	query = vim.trim(tostring(query or "")):lower()
	if query == "" then
		return true
	end
	local values = { note.title, note.file, note.notebook_id }
	local notebook = note.notebook_id and index.get_notebook(note.notebook_id) or nil
	if notebook then
		table.insert(values, notebook.name)
		table.insert(values, notebook.path)
	end
	for _, tag in ipairs(note.tags or {}) do
		table.insert(values, tag)
	end
	for _, target in ipairs(note.targets or {}) do
		table.insert(values, target.path)
	end
	for _, value in ipairs(values) do
		if tostring(value or ""):lower():find(query, 1, true) then
			return true
		end
	end
	return false
end

function M.render_all()
	local state = state_mod.get()
	local limit = state.config.sidebar.all_mode_limit or 500
	local lines, line_items = {}, {}
	local sort = sidebar_state().all_sort
	if sort ~= "date" and sort ~= "created" then
		sort = "updated"
	end
	sidebar_state().all_sort = sort
	append_sort_indicator(lines, line_items)
	local all_tag = sidebar_state().all_tag or "all"
	local all_notebook = sidebar_state().all_notebook or "all"
	if all_notebook ~= "all" and not index.get_notebook(all_notebook) then
		all_notebook = "all"
		sidebar_state().all_notebook = "all"
	end
	local all_notes = index.query_notes({
		sort = sort,
		tag = all_tag,
		notebook_id = all_notebook ~= "all" and all_notebook or nil,
	})
	local title_filter = sidebar_state().title_filter or ""
	if vim.trim(title_filter) ~= "" then
		all_notes = vim.tbl_filter(function(note)
			return note_matches_search(note, title_filter)
		end, all_notes)
	end
	if #all_notes == 0 then
		table.insert(lines, next(state.notes_by_id or {}) and "No notes for this filter" or "No notes yet")
		line_items[#lines] = { kind = "help" }
	else
		local previous_pinned = nil
		for i, note in ipairs(all_notes) do
			if i > limit then
				table.insert(lines, string.format("Showing %d of %d notes", limit, #all_notes))
				line_items[#lines] = { kind = "help" }
				break
			end
			if i > 1 then
				append_note_dividers(lines, line_items, 1)
			end
			append_note_card(lines, line_items, note)
			previous_pinned = note.pinned
		end
	end
	return lines, line_items
end

local function active_scope()
	local sidebar = sidebar_state()
	return {
		tag = sidebar.all_tag or "all",
		notebook_id = sidebar.all_notebook ~= "all" and sidebar.all_notebook or nil,
	}
end

local function split_word_by_width(word, width)
	local chunks, current = {}, ""
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
	local result, current = {}, ""
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
append_note_card = function(lines, line_items, note)
	local width = sidebar_width()
	local function append(text, role, details)
		local item = details or {}
		item.kind = "note"
		item.note_id = note.id
		item.card_role = role
		table.insert(lines, text)
		line_items[#lines] = item
	end
	local function append_wrapped(prefix, text, role, details)
		local continuation = string.rep(" ", display_width(prefix))
		for chunk_index, chunk in ipairs(wrap_text(text, width - display_width(prefix))) do
			local start = chunk_index == 1 and prefix or continuation
			local item = vim.deepcopy(details or {})
			if chunk_index > 1 then
				item.pin_start = nil
				item.pin_end = nil
				item.project_start = nil
				item.project_end = nil
			end
			append(start .. chunk, role, item)
		end
	end

	local title_prefix = ""
	local title_details = {}
	if note.pinned then
		title_details.pin_start = 0
		title_details.pin_end = #pin_icon
		title_prefix = pin_icon .. " "
	end
	if note.notebook_id then
		local book = index.get_notebook(note.notebook_id)
		title_details.project_start = #title_prefix
		title_prefix = title_prefix .. notebook_display_icon(book) .. " "
		title_details.project_end = #title_prefix - 1
		title_details.project_color = book and book.color or nil
	end
	append_wrapped(title_prefix, note.title or note.id, "title", {
		pin_start = title_details.pin_start,
		pin_end = title_details.pin_end,
		project_start = title_details.project_start,
		project_end = title_details.project_end,
		project_color = title_details.project_color,
	})

	local created = tostring(note.created_at or ""):match("^(%d%d%d%d%-%d%d%-%d%d)")
	local calendar_date = tostring(note.calendar_date or "")
	local date_line = created or ""
	local calendar_start, calendar_end
	if calendar_date ~= "" and calendar_date ~= created then
		calendar_start = #date_line + (date_line ~= "" and 2 or 0)
		date_line = date_line .. (date_line ~= "" and "  " or "") .. calendar_date
		calendar_end = #date_line
	end
	if date_line ~= "" then
		append(date_line, "meta", {
			calendar_start = calendar_start,
			calendar_end = calendar_end,
		})
	end

	local detail_line, tag_ranges = "", {}
	for _, tag in ipairs(note.tags or {}) do
		local icon = tag_display_icon(tag)
		local separator = detail_line ~= "" and " " or ""
		if detail_line ~= "" and display_width(detail_line .. separator .. icon) > width then
			append(detail_line, "tags", { tag_ranges = tag_ranges })
			detail_line, tag_ranges, separator = "", {}, ""
		end
		detail_line = detail_line .. separator
		local start_col = #detail_line
		detail_line = detail_line .. icon
		table.insert(tag_ranges, { start_col = start_col, end_col = #detail_line, tag = tag })
	end

	for _, target in ipairs(note.targets or {}) do
		if target.path then
			local status = target_status.get(target.path)
			local missing = status and status.exists == false or false
			local target_text = (missing and "! " or "↗ ") .. paths.basename(target.path)
			local separator = detail_line ~= "" and "  " or ""
			if detail_line ~= "" and display_width(detail_line .. separator .. target_text) <= width then
				local target_start = #detail_line + #separator
				detail_line = detail_line .. separator .. target_text
				append(detail_line, "tags", {
					tag_ranges = tag_ranges,
					target_start = target_start,
					target_end = #detail_line,
					missing_target = missing,
				})
				detail_line, tag_ranges = "", {}
			else
				if detail_line ~= "" then
					append(detail_line, "tags", { tag_ranges = tag_ranges })
					detail_line, tag_ranges = "", {}
				end
				append_wrapped(missing and "! " or "↗ ", paths.basename(target.path), "target", {
					missing_target = missing,
				})
			end
		end
	end
	if detail_line ~= "" then
		append(detail_line, "tags", { tag_ranges = tag_ranges })
	end
end

local function calendar_cell(label, width)
	label = tostring(label or "")
	local remaining = math.max(0, width - display_width(label))
	local left = math.floor(remaining / 2)
	return string.rep(" ", left) .. label .. string.rep(" ", remaining - left)
end

local function clear_preview_state(sidebar, dismissed)
	if sidebar.preview_buf then
		sidebar.note_bufs[sidebar.preview_buf] = nil
	end
	sidebar.preview_win = nil
	sidebar.preview_buf = nil
	sidebar.preview_note_id = nil
	sidebar.note_header_win = nil
	sidebar.note_header_buf = nil
	sidebar.preview_width_initialized = false
	if dismissed ~= nil then
		sidebar.preview_dismissed = dismissed
	end
end

local function close_preview_pair(sidebar, dismissed)
	local header_buf = sidebar.note_header_buf
	local current_win = vim.api.nvim_get_current_win()
	if
		(current_win == sidebar.note_header_win or current_win == sidebar.preview_win)
		and is_valid_win(sidebar.win)
	then
		vim.api.nvim_set_current_win(sidebar.win)
	end

	if is_valid_win(sidebar.note_header_win) then
		pcall(vim.api.nvim_win_close, sidebar.note_header_win, true)
	end
	if is_valid_win(sidebar.preview_win) then
		pcall(vim.api.nvim_win_close, sidebar.preview_win, true)
	end
	clear_preview_state(sidebar, dismissed)
	if is_valid_buf(header_buf) then
		pcall(vim.api.nvim_buf_delete, header_buf, { force = true })
	end
end

local function close_preview_window()
	close_preview_pair(sidebar_state(), false)
end

local function rebalance_normal_layout()
	local sidebar = sidebar_state()
	layout.rebalance_sidebar(
		sidebar,
		preferred_sidebar_width(),
		preferred_preview_width()
	)
end

local function rebalance_full_layout()
	layout.rebalance_sidebar(sidebar_state(), preferred_sidebar_width(), nil, { full = true })
end

local function schedule_layout_rebalance()
	if layout_rebalance_timer then
		layout_rebalance_timer:stop()
		layout_rebalance_timer:close()
	end
	local timer = vim.loop.new_timer()
	layout_rebalance_timer = timer
	timer:start(20, 0, vim.schedule_wrap(function()
		if layout_rebalance_timer == timer then
			layout_rebalance_timer = nil
		end
		if not timer:is_closing() then
			timer:stop()
			timer:close()
		end
		local sidebar = sidebar_state()
		if sidebar.open and not sidebar.closing and not sidebar.full_layout_active then
			rebalance_normal_layout()
		end
	end))
end

M.schedule_layout_rebalance = schedule_layout_rebalance

local function adjacent_external_window(sidebar, reference_win, side)
	if not is_valid_win(reference_win) then
		return nil
	end
	local reference_pos = vim.fn.win_screenpos(reference_win)
	local reference_row, reference_col = reference_pos[1], reference_pos[2]
	local reference_bottom = reference_row + vim.api.nvim_win_get_height(reference_win)
	local best, best_edge = nil, side == "right" and math.huge or -1
	for _, win in ipairs(layout.external_windows(sidebar)) do
		local pos = vim.fn.win_screenpos(win)
		local row, col = pos[1], pos[2]
		local bottom = row + vim.api.nvim_win_get_height(win)
		local right = col + vim.api.nvim_win_get_width(win)
		local overlaps = row < reference_bottom and bottom > reference_row
		if side == "left" and overlaps and col < reference_col and right > best_edge then
			best, best_edge = win, right
		elseif side == "right" and overlaps and col > reference_col and col < best_edge then
			best, best_edge = win, col
		end
	end
	return best
end

function M.reconcile_note_windows()
	local sidebar = sidebar_state()
	if not sidebar.open or sidebar.closing then
		return
	end

	-- The list and selector panes are the Seijaku shell. If one is closed by
	-- the user, tear down the complete workspace rather than leaving a partial
	-- sidebar with a still-open preview. The note preview/header pair below is
	-- intentionally handled separately and keeps the sidebar alive.
	for _, win in ipairs({ sidebar.win, sidebar.notebook_win, sidebar.tag_win }) do
		if win and not is_valid_win(win) then
			M.close()
			return
		end
	end

	local has_preview_state = sidebar.preview_win
		or sidebar.preview_buf
		or sidebar.note_header_win
		or sidebar.note_header_buf
	if not has_preview_state then
		return
	end

	local preview_alive = is_valid_win(sidebar.preview_win)
		and is_valid_buf(sidebar.preview_buf)
		and vim.api.nvim_win_get_buf(sidebar.preview_win) == sidebar.preview_buf
	local header_alive = is_valid_win(sidebar.note_header_win)
		and is_valid_buf(sidebar.note_header_buf)
		and vim.api.nvim_win_get_buf(sidebar.note_header_win) == sidebar.note_header_buf
	if preview_alive and header_alive then
		return
	end

	-- Header and Markdown preview form one component. If either side is closed,
	-- deleted or replaced, remove the other side as well.
	close_preview_pair(sidebar, true)
	rebalance_normal_layout()
	schedule_layout_rebalance()
end

function M.redirect_calendar_entry(from_win, entered_win)
	local sidebar = sidebar_state()
	if not sidebar.open or sidebar.mode ~= "calendar" or entered_win ~= sidebar.win then
		return false
	end
	if not is_valid_win(sidebar.calendar_notes_win) then
		return false
	end
	if from_win and layout.managed_windows(sidebar)[from_win] then
		return false
	end

	local has_items = false
	for _, item in pairs(sidebar.calendar_notes_items or {}) do
		if item.kind == "note" then
			has_items = true
			break
		end
	end
	if not has_items then
		return false
	end

	vim.schedule(function()
		local current = sidebar_state()
		if
			current.open
			and current.mode == "calendar"
			and is_valid_win(current.win)
			and vim.api.nvim_get_current_win() == current.win
			and is_valid_win(current.calendar_notes_win)
		then
			vim.api.nvim_set_current_win(current.calendar_notes_win)
		end
	end)
	return true
end

function M.redirect_sidebar_entry(from_win, entered_win)
	local sidebar = sidebar_state()
	if not sidebar.open then
		return false
	end
	local entered_selector = entered_win == sidebar.notebook_win or entered_win == sidebar.tag_win
	if entered_selector then
		if sidebar.selector_saved_winwidth == nil then
			sidebar.selector_saved_winwidth = vim.o.winwidth
		end
		-- 'winwidth' is applied to the focused window even when winfixwidth is
		-- set. Lower it only while a compact selector owns focus.
		vim.o.winwidth = 1
		rebalance_normal_layout()
	else
		if sidebar.selector_saved_winwidth ~= nil then
			local saved = sidebar.selector_saved_winwidth
			sidebar.selector_saved_winwidth = nil
			vim.o.winwidth = saved
		end
	end

	if entered_win == sidebar.win then
		return M.redirect_calendar_entry(from_win, entered_win)
	end
	if entered_win == sidebar.header_win and sidebar.search_active then
		return false
	end
	-- Notebook and tag selectors are interactive filters. Their local mappings
	-- handle selection and editing without falling through to the header.
	if entered_selector then
		return false
	end
	if entered_win ~= sidebar.header_win then
		return false
	end

	local destination = sidebar.win
	if sidebar.mode == "calendar" and is_valid_win(sidebar.calendar_notes_win) then
		for _, item in pairs(sidebar.calendar_notes_items or {}) do
			if item.kind == "note" then
				destination = sidebar.calendar_notes_win
				break
			end
		end
	end
	vim.schedule(function()
		if sidebar.open and is_valid_win(destination) and vim.api.nvim_get_current_win() == entered_win then
			vim.api.nvim_set_current_win(destination)
		end
	end)
	return true
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
	local counts = index.get_calendar_counts(selected.year, selected.month, active_scope())

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
	local day_notes = index.get_notes_for_calendar_date(date, active_scope())
	local title_filter = sidebar.title_filter or ""
	if vim.trim(title_filter) ~= "" then
		day_notes = vim.tbl_filter(function(note)
			return note_matches_search(note, title_filter)
		end, day_notes)
	end
	local lines = {}
	local line_items = {}
	local exists_cache = {}
	append_sort_indicator(lines, line_items)

	if #day_notes == 0 then
		table.insert(lines, "No notes for this day")
		line_items[#lines] = { kind = "help" }
	else
		for note_index, note in ipairs(day_notes) do
			if note_index > 1 then
				append_note_dividers(lines, line_items)
			end
			append_note_card(lines, line_items, note, exists_cache)
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
	if mode ~= "all" and mode ~= "calendar" then
		return false
	end

	local sidebar = sidebar_state()
	if stop_calendar_day_timer then
		stop_calendar_day_timer()
	end
	sidebar.calendar_day_input = ""
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

	M.set_mode(sidebar.mode == "all" and "calendar" or "all")
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

function M.toggle_all_tag()
	local sidebar = sidebar_state()
	local choices = { "all" }
	vim.list_extend(choices, index.list_tags())
	local current = vim.fn.index(choices, sidebar.all_tag or "all")
	sidebar.all_tag = choices[((current + 1) % #choices) + 1]
	M.refresh()
	M.sync_mode_preview(true)
end

function M.toggle_all_notebook()
	return M.cycle_notebook(1)
end

function M.cycle_notebook(direction)
	local sidebar = sidebar_state()
	local choices = { "all" }
	for _, notebook in ipairs(index.list_notebooks()) do
		table.insert(choices, notebook.id)
	end
	local current = vim.fn.index(choices, sidebar.all_notebook or "all")
	direction = direction or 1
	sidebar.all_notebook = choices[((current + direction) % #choices) + 1]
	M.refresh()
	M.sync_mode_preview(true)
end

function M.cycle_tag(direction)
	local sidebar = sidebar_state()
	local choices = { "all" }
	vim.list_extend(choices, index.list_tags())
	local current = vim.fn.index(choices, sidebar.all_tag or "all")
	direction = direction or 1
	sidebar.all_tag = choices[((current + direction) % #choices) + 1]
	M.refresh()
	M.sync_mode_preview(true)
end

local function panel_options(win)
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].wrap = false
	vim.wo[win].cursorline = false
	vim.wo[win].cursorcolumn = false
end

local function ensure_sidebar_panels()
	local sidebar = sidebar_state()
	if not is_valid_win(sidebar.win) then
		return
	end
	if not is_valid_buf(sidebar.header_buf) then
		sidebar.header_buf = vim.api.nvim_create_buf(false, true)
		set_sidebar_options(sidebar.header_buf)
		vim.bo[sidebar.header_buf].modifiable = true
	end
	if not is_valid_win(sidebar.header_win) then
		local current = vim.api.nvim_get_current_win()
		vim.api.nvim_set_current_win(sidebar.win)
		vim.cmd("aboveleft split")
		sidebar.header_win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(sidebar.header_win, sidebar.header_buf)
		panel_options(sidebar.header_win)
		vim.api.nvim_win_set_height(sidebar.header_win, 1)
		vim.wo[sidebar.header_win].winfixheight = true
		M.setup_header_mappings(sidebar.header_buf)
		if is_valid_win(current) then
			vim.api.nvim_set_current_win(current)
		end
	end
	if not is_valid_buf(sidebar.notebook_buf) then
		sidebar.notebook_buf = vim.api.nvim_create_buf(false, true)
		set_sidebar_options(sidebar.notebook_buf)
	end
	if not is_valid_buf(sidebar.tag_buf) then
		sidebar.tag_buf = vim.api.nvim_create_buf(false, true)
		set_sidebar_options(sidebar.tag_buf)
	end
	if not is_valid_win(sidebar.notebook_win) then
		local current = vim.api.nvim_get_current_win()
		vim.api.nvim_set_current_win(sidebar.win)
		vim.cmd("rightbelow vsplit")
		sidebar.notebook_win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(sidebar.notebook_win, sidebar.notebook_buf)
		panel_options(sidebar.notebook_win)
		vim.api.nvim_win_set_width(sidebar.notebook_win, sidebar.selector_width or 3)
		-- Keep the selector column genuinely narrow.  Without winfixwidth Neovim
		-- gives a fresh split its preferred `winwidth`, which makes this compact
		-- sidebar unexpectedly wide.
		vim.wo[sidebar.notebook_win].winfixwidth = true
		M.setup_notebook_mappings(sidebar.notebook_buf)
		vim.cmd("belowright split")
		sidebar.tag_win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(sidebar.tag_win, sidebar.tag_buf)
		panel_options(sidebar.tag_win)
		vim.wo[sidebar.tag_win].winfixwidth = true
		M.setup_tag_mappings(sidebar.tag_buf)
		if is_valid_win(current) then
			vim.api.nvim_set_current_win(current)
		end
	end
end

local function render_header_panel()
	local sidebar = sidebar_state()
	if not is_valid_buf(sidebar.header_buf) then
		return
	end
	local lines, items = {}, {}
	add_header(lines, items)
	if not sidebar.search_active then
		vim.api.nvim_buf_set_lines(sidebar.header_buf, 0, -1, false, lines)
	else
		lines = vim.api.nvim_buf_get_lines(sidebar.header_buf, 0, -1, false)
	end
	apply_highlights(sidebar.header_buf, lines, items)
end

local function render_selector_panels()
	local sidebar = sidebar_state()
	local selector_width = math.max(display_width(no_filter_icon), display_width(no_filter_active_icon))
	for _, book in ipairs(index.list_notebooks()) do
		selector_width = math.max(selector_width, display_width(notebook_display_icon(book) .. " " .. book.name))
	end
	for _, tag in ipairs(index.list_tags()) do
		selector_width = math.max(selector_width, display_width(tag_display_icon(tag) .. " " .. tag))
	end
	-- The note list has its own fixed width. The adjacent selector column is
	-- sized from its content, so notebook and tag names remain legible and the
	-- preview/external panes take the remaining space.
	sidebar.selector_width = selector_width
	if is_valid_buf(sidebar.notebook_buf) then
		local lines, items = {}, {}
		table.insert(lines, no_filter_display_icon(sidebar.all_notebook == "all"))
		items[#lines] = { id = "all", all = true }
		for _, book in ipairs(index.list_notebooks()) do
			table.insert(lines, notebook_display_icon(book) .. " " .. book.name)
			items[#lines] = { id = book.id, color = book.color, icon = book.icon, path = book.path }
		end
		sidebar.notebook_items = items
		with_modifiable(sidebar.notebook_buf, function()
			vim.api.nvim_buf_set_lines(sidebar.notebook_buf, 0, -1, false, lines)
		end)
		vim.api.nvim_buf_clear_namespace(sidebar.notebook_buf, highlight_ns, 0, -1)
		for line, item in ipairs(items) do
			local selected = item.id == sidebar.all_notebook
			local group = "SeijakuMuted"
			if item.all then
				group = selected and "SeijakuSelectorAllSelected" or "SeijakuSelectorAll"
			elseif selected then
				group = "SeijakuSelectorSelected"
			elseif item.path then
				group = "SeijakuTarget"
			end
			vim.api.nvim_buf_set_extmark(sidebar.notebook_buf, highlight_ns, line - 1, 0, {
				end_col = #lines[line],
				hl_group = group,
				hl_mode = "replace",
				priority = 120,
			})
			if item.color and item.color:match("^#%x%x%x%x%x%x$") then
				local glyph_group = "SeijakuNotebookGlyph_" .. item.color:sub(2)

				if not notebook_hl_cache[glyph_group] then
					vim.api.nvim_set_hl(0, glyph_group, {
						fg = item.color,
						bg = "NONE",
						bold = true,
					})
					notebook_hl_cache[glyph_group] = true
				end

				if item.id == sidebar.all_notebook then
					local selected_group = "SeijakuNotebookSelected_" .. item.color:sub(2)

					if not notebook_hl_cache[selected_group] then
						vim.api.nvim_set_hl(0, selected_group, {
							fg = "#ffffff",
							bg = item.color,
							bold = true,
						})
						notebook_hl_cache[selected_group] = true
					end

					vim.api.nvim_buf_set_extmark(sidebar.notebook_buf, highlight_ns, line - 1, 0, {
						end_col = #lines[line],
						hl_group = selected_group,
						hl_mode = "replace",
						priority = 140,
					})
				else
					vim.api.nvim_buf_set_extmark(sidebar.notebook_buf, highlight_ns, line - 1, 0, {
						end_col = #notebook_display_icon(item),
						hl_group = glyph_group,
						hl_mode = "combine",
						priority = 130,
					})
				end
			end
			if item.id == sidebar.all_notebook and is_valid_win(sidebar.notebook_win) then
				pcall(vim.api.nvim_win_set_cursor, sidebar.notebook_win, { line, 0 })
			end
		end
	end
	if is_valid_buf(sidebar.tag_buf) then
		local lines, items = {}, {}
		table.insert(lines, no_filter_display_icon(sidebar.all_tag == "all"))
		items[#lines] = { tag = "all", all = true }
		for _, tag in ipairs(index.list_tags()) do
			local icon = tag_display_icon(tag)
			table.insert(lines, icon .. " " .. tag)
			items[#lines] = { tag = tag, icon = icon }
		end
		sidebar.tag_items = items
		with_modifiable(sidebar.tag_buf, function()
			vim.api.nvim_buf_set_lines(sidebar.tag_buf, 0, -1, false, lines)
		end)
		vim.api.nvim_buf_clear_namespace(sidebar.tag_buf, highlight_ns, 0, -1)
		for line, item in ipairs(items) do
			local selected = item.tag == sidebar.all_tag
			local tag_group = not item.all and notes.tag_glyph_highlight(item.tag) or nil

			if item.all then
				vim.api.nvim_buf_set_extmark(sidebar.tag_buf, highlight_ns, line - 1, 0, {
					end_col = #lines[line],
					hl_group = selected and "SeijakuSelectorAllSelected" or "SeijakuSelectorAll",
					hl_mode = "replace",
					priority = 140,
				})
			elseif selected then
				local tag_hl = vim.api.nvim_get_hl(0, {
					name = tag_group,
					link = false,
				})

				local bg = tag_hl.fg

				if bg then
					local selected_group = "SeijakuTagSelected_" .. tostring(bg)

					if not tag_hl_cache[selected_group] then
						vim.api.nvim_set_hl(0, selected_group, {
							fg = "#ffffff",
							bg = bg,
							bold = true,
						})
						tag_hl_cache[selected_group] = true
					end

					vim.api.nvim_buf_set_extmark(sidebar.tag_buf, highlight_ns, line - 1, 0, {
						end_col = #lines[line],
						hl_group = selected_group,
						hl_mode = "replace",
						priority = 140,
					})
				end
			else
				vim.api.nvim_buf_set_extmark(sidebar.tag_buf, highlight_ns, line - 1, 0, {
					end_col = #lines[line],
					hl_group = "SeijakuMuted",
					priority = 120,
				})

				vim.api.nvim_buf_set_extmark(sidebar.tag_buf, highlight_ns, line - 1, 0, {
					end_col = #(item.icon or tag_icon),
					hl_group = tag_group,
					hl_mode = "combine",
					priority = 130,
				})
			end
		end
	end
end

function M.refresh()
	local sidebar = sidebar_state()

	if not sidebar.open or not is_valid_buf(sidebar.buf) then
		return
	end

	local lines, line_items
	local selected_note_id = nil
	if sidebar.mode == "all" then
		local selected = selected_item()
		selected_note_id = selected and selected.kind == "note" and selected.note_id or nil
	end

	if sidebar.mode == "calendar" then
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
	render_selector_panels()
	render_header_panel()

	if selected_note_id and sidebar.mode == "all" and is_valid_win(sidebar.win) then
		for line, item in ipairs(line_items) do
			if item.kind == "note" and item.note_id == selected_note_id then
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
		local selected_id = selected_kind == "note" and selected.note_id or nil
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
				local item_id = item.kind == "note" and item.note_id or nil
				if item.kind == selected_kind and item_id == selected_id then
					selected_line = line
					break
				end
			end

			if not selected_line then
				for line, item in ipairs(note_items) do
					if item.kind == "note" then
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
	update_visible_card_selection()
	-- The preview context strip is a separate immutable buffer, so refresh it
	-- independently when an attribute changes without switching notes.
	if is_valid_win(sidebar.preview_win) then
		M.open_preview(sidebar.preview_note_id)
	end
	-- Let Neovim finish split creation and redraw before enforcing compact pane
	-- widths; synchronous resizing here gets undone during the same refresh.
	schedule_layout_rebalance()
end

function M.schedule_refresh()
	local state = state_mod.get()
	local delay = state.config.sidebar.debounce_ms or 150

	if refresh_timer then
		refresh_timer:stop()
		refresh_timer:close()
		refresh_timer = nil
	end

	local timer = vim.loop.new_timer()
	refresh_timer = timer
	timer:start(
		delay,
		0,
		vim.schedule_wrap(function()
			if refresh_timer ~= timer then
				if not timer:is_closing() then
					timer:close()
				end
				return
			end
			refresh_timer = nil
			if not timer:is_closing() then
				timer:close()
			end
			M.refresh()
		end)
	)
end

function M.open()
	local state = state_mod.get()
	local sidebar = state.sidebar

	if is_valid_win(sidebar.win) then
		sidebar.open = true
		sidebar.full_layout_active = false
		focus_sidebar_tab(sidebar, sidebar.win)
		M.refresh()
		return
	end

	local current_win = vim.api.nvim_get_current_win()
	sidebar.source_win = current_win
	sidebar.preview_dismissed = false
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
	sidebar.full_layout_active = false

	vim.api.nvim_win_set_buf(sidebar.win, sidebar.buf)
	vim.api.nvim_win_set_width(sidebar.win, preferred_sidebar_width())
	vim.wo[sidebar.win].number = false
	vim.wo[sidebar.win].relativenumber = false
	vim.wo[sidebar.win].signcolumn = "no"
	vim.wo[sidebar.win].wrap = false
	vim.wo[sidebar.win].winfixwidth = false

	M.setup_mappings(sidebar.buf)
	M.open_preview(nil)
	ensure_sidebar_panels()
	M.refresh()

	for line, item in ipairs(sidebar.line_items) do
		if item.kind == "note" then
			vim.api.nvim_win_set_cursor(sidebar.win, { line, 0 })
			update_visible_card_selection()
			M.open_preview(item.note_id)
			break
		end
	end
	rebalance_normal_layout()

	if sidebar.mode == "calendar" and is_valid_win(sidebar.calendar_notes_win) then
		vim.api.nvim_set_current_win(sidebar.calendar_notes_win)
	elseif is_valid_win(current_win) then
		vim.api.nvim_set_current_win(current_win)
	end
end

function M.full_layout()
	local sidebar = sidebar_state()
	if not sidebar.open or not is_valid_win(sidebar.win) then
		M.open()
		sidebar = sidebar_state()
	end
	focus_sidebar_tab(sidebar, is_valid_win(sidebar.preview_win) and sidebar.preview_win or sidebar.win)

	if sidebar.mode ~= "all" then
		M.set_mode("all")
		sidebar = sidebar_state()
	end
	sidebar.full_layout_active = true
	rebalance_full_layout()
	if is_valid_win(sidebar.preview_win) then
		vim.api.nvim_set_current_win(sidebar.preview_win)
	else
		vim.api.nvim_set_current_win(sidebar.win)
	end

	local managed_buffers = {}
	for _, buf in ipairs({
		sidebar.buf,
		sidebar.header_buf,
		sidebar.notebook_buf,
		sidebar.tag_buf,
		sidebar.note_header_buf,
		sidebar.preview_buf,
		sidebar.calendar_notes_buf,
	}) do
		if is_valid_buf(buf) then
			managed_buffers[buf] = true
		end
	end

	-- Closing a split can run user autocmds that create or rearrange windows.
	-- Re-evaluate the tab a few times so Full cannot leave a residual host pane.
	for _ = 1, 4 do
		local managed = layout.managed_windows(sidebar)
		local external = {}
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
			if is_valid_win(win) and vim.api.nvim_win_get_config(win).relative == "" and not managed[win] then
				table.insert(external, win)
			end
		end
		if #external == 0 then
			break
		end
		for _, win in ipairs(external) do
			if is_valid_win(win) then
				local ok, err = pcall(vim.api.nvim_win_close, win, true)
				if not ok then
					vim.notify("seijaku: cannot close another window: " .. tostring(err), vim.log.levels.WARN)
					return false
				end
			end
		end
	end
	-- Full mode is a fresh Seijaku workspace, rather than merely a different
	-- window arrangement. Remove prior, unmodified listed buffers as well.
	-- Modified buffers are intentionally retained in memory to avoid data loss.
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if
			vim.api.nvim_buf_is_valid(buf)
			and vim.bo[buf].buflisted
			and not vim.bo[buf].modified
			and not managed_buffers[buf]
		then
			pcall(vim.api.nvim_buf_delete, buf, { force = false })
		end
	end
	sidebar.note_bufs = {}
	if is_valid_buf(sidebar.preview_buf) then
		sidebar.note_bufs[sidebar.preview_buf] = true
	end

	sidebar.source_win = nil
	rebalance_full_layout()
	-- WinClosed handlers run on the next loop. Audit once after them so a
	-- scratch/host window recreated by an autocmd cannot survive Full mode.
	vim.schedule(function()
		local current = sidebar_state()
		if not current.open then
			return
		end
		local current_managed = layout.managed_windows(current)
		if is_valid_win(current.preview_win) then
			vim.api.nvim_set_current_win(current.preview_win)
		elseif is_valid_win(current.win) then
			vim.api.nvim_set_current_win(current.win)
		else
			return
		end
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
			if
				is_valid_win(win)
				and vim.api.nvim_win_get_config(win).relative == ""
				and not current_managed[win]
			then
				pcall(vim.api.nvim_win_close, win, true)
			end
		end
		rebalance_full_layout()
	end)
	return true
end

function M.close()
	local sidebar = sidebar_state()
	if sidebar.closing then
		return
	end
	sidebar.closing = true
	if sidebar.selector_saved_winwidth ~= nil then
		vim.o.winwidth = sidebar.selector_saved_winwidth
		sidebar.selector_saved_winwidth = nil
	end
	if stop_calendar_day_timer then
		stop_calendar_day_timer()
	end
	sidebar.calendar_day_input = ""

	close_preview_window()

	sidebar.note_bufs = {}
	close_calendar_notes_window()
	for _, key in ipairs({ "tag_win", "notebook_win", "header_win" }) do
		local win = sidebar[key]
		if is_valid_win(win) then
			if vim.api.nvim_get_current_win() == win and is_valid_win(sidebar.win) then
				vim.api.nvim_set_current_win(sidebar.win)
			end
			local normal_wins = layout.normal_windows()
			if #normal_wins == 1 and normal_wins[1] == win then
				-- Neovim cannot close the last window. Replace its Seijaku buffer
				-- with a scratch buffer and finish tearing down the state.
				local empty_buf = vim.api.nvim_create_buf(true, false)
				vim.api.nvim_win_set_buf(win, empty_buf)
				vim.api.nvim_set_current_win(win)
			else
				pcall(vim.api.nvim_win_close, win, true)
			end
		end
		sidebar[key] = nil
	end

	if is_valid_win(sidebar.win) then
		vim.wo[sidebar.win].winfixwidth = false
		local normal_wins = layout.normal_windows()

		if #normal_wins == 1 and normal_wins[1] == sidebar.win then
			local empty_buf = vim.api.nvim_create_buf(true, false)
			vim.api.nvim_win_set_buf(sidebar.win, empty_buf)
			vim.api.nvim_set_current_win(sidebar.win)
		else
			vim.api.nvim_win_close(sidebar.win, true)
		end
	end

	sidebar.open = false
	sidebar.full_layout_active = false
	sidebar.win = nil
	sidebar.source_win = nil
	sidebar.preview_dismissed = false
	sidebar.closing = false
end

local function set_preview_placeholder(sidebar, message)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", "  " .. message })
	vim.bo[buf].modifiable = false
	vim.api.nvim_win_set_buf(sidebar.preview_win, buf)
	sidebar.preview_buf = buf
	sidebar.preview_note_id = nil
	sidebar.note_bufs[buf] = true
end

local function notebook_header_highlight(notebook)
	if not notebook or type(notebook.color) ~= "string" or not notebook.color:match("^#%x%x%x%x%x%x$") then
		return "SeijakuTag"
	end
	local group = "SeijakuPreviewNotebook_" .. notebook.color:sub(2)
	if not notebook_hl_cache[group] then
		vim.api.nvim_set_hl(0, group, { fg = notebook.color, bg = "NONE", bold = true })
		notebook_hl_cache[group] = true
	end
	return group
end

local function render_note_header(note_id)
	local sidebar = sidebar_state()
	if not is_valid_buf(sidebar.note_header_buf) then
		return
	end
	local note = note_id and index.get_note(note_id) or nil
	local chunks = {}
	local function add(text, group)
		if #chunks > 0 then
			table.insert(chunks, { "  ", "Normal" })
		end
		table.insert(chunks, { text, group })
	end
	if note then
		if note.pinned then
			add(pin_icon:gsub("%s+$", " "), "SeijakuPinned")
		end
		local notebook = note.notebook_id and index.get_notebook(note.notebook_id) or nil
		if note.notebook_id then
			add(
				notebook_display_icon(notebook) .. " " .. (notebook and notebook.name or note.notebook_id),
				notebook_header_highlight(notebook)
			)
		end
		for _, tag in ipairs(note.tags or {}) do
			add(tag_display_icon(tag) .. " " .. tag, notes.tag_glyph_highlight(tag))
		end
	end

	local text, offset = "", 0
	for _, chunk in ipairs(chunks) do
		text = text .. chunk[1]
	end
	with_modifiable(sidebar.note_header_buf, function()
		vim.api.nvim_buf_set_lines(sidebar.note_header_buf, 0, -1, false, { text })
		vim.api.nvim_buf_clear_namespace(sidebar.note_header_buf, highlight_ns, 0, -1)
		for _, chunk in ipairs(chunks) do
			vim.api.nvim_buf_set_extmark(sidebar.note_header_buf, highlight_ns, 0, offset, {
				end_col = offset + #chunk[1],
				hl_group = chunk[2],
				hl_mode = "combine",
			})
			offset = offset + #chunk[1]
		end
	end)
end

local function ensure_note_header_window(sidebar)
	if not is_valid_win(sidebar.preview_win) then
		return
	end
	if not is_valid_buf(sidebar.note_header_buf) then
		sidebar.note_header_buf = vim.api.nvim_create_buf(false, true)
		set_sidebar_options(sidebar.note_header_buf)
	end
	if not is_valid_win(sidebar.note_header_win) then
		local current = vim.api.nvim_get_current_win()
		vim.api.nvim_set_current_win(sidebar.preview_win)
		vim.cmd("aboveleft split")
		sidebar.note_header_win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(sidebar.note_header_win, sidebar.note_header_buf)
		panel_options(sidebar.note_header_win)
		vim.api.nvim_win_set_height(sidebar.note_header_win, 1)
		vim.wo[sidebar.note_header_win].winfixheight = true
		-- Splitting the header changes the preview column geometry. Apply the
		-- configured initial width once more after the complete pair exists.
		sidebar.preview_width_initialized = false
		if is_valid_win(current) then
			vim.api.nvim_set_current_win(current)
		end
	end
end

function M.open_preview(note_id, opts)
	opts = opts or {}
	local sidebar = sidebar_state()
	if not sidebar.open or not is_valid_win(sidebar.win) then
		return false
	end
	if not is_valid_win(sidebar.preview_win) and sidebar.preview_dismissed and not opts.reopen then
		return false
	end

	if note_id == sidebar.preview_note_id and is_valid_win(sidebar.preview_win) then
		render_note_header(note_id)
		if opts.focus then
			vim.api.nvim_set_current_win(sidebar.preview_win)
		end
		return true
	end

	local return_win = vim.api.nvim_get_current_win()
	if not is_valid_win(sidebar.preview_win) then
		local position = state_mod.get().config.sidebar.position or "right"
		local external_side = position == "left" and "right" or "left"
		local anchor = adjacent_external_window(sidebar, sidebar.win, external_side)
		if is_valid_win(anchor) then
			vim.api.nvim_set_current_win(anchor)
			vim.cmd(position == "left" and "leftabove vsplit" or "rightbelow vsplit")
		else
			-- With only the sidebar left, split it and lift the preview out of the
			-- sidebar's internal header/list tree into a full-height column.
			vim.api.nvim_set_current_win(sidebar.win)
			vim.cmd(position == "left" and "rightbelow vsplit" or "leftabove vsplit")
			vim.cmd(position == "left" and "wincmd L" or "wincmd H")
		end
		sidebar.preview_win = vim.api.nvim_get_current_win()
		sidebar.preview_width_initialized = false
		vim.wo[sidebar.preview_win].winfixwidth = false
		set_preview_placeholder(sidebar, "Select a note")
		sidebar.preview_dismissed = false
		-- Split creation may donate columns back to the sidebar group. Restore
		-- its compact invariant immediately and once more after Neovim settles.
		rebalance_normal_layout()
		schedule_layout_rebalance()
	end
	ensure_note_header_window(sidebar)

	local note = note_id and index.get_note(note_id) or nil
	if note then
		local abs_path = paths.join(state_mod.get().vault_dir, note.file)
		if vim.fn.filereadable(abs_path) == 0 then
			set_preview_placeholder(sidebar, "Note file is missing")
			render_note_header(nil)
			if opts.focus then
				vim.api.nvim_set_current_win(sidebar.preview_win)
			elseif is_valid_win(return_win) then
				vim.api.nvim_set_current_win(return_win)
			end
			return false
		end
		local buf = vim.fn.bufadd(abs_path)
		local loaded = pcall(vim.fn.bufload, buf)
		if not loaded then
			set_preview_placeholder(sidebar, "Unable to load note")
			render_note_header(nil)
			return false
		end
		notes.clean_legacy_metadata(note, buf)
		vim.api.nvim_win_set_buf(sidebar.preview_win, buf)
		sidebar.preview_buf = buf
		sidebar.preview_note_id = note_id
		sidebar.note_bufs[buf] = true
		notes.apply_window_options(sidebar.preview_win)
		render_note_header(note_id)
	else
		render_note_header(nil)
	end
	if opts.focus and is_valid_win(sidebar.preview_win) then
		vim.api.nvim_set_current_win(sidebar.preview_win)
	elseif is_valid_win(return_win) then
		vim.api.nvim_set_current_win(return_win)
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
		-- Keep the persistent preview stable when a filter has no results.
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
		local owner_tab = sidebar_tabpage(sidebar)
		if owner_tab and owner_tab ~= vim.api.nvim_get_current_tabpage() then
			focus_sidebar_tab(sidebar, sidebar.win)
		else
			M.close()
		end
	else
		M.open()
	end
end

function M.handle_enter()
	local sidebar = sidebar_state()

	if sidebar.mode == "calendar" then
		if sidebar.calendar_day_input and sidebar.calendar_day_input ~= "" then
			apply_calendar_day_input()
			return
		end
		if is_valid_win(sidebar.calendar_notes_win) then
			vim.api.nvim_set_current_win(sidebar.calendar_notes_win)
			for line = 1, #(sidebar.calendar_notes_lines or {}) do
				local item = sidebar.calendar_notes_items[line]
				if item and item.kind == "note" then
					vim.api.nvim_win_set_cursor(sidebar.calendar_notes_win, { line, 0 })
					break
				end
			end
		end
		return
	end

	local item = selected_item()
	if item and item.kind == "note" then
		M.open_preview(item.note_id, { focus = true, reopen = true })
	end
end

function M.handle_create()
	notes.create({
		calendar_date = sidebar_state().mode == "calendar" and sidebar_state().calendar_date or nil,
	})
end

local function rename_item(item)
	if not item then
		return
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

local function active_note_item()
	local sidebar = sidebar_state()
	if sidebar.mode == "calendar" and vim.api.nvim_get_current_buf() == sidebar.calendar_notes_buf then
		return selected_calendar_note_item()
	end
	return selected_item()
end

function M.handle_tags()
	local item = active_note_item()
	if not item or item.kind ~= "note" then
		return
	end
	local note = index.get_note(item.note_id)
	if not note then
		return
	end
	notes.select_tags(note.tags or {}, function(tags)
		local ok, err = index.set_tags(note.id, tags)
		if not ok then
			vim.notify("seijaku: " .. tostring(err), vim.log.levels.ERROR)
			return
		end
		M.refresh()
	end)
end

function M.handle_notebook()
	local item = active_note_item()
	if not item or item.kind ~= "note" then
		return
	end
	local note = index.get_note(item.note_id)
	if not note then
		return
	end

	local choices = {
		{ value = false, label = "No notebook", icon = "·", highlight = "SeijakuSelectorAll" },
	}
	for _, notebook in ipairs(index.list_notebooks()) do
		table.insert(choices, {
			value = notebook.id,
			label = notebook.name,
			icon = notebook_display_icon(notebook),
			color = notebook.color,
		})
	end
	picker.select(choices, {
		title = " notebook ",
		initial_value = note.notebook_id or false,
	}, function(choice)
		if not choice then
			return
		end
		local notebook_id = choice.value or nil
		local ok, err = index.assign_notebook(note.id, notebook_id)
		if not ok then
			vim.notify("seijaku: " .. tostring(err), vim.log.levels.ERROR)
			return
		end
		M.refresh()
	end)
end

local function assign_inferred_notebook(note, target_path)
	if note.notebook_id then
		return
	end
	local notebook = index.notebook_for_target_path(target_path)
	if not notebook then
		return
	end
	local assigned, err = index.assign_notebook(note.id, notebook.id)
	if not assigned then
		vim.notify("seijaku: " .. tostring(err), vim.log.levels.WARN)
	end
end

function M.handle_attach_target()
	local item = active_note_item()
	if not item or item.kind ~= "note" then
		return
	end
	local note = index.get_note(item.note_id)
	if not note then
		return
	end
	local initial = note.targets and note.targets[1] and note.targets[1].path or ""
	picker.browse_path(initial, function(selected_path)
		if selected_path == nil or selected_path == "" then
			return
		end
		local target_path = paths.normalize(selected_path)
		if not target_path then
			vim.notify("seijaku: invalid target path", vim.log.levels.ERROR)
			return
		end
		local ok, err = index.attach(note.id, target_path, paths.target_type(target_path))
		if not ok then
			vim.notify("seijaku: " .. tostring(err), vim.log.levels.ERROR)
			return
		end
		assign_inferred_notebook(note, target_path)
		M.refresh()
	end)
end

function M.handle_replace_target()
	local item = active_note_item()
	if not item or item.kind ~= "note" then
		return
	end
	local note = index.get_note(item.note_id)
	if not note then
		return
	end
	local initial = note.targets and note.targets[1] and note.targets[1].path or ""
	picker.browse_path(initial, function(selected_path)
		if selected_path == nil or selected_path == "" then
			return
		end
		local target_path = paths.normalize(selected_path)
		if not target_path then
			vim.notify("seijaku: invalid target path", vim.log.levels.ERROR)
			return
		end
		local ok, err = index.set_target(note.id, target_path, paths.target_type(target_path))
		if not ok then
			vim.notify("seijaku: " .. tostring(err), vim.log.levels.ERROR)
			return
		end
		assign_inferred_notebook(note, target_path)
		M.refresh()
	end)
end

function M.handle_pin()
	local item = active_note_item()
	if not item or item.kind ~= "note" then
		return
	end
	local ok, pinned = index.toggle_pin(item.note_id)
	if not ok then
		return
	end
	vim.notify("seijaku: note " .. (pinned and "pinned" or "unpinned"))
	M.refresh()
end

local function edit_notebook(notebook)
	if not notebook then
		return
	end
	picker.input({ title = " notebook name ", default = notebook.name }, function(name)
		if not name then
			return
		end
		picker.browse_path(notebook.path or "", function(path)
			if path == nil then
				return
			end
			picker.input(
				{ title = " notebook icon · optional ", default = notebook_display_icon(notebook), allow_empty = true },
				function(icon)
					if icon == nil then
						return
					end
					picker.input(
						{ title = " notebook color · #RRGGBB ", default = notebook.color or "", allow_empty = false },
						function(color)
							if not color then
								return
							end
							local ok, err = index.update_notebook(notebook.id, {
								name = name,
								path = path,
								icon = icon ~= "" and icon or false,
								color = color,
							})
							if not ok then
								vim.notify("seijaku: " .. tostring(err), vim.log.levels.ERROR)
								return
							end
							M.refresh()
						end
					)
				end
			)
		end)
	end)
end

local function edit_tag(tag)
	if not tag then
		return
	end
	picker.input({ title = " tag name ", default = tag }, function(name)
		if not name then
			return
		end
		picker.input(
			{ title = " tag icon · optional ", default = tag_display_icon(tag), allow_empty = true },
			function(icon)
				if icon == nil then
					return
				end
				picker.input(
					{ title = " tag color · #RRGGBB ", default = index.get_tag_color(tag) or "", allow_empty = false },
					function(color)
						if not color then
							return
						end
						local ok, err = index.rename_tag(tag, name)
						if not ok then
							vim.notify("seijaku: " .. tostring(err), vim.log.levels.ERROR)
							return
						end
						ok, err = index.set_tag_icon(name, icon ~= "" and icon or false)
						if not ok then
							vim.notify("seijaku: " .. tostring(err), vim.log.levels.ERROR)
							return
						end
						ok, err = index.set_tag_color(name, color)
						if not ok then
							vim.notify("seijaku: " .. tostring(err), vim.log.levels.ERROR)
							return
						end
						local sidebar = sidebar_state()
						if sidebar.all_tag == tag then
							sidebar.all_tag = vim.trim(name):lower()
						end
						M.refresh()
					end
				)
			end
		)
	end)
end

local function create_notebook_from_selector()
	picker.input({ title = " notebook name " }, function(name)
		if not name then
			return
		end
		picker.browse_path("", function(path)
			if path == nil then
				return
			end
			picker.input(
				{ title = " notebook icon · optional ", default = default_notebook_icon, allow_empty = true },
				function(icon)
					if icon == nil then
						return
					end
					picker.input(
						{ title = " notebook color · #RRGGBB · optional ", allow_empty = true },
						function(color)
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
								vim.notify("seijaku: " .. tostring(err), vim.log.levels.ERROR)
								return
							end
							M.refresh()
						end
					)
				end
			)
		end)
	end)
end

local function create_tag_from_selector()
	picker.input({ title = " tag name " }, function(name)
		if not name then
			return
		end
		picker.input(
			{ title = " tag icon · optional ", default = tag_icon, allow_empty = true },
			function(icon)
				if icon == nil then
					return
				end
				picker.input(
					{ title = " tag color · #RRGGBB ", default = "#cc5555", allow_empty = false },
					function(color)
						if not color then
							return
						end
						local ok, err = index.set_tag_color(name, color)
						if not ok then
							vim.notify("seijaku: " .. tostring(err), vim.log.levels.ERROR)
							return
						end
						ok, err = index.set_tag_icon(name, icon ~= "" and icon or false)
						if not ok then
							vim.notify("seijaku: " .. tostring(err), vim.log.levels.ERROR)
							return
						end
						M.refresh()
					end
				)
			end
		)
	end)
end

local function delete_notebook_from_selector()
	local sidebar = sidebar_state()
	local item = sidebar.notebook_items[vim.api.nvim_win_get_cursor(0)[1]]
	local notebook = item and not item.all and index.get_notebook(item.id) or nil
	if not notebook then
		return
	end
	if vim.fn.confirm("Delete notebook '" .. notebook.name .. "'? Notes stay intact.", "&Delete\n&Cancel", 2) ~= 1 then
		return
	end
	local ok, err = index.delete_notebook(notebook.id)
	if not ok then
		vim.notify("seijaku: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	if sidebar.all_notebook == notebook.id then
		sidebar.all_notebook = "all"
	end
	M.refresh()
end

local function delete_tag_from_selector()
	local sidebar = sidebar_state()
	local item = sidebar.tag_items[vim.api.nvim_win_get_cursor(0)[1]]
	local tag = item and not item.all and item.tag or nil
	if not tag then
		return
	end
	if vim.fn.confirm("Delete tag '" .. tag .. "'? Notes stay intact.", "&Delete\n&Cancel", 2) ~= 1 then
		return
	end
	local ok, err = index.delete_tag(tag)
	if not ok then
		vim.notify("seijaku: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	if sidebar.all_tag == tag then
		sidebar.all_tag = "all"
	end
	M.refresh()
end

local function open_path_in_oil(target_path)
	local stat = (vim.uv or vim.loop).fs_stat(target_path)
	if not stat then
		vim.notify("seijaku: target no longer exists: " .. target_path, vim.log.levels.WARN)
		return false
	end
	if state_mod.get().config.integrations and state_mod.get().config.integrations.oil == false then
		vim.notify("seijaku: Oil integration is disabled", vim.log.levels.WARN)
		return false
	end
	local ok, oil = pcall(require, "oil")
	if not ok then
		vim.notify("seijaku: oil.nvim is not available", vim.log.levels.WARN)
		return false
	end

	local sidebar = sidebar_state()
	-- Use the pane immediately before the preview (or before the sidebar while
	-- the preview is closed) as the insertion anchor. This preserves the stable
	-- order `editors | Oil | preview | sidebar` for both notes and notebooks.
	local reference = is_valid_win(sidebar.preview_win) and sidebar.preview_win or sidebar.win
	local destination = adjacent_external_window(sidebar, reference, "left")
	if not destination then
		if is_valid_win(sidebar.source_win) and not layout.managed_windows(sidebar)[sidebar.source_win] then
			destination = sidebar.source_win
		else
			destination = layout.external_windows(sidebar)[1]
		end
	end
	local created_win = nil
	if destination then
		vim.api.nvim_set_current_win(destination)
		-- Preserve an existing editor buffer. Reuse the adjacent Oil pane when
		-- there already is one; otherwise insert a fresh pane immediately before
		-- the preview/sidebar column.
		local destination_buf = vim.api.nvim_win_get_buf(destination)
		local reuse_oil = stat.type == "directory" and vim.bo[destination_buf].filetype == "oil"
		if not reuse_oil then
			vim.cmd("rightbelow vsplit")
			created_win = vim.api.nvim_get_current_win()
		end
	else
		vim.api.nvim_set_current_win(is_valid_win(sidebar.preview_win) and sidebar.preview_win or sidebar.win)
		vim.cmd("leftabove vsplit")
		vim.cmd("wincmd H")
		created_win = vim.api.nvim_get_current_win()
	end
	local opened, err = pcall(oil.open, target_path)
	if not opened then
		if is_valid_win(created_win) then
			pcall(vim.api.nvim_win_close, created_win, true)
		end
		vim.notify("seijaku: failed to open target in Oil: " .. tostring(err), vim.log.levels.ERROR)
		return false
	end
	-- Only restore the fixed sidebar shell. Oil and the Markdown preview remain
	-- ordinary flexible panes, so Neovim can distribute the remaining space.
	rebalance_normal_layout()
	schedule_layout_rebalance()
	return true
end

function M.handle_open_target()
	local item = active_note_item()
	if not item or item.kind ~= "note" then
		return
	end
	local entity = index.get_note(item.note_id)
	local target_path = item.target_path or (entity and entity.targets and entity.targets[1] and entity.targets[1].path)
	if not target_path then
		vim.notify("seijaku: this item has no filesystem target", vim.log.levels.INFO)
		return
	end
	open_path_in_oil(target_path)
end

function M.handle_open_notebook_target()
	local sidebar = sidebar_state()
	local item = sidebar.notebook_items[vim.api.nvim_win_get_cursor(0)[1]]
	local notebook = item and not item.all and index.get_notebook(item.id) or nil
	if not notebook then
		return
	end
	if not notebook.path then
		vim.notify("seijaku: notebook has no working directory", vim.log.levels.INFO)
		return
	end
	open_path_in_oil(notebook.path)
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
		vim.notify("seijaku: no target to detach from this item", vim.log.levels.WARN)
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

function M.prompt_title_filter()
	local sidebar = sidebar_state()
	if not is_valid_win(sidebar.header_win) or not is_valid_buf(sidebar.header_buf) then
		return
	end
	sidebar.search_active = true
	vim.api.nvim_buf_set_lines(sidebar.header_buf, 0, -1, false, { sidebar.title_filter or "" })
	vim.api.nvim_set_current_win(sidebar.header_win)
	vim.api.nvim_win_set_cursor(sidebar.header_win, { 1, #(sidebar.title_filter or "") })
	vim.cmd("startinsert")
end

function M.finish_title_filter()
	local sidebar = sidebar_state()
	-- `<CR>` is pressed from Insert mode in the search field. Leave that mode
	-- before moving to the immutable note list, otherwise Insert follows focus.
	pcall(vim.cmd, "stopinsert")
	sidebar.search_active = false
	if is_valid_win(sidebar.win) then
		vim.api.nvim_set_current_win(sidebar.win)
	end
	M.refresh()
end

function M.sync_title_filter_from_header()
	local sidebar = sidebar_state()
	if not sidebar.search_active or not is_valid_buf(sidebar.header_buf) then
		return
	end
	sidebar.title_filter = vim.trim(vim.api.nvim_buf_get_lines(sidebar.header_buf, 0, 1, false)[1] or "")
	M.refresh()
end

function M.calendar_move_days(amount)
	local sidebar = sidebar_state()
	stop_calendar_day_timer()
	sidebar.calendar_day_input = ""
	local selected = calendar.parse(sidebar.calendar_date) or calendar.today()
	local result = calendar.add_days(selected, amount)
	sidebar.calendar_date = calendar.format(result.year, result.month, result.day)
	M.refresh()
end

function M.calendar_move_months(amount)
	local sidebar = sidebar_state()
	stop_calendar_day_timer()
	sidebar.calendar_day_input = ""
	local selected = calendar.parse(sidebar.calendar_date) or calendar.today()
	local result = calendar.add_months(selected, amount)
	sidebar.calendar_date = calendar.format(result.year, result.month, result.day)
	M.refresh()
end

function M.calendar_today()
	stop_calendar_day_timer()
	sidebar_state().calendar_day_input = ""
	local today = calendar.today()
	sidebar_state().calendar_date = calendar.format(today.year, today.month, today.day)
	M.refresh()
end

function M.all_today()
	local sidebar = sidebar_state()
	if sidebar.mode ~= "all" or not is_valid_win(sidebar.win) then
		return false
	end

	local today = calendar.today()
	local today_key = calendar.format(today.year, today.month, today.day)
	for line = 1, #(sidebar.lines or {}) do
		local item = sidebar.line_items[line]
		if item and item.kind == "note" then
			local note = index.get_note(item.note_id)
			if note and index.calendar_date(note) == today_key then
				pcall(vim.api.nvim_win_set_cursor, sidebar.win, { line, 0 })
				vim.api.nvim_win_call(sidebar.win, function()
					vim.cmd("normal! zt")
				end)
				M.preview_selected()
				return true
			end
		end
	end

	vim.notify("seijaku: no notes for today in the current list", vim.log.levels.INFO)
	return false
end

function M.go_to_today()
	if sidebar_state().mode == "calendar" then
		M.calendar_today()
	elseif sidebar_state().mode == "all" then
		M.all_today()
	end
end

function M.calendar_month_edge(last)
	local sidebar = sidebar_state()
	stop_calendar_day_timer()
	sidebar.calendar_day_input = ""
	local selected = calendar.parse(sidebar.calendar_date) or calendar.today()
	selected.day = last and calendar.days_in_month(selected.year, selected.month) or 1
	sidebar.calendar_date = calendar.format(selected.year, selected.month, selected.day)
	M.refresh()
end

stop_calendar_day_timer = function()
	if calendar_day_timer then
		calendar_day_timer:stop()
		if not calendar_day_timer:is_closing() then
			calendar_day_timer:close()
		end
		calendar_day_timer = nil
	end
end

apply_calendar_day_input = function()
	stop_calendar_day_timer()
	local sidebar = sidebar_state()
	local pending = sidebar.calendar_day_input or ""
	sidebar.calendar_day_input = ""
	local day = tonumber(pending)
	local selected = calendar.parse(sidebar.calendar_date) or calendar.today()
	if not day or not calendar.is_valid(selected.year, selected.month, day) then
		M.refresh()
		if pending ~= "" then
			vim.notify("seijaku: invalid day " .. pending, vim.log.levels.INFO)
		end
		return false
	end
	sidebar.calendar_date = calendar.format(selected.year, selected.month, day)
	M.refresh()
	return true
end

function M.calendar_day_digit(digit)
	local sidebar = sidebar_state()
	if sidebar.mode ~= "calendar" then
		vim.api.nvim_feedkeys(tostring(digit), "n", false)
		return
	end

	stop_calendar_day_timer()
	local pending = (sidebar.calendar_day_input or "") .. tostring(digit)
	if #pending > 2 then
		pending = tostring(digit)
	end
	sidebar.calendar_day_input = pending

	local numeric = tonumber(pending)
	if #pending == 2 or (#pending == 1 and numeric and numeric >= 4) then
		apply_calendar_day_input()
		return
	end

	M.refresh()
	local uv = vim.uv or vim.loop
	calendar_day_timer = uv.new_timer()
	calendar_day_timer:start(
		600,
		0,
		vim.schedule_wrap(function()
			apply_calendar_day_input()
		end)
	)
end

function M.cancel_calendar_day_input()
	stop_calendar_day_timer()
	if sidebar_state().calendar_day_input ~= "" then
		sidebar_state().calendar_day_input = ""
		M.refresh()
		return true
	end
	return false
end

function M.handle_calendar_note_enter()
	local item = selected_calendar_note_item()

	if item and item.kind == "note" then
		M.open_preview(item.note_id, { focus = true, reopen = true })
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

local function move_list_selection(win, items, direction)
	if not is_valid_win(win) then
		return
	end
	local current = vim.api.nvim_win_get_cursor(win)[1]
	for _ = 1, vim.v.count1 do
		local selected = items[current]
		local selected_id = selected and selected.note_id
		local line = current + direction
		local found = nil
		while line >= 1 and line <= #items do
			local item = items[line]
			local item_id = item and item.note_id
			if item_id and (item_id ~= selected_id or item.kind ~= selected.kind) then
				found = line
				break
			end
			line = line + direction
		end
		if not found then
			break
		end
		current = found
	end
	vim.api.nvim_win_set_cursor(win, { current, 0 })
	update_visible_card_selection()
	if sidebar_state().mode == "calendar" then
		vim.schedule(M.preview_calendar_note_selected)
	else
		vim.schedule(M.preview_selected)
	end
end

local function sidebar_vertical_move(direction)
	local sidebar = sidebar_state()
	if sidebar.mode == "calendar" then
		M.calendar_move_days(direction * 7 * vim.v.count1)
	elseif sidebar.mode == "all" then
		move_list_selection(sidebar.win, sidebar.line_items, direction)
	else
		vim.cmd("normal! " .. (direction < 0 and "k" or "j"))
	end
end

local function return_to_note_list()
	local sidebar = sidebar_state()
	local destination = sidebar.win
	if sidebar.mode == "calendar" and is_valid_win(sidebar.calendar_notes_win) then
		destination = sidebar.calendar_notes_win
	end
	if is_valid_win(destination) then
		vim.api.nvim_set_current_win(destination)
	end
end

function M.setup_notebook_mappings(buf)
	local opts = { buffer = buf, silent = true, nowait = true }
	local function apply_hovered_notebook()
		local sidebar = sidebar_state()
		if vim.api.nvim_get_current_win() ~= sidebar.notebook_win then
			return
		end
		local item = sidebar.notebook_items[vim.api.nvim_win_get_cursor(0)[1]]
		if item and sidebar.all_notebook ~= item.id then
			sidebar.all_notebook = item.id
			M.refresh()
			M.sync_mode_preview(true)
		end
	end
	vim.keymap.set("n", "<CR>", function()
		return_to_note_list()
	end, opts)
	vim.keymap.set("n", "r", function()
		local item = sidebar_state().notebook_items[vim.api.nvim_win_get_cursor(0)[1]]
		if item and not item.all then
			edit_notebook(index.get_notebook(item.id))
		end
	end, opts)
	vim.keymap.set("n", "dd", delete_notebook_from_selector, opts)
	vim.keymap.set("n", "n", create_notebook_from_selector, opts)
	vim.keymap.set("n", "o", M.handle_open_notebook_target, opts)
	vim.keymap.set("n", "<Space>", function()
		local sidebar = sidebar_state()
		local item = sidebar.notebook_items[vim.api.nvim_win_get_cursor(0)[1]]
		if item then
			sidebar.all_notebook = item.id
			M.refresh()
			M.sync_mode_preview(true)
		end
	end, opts)
	vim.keymap.set("n", "<Tab>", function()
		M.cycle_notebook(1)
	end, opts)
	vim.keymap.set("n", "<S-Tab>", function()
		M.cycle_notebook(-1)
	end, opts)
	vim.keymap.set("n", "f", function()
		M.cycle_tag(1)
	end, opts)
	vim.keymap.set("n", "F", function()
		M.cycle_tag(-1)
	end, opts)
	vim.keymap.set("n", "C", M.toggle_mode, opts)
	vim.api.nvim_create_autocmd("CursorMoved", {
		buffer = buf,
		callback = apply_hovered_notebook,
	})
end

function M.setup_header_mappings(buf)
	local opts = { buffer = buf, silent = true, nowait = true }
	vim.keymap.set("i", "<Esc>", function()
		vim.cmd("stopinsert")
		M.finish_title_filter()
	end, opts)
	vim.keymap.set("i", "<CR>", function()
		M.finish_title_filter()
	end, opts)
	vim.keymap.set("n", "<CR>", M.finish_title_filter, opts)
	vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
		buffer = buf,
		callback = M.sync_title_filter_from_header,
	})
end

function M.setup_tag_mappings(buf)
	local opts = { buffer = buf, silent = true, nowait = true }
	local function apply_hovered_tag()
		local sidebar = sidebar_state()
		if vim.api.nvim_get_current_win() ~= sidebar.tag_win then
			return
		end
		local item = sidebar.tag_items[vim.api.nvim_win_get_cursor(0)[1]]
		if item and sidebar.all_tag ~= item.tag then
			sidebar.all_tag = item.tag
			M.refresh()
			M.sync_mode_preview(true)
		end
	end
	vim.keymap.set("n", "<CR>", function()
		return_to_note_list()
	end, opts)
	vim.keymap.set("n", "r", function()
		local item = sidebar_state().tag_items[vim.api.nvim_win_get_cursor(0)[1]]
		if item and not item.all then
			edit_tag(item.tag)
		end
	end, opts)
	vim.keymap.set("n", "dd", delete_tag_from_selector, opts)
	vim.keymap.set("n", "n", create_tag_from_selector, opts)
	vim.keymap.set("n", "<Space>", function()
		local sidebar = sidebar_state()
		local item = sidebar.tag_items[vim.api.nvim_win_get_cursor(0)[1]]
		if item then
			sidebar.all_tag = item.tag
			M.refresh()
			M.sync_mode_preview(true)
		end
	end, opts)
	vim.keymap.set("n", "f", function()
		M.cycle_tag(1)
	end, opts)
	vim.keymap.set("n", "F", function()
		M.cycle_tag(-1)
	end, opts)
	vim.keymap.set("n", "<Tab>", function()
		M.cycle_notebook(1)
	end, opts)
	vim.keymap.set("n", "<S-Tab>", function()
		M.cycle_notebook(-1)
	end, opts)
	vim.keymap.set("n", "C", M.toggle_mode, opts)
	vim.keymap.set("n", "/", M.prompt_title_filter, opts)
	vim.api.nvim_create_autocmd("CursorMoved", {
		buffer = buf,
		callback = apply_hovered_tag,
	})
end

function M.setup_calendar_notes_mappings(buf)
	local opts = {
		buffer = buf,
		silent = true,
		nowait = true,
	}
	for _, lhs in ipairs({ "i", "I", "A", "c", "S" }) do
		vim.keymap.set({ "n", "x" }, lhs, "<Nop>", opts)
	end
	for _, lhs in ipairs({ "gi", "gI", "<Insert>" }) do
		vim.keymap.set("n", lhs, "<Nop>", opts)
	end
	vim.api.nvim_create_autocmd("InsertEnter", {
		buffer = buf,
		callback = function()
			vim.schedule(function()
				if vim.api.nvim_get_current_buf() == buf then
					vim.cmd("stopinsert")
				end
			end)
		end,
	})

	vim.keymap.set("n", "<CR>", M.handle_calendar_note_enter, opts)
	vim.keymap.set("n", "a", M.handle_attach_target, opts)
	vim.keymap.set("n", "n", M.handle_create, opts)
	vim.keymap.set("n", "x", M.handle_calendar_clear_date, opts)
	vim.keymap.set("n", "r", M.handle_calendar_rename, opts)
	vim.keymap.set("n", "T", M.handle_tags, opts)
	vim.keymap.set("n", "N", M.handle_notebook, opts)
	vim.keymap.set("n", "p", M.handle_pin, opts)
	vim.keymap.set("n", "o", M.handle_open_target, opts)
	vim.keymap.set("n", "O", M.handle_replace_target, opts)
	vim.keymap.set("n", "dd", M.handle_calendar_delete, opts)
	vim.keymap.set("n", "<Tab>", M.toggle_all_notebook, opts)
	vim.keymap.set("n", "<S-Tab>", function()
		M.cycle_notebook(-1)
	end, opts)
	vim.keymap.set("n", "f", function()
		M.cycle_tag(1)
	end, opts)
	vim.keymap.set("n", "F", function()
		M.cycle_tag(-1)
	end, opts)
	vim.keymap.set("n", "C", M.toggle_mode, opts)
	vim.keymap.set("n", "/", M.prompt_title_filter, opts)
	vim.keymap.set("n", "R", M.refresh, opts)
	vim.keymap.set("n", "j", function()
		move_list_selection(sidebar_state().calendar_notes_win, sidebar_state().calendar_notes_items, 1)
	end, opts)
	vim.keymap.set("n", "k", function()
		move_list_selection(sidebar_state().calendar_notes_win, sidebar_state().calendar_notes_items, -1)
	end, opts)
	vim.keymap.set("n", "<Down>", function()
		move_list_selection(sidebar_state().calendar_notes_win, sidebar_state().calendar_notes_items, 1)
	end, opts)
	vim.keymap.set("n", "<Up>", function()
		move_list_selection(sidebar_state().calendar_notes_win, sidebar_state().calendar_notes_items, -1)
	end, opts)

	vim.api.nvim_create_autocmd("CursorMoved", {
		buffer = buf,
		callback = function()
			update_visible_card_selection()
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
	vim.keymap.set("n", "a", M.handle_attach_target, opts)
	vim.keymap.set("n", "x", M.handle_detach_current, opts)
	vim.keymap.set("n", "r", M.handle_rename, opts)
	vim.keymap.set("n", "dd", M.handle_delete, opts)
	vim.keymap.set("n", "<Tab>", M.toggle_all_notebook, opts)
	vim.keymap.set("n", "<S-Tab>", function()
		M.cycle_notebook(-1)
	end, opts)
	vim.keymap.set("n", "C", M.toggle_mode, opts)
	vim.keymap.set("n", "s", M.toggle_all_sort, opts)
	vim.keymap.set("n", "f", function()
		M.cycle_tag(1)
	end, opts)
	vim.keymap.set("n", "F", function()
		M.cycle_tag(-1)
	end, opts)
	vim.keymap.set("n", "N", M.handle_notebook, opts)
	vim.keymap.set("n", "T", M.handle_tags, opts)
	vim.keymap.set("n", "p", M.handle_pin, opts)
	vim.keymap.set("n", "o", M.handle_open_target, opts)
	vim.keymap.set("n", "O", M.handle_replace_target, opts)
	vim.keymap.set("n", "/", M.prompt_title_filter, opts)
	vim.keymap.set("n", "g/", M.handle_live_grep, opts)
	vim.keymap.set("n", "R", M.refresh, opts)
	for _, lhs in ipairs({ "i", "I", "A", "c", "S" }) do
		vim.keymap.set({ "n", "x" }, lhs, "<Nop>", opts)
	end
	for _, lhs in ipairs({ "gi", "gI", "<Insert>" }) do
		vim.keymap.set("n", lhs, "<Nop>", opts)
	end
	vim.api.nvim_create_autocmd("InsertEnter", {
		buffer = buf,
		callback = function()
			vim.schedule(function()
				if vim.api.nvim_get_current_buf() == buf then
					vim.cmd("stopinsert")
				end
			end)
		end,
	})
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
		sidebar_vertical_move(-1)
	end, opts)
	vim.keymap.set("n", "j", function()
		sidebar_vertical_move(1)
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
		sidebar_vertical_move(-1)
	end, opts)
	vim.keymap.set("n", "<Down>", function()
		sidebar_vertical_move(1)
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
		M.go_to_today()
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
	for digit = 0, 9 do
		local value = digit
		vim.keymap.set("n", tostring(value), function()
			M.calendar_day_digit(value)
		end, opts)
	end
	vim.keymap.set("n", "<Esc>", function()
		if not M.cancel_calendar_day_input() then
			vim.cmd("nohlsearch")
		end
	end, opts)

	vim.api.nvim_create_autocmd("CursorMoved", {
		buffer = buf,
		callback = function()
			update_visible_card_selection()
			vim.schedule(M.preview_selected)
		end,
	})
end

return M
