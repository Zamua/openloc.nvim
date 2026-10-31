-- One candidate editor: its lifecycle state and every output format (JSON
-- views, text rows).
--
-- c.state is a single enum:
--   unprobed   address known, no answer recorded yet
--   ok         answered the probe and is eligible
--   excluded   answered the probe, ruled out by scoring (reason recorded)
--   dead       connect failed
--   wedged     accepted the socket, never answered
--   self       this CLI process
--   duplicate  second socket of an editor already listed

local M = {}

function M.new(addr, origin)
  return {
    addr = addr,
    origin = origin,
    state = 'unprobed',
    score = 0,
    reasons = {},
    longest = 0,
  }
end

local UNUSABLE_REASON = {
  wedged = 'unresponsive (accepted socket, no answer)',
  dead = 'stale socket (connect failed)',
  self = 'this CLI process',
}

-- Record a probe outcome: status is ok | dead | wedged | self.
function M.probed(c, status, payload)
  c.state = status
  c.payload = payload
  if UNUSABLE_REASON[status] then
    c.reasons[#c.reasons + 1] = UNUSABLE_REASON[status]
  end
end

function M.exclude(c, reason)
  c.state = 'excluded'
  c.reasons[#c.reasons + 1] = reason
end

function M.mark_duplicate(c, keep)
  c.state = 'duplicate'
  c.reasons[#c.reasons + 1] = 'duplicate socket of ' .. keep.addr
end

function M.eligible(c)
  return c.state == 'ok'
end

-- Answered the probe, whether or not scoring then ruled it out.
function M.live(c)
  return c.state == 'ok' or c.state == 'excluded'
end

function M.probed_yet(c)
  return c.state ~= 'unprobed'
end

-- Liveness as output shows it: an excluded editor is still a live one.
local function status(c)
  if c.state == 'unprobed' then
    return nil
  end
  return c.state == 'excluded' and 'ok' or c.state
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
    wedged = c.state == 'wedged',
    excluded = c.state ~= 'ok' and c.state ~= 'unprobed',
    status = status(c),
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
  status = function(c) return ('%-8s'):format(status(c) or '?') end,
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
