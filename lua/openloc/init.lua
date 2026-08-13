-- Editor-side half of openloc: claims registry sockets so the CLI can route
-- an open straight to this instance, and performs the in-editor open.

local uv = vim.uv
local key = require('openloc.key')

local M = {}

local defaults = {
  register = true,
  -- nil: global cwd plus the current buffer's git root. Or a list of paths,
  -- or a function returning one.
  roots = nil,
}

local config = vim.deepcopy(defaults)

M._claims = {}

local function ensure_started()
  if not vim.g.openloc_started then
    vim.g.openloc_started = os.time()
  end
end

function M.setup(opts)
  config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
  ensure_started()
  return M
end

-- Declared roots, realpath'd and deduped. The CLI's probe reads this through
-- package.loaded for the declared-root scoring tier.
function M.roots()
  local list
  if type(config.roots) == 'function' then
    local ok, r = pcall(config.roots)
    list = (ok and type(r) == 'table') and r or {}
  elseif type(config.roots) == 'table' then
    list = config.roots
  else
    list = { vim.fn.getcwd(-1, -1) }
    local ok, git = pcall(vim.fs.root, 0, '.git')
    if ok and type(git) == 'string' then
      list[#list + 1] = git
    end
  end
  local out, seen = {}, {}
  for _, r in ipairs(list) do
    if type(r) == 'string' and r ~= '' then
      local rp = uv.fs_realpath(vim.fs.normalize(r))
      if rp and not seen[rp] then
        seen[rp] = true
        out[#out + 1] = rp
      end
    end
  end
  return out
end

-- --listen replaces the default stdpath('run') socket; add one back so the
-- instance stays visible to glob discovery.
local function ensure_default_server()
  local pid = vim.fn.getpid()
  local pat = '[/\\]nvim%.' .. pid .. '%.'
  for _, a in ipairs(vim.fn.serverlist()) do
    if a:find(pat) then
      return
    end
  end
  pcall(vim.fn.serverstart)
end

local function ensure_registry_dir()
  local dir = key.registry_dir()
  vim.fn.mkdir(dir, 'p', tonumber('700', 8))
  uv.fs_chmod(dir, tonumber('700', 8))
  return dir
end

-- Claim protocol: fs_stat -> sockconnect -> remove stale -> serverstart ->
-- fs_stat again (sun_path truncation makes serverstart lie). A successful
-- connect means a live owner (a wedged one still accepts), so never steal it.
-- Liveness here is a bare sockconnect, not remote.probe_all: the claim path
-- only needs owned-or-stale, and must not drag callback-server setup into
-- editor startup.
local function claim(k, meta)
  local existing = M._claims[k]
  if existing and uv.fs_stat(existing.sock) then
    return existing
  end
  local sock = key.socket_path(k)
  local json = key.json_path(k)
  if uv.fs_stat(sock) then
    local ok, chan = pcall(vim.fn.sockconnect, 'pipe', sock, { rpc = true })
    if ok and chan and chan ~= 0 then
      pcall(vim.fn.chanclose, chan)
      return nil
    end
    os.remove(sock)
  end
  local ok = pcall(vim.fn.serverstart, sock)
  if not ok or not uv.fs_stat(sock) then
    return nil
  end
  local f = io.open(json, 'w')
  if f then
    f:write(vim.json.encode({
      v = 1,
      pid = vim.fn.getpid(),
      key = k,
      addr = sock,
      root = meta.root,
      ws = meta.ws,
      started = vim.g.openloc_started,
    }))
    f:close()
  end
  M._claims[k] = { key = k, sock = sock, json = json, root = meta.root, ws = meta.ws }
  return M._claims[k]
end

-- Idempotent; DirChanged re-runs it to claim keys for the new roots while
-- keeping earlier claims alive.
function M.register()
  ensure_started()
  if config.register == false then
    return
  end
  ensure_default_server()
  ensure_registry_dir()
  local ws = vim.env.HERDR_WORKSPACE_ID
  if ws == '' then
    ws = nil
  end
  if ws then
    claim(key.ws_key(ws), { ws = ws })
  end
  for _, root in ipairs(M.roots()) do
    claim(key.root_key(root), { root = root, ws = ws })
  end
end

function M.unregister()
  for k, c in pairs(M._claims) do
    pcall(vim.fn.serverstop, c.sock)
    if uv.fs_stat(c.sock) then
      pcall(os.remove, c.sock)
    end
    pcall(os.remove, c.json)
    M._claims[k] = nil
  end
end

function M.claims()
  local out = {}
  for k, c in pairs(M._claims) do
    out[k] = { key = c.key, sock = c.sock, root = c.root, ws = c.ws }
  end
  return out
end

-- Open target in this instance: tab drop (never :edit, which E37s under
-- 'nohidden'), clamp line and col instead of erroring, zv unfolds, zz
-- centers. Never creates the target.
function M.open(path, line, col)
  line = tonumber(line)
  col = tonumber(col)
  local target = vim.fs.normalize(tostring(path))
  if target:sub(1, 1) ~= '/' then
    target = vim.fs.joinpath(vim.fn.getcwd(-1, -1), target)
  end
  local rp = uv.fs_realpath(target)
  local st = rp and uv.fs_stat(rp)
  if not st or st.type ~= 'file' then
    return { ok = false, err = 'not an existing regular file: ' .. target }
  end
  target = rp
  local ok, err = pcall(function()
    vim.cmd('tab drop ' .. vim.fn.fnameescape(target))
    local last = vim.api.nvim_buf_line_count(0)
    local l = math.min(math.max(line or 1, 1), last)
    local text = (vim.api.nvim_buf_get_lines(0, l - 1, l, false)[1]) or ''
    local c = math.min(math.max((col or 1) - 1, 0), math.max(#text - 1, 0))
    vim.api.nvim_win_set_cursor(0, { l, c })
    vim.cmd('normal! zvzz')
  end)
  return {
    ok = ok,
    -- not the `ok and nil or x` form: `ok and nil` falls through to x
    err = not ok and tostring(err) or nil,
    pid = vim.fn.getpid(),
    buf = vim.api.nvim_buf_get_name(0),
    line = vim.fn.line('.'),
    col = vim.fn.col('.'),
    pane = vim.env.HERDR_PANE_ID,
    tab = vim.env.HERDR_TAB_ID,
  }
end

-- RPC-friendly variant: a JSON string survives msgpack round trips without
-- nil-field surprises.
function M.open_json(path, line, col)
  return vim.json.encode(M.open(path, line, col))
end

return M
