-- Result output: the --json object, human lines and the ambiguous report.

local EXIT = require('openloc.cli.exit')

local M = {}

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
      session = c.session,
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
  local dur = state.budget:elapsed_ms()
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
      session = state.session or nil,
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
  local dur = state.budget:elapsed_ms()
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
        session = c.session,
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

M.emit = emit
M.emit_ambiguous = emit_ambiguous

return M
