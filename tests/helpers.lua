-- Shared test scaffolding: isolation re-exec, assertion counters, child
-- process tracking. dofile'd by each test file; not a runtime module.

local uv = vim.uv

local M = {}

local script = debug.getinfo(1, 'S').source:sub(2)
M.tests_dir = vim.fs.dirname(uv.fs_realpath(script) or script)
M.root = vim.fs.dirname(M.tests_dir)

M.npass, M.nfail = 0, 0

function M.ok(cond, name, detail)
  if cond then
    M.npass = M.npass + 1
    print('PASS ' .. name)
  else
    M.nfail = M.nfail + 1
    print('FAIL ' .. name .. (detail and (' :: ' .. tostring(detail)) or ''))
  end
  return cond
end

function M.mkdir(p)
  vim.fn.mkdir(p, 'p')
  return p
end

function M.write_file(p, content)
  vim.fn.mkdir(vim.fs.dirname(p), 'p')
  local f = assert(io.open(p, 'w'))
  f:write(content or 'x\n')
  f:close()
end

-- n numbered lines, so cursor assertions have a known line count.
function M.lines_file(p, n)
  local t = {}
  for i = 1, n do
    t[i] = ('line %02d abcdef'):format(i)
  end
  M.write_file(p, table.concat(t, '\n') .. '\n')
end

M.children = {}
-- Pids this process did not fork itself, so vim.system holds no handle for
-- them: a grandchild is orphaned rather than reaped when its parent is
-- SIGKILLed, and a headless nvim left listening on a default socket is
-- discoverable by any later real click.
M.orphans = {}

-- Spawned pids also go to $OLTEST_PIDFILE so the run.sh trap can reap them
-- if the test process dies before its own cleanup.
local function note_pid(pid)
  local pf = vim.env.OLTEST_PIDFILE
  if pf and pf ~= '' then
    local f = io.open(pf, 'a')
    if f then
      f:write(pid, '\n')
      f:close()
    end
  end
end

