-- Registry key derivation. Pure string work; the only environment read is
-- stdpath('cache').

local M = {}

-- macOS sun_path is 104 bytes and overflow truncates silently; stay clear.
M.MAX_SOCKET_PATH = 100

function M.registry_dir()
  return vim.fn.stdpath('cache') .. '/openloc'
end

-- Keys become socket filenames: anything outside [%w-_] is unsafe there.
function M.sanitize(s)
  return (tostring(s):gsub('[^%w%-_]', '-'))
end

function M.ws_key(workspace_id)
  return 'ws-' .. M.sanitize(workspace_id)
end

-- root must already be realpath'd; hashing a symlinked spelling would split
-- one root into two keys.
function M.root_key(root)
  return 'r-' .. string.sub(vim.fn.sha256(root), 1, 12)
end

local function hashed(key)
  local prefix = key:match('^(%a+)%-') or 'k'
  return prefix .. '-' .. string.sub(vim.fn.sha256(key), 1, 12)
end

-- Length-guarded key: when the socket path would risk sun_path truncation,
-- collapse the key to prefix + 12-hex hash. A registry dir so deep that even
-- the hashed form overflows cannot be fixed here; health.lua reports it.
function M.effective_key(key)
  local path = M.registry_dir() .. '/' .. key .. '.sock'
  if #path < M.MAX_SOCKET_PATH then
    return key
  end
  return hashed(key)
end

function M.socket_path(key)
  return M.registry_dir() .. '/' .. M.effective_key(key) .. '.sock'
end

function M.json_path(key)
  return M.registry_dir() .. '/' .. M.effective_key(key) .. '.json'
end

return M
