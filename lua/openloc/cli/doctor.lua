-- `doctor`: installation and environment report.

local uv = vim.uv
local key = require('openloc.key')
local remote = require('openloc.remote')
local EXIT = require('openloc.cli.exit')
local budget = require('openloc.cli.budget')
local diagnostics = require('openloc.diagnostics')
local discovery = require('openloc.cli.discovery')
local herdr = require('openloc.cli.herdr')

local HERDR_CALL_MS = budget.HERDR_CALL_MS

local M = {}

local function run(state)
  local out = {}
  local function line(status, msg)
    out[#out + 1] = string.format('%-4s %s', status, msg)
  end
  local function render(f)
    line(f.level == 'error' and 'FAIL' or f.level, f.topic .. ': ' .. f.msg)
  end
  local src = debug.getinfo(1, 'S').source:gsub('^@', '')
  local cli_dir = vim.fs.dirname(vim.fs.dirname(uv.fs_realpath(src) or src))
  local cli_path = cli_dir .. '/cli.lua'
  line(uv.fs_stat(cli_path) and 'ok' or 'FAIL', 'cli: ' .. cli_path)
  line('ok', 'nvim: ' .. vim.v.progpath .. ' (' .. tostring(vim.version()) .. ')')
  render(diagnostics.nvim_on_path())

  local dir = key.registry_dir()
  render(diagnostics.registry_dir(dir))
  render(diagnostics.socket_path_length(dir))

  local socks = discovery.registry_sockets()
  if #socks > 0 then
    local results, status = remote.probe_all(socks, state.budget:clamp(remote.PROBE_SET_MS))
    for _, s in ipairs(socks) do
      local tag = status[s]
      local pid = results[s] and results[s].pid
      if tag == 'ok' then
        line('ok', 'registry socket live: ' .. s .. ' pid ' .. tostring(pid))
      elseif tag == 'wedged' then
        line('warn', 'registry socket wedged (editor at a blocking prompt?): ' .. s)
      else
        line('warn', 'registry socket stale: ' .. s)
      end
    end
  else
    line('ok', 'registry sockets: none')
  end
  if uv.fs_stat(dir) then
    for name, t in vim.fs.dir(dir) do
      if t ~= 'directory' and name:match('^cli%-%d+%.sock$') then
        local pid = tonumber(name:match('%d+'))
        local alive = pid and pcall(uv.kill, pid, 0) or false
        if not alive and (dir .. '/' .. name) ~= remote.cli_sock_path() then
          line('warn', 'leftover CLI callback socket: ' .. dir .. '/' .. name)
        end
      end
    end
  end

  local bin = herdr.bin()
  render(diagnostics.herdr(bin, bin and herdr.run(state, { bin, '--version' }, HERDR_CALL_MS) or nil))
  local sess = herdr.current_session(state)
  if sess then
    line('ok', 'herdr session: server pid ' .. tostring(sess)
      .. ' (editors under other servers are excluded)')
  else
    line('warn', 'herdr session: no herdr server ancestor; sibling sessions cannot be excluded')
  end
  io.stdout:write(table.concat(out, '\n'), '\n')
  return EXIT.ok
end

M.run = run

return M
