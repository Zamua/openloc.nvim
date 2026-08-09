-- Subdir entry shim: the shared implementation lives in the parent checkout.
-- OPENLOC-VENDOR-MARKER: release tooling replaces this file with a vendored
-- copy of the CLI so the herdr subdir also works as a standalone checkout.

-- nvim -l publishes its own server socket; retract it before anything else.
pcall(vim.fn.serverstop, vim.v.servername)

local src = debug.getinfo(1, 'S').source:gsub('^@', '')
src = vim.uv.fs_realpath(src) or src
local adapter_root = vim.fs.dirname(vim.fs.dirname(src))
local root = vim.fs.dirname(adapter_root)
local lua_dir = root .. '/lua'
local cli_path = lua_dir .. '/openloc/cli.lua'

-- The climb above the subdir is trusted only when the layout matches the
-- full repo (herdr/cli/openloc.lua); a standalone subdir checkout must never
-- dofile whatever happens to sit two levels up.
if vim.fs.basename(adapter_root) ~= 'herdr' or not vim.uv.fs_stat(cli_path) then
  io.stderr:write('openloc: standalone subdir checkout without the vendored CLI\n')
  io.stderr:write('openloc: reinstall with: herdr plugin install <owner>/openloc.nvim/herdr\n')
  os.exit(1)
end

package.path = lua_dir .. '/?.lua;' .. lua_dir .. '/?/init.lua;' .. package.path

local mod = dofile(cli_path)
if type(mod) == 'table' then
  local main = mod.main or mod.run
  if type(main) == 'function' then
    local code = main(_G.arg)
    os.exit(type(code) == 'number' and code or 0)
  end
end
io.stderr:write('openloc: cli.lua exposes no main(arg) entry\n')
os.exit(1)
