local M = {}

local state_mod = require("seijaku.state")
local paths = require("seijaku.paths")
local util = require("seijaku.util")

local save_timer = nil
local reload_timer = nil
local vault_watcher = nil
local pending_upserts = {}
local pending_deletes = {}
local pending_tag_colors = {}
local pending_tag_icons = {}
local pending_notebook_upserts = {}
local pending_notebook_deletes = {}
local last_index_raw = nil
local note_query_cache = {}
local schema_version = 6

local notebook_palette = {
  "#795548", "#66558a", "#3e6d78", "#5f7848", "#926449", "#875770",
  "#466b8a", "#857245", "#6d596b", "#49766a", "#805b4c", "#586888",
}

local tag_palette = {
  "#795548", "#66558a", "#3e6d78", "#5f7848", "#926449", "#875770",
  "#466b8a", "#857245", "#6d596b", "#49766a", "#805b4c", "#586888",
}

local function valid_color(color)
  return type(color) == "string" and color:match("^#%x%x%x%x%x%x$") ~= nil
end

local function notebook_icon(value)
  if value == nil or value == false or value == "" then
    return nil
  end
  if type(value) ~= "string" then
    return nil
  end
  local icon = vim.trim(value)
  if icon == "" or icon:find("%c") or vim.fn.strchars(icon) > 4 then
    return nil
  end
  return icon
end

