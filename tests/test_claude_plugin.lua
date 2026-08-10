-- Pins the Claude Code plugin contract: manifests parse, the SessionStart
-- hook emits the documented additionalContext JSON, and the kill switch
-- silences it.
local uv = vim.uv
local this = debug.getinfo(1, 'S').source:sub(2)
local this_abs = uv.fs_realpath(this) or this
local H = dofile(vim.fs.dirname(this_abs) .. '/helpers.lua')
H.ensure_isolated('claude-plugin', this_abs)
local ok = H.ok
local root = H.root

local function jfile(rel)
  local f = assert(io.open(root .. '/' .. rel, 'r'))
  local body = f:read('*a')
  f:close()
  local okd, obj = pcall(vim.json.decode, body)
  return okd and obj or nil
end

print('== manifests ==')
local plug = jfile('claude/.claude-plugin/plugin.json')
ok(plug ~= nil and plug.name == 'openloc', 'plugin.json parses, name openloc')
local market = jfile('.claude-plugin/marketplace.json')
ok(market ~= nil and market.plugins[1].source == './claude',
  'marketplace.json parses, sources ./claude')
local hooks = jfile('claude/hooks/hooks.json')
ok(hooks ~= nil and hooks.hooks.SessionStart ~= nil, 'hooks.json wires SessionStart')
local cmd = hooks and hooks.hooks.SessionStart[1].hooks[1].command or ''
ok(cmd:find('session%-start%.sh') ~= nil, 'hook command names the script')

print('== hook contract ==')
local script = root .. '/claude/hooks/session-start.sh'
local r = vim.system({ 'bash', script }, { stdin = '{}', text = true, timeout = 5000 }):wait()
ok(r.code == 0, 'hook exits 0', r.code)
local out = vim.json.decode(r.stdout)
local ctx = out.hookSpecificOutput
ok(ctx and ctx.hookEventName == 'SessionStart', 'hookEventName is SessionStart')
ok(type(ctx.additionalContext) == 'string'
  and ctx.additionalContext:find('openloc%.invalid') ~= nil,
  'additionalContext carries the link instruction')

local r2 = vim.system({ 'bash', script }, {
  stdin = '{}', text = true, timeout = 5000, env = { OPENLOC_LINKS = 'off', PATH = vim.env.PATH },
}):wait()
ok(r2.code == 0 and (r2.stdout or '') == '', 'OPENLOC_LINKS=off silences the hook')

H.summary()
