-- The spawn fallback when no editor is running: herdr split, OPENLOC_SPAWN, and the spawn lock.
-- Run: nvim -l tests/test_cli_spawn.lua (or via tests/run.sh)

local uv = vim.uv

local this = debug.getinfo(1, 'S').source:sub(2)
local this_abs = uv.fs_realpath(this) or this
local H = dofile(vim.fs.dirname(this_abs) .. '/helpers.lua')
H.ensure_isolated('cli_spawn', this_abs)
local S = dofile(H.tests_dir .. '/scenario.lua')(H, 'cli_spawn')

local ok = H.ok
local scenario, run_cli, jdecode, rpc_eval, slurp = S.scenario, S.run_cli, S.jdecode, S.rpc_eval, S.slurp

print('== herdr action env spawn ==')
do
  -- A plugin action or link handler receives ONLY HERDR_PLUGIN_* vars, no
  -- pane-inherited HERDR_*; the split fallback must still fire.
  local s = scenario('spawnh')
  H.lines_file(s.work .. '/f.txt', 20)
  local stubdir, log = S.spawn_stub(s, 'stub')
  local r = run_cli(s, { 'open', 'f.txt', '--json' }, {
    path_prefix = stubdir,
    env = { HERDR_PLUGIN_CONTEXT_JSON = S.plugin_ctx(s), HERDR_PLUGIN_ROOT = stubdir },
  })
  local obj = jdecode(r.stdout)
  ok(r.code == 0, 'spawnh: default --spawn split spawns via herdr (exit 0)',
    r.code .. ' ' .. (r.stderr or ''))
  ok(obj and obj.spawned == true, 'spawnh: json reports spawned', r.stdout)
  ok(obj and obj.live_map_used == true, 'spawnh: live map consulted (herdr reachable)')
  local f = io.open(log, 'r')
  local logged = f and f:read('*a') or ''
  if f then
    f:close()
  end
  ok(logged:find('pane split', 1, true) ~= nil, 'spawnh: stub received pane split', logged)
  ok(logged:find('pane run', 1, true) ~= nil, 'spawnh: stub received pane run', logged)
end

print('== OPENLOC_SPAWN detached ==')
do
  local s = scenario('spawne')
  H.lines_file(s.work .. '/f.txt', 20)
  local bindir = H.mkdir(s.dir .. '/bin')
  local marker = s.dir .. '/ed-ran'
  H.write_exec(bindir .. '/slow-ed', ('#!/bin/sh\ntouch "%s"\nsleep 8\n'):format(marker))
  local r = run_cli(s, { 'open', 'f.txt', '--json' }, {
    env = { OPENLOC_SPAWN = '1', EDITOR = bindir .. '/slow-ed' },
  })
  local obj = jdecode(r.stdout)
  ok(r.code == 0, 'spawne: exits 0', r.code .. ' ' .. (r.stderr or ''))
  ok(r.ms < 3000, ('spawne: returns without waiting on the editor (%.0fms)'):format(r.ms))
  ok(obj and obj.spawned == true, 'spawne: json reports spawned', r.stdout)
  local ran = vim.wait(2000, function()
    return uv.fs_stat(marker) ~= nil
  end, 20)
  ok(ran, 'spawne: detached editor actually launched')
end

