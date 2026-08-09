# WezTerm

The reference click adapter. WezTerm's `hyperlink_rules` linkify plain text
file refs itself, so a plain unmodified left click works. The `open-uri` event
then routes the click to openloc instead of a browser.

Status: follows WezTerm's documented API; untested end to end.

```lua
-- ~/.wezterm.lua
local wezterm = require 'wezterm'
local config = wezterm.config_builder()

-- Linkify path:line in plain output.
config.hyperlink_rules = wezterm.default_hyperlink_rules()
table.insert(config.hyperlink_rules, {
  regex = [[([\w./~-]+\.[A-Za-z0-9]+):(\d+)]],
  format = 'https://openloc.invalid/o?p=$1&l=$2',
})

-- Adjust when the plugin is not managed by lazy.nvim.
local openloc = wezterm.home_dir .. '/.local/share/nvim/lazy/openloc.nvim/bin/openloc'

wezterm.on('open-uri', function(window, pane, uri)
  if uri:match('^https://openloc%.invalid/') then
    local url = uri
    local cwd = pane:get_current_working_dir()
    if cwd and cwd.file_path then
      url = url .. '&cwd=' .. cwd.file_path
    end
    wezterm.background_child_process { 'nvim', '-l', openloc, 'open-url', url }
    return false -- suppress the default opener
  end
end)

return config
```

Caveats:

- `$1` and the appended cwd are not percent encoded. The router tolerates raw
  `/` and `.` in query values, but a path containing `&`, `?` or `#` will
  parse wrong.
- Use an absolute `nvim` path in `background_child_process` if WezTerm's
  environment lacks it.
