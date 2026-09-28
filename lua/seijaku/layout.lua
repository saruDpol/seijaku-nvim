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

function M.rebalance_sidebar(sidebar, width, preview_width, opts)
  if not M.is_valid_win(sidebar.win) then
    return
  end

  opts = opts or {}

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
  local selector_width = math.max(1, tonumber(sidebar.selector_width) or 3)
  local preview_target = math.max(5, tonumber(preview_width) or 5)
  local sidebar_target = width + selector_width + 1
  local preview_windows = { sidebar.preview_win, sidebar.note_header_win }

  if opts.full then
    -- Full layout has no host window: the sidebar keeps its compact geometry
    -- and the preview pair is the only flexible region.
    for _, win in ipairs(preview_windows) do
      if M.is_valid_win(win) then
        vim.wo[win].winfixwidth = false
      end
    end
  end

  for _, win in ipairs(sidebar_windows) do
    if M.is_valid_win(win) then
      vim.wo[win].winfixwidth = false
    end
  end
  if M.is_valid_win(sidebar.header_win) then
    pcall(vim.api.nvim_win_set_width, sidebar.header_win, sidebar_target)
  end
  if M.is_valid_win(sidebar.notebook_win) then
    pcall(vim.api.nvim_win_set_width, sidebar.notebook_win, selector_width)
  end
  if M.is_valid_win(sidebar.tag_win) then
    pcall(vim.api.nvim_win_set_width, sidebar.tag_win, selector_width)
  end
  pcall(vim.api.nvim_win_set_width, sidebar.win, width)

  for _, win in ipairs(sidebar_windows) do
    if M.is_valid_win(win) then
      vim.wo[win].winfixwidth = true
    end
  end

  if opts.full then
    sidebar.preview_width_initialized = true
  elseif M.is_valid_win(sidebar.preview_win) and not sidebar.preview_width_initialized then
    -- Apply the configured width once. Afterwards the preview is an ordinary,
    -- resizable editor pane and never participates in sidebar rebalancing.
    for _, win in ipairs(preview_windows) do
      if M.is_valid_win(win) then
        vim.wo[win].winfixwidth = true
        pcall(vim.api.nvim_win_set_width, win, preview_target)
      end
    end
    for _, win in ipairs(preview_windows) do
      if M.is_valid_win(win) then
        vim.wo[win].winfixwidth = false
      end
    end
    sidebar.preview_width_initialized = true
  end

  vim.o.winminwidth = min_width
  vim.o.winwidth = preferred_width
end

return M
