-- Deadline-bounded RPC to candidate nvim instances.
--
-- rpcrequest has no timeout and a wedged nvim (hit-enter, -- More --,
-- swapfile ATTENTION) accepts the socket and answers nothing. Every round
-- trip here is therefore notify + callback + vim.wait: the candidate is sent
-- nvim_exec_lua as a notification and delivers its answer by connecting back
-- to this process's callback socket. A failed connect means dead; a connect
-- with no answer inside the deadline means wedged.
--
-- Never use vim.uv.run here: it deadlocks against nvim's own loop in nvim -l.

local uv = vim.uv
local key = require('openloc.key')

local M = {}

M.PROBE_PER_CANDIDATE_MS = 300
M.PROBE_SET_MS = 1000
M.OPEN_DEADLINE_MS = 1000

M._sock = nil
M._results = {}
M._round = 0

-- Delivered payloads arrive as a second nvim_exec_lua, executed in THIS
-- process while vim.wait pumps events. Payloads are JSON strings so no
-- msgpack nil quirks leak through.
local COLLECT_SRC =
  "local t, p = ...; local c = rawget(_G, '__openloc_collect'); if c then c(t, p) end"

-- Runs inside a candidate. Must be safe on a stock nvim: pure vim.* API,
-- every step pcall-wrapped, no plugin assumed.
M.PROBE_SRC = [[
local cli_sock, token, target = ...
local function run()
  local ok, chan = pcall(vim.fn.sockconnect, 'pipe', cli_sock, { rpc = true })
  if not ok or not chan or chan == 0 then return end
  local payload = { pid = vim.fn.getpid() }
  pcall(function() payload.ws = vim.env.HERDR_WORKSPACE_ID end)
  pcall(function() payload.pane = vim.env.HERDR_PANE_ID end)
  pcall(function() payload.tab = vim.env.HERDR_TAB_ID end)
  pcall(function() payload.cwd = vim.fn.getcwd(-1, -1) end)
  pcall(function() payload.git = vim.fs.root(0, '.git') end)
  pcall(function()
    payload.has = false
    if target and target ~= '' then
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) then
          local name = vim.api.nvim_buf_get_name(b)
          if name ~= '' and (name == target or vim.uv.fs_realpath(name) == target) then
            payload.has = true
            break
          end
        end
      end
    end
  end)
  pcall(function()
    local o = package.loaded['openloc']
    if type(o) == 'table' and type(o.roots) == 'function' then payload.roots = o.roots() end
  end)
  pcall(function()
    local any, term = false, true
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) then
        any = true
        if vim.api.nvim_buf_get_name(b):sub(1, 7) ~= 'term://' then
          term = false
          break
        end
      end
    end
    payload.term_only = any and term
  end)
  pcall(function() payload.started = vim.g.openloc_started end)
  pcall(vim.fn.rpcnotify, chan, 'nvim_exec_lua',
    "local t, p = ...; local c = rawget(_G, '__openloc_collect'); if c then c(t, p) end",
    { token, vim.json.encode(payload) })
  pcall(vim.fn.chanclose, chan)
end
if vim.in_fast_event() then vim.schedule(run) else run() end
]]

