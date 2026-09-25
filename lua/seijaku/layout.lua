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
  for _, win in ipairs({ sidebar.win, sidebar.preview_win, sidebar.calendar_notes_win }) do
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

function M.rebalance_sidebar(sidebar, width)
  if M.is_valid_win(sidebar.win) then
    vim.wo[sidebar.win].winfixwidth = true
    pcall(vim.api.nvim_win_set_width, sidebar.win, width)
  end
end

return M
