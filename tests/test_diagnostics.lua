-- Shared environment checks behind `openloc doctor` and :checkhealth openloc:
-- one verdict per condition, whichever renderer shows it.
-- Run: nvim -l tests/test_diagnostics.lua (or via tests/run.sh)

local uv = vim.uv

local this = debug.getinfo(1, 'S').source:sub(2)
local this_abs = uv.fs_realpath(this) or this
local H = dofile(vim.fs.dirname(this_abs) .. '/helpers.lua')
H.ensure_isolated('diagnostics', this_abs)

package.path = H.root .. '/lua/?.lua;' .. H.root .. '/lua/?/init.lua;' .. package.path
local key = require('openloc.key')
local diagnostics = require('openloc.diagnostics')
local ok = H.ok

local BASE = vim.env.OLTEST_BASE
if not BASE or BASE == '' then
  BASE = H.mkdir('/tmp/oltest-diagnostics-' .. uv.os_getpid())
end

print('== registry dir ==')
local f, st = diagnostics.registry_dir(BASE .. '/absent')
ok(f.level == 'info' and st == nil, 'registry dir: absent is informational', f.level)

H.write_file(BASE .. '/afile', 'x')
f = diagnostics.registry_dir(BASE .. '/afile')
ok(f.level == 'error', 'registry dir: a file in its place is an error', f.level)

local d = H.mkdir(BASE .. '/dir')
uv.fs_chmod(d, tonumber('755', 8))
f = diagnostics.registry_dir(d)
ok(f.level == 'warn' and f.hint ~= nil, 'registry dir: open permissions warn with a fix', f.level)
uv.fs_chmod(d, key.DIR_MODE)
f, st = diagnostics.registry_dir(d)
ok(f.level == 'ok' and st ~= nil and st.type == 'directory', 'registry dir: 0700 own directory is ok', f.level)

print('== socket path length ==')
-- worst-case path = #dir + 1 + 20
local function level_for_worst(n)
  return diagnostics.socket_path_length(string.rep('d', n - 21)).level
end
ok(level_for_worst(key.MAX_SOCKET_PATH - 1) == 'ok', 'socket length: under the soft limit is ok')
ok(level_for_worst(key.MAX_SOCKET_PATH) == 'warn', 'socket length: the soft limit warns')
ok(level_for_worst(key.SUN_PATH_BYTES - 1) == 'warn', 'socket length: just under the hard limit warns')
ok(level_for_worst(key.SUN_PATH_BYTES) == 'error', 'socket length: the hard limit is an error')

print('== tools ==')
ok(diagnostics.herdr(nil, nil).level == 'info', 'herdr: absent is informational')
f = diagnostics.herdr('/x/herdr', 'herdr 1.2.3\n')
ok(f.level == 'ok' and f.msg:find('1.2.3', 1, true) ~= nil, 'herdr: found names its version', f.msg)

H.summary({ BASE ~= vim.env.OLTEST_BASE and BASE or nil })