function M.spawn(argv, opts)
  opts = opts or {}
  local obj = vim.system(argv, { env = opts.env, cwd = opts.cwd })
  M.children[#M.children + 1] = obj
  note_pid(obj.pid)
  return obj
end

-- Headless candidate editor listening on sock; opts.args appends (e.g. a file
-- to hold open), opts.env/opts.cwd shape its identity for scoring tests.
function M.spawn_nvim(sock, opts)
  opts = opts or {}
  vim.fn.mkdir(vim.fs.dirname(sock), 'p')
  local argv = { vim.v.progpath, '--headless', '--clean', '--listen', sock }
  for _, a in ipairs(opts.args or {}) do
    argv[#argv + 1] = a
  end
  local obj = M.spawn(argv, opts)
  local up = vim.wait(5000, function()
    return uv.fs_stat(sock) ~= nil
  end, 10)
  return obj, up
end

-- A process whose name is `herdr`, standing in for a session server. Hardlink
-- first: macOS takes a process's reported name from the executable's own
-- directory entry, so the link name is the name ps reports, while a copy of a
-- signed platform binary such as /bin/sh is SIGKILLed on exec. The fallback
-- copy covers a tests dir on another filesystem.
function M.fake_herdr_bin(dir)
  local path = dir .. '/herdr'
  if uv.fs_stat(path) then
    return path
  end
  M.mkdir(dir)
  if not uv.fs_link(vim.v.progpath, path) then
    local src = io.open(vim.v.progpath, 'rb')
    if not src then
      return nil
    end
    local dst = io.open(path, 'wb')
    if not dst then
      src:close()
      return nil
    end
    dst:write(src:read('*a'))
    src:close()
    dst:close()
    uv.fs_chmod(path, tonumber('755', 8))
  end
  return path
end

-- A candidate editor whose nearest `herdr` ancestor is fake_bin, i.e. one
-- that belongs to a different session than anything this test spawns
-- directly. The wrapper stays alive so the ancestry stays walkable.
function M.spawn_nvim_under(fake_bin, sock, opts)
  opts = opts or {}
  vim.fn.mkdir(vim.fs.dirname(sock), 'p')
  local argv = { vim.v.progpath, '--headless', '--clean', '--listen', sock }
  for _, a in ipairs(opts.args or {}) do
    argv[#argv + 1] = a
  end
  local spec = vim.inspect(argv, { newline = ' ', indent = '' })
  local lua = ('vim.system(%s); vim.uv.sleep(%d)'):format(spec, opts.hold_ms or 30000)
  -- An explicit --listen keeps the wrapper off the default socket path, so
  -- glob discovery never offers this scaffolding as a candidate.
  local wrapper = M.spawn({
    fake_bin, '--headless', '--clean',
    '--listen', vim.fs.dirname(sock) .. '/wrapper-' .. tostring(uv.os_getpid()) .. '.sock',
    '-c', 'lua ' .. lua,
  }, opts)
  local up = vim.wait(8000, function()
    return uv.fs_stat(sock) ~= nil
  end, 10)
  local pid = nil
  if up then
    local ok, chan = pcall(vim.fn.sockconnect, 'pipe', sock, { rpc = true })
    if ok and chan and chan ~= 0 then
      local ok2, got = pcall(vim.fn.rpcrequest, chan, 'nvim_eval', 'getpid()')
      if ok2 then
        pid = got
        M.orphans[#M.orphans + 1] = pid
        note_pid(pid)
      end
      pcall(vim.fn.chanclose, chan)
    end
  end
  return { wrapper = wrapper, pid = pid }, up and pid ~= nil
end

-- Block a candidate's main loop; its listen socket keeps accepting connects
-- but nothing answers, the observable state of a hit-enter or swapfile
-- ATTENTION prompt.
function M.wedge(sock, ms)
  local ok, chan = pcall(vim.fn.sockconnect, 'pipe', sock, { rpc = true })
  if not ok or not chan or chan == 0 then
    return false
  end
  pcall(vim.fn.rpcnotify, chan, 'nvim_exec_lua', ('vim.uv.sleep(%d)'):format(ms or 60000), {})
  vim.wait(200)
  pcall(vim.fn.chanclose, chan)
  return true
end

function M.cleanup()
  for _, c in ipairs(M.children) do
    pcall(function()
      c:kill(9)
    end)
  end
  for _, pid in ipairs(M.orphans) do
    pcall(uv.kill, pid, 9)
  end
  M.children = {}
  M.orphans = {}
end

function M.summary(extra_dirs)
  M.cleanup()
  for _, d in ipairs(extra_dirs or {}) do
    vim.fn.delete(d, 'rf')
  end
  print(('== %d passed, %d failed =='):format(M.npass, M.nfail))
  io.stdout:flush()
  os.exit(M.nfail == 0 and 0 or 1)
end

-- Re-exec this test in an isolated environment when invoked directly
-- (nvim -l tests/test_x.lua). run.sh sets OLTEST_ISOLATED=1 and provides the
-- isolation itself, so under run.sh this is a no-op. Isolation means: fresh
-- TMPDIR / XDG dirs (registry and glob discovery cannot see or touch real
-- editors) and no HERDR_* / OPENLOC_* inherited from the operator's shell.
function M.ensure_isolated(name, script_path)
  if vim.env.OLTEST_ISOLATED == '1' then
    return
  end
  local base = '/tmp/oltest-' .. name .. '-' .. uv.os_getpid()
  local pidfile = base .. '/pids'
  M.mkdir(base .. '/tmp')
  M.mkdir(base .. '/xdg-cache')
  M.mkdir(base .. '/xdg-run')
  uv.fs_chmod(base .. '/xdg-run', tonumber('700', 8))
  io.open(pidfile, 'w'):close()

  local drop = {
    HERDR_PLUGIN_CONTEXT_JSON = true,
    HERDR_PLUGIN_CLICKED_URL = true,
    HERDR_PLUGIN_ROOT = true,
    HERDR_WORKSPACE_ID = true,
    HERDR_PANE_ID = true,
    HERDR_TAB_ID = true,
    HERDR_ENV = true,
    HERDR_BIN_PATH = true,
    OPENLOC_ALLOW = true,
    OPENLOC_STRICT = true,
    OPENLOC_SPAWN = true,
    OPENLOC_NVIM = true,
    OPENLOC_CLI = true,
    OPENLOC_PICK_MARGIN = true,
  }
  local env = {}
  for k, v in pairs(vim.fn.environ()) do
    if not drop[k] then
      env[#env + 1] = k .. '=' .. v
    end
  end
  local extra = {
    OLTEST_ISOLATED = '1',
    OLTEST_BASE = base,
    OLTEST_PIDFILE = pidfile,
    TMPDIR = base .. '/tmp',
    XDG_CACHE_HOME = base .. '/xdg-cache',
    XDG_RUNTIME_DIR = base .. '/xdg-run',
  }
  for k, v in pairs(extra) do
    env[#env + 1] = k .. '=' .. v
  end

  local code, done
  local handle = uv.spawn(vim.v.progpath, {
    args = { '-l', script_path },
    env = env,
    stdio = { 0, 1, 2 },
  }, function(c)
    code = c
    done = true
  end)
  if not handle then
    io.stderr:write('helpers: re-exec spawn failed\n')
    os.exit(1)
  end
  vim.wait(600000, function()
    return done
  end, 50)
  -- reap anything the child left behind, then drop its scratch tree
  local f = io.open(pidfile, 'r')
  if f then
    for line in f:lines() do
      local pid = tonumber(line)
      if pid then
        pcall(uv.kill, pid, 9)
      end
    end
    f:close()
  end
  vim.fn.delete(base, 'rf')
  os.exit(code or 1)
end

return M
