local M = {}

local state_mod = require("seijaku.state")
local index = require("seijaku.index")
local paths = require("seijaku.paths")
local util = require("seijaku.util")

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

function M.create(opts)
  opts = opts or {}

  local default_title = opts.title or "Untitled"

  prompt_title(default_title, function(title)
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
      targets = {},
      tags = {},
    }

    util.write_file(abs_path, {
      "# " .. title,
      "",
    })

    index.add_note(note)

    if opts.target_path then
      index.attach(note_id, opts.target_path, opts.target_type)
    end

    M.open(note_id)
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
end

function M.rename(note_id, new_title)
  local note = index.get_note(note_id)

  if not note then
    return false
  end

  note.title = new_title
  note.updated_at = util.now()

  index.mark_dirty()

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

  return true
end

return M
