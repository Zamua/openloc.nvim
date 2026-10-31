-- Wall-clock budget shared by every step of one invocation. No step may block
-- past GLOBAL_CAP_MS; later steps keep a reserve so earlier ones cannot starve
-- them.

local uv = vim.uv

local M = {}

M.GLOBAL_CAP_MS = 5000
M.HERDR_CALL_MS = 800
-- Budget kept back for the steps after the current one (open + focus).
M.RESERVE_PROBE_MS = 2500
M.RESERVE_LIVEMAP_MS = 1700
M.RESERVE_OPEN_MS = 500

local Budget = {}
Budget.__index = Budget

function M.new()
  return setmetatable({ t0 = uv.hrtime() }, Budget)
end

function Budget:elapsed_ms()
  return math.floor((uv.hrtime() - self.t0) / 1e6)
end

function Budget:remaining()
  return M.GLOBAL_CAP_MS - self:elapsed_ms()
end

-- Deadline for the next step: at most ms, never past the global cap minus
-- what later steps still need.
function Budget:clamp(ms, reserve)
  local rem = self:remaining() - (reserve or 0)
  if rem < 0 then
    rem = 0
  end
  if ms and ms < rem then
    return ms
  end
  return rem
end

return M
