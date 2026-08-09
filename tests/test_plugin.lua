-- Editor-side plugin tests: registry claim protocol (claim, no-steal,
-- stale-after-SIGKILL reclaim), metadata, unregister, and OpenlocJump.
-- Run: nvim -l tests/test_plugin.lua (or via tests/run.sh)

local uv = vim.uv

local this = debug.getinfo(1, 'S').source:sub(2)
local this_abs = uv.fs_realpath(this) or this
local H = dofile(vim.fs.dirname(this_abs) .. '/helpers.lua')
H.ensure_isolated('plugin', this_abs)

package.path = H.root .. '/lua/?.lua;' .. H.root .. '/lua/?/init.lua;' .. package.path
local key = require('openloc.key')
local openloc = require('openloc')
local ok = H.ok

local BASE = vim.env.OLTEST_BASE
if not BASE or BASE == '' then
  BASE = H.mkdir('/tmp/oltest-plugin-' .. uv.os_getpid())
end

-- Claims write real sockets into stdpath('cache'); refuse to run against a
-- non-isolated cache.
if not key.registry_dir():find('^/tmp/oltest%-') then
  io.stderr:write('test_plugin: refusing to run against a non-isolated cache: '
    .. key.registry_dir() .. '\n')
  os.exit(1)
end

local function nclaims()
  local n = 0
  for _ in pairs(openloc.claims()) do
    n = n + 1
  end
  return n
end

local function read_json(p)
  local f = io.open(p, 'r')
  if not f then
    return nil
  end
  local body = f:read('*a')
  f:close()
  local okd, obj = pcall(vim.json.decode, body, { luanil = { object = true } })
  return okd and obj or nil
end

local function connectable(sock)
  local okc, chan = pcall(vim.fn.sockconnect, 'pipe', sock, { rpc = true })
  if okc and chan and chan ~= 0 then
    pcall(vim.fn.chanclose, chan)
    return true
  end
  return false
end

-- ---------------------------------------------------------- registry claim

print('== registry claim ==')
local work1 = H.mkdir(BASE .. '/plug/proj1')
H.lines_file(work1 .. '/f.txt', 10)
vim.env.HERDR_WORKSPACE_ID = 'wtest'
openloc.setup({ roots = { work1 } })
openloc.register()

ok(type(vim.g.openloc_started) == 'number', 'claim: openloc_started set')
local claims = openloc.claims()
ok(claims['ws-wtest'] ~= nil, 'claim: workspace key claimed')
local rk = key.root_key(uv.fs_realpath(work1))
ok(claims[rk] ~= nil, 'claim: root key claimed')

local wsock = key.socket_path('ws-wtest')
ok(uv.fs_stat(wsock) ~= nil, 'claim: workspace socket on disk')
ok(uv.fs_stat(key.socket_path(rk)) ~= nil, 'claim: root socket on disk')
ok(connectable(wsock), 'claim: workspace socket connectable')

local dst = uv.fs_stat(key.registry_dir())
ok(dst ~= nil and dst.mode % 512 == 448, 'claim: registry dir mode 0700',
  dst and ('%o'):format(dst.mode % 512) or 'missing')

local meta = read_json(key.json_path('ws-wtest'))
ok(meta ~= nil, 'claim: metadata json written')
ok(meta and meta.pid == vim.fn.getpid(), 'claim: metadata pid is ours')
ok(meta and meta.key == 'ws-wtest' and meta.ws == 'wtest', 'claim: metadata key/ws')
ok(meta and type(meta.started) == 'number', 'claim: metadata started')
local rmeta = read_json(key.json_path(rk))
ok(rmeta and rmeta.root == uv.fs_realpath(work1), 'claim: root metadata carries the root')

local before = nclaims()
openloc.register()
ok(nclaims() == before, 'claim: register is idempotent', nclaims())

-- -------------------------------------------------------------- no stealing

print('== live claim is never stolen ==')
local claimer = BASE .. '/plug/claimer.lua'
H.write_file(claimer, ([[
package.path = %q .. '/lua/?.lua;' .. %q .. '/lua/?/init.lua;' .. package.path
local openloc = require('openloc')
openloc.setup({ roots = { %q } })
openloc.register()
local c = openloc.claims()
io.stdout:write(vim.json.encode({ ws = c['ws-wtest'] ~= nil, root = c[%q] ~= nil }))
io.stdout:flush()
]]):format(H.root, H.root, work1, rk))
local res = vim.system({ vim.v.progpath, '-l', claimer }, {
  env = { HERDR_WORKSPACE_ID = 'wtest' },
  text = true,
  timeout = 8000,
}):wait()
ok(res.code == 0, 'no-steal: second instance ran', res.code .. ' ' .. (res.stderr or ''))
local got = res.stdout and vim.json.decode(res.stdout) or nil
ok(got and got.ws == false, 'no-steal: live workspace key not claimed by a second instance')
ok(got and got.root == false, 'no-steal: live root key not claimed by a second instance')
local meta2 = read_json(key.json_path('ws-wtest'))
ok(meta2 and meta2.pid == vim.fn.getpid(), 'no-steal: metadata still ours')

