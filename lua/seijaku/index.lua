local M = {}

local state_mod = require("seijaku.state")
local paths = require("seijaku.paths")
local util = require("seijaku.util")

local save_timer = nil
local reload_timer = nil
local vault_watcher = nil
local pending_upserts = {}
local pending_deletes = {}
local pending_todo_upserts = {}
local pending_todo_deletes = {}
local last_index_raw = nil
local note_query_cache = {}

local function invalidate_note_queries()
  note_query_cache = {}
end

local function stop_save_timer()
  if save_timer then
    save_timer:stop()
    if not save_timer:is_closing() then
      save_timer:close()
    end
    save_timer = nil
  end
end

local function stop_reload_timer()
  if reload_timer then
    reload_timer:stop()
    if not reload_timer:is_closing() then
      reload_timer:close()
    end
    reload_timer = nil
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
    version = 2,
    created_at = util.now(),
    updated_at = util.now(),
    notes = {},
    todos = {},
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

local function read_index_file(state)
  local raw = util.read_file(state.index_path)
  if not raw or raw == "" then
    return empty_index(), raw
  end

  local ok, decoded = pcall(decode_json, raw)
  if not ok or type(decoded) ~= "table" then
    return nil, raw, "failed to parse " .. state.index_path .. "; the file was left unchanged"
  end

  decoded.notes = decoded.notes or {}
  decoded.todos = decoded.todos or {}
  decoded.version = math.max(tonumber(decoded.version) or 1, 2)
  return decoded, raw
end

local function queue_upsert(note)
  if not note or not note.id then
    return
  end
  pending_deletes[note.id] = nil
  pending_upserts[note.id] = vim.deepcopy(note)
end

local function queue_delete(note_id)
  if not note_id then
    return
  end
  pending_upserts[note_id] = nil
  pending_deletes[note_id] = true
end

local function queue_todo_upsert(todo)
  if not todo or not todo.id then
    return
  end
  pending_todo_deletes[todo.id] = nil
  pending_todo_upserts[todo.id] = vim.deepcopy(todo)
end

local function queue_todo_delete(todo_id)
  if not todo_id then
    return
  end
  pending_todo_upserts[todo_id] = nil
  pending_todo_deletes[todo_id] = true
end

local function apply_pending(index)
  index.notes = index.notes or {}
  for note_id, _ in pairs(pending_deletes) do
    index.notes[note_id] = nil
  end
  for note_id, note in pairs(pending_upserts) do
    index.notes[note_id] = vim.deepcopy(note)
  end
  index.todos = index.todos or {}
  for todo_id, _ in pairs(pending_todo_deletes) do
    index.todos[todo_id] = nil
  end
  for todo_id, todo in pairs(pending_todo_upserts) do
    index.todos[todo_id] = vim.deepcopy(todo)
  end
  return index
end

local function clear_pending()
  pending_upserts = {}
  pending_deletes = {}
  pending_todo_upserts = {}
  pending_todo_deletes = {}
end

local function has_pending()
  return next(pending_upserts) ~= nil
    or next(pending_deletes) ~= nil
    or next(pending_todo_upserts) ~= nil
    or next(pending_todo_deletes) ~= nil
end

local function acquire_index_lock(state)
  local lock_path = state.index_path .. ".lock"
  local acquired = false
  local index_config = state.config.index or {}
  local stale_after = index_config.stale_lock_ms or 10000
  vim.wait(index_config.lock_timeout_ms or 2000, function()
    local ok = vim.loop.fs_mkdir(lock_path, 448)
    if ok then
      acquired = true
      return true
    end

    local stat = vim.loop.fs_stat(lock_path)
    local modified = stat and stat.mtime and stat.mtime.sec or nil
    if modified and (os.time() - modified) * 1000 > stale_after then
      vim.loop.fs_rmdir(lock_path)
    end
    return false
  end, 20)

  if not acquired then
    return nil, "timed out waiting for " .. lock_path
  end
  return lock_path
