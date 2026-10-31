-- Filesystem path predicates.

local uv = vim.uv

local M = {}

local function is_file(p)
  local st = uv.fs_stat(p)
  return st ~= nil and st.type == 'file'
end

-- realpath of a directory, trailing slash stripped, nil if it does not exist.
local function norm_dir(p)
  if type(p) ~= 'string' or p == '' then
    return nil
  end
  local r = uv.fs_realpath(p)
  if not r then
    return nil
  end
  r = r:gsub('/+$', '')
  if r == '' then
    r = '/'
  end
  return r
end

local function is_ancestor(dir, path)
  if not dir or not path then
    return false
  end
  if dir == '/' then
    return path:sub(1, 1) == '/'
  end
  return path == dir or path:sub(1, #dir + 1) == dir .. '/'
end

M.is_file = is_file
M.norm_dir = norm_dir
M.is_ancestor = is_ancestor

return M
