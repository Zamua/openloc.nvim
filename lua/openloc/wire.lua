-- Wire contract between the CLI and candidate editors: the Lua that runs
-- inside a candidate, the callback entry it delivers to, and the typed
-- decoders for what comes back. Nothing outside this file reads a raw payload.
--
-- Candidate-side code must be safe on a stock nvim: pure vim.* API, every
-- step pcall-wrapped, no plugin assumed.

local M = {}

-- Global the CLI's callback server exposes; candidates deliver (token, json)
-- to it through nvim_exec_lua, executed in the CLI while vim.wait pumps
-- events. JSON strings keep msgpack nil quirks out of the payload.
M.COLLECT_GLOBAL = '__openloc_collect'

local COLLECT_SRC = ("local t, p = ...; local c = rawget(_G, '%s'); if c then c(t, p) end")
  :format(M.COLLECT_GLOBAL)

local function with_collect(src)
  local lit = string.format('%q', COLLECT_SRC)
  return (src:gsub('@COLLECT@', function()
    return lit
  end))
end

-- Probe payload fields. `roots` is a list of non-empty strings; every other
-- field is a scalar of the declared type. Only `pid` is required.
M.PROBE_FIELDS = {
  pid = 'number',
  ws = 'string',
  pane = 'string',
  tab = 'string',
  cwd = 'string',
  git = 'string',
  has = 'boolean',
  term_only = 'boolean',
  started = 'number',
}

-- Runs inside a candidate: builds the PROBE_FIELDS payload plus `roots`.
M.PROBE_SRC = with_collect([[
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
  pcall(vim.fn.rpcnotify, chan, 'nvim_exec_lua', @COLLECT@,
    { token, vim.json.encode(payload) })
  pcall(vim.fn.chanclose, chan)
end
if vim.in_fast_event() then vim.schedule(run) else run() end
]])

-- Runs inside the winner. drop into the current window, reusing a window
-- already showing the target; the hide modifier keeps a modified current
-- buffer from E37ing under 'nohidden'. Clamp line and col rather than
-- error; zv unfolds, zz centers.
M.OPEN_SRC = with_collect([[
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
    err = not ok and tostring(err) or nil,
    pid = vim.fn.getpid(),
    buf = vim.api.nvim_buf_get_name(0),
    line = vim.fn.line('.'),
    col = vim.fn.col('.'),
  }
  pcall(function() ack.pane = vim.env.HERDR_PANE_ID end)
  pcall(function() ack.tab = vim.env.HERDR_TAB_ID end)
  local ok2, chan = pcall(vim.fn.sockconnect, 'pipe', cli_sock, { rpc = true })
  if ok2 and chan and chan ~= 0 then
    pcall(vim.fn.rpcnotify, chan, 'nvim_exec_lua', @COLLECT@,
      { token, vim.json.encode(ack) })
    pcall(vim.fn.chanclose, chan)
  end
end
if vim.in_fast_event() then vim.schedule(run) else run() end
]])

-- JSON text from a candidate to the raw decoded value; non-JSON text passes
-- through unchanged so a decoder can reject it.
function M.decode_json(body)
  if type(body) ~= 'string' then
    return body
  end
  local ok, decoded = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
  if ok then
    return decoded
  end
  return body
end

local function scalars(raw, fields)
  local out = {}
  for name, want in pairs(fields) do
    local v = raw[name]
    if type(v) == want then
      out[name] = v
    end
  end
  return out
end

-- Typed probe payload, or nil when the candidate's answer is unusable.
-- Booleans are always present; roots is always a list.
function M.decode_probe(raw)
  if type(raw) ~= 'table' or type(raw.pid) ~= 'number' then
    return nil
  end
  local p = scalars(raw, M.PROBE_FIELDS)
  p.has = p.has == true
  p.term_only = p.term_only == true
  p.roots = {}
  if type(raw.roots) == 'table' then
    for _, r in ipairs(raw.roots) do
      if type(r) == 'string' and r ~= '' then
        p.roots[#p.roots + 1] = r
      end
    end
  end
  return p
end

local ACK_FIELDS = {
  pid = 'number',
  buf = 'string',
  line = 'number',
  col = 'number',
  pane = 'string',
  tab = 'string',
  err = 'string',
}

-- Typed open acknowledgement, or nil when unusable. `ok` is always a boolean.
function M.decode_ack(raw)
  if type(raw) ~= 'table' then
    return nil
  end
  local a = scalars(raw, ACK_FIELDS)
  a.ok = raw.ok == true
  return a
end

return M
