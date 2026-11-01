-- CLI scenario harness shared by the test_cli_* and test_herdr_* files:
-- an isolated fixture tree per scenario, subprocess invocation of the CLI and
-- the herdr launcher, and the stand-ins they need. dofile'd with the helpers
-- instance so assertion counters stay shared; not a runtime module.
--
--   local S = dofile(H.tests_dir .. '/scenario.lua')(H, '<file name>')

return function(H, name)
  local uv = vim.uv
  local S = {}

  S.BASE = vim.env.OLTEST_BASE
  if not S.BASE or S.BASE == '' then
    S.BASE = H.mkdir('/tmp/oltest-' .. name .. '-' .. uv.os_getpid())
  end
  local OPENLOC = H.root .. '/bin/openloc'
  local LAUNCHER = H.root .. '/herdr/bin/openloc-herdr'

  -- Each scenario gets its own TMPDIR, fake user, runtime dir and cache, so
  -- the CLI's three glob shapes and its registry can only ever see fixtures
  -- this scenario planted.
  function S.scenario(label)
    local s = {}
    s.name = label
    s.dir = S.BASE .. '/rt-' .. label
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

  -- The scenario's confinement of temp, runtime and cache dirs.
  function S.isolated_env(s)
    return {
      TMPDIR = s.tmp,
      USER = s.user,
      LOGNAME = s.user,
      XDG_RUNTIME_DIR = s.run,
      XDG_CACHE_HOME = s.cache,
      HOME = s.dir,
      PWD = s.work,
    }
  end

  -- Start the CLI with the scenario's isolated env and return the running
  -- process; :wait() collects it. HERDR_*/OPENLOC_* are masked to '' (the CLI
  -- treats empty as unset); opts.env overrides win.
  function S.start_cli(s, args, opts)
    opts = opts or {}
    local env = vim.tbl_extend('force', S.isolated_env(s), {
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
      OPENLOC_STRICT = '',
      OPENLOC_SPAWN = '',
      OPENLOC_NVIM = '',
      OPENLOC_PICK_MARGIN = '',
    })
    for k, v in pairs(opts.env or {}) do
      env[k] = v
    end
    local argv = { vim.v.progpath, '-l', OPENLOC }
    vim.list_extend(argv, args)
    return vim.system(argv, {
      env = env,
      cwd = opts.cwd or s.work,
      text = true,
      timeout = 8000,
    })
  end

  -- Run the CLI to completion; res.ms is its wall time.
  function S.run_cli(s, args, opts)
    local t0 = uv.hrtime()
    local res = S.start_cli(s, args, opts):wait()
    res.ms = (uv.hrtime() - t0) / 1e6
    return res
  end

  -- The herdr launcher script under the scenario's isolated env.
  function S.run_launcher(s, args, extra)
    local env = vim.tbl_extend('force', S.isolated_env(s), { OPENLOC_NVIM = vim.v.progpath }, extra or {})
    return vim.system(vim.list_extend({ 'bash', LAUNCHER }, args), {
      text = true,
      timeout = 8000,
      cwd = s.work,
      env = env,
    }):wait()
  end

  function S.jdecode(str)
    local okd, obj = pcall(vim.json.decode, str, { luanil = { object = true, array = true } })
    return okd and obj or nil
  end

  function S.find_cand(obj, field, value)
    for _, c in ipairs(obj and obj.candidates or {}) do
      if c[field] == value then
        return c
      end
    end
    return nil
  end

  -- Evaluate an expression inside a live candidate, nil on any failure.
  function S.rpc_eval(sock, expr)
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

  function S.slurp(p)
    local f = io.open(p, 'r')
    if not f then
      return ''
    end
    local body = f:read('*a')
    f:close()
    return body
  end

  -- Percent-encode a query value the way a link writer would.
  function S.enc(str)
    return (str:gsub('[^%w%-_%.~]', function(ch)
      return ('%%%02X'):format(ch:byte())
    end))
  end

  -- Any nvim socket left anywhere under the scenario's TMPDIR or runtime dir.
  -- The run-dir layout differs across platforms; sweep every depth.
  function S.socket_litter(s, ignore)
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

  -- A `herdr` stand-in on PATH: dir/herdr runs body.
  function S.herdr_stub(dir, body)
    H.mkdir(dir)
    H.write_exec(dir .. '/herdr', body)
    return dir .. '/herdr'
  end

  -- The herdr stand-in for spawn tests: logs argv, answers pane split/run.
  -- Returns its dir and the log path.
  function S.spawn_stub(s, label)
    local dir = s.dir .. '/' .. label
    local log = s.dir .. '/' .. label .. '.log'
    S.herdr_stub(dir, ([[#!/bin/sh
echo "$@" >> "%s"
case "$1 $2" in
  "pane list") echo '{"id":1,"result":{"panes":[]}}' ;;
  "pane split") echo '{"id":2,"result":{"pane_id":"w1:p9"}}' ;;
  "pane run") echo '{"id":3,"result":{}}' ;;
  *) echo '{"id":9,"error":{"code":"stub_unhandled"}}' ;;
esac
]]):format(log))
    return dir, log
  end

  -- herdr plugin context as the action environment carries it.
  function S.plugin_ctx(s)
    return vim.json.encode({ workspace_id = 'w1', focused_pane_id = 'w1:p1', workspace_cwd = s.work })
  end

  function S.summary()
    H.summary({ S.BASE ~= vim.env.OLTEST_BASE and S.BASE or nil })
  end

  return S
end
