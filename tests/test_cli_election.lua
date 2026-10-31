-- Choosing among several editors: cwd and open-file signals, the registry fast path, live workspace and session scope, term-only editors, --choose auto, forced --addr.
-- Run: nvim -l tests/test_cli_election.lua (or via tests/run.sh)

local uv = vim.uv

local this = debug.getinfo(1, 'S').source:sub(2)
local this_abs = uv.fs_realpath(this) or this
local H = dofile(vim.fs.dirname(this_abs) .. '/helpers.lua')
H.ensure_isolated('cli_election', this_abs)
local S = dofile(H.tests_dir .. '/scenario.lua')(H, 'cli_election')

local ok = H.ok
local scenario, run_cli, jdecode, find_cand, rpc_eval = S.scenario, S.run_cli, S.jdecode, S.find_cand, S.rpc_eval

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
  local x = find_cand(obj, 'addr', sockX)
  ok(x and x.excluded == false and x.score < obj.winner.score,
    'cwd: unrelated editor stays eligible but ranks below the winner', x and x.score or 'missing')
end

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
end

print('== registry fast path ==')
do
  local s = scenario('reg')
  H.lines_file(s.work .. '/f.txt', 20)
  local elsewhere = H.mkdir(s.dir .. '/elsewhere2')
  local regdir = H.mkdir(s.cache .. '/nvim/openloc')
  local rsock = regdir .. '/ws-w1.sock'
  local cand, up = H.spawn_nvim(rsock, { cwd = elsewhere })
  ok(up, 'registry: claimed editor came up')
  -- a rival whose cwd contains the target would win an election on score
  local rival_sock = s.glob_sock()
  local rival, rup = H.spawn_nvim(rival_sock, { cwd = s.work })
  ok(rup, 'registry: rival editor came up')

  local r = run_cli(s, { 'open', 'f.txt', '--ws', 'w1', '--spawn', 'never', '--json' })
  local obj = jdecode(r.stdout)
  ok(r.code == 0, 'registry: exits 0', r.code .. ' ' .. (r.stderr or ''))
  ok(obj and obj.winner and obj.winner.addr == rsock, 'registry: ws-key socket wins outright')
  ok(obj and obj.winner and obj.winner.pid == cand.pid, 'registry: winner pid matches')
  ok(obj and obj.winner and obj.winner.pid ~= rival.pid, 'registry: a better-scoring rival does not displace it')
end

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
  S.herdr_stub(stubdir, stub)

  local r = run_cli(s, { 'open', 'f.txt', '--ws', 'w1', '--spawn', 'never', '--json' },
    { path_prefix = stubdir })
  local obj = jdecode(r.stdout)
  ok(r.code == 0, 'live: exits 0', r.code .. ' ' .. (r.stderr or ''))
  ok(obj and obj.live_map_used == true, 'live: live map was consulted')
  ok(obj and obj.winner and obj.winner.pid == candA.pid, 'live: confirmed-in-ws editor wins')

  local b = find_cand(obj, 'pid', candB.pid)
  ok(b ~= nil, 'live: unconfirmed-mismatch candidate listed', r.stdout)
  ok(b and b.excluded == false, 'live: unconfirmed mismatch demoted, NOT excluded')
  ok(b and obj.winner and b.score < obj.winner.score, 'live: the demoted candidate ranks below the confirmed one')

  local c = find_cand(obj, 'pid', candC.pid)
  ok(c ~= nil, 'live: confirmed-elsewhere candidate listed')
  ok(c and c.excluded == true, 'live: confirmed-other-workspace candidate excluded')

  -- demotion is not exclusion: with the confirmed editor gone, the
  -- unconfirmed one still takes the open
  candA:kill(9)
  pcall(function()
    candA:wait(2000)
  end)
  r = run_cli(s, { 'open', 'f.txt', '--ws', 'w1', '--spawn', 'never', '--json' },
    { path_prefix = stubdir })
  obj = jdecode(r.stdout)
  ok(r.code == 0 and obj and obj.winner and obj.winner.pid == candB.pid,
    'live: an unconfirmed-mismatch editor still opens when nothing better is left',
    r.code .. ' ' .. (r.stderr or ''))
end

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

  local nsock = s.glob_sock()
  local cand, up2 = H.spawn_nvim(nsock, { cwd = s.work })
  ok(up2, 'term: normal sibling came up')
  r = run_cli(s, { 'open', 'f.txt', '--spawn', 'never', '--json' })
  obj = jdecode(r.stdout)
  ok(r.code == 0 and obj and obj.winner and obj.winner.pid == cand.pid,
    'term: normal sibling wins over the terminal host', r.code)
end

print('== choose election ==')
do
  local s = scenario('choose')
  H.lines_file(s.work .. '/f.txt', 20)
  H.lines_file(s.work .. '/g.txt', 20)
  H.lines_file(s.work .. '/h.txt', 20)
  local elsewhere = H.mkdir(s.dir .. '/elsewhere')
  local sockA, sockB = s.glob_sock(), s.glob_sock()
  -- A: cwd ancestor of the targets. B: unrelated cwd. The gap sits under the
  -- default margin, so both are close AND deterministically ordered.
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

  -- OPENLOC_PICK_MARGIN override: any real gap clears a margin of 1
  r = run_cli(s, { 'open', 'f.txt', '--choose', 'auto', '--spawn', 'never', '--json' },
    { env = { OPENLOC_PICK_MARGIN = '1' } })
  obj = jdecode(r.stdout)
  ok(r.code == 0, 'choose auto: OPENLOC_PICK_MARGIN override opens', r.code .. ' ' .. (r.stderr or ''))
  ok(obj and obj.winner and obj.winner.pid == candA.pid, 'choose auto: override winner is the top scorer')

  -- A now holds f.txt: that is decisive, the gap clears the default margin
  r = run_cli(s, { 'open', 'f.txt', '--choose', 'auto', '--spawn', 'never', '--json' })
  obj = jdecode(r.stdout)
  ok(r.code == 0, 'choose auto: clear winner opens', r.code)
  ok(obj and obj.winner and obj.winner.pid == candA.pid,
    'choose auto: clear winner is the editor holding the file')

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
    'addr: election winner is the editor holding the file', r.code)

  r = run_cli(s, { 'open', 'f.txt:7:3', '--addr', sockB, '--json' })
  obj = jdecode(r.stdout)
  ok(r.code == 0, 'addr: forced open exits 0', r.code .. ' ' .. (r.stderr or ''))
  ok(obj and obj.winner and obj.winner.addr == sockB and obj.winner.pid == candB.pid,
    'addr: winner is the forced non-winner')
  local name = rpc_eval(sockB, 'expand("%:p")')
  ok(name == target, 'addr: file opened in the forced editor', tostring(name))
  local pos = rpc_eval(sockB, 'getcurpos()')
  ok(type(pos) == 'table' and pos[2] == 7 and pos[3] == 3,
    'addr: cursor at 7:3 in the forced editor', vim.inspect(pos))

  -- R0 still runs under --addr
  r = run_cli(s, { 'open', s.dir .. '/out/nope-g.txt', '--addr', sockB })
  ok(r.code == 3, 'addr: stat oracle still enforced with --addr', r.code)

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

S.summary()
