local M = {}

function M.expand(path)
  return vim.fn.expand(path)
end

function M.normalize(path)
  path = M.absolute(path)
  if not path then
    return nil
  end

  local real = vim.loop.fs_realpath(path)
  return real or path
end

-- Return a stable absolute path without touching the filesystem. This is the
-- right operation for paths already stored in the index: they may point to an
-- unmounted drive or to a project which is temporarily unavailable.
function M.absolute(path)
  if not path or path == "" then
    return nil
  end

  local is_absolute = path:sub(1, 1) == "/"
    or path:match("^%a:[/\\]") ~= nil
    or path:match("^[/\\][/\\]") ~= nil
  if not is_absolute then
    path = vim.fn.expand(path)
    path = vim.fn.fnamemodify(path, ":p")
  end

  if path ~= "/" then
    path = path:gsub("/$", "")
  end

  if path == "" then
    return nil
  end

  return path
end

function M.basename(path)
  return vim.fs.basename(path)
end

function M.parent_dir(path)
  if not path or path == "" then
    return nil
  end

  return M.normalize(vim.fn.fnamemodify(path, ":h"))
end

function M.parent_dir_absolute(path)
  if not path or path == "" then
    return nil
  end

  return M.absolute(vim.fs.dirname(path))
end

function M.join(...)
  local parts = { ... }
  local result = table.concat(parts, "/")
  result = result:gsub("//+", "/")
  return result
end

function M.target_type(path)
  local stat = vim.loop.fs_stat(path)

  if not stat then
    return "unknown"
  end

  if stat.type == "directory" then
    return "directory"
  end

  if stat.type == "file" then
    return "file"
  end

  return stat.type or "unknown"
end

function M.exists(path)
  if not path or path == "" then
    return false
  end

  if vim.loop.fs_stat(path) ~= nil then
    return true
  end

  local is_absolute = path:sub(1, 1) == "/"
    or path:match("^%a:[/\\]") ~= nil
    or path:match("^[/\\][/\\]") ~= nil
  if is_absolute then
    return false
  end

  local normalized = M.normalize(path)
  return normalized ~= nil and vim.loop.fs_stat(normalized) ~= nil
end

function M.relative_to(base, path)
  base = M.normalize(base)
  path = M.normalize(path)

  if not base or not path then
    return nil
  end

  if path:sub(1, #base) == base then
    local rel = path:sub(#base + 2)
    return rel
  end

  return path
end

function M.inside_dir(path, dir)
  path = M.normalize(path)
  dir = M.normalize(dir)

  if not path or not dir then
    return false
  end

  return path == dir or path:sub(1, #dir + 1) == dir .. "/"
end

return M
