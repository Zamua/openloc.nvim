-- Environment checks shared by `openloc doctor` and :checkhealth openloc.
-- A finding is { level, topic, msg, hint? } with level ok | info | warn |
-- error. Renderers decide presentation; thresholds live only here.

local uv = vim.uv
local key = require('openloc.key')

local M = {}

local function finding(level, topic, msg, hint)
  return { level = level, topic = topic, msg = msg, hint = hint }
end

-- Registry directory: existence, type, owner and permissions. Second return
-- is the fs_stat result (nil when absent) so callers can go on to list it.
function M.registry_dir(dir)
  dir = dir or key.registry_dir()
  local topic = 'registry dir'
  local st = uv.fs_stat(dir)
  if not st then
    return finding('info', topic, 'not created yet (no plugin-registered editor): ' .. dir), nil
  end
  if st.type ~= 'directory' then
    return finding('error', topic, 'not a directory: ' .. dir), st
  end
  if st.uid ~= uv.getuid() then
    return finding('error', topic, ('owned by uid %d, expected %d: %s'):format(st.uid, uv.getuid(), dir)), st
  end
  local bits = key.perm_bits(st.mode)
  if bits ~= key.DIR_MODE then
    return finding('warn', topic, ('mode %o, expected %o: %s'):format(bits, key.DIR_MODE, dir),
      ('chmod %o %s'):format(key.DIR_MODE, dir)), st
  end
  return finding('ok', topic, ('%s (mode %o, owned by this user)'):format(dir, key.DIR_MODE)), st
end

-- Unix socket paths truncate silently at SUN_PATH_BYTES. Warn from
-- MAX_SOCKET_PATH, where the hashed key form is the only slack left.
function M.socket_path_length(dir)
  local topic = 'socket path length'
  local worst = key.worst_socket_path_len(dir)
  if worst >= key.SUN_PATH_BYTES then
    return finding('error', topic,
      ('registry socket paths reach %d bytes; unix sockets truncate silently at %d'):format(worst, key.SUN_PATH_BYTES),
      'point XDG_CACHE_HOME at a shorter path')
  elseif worst >= key.MAX_SOCKET_PATH then
    return finding('warn', topic,
      ('registry socket paths reach %d bytes, near the %d-byte limit'):format(worst, key.SUN_PATH_BYTES))
  end
  return finding('ok', topic, ('worst-case socket path %d bytes (limit %d)'):format(worst, key.SUN_PATH_BYTES))
end

function M.nvim_on_path()
  local path = vim.fn.exepath('nvim')
  if path == '' then
    return finding('warn', 'nvim on PATH', 'not found',
      'the herdr launcher probes common install paths; set OPENLOC_NVIM to override')
  end
  return finding('ok', 'nvim on PATH', path)
end

-- bin: the located herdr binary or nil; version: its --version output or nil.
function M.herdr(bin, version)
  if not bin then
    return finding('info', 'herdr',
      'not found; routing works, but the live workspace filter and pane spawn are unavailable')
  end
  return finding('ok', 'herdr', bin .. ' (' .. (version and vim.trim(version) or 'version unknown') .. ')')
end

return M