end
local function release_index_lock(lock_path)
  if lock_path then
    vim.loop.fs_rmdir(lock_path)
  end
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
  stop_save_timer()
  stop_reload_timer()
  clear_pending()
  last_index_raw = nil
  local state = state_mod.get()
  local decoded, raw, err = read_index_file(state)

  if not decoded then
    state.index = nil
    return false, err
  end

  state.index = apply_pending(decoded)
  last_index_raw = raw
  M.rebuild_derived_indexes()
  return true
end

function M.rebuild_derived_indexes()
  local state = state_mod.get()
  local index = state.index or empty_index()

  invalidate_note_queries()
  index.notes = index.notes or {}
  index.todos = index.todos or {}
  index.targets = {}
  index.target_dirs = {}

  state.notes_by_id = index.notes
  state.todos_by_id = index.todos
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
  if vim.fn.rename(tmp_path, state.index_path) ~= 0 then
    return false, "failed to replace " .. state.index_path
  end

  last_index_raw = json
  state_mod.clear_dirty()
  return true
end

function M.save_sync(opts)
  opts = opts or {}
  stop_save_timer()
  local state = state_mod.get()
  if not opts.force and not state.dirty and not has_pending() then
    return true
  end
  local lock_path, lock_err = acquire_index_lock(state)
  if not lock_path then
    M.schedule_save()
    return false, lock_err
  end

  local latest, _, read_err = read_index_file(state)
  if not latest then
    release_index_lock(lock_path)
    return false, read_err
  end

  state.index = apply_pending(latest)
  M.rebuild_derived_indexes()
  local ok, write_err = write_index_sync()
  if ok then
    clear_pending()
  end
  release_index_lock(lock_path)
  return ok, write_err
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

    M.save_sync()
    if not timer:is_closing() then
      timer:close()
    end
    if save_timer == timer then
      save_timer = nil
    end
  end))
end

local function refresh_sidebar_after_reload()
  local ok, sidebar = pcall(require, "seijaku.sidebar")
  if ok and state_mod.get().sidebar.open then
    sidebar.refresh()
  end
end

function M.reload_if_changed()
  local state = state_mod.get()
  local latest, raw, err = read_index_file(state)
  if not latest then
    util.notify("external index reload skipped: " .. tostring(err), vim.log.levels.ERROR)
    return false, err
  end
  if raw == last_index_raw then
    return false
  end

  state.index = apply_pending(latest)
  last_index_raw = raw
  M.rebuild_derived_indexes()
  pcall(vim.cmd, "silent! checktime")
  refresh_sidebar_after_reload()
  return true
end

local function schedule_external_reload()
  local state = state_mod.get()
  local delay = (state.config.index or {}).reload_debounce_ms or 120
  stop_reload_timer()
  local timer = vim.loop.new_timer()
  reload_timer = timer
  timer:start(delay, 0, vim.schedule_wrap(function()
    if reload_timer ~= timer then
      if not timer:is_closing() then
        timer:close()
      end
      return
    end

    M.reload_if_changed()
    if not timer:is_closing() then
      timer:close()
    end
    if reload_timer == timer then
      reload_timer = nil
    end
  end))
end

function M.stop_watcher()
  stop_reload_timer()
  if vault_watcher then
    vault_watcher:stop()
    if not vault_watcher:is_closing() then
      vault_watcher:close()
    end
    vault_watcher = nil
  end
end

function M.start_watcher()
  M.stop_watcher()
  local state = state_mod.get()
  if (state.config.index or {}).watch_external_changes == false then
    return false
  end

  local watcher = vim.loop.new_fs_event()
  local ok, err = watcher:start(state.vault_dir, {}, function(watch_err, filename)
    if watch_err then
      vim.schedule(function()
        util.notify("vault watcher error: " .. tostring(watch_err), vim.log.levels.WARN)
      end)
      return
    end

    if not filename or filename == "index.json" then
      schedule_external_reload()
    end
  end)

  if not ok then
    watcher:close()
    return false, err
  end

  vault_watcher = watcher
  return true
