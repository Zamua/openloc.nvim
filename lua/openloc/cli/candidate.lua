-- One candidate editor as the CLI reports it: the JSON views and the text
-- rows. Every output format is defined here and nowhere else.

local M = {}

function M.new(addr, origin)
  return {
    addr = addr,
    origin = origin,
    score = 0,
    reasons = {},
    excluded = false,
    longest = 0,
  }
end

-- Everything any view can show, read off the candidate once.
local function fields(c)
  local p = c.payload or {}
  return {
    addr = c.addr,
    pid = p.pid,
    score = c.score,
    ws = p.ws,
    cwd = p.cwd,
    session = c.session,
    wedged = c.status == 'wedged',
    excluded = c.excluded,
    status = c.status,
    reasons = c.reasons,
  }
end

-- JSON views: the election winner, a choice offered to the user, and the
-- full candidate list.
local VIEWS = {
  winner = { 'addr', 'pid', 'score', 'reasons' },
  choice = { 'addr', 'pid', 'score', 'cwd', 'ws', 'session', 'reasons' },
  full = { 'addr', 'pid', 'score', 'ws', 'cwd', 'session', 'wedged', 'excluded', 'status', 'reasons' },
}

function M.json(c, view)
  local all, out = fields(c), {}
  for _, name in ipairs(VIEWS[view]) do
    out[name] = all[name]
  end
  return out
end

local function dash(v)
  if v == nil or v == false then
    return '-'
  end
  return tostring(v)
end

local COLUMNS = {
  status = function(c) return ('%-8s'):format(c.status or '?') end,
  origin = function(c) return ('%-9s'):format(c.origin) end,
  pid = function(c) return ('pid=%-8s'):format(dash(fields(c).pid)) end,
  sess = function(c) return ('sess=%-8s'):format(dash(c.session)) end,
  ws = function(c) return ('ws=%-8s'):format(dash(fields(c).ws)) end,
  score = function(c) return ('score=%-5d'):format(c.score) end,
  cwd = function(c) return 'cwd=' .. dash(fields(c).cwd) end,
  addr = function(c) return 'addr=' .. c.addr end,
}

M.LIST_ROW = { 'status', 'origin', 'pid', 'sess', 'ws', 'score', 'cwd', 'addr' }
M.CHOICE_ROW = { 'score', 'pid', 'ws', 'cwd', 'addr' }

-- Space-joined text columns.
function M.row(c, columns)
  local out = {}
  for _, name in ipairs(columns) do
    out[#out + 1] = COLUMNS[name](c)
  end
  return table.concat(out, ' ')
end

return M
