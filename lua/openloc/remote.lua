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
local wire = require('openloc.wire')

local M = {}

M.PROBE_PER_CANDIDATE_MS = 300
M.PROBE_SET_MS = 1000
M.OPEN_DEADLINE_MS = 1000

M._sock = nil
M._results = {}
M._round = 0

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
  _G[wire.COLLECT_GLOBAL] = function(token, body)
    M._results[token] = wire.decode_json(body)
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
  _G[wire.COLLECT_GLOBAL] = nil
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
      pcall(vim.fn.rpcnotify, chan, 'nvim_exec_lua', wire.PROBE_SRC, { M._sock, token, opts.target })
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
    local raw = M._results[tokens[addr]]
    M._results[tokens[addr]] = nil
    -- An answer that decodes to nothing stays 'wedged': reachable, unusable.
    local p = wire.decode_probe(raw)
    if status[addr] == 'wedged' and p ~= nil then
      if p.pid == self_pid then
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
--   status: 'ok' | 'dead' | 'wedged'; 'dead' also covers an unusable answer
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
  pcall(vim.fn.rpcnotify, chan, 'nvim_exec_lua', wire.OPEN_SRC,
    { M._sock, token, target, line or 1, col or 1 })
  vim.wait(deadline_ms, function() return M._results[token] ~= nil end, 10)
  pcall(vim.fn.chanclose, chan)
  local raw = M._results[token]
  M._results[token] = nil
  if raw == nil then
    return nil, 'wedged'
  end
  local ack = wire.decode_ack(raw)
  if ack == nil then
    return nil, 'dead'
  end
  return ack, 'ok'
end

return M
