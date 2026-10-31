-- Foundation tests: key derivation and the deadline-bounded RPC layer.
-- Run from the repo root: nvim -l tests/test_foundation.lua

local uv = vim.uv

local this = debug.getinfo(1, 'S').source:sub(2)
local this_abs = uv.fs_realpath(this) or this
local H = dofile(vim.fs.dirname(this_abs) .. '/helpers.lua')
H.ensure_isolated('foundation', this_abs)

package.path = table.concat({
  H.root .. '/lua/?.lua',
  H.root .. '/lua/?/init.lua',
  package.path,
}, ';')

local key = require('openloc.key')
local remote = require('openloc.remote')
local wire = require('openloc.wire')
local ok = H.ok

local BASE = vim.env.OLTEST_BASE
if not BASE or BASE == '' then
  BASE = H.mkdir('/tmp/oltest-foundation-' .. uv.os_getpid())
end

-- ---------------------------------------------------------------- key.lua

print('== key ==')
ok(key.sanitize('w31') == 'w31', 'key: sanitize passthrough')
ok(key.sanitize('a b/c:d') == 'a-b-c-d', 'key: sanitize replaces unsafe chars')
ok(key.sanitize('A_Z-9') == 'A_Z-9', 'key: sanitize keeps [%w-_]')
ok(key.ws_key('w31') == 'ws-w31', 'key: ws_key shape')
local rk = key.root_key('/x')
ok(#rk == 14 and rk:match('^r%-%x+$') ~= nil, 'key: root_key format')
ok(key.root_key('/a') ~= key.root_key('/b'), 'key: distinct roots distinct keys')
ok(key.root_key('/a') == key.root_key('/a'), 'key: deterministic')

local short_path = key.socket_path('ws-w31')
ok(short_path == key.registry_dir() .. '/ws-w31.sock', 'key: short key kept verbatim')
ok(#short_path < key.MAX_SOCKET_PATH, 'key: short socket path under limit')

local long_id = string.rep('x', 200)
local eff = key.effective_key(key.ws_key(long_id))
ok(eff:match('^ws%-%x%x%x%x%x%x%x%x%x%x%x%x$') ~= nil, 'key: long key collapses to prefix+hash')
ok(#key.socket_path(key.ws_key(long_id)) < key.MAX_SOCKET_PATH, 'key: hashed socket path under limit')
ok(key.effective_key(key.ws_key(long_id)) == eff, 'key: hashed form deterministic')

-- the worst-case bound the diagnostics report really bounds every generated path
local worst = key.worst_socket_path_len()
for name, k in pairs({
  ws = key.ws_key('w1'),
  root = key.root_key('/some/root'),
  long_ws = key.ws_key(long_id),
  spawn = key.ws_key(long_id) .. '-s12345',
}) do
  ok(#key.socket_path(k) <= worst, 'key: ' .. name .. ' socket path within the worst-case bound',
    #key.socket_path(k) .. ' > ' .. worst)
end

-- ------------------------------------------------------------- remote.lua

print('== remote ==')

-- R-1: nvim -l publishes its own default socket; serverstop retracts it
local before = vim.v.servername
if before ~= '' then
  ok(uv.fs_stat(before) ~= nil, 'remote: nvim -l default socket exists (premise of R-1)')
  pcall(vim.fn.serverstop, before)
  ok(uv.fs_stat(before) == nil, 'remote: R-1 serverstop removes the default socket')
  ok(#vim.fn.serverlist() == 0, 'remote: serverlist empty after R-1')
else
  print('SKIP R-1 premise: this nvim -l has no default server')
end

-- callback server on an explicit path; the default must not come back
local cli_sock, cerr = remote.make_callback_server()
ok(cli_sock ~= nil, 'remote: callback server started', cerr)
ok(cli_sock and uv.fs_stat(cli_sock) ~= nil, 'remote: callback socket exists on disk')
local sl = vim.fn.serverlist()
ok(#sl == 1 and sl[1] == cli_sock,
  'remote: serverlist is exactly the CLI sock (default not re-added)', vim.inspect(sl))
local cok, cchan = pcall(vim.fn.sockconnect, 'pipe', cli_sock, { rpc = true })
ok(cok and cchan ~= 0, 'remote: CLI sock is connectable')
if cok and cchan ~= 0 then pcall(vim.fn.chanclose, cchan) end

-- fixture file for open tests
H.lines_file(BASE .. '/found/f.txt', 20)
local target = uv.fs_realpath(BASE .. '/found/f.txt')

-- live candidate: stock --clean nvim
local sock_a = BASE .. '/found/a.sock'
local cand_a, up_a = H.spawn_nvim(sock_a)
local pid_a = cand_a.pid
ok(up_a, 'remote: live candidate socket appeared')

local t0 = uv.hrtime()
local results, status = remote.probe_all({ sock_a }, nil, { target = target })
local probe_ms = (uv.hrtime() - t0) / 1e6
local p = results[sock_a]
ok(p ~= nil and status[sock_a] == 'ok', 'remote: probe round trip against stock nvim',
  vim.inspect(status))
ok(p and p.pid == pid_a, 'remote: payload pid matches spawned pid',
  p and (p.pid .. ' vs ' .. pid_a) or 'no payload')
ok(p and type(p.cwd) == 'string' and #p.cwd > 0, 'remote: payload carries cwd')
ok(p and p.has == false, 'remote: has=false before open')
ok(p and p.started == nil, 'remote: stock nvim reports no started timestamp')
print(('  probe round trip: %.1fms'):format(probe_ms))

-- open at line:col, ack round trip
local ack, ost = remote.open_in(sock_a, target, 7, 3)
ok(ack ~= nil and ost == 'ok', 'remote: open_in acked', ost)
ok(ack and ack.ok == true, 'remote: open succeeded', ack and ack.err or nil)
ok(ack and ack.err == nil, 'remote: a successful open carries no err', ack and ack.err)
ok(ack and ack.line == 7 and ack.col == 3, 'remote: cursor at 7:3',
  ack and (ack.line .. ':' .. ack.col) or nil)
ok(ack and uv.fs_realpath(ack.buf) == target, 'remote: right buffer opened')

-- line clamp
local ack2 = remote.open_in(sock_a, target, 9999, 1)
ok(ack2 and ack2.ok == true and ack2.line == 20, 'remote: line clamped to buffer length',
  ack2 and ack2.line or nil)

-- has=true after open
local r2 = remote.probe_all({ sock_a }, nil, { target = target })
ok(r2[sock_a] and r2[sock_a].has == true, 'remote: has=true after open')

-- the decoded payload is typed at the edge: consumers never re-check shapes
ok(p and type(p.has) == 'boolean' and type(p.term_only) == 'boolean' and type(p.roots) == 'table',
  'remote: probe payload carries booleans and a roots list', vim.inspect(p))

-- dead socket: connect failure, not a hang
local dead_sock = BASE .. '/found/dead.sock'
local rd, sd = remote.probe_all({ dead_sock })
ok(rd[dead_sock] == nil and sd[dead_sock] == 'dead', 'remote: missing socket classed dead')

-- wedged candidate: accepts the socket, never answers; probe must return at
-- the deadline. The wedge is a main-loop block, same observable state as a
-- hit-enter or ATTENTION prompt: connect succeeds, nothing is processed.
local sock_w = BASE .. '/found/w.sock'
local _, up_w = H.spawn_nvim(sock_w)
ok(up_w, 'remote: wedge candidate socket appeared')
ok(H.wedge(sock_w), 'remote: wedge candidate connectable and now blocked')

local t1 = uv.hrtime()
local rw, sw = remote.probe_all({ sock_w }, 500)
local wedge_ms = (uv.hrtime() - t1) / 1e6
ok(rw[sock_w] == nil and sw[sock_w] == 'wedged', 'remote: silent candidate classed wedged',
  vim.inspect(sw))
ok(wedge_ms >= 400 and wedge_ms < 3000,
  ('remote: wedged probe returned at deadline (%.0fms), no hang'):format(wedge_ms))

-- mixed set: one wait bounds the whole set; live answers, wedged does not
local t2 = uv.hrtime()
local rm, sm = remote.probe_all({ sock_a, sock_w, dead_sock }, 1000, { target = target })
local mixed_ms = (uv.hrtime() - t2) / 1e6
ok(rm[sock_a] ~= nil and sm[sock_a] == 'ok', 'remote: mixed set, live still ok')
ok(rm[sock_w] == nil and sm[sock_w] == 'wedged', 'remote: mixed set, wedged still wedged')
ok(sm[dead_sock] == 'dead', 'remote: mixed set, dead still dead')
ok(mixed_ms < 3000, ('remote: mixed set bounded (%.0fms)'):format(mixed_ms))

-- open into the wedged candidate: exit-5 material, nil ack at the deadline
local t3 = uv.hrtime()
local wack, wost = remote.open_in(sock_w, target, 1, 1, 500)
local wopen_ms = (uv.hrtime() - t3) / 1e6
ok(wack == nil and wost == 'wedged', 'remote: open into wedged yields nil ack + wedged')
ok(wopen_ms < 3000, ('remote: wedged open bounded (%.0fms)'):format(wopen_ms))

-- ---------------------------------------------------------------- wire.lua

print('== wire ==')
ok(wire.decode_probe('garbage') == nil, 'wire: non-table probe answer rejected')
ok(wire.decode_probe({ cwd = '/x' }) == nil, 'wire: probe answer without a pid rejected')
ok(wire.decode_probe({ pid = '7' }) == nil, 'wire: probe answer with a non-numeric pid rejected')
local dp = wire.decode_probe({
  pid = 7, ws = 5, cwd = '/x', git = '/g', has = 'yes', term_only = true,
  roots = { '/a', '', 3, '/b' }, started = 'soon', pane = 'w1:p1',
})
ok(dp ~= nil and dp.pid == 7 and dp.cwd == '/x' and dp.git == '/g' and dp.pane == 'w1:p1',
  'wire: well-typed probe fields survive', vim.inspect(dp))
ok(dp and dp.ws == nil and dp.started == nil, 'wire: wrong-typed scalar fields are dropped')
ok(dp and dp.has == false and dp.term_only == true, 'wire: booleans are strict')
ok(dp and vim.deep_equal(dp.roots, { '/a', '/b' }), 'wire: roots keep only non-empty strings',
  dp and vim.inspect(dp.roots))
ok(wire.decode_probe({ pid = 1 }).roots[1] == nil, 'wire: roots default to an empty list')
ok(wire.decode_ack(nil) == nil and wire.decode_ack('x') == nil, 'wire: non-table ack rejected')
local da = wire.decode_ack({ ok = true, pid = 9, buf = '/f', line = 3, col = 2, err = 4 })
ok(da and da.ok == true and da.pid == 9 and da.buf == '/f' and da.line == 3 and da.col == 2,
  'wire: well-typed ack fields survive', vim.inspect(da))
ok(da and da.err == nil, 'wire: wrong-typed ack err is dropped')
ok(wire.decode_ack({ ok = 'true' }).ok == false, 'wire: ack ok is strict')
ok(wire.decode_json('{"a":null,"b":[1]}').a == nil and wire.decode_json('not json') == 'not json',
  'wire: decode_json passes non-JSON through for the typed decoders to reject')

-- ---------------------------------------------------------------- summary

remote.close_callback_server()
H.summary({ BASE ~= vim.env.OLTEST_BASE and BASE or nil })
