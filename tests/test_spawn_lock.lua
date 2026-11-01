-- Spawn lock lifecycle: the decisions as event sequences, the file effects of
-- each step, and a steal under contention. Run: nvim -l tests/test_spawn_lock.lua (or via tests/run.sh)

local uv = vim.uv

local this = debug.getinfo(1, 'S').source:sub(2)
local this_abs = uv.fs_realpath(this) or this
local H = dofile(vim.fs.dirname(this_abs) .. '/helpers.lua')
H.ensure_isolated('spawn_lock', this_abs)

package.path = H.root .. '/lua/?.lua;' .. H.root .. '/lua/?/init.lua;' .. package.path
local lock = require('openloc.cli.spawn_lock')
local ok = H.ok

local BASE = H.mkdir(vim.env.OLTEST_BASE .. '/spawn_lock')
local NOW = 1000000
local A = { sock = '/r/ws-w1-s11.sock', pid = 11 }
local B = { sock = '/r/ws-w1-s22.sock', pid = 22 }
local C = { sock = '/r/ws-w1-s33.sock', pid = 33 }

local PAST_WINDOW_S = lock.FRESH_MS / 1000 + 1

local function file_of(owner, age_s)
  return { sock = owner.sock, pid = owner.pid, mtime = NOW - (age_s or 0) }
end

-- What `who` decides on `event` when the lock file is `file` at time now.
local function decide(file, now, who, event, joined)
  return lock.decide(lock.classify(file, now, who, joined), event)
end

print('== decisions ==')
do
  ok(decide(nil, NOW, A, 'acquire') == 'acquire', 'no lock: the first click acquires')
  ok(decide(file_of(A), NOW + 2, B, 'acquire') == 'join', 'a click inside the boot window joins the spawner')
  ok(decide(file_of(A, PAST_WINDOW_S), NOW, B, 'acquire') == 'steal', 'a click past the boot window steals')
  ok(decide({ mtime = NOW }, NOW, B, 'acquire') == 'steal', 'a lock naming no socket is stolen, there is nothing to join')
  ok(decide(file_of(A), NOW + 4, B, 'join_timed_out', A) == 'steal',
    'a join timeout steals the lock it waited on, though still inside the window')
  ok(decide(file_of(C), NOW + 4, B, 'join_timed_out', A) == 'give_up',
    'a join timeout gives up when someone else re-took the lock')
  ok(decide(nil, NOW + 4, B, 'join_timed_out', A) == 'acquire',
    'a join timeout acquires when the spawner released the lock')
  ok(decide(file_of(A), NOW, A, 'spawn_failed') == 'release', 'a failed spawn releases its own lock')
  ok(decide(file_of(B), NOW, A, 'spawn_failed') == 'keep', 'a failed spawn never releases another spawner lock')
  ok(decide(file_of(A), NOW, A, 'spawned') == 'keep', 'a successful spawn keeps its lock to cover the editor boot')
end

