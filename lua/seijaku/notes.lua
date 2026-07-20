local M = {}

local state_mod = require("seijaku.state")
local index = require("seijaku.index")
local paths = require("seijaku.paths")
local util = require("seijaku.util")

local metadata_start = "<!-- seijaku:metadata:start -->"
local metadata_end = "<!-- seijaku:metadata:end -->"
local note_types = {
  { value = "general", label = "1  General" },
  { value = "diary", label = "2  Diary" },
  { value = "meeting", label = "3  Meeting" },
  { value = "desc", label = "4  Description" },
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

local function prompt_title(default, callback)
  vim.ui.input({
    prompt = "Note title: ",
    default = default or "Untitled",
  }, function(input)
    if not input or input == "" then
      return
    end

    callback(input)
  end)
end

local function prompt_note_type(default, callback)
  if default then
    callback(default)
    return
  end

  local choices = {}
  for index_in_list, item in ipairs(note_types) do
    choices[tostring(index_in_list)] = item.value
  end

  while true do
    vim.api.nvim_echo({ {
      "Note type  1 General  2 Diary  3 Meeting  4 Description  (Esc cancel)",
      "Question",
    } }, false, {})
    local ok, key = pcall(vim.fn.getcharstr)
    vim.api.nvim_echo({}, false, {})

    if not ok or key == "\027" then
      return
    end

    if choices[key] then
      callback(choices[key])
      return
    end
  end
end

local function default_title_for_type(note_type, opts)
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

  return opts.title or "Untitled"
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

  prompt_note_type(opts.note_type, function(note_type)
    prompt_title(default_title_for_type(note_type, opts), function(title)
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
  end)
end

function M.create_global()
  return M.create({
    title = "Untitled",
  })
end

function M.create_for_target(target_path, target_type)
  local title = paths.basename(target_path) or "Untitled"

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
