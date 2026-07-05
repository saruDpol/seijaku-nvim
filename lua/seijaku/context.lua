local M = {}

local paths = require("seijaku.paths")

function M.get_current()
  local bufname = vim.api.nvim_buf_get_name(0)

  if not bufname or bufname == "" then
    return {
      source = "unknown",
      target_path = nil,
      target_type = "unknown",
      directory = vim.loop.cwd(),
    }
  end

  local normalized = paths.normalize(bufname)

  if not normalized then
    return {
      source = "unknown",
      target_path = nil,
      target_type = "unknown",
      directory = vim.loop.cwd(),
    }
  end

  local target_type = paths.target_type(normalized)

  local directory
  if target_type == "directory" then
    directory = normalized
  else
    directory = paths.parent_dir(normalized)
  end

  return {
    source = "buffer",
    target_path = normalized,
    target_type = target_type,
    directory = directory,
  }
end

return M