-- Runs inside the winner. drop into the current window, reusing a window
-- already showing the target; the hide modifier keeps a modified current
-- buffer from E37ing under 'nohidden'. Clamp line and col rather than
-- error; zv unfolds, zz centers.
M.OPEN_SRC = [[
local cli_sock, token, target, line, col = ...
local function run()
  local ok, err = pcall(function()
    vim.cmd('hide drop ' .. vim.fn.fnameescape(target))
    local last = vim.api.nvim_buf_line_count(0)
    local l = math.min(math.max(line or 1, 1), last)
    local text = (vim.api.nvim_buf_get_lines(0, l - 1, l, false)[1]) or ''
    local c = math.min(math.max((col or 1) - 1, 0), math.max(#text - 1, 0))
    vim.api.nvim_win_set_cursor(0, { l, c })
    vim.cmd('normal! zvzz')
  end)
  local ack = {
    ok = ok,
    err = ok and nil or tostring(err),
    pid = vim.fn.getpid(),
    buf = vim.api.nvim_buf_get_name(0),
    line = vim.fn.line('.'),
    col = vim.fn.col('.'),
  }
  pcall(function() ack.pane = vim.env.HERDR_PANE_ID end)
  pcall(function() ack.tab = vim.env.HERDR_TAB_ID end)
  local ok2, chan = pcall(vim.fn.sockconnect, 'pipe', cli_sock, { rpc = true })
  if ok2 and chan and chan ~= 0 then
    pcall(vim.fn.rpcnotify, chan, 'nvim_exec_lua',
      "local t, p = ...; local c = rawget(_G, '__openloc_collect'); if c then c(t, p) end",
      { token, vim.json.encode(ack) })
    pcall(vim.fn.chanclose, chan)
  end
end
if vim.in_fast_event() then vim.schedule(run) else run() end
]]

function M.cli_sock_path()
  return key.registry_dir() .. '/cli-' .. uv.os_getpid() .. '.sock'
end

-- Callback server: serverstart on an explicit path inside nvim -l, after the
-- CLI's R-1 self-unpublish. An explicit serverstart does not re-add the
-- default socket, so the CLI stays invisible to candidate discovery.
function M.make_callback_server(sock_path)
  sock_path = sock_path or M.cli_sock_path()
  if M._sock == sock_path then
    return M._sock
  end
  local dir = vim.fs.dirname(sock_path)
  vim.fn.mkdir(dir, 'p', tonumber('700', 8))
  if uv.fs_stat(sock_path) then
    os.remove(sock_path)
  end
  local ok, err = pcall(vim.fn.serverstart, sock_path)
  if not ok then
    return nil, tostring(err)
  end
  if not uv.fs_stat(sock_path) then
    return nil, 'socket not created (path too long?): ' .. sock_path
  end
  M._sock = sock_path
  M._results = {}
  _G.__openloc_collect = function(token, body)
    local payload = body
    if type(body) == 'string' then
      local dok, decoded = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
      if dok then payload = decoded end
    end
    M._results[token] = payload
  end
  return M._sock
end

function M.close_callback_server()
  if M._sock then
    pcall(vim.fn.serverstop, M._sock)
    if uv.fs_stat(M._sock) then
      os.remove(M._sock)
    end
    M._sock = nil
  end
  _G.__openloc_collect = nil
  M._results = {}
end

local function ensure_server()
  if not M._sock then
    local sock, err = M.make_callback_server()
    if not sock then
      error('openloc: callback server failed: ' .. tostring(err))
    end
  end
end

-- probe_all(addrs, deadline_ms?, opts?) -> results, status
--   results: addr -> payload table (nil for dead/wedged/self)
--   status:  addr -> 'ok' | 'dead' | 'wedged' | 'self'
-- opts.target: realpath the candidate checks for an open buffer.
-- All probes are issued first, then one wait covers the set.
function M.probe_all(addrs, deadline_ms, opts)
  opts = opts or {}
  ensure_server()
  deadline_ms = deadline_ms
    or math.min(M.PROBE_PER_CANDIDATE_MS * math.max(#addrs, 1), M.PROBE_SET_MS)
  M._round = M._round + 1
  local round = M._round
  local self_pid = uv.os_getpid()
  local results, status, chans, tokens = {}, {}, {}, {}
  for _, addr in ipairs(addrs) do
    local token = round .. '|' .. addr
    tokens[addr] = token
    local ok, chan = pcall(vim.fn.sockconnect, 'pipe', addr, { rpc = true })
    if ok and chan and chan ~= 0 then
      chans[addr] = chan
      status[addr] = 'wedged'
      pcall(vim.fn.rpcnotify, chan, 'nvim_exec_lua', M.PROBE_SRC, { M._sock, token, opts.target })
    else
      status[addr] = 'dead'
    end
  end
  local function all_answered()
    for addr, s in pairs(status) do
      if s == 'wedged' and M._results[tokens[addr]] == nil then
        return false
      end
    end
    return true
  end
  if not all_answered() then
    vim.wait(deadline_ms, all_answered, 10)
  end
  for _, addr in ipairs(addrs) do
    -- channel held open until now so the notify is flushed before close
    if chans[addr] then
      pcall(vim.fn.chanclose, chans[addr])
    end
    local p = M._results[tokens[addr]]
    M._results[tokens[addr]] = nil
    if status[addr] == 'wedged' and p ~= nil then
      if type(p) == 'table' and p.pid == self_pid then
        status[addr] = 'self'
      else
        results[addr] = p
        status[addr] = 'ok'
      end
    end
  end
  return results, status
end

-- open_in(addr, target, line, col, deadline_ms?) -> ack|nil, status
--   status: 'ok' | 'dead' | 'wedged'
-- A nil ack with 'wedged' means the target accepted the socket and never
-- answered; the file may still have opened, so callers must not retry
-- another candidate.
function M.open_in(addr, target, line, col, deadline_ms)
  ensure_server()
  deadline_ms = deadline_ms or M.OPEN_DEADLINE_MS
  M._round = M._round + 1
  local token = 'open|' .. M._round .. '|' .. addr
  local ok, chan = pcall(vim.fn.sockconnect, 'pipe', addr, { rpc = true })
  if not ok or not chan or chan == 0 then
    return nil, 'dead'
  end
  pcall(vim.fn.rpcnotify, chan, 'nvim_exec_lua', M.OPEN_SRC,
    { M._sock, token, target, line or 1, col or 1 })
  vim.wait(deadline_ms, function() return M._results[token] ~= nil end, 10)
  pcall(vim.fn.chanclose, chan)
  local ack = M._results[token]
  M._results[token] = nil
  if ack == nil then
    return nil, 'wedged'
  end
  return ack, 'ok'
end

return M
