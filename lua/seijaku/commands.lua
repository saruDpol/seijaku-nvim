local M = {}

function M.setup()
  vim.api.nvim_create_user_command("SeijakuToggle", function()
    require("seijaku").toggle_sidebar()
  end, {})

  vim.api.nvim_create_user_command("SeijakuOpenSidebar", function()
    require("seijaku").open_sidebar()
  end, {})

  vim.api.nvim_create_user_command("SeijakuCloseSidebar", function()
    require("seijaku").close_sidebar()
  end, {})

  vim.api.nvim_create_user_command("SeijakuModeAll", function()
    require("seijaku").mode_all()
  end, {})

  vim.api.nvim_create_user_command("SeijakuModeDirectory", function()
    require("seijaku").mode_directory()
  end, {})

  vim.api.nvim_create_user_command("SeijakuToggleMode", function()
    require("seijaku").toggle_mode()
  end, {})

  vim.api.nvim_create_user_command("SeijakuNew", function()
    require("seijaku").new_note()
  end, {})

  vim.api.nvim_create_user_command("SeijakuNewForCurrent", function()
    require("seijaku").new_note_for_current()
  end, {})

  vim.api.nvim_create_user_command("SeijakuNewForPath", function(args)
    require("seijaku").new_note_for_path(args.args)
  end, {
    nargs = 1,
    complete = "file",
  })

  vim.api.nvim_create_user_command("SeijakuAttachPath", function(args)
    if #args.fargs < 2 then
      vim.notify("seijaku: usage :SeijakuAttachPath <note_id> <path>", vim.log.levels.ERROR)
      return
    end

    require("seijaku").attach_path(args.fargs[1], args.fargs[2])
  end, {
    nargs = "+",
    complete = function(_, line)
      local parts = vim.split(line, "%s+", { trimempty = true })

      if #parts <= 2 then
        local items = {}
        for _, note in ipairs(require("seijaku.index").list_notes()) do
          table.insert(items, note.id)
        end
        return items
      end

      return vim.fn.getcompletion(parts[#parts] or "", "file")
    end,
  })

  vim.api.nvim_create_user_command("SeijakuDetachPath", function(args)
    if #args.fargs < 2 then
      vim.notify("seijaku: usage :SeijakuDetachPath <note_id> <path>", vim.log.levels.ERROR)
      return
    end

    require("seijaku").detach_path(args.fargs[1], args.fargs[2])
  end, {
    nargs = "+",
    complete = function(_, line)
      local parts = vim.split(line, "%s+", { trimempty = true })

      if #parts <= 2 then
        local items = {}
        for _, note in ipairs(require("seijaku.index").list_notes()) do
          table.insert(items, note.id)
        end
        return items
      end

      return vim.fn.getcompletion(parts[#parts] or "", "file")
    end,
  })

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
