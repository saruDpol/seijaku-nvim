local M = {}

local config = require("seijaku.config")
local state = require("seijaku.state")
local index = require("seijaku.index")
local commands = require("seijaku.commands")
local autocmds = require("seijaku.autocmds")
local notes = require("seijaku.notes")
local context = require("seijaku.context")

function M.setup(opts)
  config.setup(opts or {})
  state.setup(config.get())

  index.ensure_vault()
  index.load()

  commands.setup()
  autocmds.setup()
end

function M.new_note()
  return notes.create_global()
end

function M.new_note_for_current()
  local ctx = context.get_current()

  if not ctx or not ctx.target_path then
    vim.notify("seijaku: no current filesystem target found", vim.log.levels.WARN)
    return
  end

  return notes.create_for_target(ctx.target_path, ctx.target_type)
end

function M.open_note(note_id)
  return notes.open(note_id)
end

function M.rebuild_index()
  return index.rebuild_derived_indexes()
end

return M
