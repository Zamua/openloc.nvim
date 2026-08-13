-- CLI router: open, open-url, list, doctor. Runs under `nvim -l` (no plugin
-- runtimepath, no init.lua); the entry script performs the R-1 self-unpublish
-- before this file loads. Implements R0 (stat oracle + confinement), R1-R3
-- (registry fast paths), R4 (candidate union), R5 (deadline-bounded probes),
-- R6 (live workspace filter), R7 (scoring), R8 (open), R9 (spawn fallback),
-- R10 (focus). No step may block past the global wall-clock cap.

-- Under nvim -l require() cannot see this repo; resolve it from this file.
if not pcall(require, 'openloc.key') then
  local src = debug.getinfo(1, 'S').source:gsub('^@', '')
  local dir = vim.fs.dirname((vim.uv or vim.loop).fs_realpath(src) or src)
  local lua_root = vim.fs.dirname(dir)
  package.path = lua_root .. '/?.lua;' .. lua_root .. '/?/init.lua;' .. package.path
end

local uv = vim.uv
local key = require('openloc.key')
local remote = require('openloc.remote')

local M = {}

local GLOBAL_CAP_MS = 5000
local HERDR_CALL_MS = 800
-- Budget kept back for the steps after the current one (open + focus).
local RESERVE_PROBE_MS = 2500
local RESERVE_LIVEMAP_MS = 1700
local RESERVE_OPEN_MS = 500

local EXIT = {
  ok = 0,
  usage = 1,
  no_editor = 2,
  unresolved = 3,
  open_failed = 4,
  deadline = 5,
  ambiguous = 6,
}

local DEFAULT_PICK_MARGIN = 75

local USAGE = table.concat({
  'usage: nvim -l bin/openloc <command> [args]',
  '  open <path>[:line[:col]] [--ws ID] [--cwd PATH] [--line N] [--col N] [--addr SOCKET]',
  '       [--choose auto|never] [--json] [--spawn split|never]',
  '  open-url <url> [--strict] [--addr SOCKET] [--choose auto|never] [--json] [--spawn split|never]',
  '  list [--json]',
  '  doctor',
}, '\n') .. '\n'

-- ---------------------------------------------------------------- utilities

local function getenv(name)
  local v = vim.env[name]
  if v == nil or v == '' then
    return nil
  end
  return v
end

local function remaining_ms(state)
  return GLOBAL_CAP_MS - math.floor((uv.hrtime() - state.t0) / 1e6)
end

-- Deadline for the next step: at most ms, never past the global cap minus
-- what later steps still need.
local function clamp(state, ms, reserve)
  local rem = remaining_ms(state) - (reserve or 0)
  if rem < 0 then
    rem = 0
  end
  if ms and ms < rem then
    return ms
  end
  return rem
end

local function is_file(p)
  local st = uv.fs_stat(p)
  return st ~= nil and st.type == 'file'
end

-- realpath of a directory, trailing slash stripped, nil if it does not exist.
local function norm_dir(p)
  if type(p) ~= 'string' or p == '' then
    return nil
  end
  local r = uv.fs_realpath(p)
  if not r then
    return nil
  end
  r = r:gsub('/+$', '')
  if r == '' then
    r = '/'
  end
  return r
end

