-- :checkhealth openloc

local uv = vim.uv

local M = {}

local function perm_bits(mode)
  return mode % 512
end

local function sock_alive(path)
  local ok, chan = pcall(vim.fn.sockconnect, 'pipe', path, { rpc = true })
  if ok and chan and chan ~= 0 then
    pcall(vim.fn.chanclose, chan)
    return true
  end
  return false
end

function M.check()
  local health = vim.health
  local key = require('openloc.key')
  local dir = key.registry_dir()

  health.start('registry')
  local st = uv.fs_stat(dir)
  if not st then
    health.info('registry dir not created yet: ' .. dir)
  elseif st.type ~= 'directory' then
    health.error('registry path is not a directory: ' .. dir)
  else
    if st.uid ~= uv.getuid() then
      health.error(('registry dir owned by uid %d, expected %d: %s'):format(st.uid, uv.getuid(), dir))
    elseif perm_bits(st.mode) ~= 448 then
      health.warn(('registry dir mode %o, expected 700: %s'):format(perm_bits(st.mode), dir),
        'chmod 700 ' .. dir)
    else
      health.ok('registry dir ' .. dir .. ' (mode 700, owned by this user)')
    end
    local live, stale = 0, {}
    for name in vim.fs.dir(dir) do
      if name:match('%.sock$') then
        if sock_alive(dir .. '/' .. name) then
          live = live + 1
        else
          stale[#stale + 1] = name
        end
      elseif name:match('%.json$') then
        if not uv.fs_stat(dir .. '/' .. name:gsub('%.json$', '.sock')) then
          stale[#stale + 1] = name .. ' (orphan metadata)'
        end
      end
    end
    health.ok(live .. ' live registry socket(s)')
    if #stale > 0 then
      health.warn('stale registry entries: ' .. table.concat(stale, ', '),
        'safe to delete; a SIGKILLed nvim leaks its socket file')
    end
  end

  health.start('socket path length')
  -- longest generated name: 'ws-' plus 12 hex plus '.sock'
  local worst = #dir + 1 + 20
  if worst >= 104 then
    health.error(('registry socket paths reach %d bytes; unix sockets truncate silently at 104'):format(worst),
      'point XDG_CACHE_HOME at a shorter path')
  elseif worst >= key.MAX_SOCKET_PATH then
    health.warn(('registry socket paths reach %d bytes, near the 104-byte limit'):format(worst))
  else
    health.ok(('worst-case socket path %d bytes (limit 104)'):format(worst))
  end

  health.start('this instance')
  local openloc = package.loaded['openloc']
  if not openloc then
    health.info('openloc not loaded; registry claims belong to plugin startup')
  else
    if vim.g.openloc_started then
      health.ok('started ' .. os.date('%Y-%m-%d %H:%M:%S', vim.g.openloc_started))
    else
      health.warn('vim.g.openloc_started not set; recency tie-breaks fall back to lowest pid')
    end
    local n = 0
    for k, c in pairs(openloc.claims()) do
      n = n + 1
      if uv.fs_stat(c.sock) then
        health.ok('claimed ' .. k .. ' -> ' .. c.sock)
      else
        health.error('claim missing on disk: ' .. c.sock,
          'another process removed it, or the path exceeds the socket limit')
      end
    end
    if n == 0 then
      health.info('no registry claims (register disabled, or nothing to key on)')
    end
  end

  health.start('tools')
  if vim.fn.executable('nvim') == 1 then
    health.ok('nvim on PATH')
  else
    health.warn('nvim not on PATH',
      'the herdr launcher probes common install paths; set OPENLOC_NVIM to override')
  end
  if vim.fn.executable('herdr') == 1 then
    local out = vim.fn.system({ 'herdr', '--version' })
    health.ok('herdr found: ' .. vim.trim(out))
  else
    health.info('herdr not on PATH; routing works, but the CLI cannot resolve live workspace ids')
  end
  health.info('herdr Ctrl-click needs mouse_capture = true (the default) and the modifier is Ctrl on every platform, including macOS; the keyboard picker works regardless')
end

return M
