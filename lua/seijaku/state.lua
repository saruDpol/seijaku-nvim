local M = {}

local state = {
  config = nil,

  vault_dir = nil,
  index_path = nil,
  root_dir = nil,

  dirty = false,
  dirty_since_last_backup = false,

  index = nil,

  notes_by_id = {},
  notes_by_file = {},
  note_ids_by_target = {},
  target_paths_by_dir = {},

  context = {
    last = nil,
    association = nil,
  },

  timers = {
    save = nil,
    sidebar = nil,
  },

  sidebar = {
    open = false,
    win = nil,
    buf = nil,
    mode = "all",
    all_sort = "date",
    current_dir = nil,
    current_target = nil,
    lines = {},
    line_items = {},
    note_wins = {},
    note_bufs = {},
    source_win = nil,
    preview_win = nil,
    preview_buf = nil,
    preview_note_id = nil,
    calendar_date = nil,
    calendar_cursor = nil,
    calendar_notes_win = nil,
    calendar_notes_buf = nil,
    calendar_notes_lines = {},
    calendar_notes_items = {},
  },
}

function M.setup(config)
  state.config = config
  state.vault_dir = config.vault_dir
  state.index_path = config.vault_dir .. "/index.json"
  state.root_dir = vim.fn.fnamemodify(vim.loop.cwd(), ":p"):gsub("/$", "")
  state.sidebar.mode = config.sidebar.default_mode or "all"
  if state.sidebar.mode == "agenda" then
    state.sidebar.mode = "calendar"
  end
  state.sidebar.all_sort = config.sidebar.default_all_sort or "date"
  state.sidebar.current_dir = nil
  state.sidebar.current_target = nil
  state.sidebar.lines = {}
  state.sidebar.line_items = {}
  state.sidebar.note_wins = {}
  state.sidebar.note_bufs = {}
  state.sidebar.source_win = nil
  state.sidebar.preview_win = nil
  state.sidebar.preview_buf = nil
  state.sidebar.preview_note_id = nil
  state.sidebar.calendar_date = os.date("%Y-%m-%d")
  state.sidebar.calendar_cursor = nil
  state.sidebar.calendar_notes_win = nil
  state.sidebar.calendar_notes_buf = nil
  state.sidebar.calendar_notes_lines = {}
  state.sidebar.calendar_notes_items = {}
  state.context.last = nil
  state.context.association = nil
end

function M.get()
  return state
end

function M.mark_dirty()
  state.dirty = true
  state.dirty_since_last_backup = true
end

function M.clear_dirty()
  state.dirty = false
end

function M.clear_backup_dirty()
  state.dirty_since_last_backup = false
end

return M
