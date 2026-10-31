-- The herdr adapter scripts: the subdir shim, the launcher, the chooser popup flow and the chooser script.
-- Run: nvim -l tests/test_herdr_scripts.lua (or via tests/run.sh)

local uv = vim.uv

local this = debug.getinfo(1, 'S').source:sub(2)
local this_abs = uv.fs_realpath(this) or this
local H = dofile(vim.fs.dirname(this_abs) .. '/helpers.lua')
H.ensure_isolated('herdr_scripts', this_abs)
local S = dofile(H.tests_dir .. '/scenario.lua')(H, 'herdr_scripts')

local ok = H.ok
local scenario, run_cli, rpc_eval, slurp, enc = S.scenario, S.run_cli, S.rpc_eval, S.slurp, S.enc

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

  -- in the full layout the shim hands off to the CLI and returns its exit code
  r = vim.system({ vim.v.progpath, '-l', shim_src, 'list' }, {
    text = true,
    timeout = 8000,
    env = S.isolated_env(s),
  }):wait()
  ok(r.code == 0 and (r.stdout or ''):find('no live editors', 1, true) ~= nil,
    'shim: full layout runs the CLI', r.code .. ' ' .. (r.stdout or '') .. (r.stderr or ''))
  r = vim.system({ vim.v.progpath, '-l', shim_src, 'bogus' }, {
    text = true,
    timeout = 8000,
    env = S.isolated_env(s),
  }):wait()
  ok(r.code == 1, 'shim: the CLI exit code propagates', r.code)
end

print('== herdr launcher ==')
do
  local s = scenario('launch')
  local r = S.run_launcher(s, { 'open-url' }, { HERDR_PLUGIN_CLICKED_URL = '' })
  ok(r.code == 1, 'launcher: open-url without a URL exits 1 (usage)', r.code)

  -- unknown subcommands fall through to the CLI, which rejects them
  r = S.run_launcher(s, { 'pick' }, {})
  ok(r.code == 1, 'launcher: the removed pick subcommand is no longer handled',
    r.code .. ' ' .. (r.stderr or ''))

  -- Without the subdir shim the launcher must still reach a CLI that runs:
  -- the fallback entry has to execute main, not merely load the module.
  local layout = H.mkdir(s.dir .. '/layout')
  H.mkdir(layout .. '/herdr')
  H.mkdir(layout .. '/bin')
  H.write_file(layout .. '/bin/openloc', slurp(H.root .. '/bin/openloc'))
  uv.fs_symlink(H.root .. '/lua', layout .. '/lua')
  r = S.run_launcher(s, { 'list' }, { HERDR_PLUGIN_ROOT = layout .. '/herdr' })
  ok(r.code == 0 and (r.stdout or ''):find('no live editors', 1, true) ~= nil,
    'launcher: shimless fallback runs the CLI', r.code .. ' ' .. (r.stdout or '') .. (r.stderr or ''))
end

print('== launcher choose popup ==')
do
  local s = scenario('popup')
  H.lines_file(s.work .. '/f.txt', 20)
  local elsewhere = H.mkdir(s.dir .. '/elsewhere')
  local sockA, sockB = s.glob_sock(), s.glob_sock()
  local candA, upA = H.spawn_nvim(sockA, { cwd = s.work })
  local candB, upB = H.spawn_nvim(sockB, { cwd = elsewhere })
  ok(upA and upB, 'popup: both candidates came up')

  local url = 'https://openloc.invalid/o?p=' .. enc('f.txt') .. '&cwd=' .. enc(s.work)

  -- herdr stub: logs argv to $HERDR_STUB_LOG; pane open exits pane_exit.
  local function write_stub(dir, pane_exit)
    return S.herdr_stub(dir, ([[#!/bin/sh
echo "$@" >> "${HERDR_STUB_LOG:?}"
if [ "$1 $2 $3" = "plugin pane open" ]; then exit %d; fi
exit 0
]]):format(pane_exit))
  end
  local stub_ok = write_stub(s.dir .. '/stub-ok', 0)
  local stub_fail = write_stub(s.dir .. '/stub-fail', 1)

  -- ambiguous election raises the popup, no toast, nothing opened
  local log1 = s.dir .. '/stub1.log'
  local r = S.run_launcher(s, { 'open-url', url },
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
  r = S.run_launcher(s, { 'open-url', url },
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
  r = S.run_launcher(s, { 'open-url', url },
    { HERDR_BIN_PATH = stub_fail, HERDR_STUB_LOG = log3, OPENLOC_CLI = fake6 })
  ok(r.code == 6, 'notify: exit 6 propagates through the fallback', r.code)
  local logged3 = slurp(log3)
  ok(logged3:find('plugin pane open', 1, true) ~= nil, 'notify: exit-6 path ran (stub consulted)')
  ok(logged3:find('notification show', 1, true) == nil, 'notify: no toast on exit 6', logged3)

  -- ...while a real failure still does (the guard is not vacuous)
  local fake4 = s.dir .. '/fake4.lua'
  H.write_file(fake4, 'io.stderr:write("boom failure\\n")\nos.exit(4)\n')
  local log4 = s.dir .. '/stub4.log'
  r = S.run_launcher(s, { 'open-url', url },
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
    S.run_launcher(s, { 'open-url', url },
      { HERDR_BIN_PATH = stub_fail, HERDR_STUB_LOG = s.dir .. '/stubc.log', OPENLOC_CLI = fake })
    local runs = select(2, slurp(counter):gsub('x', ''))
    ok(runs == 1, 'no-retry: exit ' .. code .. ' invokes the CLI once', tostring(runs))
  end
end

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
    local env = vim.tbl_extend('force', S.isolated_env(s), {
      OPENLOC_NVIM = vim.v.progpath,
      OPENLOC_CHOOSE_JSON = payload,
      OPENLOC_CHOOSE_ARGS = 'open\tf.txt',
      OPENLOC_CHOOSE_INPUT = input,
    })
    return vim.system({ 'bash', chooser }, {
      text = true,
      timeout = 8000,
      cwd = s.work,
      env = env,
    }):wait()
  end

  -- payload order is score desc: 1 = A (cwd ancestor), 2 = B (unrelated)
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

S.summary()
