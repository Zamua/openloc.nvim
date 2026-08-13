-- Foundation tests: key derivation and the deadline-bounded RPC layer.
-- Run from the repo root: nvim -l tests/test_foundation.lua

local uv = vim.uv

-- resolve repo root from this script, so cwd does not matter
local script = debug.getinfo(1, 'S').source:sub(2)
local script_abs = uv.fs_realpath(script) or script
local root = vim.fs.dirname(vim.fs.dirname(script_abs))
package.path = table.concat({
  root .. '/lua/?.lua',
  root .. '/lua/?/init.lua',
  package.path,
}, ';')

local key = require('openloc.key')
local remote = require('openloc.remote')

local npass, nfail = 0, 0
local function ok(cond, name, detail)
  if cond then
    npass = npass + 1
    print('PASS ' .. name)
  else
    nfail = nfail + 1
    print('FAIL ' .. name .. (detail and (' :: ' .. tostring(detail)) or ''))
  end
end

local mypid = uv.os_getpid()
local children = {}

local function write_file(p, content)
  vim.fn.mkdir(vim.fs.dirname(p), 'p')
  local f = assert(io.open(p, 'w'))
  f:write(content or 'x\n')
  f:close()
end

local function spawn_nvim(sock_path)
  local handle, pid = uv.spawn(vim.v.progpath, {
    args = { '--headless', '--clean', '--listen', sock_path },
  }, function() end)
  children[#children + 1] = { handle = handle, pid = pid, sock = sock_path }
  local up = vim.wait(5000, function() return uv.fs_stat(sock_path) ~= nil end, 20)
  return handle, pid, up
end

local function cleanup()
  for _, c in ipairs(children) do
    if c.handle and not c.handle:is_closing() then
      c.handle:kill('sigkill')
      c.handle:close()
    end
    if c.sock then os.remove(c.sock) end
  end
  remote.close_callback_server()
  vim.fn.delete('/tmp/oltest-found-' .. mypid, 'rf')
end

-- ---------------------------------------------------------------- key.lua

print('== key ==')
ok(key.sanitize('w31') == 'w31', 'key: sanitize passthrough')
ok(key.sanitize('a b/c:d') == 'a-b-c-d', 'key: sanitize replaces unsafe chars')
ok(key.sanitize('A_Z-9') == 'A_Z-9', 'key: sanitize keeps [%w-_]')
ok(key.ws_key('w31') == 'ws-w31', 'key: ws_key shape')
local rk = key.root_key('/x')
ok(rk == 'r-' .. string.sub(vim.fn.sha256('/x'), 1, 12), 'key: root_key is 12-hex sha256')
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
local froot = '/tmp/oltest-found-' .. mypid
local lines = {}
for i = 1, 20 do lines[i] = ('line %02d abcdef'):format(i) end
write_file(froot .. '/f.txt', table.concat(lines, '\n') .. '\n')
local target = uv.fs_realpath(froot .. '/f.txt')

-- live candidate: stock --clean nvim
local sock_a = '/tmp/oltest-found-' .. mypid .. '-a.sock'
local _, pid_a, up_a = spawn_nvim(sock_a)
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

-- dead socket: connect failure, not a hang
local dead_sock = '/tmp/oltest-found-' .. mypid .. '-dead.sock'
local rd, sd = remote.probe_all({ dead_sock })
ok(rd[dead_sock] == nil and sd[dead_sock] == 'dead', 'remote: missing socket classed dead')

-- wedged candidate: accepts the socket, never answers; probe must return at
-- the deadline. The wedge is a main-loop block, same observable state as a
-- hit-enter or ATTENTION prompt: connect succeeds, nothing is processed.
local sock_w = '/tmp/oltest-found-' .. mypid .. '-w.sock'
local _, pid_w, up_w = spawn_nvim(sock_w)
ok(up_w, 'remote: wedge candidate socket appeared')
local wok, wchan = pcall(vim.fn.sockconnect, 'pipe', sock_w, { rpc = true })
ok(wok and wchan ~= 0, 'remote: wedge candidate connectable before wedging')
pcall(vim.fn.rpcnotify, wchan, 'nvim_exec_lua', 'vim.uv.sleep(30000)', {})
vim.wait(300) -- let the block start
pcall(vim.fn.chanclose, wchan)

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

-- ---------------------------------------------------------------- summary

cleanup()
print(('== %d passed, %d failed =='):format(npass, nfail))
os.exit(nfail == 0 and 0 or 1)
