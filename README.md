# openloc.nvim

Zellij already makes `src/main.rs:42` clickable and opens it in a new floating
pane running a fresh `$EDITOR`. openloc opens it in the Neovim you already
have running for that workspace, with your LSP, session and jumplist intact.

openloc is a routing engine with a typed CLI contract: path + line +
workspace hints in, one chosen live editor out. Every way of producing the
input (a herdr keybinding, a Ctrl-click on a link, a terminal hint) is a thin
adapter that can fail without taking the product down.

The primary entry point is keyboard, not mouse: press a key, openloc scans
the pane for file references, and the newest one that resolves to a real file
opens in the right Neovim. It works over SSH, with any agent, and with no
OSC 8 support anywhere in the stack.

> **Clicking in herdr is Ctrl+click on every platform, including macOS.**
> Cmd+click never reaches herdr; that is hardcoded upstream. Link clicks also
> require herdr's default `mouse_capture = true`.

## Install

Neovim side (lazy.nvim):

```lua
{
  "Zamua/openloc.nvim",
  lazy = false, -- the socket must be claimed before the first jump arrives
  opts = {},
}
```

herdr side (the adapter lives in the `herdr/` subdir of the same repo):

```sh
herdr plugin install Zamua/openloc.nvim/herdr
```

Pin a release with `--ref vX.Y.Z`. herdr has no `plugin update` command:
reinstall to upgrade.

Then paste the keybinding into `~/.config/herdr/config.toml` (plugins cannot
ship keybindings):

```toml
[[keys.command]]
key = "prefix+o"
type = "shell"
command = "herdr plugin action invoke openloc.pick"
description = "openloc: open a file reference from this pane"
```

`pick` scans the focused pane (or your selection), keeps only refs that stat
to a real file, and opens the newest one. With a real tty it offers a
numbered menu; herdr runs actions detached, so under the keybinding it opens
the newest match directly.

## CLI

The router is a zero-dependency Lua CLI executed by Neovim itself:

```
nvim -l bin/openloc open <path>[:line[:col]] [--ws ID] [--cwd PATH] [--line N] [--col N] [--json] [--spawn split|never]
nvim -l bin/openloc open-url <url>
nvim -l bin/openloc list [--json]
nvim -l bin/openloc doctor
```

Exit codes are contract:

| code | meaning |
| --- | --- |
| 0 | opened |
| 2 | no editor found and spawning disabled |
| 3 | path did not resolve to an existing file, or failed confinement |
| 4 | editor found but the open failed |
| 5 | deadline exceeded: the target accepted the socket but never answered |
| 1 | internal or installation error |

No invocation blocks past a 5 second wall clock. `--json` prints one object
naming the winner, its score and reasons, and every candidate (including
wedged ones). `list` shows the scored table for all live editors.

When no live editor is found, the default `--spawn split` opens a new herdr
pane running Neovim (herdr environments only). Outside herdr, setting
`OPENLOC_SPAWN=1` launches `$VISUAL`/`$EDITOR` detached through the shell;
openloc reports it as spawned and exits without waiting on the editor.

## The URL form

Adapters that click carry the ref as an https URL:

```
https://openloc.invalid/o?p=<path>&l=<line>&c=<col>&ws=<workspace id>&cwd=<base dir>
```

Only `p` is required; `p` and `cwd` are percent encoded. `openloc.invalid`
never resolves in DNS, so a stray click without the handler produces a DNS
error page, not a network request. `open-url` accepts any http(s) URL and
reads only the query params; a strict mode rejects hosts other than
`openloc.invalid`. Non-http(s) URLs are always rejected.

## Making an agent emit clickable refs

Add one line to the agent's instructions (for Claude Code: `CLAUDE.md` or an
output style):

```
When you reference a source location, render it as a markdown link:
[src/app.rs:42](https://openloc.invalid/o?p=src%2Fapp.rs&l=42)
Percent-encode the p value and keep the display text as path:line.
```

The display text stays readable; the link carries the machine-readable
target. Ctrl+click it in herdr and the link handler routes it to openloc.

## Terminal adapters

Outside herdr, thin per-terminal snippets produce the same two CLI calls.
Each file states its caveats and whether it is tested:

| terminal | mechanism | file |
| --- | --- | --- |
| WezTerm | plain left click on plain text (`hyperlink_rules`) | [adapters/wezterm.md](adapters/wezterm.md) |
| kitty | clicked URL dispatch (`open-actions.conf`) | [adapters/kitty.md](adapters/kitty.md) |
| Alacritty | regex hints, Ctrl+click | [adapters/alacritty.md](adapters/alacritty.md) |
| tmux | `#{mouse_hyperlink}` or a capture-pane keybinding | [adapters/tmux.md](adapters/tmux.md) |
| iTerm2 | Semantic History, Cmd+click | [adapters/iterm2.md](adapters/iterm2.md) |

## How routing works, briefly

Every plugin-loaded Neovim registers a socket keyed by workspace id and by
project root. The CLI resolves the target path (stat oracle: refs that do not
name an existing regular file are rejected, never created), probes registry
and discovered sockets with deadline-bounded RPC, filters by the workspace's
live pane map when herdr is available, and scores the rest (workspace match,
file already open, root ancestry, git root, cwd). The winner gets a
`tab drop` with line clamp; stock Neovim instances without the plugin still
work through the same inlined open source.

## Troubleshooting

- `nvim -l bin/openloc doctor` checks PATH, the registry, socket path
  length, the resolved CLI path and the herdr version.
- `:checkhealth openloc` reports stale registry entries and wedged editors.
- `herdr plugin log list --plugin openloc` shows what an action printed.
- A Neovim parked at a hit-enter, `-- More --` or swapfile prompt answers no
  RPC. openloc reports it as wedged (exit 5) instead of hanging; press enter
  in that Neovim and retry.

## License

MIT. See [LICENSE](LICENSE).
