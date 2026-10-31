-- Argument, path and URL handling: usage errors, the stat oracle, open-url parsing and failure reporting.
-- Run: nvim -l tests/test_cli_input.lua (or via tests/run.sh)

local uv = vim.uv

local this = debug.getinfo(1, 'S').source:sub(2)
local this_abs = uv.fs_realpath(this) or this
local H = dofile(vim.fs.dirname(this_abs) .. '/helpers.lua')
H.ensure_isolated('cli_input', this_abs)
local S = dofile(H.tests_dir .. '/scenario.lua')(H, 'cli_input')

local ok = H.ok
local scenario, run_cli, jdecode, enc = S.scenario, S.run_cli, S.jdecode, S.enc

print('== usage ==')
do
  local s = scenario('usage')
  H.lines_file(s.work .. '/f.txt', 20)
  ok(run_cli(s, {}).code == 1, 'usage: no subcommand exits 1')
  ok(run_cli(s, { 'bogus' }).code == 1, 'usage: unknown subcommand exits 1')
  ok(run_cli(s, { 'open' }).code == 1, 'usage: open without a path exits 1')
  ok(run_cli(s, { 'open', 'f.txt', '--spawn', 'sideways' }).code == 1, 'usage: bad --spawn value exits 1')
  ok(run_cli(s, { 'open', 'f.txt', '--frobnicate' }).code == 1, 'usage: unknown flag exits 1')
  ok(run_cli(s, { 'open', 'f.txt', '--line' }).code == 1, 'usage: value flag at argv end exits 1')
  ok(run_cli(s, { 'open', 'f.txt', '--ws', '--json' }).code == 1, 'usage: value flag eating a flag exits 1')
  ok(run_cli(s, { 'open', 'f.txt', '--line', 'abc' }).code == 1, 'usage: non-numeric --line exits 1')
end

print('== stat oracle ==')
do
  local s = scenario('oracle')
  H.lines_file(s.work .. '/f.txt', 20)
  H.lines_file(s.dir .. '/out/f.txt', 5)

  local r = run_cli(s, { 'open', 'nope-xyz.txt', '--spawn', 'never' })
  ok(r.code == 3, 'oracle: missing file exits 3', r.code)
  ok(r.stderr:find('not an existing regular file', 1, true) ~= nil, 'oracle: error names the failure')
  ok(r.stderr:find('nope%-xyz') ~= nil, 'oracle: error names the spec')

  r = run_cli(s, { 'open', 'bad\1name.txt:3', '--spawn', 'never' })
  ok(r.code == 3, 'oracle: control character in spec exits 3', r.code)

  -- every invisible or direction-changing codepoint is refused up front
  local invisible = {
    ['U+200B'] = '\226\128\139', ['U+200E'] = '\226\128\142', ['U+200F'] = '\226\128\143',
    ['U+202E'] = '\226\128\174', ['U+2028'] = '\226\128\168', ['U+2029'] = '\226\128\169',
    ['U+2066'] = '\226\129\166', ['U+FEFF'] = '\239\187\191',
    ['U+0080'] = '\194\128', ['U+0085'] = '\194\133', ['U+009F'] = '\194\159',
  }
  for cp, bytes in pairs(invisible) do
    r = run_cli(s, { 'open', 'f' .. bytes .. '.txt', '--spawn', 'never' })
    ok(r.code == 3 and r.stderr:find('control or invisible', 1, true) ~= nil,
      'oracle: ' .. cp .. ' in a spec is refused as invisible', r.code .. ' ' .. (r.stderr or ''))
  end

  -- an existing file outside every resolved root still resolves; exit 2 is the
  -- absent editor, not a rejected path
  local outside = s.dir .. '/out/f.txt'
  r = run_cli(s, { 'open', outside, '--spawn', 'never' })
  ok(r.code == 2, 'oracle: a path outside every root resolves (exit 2, not 3)', r.code)

  -- directories are not regular files
  r = run_cli(s, { 'open', s.work, '--spawn', 'never' })
  ok(r.code == 3, 'oracle: a directory exits 3', r.code)
end

print('== open-url ==')
do
  local s = scenario('url')
  H.lines_file(s.work .. '/sub/f.txt', 20)
  -- rejections need no candidate: they exit before discovery
  local r = run_cli(s, { 'open-url', 'ftp://openloc.invalid/o?p=x' })
  ok(r.code == 3, 'url: non-http(s) scheme exits 3', r.code)
  r = run_cli(s, { 'open-url', 'not a url' })
  ok(r.code == 3, 'url: garbage exits 3', r.code)
  r = run_cli(s, { 'open-url', 'https://evil.example/o?p=x', '--strict' })
  ok(r.code == 3, 'url: --strict rejects a foreign host', r.code)
  ok(r.stderr:find('strict', 1, true) ~= nil, 'url: strict rejection names strict mode')
  r = run_cli(s, { 'open-url', 'https://openloc.invalid/o?l=42' })
  ok(r.code == 3, 'url: missing p exits 3', r.code)
  r = run_cli(s, { 'open-url' })
  ok(r.code == 1, 'url: no URL and no HERDR_PLUGIN_CLICKED_URL exits 1', r.code)

  local sock = s.glob_sock()
  local cand, up = H.spawn_nvim(sock, { cwd = s.work })
  ok(up, 'url: candidate came up')
  local u = 'https://openloc.invalid/o?p=' .. enc('sub/f.txt') .. '&l=5&c=2&cwd=' .. enc(s.work)
  r = run_cli(s, { 'open-url', u }, { cwd = s.dir })
  ok(r.code == 0 and r.stdout:find(':5:2 pid', 1, true) ~= nil,
    'url: p/l/c/cwd params resolve and position', r.code .. ' ' .. r.stdout .. (r.stderr or ''))

  -- default (non-strict) accepts any http(s) host, reading only the query
  r = run_cli(s, { 'open-url', 'https://evil.example/o?p=' .. enc('sub/f.txt') .. '&l=4&cwd=' .. enc(s.work) },
    { cwd = s.dir })
  ok(r.code == 0 and r.stdout:find(':4:1 pid', 1, true) ~= nil,
    'url: foreign host accepted without --strict', r.code)

  -- HERDR_PLUGIN_CLICKED_URL is the fallback when the positional is absent
  r = run_cli(s, { 'open-url', '--json' }, { cwd = s.dir, env = { HERDR_PLUGIN_CLICKED_URL = u } })
  local obj = jdecode(r.stdout)
  ok(r.code == 0 and obj and obj.winner and obj.winner.pid == cand.pid,
    'url: HERDR_PLUGIN_CLICKED_URL fallback routes', r.code)
end

print('== json failures reach stderr ==')
do
  -- The herdr launcher always passes --json and captures stdout, so an
  -- error that lives only in the JSON leaves the toast with just an exit
  -- code. Failures must appear on stderr in both output modes.
  local s = scenario('jsonerr')
  local r = run_cli(s, { 'open', 'nope-xyz.txt', '--spawn', 'never', '--json' })
  ok(r.code == 3, 'jsonerr: missing file still exits 3', r.code)
  local obj = jdecode(r.stdout)
  ok(obj and obj.error ~= nil, 'jsonerr: the JSON still carries the error', r.stdout)
  ok((r.stderr or ''):find('not an existing regular file', 1, true) ~= nil,
    'jsonerr: --json failures also write the reason to stderr', vim.inspect(r.stderr))
end

S.summary()
