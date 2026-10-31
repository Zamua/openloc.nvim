-- Target resolution: the click-time context, the ordered base directories and
-- the stat oracle (R0).

local uv = vim.uv
local paths = require('openloc.cli.paths')
local getenv = require('openloc.cli.env').getenv
local split_spec = require('openloc.cli.args').split_spec

local is_file, norm_dir, is_ancestor = paths.is_file, paths.norm_dir, paths.is_ancestor

local M = {}

local function build_ctx(flags, url)
  local ctx = {}
  local raw = getenv('HERDR_PLUGIN_CONTEXT_JSON')
  local plug = {}
  if raw then
    local ok, decoded = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
    if ok and type(decoded) == 'table' then
      plug = decoded
    end
  end
  local url_ws = url and url.params.ws
  ctx.workspace_id = flags.ws or url_ws or plug.workspace_id or getenv('HERDR_WORKSPACE_ID')
  ctx.session = tonumber(flags.session) or flags.session
  ctx.workspace_cwd = plug.workspace_cwd
  ctx.focused_pane_cwd = plug.focused_pane_cwd
  ctx.focused_pane_id = plug.focused_pane_id or getenv('HERDR_PANE_ID')
  if type(plug.worktree) == 'table' then
    ctx.worktree = plug.worktree
  end
  ctx.base = flags.cwd or (url and url.params.cwd)
  -- Pane-inherited HERDR_* vars are absent in a plugin action or link
  -- handler, which receives only HERDR_PLUGIN_*; both mean herdr is present.
  ctx.herdr_env = (getenv('HERDR_ENV') or getenv('HERDR_PANE_ID') or getenv('HERDR_WORKSPACE_ID')
    or getenv('HERDR_PLUGIN_CONTEXT_JSON') or getenv('HERDR_PLUGIN_ROOT')) ~= nil
  return ctx
end

local function roots_in_order(ctx)
  local roots = {}
  local function add(p)
    if type(p) == 'string' and p ~= '' then
      roots[#roots + 1] = p
    end
  end
  add(ctx.worktree and ctx.worktree.checkout_path)
  add(ctx.workspace_cwd)
  add(ctx.focused_pane_cwd)
  add(ctx.base)
  add(getenv('PWD') or uv.cwd())
  return roots
end

-- Resolve raw against the bases, first hit wins. Absolute paths stand alone.
local function resolve_one(raw, roots, tried)
  local p = raw
  if p:sub(1, 1) == '~' then
    p = vim.fs.normalize(p)
  end
  if p:sub(1, 1) == '/' then
    tried[#tried + 1] = p
    if is_file(p) then
      return uv.fs_realpath(p) or p
    end
    return nil
  end
  for _, base in ipairs(roots) do
    local joined = base:gsub('/+$', '') .. '/' .. p
    tried[#tried + 1] = joined
    if is_file(joined) then
      return uv.fs_realpath(joined) or joined
    end
  end
  return nil
end

-- R0. Returns target, line, col, tried. The suffix parse is attempted, and
-- the raw spelling is retried whenever the other form fails to resolve, so a
-- file literally named 'a:3' still opens.
local function resolve_target(spec, roots, is_url)
  local tried = {}
  local p, l, c = split_spec(spec)
  if is_url then
    local t = resolve_one(spec, roots, tried)
    if t then
      return t, nil, nil, tried
    end
    if p ~= spec then
      t = resolve_one(p, roots, tried)
      if t then
        return t, l, c, tried
      end
    end
    return nil, nil, nil, tried
  end
  local t = resolve_one(p, roots, tried)
  if t then
    return t, l, c, tried
  end
  if p ~= spec then
    t = resolve_one(spec, roots, tried)
    if t then
      return t, nil, nil, tried
    end
  end
  return nil, nil, nil, tried
end

-- The first resolved root that contains target, nil when none do. Supplies
-- the spawn cwd, so a spawned editor lands on the project rather than on the
-- target's parent directory.
local function containing_root(target, roots)
  for _, r in ipairs(roots) do
    local nd = norm_dir(r)
    if nd and is_ancestor(nd, target) then
      return nd
    end
  end
  return nil
end

M.build_ctx = build_ctx
M.roots_in_order = roots_in_order
M.resolve_target = resolve_target
M.containing_root = containing_root

return M
