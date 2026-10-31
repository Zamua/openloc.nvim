-- herdr adapter: binary lookup, CLI envelope, session ancestry, live pane map
-- and tab focus. Every failure collapses to nil/false so herdr stays optional.

local uv = vim.uv
local budget = require('openloc.cli.budget')
local getenv = require('openloc.cli.env').getenv

local HERDR_CALL_MS = budget.HERDR_CALL_MS
local RESERVE_LIVEMAP_MS = budget.RESERVE_LIVEMAP_MS
local RESERVE_OPEN_MS = budget.RESERVE_OPEN_MS

local M = {}

local function run_cmd(state, argv, ms, reserve)
  local budget = state.budget:clamp(ms, reserve)
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


-- herdr runs one server per named session and each server numbers its own
-- workspaces from scratch, so `w4` in one session and `w4` in another are
-- unrelated panes. Comparing HERDR_WORKSPACE_ID across sessions is therefore
-- meaningless, and `herdr pane list` only ever answers for one session, which
-- leaves every editor in a sibling session unresolvable by the live map.
--
-- A pane's processes descend from the server that owns them, so the first
-- herdr ancestor of a pid identifies its session without asking herdr
-- anything. Comparing those pids is what makes the workspace ids comparable.
local PROC_WALK_MAX = 40

-- The server's process name, which a renamed or wrapped install changes.
local function server_comm()
  local bin = herdr_bin()
  local base = bin and bin:match('([^/]+)$')
  if base and base ~= '' then
    return base
  end
  return 'herdr'
end

local function build_proc_table(state)
  if state.procs ~= nil then
    return state.procs or nil
  end
  local out = run_cmd(state, { 'ps', '-A', '-o', 'pid=,ppid=,ucomm=' }, HERDR_CALL_MS, RESERVE_OPEN_MS)
  if not out then
    -- false, not nil: a failed probe must not be retried on every candidate.
    state.procs = false
    return nil
  end
  local want = server_comm()
  local ppid, herdr = {}, {}
  for line in out:gmatch('[^\n]+') do
    local pid, par, comm = line:match('^%s*(%d+)%s+(%d+)%s+(.-)%s*$')
    if pid then
      pid, par = tonumber(pid), tonumber(par)
      ppid[pid] = par
      if comm == want or comm == 'herdr' then
        herdr[pid] = true
      end
    end
  end
  state.procs = { ppid = ppid, herdr = herdr }
  return state.procs
end

-- The session-owning server's pid, or nil when the pid is dead or lives
-- outside herdr entirely. nil means "unknown", never "same session".
local function session_of(procs, pid)
  if not procs or type(pid) ~= 'number' then
    return nil
  end
  local cur, depth = procs.ppid[pid] and pid or nil, 0
  while cur and cur > 1 and depth < PROC_WALK_MAX do
    if procs.herdr[cur] then
      return cur
    end
    cur = procs.ppid[cur]
    depth = depth + 1
  end
  return nil
end

local function current_session(state, ctx)
  if ctx and ctx.session then
    return ctx.session
  end
  if state.session == nil then
    state.session = session_of(build_proc_table(state), vim.fn.getpid()) or false
  end
  return state.session or nil
end

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
  local procs = build_proc_table(state)
  if not procs then
    return nil
  end
  local ppid = procs.ppid
  local panes = {}
  for _, p in ipairs(res.panes) do
    if #panes >= 24 or state.budget:remaining() <= RESERVE_LIVEMAP_MS then
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

M.bin = herdr_bin
M.run = run_cmd
M.json = herdr_json
M.session_of = session_of
M.current_session = current_session
M.build_proc_table = build_proc_table
M.build_live_map = build_live_map
M.live_lookup = live_lookup
M.focus_winner = focus_winner

return M
