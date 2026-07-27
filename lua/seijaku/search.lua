local M = {}

local state_mod = require("seijaku.state")
local index = require("seijaku.index")
local paths = require("seijaku.paths")

local valid_note_types = {
  general = true,
  diary = true,
  meeting = true,
  desc = true,
}

local function unique_notes(grouped)
  local result = {}
  local seen = {}

  for _, notes in pairs(grouped or {}) do
    for _, note in ipairs(notes) do
      if note.id and not seen[note.id] then
        seen[note.id] = true
        table.insert(result, note)
      end
    end
  end

  return result
end

function M.notes_for_current_scope()
  local state = state_mod.get()
  local sidebar = state.sidebar

  if sidebar.mode ~= "all" and sidebar.mode ~= "directory" then
    return nil, "search is only available in all and directory modes"
  end

  if sidebar.mode == "all" then
    local filter = valid_note_types[sidebar.all_filter] and sidebar.all_filter or "all"
    local notes = index.query_notes({ sort = "updated", filter = filter })
    return notes, filter == "all" and "all notes" or (filter .. " notes")
  end

  local ctx = require("seijaku.context").get_current()
  local target = (sidebar.open and sidebar.current_target) or (ctx and ctx.target_path)
  if not target then
    return {}, "current directory"
  end

  local target_type = ctx and ctx.target_path == target and ctx.target_type or paths.target_type(target)
  if target_type == "directory" then
    return unique_notes(index.get_notes_for_tree(target)), "directory notes"
  end

  return index.get_notes_for_target(target), "target notes"
end

local function open_match(entry)
  if not entry then
    return
  end

  local filename = entry.path or entry.filename
  if not filename then
    return
  end

  local note = index.get_note_for_file(filename)
  if not note then
    return
  end

  local sidebar = require("seijaku.sidebar")
  local opened = sidebar.open_preview(note.id, { force = true, focus = true })
  if not opened then
    require("seijaku.notes").open(note.id)
  end

  local win = vim.api.nvim_get_current_win()
  local line_count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
  local line = math.max(1, math.min(tonumber(entry.lnum) or 1, line_count))
  local col = math.max(0, (tonumber(entry.col) or 1) - 1)
  pcall(vim.api.nvim_win_set_cursor, win, { line, col })
end

function M.live_grep()
  local state = state_mod.get()
  if state.config.integrations and state.config.integrations.telescope == false then
    vim.notify("seijaku: Telescope integration is disabled", vim.log.levels.WARN)
    return false
  end

  if vim.fn.executable("rg") ~= 1 then
    vim.notify("seijaku: ripgrep (rg) is required for live grep", vim.log.levels.WARN)
    return false
  end

  local ok_builtin, builtin = pcall(require, "telescope.builtin")
  local ok_actions, actions = pcall(require, "telescope.actions")
  local ok_state, action_state = pcall(require, "telescope.actions.state")
  if not ok_builtin or not ok_actions or not ok_state then
    vim.notify("seijaku: telescope.nvim is not available", vim.log.levels.WARN)
    return false
  end

  local scoped_notes, label = M.notes_for_current_scope()
  if not scoped_notes then
    vim.notify("seijaku: " .. label, vim.log.levels.INFO)
    return false
  end

  local search_dirs = {}
  for _, note in ipairs(scoped_notes) do
    if note.file then
      local abs_path = paths.normalize(paths.join(state.vault_dir, note.file))
      if abs_path and vim.fn.filereadable(abs_path) == 1 then
        table.insert(search_dirs, abs_path)
      end
    end
  end
  table.sort(search_dirs)

  if #search_dirs == 0 then
    vim.notify("seijaku: no notes in the current search scope", vim.log.levels.INFO)
    return false
  end

  builtin.live_grep({
    prompt_title = "Seijaku · " .. label,
    search_dirs = search_dirs,
    cwd = state.vault_dir,
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        vim.schedule(function()
          open_match(entry)
        end)
      end)
      return true
    end,
  })

  return true
end

return M
