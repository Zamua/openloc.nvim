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
local args = require('openloc.cli.args')
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

print('== flags ==')
local docs = slurp('docs/reference.md')
local cli_block = docs:match('```\nnvim %-l bin/openloc.-```') or ''
for name in pairs(args.FLAGS) do
  ok(args.USAGE:find('--' .. name, 1, true) ~= nil, 'flags: --' .. name .. ' is in the usage text')
  ok(cli_block:find('--' .. name, 1, true) ~= nil, 'flags: --' .. name .. ' is in the documented CLI synopsis')
end

print('== environment ==')
-- popup-to-chooser plumbing and script-local names, not user-facing settings
local internal = {
  OPENLOC_CHOOSE_JSON = true, OPENLOC_CHOOSE_ARGS = true, OPENLOC_CHOOSE_INPUT = true,
  OPENLOC_CHOOSE_EOF = true, OPENLOC_EXIT_AMBIGUOUS = true, OPENLOC_PROG = true,
}
local seen = {}
for _, dir in ipairs({ 'lua', 'herdr', 'bin', 'claude', 'plugin' }) do
  for name, kind in vim.fs.dir(H.root .. '/' .. dir, { depth = 4 }) do
    if kind == 'file' then
      local f = io.open(H.root .. '/' .. dir .. '/' .. name, 'r')
      if f then
        for var in f:read('*a'):gmatch('OPENLOC_[A-Z_]+') do
          seen[var] = true
        end
        f:close()
      end
    end
  end
end
for var in pairs(seen) do
  if not internal[var] then
    ok(docs:find(var, 1, true) ~= nil, 'env: ' .. var .. ' is documented')
  end
end

H.summary()
