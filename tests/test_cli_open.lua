-- Opening a file in a live editor: self-election guard, wedged candidates, the --json contract, focus, list and doctor.
-- Run: nvim -l tests/test_cli_open.lua (or via tests/run.sh)

local uv = vim.uv

local this = debug.getinfo(1, 'S').source:sub(2)
local this_abs = uv.fs_realpath(this) or this
local H = dofile(vim.fs.dirname(this_abs) .. '/helpers.lua')
H.ensure_isolated('cli_open', this_abs)
local S = dofile(H.tests_dir .. '/scenario.lua')(H, 'cli_open')

local ok = H.ok
local scenario, run_cli, jdecode, find_cand, socket_litter = S.scenario, S.run_cli, S.jdecode, S.find_cand, S.socket_litter

print('== self-election guard ==')
do
  local s = scenario('self')
  H.lines_file(s.work .. '/f.txt', 20)
  local r = run_cli(s, { 'open', 'f.txt', '--spawn', 'never', '--json' })
  ok(r.code == 2, 'R-1: zero live editors exits 2, never 0 (self-election)', r.code)
  local obj = jdecode(r.stdout)
  ok(obj ~= nil, 'R-1: exit-2 --json still emits the contract object', r.stdout)
  ok(obj and obj.ok == false and obj.exit_code == 2, 'R-1: json ok=false exit_code=2')
  ok(obj and #obj.candidates == 0, 'R-1: candidate set is empty (own socket retracted)',
    obj and vim.inspect(obj.candidates) or nil)
  -- The retraction removes the socket FILE, not just the listener. A CLI that
  -- skips R-1 leaks a dead nvim.<pid>.0 into a globbed dir on every run, and
  -- those leaks are what poison later invocations.
  local left = socket_litter(s)
  ok(#left == 0, 'R-1: no CLI socket file left in any globbed dir', vim.inspect(left))
end

print('== repeated opens ==')
do
  -- Back-to-back invocations against one editor: every open must route.
  -- Degrades hard when the CLI leaves its own server published (R-1).
  local s = scenario('rapid')
  H.lines_file(s.work .. '/f.txt', 20)
  local sock = s.glob_sock()
  local cand, up = H.spawn_nvim(sock, { cwd = s.work })
  ok(up, 'rapid: candidate came up')
  local codes = {}
  for i = 1, 5 do
    codes[i] = run_cli(s, { 'open', 'f.txt', '--spawn', 'never' }).code
  end
  ok(vim.deep_equal(codes, { 0, 0, 0, 0, 0 }), 'rapid: five consecutive opens all route',
    vim.inspect(codes))
  local left = socket_litter(s, { [sock] = true })
  ok(#left == 0, 'rapid: no socket litter after five runs', vim.inspect(left))
end

print('== wedged candidate ==')
do
  local s = scenario('wedge')
  H.lines_file(s.work .. '/f.txt', 20)
  local wsock = s.glob_sock()
  local _, up = H.spawn_nvim(wsock, { cwd = s.work })
  ok(up, 'wedged: fixture editor came up')
  ok(H.wedge(wsock), 'wedged: fixture main loop blocked')

  local r = run_cli(s, { 'open', 'f.txt', '--spawn', 'never', '--json' })
  ok(r.code == 2, 'wedged: no responsive candidate exits 2 (never a winner)', r.code)
  ok(r.ms < 3000, ('wedged: bounded by the probe deadline (%.0fms)'):format(r.ms))
  local obj = jdecode(r.stdout)
  local c = find_cand(obj, 'addr', wsock)
  ok(c ~= nil, 'wedged: candidate surfaced in --json', r.stdout)
  ok(c and c.wedged == true and c.status == 'wedged', 'wedged: flagged wedged=true')
  ok(c and c.excluded == true, 'wedged: excluded from election')
  ok(obj and obj.winner == nil, 'wedged: no winner reported')

  -- a live editor next to the wedged one wins; the wedged one is still named
  local lsock = s.glob_sock()
  local lobj, lup = H.spawn_nvim(lsock, { cwd = s.work })
  ok(lup, 'wedged: live sibling came up')
  r = run_cli(s, { 'open', 'f.txt', '--spawn', 'never', '--json' })
  obj = jdecode(r.stdout)
  ok(r.code == 0, 'wedged: live sibling wins (exit 0)', r.code .. ' ' .. (r.stderr or ''))
  ok(obj and obj.winner and obj.winner.pid == lobj.pid, 'wedged: winner is the live editor')
  c = find_cand(obj, 'addr', wsock)
  ok(c and c.wedged == true, 'wedged: still reported alongside the winner')
end

print('== open + json contract ==')
do
  local s = scenario('open')
  H.lines_file(s.work .. '/f.txt', 20)
  local sock = s.glob_sock()
  local cand, up = H.spawn_nvim(sock, { cwd = s.work })
  ok(up, 'open: candidate came up')

  local r = run_cli(s, { 'open', 'f.txt', '--line', '5', '--col', '3', '--json' })
  ok(r.code == 0, 'open: exits 0', r.code .. ' ' .. (r.stderr or ''))
  local obj = jdecode(r.stdout)
  ok(obj ~= nil, 'open: stdout is one JSON object', r.stdout)
  if obj then
    ok(obj.ok == true and obj.exit_code == 0, 'json: ok/exit_code')
    ok(obj.target == (uv.fs_realpath(s.work .. '/f.txt')), 'json: target is the realpath')
    ok(obj.line == 5 and obj.col == 3, 'json: line/col echoed')
    ok(type(obj.winner) == 'table' and obj.winner.addr == sock, 'json: winner.addr')
    ok(obj.winner and obj.winner.pid == cand.pid, 'json: winner.pid')
    ok(obj.winner and type(obj.winner.score) == 'number', 'json: winner.score')
    ok(obj.winner and type(obj.winner.reasons) == 'table', 'json: winner.reasons')
    ok(type(obj.candidates) == 'table' and #obj.candidates == 1, 'json: candidates listed')
    local c = obj.candidates[1]
    ok(c and c.addr == sock and c.pid == cand.pid, 'json: candidate addr/pid')
    ok(c and c.wedged == false and c.excluded == false and c.status == 'ok', 'json: candidate liveness fields')
    ok(obj.live_map_used == false, 'json: live_map_used false without herdr')
    ok(obj.focused == false, 'json: focused false without herdr')
    ok(type(obj.duration_ms) == 'number', 'json: duration_ms present')
  end

  -- suffix spec positions the cursor; human output reports the ack
  r = run_cli(s, { 'open', 'f.txt:7:3' })
  ok(r.code == 0 and r.stdout:find(':7:3 pid', 1, true) ~= nil,
    'open: path:line:col lands at 7:3', r.stdout)

  -- line clamp: 9999 lands on the last line (file has 20)
  r = run_cli(s, { 'open', 'f.txt:9999' })
  ok(r.code == 0 and r.stdout:find(':20:1 pid', 1, true) ~= nil,
    'open: line beyond EOF clamps to last line', r.stdout)
end

print('== focus null result ==')
do
  -- {"result":null} from tab focus is success; luanil decoding must not
  -- conflate it with failure.
  local s = scenario('focus')
  H.lines_file(s.work .. '/f.txt', 20)
  local stubdir = H.mkdir(s.dir .. '/stub')
  S.herdr_stub(stubdir, [[#!/bin/sh
case "$1 $2" in
  "pane get") echo '{"id":1,"result":{"pane":{"pane_id":"w1:p1","tab_id":"w1:t1"}}}' ;;
  "tab focus") echo '{"id":2,"result":null}' ;;
  *) echo '{"id":9,"error":{"code":"stub_unhandled"}}' ;;
esac
]])
  local sock = s.glob_sock()
  local _, up = H.spawn_nvim(sock, { cwd = s.work, env = { HERDR_PANE_ID = 'w1:p1' } })
  ok(up, 'focus: candidate came up')
  local r = run_cli(s, { 'open', 'f.txt', '--json' }, { path_prefix = stubdir })
  local obj = jdecode(r.stdout)
  ok(r.code == 0, 'focus: exits 0', r.code .. ' ' .. (r.stderr or ''))
  ok(obj and obj.focused == true, 'focus: null-result tab focus reported focused', r.stdout)
