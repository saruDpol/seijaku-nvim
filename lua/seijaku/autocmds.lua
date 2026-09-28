local M = {}

function M.setup()
  local group = vim.api.nvim_create_augroup("Seijaku", { clear = true })
  local sidebar = require("seijaku.sidebar")
  local previous_win = vim.api.nvim_get_current_win()

  sidebar.define_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = sidebar.define_highlights,
  })

  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      local entered_win = vim.api.nvim_get_current_win()
      local from_win = previous_win
      previous_win = entered_win
      sidebar.redirect_sidebar_entry(from_win, entered_win)
    end,
  })

  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = group,
    callback = function()
      if require("seijaku.state").get().sidebar.open then
        sidebar.schedule_layout_rebalance()
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(args)
      local state = require("seijaku.state").get()

      local sidebar = state.sidebar
      local managed = args.buf == sidebar.buf
        or args.buf == sidebar.calendar_notes_buf
        or args.buf == sidebar.preview_buf
        or sidebar.note_bufs[args.buf] == true

      if managed then
        return
      end

      if vim.bo[args.buf].filetype == "netrw" then
        require("seijaku.context").get_current()
      end

      -- Entering an unrelated buffer changes context, not note data. Avoid a
      -- full sidebar render here; index changes refresh the sidebar themselves.
    end,
  })

  local function capture_netrw(buf, refresh)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= "netrw" then
        return
      end

      local win = vim.fn.bufwinid(buf)
      if win == -1 or not vim.api.nvim_win_is_valid(win) then
        return
      end

      vim.api.nvim_win_call(win, function()
        require("seijaku.context").get_current()
      end)

      local state = require("seijaku.state").get()
      if refresh and state.sidebar.open then
        require("seijaku.sidebar").schedule_refresh()
      end
    end)
  end

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "netrw",
    callback = function(args)
      capture_netrw(args.buf, true)
    end,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    callback = function(args)
      if vim.bo[args.buf].filetype == "netrw" then
        capture_netrw(args.buf, false)
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "OilEnter",
    callback = function(args)
      local state = require("seijaku.state").get()
      local oil_buf = args.data and args.data.buf or nil
      local source_win = state.sidebar.source_win

      if oil_buf and vim.api.nvim_get_current_buf() == oil_buf then
        require("seijaku.context").get_current()
      elseif oil_buf
          and source_win
          and vim.api.nvim_win_is_valid(source_win)
          and vim.api.nvim_win_get_buf(source_win) == oil_buf then
        vim.api.nvim_win_call(source_win, function()
          require("seijaku.context").get_current()
        end)
      end

      -- Capturing Oil context is enough. The sidebar content did not change.
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePre", {
    group = group,
    callback = function(args)
      local file_path = vim.api.nvim_buf_get_name(args.buf)
      local index = require("seijaku.index")

      if index.touch_note_for_file(file_path) then
        require("seijaku.notes").clean_legacy_metadata(index.get_note_for_file(file_path), args.buf, {
          write = false,
        })
        local state = require("seijaku.state").get()
        if state.sidebar.open then
          require("seijaku.sidebar").schedule_refresh()
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function()
      vim.schedule(function()
        local state = require("seijaku.state").get()
        if state.sidebar.open then
          require("seijaku.sidebar").reconcile_note_windows()
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufWinLeave", "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(args)
      local sidebar_state = require("seijaku.state").get().sidebar
      if not sidebar_state.open
          or (args.buf ~= sidebar_state.preview_buf and args.buf ~= sidebar_state.note_header_buf) then
        return
      end
      vim.schedule(function()
        require("seijaku.sidebar").reconcile_note_windows()
      end)
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      require("seijaku.index").save_sync()
      require("seijaku.index").stop_watcher()
    end,
  })
end

return M