end

function M.mark_dirty(note)
  invalidate_note_queries()
  queue_upsert(note)
  state_mod.mark_dirty()
  M.schedule_save()
end

function M.mark_dirty_sync(note)
  invalidate_note_queries()
  queue_upsert(note)
  structural_save()
end

function M.add_note(note, opts)
  opts = opts or {}
  local state = state_mod.get()
  local index = state.index

  invalidate_note_queries()
  index.notes[note.id] = note
  state.notes_by_id[note.id] = note

  if note.file then
    local abs_note_path = paths.normalize(paths.join(state.vault_dir, note.file))

    if abs_note_path then
      state.notes_by_file[abs_note_path] = note
    end
  end

  if opts.defer_save then
    queue_upsert(note)
    state_mod.mark_dirty()
  else
    queue_upsert(note)
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
  M.mark_dirty(note)
  return true
end

local function normalized_note_type(note)
  return note and note.note_type or "general"
end

local function note_comparator(sort)
  if sort == "date" then
    return function(a, b)
      local a_date = tostring(M.calendar_date(a) or "")
      local b_date = tostring(M.calendar_date(b) or "")
      if a_date ~= b_date then
        return a_date > b_date
      end

      local a_updated = tostring(a.updated_at or "")
      local b_updated = tostring(b.updated_at or "")
      if a_updated ~= b_updated then
        return a_updated > b_updated
      end
      return tostring(a.id or "") < tostring(b.id or "")
    end
  end

  if sort == "created" then
    return function(a, b)
      local a_created = tostring(a.created_at or "")
      local b_created = tostring(b.created_at or "")
      if a_created ~= b_created then
        return a_created > b_created
      end
      return tostring(a.id or "") < tostring(b.id or "")
    end
  end

  return function(a, b)
    local a_updated = tostring(a.updated_at or "")
    local b_updated = tostring(b.updated_at or "")
    if a_updated ~= b_updated then
      return a_updated > b_updated
    end
    return tostring(a.id or "") < tostring(b.id or "")
  end
end

function M.query_notes(opts)
  opts = opts or {}
  local sort = opts.sort
  if sort ~= "date" and sort ~= "created" then
    sort = "updated"
  end
  local filter = opts.filter or "all"
  local cache_key = sort .. "\0" .. filter
  local cached = note_query_cache[cache_key]
  if cached then
    return cached
  end

  local result = {}

  for _, note in pairs(state_mod.get().notes_by_id or {}) do
    if filter == "all" or normalized_note_type(note) == filter then
      table.insert(result, note)
    end
  end

  table.sort(result, note_comparator(sort))
  note_query_cache[cache_key] = result
  return result
end

function M.list_notes()
  local cached = M.query_notes({ sort = "updated", filter = "all" })
  local result = {}
  for i, note in ipairs(cached) do
    result[i] = note
  end
  return result
end

function M.add_todo(todo, opts)
  opts = opts or {}
  if not todo or not todo.id then
    return false, "invalid todo"
  end

  local state = state_mod.get()
  state.index.todos = state.index.todos or {}
  state.index.todos[todo.id] = todo
  state.todos_by_id[todo.id] = todo
  queue_todo_upsert(todo)

  if opts.defer_save then
    state_mod.mark_dirty()
  else
    structural_save()
  end
  return true
end

function M.get_todo(todo_id)
  return state_mod.get().todos_by_id[todo_id]
end

function M.list_todos()
  local result = {}
  for _, todo in pairs(state_mod.get().todos_by_id or {}) do
    table.insert(result, todo)
  end

  table.sort(result, function(a, b)
    local a_date = M.todo_date(a) or ""
    local b_date = M.todo_date(b) or ""
    if a_date ~= b_date then
      return a_date > b_date
    end
    return tostring(a.created_at or "") > tostring(b.created_at or "")
  end)
  return result
