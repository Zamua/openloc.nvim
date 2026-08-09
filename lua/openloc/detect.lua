-- File-reference detection: a permissive regex tier over raw text, then the
-- stat oracle. A candidate survives only if it resolves, against the given
-- bases, to an existing regular file; regex false positives die on fs_stat.

local uv = vim.uv

local M = {}

-- Conservative path charset. Excludes whitespace, quotes, parens and colon so
-- the surrounding syntax can anchor the match.
local P = '[%w%._%-/~+@]+'

-- Permissive tier, higher priority first. Overlapping lower-priority matches
-- are dropped. Each pattern names the tool output it covers.
M.patterns = {
  -- rustc diagnostics: ' --> src/main.rs:4:9'
  { name = 'rust_arrow', pat = '%-%->%s*(' .. P .. '):(%d+):(%d+)', groups = 3 },
  -- CPython traceback: 'File "app/main.py", line 12'
  { name = 'python_file', pat = 'File "([^"]+)", line (%d+)', groups = 2 },
  -- generic quoted ref: '"app/main.py", line 3'
  { name = 'quoted_line', pat = '"([^"]+)",[ \t]*line[ \t]+(%d+)', groups = 2 },
  -- rg --vimgrep, gcc/clang, go vet, node stack frames '(/x.js:1:2)'
  { name = 'path_line_col', pat = '(' .. P .. '):(%d+):(%d+)', groups = 3 },
  -- grep -n, rg -n, go test 'x.go:12:', lua errors, make
  { name = 'path_line', pat = '(' .. P .. '):(%d+)', groups = 2 },
  -- MSVC / .NET / tsc: 'path(42,7)'
  { name = 'paren_line_col', pat = '(' .. P .. ')%((%d+),(%d+)%)', groups = 3 },
  -- MSVC: 'path(42)'
  { name = 'paren_line', pat = '(' .. P .. ')%((%d+)%)', groups = 2 },
}

-- Control, zero-width and bidi characters never belong in a real file
-- reference; they are how a displayed path lies about its target.
local function forbidden(path)
  if path:find('%c') then return true end
  if path:find('\226\128[\139-\141]') then return true end -- U+200B..U+200D
  if path:find('\239\187\191', 1, true) then return true end -- U+FEFF
  if path:find('\226\128[\170-\174]') then return true end -- U+202A..U+202E
  if path:find('\226\129[\166-\169]') then return true end -- U+2066..U+2069
  return false
end

local function is_file(p)
  local st = uv.fs_stat(p)
  return st ~= nil and st.type == 'file'
end

-- Resolve a detected path against the bases, first hit wins. Returns the
-- realpath of an existing regular file, else nil. Never creates anything.
local function resolve(path, bases)
  local p = path
  if p:sub(1, 1) == '~' then
    p = vim.fs.normalize(p)
  end
  if p:sub(1, 1) == '/' then
    if is_file(p) then
      return uv.fs_realpath(p) or p
    end
    return nil
  end
  for _, base in ipairs(bases or {}) do
    if type(base) == 'string' and base ~= '' then
      local joined = base:gsub('/+$', '') .. '/' .. p
      if is_file(joined) then
        return uv.fs_realpath(joined) or joined
      end
    end
  end
  return nil
end

-- detect(text, bases) -> [{ path, line, col, span = {start, stop} }]
-- path is the resolved realpath; span is byte offsets into text; results are
-- in text order.
function M.detect(text, bases)
  local raw = {}
  for prio, spec in ipairs(M.patterns) do
    local init = 1
    while true do
      local s, e, a, b, c = text:find(spec.pat, init)
      if not s then break end
      local m = { s = s, e = e, prio = prio, path = a }
      if spec.groups >= 2 then m.line = tonumber(b) end
      if spec.groups >= 3 then m.col = tonumber(c) end
      raw[#raw + 1] = m
      init = e + 1
    end
  end
  table.sort(raw, function(x, y)
    if x.prio ~= y.prio then return x.prio < y.prio end
    return x.s < y.s
  end)
  -- Only oracle-passing matches claim their span, so a false positive cannot
  -- shadow a real overlapping reference from a later pattern.
  local accepted, out = {}, {}
  for _, m in ipairs(raw) do
    local overlaps = false
    for _, a in ipairs(accepted) do
      if m.s <= a.e and m.e >= a.s then
        overlaps = true
        break
      end
    end
    if not overlaps and not forbidden(m.path) then
      local abs = resolve(m.path, bases)
      if abs then
        accepted[#accepted + 1] = m
        out[#out + 1] = { path = abs, line = m.line, col = m.col, span = { m.s, m.e } }
      end
    end
  end
  table.sort(out, function(x, y) return x.span[1] < y.span[1] end)
  return out
end

return M