-- ------------------------------------------------ stale reclaim after kill

print('== stale claim reclaimed after SIGKILL ==')
local holder = BASE .. '/plug/holder.lua'
H.write_file(holder, ([[
package.path = %q .. '/lua/?.lua;' .. %q .. '/lua/?/init.lua;' .. package.path
local openloc = require('openloc')
openloc.setup({ roots = {} })
openloc.register()
io.stdout:write('READY\n')
io.stdout:flush()
vim.wait(60000)
]]):format(H.root, H.root))
local ksock = key.socket_path('ws-wkill')
local hobj = H.spawn({ vim.v.progpath, '-l', holder }, { env = { HERDR_WORKSPACE_ID = 'wkill' } })
local up = vim.wait(5000, function()
  return uv.fs_stat(ksock) ~= nil
end, 10)
ok(up, 'reclaim: holder claimed the workspace key')
hobj:kill(9)
local refused = vim.wait(2000, function()
  return not connectable(ksock)
end, 50)
ok(refused, 'reclaim: killed holder no longer accepts connects')
ok(uv.fs_stat(ksock) ~= nil, 'reclaim: SIGKILL leaked the socket file (premise)')

vim.env.HERDR_WORKSPACE_ID = 'wkill'
openloc.register()
ok(openloc.claims()['ws-wkill'] ~= nil, 'reclaim: stale key reclaimed')
ok(connectable(ksock), 'reclaim: reclaimed socket connectable')
local kmeta = read_json(key.json_path('ws-wkill'))
ok(kmeta and kmeta.pid == vim.fn.getpid(), 'reclaim: metadata now ours')

-- --------------------------------------------------- plugin + OpenlocJump

print('== OpenlocJump ==')
dofile(H.root .. '/plugin/openloc.lua')
ok(vim.fn.exists(':OpenlocJump') == 2, 'plugin: OpenlocJump command defined')

local work3 = H.mkdir(BASE .. '/plug/proj3')
H.lines_file(work3 .. '/src/foo.rs', 10)
H.lines_file(work3 .. '/x.py', 5)
openloc.setup({ roots = { work3 } })

-- a scratch terminal buffer stands in for a running agent pane
local tbuf = vim.api.nvim_create_buf(false, true)
local tchan = vim.api.nvim_open_term(tbuf, {})
vim.api.nvim_chan_send(tchan, 'build failed\r\nsee src/foo.rs:3 and x.py:2\r\ndone\r\n')
vim.api.nvim_win_set_buf(0, tbuf)
local rendered = vim.wait(2000, function()
  local lines = vim.api.nvim_buf_get_lines(tbuf, 0, -1, false)
  return table.concat(lines, '\n'):find('x%.py:2') ~= nil
end, 10)
ok(rendered, 'jump: terminal buffer rendered')

local refs = openloc.jump({})
ok(#refs == 2, 'jump: both refs detected', vim.inspect(refs))
local q = vim.fn.getqflist({ items = 1, title = 1 })
ok(q.title == 'openloc', 'jump: quickfix titled openloc', q.title)
ok(#q.items == 2, 'jump: quickfix carries both refs', #q.items)
if #q.items == 2 then
  ok(vim.fn.bufname(q.items[1].bufnr):find('foo%.rs$') ~= nil and q.items[1].lnum == 3,
    'jump: first quickfix item is foo.rs:3')
  ok(vim.fn.bufname(q.items[2].bufnr):find('x%.py$') ~= nil and q.items[2].lnum == 2,
    'jump: second quickfix item is x.py:2')
end
ok(uv.fs_realpath(vim.api.nvim_buf_get_name(0)) == uv.fs_realpath(work3 .. '/src/foo.rs'),
  'jump: opened the first ref', vim.api.nvim_buf_get_name(0))
ok(vim.fn.line('.') == 3, 'jump: cursor on line 3', vim.fn.line('.'))

-- register variant via the ex command
vim.fn.setreg('a', 'trace: x.py:4 something')
vim.cmd('OpenlocJump! a')
q = vim.fn.getqflist({ items = 1, title = 1 })
ok(#q.items == 1 and q.items[1].lnum == 4, 'jump!: register scan fills quickfix')
ok(uv.fs_realpath(vim.api.nvim_buf_get_name(0)) == uv.fs_realpath(work3 .. '/x.py'),
  'jump!: opened the register ref')
ok(vim.fn.line('.') == 4, 'jump!: cursor on line 4', vim.fn.line('.'))

-- --------------------------------------------------------------- unregister

print('== unregister ==')
openloc.unregister()
ok(next(openloc.claims()) == nil, 'unregister: claims table empty')
ok(uv.fs_stat(wsock) == nil, 'unregister: workspace socket removed')
ok(uv.fs_stat(key.json_path('ws-wtest')) == nil, 'unregister: metadata removed')
ok(uv.fs_stat(ksock) == nil, 'unregister: reclaimed socket removed')

H.summary({ BASE ~= vim.env.OLTEST_BASE and BASE or nil })
