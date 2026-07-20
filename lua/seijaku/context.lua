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
    local context_state = state_mod.get().context
    context_state.last = vim.deepcopy(ctx)
    context_state.association = vim.deepcopy(ctx)
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

  local directory_context = context_for_target(dir, "directory", "oil")
  local association_context = directory_context

  if type(oil.get_cursor_entry) == "function" then
    local entry = oil.get_cursor_entry()

    if entry and entry.name and entry.name ~= "" then
      local target_path = paths.join(dir, entry.name)
      local target_type = entry.type or paths.target_type(target_path)

      association_context = context_for_target(target_path, target_type, "oil")
    end
  end

  remember(directory_context)
  state.context.association = vim.deepcopy(association_context)

  return directory_context
end

local function netrw_context()
  local state = state_mod.get()

  if state.config
      and state.config.integrations
      and state.config.integrations.netrw == false then
    return nil
  end

  local dir = vim.b.netrw_curdir
  if type(dir) ~= "string" or dir == "" or dir:match("^%a[%w+.-]*://") then
    return nil
  end

  local directory_context = context_for_target(dir, "directory", "netrw")
  local association_context = directory_context
  local view = vim.fn.winsaveview()
  local ok_word, word = pcall(vim.fn["netrw#Call"], "NetrwGetWord")
  pcall(vim.fn.winrestview, view)

  if ok_word and type(word) == "string" and word ~= "" then
    local ok_path, target_path = pcall(vim.fn["netrw#Call"], "NetrwFile", word)
    if ok_path and type(target_path) == "string" and target_path ~= "" then
      local target_type = paths.target_type(target_path)
      if target_type ~= "unknown" then
        association_context = context_for_target(target_path, target_type, "netrw")
      end
    end
  end

  remember(directory_context)
  state.context.association = vim.deepcopy(association_context)

  return directory_context
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

  if filetype == "netrw" then
    return netrw_context() or fallback_context()
  end

  if filetype == "seijaku" then
    return fallback_context()
  end

  if not bufname or bufname == "" then
    return fallback_context()
  end

  local normalized = paths.normalize(bufname)

  if not normalized then
    return fallback_context()
  end

  -- Some viewers use a special buffer for real files (for example binary
  -- documents). Treat them as filesystem contexts when the backing path
  -- exists, regardless of extension.
  if buftype ~= "" and buftype ~= "acwrite" and not vim.loop.fs_stat(normalized) then
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

function M.get_association_target()
  local state = state_mod.get()
  local current_buf = vim.api.nvim_get_current_buf()

  if vim.bo.filetype == "oil" then
    oil_context()
    return state.context.association and vim.deepcopy(state.context.association) or fallback_context()
  end

  if vim.bo.filetype == "netrw" then
    netrw_context()
    return state.context.association and vim.deepcopy(state.context.association) or fallback_context()
  end

  if vim.bo.filetype == "seijaku"
      or (state.sidebar
        and state.sidebar.open
        and state.sidebar.note_bufs
        and state.sidebar.note_bufs[current_buf]) then
    return state.context.association and vim.deepcopy(state.context.association) or fallback_context()
  end

  return M.get_current()
end

return M