print('== every state and event is decided ==')
do
  local files = { absent = nil, mine = file_of(A), fresh = file_of(B), stale = file_of(B, PAST_WINDOW_S) }
  local valid = { acquire = true, steal = true, join = true, give_up = true, release = true, keep = true }
  local undecided = {}
  for _, kind in ipairs({ 'absent', 'mine', 'fresh', 'stale' }) do
    local state = lock.classify(files[kind], NOW, A)
    ok(state.kind == kind, 'classify: ' .. kind, state.kind)
    for _, event in ipairs({ 'acquire', 'join_timed_out', 'spawn_failed', 'spawned' }) do
      local good, action = pcall(lock.decide, state, event)
      if not (good and valid[action]) then
        undecided[#undecided + 1] = kind .. '/' .. event
      end
    end
  end
  ok(#undecided == 0, 'every state and event pair maps to an action', table.concat(undecided, ' '))
  ok(not pcall(lock.decide, { kind = 'absent' }, 'bogus'), 'an unknown event is rejected')
end

print('== steps on the file ==')
do
  local path = BASE .. '/seq/spawn-ws-w1.lock'
  local a1, s1 = lock.step(path, A, 'acquire')
  ok(a1 == 'acquire' and s1.kind == 'absent', 'step: the first click acquires', tostring(a1))
  local a2, s2 = lock.step(path, B, 'acquire')
  ok(a2 == 'join' and s2.owner.sock == A.sock, 'step: the next click joins the socket the lock names', tostring(a2))
  ok(lock.step(path, B, 'spawn_failed') == 'keep' and uv.fs_stat(path) ~= nil,
    'step: a non-owner never removes the lock')
  ok(lock.step(path, A, 'spawned') == 'keep' and uv.fs_stat(path) ~= nil, 'step: a spawned owner keeps the lock')
  local a3 = lock.step(path, B, 'join_timed_out', s2.owner)
  ok(a3 == 'steal', 'step: the timed-out joiner steals', tostring(a3))
  local a4, s4 = lock.step(path, C, 'join_timed_out', s2.owner)
  ok(a4 == 'give_up' and s4.owner.sock == B.sock, 'step: a second timed-out joiner finds the steal and gives up',
    tostring(a4))
  ok(lock.step(path, B, 'spawn_failed') == 'release' and uv.fs_stat(path) == nil,
    'step: the owner of a failed spawn releases the lock')
end

print('== steal under contention ==')
do
  -- N processes reach the same stale lock at one instant, ROUNDS times over;
  -- each round must have exactly one winner.
  local N, ROUNDS, SLOT_US = 8, 30, 30000
  local dir = H.mkdir(BASE .. '/race')
  for r = 1, ROUNDS do
    local p = dir .. '/spawn-r' .. r .. '.lock'
    H.write_file(p, '/r/dead.sock\n1\n')
    uv.fs_utime(p, os.time() - 60, os.time() - 60)
  end
  local child = dir .. '/contender.lua'
  H.write_file(child, ([[
package.path = %q .. '/lua/?.lua;' .. package.path
local uv = vim.uv
local lock = require('openloc.cli.spawn_lock')
local dir, start = arg[1], tonumber(arg[2])
local me = { sock = '/r/c' .. uv.os_getpid() .. '.sock', pid = uv.os_getpid() }
local function now_us()
  local s, us = uv.gettimeofday()
  return s * 1e6 + us
end
for r = 1, %d do
  local at = start + (r - 1) * %d
  local wait_ms = math.floor((at - now_us()) / 1000) - 2
  if wait_ms > 0 then uv.sleep(wait_ms) end
  while now_us() < at do end
  io.stdout:write(r, ' ', tostring((lock.step(dir .. '/spawn-r' .. r .. '.lock', me, 'acquire'))), '\n')
end
]]):format(H.root, ROUNDS, SLOT_US))
  local s, us = uv.gettimeofday()
  local start = s * 1e6 + us + 600000
  local procs = {}
  for i = 1, N do
    procs[i] = H.spawn({ vim.v.progpath, '-l', child, dir, ('%d'):format(start) })
  end
  local wins, joins = {}, {}
  for r = 1, ROUNDS do
    wins[r], joins[r] = 0, 0
  end
  for i = 1, N do
    local res = procs[i]:wait(10000)
    for r, action in (res.stdout or ''):gmatch('(%d+) (%S+)') do
      r = tonumber(r)
      if action == 'steal' or action == 'acquire' then
        wins[r] = wins[r] + 1
      elseif action == 'join' then
        joins[r] = joins[r] + 1
      end
    end
  end
  local bad = {}
  for r = 1, ROUNDS do
    if wins[r] ~= 1 or joins[r] ~= N - 1 then
      bad[#bad + 1] = ('round %d: %d won, %d joined'):format(r, wins[r], joins[r])
    end
  end
  ok(#bad == 0, ('contention: one winner per stale lock across %d processes'):format(N), table.concat(bad, '; '))
end

H.summary()
