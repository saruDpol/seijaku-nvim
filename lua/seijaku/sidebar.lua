local M = {}

local state_mod = require("seijaku.state")
local index = require("seijaku.index")
local notes = require("seijaku.notes")
local context = require("seijaku.context")
local paths = require("seijaku.paths")

local refresh_timer = nil

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

local function note_line(note)
  local title = note.title or note.id
  local target_count = #(note.targets or {})

  if target_count > 0 then
    return string.format("- %s [%d]", title, target_count)
  end

  return "- " .. title
end

local function target_label(target_path)
  local target_type = paths.target_type(target_path)
  local basename = paths.basename(target_path)

  if target_type == "directory" then
    return "[dir] " .. (basename ~= "" and basename or target_path)
  end

  if target_type == "file" then
    return "[file] " .. basename
  end

  return "[path] " .. (basename ~= "" and basename or target_path)
end

function M.render_all()
  local state = state_mod.get()
  local limit = state.config.sidebar.all_mode_limit or 500
  local all_notes = index.list_notes()
  local lines = {
    "seijaku: all notes",
    "",
  }
  local line_items = {}

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
  local line_items = {}
  local lines = {}

  sidebar.current_dir = dir
  sidebar.current_target = ctx and ctx.target_path or nil

  if not dir then
    return {
      "seijaku: directory",
      "",
      "No current directory",
    }, line_items
  end

  lines = {
    "seijaku: " .. dir,
    "",
  }

  local target_paths = state_mod.get().target_paths_by_dir[dir] or {}

  if #target_paths == 0 then
    table.insert(lines, "No notes for this directory")
    return lines, line_items
  end

  table.sort(target_paths)

  for _, target_path in ipairs(target_paths) do
    local target_notes = index.get_notes_for_target(target_path)

    if #target_notes > 0 then
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
  local item = selected_item()

  if item and item.kind == "note" then
    notes.open(item.note_id)
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

function M.setup_mappings(buf)
  local opts = {
    buffer = buf,
    silent = true,
    nowait = true,
  }

  vim.keymap.set("n", "<CR>", M.handle_enter, opts)
  vim.keymap.set("n", "n", M.handle_create, opts)
  vim.keymap.set("n", "r", M.handle_rename, opts)
  vim.keymap.set("n", "D", M.handle_delete, opts)
  vim.keymap.set("n", "m", M.toggle_mode, opts)
  vim.keymap.set("n", "R", M.refresh, opts)
  vim.keymap.set("n", "q", M.close, opts)
end

return M
