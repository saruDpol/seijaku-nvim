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

  return state_mod.get().config.sidebar.width or 40
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

  if target_type == "directory" then
    return "/" .. basename
  end

  return basename
end

local function add_header(lines, line_items, title)
  local start = #lines + 1
  local width = sidebar_width()
  local rule = string.rep("─", math.max(8, math.min(width, 36)))

  table.insert(lines, center("静寂", width))
  table.insert(lines, center("seijaku", width))
  table.insert(lines, center(rule, width))
  table.insert(lines, center("a add  x detach  n new", width))
  table.insert(lines, center("r rename  dd delete", width))
  table.insert(lines, center("m mode  R refresh", width))
  table.insert(lines, "")
  table.insert(lines, title and truncate_left(title, width) or "")
  table.insert(lines, "")

  line_items[start] = { kind = "header" }
  line_items[start + 1] = { kind = "subheader" }
  line_items[start + 2] = { kind = "rule" }
  line_items[start + 3] = { kind = "help" }
  line_items[start + 4] = { kind = "help" }
  line_items[start + 5] = { kind = "help" }
  line_items[start + 6] = { kind = "spacer" }
  line_items[start + 7] = { kind = "section" }
  line_items[start + 8] = { kind = "spacer" }
end

local function apply_highlights()
  local sidebar = sidebar_state()

  if not is_valid_buf(sidebar.buf) then
    return
  end

  vim.api.nvim_buf_clear_namespace(sidebar.buf, highlight_ns, 0, -1)
  vim.api.nvim_set_hl(0, "SeijakuHeader", { bold = true })
  vim.api.nvim_set_hl(0, "SeijakuSubheader", { link = "Comment" })
  vim.api.nvim_set_hl(0, "SeijakuHelp", { link = "Comment" })
  vim.api.nvim_set_hl(0, "SeijakuSection", { link = "Title" })
  vim.api.nvim_set_hl(0, "SeijakuTarget", { link = "Directory" })

  local highlight_by_kind = {
    header = "SeijakuHeader",
    subheader = "SeijakuSubheader",
    rule = "SeijakuHelp",
    help = "SeijakuHelp",
    section = "SeijakuSection",
    target = "SeijakuTarget",
  }

  for line, item in pairs(sidebar.line_items or {}) do
    local group = item and highlight_by_kind[item.kind]

    if group then
      vim.api.nvim_buf_set_extmark(sidebar.buf, highlight_ns, line - 1, 0, {
        line_hl_group = group,
        priority = 100,
      })
    end
  end
end

local function note_line(note)
  local title = note.title or note.id
  local target_count = #(note.targets or {})

  if target_count > 0 then
    return string.format("  %s [%d]", title, target_count)
  end

  return "  " .. title
end

local function target_label(target_path)
  local target_type = paths.target_type(target_path)
  local width = math.max(8, sidebar_width() - 2)
  local label = truncate_left(target_name(target_path), width)

  if target_type == "directory" then
    return "▾ " .. label
  end

  if target_type == "file" then
    return "• " .. label
  end

  return "· " .. label
end

