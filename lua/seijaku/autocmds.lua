local M = {}

function M.setup()
  local group = vim.api.nvim_create_augroup("Seijaku", { clear = true })

  vim.api.nvim_create_autocmd({ "BufEnter", "DirChanged" }, {
    group = group,
    callback = function()
      local state = require("seijaku.state").get()

      if state.sidebar.open then
        require("seijaku.sidebar").schedule_refresh()
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(args)
      local file_path = vim.api.nvim_buf_get_name(args.buf)

      if require("seijaku.index").touch_note_for_file(file_path) then
        local state = require("seijaku.state").get()
        if state.sidebar.open then
          require("seijaku.sidebar").schedule_refresh()
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      require("seijaku.index").save_sync()
    end,
  })
end

return M