print('== spawn lock ==')
do
  local spawn_stub, ctx_of = S.spawn_stub, S.plugin_ctx

  -- first spawn takes the lock and starts nvim on the registry socket
  local s = scenario('slock')
  H.lines_file(s.work .. '/f.txt', 20)
  local stub, log = spawn_stub(s, 'stub')
  local r = run_cli(s, { 'open', 'f.txt', '--json' }, {
    path_prefix = stub,
    env = { HERDR_PLUGIN_CONTEXT_JSON = ctx_of(s), HERDR_PLUGIN_ROOT = stub },
  })
  ok(r.code == 0 and (jdecode(r.stdout) or {}).spawned == true, 'slock: spawner exits 0 spawned', r.stdout)
  local locks = vim.fn.glob(s.cache .. '/nvim/openloc/spawn-*.lock', true, true)
  ok(#locks == 1, 'slock: spawn lock written', vim.inspect(locks))
  local logged = slurp(log)
  ok(logged:find('--listen', 1, true) ~= nil, 'slock: spawned nvim listens on a known socket', logged)
  ok(logged:find('/openloc/ws%-w1') ~= nil or logged:find('openloc/ws%-w1') ~= nil,
    'slock: the known socket is the workspace registry socket', logged)

  -- fresh lock + live socket: the second click JOINS instead of splitting.
  -- The socket sits where discovery cannot see it, so only the lock leads there.
  local s2 = scenario('sjoin')
  H.lines_file(s2.work .. '/f.txt', 20)
  local stub2, log2 = spawn_stub(s2, 'stub')
  local regdir = H.mkdir(s2.cache .. '/nvim/openloc')
  local sock2 = H.mkdir(s2.dir .. '/booting') .. '/spawned.sock'
  H.write_file(regdir .. '/spawn-ws-w1.lock', sock2 .. '\n0\n')
  local _, up = H.spawn_nvim(sock2, { cwd = s2.work })
  ok(up, 'sjoin: the "just spawned" editor is listening')
  local r2 = run_cli(s2, { 'open', 'f.txt', '--line', '7', '--json' }, {
    path_prefix = stub2,
    env = { HERDR_PLUGIN_CONTEXT_JSON = ctx_of(s2), HERDR_PLUGIN_ROOT = stub2 },
  })
  local obj2 = jdecode(r2.stdout)
  ok(r2.code == 0, 'sjoin: joiner exits 0', r2.code .. ' ' .. (r2.stderr or ''))
  ok(obj2 and obj2.winner and obj2.winner.addr == sock2, 'sjoin: opened into the spawning editor', r2.stdout)
  ok(obj2 and #obj2.candidates == 0, 'sjoin: the editor was reached through the lock, not elected', r2.stdout)
  local logged2 = slurp(log2)
  ok(logged2:find('pane split', 1, true) == nil, 'sjoin: no second split', logged2)
  local pos = rpc_eval(sock2, 'expand("%:t") .. ":" .. line(".")')
  ok(pos == 'f.txt:7', 'sjoin: file and line landed in the joined editor', tostring(pos))

  -- A spawning editor that takes the open and never answers may already
  -- hold the file: report it wedged rather than split a second editor.
  local s7 = scenario('swedge')
  H.lines_file(s7.work .. '/f.txt', 20)
  local stub7, log7 = spawn_stub(s7, 'stub')
  local regdir7 = H.mkdir(s7.cache .. '/nvim/openloc')
  local sock7 = H.mkdir(s7.dir .. '/booting') .. '/spawned.sock'
  H.write_file(regdir7 .. '/spawn-ws-w1.lock', sock7 .. '\n0\n')
  local _, up7 = H.spawn_nvim(sock7, { cwd = s7.work })
  ok(up7 and H.wedge(sock7, 8000), 'swedge: the spawning editor is listening and wedged')
  local r7 = run_cli(s7, { 'open', 'f.txt', '--json' }, {
    path_prefix = stub7,
    env = { HERDR_PLUGIN_CONTEXT_JSON = ctx_of(s7), HERDR_PLUGIN_ROOT = stub7 },
  })
  ok(r7.code == 5, 'swedge: a wedged spawning editor exits 5', r7.code .. ' ' .. (r7.stderr or ''))
  ok(slurp(log7):find('pane split', 1, true) == nil, 'swedge: no second split', slurp(log7))

  -- stale lock: steal it and spawn
  local s3 = scenario('sstale')
  H.lines_file(s3.work .. '/f.txt', 20)
  local stub3, log3 = spawn_stub(s3, 'stub')
  local regdir3 = H.mkdir(s3.cache .. '/nvim/openloc')
  local lock3 = regdir3 .. '/spawn-ws-w1.lock'
  H.write_file(lock3, regdir3 .. '/ws-w1.sock\n0\n')
  local past = os.time() - 60
  uv.fs_utime(lock3, past, past)
  local r3 = run_cli(s3, { 'open', 'f.txt', '--json' }, {
    path_prefix = stub3,
    env = { HERDR_PLUGIN_CONTEXT_JSON = ctx_of(s3), HERDR_PLUGIN_ROOT = stub3 },
  })
  ok(r3.code == 0 and (jdecode(r3.stdout) or {}).spawned == true,
    'sstale: stale lock is stolen, spawn proceeds', r3.stdout)
  ok(slurp(log3):find('pane split', 1, true) ~= nil, 'sstale: split happened')

  -- Regression: a stealer must bind its own socket. Reusing the first
  -- spawner's address makes the second nvim die with
  -- "--listen: address already in use" when the first finally boots.
  local s4 = scenario('suniq')
  H.lines_file(s4.work .. '/f.txt', 20)
  local stub4, log4 = spawn_stub(s4, 'stub')
  local env4 = { HERDR_PLUGIN_CONTEXT_JSON = ctx_of(s4), HERDR_PLUGIN_ROOT = stub4 }
  local r4a = run_cli(s4, { 'open', 'f.txt', '--json' }, { path_prefix = stub4, env = env4 })
  ok(r4a.code == 0, 'suniq: first spawn ok', r4a.code)
  local sock_a = slurp(log4):match("%-%-listen '([^']+)'")
  local lock4 = vim.fn.glob(s4.cache .. '/nvim/openloc/spawn-*.lock', true, true)[1]
  ok(sock_a ~= nil and lock4 ~= nil, 'suniq: first spawn recorded lock + socket')
  local past4 = os.time() - 60
  uv.fs_utime(lock4, past4, past4)
  H.write_file(log4, '')
  local r4b = run_cli(s4, { 'open', 'f.txt', '--json' }, { path_prefix = stub4, env = env4 })
  ok(r4b.code == 0, 'suniq: second spawn ok', r4b.code)
  local sock_b = slurp(log4):match("%-%-listen '([^']+)'")
  ok(sock_b ~= nil and sock_a ~= sock_b,
    'suniq: stealer binds a different socket than the first spawner',
    tostring(sock_a) .. ' vs ' .. tostring(sock_b))
  ok(slurp(lock4):find(vim.pesc(vim.fs.basename(sock_b))) ~= nil
    or slurp(vim.fn.glob(s4.cache .. '/nvim/openloc/spawn-*.lock', true, true)[1] or lock4)
      :find(vim.pesc(vim.fs.basename(sock_b))) ~= nil,
    'suniq: the lock names the stealer socket so joiners follow it')

  -- A failed split releases the lock, so the next click spawns at once
  -- instead of waiting out a join.
  local s6 = scenario('sfail')
  H.lines_file(s6.work .. '/f.txt', 20)
  local stub6 = s6.dir .. '/stub'
  S.herdr_stub(stub6, [[#!/bin/sh
case "$1 $2" in
  "pane list") echo '{"id":1,"result":{"panes":[]}}' ;;
  *) echo '{"id":9,"error":{"code":"split_refused"}}' ;;
esac
]])
  local r6 = run_cli(s6, { 'open', 'f.txt', '--json' }, {
    path_prefix = stub6,
    env = { HERDR_PLUGIN_CONTEXT_JSON = ctx_of(s6), HERDR_PLUGIN_ROOT = stub6 },
  })
  ok(r6.code == 2, 'sfail: a failed split exits 2', r6.code .. ' ' .. (r6.stderr or ''))
  ok(#vim.fn.glob(s6.cache .. '/nvim/openloc/spawn-*.lock', true, true) == 0, 'sfail: the lock is released')
end

print('== spawn lock: join timeout ==')
do
  -- Two clicks join a spawner whose editor never comes up. Once both time
  -- out, exactly one spawns; the other finds the lock re-taken and stops.
  local s = scenario('sjointo')
  H.lines_file(s.work .. '/f.txt', 20)
  local stub, log = S.spawn_stub(s, 'stub')
  local regdir = H.mkdir(s.cache .. '/nvim/openloc')
  local lock = regdir .. '/spawn-ws-w1.lock'
  H.write_file(lock, regdir .. '/ws-w1-sdead.sock\n0\n')
  local opts = { path_prefix = stub, env = { HERDR_PLUGIN_CONTEXT_JSON = S.plugin_ctx(s), HERDR_PLUGIN_ROOT = stub } }
  local p1 = S.start_cli(s, { 'open', 'f.txt', '--json' }, opts)
  -- Staggered so the first CLI has retracted its startup socket, which the
  -- second would otherwise discover as an editor.
  vim.wait(300)
  local p2 = S.start_cli(s, { 'open', 'f.txt', '--json' }, opts)
  local results = { p1:wait(), p2:wait() }
  local _, splits = slurp(log):gsub('pane split', '')
  ok(splits == 1, 'sjointo: two timed-out joiners split exactly one pane', splits)
  local spawned, stopped = 0, 0
  for _, r in ipairs(results) do
    if r.code == 0 and (jdecode(r.stdout) or {}).spawned == true then
      spawned = spawned + 1
    elseif r.code == 2 then
      stopped = stopped + 1
    end
  end
  ok(spawned == 1 and stopped == 1, 'sjointo: one spawns, the other exits 2',
    vim.inspect(vim.tbl_map(function(r) return { r.code, r.stderr } end, results)))
  ok(slurp(lock):find('ws-w1-sdead', 1, true) == nil, 'sjointo: the lock names the new spawner')
end

S.summary()
