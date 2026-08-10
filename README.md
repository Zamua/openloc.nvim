# openloc.nvim

Click `src/main.rs:42` in a terminal pane, land on that line in the Neovim
already running for that workspace.

![Claude Code answers with a file link; Ctrl+click routes it to the running Neovim](demo/openloc-demo.gif)

The recording is real: Claude Code answers with a file link, Ctrl+click in
herdr fires it, openloc jumps the Neovim on the left to the line.

## Install

1. Neovim plugin (lazy.nvim):

   ```lua
   { "Zamua/openloc.nvim", lazy = false, opts = {} }
   ```

2. herdr plugin:

   ```sh
   herdr plugin install Zamua/openloc.nvim/herdr
   ```

3. Tell your agent to emit clickable refs. For Claude Code, add one line to
   `CLAUDE.md`:

   ```
   When you reference a source location, render it as a markdown link:
   [src/app.rs:42](https://openloc.invalid/o?p=src%2Fapp.rs&l=42)
   Percent-encode the p value and keep the display text as path:line.
   ```

4. Optional but recommended: enable herdr toasts so failed opens explain
   themselves. In `~/.config/herdr/config.toml`:

   ```toml
   [ui.toast]
   delivery = "herdr"
   ```

   then `herdr server reload-config`.

Clicking in herdr is **Ctrl+click** on every platform, including macOS.

Optional keyboard entry point (paste into `~/.config/herdr/config.toml`):

```toml
[[keys.command]]
key = "prefix+o"
type = "shell"
command = "herdr plugin action invoke openloc.pick"
description = "openloc: open a file reference from this pane"
```

## What it does

openloc routes a `path:line` to the right Neovim among the ones already
running: it scores every live editor (workspace match, file already open,
project ancestry) and jumps the winner. When two editors are genuinely
close it pops a chooser. Works with any agent and any terminal that can
produce a click or a keybinding; herdr is the first-class adapter.

Full CLI, URL format, terminal adapters (WezTerm, kitty, Alacritty, tmux,
iTerm2), routing details and troubleshooting: [docs/reference.md](docs/reference.md).

## License

MIT. See [LICENSE](LICENSE).
