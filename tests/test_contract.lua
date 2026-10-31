-- Values that more than one file must agree on: exit codes across the CLI,
-- the herdr scripts and the docs. A drift fails here instead of in the field.
-- Run: nvim -l tests/test_contract.lua (or via tests/run.sh)

local uv = vim.uv

local this = debug.getinfo(1, 'S').source:sub(2)
local this_abs = uv.fs_realpath(this) or this
local H = dofile(vim.fs.dirname(this_abs) .. '/helpers.lua')
H.ensure_isolated('contract', this_abs)

package.path = H.root .. '/lua/?.lua;' .. H.root .. '/lua/?/init.lua;' .. package.path
local EXIT = require('openloc.cli.exit')
local ok = H.ok

local function slurp(rel)
  local f = assert(io.open(H.root .. '/' .. rel, 'r'))
  local body = f:read('*a')
  f:close()
  return body
end

print('== exit codes ==')
local lib = slurp('herdr/bin/lib.sh')
local shell_code = tonumber(lib:match('\nOPENLOC_EXIT_AMBIGUOUS=(%d+)'))
ok(shell_code == EXIT.ambiguous, 'exit: lib.sh ambiguous code equals the CLI constant',
  tostring(shell_code) .. ' vs ' .. tostring(EXIT.ambiguous))
for _, rel in ipairs({ 'herdr/bin/openloc-herdr', 'herdr/bin/openloc-choose' }) do
  local body = slurp(rel)
  ok(not body:find('%-[en][eq] 6') and not body:find('%-eq%s+' .. EXIT.ambiguous),
    'exit: ' .. rel .. ' compares against the shared constant, not a literal')
end

local want = {}
for _, code in pairs(EXIT) do
  want[code] = true
end
local documented = {}
for code in slurp('docs/reference.md'):gmatch('\n| (%d+) |') do
  documented[tonumber(code)] = true
end
ok(vim.deep_equal(want, documented), 'exit: docs/reference.md table lists exactly the CLI exit codes',
  vim.inspect(documented) .. ' vs ' .. vim.inspect(want))

H.summary()
