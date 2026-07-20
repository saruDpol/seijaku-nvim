local M = {}

local index = require("seijaku.index")
local util = require("seijaku.util")

local function normalize_text(value)
  return vim.trim(tostring(value or ""):gsub("[\r\n]+", " "))
end

local function refresh_sidebar()
  local ok, sidebar = pcall(require, "seijaku.sidebar")
  if ok then
    sidebar.refresh()
  end
end

function M.generate_id()
  local parts = util.date_parts()
  return string.format(
    "todo_%s%s%s_%s_%s",
    parts.year,
    parts.month,
    parts.day,
    os.date("%H%M%S"),
    util.random_hex(6)
  )
end

function M.create(opts)
  opts = opts or {}
  if opts.calendar_date and not require("seijaku.calendar").parse(opts.calendar_date) then
    vim.notify("seijaku: invalid todo date", vim.log.levels.ERROR)
    return false
  end
  vim.ui.input({ prompt = "Todo: " }, function(input)
    local text = normalize_text(input)
    if text == "" then
      return
    end

    local now = util.now()
    local todo = {
      id = M.generate_id(),
      text = text,
      created_at = now,
      updated_at = now,
      calendar_date = opts.calendar_date,
      completed_at = nil,
    }

    local ok, err = index.add_todo(todo)
    if not ok then
      vim.notify("seijaku: " .. tostring(err or "failed to create todo"), vim.log.levels.ERROR)
      return
    end
    if opts.on_created then
      opts.on_created(todo)
    end
    refresh_sidebar()
  end)
  return true
end

function M.toggle(todo_id)
  local todo = index.get_todo(todo_id)
  if not todo then
    return false, "todo not found"
  end
  if todo.completed_at then
    todo.completed_at = nil
  else
    todo.completed_at = util.now()
  end
  todo.updated_at = util.now()
  return index.update_todo(todo)
end

function M.rename(todo_id)
  local todo = index.get_todo(todo_id)
  if not todo then
    return false, "todo not found"
  end

  vim.ui.input({
    prompt = "Todo: ",
    default = todo.text or "",
  }, function(input)
    local text = normalize_text(input)
    if text == "" or text == todo.text then
      return
    end
    todo.text = text
    todo.updated_at = util.now()
    local ok, err = index.update_todo(todo)
    if not ok then
      vim.notify("seijaku: " .. tostring(err or "failed to rename todo"), vim.log.levels.ERROR)
      return
    end
    refresh_sidebar()
  end)
  return true
end

function M.delete(todo_id)
  return index.delete_todo(todo_id)
end

return M
