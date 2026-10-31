-- Environment access.

local M = {}

-- An empty variable counts as unset.
function M.getenv(name)
  local v = vim.env[name]
  if v == nil or v == '' then
    return nil
  end
  return v
end

return M
