-- Router CLI tests, run against real subprocess invocations of bin/openloc.
-- Pins the three regression tests the design requires: the CLI never elects
-- itself (exit 2 with zero live editors), a wedged candidate is detected at
-- the deadline and never wins, and an unconfirmed env workspace mismatch is
-- demoted (-150) while a live-map-confirmed mismatch is excluded.
-- Run: nvim -l tests/test_router.lua (or via tests/run.sh)

local uv = vim.uv

local this = debug.getinfo(1, 'S').source:sub(2)
local this_abs = uv.fs_realpath(this) or this
local H = dofile(vim.fs.dirname(this_abs) .. '/helpers.lua')
H.ensure_isolated('router', this_abs)

local ok = H.ok
local BASE = vim.env.OLTEST_BASE
if not BASE or BASE == '' then
  BASE = H.mkdir('/tmp/oltest-router-' .. uv.os_getpid())
end
local OPENLOC = H.root .. '/bin/openloc'

-- ------------------------------------------------------------- scaffolding

-- Each scenario gets its own TMPDIR, fake user, runtime dir and cache, so
-- the CLI's three glob shapes and its registry can only ever see fixtures
-- this scenario planted.
local function scenario(name)
  local s = {}
  s.name = name
  s.dir = BASE .. '/rt-' .. name
  s.tmp = H.mkdir(s.dir .. '/tmp')
  s.cache = H.mkdir(s.dir .. '/cache')
  s.run = H.mkdir(s.dir .. '/run')
  s.work = H.mkdir(s.dir .. '/work')
  -- real nvim names its socket dir after the uid (uv passwd), never $USER;
  -- the CLI matches that, so fake sockets must live under the real name
  s.user = (vim.uv or vim.loop).os_get_passwd().username
  s.nsock = 0
  s.glob_sock = function()
    s.nsock = s.nsock + 1
    local d = H.mkdir(s.tmp .. '/nvim.' .. s.user .. '/d' .. s.nsock)
    return d .. '/nvim.' .. (1000 + s.nsock) .. '.0'
  end
  return s
end

-- Invoke the CLI with the scenario's isolated env. HERDR_*/OPENLOC_* are
-- masked to '' (the CLI treats empty as unset); opts.env overrides win.
local function run_cli(s, args, opts)
  opts = opts or {}
  local env = {
    TMPDIR = s.tmp,
    USER = s.user,
    LOGNAME = s.user,
    XDG_RUNTIME_DIR = s.run,
    XDG_CACHE_HOME = s.cache,
    HOME = s.dir,
    PATH = (opts.path_prefix and (opts.path_prefix .. ':') or '') .. '/usr/bin:/bin',
    PWD = opts.cwd or s.work,
    HERDR_PLUGIN_CONTEXT_JSON = '',
    HERDR_PLUGIN_CLICKED_URL = '',
    HERDR_PLUGIN_ROOT = '',
    HERDR_WORKSPACE_ID = '',
    HERDR_PANE_ID = '',
    HERDR_TAB_ID = '',
    HERDR_ENV = '',
    HERDR_BIN_PATH = '',
    OPENLOC_ALLOW = '',
    OPENLOC_STRICT = '',
    OPENLOC_SPAWN = '',
    OPENLOC_NVIM = '',
    OPENLOC_PICK_MARGIN = '',
  }
  for k, v in pairs(opts.env or {}) do
    env[k] = v
  end
  local argv = { vim.v.progpath, '-l', OPENLOC }
  vim.list_extend(argv, args)
  local t0 = uv.hrtime()
  local res = vim.system(argv, {
    env = env,
    cwd = opts.cwd or s.work,
    text = true,
    timeout = 8000,
  }):wait()
  res.ms = (uv.hrtime() - t0) / 1e6
  return res
end

local function jdecode(str)
  local okd, obj = pcall(vim.json.decode, str, { luanil = { object = true, array = true } })
  return okd and obj or nil
end

local function find_cand(obj, field, value)
  for _, c in ipairs(obj and obj.candidates or {}) do
    if c[field] == value then
      return c
    end
  end
  return nil
end

local function has_reason(t, needle)
  for _, r in ipairs(t and t.reasons or {}) do
    if r:find(needle, 1, true) then
      return true
    end
  end
  return false
end

-- Evaluate an expression inside a live candidate, nil on any failure.
local function rpc_eval(sock, expr)
  local okc, chan = pcall(vim.fn.sockconnect, 'pipe', sock, { rpc = true })
  if not okc or not chan or chan == 0 then
    return nil
  end
  local okr, res = pcall(vim.fn.rpcrequest, chan, 'nvim_eval', expr)
  pcall(vim.fn.chanclose, chan)
  if okr then
    return res
  end
  return nil
end

local function slurp(p)
  local f = io.open(p, 'r')
  if not f then
    return ''
  end
  local body = f:read('*a')
  f:close()
  return body
end

