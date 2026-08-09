# tmux

Two options.

## Hyperlink click (tmux >= 3.4, unverified)

tmux exposes the OSC 8 target under the mouse as `#{mouse_hyperlink}`. This
mechanism is unverified in the openloc design; the binding is documented for
completeness.

```tmux
# ~/.tmux.conf
set -ga terminal-features "*:hyperlinks"
bind-key -T root DoubleClick1Pane if-shell -F '#{!=:#{mouse_hyperlink},}' \
  'run-shell "nvim -l /path/to/openloc.nvim/bin/openloc open-url \"#{mouse_hyperlink}\""'
```

Caveats: `terminal-features` fails silently when the outer terminal lacks
hyperlink support; the hyperlink table lives only as long as the scrollback;
needs an emitter producing OSC 8 URLs.

## Keyboard binding, works today

Opens the newest file ref in the visible pane plus recent scrollback. No
OSC 8, no mouse.

```tmux
bind-key o run-shell 'ref="$(tmux capture-pane -p -S -300 | grep -oE "[[:alnum:]_./~-]+:[0-9]+" | tail -n 1)"; if [ -n "$ref" ]; then nvim -l /path/to/openloc.nvim/bin/openloc open "$ref" --cwd "#{pane_current_path}"; fi'
```

Caveat: the grep tier here is cruder than the router's own detector; refs that
do not stat to a real file are still rejected by the router (exit 3).
