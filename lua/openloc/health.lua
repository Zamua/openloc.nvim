-- :checkhealth openloc

local uv = vim.uv
local diagnostics = require('openloc.diagnostics')

local M = {}

local function render(f)
  local health = vim.health
  local text = f.topic .. ': ' .. f.msg
  if f.level == 'ok' then
    health.ok(text)
  elseif f.level == 'info' then
    health.info(text)
  elseif f.level == 'warn' then
    health.warn(text, f.hint)
  else
    health.error(text, f.hint)
  end
end

local function sock_alive(path)
  local ok, chan = pcall(vim.fn.sockconnect, 'pipe', path, { rpc = true })
  if ok and chan and chan ~= 0 then
    pcall(vim.fn.chanclose, chan)
    return true
  end
  return false
end

function M.check()
  local health = vim.health
  local key = require('openloc.key')
  local dir = key.registry_dir()

  health.start('registry')
  local dir_finding, st = diagnostics.registry_dir(dir)
  render(dir_finding)
  if st and st.type == 'directory' then
    local live, stale = 0, {}
    for name in vim.fs.dir(dir) do
      if name:match('%.sock$') then
        if sock_alive(dir .. '/' .. name) then
          live = live + 1
        else
          stale[#stale + 1] = name
        end
      elseif name:match('%.json$') then
        if not uv.fs_stat(dir .. '/' .. name:gsub('%.json$', '.sock')) then
          stale[#stale + 1] = name .. ' (orphan metadata)'
        end
      end
    end
    health.ok(live .. ' live registry socket(s)')
    if #stale > 0 then
      health.warn('stale registry entries: ' .. table.concat(stale, ', '),
        'safe to delete; a SIGKILLed nvim leaks its socket file')
    end
  end

  health.start('socket path length')
  render(diagnostics.socket_path_length(dir))

  health.start('this instance')
  local openloc = package.loaded['openloc']
  if not openloc then
    health.info('openloc not loaded; registry claims belong to plugin startup')
  else
    if vim.g.openloc_started then
      health.ok('started ' .. os.date('%Y-%m-%d %H:%M:%S', vim.g.openloc_started))
    else
      health.warn('vim.g.openloc_started not set; recency tie-breaks fall back to lowest pid')
    end
    local n = 0
    for k, c in pairs(openloc.claims()) do
      n = n + 1
      if uv.fs_stat(c.sock) then
        health.ok('claimed ' .. k .. ' -> ' .. c.sock)
      else
        health.error('claim missing on disk: ' .. c.sock,
          'another process removed it, or the path exceeds the socket limit')
      end
    end
    if n == 0 then
      health.info('no registry claims (register disabled, or nothing to key on)')
    end
  end

  health.start('tools')
  render(diagnostics.nvim_on_path())
  local herdr_bin = vim.fn.exepath('herdr')
  herdr_bin = herdr_bin ~= '' and herdr_bin or nil
  render(diagnostics.herdr(herdr_bin, herdr_bin and vim.fn.system({ herdr_bin, '--version' }) or nil))
  health.info('herdr Ctrl-click needs mouse_capture = true (the default) and the modifier is Ctrl on every platform, including macOS; the keyboard picker works regardless')

  health.start('install points')
  if vim.fn.executable('herdr') == 1 then
    local plugins = vim.fn.system({ 'herdr', 'plugin', 'list' })
    if plugins:find('openloc', 1, true) then
      health.ok('herdr plugin installed')
    else
      health.warn('herdr plugin not installed',
        'herdr plugin install Zamua/openloc.nvim/herdr')
    end
    local conf = vim.fn.expand('~/.config/herdr/config.toml')
    local body = ''
    local f = io.open(conf, 'r')
    if f then
      body = f:read('*a')
      f:close()
    end
    if body:find('%[ui%.toast%]') and not body:find('delivery%s*=%s*"off"') then
      health.ok('herdr toast delivery enabled (failed opens explain themselves)')
    else
      health.info('herdr toasts off (optional): add [ui.toast] delivery = "herdr" to '
        .. conf .. ' then run: herdr server reload-config')
    end
  end
  if vim.fn.executable('claude') == 1 then
    local list = vim.fn.system({ 'claude', 'plugin', 'list' })
    if list:find('openloc', 1, true) then
      health.ok('Claude Code plugin installed (agent emits clickable refs)')
    else
      health.info('Claude Code plugin not installed: /plugin marketplace add Zamua/openloc.nvim '
        .. 'then /plugin install openloc@openloc (or add the instruction line from docs/reference.md)')
    end
  end
end

return M
