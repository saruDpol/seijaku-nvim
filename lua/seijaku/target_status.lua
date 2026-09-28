local M = {}

local uv = vim.uv or vim.loop
local cache = {}
local queued = {}
local queue = {}
local active = 0
local generation = 0

local max_parallel = 4
local ttl_ms = 30000
local on_change = nil

local function now_ms()
  return uv.hrtime() / 1000000
end

local function notify_change()
  if on_change then
    on_change()
  end
end

local run_next

local function complete(path, stat)
  local previous = cache[path]
  cache[path] = {
    exists = stat ~= nil,
    type = stat and stat.type or "unknown",
    checked_at = now_ms(),
  }
  queued[path] = nil
  active = active - 1

  if not previous or previous.exists ~= cache[path].exists or previous.type ~= cache[path].type then
    notify_change()
  end
  run_next()
end

run_next = function()
  while active < max_parallel and #queue > 0 do
    local path = table.remove(queue, 1)
    local request_generation = generation
    active = active + 1
    uv.fs_stat(path, function(_, stat)
      vim.schedule(function()
        if request_generation == generation then
          complete(path, stat)
        end
      end)
    end)
  end
end

local function enqueue(path)
  if queued[path] then
    return
  end
  queued[path] = true
  table.insert(queue, path)
  run_next()
end

-- Return the last known status immediately and refresh it in the background
-- when absent or stale. Callers never wait for slow mounts or missing paths.
function M.get(path)
  if not path or path == "" then
    return nil
  end

  local status = cache[path]
  if not status or now_ms() - status.checked_at >= ttl_ms then
    enqueue(path)
  end
  return status
end

function M.invalidate(path)
  if path then
    cache[path] = nil
  else
    cache = {}
  end
end

function M.setup(opts)
  opts = opts or {}
  max_parallel = math.max(1, math.floor(opts.max_parallel or max_parallel))
  ttl_ms = math.max(0, math.floor(opts.ttl_ms or ttl_ms))
  on_change = opts.on_change
end

function M.clear()
  generation = generation + 1
  cache = {}
  queued = {}
  queue = {}
  active = 0
end

return M
