# Alacritty

Alacritty hints match a regex over visible text and pass the matched text as
the final argument, so bare `path:line` works with no OSC 8 anywhere.

Status: untested.

```toml
# ~/.config/alacritty/alacritty.toml
[[hints.enabled]]
regex = "[A-Za-z0-9_./~-]+\\.[A-Za-z0-9]+:[0-9]+(:[0-9]+)?"
hyperlinks = false
post_processing = true
mouse = { enabled = true, mods = "Control" }
command = { program = "nvim", args = ["-l", "/path/to/openloc.nvim/bin/openloc", "open"] }
```

Ctrl+click a highlighted ref. Alacritty appends the matched text as the last
argument, so the router receives `open src/foo.rs:42`.

Caveat: the hint command gets no pane cwd, so relative paths resolve against
the alacritty process's own `$PWD`. Absolute paths are the reliable case.
