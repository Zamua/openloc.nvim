-- Candidate discovery: registry and glob sockets, the registry fast path
-- (R1-R3) and the probed union (R4, R5).

local uv = vim.uv
local key = require('openloc.key')
local remote = require('openloc.remote')
local budget = require('openloc.cli.budget')
local candidate = require('openloc.cli.candidate')
local getenv = require('openloc.cli.env').getenv
local norm_dir = require('openloc.cli.paths').norm_dir

local RESERVE_PROBE_MS = budget.RESERVE_PROBE_MS

local M = {}

local function registry_sockets()
  local dir = key.registry_dir()
  local out = {}
  if not uv.fs_stat(dir) then
    return out
  end
  local ok, iter = pcall(vim.fs.dir, dir)
  if not ok then
    return out
  end
  for name, t in iter do
    if t ~= 'directory' and name:sub(-5) == '.sock' and name:sub(1, 4) ~= 'cli-' then
      out[#out + 1] = dir .. '/' .. name
    end
  end
  return out
end

-- R4(b): the three default-socket glob shapes, one level deep.
local function glob_sockets()
  -- uid lookup, not $USER: plugin-action environments may strip it
  local passwd = (vim.uv or vim.loop).os_get_passwd()
  local user = (passwd and passwd.username)
    or getenv('USER') or getenv('LOGNAME') or ''
  local pats = {}
  local tmp = getenv('TMPDIR')
  if not tmp and (vim.uv or vim.loop).os_uname().sysname == 'Darwin' then
    -- plugin-action environments drop TMPDIR; the per-user temp dir where
    -- default sockets actually live is only reachable via confstr
    local ok, res = pcall(function()
      return vim.system({ 'getconf', 'DARWIN_USER_TEMP_DIR' }, { timeout = 1000 }):wait()
    end)
    if ok and res and res.code == 0 and res.stdout then
      local dir = res.stdout:gsub('%s+$', '')
      if dir ~= '' then tmp = dir end
    end
  end
  if tmp then
    pats[#pats + 1] = tmp:gsub('/+$', '') .. '/nvim.' .. user .. '/*/nvim.*.0'
  end
  pats[#pats + 1] = '/tmp/nvim.' .. user .. '/*/nvim.*.0'
  local xdg = getenv('XDG_RUNTIME_DIR')
  if xdg then
    pats[#pats + 1] = xdg:gsub('/+$', '') .. '/nvim.*.0'
  end
  local seen, out = {}, {}
  for _, pat in ipairs(pats) do
    local ok, matches = pcall(vim.fn.glob, pat, true, true)
    if ok then
      for _, m in ipairs(matches) do
        if not seen[m] then
          seen[m] = true
          out[#out + 1] = m
        end
      end
    end
  end
  return out
end

local function add_candidate(state, addr, origin)
  if state.cands[addr] then
    return state.cands[addr]
  end
  local c = candidate.new(addr, origin)
  state.cands[addr] = c
  state.order[#state.order + 1] = addr
  return c
end

local function own_addrs()
  local own = {}
  local sn = vim.v.servername
  if sn and sn ~= '' then
    own[sn] = true
  end
  own[remote.cli_sock_path()] = true
  return own
end

local function record_probe(state, results, status)
  for addr, s in pairs(status) do
    local c = state.cands[addr]
    if c then
      candidate.probed(c, s, results[addr])
    end
  end
end

-- R1-R3: probe registry keys in order; first answering socket wins outright.
local function fast_path(state, ctx, roots, target)
  local keys, seen = {}, {}
  local function add(k, why)
    if k and not seen[k] then
      seen[k] = true
      keys[#keys + 1] = { k = k, why = why }
    end
  end
  if ctx.workspace_id then
    add(key.ws_key(ctx.workspace_id), 'workspace id')
  end
  if ctx.worktree and type(ctx.worktree.checkout_path) == 'string' then
    local rp = norm_dir(ctx.worktree.checkout_path)
    if rp then
      add(key.root_key(rp), 'worktree checkout')
    end
  end
  for _, r in ipairs(roots) do
    local rp = norm_dir(r)
    if rp then
      add(key.root_key(rp), 'root')
    end
  end
  for _, e in ipairs(keys) do
    local sock = key.socket_path(e.k)
    if uv.fs_stat(sock) then
      local c = add_candidate(state, sock, 'registry')
      if not candidate.probed_yet(c) then
        local results, status =
          remote.probe_all({ sock }, state.budget:clamp(remote.PROBE_PER_CANDIDATE_MS, RESERVE_PROBE_MS), { target = target })
        record_probe(state, results, status)
      end
      if candidate.eligible(c) then
        table.insert(c.reasons, 1, 'registry fast path (' .. e.why .. ')')
        return c
      end
    end
  end
  return nil
end

-- R4 + R5: union of registry and glob sockets, probed as one set.
local function probe_all_candidates(state, target)
  local own = own_addrs()
  for _, s in ipairs(registry_sockets()) do
    if not own[s] then
      add_candidate(state, s, 'registry')
    end
  end
  for _, s in ipairs(glob_sockets()) do
    if not own[s] then
      add_candidate(state, s, 'glob')
    end
  end
  local todo = {}
  for _, addr in ipairs(state.order) do
    if not candidate.probed_yet(state.cands[addr]) then
      todo[#todo + 1] = addr
    end
  end
  if #todo > 0 then
    local deadline =
      state.budget:clamp(math.min(remote.PROBE_PER_CANDIDATE_MS * #todo, remote.PROBE_SET_MS), RESERVE_PROBE_MS)
    local results, status = remote.probe_all(todo, deadline, { target = target })
    record_probe(state, results, status)
  end
  -- Dedupe by probed pid: one instance can own several sockets. Registry
  -- origin wins so the +10 stays attached to the surviving candidate.
  local by_pid = {}
  for _, addr in ipairs(state.order) do
    local c = state.cands[addr]
    if candidate.live(c) then
      local prev = by_pid[c.payload.pid]
      if not prev then
        by_pid[c.payload.pid] = c
      else
        local keep, drop = prev, c
        if prev.origin ~= 'registry' and c.origin == 'registry' then
          keep, drop = c, prev
          by_pid[c.payload.pid] = c
        end
        candidate.mark_duplicate(drop, keep)
      end
    end
  end
end

M.registry_sockets = registry_sockets
M.add_candidate = add_candidate
M.record_probe = record_probe
M.fast_path = fast_path
M.probe_all_candidates = probe_all_candidates

return M
