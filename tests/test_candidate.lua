-- Candidate lifecycle and views: the one state enum, the JSON shapes and
-- text rows every command reports. Pure, no editors. Run: nvim -l tests/test_candidate.lua (or via tests/run.sh)

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
c.state = 'ok'

print('== json views ==')
ok(keys(candidate.json(c, 'winner')) == 'addr,pid,reasons,score', 'winner view names who won and why',
  keys(candidate.json(c, 'winner')))
ok(keys(candidate.json(c, 'choice')) == 'addr,cwd,pid,reasons,score,session,ws',
  'choice view carries what a chooser shows', keys(candidate.json(c, 'choice')))
local full = candidate.json(c, 'full')
ok(full.status == 'ok' and full.excluded == false and full.wedged == false and full.pid == 41,
  'full view carries liveness fields', vim.inspect(full))
c.state = 'wedged'
ok(candidate.json(c, 'full').wedged == true, 'full view flags a wedged candidate')
c.state = 'ok'

print('== lifecycle ==')
local n = candidate.new('/s/n', 'registry')
ok(not candidate.eligible(n) and not candidate.probed_yet(n), 'new candidate is unprobed and not eligible')
ok(candidate.json(n, 'full').excluded == false and candidate.json(n, 'full').status == nil,
  'unprobed is neither excluded nor given a status')
candidate.probed(n, 'ok', { pid = 5 })
ok(candidate.eligible(n) and candidate.live(n) and candidate.json(n, 'full').status == 'ok',
  'an answered probe makes it eligible')
candidate.exclude(n, 'excluded: because')
local nj = candidate.json(n, 'full')
ok(not candidate.eligible(n) and candidate.live(n), 'excluded stays live but is no longer eligible')
ok(nj.excluded == true and nj.status == 'ok' and nj.reasons[#nj.reasons] == 'excluded: because',
  'excluded still reports the editor as responsive, with the reason', vim.inspect(nj))
for _, st in ipairs({ 'dead', 'wedged', 'self' }) do
  local u = candidate.new('/s/' .. st, 'glob')
  candidate.probed(u, st)
  local uj = candidate.json(u, 'full')
  ok(not candidate.eligible(u) and not candidate.live(u) and uj.excluded == true and uj.status == st
    and #uj.reasons == 1, 'probe outcome ' .. st .. ' is unusable and explained', vim.inspect(uj))
end
local d = candidate.new('/s/dup', 'glob')
candidate.probed(d, 'ok', { pid = 5 })
candidate.mark_duplicate(d, n)
ok(candidate.json(d, 'full').status == 'duplicate' and not candidate.eligible(d),
  'a duplicate socket is reported as such and never eligible')

print('== text rows ==')
ok(candidate.row(c, candidate.LIST_ROW)
  == 'ok       glob      pid=41       sess=7        ws=w2       score=120   cwd=/proj addr=/s/nvim.1.0',
  'list row layout', candidate.row(c, candidate.LIST_ROW))
ok(candidate.row(c, candidate.CHOICE_ROW) == 'score=120   pid=41       ws=w2       cwd=/proj addr=/s/nvim.1.0',
  'choice row layout', candidate.row(c, candidate.CHOICE_ROW))
local bare = candidate.new('/s/x', 'registry')
ok(candidate.row(bare, candidate.CHOICE_ROW):find('pid=-  ', 1, true) ~= nil, 'absent fields print a dash')

H.summary()