-- Any nvim socket left anywhere under the scenario's TMPDIR or runtime dir.
-- The run-dir layout differs across platforms; sweep every depth.
local function socket_litter(s, ignore)
  local out = {}
  for _, base in ipairs({ s.run, s.tmp }) do
    for _, depth in ipairs({ '/nvim.*.0', '/*/nvim.*.0', '/*/*/nvim.*.0' }) do
      for _, m in ipairs(vim.fn.glob(base .. depth, true, true)) do
        if not (ignore and ignore[m]) then
          out[#out + 1] = m
        end
      end
    end
  end
  return out
end

-- --------------------------------------------------------- usage / exit 1

print('== usage ==')
do
  local s = scenario('usage')
  H.lines_file(s.work .. '/f.txt', 20)
  ok(run_cli(s, {}).code == 1, 'usage: no subcommand exits 1')
  ok(run_cli(s, { 'bogus' }).code == 1, 'usage: unknown subcommand exits 1')
  ok(run_cli(s, { 'open' }).code == 1, 'usage: open without a path exits 1')
  ok(run_cli(s, { 'open', 'f.txt', '--spawn', 'sideways' }).code == 1, 'usage: bad --spawn value exits 1')
  ok(run_cli(s, { 'open', 'f.txt', '--frobnicate' }).code == 1, 'usage: unknown flag exits 1')
  ok(run_cli(s, { 'open', 'f.txt', '--line' }).code == 1, 'usage: value flag at argv end exits 1')
  ok(run_cli(s, { 'open', 'f.txt', '--ws', '--json' }).code == 1, 'usage: value flag eating a flag exits 1')
  ok(run_cli(s, { 'open', 'f.txt', '--line', 'abc' }).code == 1, 'usage: non-numeric --line exits 1')
end

-- ------------------------------------------------- R0 stat oracle / exit 3

print('== stat oracle ==')
do
  local s = scenario('oracle')
  H.lines_file(s.work .. '/f.txt', 20)
  H.lines_file(s.dir .. '/out/f.txt', 5)

  local r = run_cli(s, { 'open', 'nope-xyz.txt', '--spawn', 'never' })
  ok(r.code == 3, 'oracle: missing file exits 3', r.code)
  ok(r.stderr:find('not an existing regular file', 1, true) ~= nil, 'oracle: error names the failure')
  ok(r.stderr:find('nope%-xyz') ~= nil, 'oracle: error names the spec')

  r = run_cli(s, { 'open', 'bad\1name.txt:3', '--spawn', 'never' })
  ok(r.code == 3, 'oracle: control character in spec exits 3', r.code)

  -- absolute path outside every resolved root
  local outside = s.dir .. '/out/f.txt'
  r = run_cli(s, { 'open', outside, '--spawn', 'never' })
  ok(r.code == 3, 'oracle: confinement violation exits 3', r.code)
  ok(r.stderr:find('confinement', 1, true) ~= nil, 'oracle: confinement named in error')

  -- OPENLOC_ALLOW lifts confinement; exit 2 proves R0 passed (no editor)
  r = run_cli(s, { 'open', outside, '--spawn', 'never' }, { env = { OPENLOC_ALLOW = s.dir } })
  ok(r.code == 2, 'oracle: OPENLOC_ALLOW admits the path (exit 2, not 3)', r.code)

  -- directories are not regular files
  r = run_cli(s, { 'open', s.work, '--spawn', 'never' })
  ok(r.code == 3, 'oracle: a directory exits 3', r.code)
end

-- ------------------------------------------- regression (a): self-election

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

-- ------------------------------------------------------- repeated opens

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

-- ------------------------------------------------ regression (b): wedged

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

-- ------------------------------------------- basic open + --json contract

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
    ok(has_reason(obj.winner, '+20 cwd ancestor'), 'json: cwd ancestor reason recorded')
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

-- ------------------------------------------------------- cwd ancestry win

print('== cwd ancestry ==')
do
  local s = scenario('cwd')
  local projA = H.mkdir(s.dir .. '/projA')
  local projB = H.mkdir(s.dir .. '/projB')
  H.lines_file(projB .. '/f.txt', 20)
  local sockX, sockY = s.glob_sock(), s.glob_sock()
  local _, upX = H.spawn_nvim(sockX, { cwd = projA })
  local candY, upY = H.spawn_nvim(sockY, { cwd = projB })
  ok(upX and upY, 'cwd: both candidates came up')

  local r = run_cli(s, { 'open', 'f.txt', '--spawn', 'never', '--json' }, { cwd = projB })
  local obj = jdecode(r.stdout)
  ok(r.code == 0, 'cwd: exits 0', r.code)
  ok(obj and obj.winner and obj.winner.pid == candY.pid, 'cwd: editor whose cwd contains the target wins')
  ok(obj and has_reason(obj.winner, '+20 cwd ancestor'), 'cwd: +20 reason on the winner')
  local x = find_cand(obj, 'addr', sockX)
  ok(x and x.score == 0 and x.excluded == false, 'cwd: unrelated editor scored 0, not excluded',
    x and x.score or 'missing')
end

-- ------------------------------------------------------ has-file-open win

print('== has-file-open bonus ==')
do
  local s = scenario('has')
  H.lines_file(s.work .. '/f.txt', 20)
  local elsewhere = H.mkdir(s.dir .. '/elsewhere')
  local target = uv.fs_realpath(s.work .. '/f.txt')
  local sockP, sockQ = s.glob_sock(), s.glob_sock()
  local _, upP = H.spawn_nvim(sockP, { cwd = elsewhere })
  local candQ, upQ = H.spawn_nvim(sockQ, { cwd = elsewhere, args = { target } })
  ok(upP and upQ, 'has: both candidates came up')

  local r = run_cli(s, { 'open', 'f.txt', '--spawn', 'never', '--json' })
  local obj = jdecode(r.stdout)
  ok(r.code == 0, 'has: exits 0', r.code)
  ok(obj and obj.winner and obj.winner.pid == candQ.pid, 'has: editor holding the buffer wins')
  ok(obj and has_reason(obj.winner, '+100 target already open'), 'has: +100 reason on the winner')
end

-- ------------------------------------------------- R1 registry fast path

print('== registry fast path ==')
do
  local s = scenario('reg')
  H.lines_file(s.work .. '/f.txt', 20)
  local elsewhere = H.mkdir(s.dir .. '/elsewhere2')
  local regdir = H.mkdir(s.cache .. '/nvim/openloc')
  local rsock = regdir .. '/ws-w1.sock'
  local cand, up = H.spawn_nvim(rsock, { cwd = elsewhere })
  ok(up, 'registry: claimed editor came up')

  local r = run_cli(s, { 'open', 'f.txt', '--ws', 'w1', '--spawn', 'never', '--json' })
  local obj = jdecode(r.stdout)
  ok(r.code == 0, 'registry: exits 0', r.code .. ' ' .. (r.stderr or ''))
  ok(obj and obj.winner and obj.winner.addr == rsock, 'registry: ws-key socket wins outright')
  ok(obj and obj.winner and obj.winner.pid == cand.pid, 'registry: winner pid matches')
  ok(obj and has_reason(obj.winner, 'registry fast path'), 'registry: fast-path reason recorded')
  ok(obj and has_reason(obj.winner, '+10 registry entry'), 'registry: +10 origin bonus recorded')
end

-- --------------------------- regression (c): stale env vs live map (R6)

print('== live workspace filter ==')
do
  local s = scenario('stale')
  H.lines_file(s.work .. '/f.txt', 20)
  local sockA, sockB, sockC = s.glob_sock(), s.glob_sock(), s.glob_sock()
  -- A: no env claim; the live map confirms it in ctx's workspace w1.
  local candA, upA = H.spawn_nvim(sockA, { cwd = s.work })
  -- B: env claims workspace w2, the live map does not know it (moved pane).
  local candB, upB = H.spawn_nvim(sockB, { cwd = s.work, env = { HERDR_WORKSPACE_ID = 'w2' } })
  -- C: the live map confirms it in ANOTHER workspace w9.
  local candC, upC = H.spawn_nvim(sockC, { cwd = s.work })
  ok(upA and upB and upC, 'live: all three candidates came up')

  local stubdir = H.mkdir(s.dir .. '/stub')
  local stub = ([[#!/bin/sh
if [ "$1 $2" = "pane list" ]; then
  echo '{"id":1,"result":{"panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1"},{"pane_id":"w9:p3","workspace_id":"w9","tab_id":"w9:t1"}]}}'
elif [ "$1 $2" = "pane process-info" ] && [ "$4" = "w1:p1" ]; then
  echo '{"id":2,"result":{"process_info":{"shell_pid":APID,"foreground_processes":[]}}}'
elif [ "$1 $2" = "pane process-info" ] && [ "$4" = "w9:p3" ]; then
  echo '{"id":3,"result":{"process_info":{"shell_pid":CPID,"foreground_processes":[]}}}'
else
  echo '{"id":9,"error":{"code":"stub_unhandled"}}'
fi
]]):gsub('APID', tostring(candA.pid)):gsub('CPID', tostring(candC.pid))
  H.write_file(stubdir .. '/herdr', stub)
  uv.fs_chmod(stubdir .. '/herdr', tonumber('755', 8))

  local r = run_cli(s, { 'open', 'f.txt', '--ws', 'w1', '--spawn', 'never', '--json' },
    { path_prefix = stubdir })
  local obj = jdecode(r.stdout)
  ok(r.code == 0, 'live: exits 0', r.code .. ' ' .. (r.stderr or ''))
  ok(obj and obj.live_map_used == true, 'live: live map was consulted')
  ok(obj and obj.winner and obj.winner.pid == candA.pid, 'live: confirmed-in-ws editor wins')
  ok(obj and has_reason(obj.winner, '+200 live workspace match'), 'live: +200 reason on the winner')

  local b = find_cand(obj, 'pid', candB.pid)
  ok(b ~= nil, 'live: unconfirmed-mismatch candidate listed', r.stdout)
  ok(b and b.excluded == false, 'live: unconfirmed mismatch demoted, NOT excluded')
  ok(b and has_reason(b, '-150 env workspace mismatch'), 'live: -150 reason on the demoted candidate')
  ok(b and b.score < 0, 'live: demotion drives the score negative', b and b.score)

  local c = find_cand(obj, 'pid', candC.pid)
  ok(c ~= nil, 'live: confirmed-elsewhere candidate listed')
  ok(c and c.excluded == true, 'live: confirmed-other-workspace candidate excluded')
  ok(c and has_reason(c, 'live map places it in w9'), 'live: exclusion reason names the workspace')
end

-- --------------------- regression (d): sibling herdr session (R6 scope)

-- herdr numbers workspaces per session, so an editor under another session's
-- server is out of scope no matter what its HERDR_WORKSPACE_ID says, and
-- `herdr pane list` cannot see it to say otherwise.
print('== herdr session scope ==')
do
  local s = scenario('session')
  H.lines_file(s.work .. '/f.txt', 20)
  local fake = H.fake_herdr_bin(s.dir .. '/fakebin')
  ok(fake ~= nil, 'sess: stand-in session server binary created')

  local sock = s.glob_sock()
  local other, up = H.spawn_nvim_under(fake, sock, { cwd = s.work })
  ok(up, 'sess: candidate under the stand-in server came up')
  local server = other.wrapper.pid

  -- Same workspace id in both sessions: the collision the pid comparison is
  -- there to catch, since each server counts workspaces from w1 on its own.
  local r = run_cli(s, { 'open', 'f.txt', '--ws', 'w1', '--session', tostring(server + 1000000),
    '--choose', 'auto', '--spawn', 'never', '--json' })
  local obj = jdecode(r.stdout)
  ok(r.code == 2, 'sess: nothing eligible, exits 2 (no editor) not 6 (ambiguous)',
    r.code .. ' ' .. (r.stderr or ''))
  local c2 = find_cand(obj, 'pid', other.pid)
  ok(c2 ~= nil, 'sess: the sibling-session candidate is still listed', r.stdout)
  ok(c2 and c2.excluded == true, 'sess: sibling-session candidate excluded')
  ok(c2 and has_reason(c2, 'another herdr session'), 'sess: reason names the session')
  ok(c2 and c2.session == server, 'sess: the reported session is the stand-in server', c2 and c2.session)

  -- Same editor, same session: eligibility is restored, so the exclusion is
  -- scoped to the session and is not just a blanket rejection.
  local r2 = run_cli(s, { 'open', 'f.txt:7', '--ws', 'w1', '--session', tostring(server),
    '--spawn', 'never', '--json' })
  local obj2 = jdecode(r2.stdout)
  ok(r2.code == 0, 'sess: same-session candidate is eligible and opens',
    r2.code .. ' ' .. (r2.stderr or ''))
  ok(obj2 and obj2.winner and obj2.winner.pid == other.pid, 'sess: it won the election')
end

-- ---------------------------------------------------------- open-url (R0)

print('== open-url ==')
do
  local s = scenario('url')
  H.lines_file(s.work .. '/sub/f.txt', 20)
  local function enc(str)
    return (str:gsub('[^%w%-_%.~]', function(ch)
      return ('%%%02X'):format(ch:byte())
    end))
  end

  -- rejections need no candidate: they exit before discovery
  local r = run_cli(s, { 'open-url', 'ftp://openloc.invalid/o?p=x' })
  ok(r.code == 3, 'url: non-http(s) scheme exits 3', r.code)
  r = run_cli(s, { 'open-url', 'not a url' })
  ok(r.code == 3, 'url: garbage exits 3', r.code)
  r = run_cli(s, { 'open-url', 'https://evil.example/o?p=x', '--strict' })
  ok(r.code == 3, 'url: --strict rejects a foreign host', r.code)
  ok(r.stderr:find('strict', 1, true) ~= nil, 'url: strict rejection names strict mode')
  r = run_cli(s, { 'open-url', 'https://openloc.invalid/o?l=42' })
  ok(r.code == 3, 'url: missing p exits 3', r.code)
  r = run_cli(s, { 'open-url' })
  ok(r.code == 1, 'url: no URL and no HERDR_PLUGIN_CLICKED_URL exits 1', r.code)

  local sock = s.glob_sock()
  local cand, up = H.spawn_nvim(sock, { cwd = s.work })
  ok(up, 'url: candidate came up')
  local u = 'https://openloc.invalid/o?p=' .. enc('sub/f.txt') .. '&l=5&c=2&cwd=' .. enc(s.work)
  r = run_cli(s, { 'open-url', u }, { cwd = s.dir })
  ok(r.code == 0 and r.stdout:find(':5:2 pid', 1, true) ~= nil,
    'url: p/l/c/cwd params resolve and position', r.code .. ' ' .. r.stdout .. (r.stderr or ''))

  -- default (non-strict) accepts any http(s) host, reading only the query
  r = run_cli(s, { 'open-url', 'https://evil.example/o?p=' .. enc('sub/f.txt') .. '&l=4&cwd=' .. enc(s.work) },
    { cwd = s.dir })
  ok(r.code == 0 and r.stdout:find(':4:1 pid', 1, true) ~= nil,
    'url: foreign host accepted without --strict', r.code)

  -- HERDR_PLUGIN_CLICKED_URL is the fallback when the positional is absent
  r = run_cli(s, { 'open-url', '--json' }, { cwd = s.dir, env = { HERDR_PLUGIN_CLICKED_URL = u } })
  local obj = jdecode(r.stdout)
  ok(r.code == 0 and obj and obj.winner and obj.winner.pid == cand.pid,
    'url: HERDR_PLUGIN_CLICKED_URL fallback routes', r.code)
end

-- ------------------------------------- R9 spawn gate in a herdr action env

print('== herdr action env spawn ==')
do
  -- A plugin action or link handler receives ONLY HERDR_PLUGIN_* vars, no
  -- pane-inherited HERDR_*; the split fallback must still fire.
  local s = scenario('spawnh')
  H.lines_file(s.work .. '/f.txt', 20)
  local stubdir = H.mkdir(s.dir .. '/stub')
  local log = s.dir .. '/herdr.log'
  H.write_file(stubdir .. '/herdr', ([[#!/bin/sh
echo "$@" >> "%s"
case "$1 $2" in
  "pane list") echo '{"id":1,"result":{"panes":[]}}' ;;
  "pane split") echo '{"id":2,"result":{"pane_id":"w1:p9"}}' ;;
  "pane run") echo '{"id":3,"result":{}}' ;;
  *) echo '{"id":9,"error":{"code":"stub_unhandled"}}' ;;
esac
]]):format(log))
  uv.fs_chmod(stubdir .. '/herdr', tonumber('755', 8))
  local ctx = vim.json.encode({
    workspace_id = 'w1',
    focused_pane_id = 'w1:p1',
    workspace_cwd = s.work,
  })
  local r = run_cli(s, { 'open', 'f.txt', '--json' }, {
    path_prefix = stubdir,
    env = { HERDR_PLUGIN_CONTEXT_JSON = ctx, HERDR_PLUGIN_ROOT = stubdir },
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

-- ------------------------------------ R9 OPENLOC_SPAWN is deadline-safe

print('== OPENLOC_SPAWN detached ==')
do
  local s = scenario('spawne')
  H.lines_file(s.work .. '/f.txt', 20)
  local bindir = H.mkdir(s.dir .. '/bin')
  local marker = s.dir .. '/ed-ran'
  H.write_file(bindir .. '/slow-ed', ('#!/bin/sh\ntouch "%s"\nsleep 8\n'):format(marker))
  uv.fs_chmod(bindir .. '/slow-ed', tonumber('755', 8))
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

-- ----------------------------------------------- R6 term-only exclusion

print('== term-only candidate ==')
do
  local s = scenario('term')
  H.lines_file(s.work .. '/f.txt', 20)
  local tsock = s.glob_sock()
  local _, up = H.spawn_nvim(tsock, { cwd = s.work, args = { '+terminal' } })
  ok(up, 'term: terminal-host candidate came up')

  local r = run_cli(s, { 'open', 'f.txt', '--spawn', 'never', '--json' })
  local obj = jdecode(r.stdout)
  ok(r.code == 2, 'term: terminal-only editor never wins (exit 2)', r.code)
  local c = find_cand(obj, 'addr', tsock)
  ok(c ~= nil, 'term: candidate surfaced in --json', r.stdout)
  ok(c and c.excluded == true, 'term: candidate excluded')
  ok(c and has_reason(c, 'term://'), 'term: exclusion reason names term://',
    c and vim.inspect(c.reasons) or nil)

  local nsock = s.glob_sock()
  local cand, up2 = H.spawn_nvim(nsock, { cwd = s.work })
  ok(up2, 'term: normal sibling came up')
  r = run_cli(s, { 'open', 'f.txt', '--spawn', 'never', '--json' })
  obj = jdecode(r.stdout)
  ok(r.code == 0 and obj and obj.winner and obj.winner.pid == cand.pid,
    'term: normal sibling wins over the terminal host', r.code)
end

-- ------------------------------------- R10 focus with a null result envelope

print('== focus null result ==')
do
  -- {"result":null} from tab focus is success; luanil decoding must not
  -- conflate it with failure.
  local s = scenario('focus')
  H.lines_file(s.work .. '/f.txt', 20)
  local stubdir = H.mkdir(s.dir .. '/stub')
  H.write_file(stubdir .. '/herdr', [[#!/bin/sh
case "$1 $2" in
  "pane get") echo '{"id":1,"result":{"pane":{"pane_id":"w1:p1","tab_id":"w1:t1"}}}' ;;
  "tab focus") echo '{"id":2,"result":null}' ;;
  *) echo '{"id":9,"error":{"code":"stub_unhandled"}}' ;;
esac
]])
  uv.fs_chmod(stubdir .. '/herdr', tonumber('755', 8))
  local sock = s.glob_sock()
  local _, up = H.spawn_nvim(sock, { cwd = s.work, env = { HERDR_PANE_ID = 'w1:p1' } })
  ok(up, 'focus: candidate came up')
  local r = run_cli(s, { 'open', 'f.txt', '--json' }, { path_prefix = stubdir })
  local obj = jdecode(r.stdout)
  ok(r.code == 0, 'focus: exits 0', r.code .. ' ' .. (r.stderr or ''))
  ok(obj and obj.focused == true, 'focus: null-result tab focus reported focused', r.stdout)