end

print('== list / doctor ==')
do
  local s = scenario('list')
  local r = run_cli(s, { 'list' })
  ok(r.code == 0 and r.stdout:find('no live editors', 1, true) ~= nil,
    'list: empty scenario says so', r.stdout)

  local sock = s.glob_sock()
  local cand, up = H.spawn_nvim(sock, { cwd = s.work })
  ok(up, 'list: candidate came up')
  r = run_cli(s, { 'list' })
  ok(r.code == 0 and r.stdout:find(sock, 1, true) ~= nil, 'list: table names the socket', r.stdout)
  ok(r.stdout:find('pid=' .. cand.pid, 1, true) ~= nil, 'list: table names the pid')

  r = run_cli(s, { 'list', '--json' })
  local obj = jdecode(r.stdout)
  ok(r.code == 0 and obj and obj.ok == true, 'list --json: contract object')
  local c = find_cand(obj, 'addr', sock)
  ok(c ~= nil and c.status == 'ok' and c.pid == cand.pid, 'list --json: candidate entry')

  r = run_cli(s, { 'doctor' })
  ok(r.code == 0, 'doctor: exits 0', r.code .. ' ' .. (r.stderr or ''))
  ok(r.stdout:find('cli:', 1, true) ~= nil, 'doctor: reports the resolved cli path')
  ok(r.stdout:find('socket path length', 1, true) ~= nil, 'doctor: reports socket length headroom')

  -- a cache path that overflows sun_path is a FAIL line, the same verdict
  -- :checkhealth gives
  r = run_cli(s, { 'doctor' }, { env = { XDG_CACHE_HOME = s.dir .. '/' .. string.rep('c', 90) } })
  ok(r.code == 0 and r.stdout:find('FAIL socket path length', 1, true) ~= nil,
    'doctor: an overlong registry path is reported FAIL', r.stdout)
end

-- Regression: a Darwin plugin-action env drops TMPDIR; discovery must fall
-- back to the confstr temp dir where default sockets actually live.
if uv.os_uname().sysname == 'Darwin' then
  print('== darwin no-TMPDIR fallback ==')
  local s = scenario('notmpdir')
  local real_tmp = vim.fn.system({ 'getconf', 'DARWIN_USER_TEMP_DIR' }):gsub('%s+$', ''):gsub('/+$', '')
  local d = real_tmp .. '/nvim.' .. s.user .. '/oltest' .. uv.os_getpid()
  local sock = d .. '/nvim.90001.0'
  local _, up = H.spawn_nvim(sock, { cwd = s.work })
  ok(up, 'no-TMPDIR: candidate came up in the confstr temp dir')
  local r = run_cli(s, { 'list', '--json' }, { env = { TMPDIR = '' } })
  local obj = jdecode(r.stdout)
  ok(find_cand(obj, 'addr', sock) ~= nil,
    'no-TMPDIR: default-shaped socket still discovered', r.stdout)
  os.remove(sock)
  uv.fs_rmdir(d)
end

S.summary()
