local M = {}

local state = {
  config = nil,

  vault_dir = nil,
  index_path = nil,
  root_dir = nil,

  dirty = false,
  index = nil,

  notes_by_id = {},
  notebooks_by_id = {},
  notes_by_file = {},
  note_ids_by_target = {},
  target_paths_by_dir = {},
  note_ids_by_date = {},
  note_ids_by_notebook = {},
  calendar_counts_by_month = {},

  context = {
    last = nil,
    association = nil,
  },

  sidebar = {
    open = false,
    win = nil,
    buf = nil,
    header_win = nil,
    header_buf = nil,
    notebook_win = nil,
    notebook_buf = nil,
    tag_win = nil,
    tag_buf = nil,
    mode = "all",
    all_sort = "updated",
    all_tag = "all",
    all_notebook = "all",
    title_filter = "",
    search_active = false,
    lines = {},
    line_items = {},
    notebook_items = {},
    tag_items = {},
    selector_width = 3,
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
    calendar_day_input = "",
    closing = false,
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
  if state.sidebar.mode ~= "all" and state.sidebar.mode ~= "calendar" then
    state.sidebar.mode = "all"
  end
  state.sidebar.all_sort = config.sidebar.default_all_sort or "updated"
  state.sidebar.all_tag = "all"
  state.sidebar.all_notebook = "all"
  state.sidebar.title_filter = ""
  state.sidebar.search_active = false
  state.sidebar.lines = {}
  state.sidebar.line_items = {}
  state.sidebar.notebook_items = {}
  state.sidebar.tag_items = {}
  state.sidebar.selector_width = 3
  state.sidebar.header_win = nil
  state.sidebar.header_buf = nil
  state.sidebar.notebook_win = nil
  state.sidebar.notebook_buf = nil
  state.sidebar.tag_win = nil
  state.sidebar.tag_buf = nil
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
  state.sidebar.calendar_day_input = ""
  state.sidebar.closing = false
  state.context.last = nil
  state.context.association = nil
end

function M.get()
  return state
end

function M.mark_dirty()
  state.dirty = true
end

function M.clear_dirty()
  state.dirty = false
end

return M