end

-- ---------------------------------------------------- subdir shim guard

print('== subdir shim guard ==')
do
  -- The shim copied out alone must not dofile whatever sits two levels up.
  local s = scenario('shim')
  local shim_src = H.root .. '/herdr/cli/openloc.lua'
  local f = assert(io.open(shim_src, 'r'))
  local body = f:read('*a')
  f:close()
  H.write_file(s.dir .. '/subonly/cli/openloc.lua', body)
  H.write_file(s.dir .. '/lua/openloc/cli.lua', 'io.stdout:write("FOREIGN\\n") os.exit(42)\n')
  local r = vim.system({ vim.v.progpath, '-l', s.dir .. '/subonly/cli/openloc.lua', 'list' },
    { text = true, timeout = 8000 }):wait()
  ok(r.code == 1, 'shim: standalone subdir checkout exits 1', r.code)
  ok((r.stdout or ''):find('FOREIGN', 1, true) == nil, 'shim: foreign cli.lua never executed', r.stdout)
  ok((r.stderr or ''):find('reinstall', 1, true) ~= nil, 'shim: reinstall instruction printed', r.stderr)
  ok((r.stderr or ''):find(s.dir .. '/lua', 1, true) == nil, 'shim: no foreign path named', r.stderr)
end

-- ------------------------------------------------------ herdr launcher