function M.render_all()
  local state = state_mod.get()
  local limit = state.config.sidebar.all_mode_limit or 500
  local all_notes = index.list_notes()
  local lines = {}
  local line_items = {}

  add_header(lines, line_items, "すべて")

  if #all_notes == 0 then
    table.insert(lines, "No notes yet")
  else
    for i, note in ipairs(all_notes) do
      if i > limit then
        table.insert(lines, "")
        table.insert(lines, string.format("Showing %d of %d notes", limit, #all_notes))
        break
      end

      table.insert(lines, note_line(note))
      line_items[#lines] = {
        kind = "note",
        note_id = note.id,
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
    target_paths = vim.deepcopy(state_mod.get().target_paths_by_dir[current_target] or {})
  else
    target_paths = { current_target }
  end

  if #target_paths == 0 then
    table.insert(lines, current_type == "file" and "No notes for this file" or "No notes for this directory")
    return lines, line_items
  end

  table.sort(target_paths)

  local shown = 0

  for _, target_path in ipairs(target_paths) do
    local target_notes = index.get_notes_for_target(target_path)

    if #target_notes > 0 then
      shown = shown + 1
      table.insert(lines, target_label(target_path))
      line_items[#lines] = {
        kind = "target",
        target_path = target_path,
      }

      table.sort(target_notes, function(a, b)
        return tostring(a.updated_at or "") > tostring(b.updated_at or "")
      end)

      for _, note in ipairs(target_notes) do
        table.insert(lines, "  " .. note_line(note))
        line_items[#lines] = {
          kind = "note",
          note_id = note.id,
          target_path = target_path,
        }
      end

      table.insert(lines, "")
    end
  end

  if lines[#lines] == "" then
    table.remove(lines, #lines)
  end

  if shown == 0 then
    table.insert(lines, current_type == "directory" and "No notes for this directory" or "No notes for this file")
  end

  return lines, line_items
end

function M.set_mode(mode)
  if mode ~= "all" and mode ~= "directory" then
    return false
  end

  sidebar_state().mode = mode
  M.refresh()
  return true
end

function M.toggle_mode()
  local sidebar = sidebar_state()

  if sidebar.mode == "directory" then
    M.set_mode("all")
  else
    M.set_mode("directory")
  end
end

function M.refresh()
  local sidebar = sidebar_state()

  if not sidebar.open or not is_valid_buf(sidebar.buf) then
    return
  end

  local lines, line_items

  if sidebar.mode == "directory" then
    lines, line_items = M.render_directory()
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
  refresh_timer:start(delay, 0, vim.schedule_wrap(function()
    M.refresh()
  end))
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
  context.get_current()

  if not is_valid_buf(sidebar.buf) then
    sidebar.buf = vim.api.nvim_create_buf(false, true)
    set_sidebar_options(sidebar.buf)
  end

  local position = state.config.sidebar.position or "right"
  if position == "left" then
    vim.cmd("topleft vertical " .. tostring(state.config.sidebar.width or 40) .. "new")
  else
    vim.cmd("botright vertical " .. tostring(state.config.sidebar.width or 40) .. "new")
  end

  sidebar.win = vim.api.nvim_get_current_win()
  sidebar.open = true

  vim.api.nvim_win_set_buf(sidebar.win, sidebar.buf)
  vim.api.nvim_win_set_width(sidebar.win, state.config.sidebar.width or 40)
  vim.wo[sidebar.win].number = false
  vim.wo[sidebar.win].relativenumber = false
  vim.wo[sidebar.win].signcolumn = "no"
  vim.wo[sidebar.win].wrap = false

  M.setup_mappings(sidebar.buf)
  M.refresh()

  if is_valid_win(current_win) then
    vim.api.nvim_set_current_win(current_win)
  end
end

function M.close()
  local sidebar = sidebar_state()

  for _, win in ipairs(sidebar.note_wins or {}) do
    if is_valid_win(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  sidebar.note_wins = {}
  sidebar.note_bufs = {}

  if is_valid_win(sidebar.win) then
    vim.api.nvim_win_close(sidebar.win, true)
  end

  sidebar.open = false
  sidebar.win = nil
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
    notes.open(item.note_id)

    local note_win = vim.api.nvim_get_current_win()
    if note_win ~= sidebar.win and is_valid_win(note_win) then
      sidebar.note_wins = sidebar.note_wins or {}
      table.insert(sidebar.note_wins, note_win)

      local note_buf = vim.api.nvim_win_get_buf(note_win)
      sidebar.note_bufs = sidebar.note_bufs or {}
      sidebar.note_bufs[note_buf] = true
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
  vim.keymap.set("n", "m", M.toggle_mode, opts)
  vim.keymap.set("n", "R", M.refresh, opts)
end

return M
