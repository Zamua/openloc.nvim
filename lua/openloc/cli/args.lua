-- Argument and URL parsing. Pure string work, no I/O.

local M = {}

local USAGE = table.concat({
  'usage: nvim -l bin/openloc <command> [args]',
  '  open <path>[:line[:col]] [--ws ID] [--session PID] [--cwd PATH] [--line N] [--col N]',
  '       [--addr SOCKET] [--choose auto|never] [--json] [--spawn split|never]',
  '  open-url <url> [--strict] [--addr SOCKET] [--session PID] [--choose auto|never] [--json]',
  '       [--spawn split|never]',
  '  list [--json]',
  '  doctor',
}, '\n') .. '\n'

-- Control, zero-width, bidi and line-separator characters are how a displayed
-- path lies about its target.
local function forbidden(path)
  if path:find('%c') then return true end
  if path:find('\194[\128-\159]') then return true end -- C1 controls U+0080..U+009F
  if path:find('\226\128[\139-\143]') then return true end -- U+200B..U+200F
  if path:find('\226\128[\168-\174]') then return true end -- U+2028..U+202E
  if path:find('\226\129[\166-\169]') then return true end -- U+2066..U+2069
  if path:find('\239\187\191', 1, true) then return true end -- U+FEFF
  return false
end

local function pct_decode(s)
  return (s:gsub('%%(%x%x)', function(h)
    return string.char(tonumber(h, 16))
  end))
end

-- Accepts any http(s) URL and reads only the query params; --strict (or
-- OPENLOC_STRICT=1) additionally requires the openloc.invalid host.
local function parse_url(url)
  local scheme = url:match('^(%a[%w+%-.]*)://')
  if not scheme then
    return nil, 'not a URL: ' .. url
  end
  local lower = scheme:lower()
  if lower ~= 'http' and lower ~= 'https' then
    return nil, 'non-http(s) scheme: ' .. scheme
  end
  local rest = url:sub(#scheme + 4)
  local host = rest:match('^([^/?#]*)') or ''
  local query = url:match('%?([^#]*)') or ''
  local params = {}
  for kv in query:gmatch('[^&]+') do
    local k, v = kv:match('^([^=]*)=?(.*)$')
    if k and k ~= '' then
      params[pct_decode(k)] = pct_decode(v or '')
    end
  end
  return { host = host, params = params }
end

-- <path>[:line[:col]] with a tolerated trailing colon (go test output).
local function split_spec(spec)
  local p, l, c = spec:match('^(.-):(%d+):(%d+):?$')
  if p and p ~= '' then
    return p, tonumber(l), tonumber(c)
  end
  p, l = spec:match('^(.-):(%d+):?$')
  if p and p ~= '' then
    return p, tonumber(l)
  end
  return spec
end

local SPAWN_MODES = { split = true, never = true }
local CHOOSE_MODES = { auto = true, never = true }

local function parse_flags(argv, i0)
  local flags, pos = {}, {}
  local i = i0
  local err
  -- Consume the next argv entry as a flag value; absent or another flag is
  -- a usage error, never silently swallowed.
  local function value(a)
    i = i + 1
    local v = argv[i]
    if v == nil or v:sub(1, 2) == '--' then
      err = 'flag ' .. a .. ' needs a value'
      return nil
    end
    return v
  end
  local function number(a)
    local v = value(a)
    if err then
      return nil
    end
    local n = tonumber(v)
    if not n then
      err = 'flag ' .. a .. ' takes a number'
    end
    return n
  end
  while i <= #argv do
    local a = argv[i]
    if a == '--json' then
      flags.json = true
    elseif a == '--strict' then
      flags.strict = true
    elseif a == '--ws' then
      flags.ws = value(a)
    elseif a == '--session' then
      flags.session = value(a)
    elseif a == '--cwd' then
      flags.cwd = value(a)
    elseif a == '--line' then
      flags.line = number(a)
    elseif a == '--col' then
      flags.col = number(a)
    elseif a == '--spawn' then
      flags.spawn = value(a)
      if not err and not SPAWN_MODES[flags.spawn or ''] then
        return nil, '--spawn takes split|never'
      end
    elseif a == '--addr' then
      flags.addr = value(a)
    elseif a == '--choose' then
      flags.choose = value(a)
      if not err and not CHOOSE_MODES[flags.choose or ''] then
        return nil, '--choose takes auto|never'
      end
    elseif a:sub(1, 2) == '--' then
      return nil, 'unknown flag: ' .. a
    else
      pos[#pos + 1] = a
    end
    if err then
      return nil, err
    end
    i = i + 1
  end
  return flags, pos
end

M.USAGE = USAGE
M.forbidden = forbidden
M.pct_decode = pct_decode
M.parse_url = parse_url
M.split_spec = split_spec
M.parse_flags = parse_flags

return M
