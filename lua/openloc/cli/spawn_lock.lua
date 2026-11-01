-- Spawn lock lifecycle. The lock names the socket a just-spawned editor will
-- listen on, so clicks during its boot join it instead of spawning another.
-- classify and decide hold every rule; step is the only code that touches
-- the file.

local uv = vim.uv
local key = require('openloc.key')

local M = {}

-- A spawned editor publishes its socket well inside this window.
M.FRESH_MS = 10000

local LOCK_MODE = tonumber('600', 8)
local GUARD_WAIT_MS = 250

local function same(a, b)
  return a ~= nil and b ~= nil and a.sock == b.sock and a.pid == b.pid
end

-- file: nil when absent, else { sock, pid, mtime } as read; me and joined are
-- owners { sock, pid }. Returns one of
--   { kind = 'absent' }
--   { kind = 'mine',  owner }  this process wrote it
--   { kind = 'fresh', owner }  another spawner, inside its boot window
--   { kind = 'stale', owner }  a spawn that never came up: past the window,
--                              naming no socket, or the one `joined` waited out
function M.classify(file, now, me, joined)
  if not file then
    return { kind = 'absent' }
  end
  local owner = { sock = file.sock, pid = file.pid }
  if same(owner, me) then
    return { kind = 'mine', owner = owner }
  end
  if owner.sock and not same(owner, joined) and (now - file.mtime) * 1000 < M.FRESH_MS then
    return { kind = 'fresh', owner = owner }
  end
  return { kind = 'stale', owner = owner }
end

-- Events: acquire (no editor found, about to spawn), join_timed_out (the
-- joined editor never came up), spawn_failed, spawned. Actions: acquire and
-- steal write this process's lock and spawn; join; give_up; release removes
-- this process's lock; keep.
local RULES = {
  acquire = { absent = 'acquire', mine = 'acquire', fresh = 'join', stale = 'steal' },
  -- fresh here is someone else's spawn that started while this click waited.
  join_timed_out = { absent = 'acquire', mine = 'acquire', fresh = 'give_up', stale = 'steal' },
  spawn_failed = { absent = 'keep', mine = 'release', fresh = 'keep', stale = 'keep' },
  -- The spawner exits before its editor listens, so the lock stays to cover
  -- the boot window and ages out to stale.
  spawned = { absent = 'keep', mine = 'keep', fresh = 'keep', stale = 'keep' },
}

function M.decide(state, event)
  local action = RULES[event] and RULES[event][state.kind]
  if not action then
    error(('spawn lock: no rule for event %s in state %s'):format(tostring(event), tostring(state.kind)))
  end
  return action
end

local function read(path)
  local st = uv.fs_stat(path)
  local f = st and io.open(path, 'r')
  if not f then
    return nil
  end
  local sock = f:read('*l')
  local pid = tonumber(f:read('*l') or '')
  f:close()
  return { sock = sock ~= '' and sock or nil, pid = pid, mtime = st.mtime.sec }
end

local function write(path, me)
  local fd = uv.fs_open(path, 'w', LOCK_MODE)
  if not fd then
    return false
  end
  uv.fs_write(fd, me.sock .. '\n' .. tostring(me.pid) .. '\n')
  uv.fs_close(fd)
  return true
end

-- No filesystem call is compare-and-replace (rename clobbers a fresh lock,
-- unlink then create lets a slow stealer delete one), so a kernel flock
-- serializes read-decide-write; it dies with its holder, so it cannot go
-- stale. Without LuaJIT's ffi there is no flock and steps run unguarded.
local LOCK_EX, LOCK_NB = 2, 4
local flock = (function()
  local ok, ffi = pcall(require, 'ffi')
  if not ok then
    return nil
  end
  pcall(ffi.cdef, 'int flock(int fd, int operation);')
  local found, fn = pcall(function()
    return ffi.C.flock
  end)
  return found and fn or nil
end)()

local function guarded(dir, fn)
  local fd = uv.fs_open(dir .. '/spawn.guard', 'a', LOCK_MODE)
  if not fd then
    return nil, 'cannot open ' .. dir .. '/spawn.guard'
  end
  if flock then
    local t0 = uv.hrtime()
    while flock(fd, LOCK_EX + LOCK_NB) ~= 0 do
      if (uv.hrtime() - t0) / 1e6 >= GUARD_WAIT_MS then
        uv.fs_close(fd)
        return nil, 'spawn guard held by another process'
      end
      uv.sleep(2)
    end
  end
  local action, detail = fn()
  uv.fs_close(fd)
  return action, detail
end

-- Apply one event to the lock at path on behalf of me = { sock, pid };
-- joined is the owner a timed-out join waited on. Returns the action and the
-- observed state, or nil and an error.
function M.step(path, me, event, joined)
  local dir = vim.fs.dirname(path)
  vim.fn.mkdir(dir, 'p', key.DIR_MODE)
  return guarded(dir, function()
    local state = M.classify(read(path), os.time(), me, joined)
    local action = M.decide(state, event)
    if (action == 'acquire' or action == 'steal') and not write(path, me) then
      return nil, 'cannot write ' .. path
    elseif action == 'release' then
      os.remove(path)
    end
    return action, state
  end)
end

return M
