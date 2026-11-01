-- Spawn fallback (R9): split a herdr pane running nvim, or launch
-- $VISUAL/$EDITOR detached, with a lock so rapid clicks share one editor.

local uv = vim.uv
local key = require('openloc.key')
local remote = require('openloc.remote')
local EXIT = require('openloc.cli.exit')
local budget = require('openloc.cli.budget')
local getenv = require('openloc.cli.env').getenv
local herdr = require('openloc.cli.herdr')
local norm_dir = require('openloc.cli.paths').norm_dir
local candidate = require('openloc.cli.candidate')
local report = require('openloc.cli.report')
local spawn_lock = require('openloc.cli.spawn_lock')
local wire = require('openloc.wire')

local HERDR_CALL_MS = budget.HERDR_CALL_MS
local RESERVE_OPEN_MS = budget.RESERVE_OPEN_MS

local M = {}

local function resolve_nvim()
  local p = getenv('OPENLOC_NVIM')
  if p then
    return p
  end
  return vim.v.progpath
end

-- How long a click waits for a spawning editor to answer before it
-- re-checks the lock.
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

-- Poll the socket a spawning editor will listen on and open there; joining
-- beats spawning a second editor. Returns 'ok', 'wedged' (it took the open
-- and never answered) or 'timeout' (it never came up).
local function join_spawning_editor(state, sock, target, line, col)
  local function try_open()
    if not uv.fs_stat(sock) then
      return nil
    end
    local ack, status = remote.open_in(sock, target, line, col, state.budget:clamp(remote.OPEN_DEADLINE_MS, 0))
    if ack and ack.ok then
      -- The ack proves it live and carries the probe's identity fields.
      local c = candidate.new(sock, 'spawning')
      candidate.probed(c, 'ok', wire.decode_probe({ pid = ack.pid, pane = ack.pane, tab = ack.tab }))
      c.reasons = { 'joined a spawning editor' }
      state.winner = c
      return 'ok'
    end
    if status == 'wedged' then
      return 'wedged'
    end
    return nil
  end
  local deadline = state.budget:clamp(SPAWN_JOIN_WAIT_MS, RESERVE_OPEN_MS)
  local t0 = uv.hrtime()
  while (uv.hrtime() - t0) / 1e6 < deadline do
    local r = try_open()
    if r ~= nil then
      return r
    end
    vim.wait(150)
  end
  -- Last chance before the caller re-checks the lock: the first editor
  -- often finishes booting right at the deadline.
  vim.wait(300)
  return try_open() or 'timeout'
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
    return report.emit(state, EXIT.no_editor, nil, 'no running editor found (spawn disabled); target ' .. target)
  end
  line = line or 1
  col = col or 1
  if ctx.herdr_env then
    local bin = herdr.bin()
    if bin then
      local k = spawn_key(ctx, root or vim.fs.dirname(target))
      local me = { sock = spawn_sock_path(k), pid = uv.os_getpid() }
      local lock = spawn_lock_path(k)
      local action, held = spawn_lock.step(lock, me, 'acquire')
      if action == 'join' then
        local joined = join_spawning_editor(state, held.owner.sock, target, line, col)
        if joined == 'ok' then
          return report.emit(state, EXIT.ok,
            'opened ' .. target .. ' in a just-spawned editor ' .. state.winner.addr)
        end
        if joined == 'wedged' then
          return report.emit(state, EXIT.deadline, nil,
            'deadline exceeded: ' .. held.owner.sock .. ' accepted the socket but never answered')
        end
        action, held = spawn_lock.step(lock, me, 'join_timed_out', held.owner)
      end
      if not action then
        return report.emit(state, EXIT.no_editor, nil, 'spawn lock unavailable (' .. held .. '); target ' .. target)
      end
      if action == 'give_up' then
        return report.emit(state, EXIT.no_editor, nil, 'another click is already spawning an editor; target ' .. target)
      end
      os.remove(me.sock)
      local args = { bin, 'pane', 'split', '--direction', 'right', '--focus' }
      if ctx.focused_pane_id then
        args[#args + 1] = '--pane'
        args[#args + 1] = ctx.focused_pane_id
      end
      args[#args + 1] = '--cwd'
      args[#args + 1] = root or vim.fs.dirname(target)
      local res = herdr.json(state, args, HERDR_CALL_MS)
      local new_pane = res and ((res.pane and res.pane.pane_id) or res.pane_id)
      if type(new_pane) == 'string' and new_pane ~= '' then
        local cmd = string.format(
          "%s --listen %s '+call cursor(%d,%d)' -- %s",
          vim.fn.shellescape(resolve_nvim()),
          vim.fn.shellescape(me.sock),
          line,
          col,
          vim.fn.shellescape(target)
        )
        if herdr.run(state, { bin, 'pane', 'run', new_pane, cmd }, HERDR_CALL_MS) then
          spawn_lock.step(lock, me, 'spawned')
          state.spawned = true
          return report.emit(state, EXIT.ok, 'spawned nvim in new pane ' .. new_pane .. ' for ' .. target)
        end
      end
      spawn_lock.step(lock, me, 'spawn_failed')
    end
    return report.emit(state, EXIT.no_editor, nil, 'no running editor found and herdr spawn failed; target ' .. target)
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
        return report.emit(state, EXIT.ok, 'spawned ' .. ed .. ' for ' .. target)
      end
      return report.emit(state, EXIT.open_failed, nil, 'failed to spawn editor: ' .. cmd)
    end
  end
  return report.emit(state, EXIT.no_editor, nil, 'no running editor found; target ' .. target)
end

M.spawn_fallback = spawn_fallback

return M
