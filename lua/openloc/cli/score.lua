-- Candidate scoring (R6, R7) and the election order.

local candidate = require('openloc.cli.candidate')
local herdr = require('openloc.cli.herdr')
local paths = require('openloc.cli.paths')

local norm_dir, is_ancestor = paths.norm_dir, paths.is_ancestor

local M = {}

local function score_candidate(state, c, ctx, target, target_git, live)
  if not candidate.eligible(c) then
    return
  end
  local p = c.payload
  local score = 0
  local reasons = c.reasons
  -- R6: an nvim used purely as a terminal host is never a jump target.
  if p.term_only then
    candidate.exclude(c, 'excluded: only term:// buffers')
    return
  end
  -- Session scope outranks every workspace signal: a link clicked in one
  -- session must never open in another, and an id match across sessions is
  -- a coincidence of two independent counters rather than evidence.
  local mine = herdr.current_session(state, ctx)
  if mine then
    local theirs = herdr.session_of(herdr.build_proc_table(state), p.pid)
    if theirs and theirs ~= mine then
      c.session = theirs
      candidate.exclude(c, 'excluded: another herdr session (server pid ' .. tostring(theirs) .. ')')
      c.score = score
      return
    end
    c.session = theirs
  end
  if ctx.workspace_id then
    local pane = live and p.pid and herdr.live_lookup(live, p.pid) or nil
    if pane then
      c.live_pane = pane.pane_id
      c.live_ws = pane.workspace_id
      if pane.workspace_id == ctx.workspace_id then
        score = score + 200
        reasons[#reasons + 1] = '+200 live workspace match'
      else
        candidate.exclude(c, 'excluded: live map places it in ' .. tostring(pane.workspace_id))
        c.score = score
        return
      end
    elseif p.ws and p.ws ~= ctx.workspace_id then
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
    for _, r in ipairs(p.roots) do
      local nd = norm_dir(r)
      if nd and is_ancestor(nd, target) and #nd > best then
        best = #nd
      end
    end
    if best > 0 then
      score = score + 50
      reasons[#reasons + 1] = '+50 declared root ancestor'
      longest = best
    end
    if target_git and p.git and norm_dir(p.git) == target_git then
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
    if candidate.eligible(c) then
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
    local as, bs = a.payload.started, b.payload.started
    if as and bs then
      if as ~= bs then
        return as > bs
      end
    elseif (as ~= nil) ~= (bs ~= nil) then
      -- A missing started (stock nvim) sorts last.
      return as ~= nil
    end
    return a.payload.pid < b.payload.pid
  end)
  return eligible
end

M.score_candidate = score_candidate
M.eligible_sorted = eligible_sorted

return M
