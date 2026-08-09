# openloc.nvim

Click `src/main.rs:42` in a terminal pane, land on that line in the Neovim
already running for that workspace: LSP, session and jumplist intact.

![Claude Code answers with a file link; Ctrl+click routes it to the running Neovim](demo/openloc-demo.gif)

The recording is real: Claude Code (instructed via `CLAUDE.md`) answers with
a markdown link, a Ctrl+click in herdr fires the link handler, and openloc
routes the jump into the Neovim already open on the left.

openloc is a routing engine with a typed CLI contract: path + line +
workspace hints in, one chosen live editor out. Producing the input (a herdr
keybinding, a Ctrl-click on a link, a terminal hint) is a thin adapter.

> **Clicking in herdr is Ctrl+click on every platform, including macOS.**
> Cmd+click never reaches herdr. Requires herdr's default
> `mouse_capture = true`.

## Install

Neovim (lazy.nvim):

```lua
{
  "Zamua/openloc.nvim",
  lazy = false, -- the socket must be claimed before the first jump arrives
  opts = {},
}
```

herdr:

```sh
herdr plugin install Zamua/openloc.nvim/herdr
```

Pin with `--ref vX.Y.Z`. There is no `plugin update`; reinstall to upgrade.

Keyboard entry point (plugins cannot ship keybindings; paste into
`~/.config/herdr/config.toml`):

```toml
[[keys.command]]
key = "prefix+o"
type = "shell"
command = "herdr plugin action invoke openloc.pick"
description = "openloc: open a file reference from this pane"
```

`pick` scans the focused pane for file references, keeps only those that
stat to a real file, and opens the newest.

## CLI

Zero-dependency Lua, executed by Neovim itself:

```
nvim -l bin/openloc open <path>[:line[:col]] [--ws ID] [--cwd PATH] [--addr SOCKET] [--choose auto|never] [--json] [--spawn split|never]
nvim -l bin/openloc open-url <url>
nvim -l bin/openloc list [--json]
nvim -l bin/openloc doctor
```

| exit | meaning |
| --- | --- |
| 0 | opened |
| 2 | no editor found and spawning disabled |
| 3 | path did not resolve to an existing file, or failed confinement |
| 4 | editor found but the open failed |
| 5 | deadline exceeded: target accepted the socket, never answered |
| 6 | ambiguous: several editors score too close (only with `--choose auto`) |
| 1 | internal or installation error |

No invocation blocks past a 5 second wall clock. `--json` names the winner,
its score and reasons, and every candidate. With no live editor, `--spawn
split` opens a Neovim in a new herdr pane; outside herdr, `OPENLOC_SPAWN=1`
launches `$VISUAL`/`$EDITOR` detached.

## Choosing between editors

`--choose auto` turns the election interactive when it is genuinely close:
with two or more eligible editors whose top scores differ by less than
`OPENLOC_PICK_MARGIN` (default 75), the CLI opens nothing and exits 6, with
`--json` carrying every candidate sorted by score. The herdr adapter runs
its opens this way and answers exit 6 with a popup menu (no keybinding
needed): pick a number, or wait for the timeout to take the top score. A
single eligible editor or a clear winner opens exactly as before, and
without a usable popup the adapter falls back to the top candidate so a
click never dead-ends. `--addr <socket>` skips the election entirely and
forces that editor.

## The URL form

```
https://openloc.invalid/o?p=<path>&l=<line>&c=<col>&ws=<workspace id>&cwd=<base dir>
```

Only `p` is required; `p` and `cwd` are percent encoded. `openloc.invalid`
never resolves, so a stray click without the handler is a DNS error page.
Non-http(s) URLs are rejected.

## Making an agent emit clickable refs

One line in the agent's instructions (for Claude Code: `CLAUDE.md` or an
output style):

```
When you reference a source location, render it as a markdown link:
[src/app.rs:42](https://openloc.invalid/o?p=src%2Fapp.rs&l=42)
Percent-encode the p value and keep the display text as path:line.
```

Ctrl+click it in herdr and the link handler routes it to openloc.

## Terminal adapters

| terminal | mechanism | file |
| --- | --- | --- |
| WezTerm | plain left click on plain text (`hyperlink_rules`) | [adapters/wezterm.md](adapters/wezterm.md) |
| kitty | clicked URL dispatch (`open-actions.conf`) | [adapters/kitty.md](adapters/kitty.md) |
| Alacritty | regex hints, Ctrl+click | [adapters/alacritty.md](adapters/alacritty.md) |
| tmux | `#{mouse_hyperlink}` or a capture-pane keybinding | [adapters/tmux.md](adapters/tmux.md) |
| iTerm2 | Semantic History, Cmd+click | [adapters/iterm2.md](adapters/iterm2.md) |

## Routing, briefly

Plugin-loaded Neovims register a socket keyed by workspace id and project
root. The CLI stats the target (never creates it), probes registry and
discovered sockets with deadline-bounded RPC, filters by the workspace's
live pane map when herdr is available, scores the rest (workspace match,
file already open, root ancestry, git root, cwd), then `tab drop` with line
clamp. Stock Neovims without the plugin work through the same inlined open.

## Troubleshooting

- `nvim -l bin/openloc doctor`: PATH, registry, socket length, CLI path.
- `:checkhealth openloc`: stale registry entries, wedged editors.
- `herdr plugin log list --plugin openloc`: what an action printed.
- A Neovim parked at a hit-enter or swapfile prompt answers no RPC: openloc
  reports it wedged (exit 5) instead of hanging. Press enter there, retry.
- No failure toasts appear: herdr renders toasts only when toast delivery is
  enabled in `~/.config/herdr/config.toml`:

  ```toml
  [ui.toast]
  delivery = "herdr"
  ```

  then `herdr server reload-config`.
- Ctrl+click works but also opens a browser tab: herdr 0.7.x forwards an
  unmatched mouse release into the pane, and agents like Claude Code open
  URLs on Ctrl+click themselves. Fixed upstream in herdr 0.8.0 (#1761);
  upgrade herdr.

## License

MIT. See [LICENSE](LICENSE).
