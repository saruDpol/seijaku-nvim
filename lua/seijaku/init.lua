local M = {}

local config = require("seijaku.config")
local state = require("seijaku.state")
local index = require("seijaku.index")
local commands = require("seijaku.commands")
local autocmds = require("seijaku.autocmds")
local notes = require("seijaku.notes")
local context = require("seijaku.context")
local sidebar = require("seijaku.sidebar")

function M.setup(opts)
  config.setup(opts or {})
  state.setup(config.get())

  index.ensure_vault()
  local ok, err = index.load()
  if not ok then
    error("seijaku: " .. tostring(err), 0)
  end

  commands.setup()
  autocmds.setup()

  local keymaps = config.get().keymaps or {}
  if keymaps.enable_default ~= false and keymaps.toggle then
    vim.keymap.set("n", keymaps.toggle, function()
      require("seijaku").toggle_sidebar()
    end, {
      desc = "Toggle Seijaku sidebar",
      silent = true,
    })
  end

  if keymaps.enable_default ~= false and keymaps.new_for_current then
    vim.keymap.set("n", keymaps.new_for_current, function()
      require("seijaku").new_note_for_current()
    end, {
      desc = "Create Seijaku note for current buffer",
      silent = true,
      nowait = true,
    })
  end
end

function M.new_note()
  return notes.create_global()
end

function M.new_note_for_current()
  local ctx = context.get_association_target()

  if not ctx or not ctx.target_path then
    vim.notify("seijaku: no current filesystem target found", vim.log.levels.WARN)
    return
  end

  return notes.create_for_target(ctx.target_path, ctx.target_type)
end

function M.new_note_for_path(path)
  return notes.create_for_path(path)
end

function M.toggle_sidebar()
  return sidebar.toggle()
end

function M.open_sidebar()
  return sidebar.open()
end

function M.close_sidebar()
  return sidebar.close()
end

function M.mode_all()
  return sidebar.set_mode("all")
end

function M.mode_directory()
  return sidebar.set_mode("directory")
end

function M.mode_calendar()
  return sidebar.set_mode("calendar")
end

function M.toggle_mode()
  return sidebar.toggle_mode()
end

function M.open_note(note_id)
  return notes.open(note_id)
end

function M.attach_path(note_id, path)
  local target_type = require("seijaku.paths").target_type(path)
  local ok, err = index.attach(note_id, path, target_type)

  if not ok then
    vim.notify("seijaku: " .. tostring(err or "failed to attach path"), vim.log.levels.ERROR)
    return false
  end

  vim.notify("seijaku: attached path")
  sidebar.refresh()
  return true
end

function M.detach_path(note_id, path)
  local ok = index.detach(note_id, path)

  if not ok then
    vim.notify("seijaku: failed to detach path", vim.log.levels.ERROR)
    return false
  end

  vim.notify("seijaku: detached path")
  sidebar.refresh()
  return true
end

function M.rebuild_index()
  return index.rebuild_derived_indexes()
end

return M