local function is_ancestor(dir, path)
  if not dir or not path then
    return false
  end
  if dir == '/' then
    return path:sub(1, 1) == '/'
  end
  return path == dir or path:sub(1, #dir + 1) == dir .. '/'
end

-- Control, zero-width and bidi characters are how a displayed path lies
-- about its target.
local function forbidden(path)
  if path:find('%c') then return true end
  if path:find('\226\128[\139-\141]') then return true end -- U+200B..U+200D
  if path:find('\239\187\191', 1, true) then return true end -- U+FEFF
  if path:find('\226\128[\170-\174]') then return true end -- U+202A..U+202E
  if path:find('\226\129[\166-\169]') then return true end -- U+2066..U+2069
  return false
end

local function pct_decode(s)
  return (s:gsub('%%(%x%x)', function(h)
    return string.char(tonumber(h, 16))
  end))
end

-- Accepts any http(s) URL and reads only the query params; --strict (or
-- OPENLOC_STRICT=1) additionally requires the openloc.invalid host.
local function parse_url(url)
  local scheme = url:match('^(%a[%w+%-.]*)://')
  if not scheme then
    return nil, 'not a URL: ' .. url
  end
  local lower = scheme:lower()
  if lower ~= 'http' and lower ~= 'https' then
    return nil, 'non-http(s) scheme: ' .. scheme
  end
  local rest = url:sub(#scheme + 4)
  local host = rest:match('^([^/?#]*)') or ''
  local query = url:match('%?([^#]*)') or ''
  local params = {}
  for kv in query:gmatch('[^&]+') do
    local k, v = kv:match('^([^=]*)=?(.*)$')
    if k and k ~= '' then
      params[pct_decode(k)] = pct_decode(v or '')
    end
  end
  return { host = host, params = params }
end

-- <path>[:line[:col]] with a tolerated trailing colon (go test output).
local function split_spec(spec)
  local p, l, c = spec:match('^(.-):(%d+):(%d+):?$')
  if p and p ~= '' then
    return p, tonumber(l), tonumber(c)
  end
  p, l = spec:match('^(.-):(%d+):?$')
  if p and p ~= '' then
    return p, tonumber(l)
  end
  return spec
end

local function run_cmd(state, argv, ms, reserve)
  local budget = clamp(state, ms, reserve)
  if budget <= 0 then
    return nil
  end
  local ok, proc = pcall(vim.system, argv, { text = true, timeout = budget })
  if not ok then
    return nil
  end
  local ok2, res = pcall(function()
    return proc:wait()
  end)
  if not ok2 or type(res) ~= 'table' or res.code ~= 0 then
    return nil
  end
  return res.stdout
end

-- herdr CLI output is a JSON envelope: {id, result} or {id, error}.
-- Returns result, ok. A null result decodes to nil under luanil, so the
-- second value alone distinguishes success from failure.
local function herdr_json(state, argv, ms, reserve)
  local out = run_cmd(state, argv, ms, reserve)
  if not out then
    return nil, false
  end
  local ok, decoded = pcall(vim.json.decode, out, { luanil = { object = true, array = true } })
  if not ok or type(decoded) ~= 'table' or decoded.error ~= nil then
    return nil, false
  end
  return decoded.result, true
end

local function herdr_bin()
  local p = getenv('HERDR_BIN_PATH')
  if p and uv.fs_stat(p) then
    return p
  end
  local e = vim.fn.exepath('herdr')
  if e ~= '' then
    return e
  end
  return nil
end

-- ------------------------------------------------------------ argv parsing

local SPAWN_MODES = { split = true, never = true }
local CHOOSE_MODES = { auto = true, never = true }

local function parse_flags(argv, i0)
  local flags, pos = {}, {}
  local i = i0
  local err
  -- Consume the next argv entry as a flag value; absent or another flag is
  -- a usage error, never silently swallowed.
  local function value(a)
    i = i + 1
    local v = argv[i]
    if v == nil or v:sub(1, 2) == '--' then
      err = 'flag ' .. a .. ' needs a value'
      return nil
    end
    return v
  end
  local function number(a)
    local v = value(a)
    if err then
      return nil
    end
    local n = tonumber(v)
    if not n then
      err = 'flag ' .. a .. ' takes a number'
    end
    return n
  end
  while i <= #argv do
    local a = argv[i]
    if a == '--json' then
      flags.json = true
    elseif a == '--strict' then
      flags.strict = true
    elseif a == '--ws' then
      flags.ws = value(a)
    elseif a == '--cwd' then
      flags.cwd = value(a)
    elseif a == '--line' then
      flags.line = number(a)
    elseif a == '--col' then
      flags.col = number(a)
    elseif a == '--spawn' then
      flags.spawn = value(a)
      if not err and not SPAWN_MODES[flags.spawn or ''] then
        return nil, '--spawn takes split|never'
      end
    elseif a == '--addr' then
      flags.addr = value(a)
    elseif a == '--choose' then
      flags.choose = value(a)
      if not err and not CHOOSE_MODES[flags.choose or ''] then
        return nil, '--choose takes auto|never'
      end
    elseif a:sub(1, 2) == '--' then
      return nil, 'unknown flag: ' .. a
    else
      pos[#pos + 1] = a
    end
    if err then
      return nil, err
    end
    i = i + 1
  end
  return flags, pos
end

-- ------------------------------------------------------------- ctx and R0

local function build_ctx(flags, url)
  local ctx = {}
  local raw = getenv('HERDR_PLUGIN_CONTEXT_JSON')
  local plug = {}
  if raw then
    local ok, decoded = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
    if ok and type(decoded) == 'table' then
      plug = decoded
    end
  end
  local url_ws = url and url.params.ws
  ctx.workspace_id = flags.ws or url_ws or plug.workspace_id or getenv('HERDR_WORKSPACE_ID')
  ctx.workspace_cwd = plug.workspace_cwd
  ctx.focused_pane_cwd = plug.focused_pane_cwd
  ctx.focused_pane_id = plug.focused_pane_id or getenv('HERDR_PANE_ID')
  if type(plug.worktree) == 'table' then
    ctx.worktree = plug.worktree
  end
  ctx.base = flags.cwd or (url and url.params.cwd)
  -- Pane-inherited HERDR_* vars are absent in a plugin action or link
  -- handler, which receives only HERDR_PLUGIN_*; both mean herdr is present.
  ctx.herdr_env = (getenv('HERDR_ENV') or getenv('HERDR_PANE_ID') or getenv('HERDR_WORKSPACE_ID')
    or getenv('HERDR_PLUGIN_CONTEXT_JSON') or getenv('HERDR_PLUGIN_ROOT')) ~= nil
  return ctx
end

local function roots_in_order(ctx)
  local roots = {}
  local function add(p)
    if type(p) == 'string' and p ~= '' then
      roots[#roots + 1] = p
    end
  end
  add(ctx.worktree and ctx.worktree.checkout_path)
  add(ctx.workspace_cwd)
  add(ctx.focused_pane_cwd)
  add(ctx.base)
  add(getenv('PWD') or uv.cwd())
  return roots
end

-- Resolve raw against the bases, first hit wins. Absolute paths stand alone.
local function resolve_one(raw, roots, tried)
  local p = raw
  if p:sub(1, 1) == '~' then
    p = vim.fs.normalize(p)
  end
  if p:sub(1, 1) == '/' then
    tried[#tried + 1] = p
    if is_file(p) then
      return uv.fs_realpath(p) or p
    end
    return nil
  end
  for _, base in ipairs(roots) do
    local joined = base:gsub('/+$', '') .. '/' .. p
    tried[#tried + 1] = joined
    if is_file(joined) then
      return uv.fs_realpath(joined) or joined
    end
  end
  return nil
end

-- R0. Returns target, line, col, tried. The suffix parse is attempted, and
-- the raw spelling is retried whenever the other form fails to resolve, so a
-- file literally named 'a:3' still opens.
local function resolve_target(spec, roots, is_url)
  local tried = {}
  local p, l, c = split_spec(spec)
  if is_url then
    local t = resolve_one(spec, roots, tried)
    if t then
      return t, nil, nil, tried
    end
    if p ~= spec then
      t = resolve_one(p, roots, tried)
      if t then
        return t, l, c, tried
      end
    end
    return nil, nil, nil, tried
  end
  local t = resolve_one(p, roots, tried)
  if t then
    return t, l, c, tried
  end
  if p ~= spec then
    t = resolve_one(spec, roots, tried)
    if t then
      return t, nil, nil, tried
    end
  end
  return nil, nil, nil, tried
end

-- Confinement: the realpath must sit under a resolved root or a dir from the
-- OPENLOC_ALLOW allowlist (colon-separated). Returns the containing dir.
local function confined(target, roots)
  local dirs = {}
  for _, r in ipairs(roots) do
    dirs[#dirs + 1] = r
  end
  for d in (getenv('OPENLOC_ALLOW') or ''):gmatch('[^:]+') do
    dirs[#dirs + 1] = d
  end
  for _, d in ipairs(dirs) do
    local nd = norm_dir(d)
    if nd and is_ancestor(nd, target) then
      return nd
    end
  end
  return nil
end

-- --------------------------------------------------------------- discovery

local function registry_sockets()
  local dir = key.registry_dir()
  local out = {}
  if not uv.fs_stat(dir) then
    return out
  end
  local ok, iter = pcall(vim.fs.dir, dir)
  if not ok then
    return out
  end
  for name, t in iter do
    if t ~= 'directory' and name:sub(-5) == '.sock' and name:sub(1, 4) ~= 'cli-' then
      out[#out + 1] = dir .. '/' .. name
    end
  end
  return out
end

-- R4(b): the three default-socket glob shapes, one level deep.
local function glob_sockets()
  -- uid lookup, not $USER: plugin-action environments may strip it
  local passwd = (vim.uv or vim.loop).os_get_passwd()
  local user = (passwd and passwd.username)
    or getenv('USER') or getenv('LOGNAME') or ''
  local pats = {}
  local tmp = getenv('TMPDIR')
  if not tmp and (vim.uv or vim.loop).os_uname().sysname == 'Darwin' then
    -- plugin-action environments drop TMPDIR; the per-user temp dir where
    -- default sockets actually live is only reachable via confstr
    local ok, res = pcall(function()
      return vim.system({ 'getconf', 'DARWIN_USER_TEMP_DIR' }, { timeout = 1000 }):wait()
    end)
    if ok and res and res.code == 0 and res.stdout then
      local dir = res.stdout:gsub('%s+$', '')
      if dir ~= '' then tmp = dir end
    end
  end
  if tmp then
    pats[#pats + 1] = tmp:gsub('/+$', '') .. '/nvim.' .. user .. '/*/nvim.*.0'
  end
  pats[#pats + 1] = '/tmp/nvim.' .. user .. '/*/nvim.*.0'
  local xdg = getenv('XDG_RUNTIME_DIR')
  if xdg then
    pats[#pats + 1] = xdg:gsub('/+$', '') .. '/nvim.*.0'
  end
  local seen, out = {}, {}
  for _, pat in ipairs(pats) do
    local ok, matches = pcall(vim.fn.glob, pat, true, true)
    if ok then
      for _, m in ipairs(matches) do
        if not seen[m] then
          seen[m] = true
          out[#out + 1] = m
        end
      end
    end
  end
  return out
end

local function add_candidate(state, addr, origin)
  if state.cands[addr] then
    return state.cands[addr]
  end
  local c = {
    addr = addr,
    origin = origin,
    score = 0,
    reasons = {},
    excluded = false,
    longest = 0,
  }
  state.cands[addr] = c
  state.order[#state.order + 1] = addr
  return c
end

local function own_addrs()
  local own = {}
  local sn = vim.v.servername
  if sn and sn ~= '' then
    own[sn] = true
  end
  own[remote.cli_sock_path()] = true
  return own
end

local function record_probe(state, results, status)
  for addr, s in pairs(status) do
    local c = state.cands[addr]
    if c then
      c.status = s
      c.payload = results[addr]
      if s ~= 'ok' then
        c.excluded = true
        if s == 'wedged' then
          c.reasons[#c.reasons + 1] = 'unresponsive (accepted socket, no answer)'
        elseif s == 'dead' then
          c.reasons[#c.reasons + 1] = 'stale socket (connect failed)'
        elseif s == 'self' then
          c.reasons[#c.reasons + 1] = 'this CLI process'
        end
      end
    end
  end
end

-- R1-R3: probe registry keys in order; first answering socket wins outright.
local function fast_path(state, ctx, roots, target)
  local keys, seen = {}, {}
  local function add(k, why)
    if k and not seen[k] then
      seen[k] = true
      keys[#keys + 1] = { k = k, why = why }
    end
  end
  if ctx.workspace_id then
    add(key.ws_key(ctx.workspace_id), 'workspace id')
  end
  if ctx.worktree and type(ctx.worktree.checkout_path) == 'string' then
    local rp = norm_dir(ctx.worktree.checkout_path)
    if rp then
      add(key.root_key(rp), 'worktree checkout')
    end
  end
  for _, r in ipairs(roots) do
    local rp = norm_dir(r)
    if rp then
      add(key.root_key(rp), 'root')
    end
  end
  for _, e in ipairs(keys) do
    local sock = key.socket_path(e.k)
    if uv.fs_stat(sock) then
      local c = add_candidate(state, sock, 'registry')
      if not c.status then
        local results, status =
          remote.probe_all({ sock }, clamp(state, remote.PROBE_PER_CANDIDATE_MS, RESERVE_PROBE_MS), { target = target })
        record_probe(state, results, status)
      end
      if c.status == 'ok' then
        table.insert(c.reasons, 1, 'registry fast path (' .. e.why .. ')')
        return c
      end
    end
  end
  return nil
end

-- R4 + R5: union of registry and glob sockets, probed as one set.
local function probe_all_candidates(state, target)
  local own = own_addrs()
  for _, s in ipairs(registry_sockets()) do
    if not own[s] then
      add_candidate(state, s, 'registry')
    end
  end
  for _, s in ipairs(glob_sockets()) do
    if not own[s] then
      add_candidate(state, s, 'glob')
    end
  end
  local todo = {}
  for _, addr in ipairs(state.order) do
    if not state.cands[addr].status then
      todo[#todo + 1] = addr
    end
  end
  if #todo > 0 then
    local deadline =
      clamp(state, math.min(remote.PROBE_PER_CANDIDATE_MS * #todo, remote.PROBE_SET_MS), RESERVE_PROBE_MS)
    local results, status = remote.probe_all(todo, deadline, { target = target })
    record_probe(state, results, status)
  end
  -- Dedupe by probed pid: one instance can own several sockets. Registry
  -- origin wins so the +10 stays attached to the surviving candidate.
  local by_pid = {}
  for _, addr in ipairs(state.order) do
    local c = state.cands[addr]
    if c.status == 'ok' and c.payload and c.payload.pid then
      local prev = by_pid[c.payload.pid]
      if not prev then
        by_pid[c.payload.pid] = c
      else
        local keep, drop = prev, c
        if prev.origin ~= 'registry' and c.origin == 'registry' then
          keep, drop = c, prev
          by_pid[c.payload.pid] = c
        end
        drop.excluded = true
        drop.status = 'duplicate'
        drop.reasons[#drop.reasons + 1] = 'duplicate socket of ' .. keep.addr
      end
    end
  end
end

-- ----------------------------------------------------------------- R6 live

-- The full pane list is fetched rather than --workspace-filtered: confirming
-- a candidate lives in ANOTHER workspace requires panes outside ctx, and the
-- filtered form hard-errors when the workspace id itself is stale.
local function build_live_map(state, ctx)
  if not ctx.workspace_id then
    return nil
  end
  local bin = herdr_bin()
  if not bin then
    return nil
  end
  local res = herdr_json(state, { bin, 'pane', 'list' }, HERDR_CALL_MS, RESERVE_LIVEMAP_MS)
  if not res or type(res.panes) ~= 'table' then
    return nil
  end
  local out = run_cmd(state, { 'ps', '-A', '-o', 'pid=,ppid=' }, HERDR_CALL_MS, RESERVE_LIVEMAP_MS)
  if not out then
    return nil
  end
  local ppid = {}
  for pid, par in out:gmatch('(%d+)%s+(%d+)') do
    ppid[tonumber(pid)] = tonumber(par)
  end
  local panes = {}
  for _, p in ipairs(res.panes) do
    if #panes >= 24 or remaining_ms(state) <= RESERVE_LIVEMAP_MS then
      break
    end
    local pane = { pane_id = p.pane_id, workspace_id = p.workspace_id, tab_id = p.tab_id, pids = {} }
    local pi = herdr_json(state, { bin, 'pane', 'process-info', '--pane', p.pane_id }, HERDR_CALL_MS, RESERVE_LIVEMAP_MS)
    local info = pi and pi.process_info
    if info then
      if info.shell_pid then
        pane.pids[info.shell_pid] = true
      end
      for _, fp in ipairs(info.foreground_processes or {}) do
        if fp.pid then
          pane.pids[fp.pid] = true
        end
      end
    end
    panes[#panes + 1] = pane
  end
  state.live_map_used = true
  return { panes = panes, ppid = ppid }
end

-- A candidate's probed pid is the --embed child; the pane's foreground pid is
-- the TUI parent. Walk up the process tree until a pane claims an ancestor.
local function live_lookup(live, pid)
  local cur, depth = pid, 0
  while cur and cur > 1 and depth < 25 do
    for _, pane in ipairs(live.panes) do
      if pane.pids[cur] then
        return pane
      end
    end
    cur = live.ppid[cur]
    depth = depth + 1
  end
  return nil
end

-- ------------------------------------------------------------- R6+R7 score

local function score_candidate(state, c, ctx, target, target_git, live)
  local p = c.payload
  if not p or c.excluded then
    return
  end
  local score = 0
  local reasons = c.reasons
  -- R6: an nvim used purely as a terminal host is never a jump target.
  if p.term_only then
    c.excluded = true
    reasons[#reasons + 1] = 'excluded: only term:// buffers'
    return
  end
  if ctx.workspace_id then
    local pane = live and p.pid and live_lookup(live, p.pid) or nil
    if pane then
      c.live_pane = pane.pane_id
      c.live_ws = pane.workspace_id
      if pane.workspace_id == ctx.workspace_id then
        score = score + 200
        reasons[#reasons + 1] = '+200 live workspace match'
      else
        c.excluded = true
        reasons[#reasons + 1] = 'excluded: live map places it in ' .. tostring(pane.workspace_id)
        c.score = score
        return
      end
    elseif type(p.ws) == 'string' and p.ws ~= ctx.workspace_id then
      score = score - 150
      reasons[#reasons + 1] = '-150 env workspace mismatch (unconfirmed)'
    end
  end
  local longest = 0
  if target then
    if p.has then
      score = score + 100
      reasons[#reasons + 1] = '+100 target already open'
    end
    local best = 0
    if type(p.roots) == 'table' then
      for _, r in ipairs(p.roots) do
        local nd = norm_dir(r)
        if nd and is_ancestor(nd, target) and #nd > best then
          best = #nd
        end
      end
    end
    if best > 0 then
      score = score + 50
      reasons[#reasons + 1] = '+50 declared root ancestor'
      longest = best
    end
    if target_git and type(p.git) == 'string' and norm_dir(p.git) == target_git then
      score = score + 40
      reasons[#reasons + 1] = '+40 git root match'
    end
    local cw = norm_dir(p.cwd)
    if cw and is_ancestor(cw, target) then
      score = score + 20
      reasons[#reasons + 1] = '+20 cwd ancestor'
      if #cw > longest then
        longest = #cw
      end
    end
  end
  if c.origin == 'registry' then
    score = score + 10
    reasons[#reasons + 1] = '+10 registry entry'
  end
  c.score = score
  c.longest = longest
end

-- Eligible candidates (responsive, non-excluded) sorted best first.
local function eligible_sorted(state)
  local eligible = {}
  for _, addr in ipairs(state.order) do
    local c = state.cands[addr]
    if c.status == 'ok' and not c.excluded then
      eligible[#eligible + 1] = c
    end
  end
  table.sort(eligible, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    if a.longest ~= b.longest then
      return a.longest > b.longest
    end
    local as = tonumber(a.payload and a.payload.started)
    local bs = tonumber(b.payload and b.payload.started)
    if as and bs then
      if as ~= bs then
        return as > bs
      end
    elseif (as ~= nil) ~= (bs ~= nil) then
      -- A missing started (stock nvim) sorts last.
      return as ~= nil
    end
    return (a.payload.pid or math.huge) < (b.payload.pid or math.huge)
  end)
  return eligible
end

-- ----------------------------------------------------------------- output

local function candidate_json(state)
  local out = {}
  for _, addr in ipairs(state.order) do
    local c = state.cands[addr]
    local p = c.payload or {}
    out[#out + 1] = {
      addr = c.addr,
      pid = p.pid,
      score = c.score,
      ws = p.ws,
      cwd = p.cwd,
      wedged = c.status == 'wedged',
      excluded = c.excluded,
      status = c.status,
      reasons = c.reasons,
    }
  end
  return out
end

local function emit(state, code, human, err)
  state.code = code
  local dur = math.floor((uv.hrtime() - state.t0) / 1e6)
  if state.json then
    local w = state.winner
    local obj = {
      ok = code == 0,
      exit_code = code,
      target = state.target,
      line = state.line,
      col = state.col,
      winner = w and {
        addr = w.addr,
        pid = w.payload and w.payload.pid,
        score = w.score,
        reasons = w.reasons,
      } or nil,
      candidates = candidate_json(state),
      live_map_used = state.live_map_used,
      focused = state.focused,
      spawned = state.spawned,
      error = err,
      duration_ms = dur,
    }
    io.stdout:write(vim.json.encode(obj), '\n')
    -- Failures also go to stderr under --json: callers capture stdout for
    -- the machine-readable object, and an empty stderr leaves a toast or a
    -- log with nothing but an exit code.
    if err then
      io.stderr:write('openloc: ', err, '\n')
    end
  else
    if human and human ~= '' then
      io.stdout:write(human, '\n')
    end
    if err then
      io.stderr:write('openloc: ', err, '\n')
    end
  end
  return code
end

-- Only ever reached with --choose auto: >= 2 eligible candidates and a score
-- gap under the margin. Nothing is opened; callers render the choice.
local function emit_ambiguous(state, eligible, margin)
  state.code = EXIT.ambiguous
  local dur = math.floor((uv.hrtime() - state.t0) / 1e6)
  if state.json then
    local cands = {}
    for _, c in ipairs(eligible) do
      local p = c.payload or {}
      cands[#cands + 1] = {
        addr = c.addr,
        pid = p.pid,
        score = c.score,
        cwd = p.cwd,
        ws = p.ws,
        reasons = c.reasons,
      }
    end
    io.stdout:write(vim.json.encode({
      ok = false,
      exit_code = EXIT.ambiguous,
      reason = 'ambiguous',
      margin = margin,
      target = state.target,
      line = state.line,
      col = state.col,
      candidates = cands,
      duration_ms = dur,
    }), '\n')
  else
    for _, c in ipairs(eligible) do
      local p = c.payload or {}
      io.stderr:write(string.format(
        'openloc: ambiguous (margin %d): score=%-5d pid=%-8s ws=%-8s cwd=%s addr=%s\n',
        margin, c.score, tostring(p.pid or '-'), tostring(p.ws or '-'), tostring(p.cwd or '-'), c.addr
      ))
    end
  end
  return EXIT.ambiguous
end

-- ------------------------------------------------------------ R8, R9, R10

local function resolve_nvim()
  local p = getenv('OPENLOC_NVIM')
  if p then
    return p
  end
  return vim.v.progpath
end

-- R10: the tab id comes from `pane get` at focus time; the inherited env id
-- may be stale and a stale id makes `tab focus` a hard error. Any failure is
-- focused=false, never a failed open.
local function focus_winner(state, c, ack)
  local bin = herdr_bin()
  if not bin then
    return false
  end
  local pane_id = c.live_pane or (ack and ack.pane) or (c.payload and c.payload.pane)
  if type(pane_id) ~= 'string' or pane_id == '' then
    return false
  end
  local res = herdr_json(state, { bin, 'pane', 'get', pane_id }, HERDR_CALL_MS)
  local tab = res and res.pane and res.pane.tab_id
  if type(tab) ~= 'string' or tab == '' then
    return false
  end
  local _, okf = herdr_json(state, { bin, 'tab', 'focus', tab }, HERDR_CALL_MS)
  return okf
end

-- A fresh spawn takes this long to publish its socket; rapid follow-up
-- clicks inside the window join it instead of spawning another editor.
local SPAWN_LOCK_FRESH_MS = 10000
local SPAWN_JOIN_WAIT_MS = 4000

local function spawn_key(ctx, root)
  if ctx.workspace_id then
    return key.ws_key(ctx.workspace_id)
  end
  return key.root_key(norm_dir(root) or root)
end

local function spawn_lock_path(k)
  return key.registry_dir() .. '/spawn-' .. key.effective_key(k) .. '.lock'
end

-- Unique per attempt. Two spawners must never share a bind address: a
-- stealer racing a slow-booting first spawner on one path ends with
-- "--listen: address already in use" in the second editor.
local function spawn_sock_path(k)
  return key.socket_path(k .. '-s' .. uv.os_getpid())
end

-- Returns 'acquired' | 'fresh' | nil (unlockable dir). A stale lock is a
-- spawn that never came up; steal it.
local function take_spawn_lock(lock, sock)
  vim.fn.mkdir(key.registry_dir(), 'p')
  for attempt = 1, 2 do
    local fd = uv.fs_open(lock, 'wx', 384)
    if fd then
      uv.fs_write(fd, sock .. '\n' .. tostring(uv.os_getpid()) .. '\n')
      uv.fs_close(fd)
      return 'acquired'
    end
    local st = uv.fs_stat(lock)
    if not st then
      -- lost a race with a steal; retry once
    elseif (os.time() - st.mtime.sec) * 1000 < SPAWN_LOCK_FRESH_MS then
      return 'fresh'
    else
      os.remove(lock)
    end
    if attempt == 2 then
      return nil
    end
  end
end

-- A fresh lock names the socket a just-spawned editor will listen on. Poll
-- it and open there; joining beats spawning a second editor. On timeout
-- (editor never came up) the caller spawns anyway.
local function join_spawning_editor(state, lock, target, line, col)
  local f = io.open(lock, 'r')
  if not f then
    return false
  end
  local sock = f:read('*l')
  f:close()
  if type(sock) ~= 'string' or sock == '' then
    return false
  end
  local function try_open()
    if not uv.fs_stat(sock) then
      return nil
    end
    local ack, status = remote.open_in(sock, target, line, col, clamp(state, remote.OPEN_DEADLINE_MS, 0))
    if ack and ack.ok then
      state.winner = { addr = sock, pid = ack.pid, score = 0, reasons = { 'joined a spawning editor' } }
      return true
    end
    if status == 'wedged' then
      return false
    end
    return nil
  end
  local deadline = clamp(state, SPAWN_JOIN_WAIT_MS, RESERVE_OPEN_MS)
  local t0 = uv.hrtime()
  while (uv.hrtime() - t0) / 1e6 < deadline do
    local r = try_open()
    if r ~= nil then
      return r
    end
    vim.wait(150)
  end
  -- Last chance before the caller steals and double-spawns: the first
  -- editor often finishes booting right at the deadline.
  vim.wait(300)
  return try_open() == true
end

-- R9. Inside herdr: split a pane and run nvim with the local +call form
-- (the --remote +cmd form is unimplemented in nvim). The spawned editor
-- listens on the registry socket for this workspace or root, so follow-up
-- clicks and future elections find it deterministically. Outside herdr the
-- spawn is opt-in via OPENLOC_SPAWN=1 and $VISUAL/$EDITOR, with the portable
-- +N line form since the editor may not be vim at all (and no join logic:
-- the editor command is opaque).
local function spawn_fallback(state, ctx, target, line, col, spawn_mode, root)
  if spawn_mode == 'never' then
    return emit(state, EXIT.no_editor, nil, 'no running editor found (spawn disabled); target ' .. target)
  end
  line = line or 1
  col = col or 1
  if ctx.herdr_env then
    local bin = herdr_bin()
    if bin then
      local k = spawn_key(ctx, root or vim.fs.dirname(target))
      local sock = spawn_sock_path(k)
      local lock = spawn_lock_path(k)
      local got = take_spawn_lock(lock, sock)
      if got == 'fresh' then
        if join_spawning_editor(state, lock, target, line, col) then
          return emit(state, EXIT.ok,
            'opened ' .. target .. ' in a just-spawned editor ' .. state.winner.addr)
        end
        -- the spawner never came up inside the window; steal and spawn
        os.remove(lock)
        take_spawn_lock(lock, sock)
      end
      os.remove(sock)
      local args = { bin, 'pane', 'split', '--direction', 'right', '--focus' }
      if ctx.focused_pane_id then
        args[#args + 1] = '--pane'
        args[#args + 1] = ctx.focused_pane_id
      end
      args[#args + 1] = '--cwd'
      args[#args + 1] = root or vim.fs.dirname(target)
      local res = herdr_json(state, args, HERDR_CALL_MS)
      local new_pane = res and ((res.pane and res.pane.pane_id) or res.pane_id)
      if type(new_pane) == 'string' and new_pane ~= '' then
        local cmd = string.format(
          "%s --listen %s '+call cursor(%d,%d)' -- %s",
          vim.fn.shellescape(resolve_nvim()),
          vim.fn.shellescape(sock),
          line,
          col,
          vim.fn.shellescape(target)
        )
        if run_cmd(state, { bin, 'pane', 'run', new_pane, cmd }, HERDR_CALL_MS) then
          state.spawned = true
          return emit(state, EXIT.ok, 'spawned nvim in new pane ' .. new_pane .. ' for ' .. target)
        end
      end
      os.remove(lock)
    end
    return emit(state, EXIT.no_editor, nil, 'no running editor found and herdr spawn failed; target ' .. target)
  end
  if getenv('OPENLOC_SPAWN') == '1' then
    local ed = getenv('VISUAL') or getenv('EDITOR')
    if ed then
      -- $VISUAL/$EDITOR may carry arguments, so it goes through the shell
      -- unescaped. Detached fire-and-forget: waiting on an interactive
      -- editor would break the global wall-clock cap.
      local cmd = string.format('%s +%d -- %s', ed, line, vim.fn.shellescape(target))
      local handle = uv.spawn('/bin/sh', { args = { '-c', cmd }, detached = true }, function() end)
      if handle then
        handle:unref()
        state.spawned = true
        return emit(state, EXIT.ok, 'spawned ' .. ed .. ' for ' .. target)
      end
      return emit(state, EXIT.open_failed, nil, 'failed to spawn editor: ' .. cmd)
    end
  end
  return emit(state, EXIT.no_editor, nil, 'no running editor found; target ' .. target)
end

-- --------------------------------------------------------------- commands

local function cmd_open(state, argv, is_url)
  local flags, pos = parse_flags(argv, 2)
  if not flags then
    io.stderr:write('openloc: ', tostring(pos), '\n', USAGE)
    return EXIT.usage
  end
  state.json = flags.json or false
  local spawn_mode = flags.spawn or 'split'

  local spec, url
  if is_url then
    local u = pos[1] or getenv('HERDR_PLUGIN_CLICKED_URL')
    if not u then
      io.stderr:write('openloc: open-url needs a URL argument or HERDR_PLUGIN_CLICKED_URL\n')
      return EXIT.usage
    end
    local parsed, perr = parse_url(u)
    if not parsed then
      return emit(state, EXIT.unresolved, nil, perr)
    end
    if (flags.strict or getenv('OPENLOC_STRICT') == '1') and parsed.host ~= 'openloc.invalid' then
      return emit(state, EXIT.unresolved, nil, 'strict mode: host is not openloc.invalid: ' .. parsed.host)
    end
    if not parsed.params.p or parsed.params.p == '' then
      return emit(state, EXIT.unresolved, nil, 'url is missing the p parameter')
    end
    spec = parsed.params.p
    url = parsed
    flags.line = flags.line or tonumber(parsed.params.l)
    flags.col = flags.col or tonumber(parsed.params.c)
  else
    spec = pos[1]
    if not spec then
      io.stderr:write('openloc: open needs a path\n', USAGE)
      return EXIT.usage
    end
  end

  -- R0: stat oracle + confinement.
  if forbidden(spec) then
    return emit(state, EXIT.unresolved, nil, 'path contains control or invisible characters')
  end
  local ctx = build_ctx(flags, url)
  local roots = roots_in_order(ctx)
  local target, sline, scol, tried = resolve_target(spec, roots, is_url)
  if not target then
    return emit(state, EXIT.unresolved, nil,
      'not an existing regular file: ' .. spec .. ' (tried: ' .. table.concat(tried, ', ') .. ')')
  end
  state.target = target
  state.line = flags.line or sline
  state.col = flags.col or scol
  local root = confined(target, roots)
  if not root then
    return emit(state, EXIT.unresolved, nil,
      'confinement: ' .. target .. ' is outside every resolved root (set OPENLOC_ALLOW to permit)')
  end

  -- Forced target: no discovery, no election, just a liveness probe.
  local winner
  local target_git = norm_dir(vim.fs.root(target, '.git'))
  if flags.addr then
    local c = add_candidate(state, flags.addr, 'forced')
    local results, status =
      remote.probe_all({ flags.addr }, clamp(state, remote.PROBE_PER_CANDIDATE_MS, RESERVE_PROBE_MS), { target = target })
    record_probe(state, results, status)
    if c.status ~= 'ok' then
      local why = c.status == 'wedged'
        and 'accepted the socket but never answered'
        or 'has no editor listening (connect failed)'
      return emit(state, EXIT.open_failed, nil, '--addr ' .. flags.addr .. ' ' .. why)
    end
    c.reasons = { 'forced --addr' }
    winner = c
  else
    -- R1-R3 fast paths, then R4+R5, R6, R7. --choose auto needs the full
    -- candidate set to judge ambiguity, so the fast path is skipped there.
    local choose = flags.choose or 'never'
    if choose ~= 'auto' then
      winner = fast_path(state, ctx, roots, target)
      if winner then
        score_candidate(state, winner, ctx, target, target_git, nil)
        if winner.excluded then
          winner = nil
        end
      end
    end
    if not winner then
      probe_all_candidates(state, target)
      local live = build_live_map(state, ctx)
      for _, addr in ipairs(state.order) do
        score_candidate(state, state.cands[addr], ctx, target, target_git, live)
      end
      local eligible = eligible_sorted(state)
      if choose == 'auto' and #eligible >= 2 then
        local margin = tonumber(getenv('OPENLOC_PICK_MARGIN')) or DEFAULT_PICK_MARGIN
        if (eligible[1].score - eligible[2].score) < margin then
          return emit_ambiguous(state, eligible, margin)
        end
      end
      winner = eligible[1]
    end
  end

  if not winner then
    return spawn_fallback(state, ctx, target, state.line, state.col, spawn_mode, root)
  end
  state.winner = winner

  -- R8: no retry on a wedged open; the file may well have opened.
  if remaining_ms(state) <= 0 then
    return emit(state, EXIT.deadline, nil, 'global deadline exceeded before open')
  end
  local ack, status =
    remote.open_in(winner.addr, target, state.line, state.col, clamp(state, remote.OPEN_DEADLINE_MS, RESERVE_OPEN_MS))
  if status == 'wedged' then
    return emit(state, EXIT.deadline, nil, 'deadline exceeded: ' .. winner.addr .. ' accepted the socket but never answered')
  end
  if status == 'dead' or type(ack) ~= 'table' then
    return emit(state, EXIT.open_failed, nil, 'editor at ' .. winner.addr .. ' died before the open')
  end
  if ack.ok ~= true then
    return emit(state, EXIT.open_failed, nil, 'open failed in ' .. winner.addr .. ': ' .. tostring(ack.err))
  end

  -- R10.
  state.focused = focus_winner(state, winner, ack)
  local human = string.format(
    'opened %s:%d:%d pid %s %s score %d%s',
    ack.buf or target,
    ack.line or state.line or 1,
    ack.col or state.col or 1,
    tostring(ack.pid),
    winner.addr,
    winner.score,
    state.focused and ' (focused)' or ''
  )
  return emit(state, EXIT.ok, human)
end

local function cmd_list(state, argv)
  local flags = parse_flags(argv, 2)
  if not flags then
    io.stderr:write(USAGE)
    return EXIT.usage
  end
  state.json = flags.json or false
  local ctx = build_ctx({}, nil)
  probe_all_candidates(state, nil)
  local live = build_live_map(state, ctx)
  for _, addr in ipairs(state.order) do
    score_candidate(state, state.cands[addr], ctx, nil, nil, live)
  end
  if state.json then
    return emit(state, EXIT.ok)
  end
  if #state.order == 0 then
    io.stdout:write('no live editors found\n')
    return EXIT.ok
  end
  for _, addr in ipairs(state.order) do
    local c = state.cands[addr]
    local p = c.payload or {}
    io.stdout:write(string.format(
      '%-8s %-9s pid=%-8s ws=%-8s score=%-5d cwd=%s addr=%s%s\n',
      c.status or '?',
      c.origin,
      tostring(p.pid or '-'),
      tostring(p.ws or '-'),
      c.score,
      tostring(p.cwd or '-'),
      c.addr,
      #c.reasons > 0 and ('  [' .. table.concat(c.reasons, '; ') .. ']') or ''
    ))
  end
  return EXIT.ok
end

local function cmd_doctor(state)
  local out = {}
  local function line(status, msg)
    out[#out + 1] = string.format('%-4s %s', status, msg)
  end
  local src = debug.getinfo(1, 'S').source:gsub('^@', '')
  local cli_path = uv.fs_realpath(src) or src
  line(uv.fs_stat(cli_path) and 'ok' or 'FAIL', 'cli: ' .. cli_path)
  line('ok', 'nvim: ' .. vim.v.progpath .. ' (' .. tostring(vim.version()) .. ')')
  local on_path = vim.fn.exepath('nvim')
  line(on_path ~= '' and 'ok' or 'warn', 'nvim on PATH: ' .. (on_path ~= '' and on_path or 'NOT FOUND'))

  local dir = key.registry_dir()
  local st = uv.fs_stat(dir)
  if st then
    local mode = st.mode % 512 -- low 9 permission bits
    line(mode == 448 and 'ok' or 'warn',
      string.format('registry dir: %s (mode %o)', dir, mode))
  else
    line('warn', 'registry dir missing (no plugin-registered editor yet): ' .. dir)
  end
  local sample = key.socket_path(key.ws_key('w0000000'))
  line(#sample < key.MAX_SOCKET_PATH and 'ok' or 'FAIL',
    string.format('socket path length: %d of %d max (%s)', #sample, key.MAX_SOCKET_PATH, sample))

  local socks = registry_sockets()
  if #socks > 0 then
    local results, status = remote.probe_all(socks, clamp(state, remote.PROBE_SET_MS))
    for _, s in ipairs(socks) do
      local tag = status[s]
      local pid = results[s] and results[s].pid
      if tag == 'ok' then
        line('ok', 'registry socket live: ' .. s .. ' pid ' .. tostring(pid))
      elseif tag == 'wedged' then
        line('warn', 'registry socket wedged (editor at a blocking prompt?): ' .. s)
      else
        line('warn', 'registry socket stale: ' .. s)
      end
    end
  else
    line('ok', 'registry sockets: none')
  end
  if uv.fs_stat(dir) then
    for name, t in vim.fs.dir(dir) do
      if t ~= 'directory' and name:match('^cli%-%d+%.sock$') then
        local pid = tonumber(name:match('%d+'))
        local alive = pid and pcall(uv.kill, pid, 0) or false
        if not alive and (dir .. '/' .. name) ~= remote.cli_sock_path() then
          line('warn', 'leftover CLI callback socket: ' .. dir .. '/' .. name)
        end
      end
    end
  end

  local bin = herdr_bin()
  if bin then
    local v = run_cmd(state, { bin, '--version' }, HERDR_CALL_MS)
    line('ok', 'herdr: ' .. bin .. ' (' .. (v and v:gsub('%s+$', '') or 'version unknown') .. ')')
  else
    line('warn', 'herdr: not found (live workspace filter and pane spawn unavailable)')
  end
  io.stdout:write(table.concat(out, '\n'), '\n')
  return EXIT.ok
end

-- ------------------------------------------------------------------- main

function M.main(argv)
  argv = argv or {}
  local state = {
    t0 = uv.hrtime(),
    cands = {},
    order = {},
    live_map_used = false,
    focused = false,
    json = false,
  }
  local cmd = argv[1]
  local code
  local ok, err = pcall(function()
    if cmd == 'open' then
      code = cmd_open(state, argv, false)
    elseif cmd == 'open-url' then
      code = cmd_open(state, argv, true)
    elseif cmd == 'list' then
      code = cmd_list(state, argv)
    elseif cmd == 'doctor' then
      code = cmd_doctor(state)
    else
      io.stderr:write(USAGE)
      code = EXIT.usage
    end
  end)
  pcall(remote.close_callback_server)
  if not ok then
    io.stderr:write('openloc: internal error: ', tostring(err), '\n')
    code = EXIT.usage
  end
  io.stdout:flush()
  io.stderr:flush()
  return code or EXIT.usage
end

return M
