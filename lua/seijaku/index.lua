local M = {}

local state_mod = require("seijaku.state")
local paths = require("seijaku.paths")
local util = require("seijaku.util")

local save_timer = nil

local function empty_index()
  return {
    version = 1,
    created_at = util.now(),
    updated_at = util.now(),
    notes = {},
    targets = {},
    target_dirs = {},
  }
end

local function encode_json(data)
  return vim.json.encode(data)
end

local function decode_json(text)
  return vim.json.decode(text)
end

function M.ensure_vault()
  local state = state_mod.get()
  local vault = state.vault_dir

  util.mkdir_p(vault)
  util.mkdir_p(paths.join(vault, "notes"))
  util.mkdir_p(paths.join(vault, "backups", "canonical"))
  util.mkdir_p(paths.join(vault, "backups", "snapshots"))

  if vim.fn.filereadable(state.index_path) == 0 then
    local initial = empty_index()
    util.write_file(state.index_path, { encode_json(initial) })
  end
end

function M.load()
  local state = state_mod.get()
  local raw = util.read_file(state.index_path)

  if not raw or raw == "" then
    state.index = empty_index()
  else
    local ok, decoded = pcall(decode_json, raw)

    if not ok or type(decoded) ~= "table" then
      vim.notify("seijaku: failed to parse index.json, using empty index", vim.log.levels.ERROR)
      state.index = empty_index()
    else
      state.index = decoded
    end
  end

  M.rebuild_derived_indexes()
end

function M.rebuild_derived_indexes()
  local state = state_mod.get()
  local index = state.index or empty_index()

  index.notes = index.notes or {}
  index.targets = index.targets or {}
  index.target_dirs = {}

  state.notes_by_id = index.notes
  state.note_ids_by_target = index.targets
  state.target_paths_by_dir = {}

  for target_path, _ in pairs(index.targets) do
    local normalized = paths.normalize(target_path)
    local dir = nil

    local target_type = paths.target_type(normalized)

    if target_type == "directory" then
      dir = normalized
    else
      dir = paths.parent_dir(normalized)
    end

    if dir then
      state.target_paths_by_dir[dir] = state.target_paths_by_dir[dir] or {}

      local exists = false
      for _, existing in ipairs(state.target_paths_by_dir[dir]) do
        if existing == normalized then
          exists = true
          break
        end
      end

      if not exists then
        table.insert(state.target_paths_by_dir[dir], normalized)
      end
    end
  end

  index.target_dirs = state.target_paths_by_dir
  state.index = index

  return index
end

local function write_index_sync()
  local state = state_mod.get()

  if not state.index then
    return
  end

  state.index.updated_at = util.now()

  local tmp_path = state.index_path .. ".tmp"
  local json = encode_json(state.index)

  util.write_file(tmp_path, { json })
  vim.fn.rename(tmp_path, state.index_path)

  state_mod.clear_dirty()
end

function M.save_sync()
  write_index_sync()
end

function M.schedule_save()
  local state = state_mod.get()
  local delay = state.config.index.save_debounce_ms or 500

  if save_timer then
    save_timer:stop()
    save_timer:close()
    save_timer = nil
  end

  save_timer = vim.loop.new_timer()
  save_timer:start(delay, 0, vim.schedule_wrap(function()
    write_index_sync()
  end))
end

function M.mark_dirty()
  state_mod.mark_dirty()
  M.schedule_save()
end

function M.add_note(note)
  local state = state_mod.get()
  local index = state.index

  index.notes[note.id] = note
  M.mark_dirty()
end

function M.get_note(note_id)
  local state = state_mod.get()
  return state.notes_by_id[note_id]
end

function M.list_notes()
  local state = state_mod.get()
  local result = {}

  for _, note in pairs(state.notes_by_id or {}) do
    table.insert(result, note)
  end

  table.sort(result, function(a, b)
    return tostring(a.updated_at or "") > tostring(b.updated_at or "")
  end)

  return result
end

function M.attach(note_id, target_path, target_type)
  local state = state_mod.get()
  local index = state.index
  local note = index.notes[note_id]

  if not note then
    return false, "note not found"
  end

  target_path = paths.normalize(target_path)
  if not target_path then
    return false, "invalid target path"
  end

  target_type = target_type or paths.target_type(target_path)

  note.targets = note.targets or {}

  for _, target in ipairs(note.targets) do
    if target.path == target_path then
      return true
    end
  end

  table.insert(note.targets, {
    path = target_path,
    type = target_type,
  })

  index.targets[target_path] = index.targets[target_path] or {}

  local already = false
  for _, id in ipairs(index.targets[target_path]) do
    if id == note_id then
      already = true
      break
    end
  end

  if not already then
    table.insert(index.targets[target_path], note_id)
  end

  note.updated_at = util.now()

  M.rebuild_derived_indexes()
  M.mark_dirty()

  return true
end

function M.detach(note_id, target_path)
  local state = state_mod.get()
  local index = state.index
  local note = index.notes[note_id]

  target_path = paths.normalize(target_path)

  if not note or not target_path then
    return false
  end

  local new_targets = {}

  for _, target in ipairs(note.targets or {}) do
    if target.path ~= target_path then
      table.insert(new_targets, target)
    end
  end

  note.targets = new_targets

  local ids = index.targets[target_path] or {}
  local new_ids = {}

  for _, id in ipairs(ids) do
    if id ~= note_id then
      table.insert(new_ids, id)
    end
  end

  if #new_ids == 0 then
    index.targets[target_path] = nil
  else
    index.targets[target_path] = new_ids
  end

  note.updated_at = util.now()

  M.rebuild_derived_indexes()
  M.mark_dirty()

  return true
end

function M.delete_note(note_id)
  local state = state_mod.get()
  local index = state.index
  local note = index.notes[note_id]

  if not note then
    return false
  end

  for _, target in ipairs(note.targets or {}) do
    local ids = index.targets[target.path] or {}
    local new_ids = {}

    for _, id in ipairs(ids) do
      if id ~= note_id then
        table.insert(new_ids, id)
      end
    end

    if #new_ids == 0 then
      index.targets[target.path] = nil
    else
      index.targets[target.path] = new_ids
    end
  end

  index.notes[note_id] = nil

  M.rebuild_derived_indexes()
  M.mark_dirty()

  return true
end

function M.get_notes_for_target(target_path)
  local state = state_mod.get()
  target_path = paths.normalize(target_path)

  local ids = state.note_ids_by_target[target_path] or {}
  local notes = {}

  for _, id in ipairs(ids) do
    local note = state.notes_by_id[id]
    if note then
      table.insert(notes, note)
    end
  end

  return notes
end

function M.get_notes_for_dir(dir_path)
  local state = state_mod.get()
  dir_path = paths.normalize(dir_path)

  local target_paths = state.target_paths_by_dir[dir_path] or {}
  local grouped = {}

  for _, target_path in ipairs(target_paths) do
    grouped[target_path] = M.get_notes_for_target(target_path)
  end

  return grouped
end

return M