print('== herdr launcher ==')
do
  local s = scenario('launch')
  local launcher = H.root .. '/herdr/bin/openloc-herdr'
  local iso = {
    OPENLOC_NVIM = vim.v.progpath,
    TMPDIR = s.tmp,
    USER = s.user,
    LOGNAME = s.user,
    XDG_RUNTIME_DIR = s.run,
    XDG_CACHE_HOME = s.cache,
    HOME = s.dir,
    PWD = s.work,
  }
  local function run_launcher(args, extra)
    local env = vim.tbl_extend('force', iso, extra or {})
    return vim.system(vim.list_extend({ 'bash', launcher }, args), {
      text = true,
      timeout = 8000,
      cwd = s.work,
      env = env,
    }):wait()
  end

  local r = run_launcher({ 'open-url' }, { HERDR_PLUGIN_CLICKED_URL = '' })
  ok(r.code == 1, 'launcher: open-url without a URL exits 1 (usage)', r.code)

  -- unknown subcommands fall through to the CLI, which rejects them
  r = run_launcher({ 'pick' }, {})
  ok(r.code == 1, 'launcher: the removed pick subcommand is no longer handled',
    r.code .. ' ' .. (r.stderr or ''))
end

-- ------------------------------------------------------------ list/doctor

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
end

