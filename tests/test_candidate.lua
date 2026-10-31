-- Candidate views: the JSON shapes and text rows every command reports.
-- Pure, no editors. Run: nvim -l tests/test_candidate.lua (or via tests/run.sh)

local uv = vim.uv

local this = debug.getinfo(1, 'S').source:sub(2)
local this_abs = uv.fs_realpath(this) or this
local H = dofile(vim.fs.dirname(this_abs) .. '/helpers.lua')
H.ensure_isolated('candidate', this_abs)

package.path = H.root .. '/lua/?.lua;' .. H.root .. '/lua/?/init.lua;' .. package.path
local candidate = require('openloc.cli.candidate')
local ok = H.ok

local function keys(t)
  local out = {}
  for k in pairs(t) do
    out[#out + 1] = k
  end
  table.sort(out)
  return table.concat(out, ',')
end

local c = candidate.new('/s/nvim.1.0', 'glob')
c.payload = { pid = 41, ws = 'w2', cwd = '/proj' }
c.score = 120
c.session = 7
c.reasons = { 'a', 'b' }
c.status = 'ok'

print('== json views ==')
ok(keys(candidate.json(c, 'winner')) == 'addr,pid,reasons,score', 'winner view names who won and why',
  keys(candidate.json(c, 'winner')))
ok(keys(candidate.json(c, 'choice')) == 'addr,cwd,pid,reasons,score,session,ws',
  'choice view carries what a chooser shows', keys(candidate.json(c, 'choice')))
local full = candidate.json(c, 'full')
ok(full.status == 'ok' and full.excluded == false and full.wedged == false and full.pid == 41,
  'full view carries liveness fields', vim.inspect(full))
c.status = 'wedged'
ok(candidate.json(c, 'full').wedged == true, 'full view flags a wedged candidate')
c.status = 'ok'

print('== text rows ==')
ok(candidate.row(c, candidate.LIST_ROW)
  == 'ok       glob      pid=41       sess=7        ws=w2       score=120   cwd=/proj addr=/s/nvim.1.0',
  'list row layout', candidate.row(c, candidate.LIST_ROW))
ok(candidate.row(c, candidate.CHOICE_ROW) == 'score=120   pid=41       ws=w2       cwd=/proj addr=/s/nvim.1.0',
  'choice row layout', candidate.row(c, candidate.CHOICE_ROW))
local bare = candidate.new('/s/x', 'registry')
ok(candidate.row(bare, candidate.CHOICE_ROW):find('pid=-  ', 1, true) ~= nil, 'absent fields print a dash')

H.summary()
