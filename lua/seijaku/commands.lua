local M = {}

function M.setup()
  vim.api.nvim_create_user_command("SeijakuNew", function()
    require("seijaku").new_note()
  end, {})

  vim.api.nvim_create_user_command("SeijakuNewForCurrent", function()
    require("seijaku").new_note_for_current()
  end, {})

  vim.api.nvim_create_user_command("SeijakuOpen", function(args)
    require("seijaku").open_note(args.args)
  end, {
    nargs = 1,
    complete = function()
      local items = {}
      for _, note in ipairs(require("seijaku.index").list_notes()) do
        table.insert(items, note.id)
      end
      return items
    end,
  })

  vim.api.nvim_create_user_command("SeijakuRebuildIndex", function()
    require("seijaku.index").rebuild_derived_indexes()
    require("seijaku.index").save_sync()
    vim.notify("seijaku: index rebuilt")
  end, {})

  vim.api.nvim_create_user_command("SeijakuList", function()
    local notes = require("seijaku.index").list_notes()

    for _, note in ipairs(notes) do
      print(note.id .. "  " .. note.title)
    end
  end, {})
end

return M
