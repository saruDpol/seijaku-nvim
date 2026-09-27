local M = {}

function M.is_valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

function M.normal_windows()
  local result = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if M.is_valid_win(win) and vim.api.nvim_win_get_config(win).relative == "" then
      table.insert(result, win)
    end
  end
  return result
end

function M.managed_windows(sidebar)
  local result = {}
  for _, win in ipairs({
    sidebar.win,
    sidebar.header_win,
    sidebar.notebook_win,
    sidebar.tag_win,
    sidebar.note_header_win,
    sidebar.preview_win,
    sidebar.calendar_notes_win,
  }) do
    if M.is_valid_win(win) then
      result[win] = true
    end
  end
  return result
end

function M.external_windows(sidebar)
  local managed = M.managed_windows(sidebar)
  local result = {}
  for _, win in ipairs(M.normal_windows()) do
    if not managed[win] then
      table.insert(result, win)
    end
  end
  return result
end

function M.rebalance_sidebar(sidebar, width, preview_width)
  if not M.is_valid_win(sidebar.win) then
    return
  end

  -- Resize the sidebar as a single fixed-width group, then give the columns it
  -- releases to the original editor window. Otherwise Neovim may spend them
  -- widening the notebook/tag selectors or the sidebar header.
  local min_width = vim.o.winminwidth
  local preferred_width = vim.o.winwidth
  vim.o.winminwidth = 1
  vim.o.winwidth = 1

  local sidebar_windows = {
    sidebar.win,
    sidebar.header_win,
    sidebar.notebook_win,
    sidebar.tag_win,
  }
  for _, win in ipairs(sidebar_windows) do
    if M.is_valid_win(win) then
      vim.wo[win].winfixwidth = false
    end
  end

  local selector_width = math.max(1, tonumber(sidebar.selector_width) or 3)
  local preview_target = math.max(5, tonumber(preview_width) or 5)
  local sidebar_target = width + selector_width + 1
  local initialize_preview = M.is_valid_win(sidebar.preview_win) and not sidebar.preview_width_initialized
  local source = sidebar.source_win
  local source_fixed
  if M.is_valid_win(source) then
    source_fixed = vim.wo[source].winfixwidth
    vim.wo[source].winfixwidth = false
    local current_source_width = vim.api.nvim_win_get_width(source)
    local current_sidebar_width = M.is_valid_win(sidebar.header_win)
      and vim.api.nvim_win_get_width(sidebar.header_win)
      or sidebar_target
    local current_preview_width = initialize_preview and M.is_valid_win(sidebar.preview_win)
      and vim.api.nvim_win_get_width(sidebar.preview_win)
      or preview_target
    local released = (current_sidebar_width - sidebar_target) + (current_preview_width - preview_target)
    pcall(vim.api.nvim_win_set_width, source, math.max(1, current_source_width + released))
    vim.wo[source].winfixwidth = true
  end

  if M.is_valid_win(sidebar.notebook_win) then
    pcall(vim.api.nvim_win_set_width, sidebar.notebook_win, selector_width)
  end
  if M.is_valid_win(sidebar.tag_win) then
    pcall(vim.api.nvim_win_set_width, sidebar.tag_win, selector_width)
  end
  pcall(vim.api.nvim_win_set_width, sidebar.win, width)
  if M.is_valid_win(sidebar.header_win) then
    pcall(vim.api.nvim_win_set_width, sidebar.header_win, sidebar_target)
  end
  if initialize_preview then
    pcall(vim.api.nvim_win_set_width, sidebar.preview_win, preview_target)
    sidebar.preview_width_initialized = true
  end

  for _, win in ipairs(sidebar_windows) do
    if M.is_valid_win(win) then
      vim.wo[win].winfixwidth = true
    end
  end
  if M.is_valid_win(source) then
    vim.wo[source].winfixwidth = source_fixed
  end
  vim.o.winminwidth = min_width
  vim.o.winwidth = preferred_width
end

return M
