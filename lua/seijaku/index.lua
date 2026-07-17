local M = {}

local state_mod = require("seijaku.state")
local paths = require("seijaku.paths")
local util = require("seijaku.util")

local save_timer = nil

local function stop_save_timer()
  if save_timer then
    save_timer:stop()
    if not save_timer:is_closing() then
      save_timer:close()
    end
    save_timer = nil
  end
end

local function sync_note_metadata(note)
  local ok, notes = pcall(require, "seijaku.notes")

  if ok and type(notes.sync_metadata) == "function" then
    notes.sync_metadata(note)
  end
end

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

local function read_note_lines(abs_path)
  if vim.fn.filereadable(abs_path) == 0 then
    return nil
  end

  return vim.fn.readfile(abs_path)
end

local function parse_note_metadata(lines)
  local metadata = {
    targets = {},
  }
  local in_block = false

  for _, line in ipairs(lines or {}) do
    if line == "<!-- seijaku:metadata:start -->" then
      in_block = true
    elseif line == "<!-- seijaku:metadata:end -->" then
      break
    elseif in_block then
      local note_type = line:match("^> Type:%s*`([^`]+)`")
      if note_type then
        metadata.note_type = note_type
      end

      local created_at = line:match("^> Created:%s*`([^`]+)`")
      if created_at then
        metadata.created_at = created_at
      end

      local updated_at = line:match("^> Updated:%s*`([^`]+)`")
      if updated_at then
        metadata.updated_at = updated_at
      end

      local target_path = line:match("^> Target:%s*`([^`]+)`")
      if target_path and target_path ~= "global" then
        table.insert(metadata.targets, {
          path = target_path,
          type = paths.target_type(target_path),
        })
      end

      local calendar_date = line:match("^> Date:%s*`([^`]+)`")
      if calendar_date then
        metadata.calendar_date = calendar_date
      end
    end
  end

  for _, line in ipairs(lines or {}) do
    local title = line:match("^#%s+(.+)$")
    if title and title ~= "" then
      metadata.title = title
      break
    end
  end

  return metadata
end

local function note_from_file(state, rel_path)
  local abs_path = paths.join(state.vault_dir, rel_path)
  local lines = read_note_lines(abs_path)

  if not lines then
    return nil
  end

  local metadata = parse_note_metadata(lines)
  local basename = vim.fn.fnamemodify(rel_path, ":t:r")

  return {
    id = basename,
    title = metadata.title or basename,
    file = rel_path,
    created_at = metadata.created_at or util.now(),
    updated_at = metadata.updated_at or metadata.created_at or util.now(),
    note_type = metadata.note_type or "general",
    calendar_date = metadata.calendar_date,
    targets = metadata.targets or {},
    tags = {},
  }
end

local function structural_save()
  state_mod.mark_dirty()
  M.save_sync()
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
      state.index = nil
      return false, "failed to parse " .. state.index_path .. "; the file was left unchanged"
    else
      state.index = decoded
    end
  end

  M.rebuild_derived_indexes()
  return true
end

function M.rebuild_derived_indexes()
  local state = state_mod.get()
  local index = state.index or empty_index()

  index.notes = index.notes or {}
  index.targets = {}
  index.target_dirs = {}

  state.notes_by_id = index.notes
  state.notes_by_file = {}
  state.note_ids_by_target = index.targets
  state.target_paths_by_dir = {}

  for _, note in pairs(index.notes) do
    if note.file then
      local abs_note_path = paths.normalize(paths.join(state.vault_dir, note.file))

      if abs_note_path then
        state.notes_by_file[abs_note_path] = note
      end
    end

    for _, target in ipairs(note.targets or {}) do
      local target_path = paths.normalize(target.path)

      if target_path then
        index.targets[target_path] = index.targets[target_path] or {}
        table.insert(index.targets[target_path], note.id)
        target.path = target_path
        target.type = target.type or paths.target_type(target_path)
      end
    end
  end

  local function add_target_to_dir(dir, normalized)
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

  for target_path, _ in pairs(index.targets) do
    local normalized = paths.normalize(target_path)
    local target_type = paths.target_type(normalized)

    if target_type == "directory" then
      add_target_to_dir(normalized, normalized)
      add_target_to_dir(paths.parent_dir(normalized), normalized)
    else
      add_target_to_dir(paths.parent_dir(normalized), normalized)
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
  stop_save_timer()
  write_index_sync()
end

function M.schedule_save()
  local state = state_mod.get()
  local delay = state.config.index.save_debounce_ms or 500

  stop_save_timer()

  local timer = vim.loop.new_timer()
  save_timer = timer
  timer:start(delay, 0, vim.schedule_wrap(function()
    if save_timer ~= timer then
      if not timer:is_closing() then
        timer:close()
      end
      return
    end

    write_index_sync()
    if not timer:is_closing() then
      timer:close()
    end
    save_timer = nil
  end))
end

function M.mark_dirty()
  state_mod.mark_dirty()
  M.schedule_save()