end

function M.todo_date(todo)
  if todo and todo.calendar_date then
    return todo.calendar_date
  end
  return todo and tostring(todo.created_at or ""):match("^(%d%d%d%d%-%d%d%-%d%d)") or nil
end

function M.get_todos_for_calendar_date(date)
  local result = {}
  for _, todo in pairs(state_mod.get().todos_by_id or {}) do
    if M.todo_date(todo) == date then
      table.insert(result, todo)
    end
  end

  table.sort(result, function(a, b)
    return tostring(a.created_at or "") > tostring(b.created_at or "")
  end)
  return result
end

function M.update_todo(todo)
  if not todo or not todo.id or not M.get_todo(todo.id) then
    return false, "todo not found"
  end
  state_mod.get().index.todos[todo.id] = todo
  state_mod.get().todos_by_id[todo.id] = todo
  queue_todo_upsert(todo)
  structural_save()
  return true
end

function M.delete_todo(todo_id)
  local state = state_mod.get()
  if not M.get_todo(todo_id) then
    return false, "todo not found"
  end
  state.index.todos[todo_id] = nil
  state.todos_by_id[todo_id] = nil
  queue_todo_delete(todo_id)
  structural_save()
  return true
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

  for _, todo in pairs(state_mod.get().todos_by_id or {}) do
    local date = M.todo_date(todo)
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
  invalidate_note_queries()
  if state.index and state.index.notes then
    state.index.notes[note_id] = note
  end
  queue_upsert(note)
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
    queue_upsert(note)
    state_mod.mark_dirty()
  else
    queue_upsert(note)
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
    queue_upsert(note)
    state_mod.mark_dirty()
  else
    queue_upsert(note)
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
  queue_delete(note_id)
  if opts.defer_save then
    state_mod.mark_dirty()
  else
    structural_save()
  end

  return true
end

function M.reconcile_vault()
  M.reload_if_changed()
  local state = state_mod.get()
  local notes_dir = paths.join(state.vault_dir, "notes")
  local seen_files = {}
  local disk_notes_by_id = {}
  local conflicts = {}
  local conflicting_ids = {}
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
          if note then
            disk_notes_by_id[note.id] = disk_notes_by_id[note.id] or {}
            table.insert(disk_notes_by_id[note.id], note)
          end
        end
      end
    end
  end

  walk(notes_dir)

  for note_id, candidates in pairs(disk_notes_by_id) do
    if #candidates > 1 then
      local files = {}
      for _, candidate in ipairs(candidates) do
        table.insert(files, candidate.file)
      end
      table.sort(files)
      conflicting_ids[note_id] = true
      table.insert(conflicts, {
        id = note_id,
        files = files,
      })
    end
  end
  table.sort(conflicts, function(a, b)
    return a.id < b.id
  end)

  for note_id, note in pairs(state.index.notes or {}) do
    if note.file and not seen_files[note.file] and not conflicting_ids[note_id] then
      state.index.notes[note_id] = nil
      queue_delete(note_id)
      removed = removed + 1
    end
  end

  -- Remove stale paths before importing files. If a Markdown note was moved
  -- inside the vault, its ID still exists in the old index entry during the
  -- scan; importing first would therefore skip it until a second reconcile.
  for note_id, candidates in pairs(disk_notes_by_id) do
    local note = #candidates == 1 and candidates[1] or nil
    if note and not state.index.notes[note_id] then
      state.index.notes[note.id] = note
      queue_upsert(note)
      imported = imported + 1
    end
  end

  M.rebuild_derived_indexes()

  if imported > 0 or removed > 0 then
    state_mod.mark_dirty()
    M.save_sync()
  end

  return {
    imported = imported,
    removed = removed,
    conflicts = conflicts,
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
