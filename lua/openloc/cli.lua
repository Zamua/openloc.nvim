-- CLI router: open, open-url, list, doctor. Runs under `nvim -l` (no plugin
-- runtimepath, no init.lua); the entry script performs the R-1 self-unpublish
-- before this file loads. Implements R0 (stat oracle), R1-R3
-- (registry fast paths), R4 (candidate union), R5 (deadline-bounded probes),
-- R6 (session scope + live workspace filter), R7 (scoring), R8 (open),
-- R9 (spawn fallback), R10 (focus). No step may block past the global
-- wall-clock cap.

-- Under nvim -l require() cannot see this repo; resolve it from this file.
if not pcall(require, 'openloc.key') then
  local src = debug.getinfo(1, 'S').source:gsub('^@', '')
  local dir = vim.fs.dirname((vim.uv or vim.loop).fs_realpath(src) or src)
  local lua_root = vim.fs.dirname(dir)
  package.path = lua_root .. '/?.lua;' .. lua_root .. '/?/init.lua;' .. package.path
end

local remote = require('openloc.remote')
local EXIT = require('openloc.cli.exit')
local args = require('openloc.cli.args')
local budget = require('openloc.cli.budget')
local candidate = require('openloc.cli.candidate')
local discovery = require('openloc.cli.discovery')
local doctor = require('openloc.cli.doctor')
local getenv = require('openloc.cli.env').getenv
local herdr = require('openloc.cli.herdr')
local paths = require('openloc.cli.paths')
local report = require('openloc.cli.report')
local resolve = require('openloc.cli.resolve')
local score = require('openloc.cli.score')
local spawn = require('openloc.cli.spawn')

local RESERVE_PROBE_MS = budget.RESERVE_PROBE_MS
local RESERVE_OPEN_MS = budget.RESERVE_OPEN_MS

local M = {}

local DEFAULT_PICK_MARGIN = 75

local function cmd_open(state, argv, is_url)
  local flags, pos = args.parse_flags(argv, 2)
  if not flags then
    io.stderr:write('openloc: ', tostring(pos), '\n', args.USAGE)
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
    local parsed, perr = args.parse_url(u)
    if not parsed then
      return report.emit(state, EXIT.unresolved, nil, perr)
    end
    if (flags.strict or getenv('OPENLOC_STRICT') == '1') and parsed.host ~= 'openloc.invalid' then
      return report.emit(state, EXIT.unresolved, nil, 'strict mode: host is not openloc.invalid: ' .. parsed.host)
    end
    if not parsed.params.p or parsed.params.p == '' then
      return report.emit(state, EXIT.unresolved, nil, 'url is missing the p parameter')
    end
    spec = parsed.params.p
    url = parsed
    flags.line = flags.line or tonumber(parsed.params.l)
    flags.col = flags.col or tonumber(parsed.params.c)
  else
    spec = pos[1]
    if not spec then
      io.stderr:write('openloc: open needs a path\n', args.USAGE)
      return EXIT.usage
    end
  end

  -- R0: stat oracle.
  if args.forbidden(spec) then
    return report.emit(state, EXIT.unresolved, nil, 'path contains control or invisible characters')
  end
  local ctx = resolve.build_ctx(flags, url)
  local roots = resolve.roots_in_order(ctx)
  local target, sline, scol, tried = resolve.resolve_target(spec, roots, is_url)
  if not target then
    return report.emit(state, EXIT.unresolved, nil,
      'not an existing regular file: ' .. spec .. ' (tried: ' .. table.concat(tried, ', ') .. ')')
  end
  state.target = target
  state.line = flags.line or sline
  state.col = flags.col or scol
  local root = resolve.containing_root(target, roots)

  -- Forced target: no discovery, no election, just a liveness probe.
  local winner
  local target_git = paths.norm_dir(vim.fs.root(target, '.git'))
  if flags.addr then
    local c = discovery.add_candidate(state, flags.addr, 'forced')
    local results, status =
      remote.probe_all({ flags.addr }, state.budget:clamp(remote.PROBE_PER_CANDIDATE_MS, RESERVE_PROBE_MS), { target = target })
    discovery.record_probe(state, results, status)
    if not candidate.eligible(c) then
      local why = c.state == 'wedged'
        and 'accepted the socket but never answered'
        or 'has no editor listening (connect failed)'
      return report.emit(state, EXIT.open_failed, nil, '--addr ' .. flags.addr .. ' ' .. why)
    end
    c.reasons = { 'forced --addr' }
    winner = c
  else
    -- R1-R3 fast paths, then R4+R5, R6, R7. --choose auto needs the full
    -- candidate set to judge ambiguity, so the fast path is skipped there.
    local choose = flags.choose or 'never'
    if choose ~= 'auto' then
      winner = discovery.fast_path(state, ctx, roots, target)
      if winner then
        score.score_candidate(state, winner, ctx, target, target_git, nil)
        if not candidate.eligible(winner) then
          winner = nil
        end
      end
    end
    if not winner then
      discovery.probe_all_candidates(state, target)
      local live = herdr.build_live_map(state, ctx)
      for _, addr in ipairs(state.order) do
        score.score_candidate(state, state.cands[addr], ctx, target, target_git, live)
      end
      local eligible = score.eligible_sorted(state)
      if choose == 'auto' and #eligible >= 2 then
        local margin = tonumber(getenv('OPENLOC_PICK_MARGIN')) or DEFAULT_PICK_MARGIN
        if (eligible[1].score - eligible[2].score) < margin then
          return report.emit_ambiguous(state, eligible, margin)
        end
      end
      winner = eligible[1]
    end
  end

  if not winner then
    return spawn.spawn_fallback(state, ctx, target, state.line, state.col, spawn_mode, root)
  end
  state.winner = winner

  -- R8: no retry on a wedged open; the file may well have opened.
  if state.budget:remaining() <= 0 then
    return report.emit(state, EXIT.deadline, nil, 'global deadline exceeded before open')
  end
  local ack, status =
    remote.open_in(winner.addr, target, state.line, state.col, state.budget:clamp(remote.OPEN_DEADLINE_MS, RESERVE_OPEN_MS))
  if status == 'wedged' then
    return report.emit(state, EXIT.deadline, nil, 'deadline exceeded: ' .. winner.addr .. ' accepted the socket but never answered')
  end
  if status == 'dead' then
    return report.emit(state, EXIT.open_failed, nil, 'editor at ' .. winner.addr .. ' died before the open')
  end
  if ack.ok ~= true then
    return report.emit(state, EXIT.open_failed, nil, 'open failed in ' .. winner.addr .. ': ' .. tostring(ack.err))
  end

  -- R10.
  state.focused = herdr.focus_winner(state, winner, ack)
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
  return report.emit(state, EXIT.ok, human)
end

local function cmd_list(state, argv)
  local flags = args.parse_flags(argv, 2)
  if not flags then
    io.stderr:write(args.USAGE)
    return EXIT.usage
  end
  state.json = flags.json or false
  local ctx = resolve.build_ctx({}, nil)
  discovery.probe_all_candidates(state, nil)
  local live = herdr.build_live_map(state, ctx)
  for _, addr in ipairs(state.order) do
    score.score_candidate(state, state.cands[addr], ctx, nil, nil, live)
  end
  if state.json then
    return report.emit(state, EXIT.ok)
  end
  report.list_rows(state)
  return EXIT.ok
end

function M.main(argv)
  argv = argv or {}
  local state = {
    budget = budget.new(),
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
      code = doctor.run(state)
    else
      io.stderr:write(args.USAGE)
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