end

function M.mark_dirty_sync()
  structural_save()
end

function M.add_note(note, opts)
  opts = opts or {}
  local state = state_mod.get()
  local index = state.index

  index.notes[note.id] = note
  state.notes_by_id[note.id] = note

  if note.file then
    local abs_note_path = paths.normalize(paths.join(state.vault_dir, note.file))

    if abs_note_path then
      state.notes_by_file[abs_note_path] = note
    end
  end

  if opts.defer_save then
    state_mod.mark_dirty()
  else
    structural_save()
  end
end

function M.get_note(note_id)
  local state = state_mod.get()
  return state.notes_by_id[note_id]
end

function M.get_note_for_file(file_path)
  local state = state_mod.get()
  local normalized = paths.normalize(file_path)

  if not normalized then
    return nil
  end

  return state.notes_by_file[normalized]
end

function M.touch_note_for_file(file_path)
  local note = M.get_note_for_file(file_path)

  if not note then
    return false
  end

  note.updated_at = util.now()
  M.mark_dirty()
  return true
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

function M.calendar_date(note)
  if note and note.calendar_date then
    return note.calendar_date
  end

  return note and tostring(note.created_at or ""):match("^(%d%d%d%d%-%d%d%-%d%d)") or nil
end

function M.get_notes_for_calendar_date(date)
  local result = {}

  for _, note in pairs(state_mod.get().notes_by_id or {}) do
    if M.calendar_date(note) == date then
      table.insert(result, note)
    end
  end

  table.sort(result, function(a, b)
    return tostring(a.updated_at or "") > tostring(b.updated_at or "")
  end)

  return result
end

function M.get_calendar_counts(year, month)
  local prefix = string.format("%04d-%02d-", year, month)
  local counts = {}

  for _, note in pairs(state_mod.get().notes_by_id or {}) do
    local date = M.calendar_date(note)
    if date and date:sub(1, #prefix) == prefix then
      counts[date] = (counts[date] or 0) + 1
    end
  end

  return counts
end

function M.set_calendar_date(note_id, date)
  local state = state_mod.get()
  local note = M.get_note(note_id)

  if not note then
    return false, "note not found"
  end

  if date ~= nil and not require("seijaku.calendar").parse(date) then
    return false, "invalid calendar date"
  end

  note.calendar_date = date
  note.updated_at = util.now()
  if state.index and state.index.notes then
    state.index.notes[note_id] = note
  end
  structural_save()
  sync_note_metadata(note)

  return true
end

function M.attach(note_id, target_path, target_type, opts)
  opts = opts or {}
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
  if opts.defer_save then
    state_mod.mark_dirty()
  else
    structural_save()
  end
  sync_note_metadata(note)

  return true
end

function M.detach(note_id, target_path, opts)
  opts = opts or {}
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
  if opts.defer_save then
    state_mod.mark_dirty()
  else
    structural_save()
  end
  sync_note_metadata(note)

  return true
end

function M.delete_note(note_id, opts)
  opts = opts or {}
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
  if opts.defer_save then
    state_mod.mark_dirty()
  else
    structural_save()
  end

  return true
end

function M.reconcile_vault()
  local state = state_mod.get()
  local notes_dir = paths.join(state.vault_dir, "notes")
  local seen_files = {}
  local imported = 0
  local removed = 0

  local function walk(dir)
    local handle = vim.loop.fs_scandir(dir)
    if not handle then
      return
    end

    while true do
      local name, kind = vim.loop.fs_scandir_next(handle)
      if not name then
        break
      end

      local abs_path = paths.join(dir, name)

      if kind == "directory" then
        walk(abs_path)
      elseif kind == "file" and name:sub(-3) == ".md" then
        local rel_path = paths.relative_to(state.vault_dir, abs_path)
        if rel_path then
          seen_files[rel_path] = true
          local note = note_from_file(state, rel_path)

          if note and not state.index.notes[note.id] then
            state.index.notes[note.id] = note
            imported = imported + 1
          end
        end
      end
    end
  end

  walk(notes_dir)

  for note_id, note in pairs(state.index.notes or {}) do
    if note.file and not seen_files[note.file] then
      state.index.notes[note_id] = nil
      removed = removed + 1
    end
  end

  M.rebuild_derived_indexes()

  if imported > 0 or removed > 0 then
    structural_save()
  end

  return {
    imported = imported,
    removed = removed,
  }
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

function M.get_notes_for_tree(dir_path)
  local state = state_mod.get()
  dir_path = paths.normalize(dir_path)
  local grouped = {}

  if not dir_path then
    return grouped
  end

  local prefix = dir_path == "/" and "/" or dir_path .. "/"

  for target_path, _ in pairs(state.note_ids_by_target or {}) do
    if target_path == dir_path or target_path:sub(1, #prefix) == prefix then
      grouped[target_path] = M.get_notes_for_target(target_path)
    end
  end

  return grouped
end

return M
