local M = {}

local paths = require("seijaku.paths")
local state_mod = require("seijaku.state")

local function fallback_context()
  local state = state_mod.get()

  if state.context.last then
    return vim.deepcopy(state.context.last)
  end

  return {
    source = "unknown",
    target_path = nil,
    target_type = "unknown",
    directory = paths.normalize(vim.loop.cwd()),
  }
end

local function context_for_target(target_path, target_type, source, note_id)
  local normalized = paths.normalize(target_path)

  if not normalized then
    return fallback_context()
  end

  target_type = target_type or paths.target_type(normalized)

  local directory
  if target_type == "directory" then
    directory = normalized
  else
    directory = paths.parent_dir(normalized)
  end

  return {
    source = source or "buffer",
    target_path = normalized,
    target_type = target_type,
    directory = directory,
    note_id = note_id,
  }
end

local function remember(ctx)
  if ctx and ctx.target_path and ctx.directory then
    state_mod.get().context.last = vim.deepcopy(ctx)
  end

  return ctx
end

local function oil_context()
  local state = state_mod.get()

  if state.config
      and state.config.integrations
      and state.config.integrations.oil == false then
    return nil
  end

  local ok, oil = pcall(require, "oil")
  if not ok or type(oil.get_current_dir) ~= "function" then
    return nil
  end

  local dir = oil.get_current_dir()

  if not dir or dir == "" then
    return nil
  end

  return remember(context_for_target(dir, "directory", "oil"))
end

function M.get_current()
  local state = state_mod.get()
  local current_buf = vim.api.nvim_get_current_buf()
  local buftype = vim.bo.buftype
  local filetype = vim.bo.filetype
  local bufname = vim.api.nvim_buf_get_name(0)

  if state.sidebar
      and state.sidebar.open
      and state.sidebar.note_bufs
      and state.sidebar.note_bufs[current_buf] then
    return fallback_context()
  end

  if filetype == "oil" then
    return oil_context() or fallback_context()
  end

  if buftype == "nofile" or filetype == "seijaku" then
    return fallback_context()
  end

  if not bufname or bufname == "" then
    return fallback_context()
  end

  local normalized = paths.normalize(bufname)

  if not normalized then
    return fallback_context()
  end

  local ok, index = pcall(require, "seijaku.index")
  if ok then
    local note = index.get_note_for_file(normalized)

    if note and note.targets and note.targets[1] then
      local target = note.targets[1]
      return remember(context_for_target(target.path, target.type, "note", note.id))
    end

    if note then
      return fallback_context()
    end
  end

  return remember(context_for_target(normalized, paths.target_type(normalized), "buffer"))
end

return M
