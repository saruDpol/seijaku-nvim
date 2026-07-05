local M = {}

local random_seeded = false

local function seed_random()
  if random_seeded then
    return
  end

  local hrtime = vim.loop.hrtime()
  local seed = os.time() + tonumber(tostring(hrtime):sub(-9))

  math.randomseed(seed)
  math.random()
  math.random()
  math.random()

  random_seeded = true
end

function M.now()
  return os.date("%Y-%m-%dT%H:%M:%S%z")
end

function M.date_parts()
  return {
    year = os.date("%Y"),
    month = os.date("%m"),
    day = os.date("%d"),
  }
end

function M.random_hex(length)
  seed_random()

  local chars = {}

  for _ = 1, length do
    table.insert(chars, string.format("%x", math.random(0, 15)))
  end

  return table.concat(chars)
end

function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "seijaku.nvim" })
end

function M.path_exists(path)
  return vim.loop.fs_stat(path) ~= nil
end

function M.mkdir_p(path)
  vim.fn.mkdir(path, "p")
end

function M.write_file(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines, path)
end

function M.read_file(path)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end

  return table.concat(vim.fn.readfile(path), "\n")
end

return M