local function assign_tag_color(index, tag)
  index.tag_colors = index.tag_colors or {}
  if valid_color(index.tag_colors[tag]) then
    return false
  end
  local color = tag_palette[math.random(#tag_palette)]
  index.tag_colors[tag] = color
  pending_tag_colors[tag] = color
  return true
end

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

local function empty_index()
  return {
    version = schema_version,
    created_at = util.now(),
    updated_at = util.now(),
    notes = {},
    notebooks = {},
    tag_colors = {},
    tag_icons = {},
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

  local version = decoded.version == nil and 1 or tonumber(decoded.version)
  if not version or version < 1 or version % 1 ~= 0 then
    return nil, raw, "invalid index version in " .. state.index_path .. "; the file was left unchanged"
  end
  if version > schema_version then
    return nil, raw, "unsupported index version " .. tostring(version) .. "; the file was left unchanged"
  end
  if decoded.notes ~= nil and type(decoded.notes) ~= "table" then
    return nil, raw, "invalid notes in " .. state.index_path .. "; the file was left unchanged"
  end
  decoded.notes = decoded.notes or {}
  decoded.todos = nil
  decoded.todo_targets = nil
  if decoded.notebooks ~= nil and type(decoded.notebooks) ~= "table" then
    return nil, raw, "invalid notebooks in " .. state.index_path .. "; the file was left unchanged"
  end
  decoded.notebooks = decoded.notebooks or {}
  for id, notebook in pairs(decoded.notebooks) do
    if type(notebook) ~= "table" then
      return nil, raw, "invalid notebook " .. tostring(id) .. " in " .. state.index_path .. "; the file was left unchanged"
    end
    notebook.icon = notebook_icon(notebook.icon)
    if notebook.path == vim.NIL or notebook.path == false or notebook.path == "" then
      notebook.path = nil
    elseif notebook.path ~= nil and type(notebook.path) ~= "string" then
      return nil, raw, "invalid notebook path in " .. state.index_path .. "; the file was left unchanged"
    end
  end
  decoded.tag_colors = type(decoded.tag_colors) == "table" and decoded.tag_colors or {}
  decoded.tag_icons = type(decoded.tag_icons) == "table" and decoded.tag_icons or {}
  for tag, icon in pairs(decoded.tag_icons) do
    decoded.tag_icons[tag] = notebook_icon(icon)
  end
  decoded.version = version
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

local function queue_notebook_upsert(notebook)
  pending_notebook_deletes[notebook.id] = nil
  pending_notebook_upserts[notebook.id] = vim.deepcopy(notebook)
end

local function queue_notebook_delete(notebook_id)
  pending_notebook_upserts[notebook_id] = nil
  pending_notebook_deletes[notebook_id] = true
end

local function apply_pending(index)
  local detached_note_ids = {}
  index.notes = index.notes or {}
  for note_id, _ in pairs(pending_deletes) do
    index.notes[note_id] = nil
  end
  for note_id, note in pairs(pending_upserts) do
    index.notes[note_id] = vim.deepcopy(note)
  end
  index.notebooks = index.notebooks or {}
  for notebook_id, _ in pairs(pending_notebook_deletes) do
    index.notebooks[notebook_id] = nil
  end
  for notebook_id, notebook in pairs(pending_notebook_upserts) do
    index.notebooks[notebook_id] = vim.deepcopy(notebook)
  end
  for note_id, note in pairs(index.notes) do
    if note.notebook_id and pending_notebook_deletes[note.notebook_id] then
      note.notebook_id = nil
      note.updated_at = util.now()
      table.insert(detached_note_ids, note_id)
    end
  end
  index.tag_colors = index.tag_colors or {}
  for tag, color in pairs(pending_tag_colors) do
    index.tag_colors[tag] = color or nil
  end
  index.tag_icons = index.tag_icons or {}
  for tag, icon in pairs(pending_tag_icons) do
    index.tag_icons[tag] = icon or nil
  end
  return index, detached_note_ids
end

local function clear_pending()
  pending_upserts = {}
  pending_deletes = {}
  pending_tag_colors = {}
  pending_tag_icons = {}
  pending_notebook_upserts = {}
  pending_notebook_deletes = {}
end

local function has_pending()
  return next(pending_upserts) ~= nil
    or next(pending_deletes) ~= nil
    or next(pending_tag_colors) ~= nil
    or next(pending_tag_icons) ~= nil
    or next(pending_notebook_upserts) ~= nil
    or next(pending_notebook_deletes) ~= nil
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

local function parse_note_title(lines)
  for _, line in ipairs(lines or {}) do
    local title = line:match("^#%s+(.+)$")
    if title and title ~= "" then
      return title
    end
  end
end

local function note_from_file(state, rel_path)
  local abs_path = paths.join(state.vault_dir, rel_path)
  local lines = read_note_lines(abs_path)

  if not lines then
    return nil
  end

  local basename = vim.fn.fnamemodify(rel_path, ":t:r")

  return {
    id = basename,
    title = parse_note_title(lines) or basename,
    file = rel_path,
    created_at = util.now(),
    updated_at = util.now(),
    targets = {},
    tags = {},
    pinned = false,
  }
end

local function structural_save()
  state_mod.mark_dirty()
  return M.save_sync()
end

function M.ensure_vault()
  local state = state_mod.get()
  local vault = state.vault_dir

  util.mkdir_p(vault)
  util.mkdir_p(paths.join(vault, "notes"))

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

	local loaded_version = decoded.version
	state.index = apply_pending(decoded)
  last_index_raw = raw
  M.rebuild_derived_indexes()
	if loaded_version < schema_version then
    local saved, save_err = M.save_sync({ force = true })
    if not saved then
      return false, save_err
    end
    return true
  end
  if next(pending_tag_colors) ~= nil or next(pending_tag_icons) ~= nil then
    state_mod.mark_dirty()
    M.schedule_save()
  end
  return true
end

function M.rebuild_derived_indexes()
  local state = state_mod.get()
  local index = state.index or empty_index()

  invalidate_note_queries()
  index.notes = index.notes or {}
  index.notebooks = index.notebooks or {}
  index.tag_colors = index.tag_colors or {}
  index.tag_icons = index.tag_icons or {}
  index.targets = {}
  index.target_dirs = {}
  index.version = schema_version

  state.notes_by_id = index.notes
  state.notebooks_by_id = index.notebooks
  state.notes_by_file = {}
  state.note_ids_by_target = index.targets
  state.target_paths_by_dir = {}
  state.note_ids_by_date = {}
  state.note_ids_by_notebook = {}
  state.calendar_counts_by_month = {}

  local function add_date_item(collection, date, id)
    if not date or not id then
      return
    end
    collection[date] = collection[date] or {}
    table.insert(collection[date], id)
    local month = date:match("^(%d%d%d%d%-%d%d)")
    if month then
      state.calendar_counts_by_month[month] = state.calendar_counts_by_month[month] or {}
      local counts = state.calendar_counts_by_month[month]
      counts[date] = (counts[date] or 0) + 1
    end
  end

  for _, note in pairs(index.notes) do
    local tags = {}
    local seen_tags = {}
    for _, value in ipairs(note.tags or {}) do
      local tag = vim.trim(tostring(value)):lower()
      if tag ~= "" and not seen_tags[tag] then
        seen_tags[tag] = true
        table.insert(tags, tag)
      end
    end
    table.sort(tags)
    note.tags = tags
    for _, tag in ipairs(tags) do
      assign_tag_color(index, tag)
    end
    note.note_type = nil
    note.pinned = note.pinned == true
    if note.notebook_id then
      state.note_ids_by_notebook[note.notebook_id] = state.note_ids_by_notebook[note.notebook_id] or {}
      table.insert(state.note_ids_by_notebook[note.notebook_id], note.id)
    end
    add_date_item(state.note_ids_by_date, M.calendar_date(note), note.id)
    if note.file then
      local abs_note_path = paths.absolute(paths.join(state.vault_dir, note.file))

      if abs_note_path then
        state.notes_by_file[abs_note_path] = note
      end
    end

    for _, target in ipairs(note.targets or {}) do
      local target_path = paths.absolute(target.path)

      if target_path then
        index.targets[target_path] = index.targets[target_path] or {}
        table.insert(index.targets[target_path], note.id)
        target.path = target_path
        target.type = target.type or "unknown"
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

  local target_types = {}
  for _, note in pairs(index.notes) do
    for _, target in ipairs(note.targets or {}) do
      if target.path and not target_types[target.path] then
        target_types[target.path] = target.type or "unknown"
      end
    end
  end
  for target_path, target_type in pairs(target_types) do
    local normalized = paths.absolute(target_path)

    if target_type == "directory" then
      add_target_to_dir(normalized, normalized)
      add_target_to_dir(paths.parent_dir_absolute(normalized), normalized)
    else
      add_target_to_dir(paths.parent_dir_absolute(normalized), normalized)
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

  if latest.version < schema_version then
    latest.version = schema_version
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

  if latest.version < schema_version then
    local migrated, migration_err = M.save_sync({ force = true })
    if not migrated then
      util.notify("external index migration failed: " .. tostring(migration_err), vim.log.levels.ERROR)
      return false, migration_err
    end
  else
    state.index = apply_pending(latest)
    last_index_raw = raw
    M.rebuild_derived_indexes()
  end
  local ok_notes, notes = pcall(require, "seijaku.notes")
  if ok_notes and type(notes.define_tag_highlights) == "function" then
    notes.define_tag_highlights()
  end
  if next(pending_tag_colors) ~= nil or next(pending_tag_icons) ~= nil then
    state_mod.mark_dirty()
    M.schedule_save()
  end
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
  return structural_save()
end

function M.add_note(note, opts)
  opts = opts or {}
  local state = state_mod.get()
  local index = state.index

  invalidate_note_queries()
  index.notes[note.id] = note
  state.notes_by_id[note.id] = note
  M.rebuild_derived_indexes()

  if note.file then
    local abs_note_path = paths.absolute(paths.join(state.vault_dir, note.file))

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

local function notebook_name(value)
  if type(value) ~= "string" then
    return nil
  end
  local name = vim.trim(value)
  if name == "" or name:find("%c") then
    return nil
  end
  return name
end

function M.get_notebook(notebook_id)
  return state_mod.get().notebooks_by_id[notebook_id]
end

function M.list_notebooks()
  local result = {}
  for _, notebook in pairs(state_mod.get().notebooks_by_id or {}) do
    table.insert(result, notebook)
  end
  table.sort(result, function(a, b)
    local a_name = (a.name or ""):lower()
    local b_name = (b.name or ""):lower()
    if a_name ~= b_name then
      return a_name < b_name
    end
    return a.id < b.id
  end)
  return result
end

-- Return the most specific notebook whose working directory contains target.
-- Notebook paths are normalized when they are written, so this only performs
-- one normalization and a small in-memory scan during note creation.
function M.notebook_for_target_path(target)
  local normalized = paths.normalize(target)
  if not normalized then
    return nil
  end

  local match, match_length
  for _, notebook in pairs(state_mod.get().notebooks_by_id or {}) do
    local root = notebook.path
    if root and root ~= "" and (normalized == root or normalized:sub(1, #root + 1) == root .. "/") then
      local length = #root
      if not match_length or length > match_length then
        match, match_length = notebook, length
      end
    end
  end
  return match
end

local function notebook_name_exists(name, except_id)
  for id, notebook in pairs(state_mod.get().notebooks_by_id or {}) do
    if id ~= except_id and (notebook.name or ""):lower() == name:lower() then
      return true
    end
  end
  return false
end

function M.create_notebook(opts)
  opts = opts or {}
  local name = notebook_name(opts.name)
  if not name then
    return nil, "notebook name must be non-empty and contain no control characters"
  end
  if notebook_name_exists(name) then
    return nil, "notebook name already exists"
  end
  if opts.color ~= nil and not valid_color(opts.color) then
    return nil, "notebook color must be a #RRGGBB value"
  end
  if opts.path ~= nil and type(opts.path) ~= "string" then
    return nil, "notebook path must be a string"
  end
  if opts.icon ~= nil and not notebook_icon(opts.icon) then
    return nil, "notebook icon must contain one to four printable characters"
  end
  local path = opts.path and paths.normalize(opts.path) or nil
  if opts.path and not path then
    return nil, "invalid notebook path"
  end
  local id
  repeat
    id = "book_" .. util.random_hex(16)
  until not M.get_notebook(id)
  local now = util.now()
  local notebook = {
    id = id,
    name = name,
    path = path,
    color = opts.color or notebook_palette[(tonumber(id:sub(-2), 16) % #notebook_palette) + 1],
    icon = notebook_icon(opts.icon),
    created_at = now,
    updated_at = now,
  }
  state_mod.get().index.notebooks[id] = notebook
  queue_notebook_upsert(notebook)
  local saved, err = structural_save()
  if not saved then
    return nil, err
  end
  return M.get_notebook(id)
end

function M.update_notebook(notebook_id, changes)
  local notebook = M.get_notebook(notebook_id)
  if not notebook then
    return false, "notebook not found"
  end
  changes = changes or {}
  local name, path, color, icon = notebook.name, notebook.path, notebook.color, notebook.icon
  if changes.name ~= nil then
    name = notebook_name(changes.name)
    if not name then
      return false, "notebook name must be non-empty and contain no control characters"
    end
    if notebook_name_exists(name, notebook_id) then
      return false, "notebook name already exists"
    end
  end
  if changes.path ~= nil then
    if changes.path == false or changes.path == "" then
      path = nil
    else
      if type(changes.path) ~= "string" then
        return false, "notebook path must be a string"
      end
      path = paths.normalize(changes.path)
      if not path then
        return false, "invalid notebook path"
      end
    end
  end
  if changes.color ~= nil then
    if not valid_color(changes.color) then
      return false, "notebook color must be a #RRGGBB value"
    end
    color = changes.color
  end
  if changes.icon ~= nil then
    icon = notebook_icon(changes.icon)
    if changes.icon ~= false and changes.icon ~= "" and not icon then
      return false, "notebook icon must contain one to four printable characters"
    end
  end
  notebook.name = name
  notebook.path = path
  notebook.color = color
  notebook.icon = icon
  notebook.updated_at = util.now()
  queue_notebook_upsert(notebook)
  return structural_save()
end

function M.delete_notebook(notebook_id)
  if not M.get_notebook(notebook_id) then
    return false, "notebook not found"
  end
  queue_notebook_delete(notebook_id)
  return structural_save()
end

function M.assign_notebook(note_id, notebook_id)
  local note = M.get_note(note_id)
  if not note then
    return false, "note not found"
  end
  if notebook_id ~= nil and not M.get_notebook(notebook_id) then
    return false, "notebook not found"
  end
  if note.notebook_id == notebook_id then
    return true
  end
  note.notebook_id = notebook_id
  note.updated_at = util.now()
  local saved, err = M.mark_dirty_sync(note)
  if not saved then
    return false, err
  end
  return true
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

local function note_matches_scope(note, opts)
  opts = opts or {}
  local tag = opts.tag or "all"
  local notebook_id = opts.notebook_id
  local tag_matches = tag == "all" or vim.tbl_contains(note.tags or {}, tag)
  local notebook_matches = notebook_id == nil
    or (notebook_id == false and note.notebook_id == nil)
    or note.notebook_id == notebook_id
  return tag_matches and notebook_matches
end

local function note_comparator(sort)
  local function pinned_first(a, b)
    local a_pinned = a and a.pinned == true
    local b_pinned = b and b.pinned == true
    if a_pinned ~= b_pinned then
      return a_pinned
    end
    return nil
  end

  if sort == "date" then
    return function(a, b)
      local pinned = pinned_first(a, b)
      if pinned ~= nil then
        return pinned
      end
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
      local pinned = pinned_first(a, b)
      if pinned ~= nil then
        return pinned
      end
      local a_created = tostring(a.created_at or "")
      local b_created = tostring(b.created_at or "")
      if a_created ~= b_created then
        return a_created > b_created
      end
      return tostring(a.id or "") < tostring(b.id or "")
    end
  end

  return function(a, b)
    local pinned = pinned_first(a, b)
    if pinned ~= nil then
      return pinned
    end
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
  local tag = opts.tag or "all"
  local notebook_id = opts.notebook_id
  local cache_key = sort .. "\0" .. tag .. "\0" .. tostring(notebook_id)
  local cached = note_query_cache[cache_key]
  if cached then
    return cached
  end

  local result = {}
  local state = state_mod.get()
  local function include(note)
    if not note then
      return
    end
    if note_matches_scope(note, { tag = tag, notebook_id = notebook_id }) then
      table.insert(result, note)
    end
  end

  if notebook_id and notebook_id ~= false then
    for _, note_id in ipairs(state.note_ids_by_notebook[notebook_id] or {}) do
      include(state.notes_by_id[note_id])
    end
  else
    for _, note in pairs(state.notes_by_id or {}) do
      include(note)
    end
  end

  table.sort(result, note_comparator(sort))
  note_query_cache[cache_key] = result
  return result
end

function M.get_notes_for_notebook(notebook_id, opts)
  opts = vim.tbl_extend("force", opts or {}, { notebook_id = notebook_id })
  return M.query_notes(opts)
end

function M.list_notes()
  local cached = M.query_notes({ sort = "updated" })
  local result = {}
  for i, note in ipairs(cached) do
    result[i] = note
  end
  return result
end

function M.calendar_date(note)
  if note and note.calendar_date then
    return note.calendar_date
  end

  return note and tostring(note.created_at or ""):match("^(%d%d%d%d%-%d%d%-%d%d)") or nil
end

function M.get_notes_for_calendar_date(date, opts)
  local result = {}
  local state = state_mod.get()
  for _, id in ipairs(state.note_ids_by_date[date] or {}) do
    local note = state.notes_by_id[id]
    if note and note_matches_scope(note, opts) then
      table.insert(result, note)
    end
  end

  table.sort(result, function(a, b)
    if (a.pinned == true) ~= (b.pinned == true) then
      return a.pinned == true
    end
    return tostring(a.updated_at or "") > tostring(b.updated_at or "")
  end)

  return result
end

function M.get_calendar_counts(year, month, opts)
  local key = string.format("%04d-%02d", year, month)
  local counts = {}
  if opts and (opts.tag and opts.tag ~= "all" or opts.notebook_id ~= nil) then
    for date, ids in pairs(state_mod.get().note_ids_by_date or {}) do
      if date:sub(1, #key) == key then
        for _, id in ipairs(ids) do
          local note = state_mod.get().notes_by_id[id]
          if note and note_matches_scope(note, opts) then
            counts[date] = (counts[date] or 0) + 1
          end
        end
      end
    end
    return counts
  end
  for date, count in pairs(state_mod.get().calendar_counts_by_month[key] or {}) do
    counts[date] = count
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
  M.rebuild_derived_indexes()
  if state.index and state.index.notes then
    state.index.notes[note_id] = note
  end
  queue_upsert(note)
  structural_save()
  return true
end

function M.list_tags()
  local seen = {}
  local result = {}
  for _, note in pairs(state_mod.get().notes_by_id or {}) do
    for _, tag in ipairs(note.tags or {}) do
      if tag ~= "" and not seen[tag] then
        seen[tag] = true
        table.insert(result, tag)
      end
    end
  end
  -- A persisted colour also represents an explicitly created tag, even before
  -- that tag has been assigned to its first note.
  for tag, _ in pairs((state_mod.get().index or {}).tag_colors or {}) do
    if tag ~= "" and not seen[tag] then
      seen[tag] = true
      table.insert(result, tag)
    end
  end
  for tag, _ in pairs((state_mod.get().index or {}).tag_icons or {}) do
    if tag ~= "" and not seen[tag] then
      seen[tag] = true
      table.insert(result, tag)
    end
  end
  table.sort(result)
  return result
end

function M.get_tag_color(tag)
  local colors = state_mod.get().index and state_mod.get().index.tag_colors or {}
  local color = colors and colors[tag]
  return valid_color(color) and color or nil
end

function M.set_tag_color(tag, color)
  tag = vim.trim(tostring(tag or "")):lower()
  if tag == "" then
    return false, "tag is required"
  end
  if tag:find("[`,%c]") then
    return false, "tags cannot contain commas, backticks or control characters"
  end
  if not valid_color(color) then
    return false, "tag color must be a #RRGGBB value"
  end
  local current_index = state_mod.get().index
  current_index.tag_colors = current_index.tag_colors or {}
  current_index.tag_colors[tag] = color
  pending_tag_colors[tag] = color
  return structural_save()
end

function M.get_tag_icon(tag)
  local icons = state_mod.get().index and state_mod.get().index.tag_icons or {}
  return notebook_icon(icons and icons[tag])
end

function M.set_tag_icon(tag, icon)
  tag = vim.trim(tostring(tag or "")):lower()
  if tag == "" then
    return false, "tag is required"
  end
  if tag:find("[`,%c]") then
    return false, "tags cannot contain commas, backticks or control characters"
  end
  local normalized = notebook_icon(icon)
  if icon ~= nil and icon ~= false and icon ~= "" and not normalized then
    return false, "tag icon must contain one to four printable characters"
  end
  local current_index = state_mod.get().index
  current_index.tag_icons = current_index.tag_icons or {}
  current_index.tag_icons[tag] = normalized
  pending_tag_icons[tag] = normalized or false
  return structural_save()
end

function M.rename_tag(old_tag, new_tag)
  old_tag = vim.trim(tostring(old_tag or "")):lower()
  new_tag = vim.trim(tostring(new_tag or "")):lower()
  if old_tag == "" or new_tag == "" then
    return false, "tag name is required"
  end
  if new_tag:find("[`,%c]") then
    return false, "tags cannot contain commas, backticks or control characters"
  end
  if old_tag == new_tag then
    return true
  end
  local state = state_mod.get()
  for _, note in pairs(state.notes_by_id) do
    local changed = false
    local tags, seen = {}, {}
    for _, tag in ipairs(note.tags or {}) do
      local renamed = tag == old_tag
      tag = renamed and new_tag or tag
      if not seen[tag] then
        seen[tag] = true
        table.insert(tags, tag)
      end
      changed = changed or renamed
    end
    if changed then
      table.sort(tags)
      note.tags = tags
      note.updated_at = util.now()
      queue_upsert(note)
    end
  end
  local colors = state.index.tag_colors or {}
  if colors[old_tag] and not colors[new_tag] then
    colors[new_tag] = colors[old_tag]
    pending_tag_colors[new_tag] = colors[new_tag]
  end
  colors[old_tag] = nil
  pending_tag_colors[old_tag] = false
  local icons = state.index.tag_icons or {}
  if icons[old_tag] and not icons[new_tag] then
    icons[new_tag] = icons[old_tag]
    pending_tag_icons[new_tag] = icons[new_tag]
  end
  icons[old_tag] = nil
  pending_tag_icons[old_tag] = false
  return structural_save()
end

function M.delete_tag(tag)
  tag = vim.trim(tostring(tag or "")):lower()
  if tag == "" then
    return false, "tag is required"
  end

  local state = state_mod.get()
  local exists = (state.index.tag_colors or {})[tag] ~= nil
    or (state.index.tag_icons or {})[tag] ~= nil
  for _, note in pairs(state.notes_by_id or {}) do
    for _, value in ipairs(note.tags or {}) do
      if value == tag then
        exists = true
        break
      end
    end
    if exists then
      break
    end
  end
  if not exists then
    return false, "tag not found"
  end

  -- Removing a tag only removes its association and presentation metadata;
  -- the notes themselves remain untouched.
  for _, note in pairs(state.notes_by_id or {}) do
    local filtered, changed = {}, false
    for _, value in ipairs(note.tags or {}) do
      if value == tag then
        changed = true
      else
        table.insert(filtered, value)
      end
    end
    if changed then
      note.tags = filtered
      note.updated_at = util.now()
      queue_upsert(note)
    end
  end

  state.index.tag_colors = state.index.tag_colors or {}
  state.index.tag_icons = state.index.tag_icons or {}
  state.index.tag_colors[tag] = nil
  state.index.tag_icons[tag] = nil
  pending_tag_colors[tag] = false
  pending_tag_icons[tag] = false
  M.rebuild_derived_indexes()
  return structural_save()
end

function M.set_tags(note_id, tags)
  local note = M.get_note(note_id)
  if not note then
    return false, "note not found"
  end

  local normalized = {}
  local seen = {}
  for _, value in ipairs(tags or {}) do
    local tag = vim.trim(tostring(value)):lower()
    if tag:find("[`,%c]") then
      return false, "tags cannot contain commas, backticks or control characters"
    end
    if tag ~= "" and not seen[tag] then
      seen[tag] = true
      table.insert(normalized, tag)
    end
  end
  table.sort(normalized)
  note.tags = normalized
  local current_index = state_mod.get().index
  for _, tag in ipairs(normalized) do
    assign_tag_color(current_index, tag)
  end
  note.updated_at = util.now()
  M.mark_dirty_sync(note)
  return true
end

function M.toggle_pin(note_id)
  local note = M.get_note(note_id)
  if not note then
    return false, "note not found"
  end
  note.pinned = not (note.pinned == true)
  note.updated_at = util.now()
  M.mark_dirty_sync(note)
  return true, note.pinned
end

function M.set_target(note_id, target_path, target_type)
  local note = M.get_note(note_id)
  if not note then
    return false, "note not found"
  end
  target_path = paths.normalize(target_path)
  if not target_path then
    return false, "invalid target path"
  end
  note.targets = {
    {
      path = target_path,
      type = target_type or paths.target_type(target_path),
    },
  }
  note.updated_at = util.now()
  M.rebuild_derived_indexes()
  queue_upsert(note)
  return structural_save()
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