-- ------------------------------------------- --choose auto election / exit 6

print('== choose election ==')
do
  local s = scenario('choose')
  H.lines_file(s.work .. '/f.txt', 20)
  H.lines_file(s.work .. '/g.txt', 20)
  H.lines_file(s.work .. '/h.txt', 20)
  local elsewhere = H.mkdir(s.dir .. '/elsewhere')
  local sockA, sockB = s.glob_sock(), s.glob_sock()
  -- A: cwd ancestor of the targets (+20). B: unrelated cwd (0). Gap 20 sits
  -- under the default margin 75, so both are close AND deterministically
  -- ordered.
  local candA, upA = H.spawn_nvim(sockA, { cwd = s.work })
  local candB, upB = H.spawn_nvim(sockB, { cwd = elsewhere })
  ok(upA and upB, 'choose: both candidates came up')

  -- default and explicit never: close scores still open
  local r = run_cli(s, { 'open', 'g.txt', '--spawn', 'never', '--json' })
  local obj = jdecode(r.stdout)
  ok(r.code == 0, 'choose: default (no --choose) opens despite close scores', r.code)
  ok(obj and obj.winner ~= nil, 'choose: default run names a winner')
  r = run_cli(s, { 'open', 'h.txt', '--choose', 'never', '--spawn', 'never' })
  ok(r.code == 0, 'choose: explicit --choose never opens despite close scores', r.code)

  -- auto + close scores: exit 6, nothing opened, full JSON contract
  r = run_cli(s, { 'open', 'f.txt', '--choose', 'auto', '--spawn', 'never', '--json' })
  obj = jdecode(r.stdout)
  ok(r.code == 6, 'choose auto: close scores exit 6', r.code .. ' ' .. (r.stderr or ''))
  ok(obj ~= nil, 'choose auto: exit-6 stdout is one JSON object', r.stdout)
  if obj then
    ok(obj.ok == false and obj.exit_code == 6, 'choose auto: json ok=false exit_code=6')
    ok(obj.reason == 'ambiguous', 'choose auto: json reason=ambiguous', obj.reason)
    ok(obj.margin == 75, 'choose auto: default margin 75 reported', obj.margin)
    ok(type(obj.candidates) == 'table' and #obj.candidates == 2,
      'choose auto: both eligible candidates listed', obj.candidates and #obj.candidates)
    local c1, c2 = obj.candidates[1], obj.candidates[2]
    ok(c1 and c2 and c1.score >= c2.score, 'choose auto: candidates sorted score desc')
    ok(c1 and c1.pid == candA.pid and c1.addr == sockA, 'choose auto: top candidate is the higher scorer')
    ok(c2 and c2.pid == candB.pid and c2.addr == sockB, 'choose auto: runner-up listed second')
    ok(c1 and type(c1.cwd) == 'string' and type(c1.reasons) == 'table',
      'choose auto: candidate carries cwd and reasons')
    ok(obj.winner == nil, 'choose auto: no winner on exit 6')
  end
  local bn = rpc_eval(sockA, 'bufname("%")') or ''
  ok(not bn:find('f.txt', 1, true), 'choose auto: exit 6 opened nothing', bn)

  -- human form: one stderr line per candidate, none on stdout
  r = run_cli(s, { 'open', 'f.txt', '--choose', 'auto', '--spawn', 'never' })
  ok(r.code == 6, 'choose auto: human form exits 6', r.code)
  local n = select(2, r.stderr:gsub('ambiguous %(margin 75%)', ''))
  ok(n == 2, 'choose auto: one stderr line per candidate', r.stderr)

  -- OPENLOC_PICK_MARGIN override: gap 20 clears a margin of 10
  r = run_cli(s, { 'open', 'f.txt', '--choose', 'auto', '--spawn', 'never', '--json' },
    { env = { OPENLOC_PICK_MARGIN = '10' } })
  obj = jdecode(r.stdout)
  ok(r.code == 0, 'choose auto: OPENLOC_PICK_MARGIN override opens', r.code .. ' ' .. (r.stderr or ''))
  ok(obj and obj.winner and obj.winner.pid == candA.pid, 'choose auto: override winner is the top scorer')

  -- A now holds f.txt (+100): the gap clears the default margin
  r = run_cli(s, { 'open', 'f.txt', '--choose', 'auto', '--spawn', 'never', '--json' })
  obj = jdecode(r.stdout)
  ok(r.code == 0, 'choose auto: clear winner opens', r.code)
  ok(obj and obj.winner and obj.winner.pid == candA.pid
    and has_reason(obj.winner, '+100 target already open'),
    'choose auto: clear winner is the +100 editor')

  -- one eligible candidate left: auto opens without an election
  candB:kill(9)
  pcall(function()
    candB:wait(2000)
  end)
  r = run_cli(s, { 'open', 'g.txt', '--choose', 'auto', '--spawn', 'never', '--json' })
  obj = jdecode(r.stdout)
  ok(r.code == 0, 'choose auto: single eligible candidate opens', r.code)
  ok(obj and obj.winner and obj.winner.pid == candA.pid, 'choose auto: sole survivor wins')
end

-- ------------------------------------------------------- forced --addr

print('== forced --addr ==')
do
  local s = scenario('addr')
  H.lines_file(s.work .. '/f.txt', 20)
  local target = uv.fs_realpath(s.work .. '/f.txt')
  local elsewhere = H.mkdir(s.dir .. '/elsewhere')
  local sockA, sockB = s.glob_sock(), s.glob_sock()
  local candA, upA = H.spawn_nvim(sockA, { cwd = s.work, args = { target } })
  local candB, upB = H.spawn_nvim(sockB, { cwd = elsewhere })
  ok(upA and upB, 'addr: both candidates came up')

  -- sanity: the election prefers A, so B below is a forced NON-winner
  local r = run_cli(s, { 'open', 'f.txt', '--spawn', 'never', '--json' })
  local obj = jdecode(r.stdout)
  ok(r.code == 0 and obj and obj.winner and obj.winner.pid == candA.pid,
    'addr: election winner is the +100 editor', r.code)

  r = run_cli(s, { 'open', 'f.txt:7:3', '--addr', sockB, '--json' })
  obj = jdecode(r.stdout)
  ok(r.code == 0, 'addr: forced open exits 0', r.code .. ' ' .. (r.stderr or ''))
  ok(obj and obj.winner and obj.winner.addr == sockB and obj.winner.pid == candB.pid,
    'addr: winner is the forced non-winner')
  ok(obj and obj.winner and #obj.winner.reasons == 1 and obj.winner.reasons[1] == 'forced --addr',
    'addr: winner.reasons is exactly forced --addr',
    obj and obj.winner and vim.inspect(obj.winner.reasons) or nil)
  local name = rpc_eval(sockB, 'expand("%:p")')
  ok(name == target, 'addr: file opened in the forced editor', tostring(name))
  local pos = rpc_eval(sockB, 'getcurpos()')
  ok(type(pos) == 'table' and pos[2] == 7 and pos[3] == 3,
    'addr: cursor at 7:3 in the forced editor', vim.inspect(pos))

  -- R0 still runs under --addr
  H.lines_file(s.dir .. '/out/g.txt', 5)
  r = run_cli(s, { 'open', s.dir .. '/out/g.txt', '--addr', sockB })
  ok(r.code == 3, 'addr: confinement still enforced with --addr', r.code)

  -- dead socket: exit 4, discovery never consulted
  local dead = s.glob_sock()
  r = run_cli(s, { 'open', 'f.txt', '--addr', dead, '--json' })
  obj = jdecode(r.stdout)
  ok(r.code == 4, 'addr: dead socket exits 4', r.code)
  ok(obj and type(obj.error) == 'string' and obj.error:find('--addr', 1, true) ~= nil,
    'addr: json error names --addr', obj and obj.error)
  ok(obj and obj.ok == false and obj.exit_code == 4, 'addr: dead-socket json contract')
  ok(obj and #obj.candidates == 1, 'addr: no discovery beyond the forced addr',
    obj and #obj.candidates)

  -- wedged forced target: exit 4
  ok(H.wedge(sockB), 'addr: fixture wedged')
  r = run_cli(s, { 'open', 'f.txt', '--addr', sockB })
  ok(r.code == 4, 'addr: wedged socket exits 4', r.code)
  ok(r.stderr:find('never answered', 1, true) ~= nil, 'addr: wedged error says never answered', r.stderr)
end

-- ------------------------------------------------ launcher choose popup

print('== launcher choose popup ==')
do
  local s = scenario('popup')
  H.lines_file(s.work .. '/f.txt', 20)
  local elsewhere = H.mkdir(s.dir .. '/elsewhere')
  local sockA, sockB = s.glob_sock(), s.glob_sock()
  local candA, upA = H.spawn_nvim(sockA, { cwd = s.work })
  local candB, upB = H.spawn_nvim(sockB, { cwd = elsewhere })
  ok(upA and upB, 'popup: both candidates came up')

  local function enc(str)
    return (str:gsub('[^%w%-_%.~]', function(ch)
      return ('%%%02X'):format(ch:byte())
    end))
  end
  local url = 'https://openloc.invalid/o?p=' .. enc('f.txt') .. '&cwd=' .. enc(s.work)

  -- herdr stub: logs argv to $HERDR_STUB_LOG; pane open exits pane_exit.
  local function write_stub(dir, pane_exit)
    H.write_file(dir .. '/herdr', ([[#!/bin/sh
echo "$@" >> "${HERDR_STUB_LOG:?}"
if [ "$1 $2 $3" = "plugin pane open" ]; then exit %d; fi
exit 0
]]):format(pane_exit))
    uv.fs_chmod(dir .. '/herdr', tonumber('755', 8))
    return dir .. '/herdr'
  end
  local stub_ok = write_stub(H.mkdir(s.dir .. '/stub-ok'), 0)
  local stub_fail = write_stub(H.mkdir(s.dir .. '/stub-fail'), 1)

  local launcher = H.root .. '/herdr/bin/openloc-herdr'
  local iso = {
    OPENLOC_NVIM = vim.v.progpath,
    TMPDIR = s.tmp,
    USER = s.user,
    LOGNAME = s.user,
    XDG_RUNTIME_DIR = s.run,
    XDG_CACHE_HOME = s.cache,
    HOME = s.dir,
    PWD = s.work,
  }
  local function run_launcher(args, extra)
    local env = vim.tbl_extend('force', iso, extra or {})
    return vim.system(vim.list_extend({ 'bash', launcher }, args), {
      text = true,
      timeout = 8000,
      cwd = s.work,
      env = env,
    }):wait()
  end

  -- ambiguous election raises the popup, no toast, nothing opened
  local log1 = s.dir .. '/stub1.log'
  local r = run_launcher({ 'open-url', url },
    { HERDR_BIN_PATH = stub_ok, HERDR_STUB_LOG = log1 })
  ok(r.code == 0, 'popup: exit 6 handled, launcher exits 0', r.code .. ' ' .. (r.stderr or ''))
  local logged = slurp(log1)
  ok(logged:find('plugin pane open', 1, true) ~= nil, 'popup: stub received plugin pane open', logged)
  ok(logged:find('--plugin openloc', 1, true) ~= nil
    and logged:find('--entrypoint choose', 1, true) ~= nil,
    'popup: targets the choose entrypoint', logged)
  ok(logged:find('--placement popup', 1, true) ~= nil, 'popup: placement popup')
  ok(logged:find('OPENLOC_CHOOSE_JSON=', 1, true) ~= nil, 'popup: JSON forwarded via --env')
  ok(logged:find('ambiguous', 1, true) ~= nil, 'popup: forwarded JSON is the exit-6 payload')
  ok(logged:find('OPENLOC_CHOOSE_ARGS=open-url', 1, true) ~= nil,
    'popup: original args forwarded via --env', logged)
  ok(logged:find('notification show', 1, true) == nil, 'popup: no toast on exit 6')
  local bn = rpc_eval(sockA, 'bufname("%")') or ''
  ok(not bn:find('f.txt', 1, true), 'popup: nothing opened while the popup pends', bn)

  -- pane open fails: fall back to a direct open of the top candidate
  local log2 = s.dir .. '/stub2.log'
  r = run_launcher({ 'open-url', url },
    { HERDR_BIN_PATH = stub_fail, HERDR_STUB_LOG = log2 })
  ok(r.code == 0, 'popup: failed pane open falls back to direct open', r.code .. ' ' .. (r.stderr or ''))
  ok(r.stdout:find('opened ', 1, true) ~= nil and r.stdout:find(sockA, 1, true) ~= nil,
    'popup: fallback opened the top candidate', r.stdout)
  local logged2 = slurp(log2)
  ok(logged2:find('plugin pane open', 1, true) ~= nil, 'popup: failing stub was consulted')
  ok(logged2:find('notification show', 1, true) == nil, 'popup: fallback open raises no toast', logged2)

  -- run_cli_notify guard: a CLI stuck at exit 6 never toasts...
  local fake6 = s.dir .. '/fake6.lua'
  H.write_file(fake6, 'io.stdout:write("{}\\n")\nos.exit(6)\n')
  local log3 = s.dir .. '/stub3.log'
  r = run_launcher({ 'open-url', url },
    { HERDR_BIN_PATH = stub_fail, HERDR_STUB_LOG = log3, OPENLOC_CLI = fake6 })
  ok(r.code == 6, 'notify: exit 6 propagates through the fallback', r.code)
  local logged3 = slurp(log3)
  ok(logged3:find('plugin pane open', 1, true) ~= nil, 'notify: exit-6 path ran (stub consulted)')
  ok(logged3:find('notification show', 1, true) == nil, 'notify: no toast on exit 6', logged3)

  -- ...while a real failure still does (the guard is not vacuous)
  local fake4 = s.dir .. '/fake4.lua'
  H.write_file(fake4, 'io.stderr:write("boom failure\\n")\nos.exit(4)\n')
  local log4 = s.dir .. '/stub4.log'
  r = run_launcher({ 'open-url', url },
    { HERDR_BIN_PATH = stub_fail, HERDR_STUB_LOG = log4, OPENLOC_CLI = fake4 })
  ok(r.code == 4, 'notify: real failures propagate', r.code)
  local logged4 = slurp(log4)
  ok(logged4:find('notification show', 1, true) ~= nil,
    'notify: real failure raises the toast', logged4)

  -- A failing exit must run the CLI exactly once. Re-running holds a second
  -- election, which can elect a different editor, and after exit 4 or 5 the
  -- first one may already hold the file.
  for _, code in ipairs({ 3, 4, 5 }) do
    local counter = s.dir .. '/count' .. code .. '.txt'
    local fake = s.dir .. '/fake-count' .. code .. '.lua'
    H.write_file(fake, ([[
local f = io.open(%q, 'a')
f:write('x\n')
f:close()
io.stderr:write('failure %d\n')
os.exit(%d)
]]):format(counter, code, code))
    run_launcher({ 'open-url', url },
      { HERDR_BIN_PATH = stub_fail, HERDR_STUB_LOG = s.dir .. '/stubc.log', OPENLOC_CLI = fake })
    local runs = select(2, slurp(counter):gsub('x', ''))
    ok(runs == 1, 'no-retry: exit ' .. code .. ' invokes the CLI once', tostring(runs))
  end
end

-- ---------------------------------------------- chooser popup script

print('== chooser popup script ==')
do
  local s = scenario('chooser')
  H.lines_file(s.work .. '/f.txt', 20)
  local target = uv.fs_realpath(s.work .. '/f.txt')
  local elsewhere = H.mkdir(s.dir .. '/elsewhere')
  local sockA, sockB = s.glob_sock(), s.glob_sock()
  local candA, upA = H.spawn_nvim(sockA, { cwd = s.work })
  local candB, upB = H.spawn_nvim(sockB, { cwd = elsewhere })
  ok(upA and upB, 'chooser: both candidates came up')

  -- real exit-6 payload from the CLI, exactly what the launcher forwards
  local r = run_cli(s, { 'open', 'f.txt', '--choose', 'auto', '--spawn', 'never', '--json' })
  ok(r.code == 6, 'chooser: fixture election is ambiguous', r.code)
  local payload = vim.trim(r.stdout or '')

  local chooser = H.root .. '/herdr/bin/openloc-choose'
  local function run_chooser(input)
    local env = {
      OPENLOC_NVIM = vim.v.progpath,
      OPENLOC_CHOOSE_JSON = payload,
      OPENLOC_CHOOSE_ARGS = 'open\tf.txt',
      OPENLOC_CHOOSE_INPUT = input,
      TMPDIR = s.tmp,
      USER = s.user,
      LOGNAME = s.user,
      XDG_RUNTIME_DIR = s.run,
      XDG_CACHE_HOME = s.cache,
      HOME = s.dir,
      PWD = s.work,
    }
    return vim.system({ 'bash', chooser }, {
      text = true,
      timeout = 8000,
      cwd = s.work,
      env = env,
    }):wait()
  end

  -- payload order is score desc: 1 = A (+20 cwd), 2 = B (0)
  r = run_chooser('2')
  ok(r.code == 0, 'chooser: forced pick 2 exits 0', r.code .. ' ' .. (r.stderr or ''))
  ok(r.stdout:find('pick one', 1, true) ~= nil, 'chooser: menu rendered', r.stdout)
  ok(r.stdout:find(sockB, 1, true) ~= nil, 'chooser: pick 2 opened at the runner-up addr', r.stdout)
  local name = rpc_eval(sockB, 'expand("%:p")')
  ok(name == target, 'chooser: file open in the picked editor', tostring(name))

  r = run_chooser('junk')
  ok(r.code == 0 and r.stdout:find(sockA, 1, true) ~= nil,
    'chooser: non-numeric input defaults to the top score', r.stdout)
end


-- ---------------------------------- --json failures still reach stderr

print('== json failures reach stderr ==')
do
  -- The herdr launcher always passes --json and captures stdout, so an
  -- error that lives only in the JSON leaves the toast with just an exit
  -- code. Failures must appear on stderr in both output modes.
  local s = scenario('jsonerr')
  local r = run_cli(s, { 'open', 'nope-xyz.txt', '--spawn', 'never', '--json' })
  ok(r.code == 3, 'jsonerr: missing file still exits 3', r.code)
  local obj = jdecode(r.stdout)
  ok(obj and obj.error ~= nil, 'jsonerr: the JSON still carries the error', r.stdout)
  ok((r.stderr or ''):find('not an existing regular file', 1, true) ~= nil,
    'jsonerr: --json failures also write the reason to stderr', vim.inspect(r.stderr))
end

-- ------------------------------------ R9 spawn lock: rapid clicks share one editor

print('== spawn lock ==')
do
  -- helper: the responding herdr stub shared by these cases
  local function spawn_stub(s, name)
    local d = H.mkdir(s.dir .. '/' .. name)
    local log = s.dir .. '/' .. name .. '.log'
    H.write_file(d .. '/herdr', ([[#!/bin/sh
echo "$@" >> "%s"
case "$1 $2" in
  "pane list") echo '{"id":1,"result":{"panes":[]}}' ;;
  "pane split") echo '{"id":2,"result":{"pane_id":"w1:p9"}}' ;;
  "pane run") echo '{"id":3,"result":{}}' ;;
  *) echo '{"id":9,"error":{"code":"stub_unhandled"}}' ;;
esac
]]):format(log))
    uv.fs_chmod(d .. '/herdr', tonumber('755', 8))
    return d, log
  end
  local ctx_of = function(s)
    return vim.json.encode({ workspace_id = 'w1', focused_pane_id = 'w1:p1', workspace_cwd = s.work })
  end

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

  -- fresh lock + live socket: the second click JOINS instead of splitting
  local s2 = scenario('sjoin')
  H.lines_file(s2.work .. '/f.txt', 20)
  local stub2, log2 = spawn_stub(s2, 'stub')
  local regdir = H.mkdir(s2.cache .. '/nvim/openloc')
  local sock2 = regdir .. '/ws-w1.sock'
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
  local logged2 = slurp(log2)
  ok(logged2:find('pane split', 1, true) == nil, 'sjoin: no second split', logged2)
  local pos = rpc_eval(sock2, 'expand("%:t") .. ":" .. line(".")')
  ok(pos == 'f.txt:7', 'sjoin: file and line landed in the joined editor', tostring(pos))

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

H.summary({ BASE ~= vim.env.OLTEST_BASE and BASE or nil })
