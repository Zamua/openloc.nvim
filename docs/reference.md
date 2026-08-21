# openloc reference

The front-page README covers install and the demo. Everything else is here.

## CLI

Zero-dependency Lua, executed by Neovim itself:

```
nvim -l bin/openloc open <path>[:line[:col]] [--ws ID] [--session PID] [--cwd PATH] [--addr SOCKET] [--choose auto|never] [--json] [--spawn split|never]
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

Only `p` is required. It takes an absolute path, or one relative to a
click-time base: the herdr worktree checkout, the workspace cwd, the focused
pane cwd, or `cwd`. It may also carry the location inline as
`<path>:<line>[:<col>]`, making `l` and `c` redundant. Percent encoding is
needed only for characters the query grammar claims, `?` `#` `&` `%` and
space; a plain `/` is legal and needs no escape. Prefer the shortest spelling
that resolves, because a terminal soft-wraps a long URL and a link matcher
reading wrapped cells then sees a fragment. `openloc.invalid` never resolves,
so a stray click without the handler is a DNS error page. Non-http(s) URLs
are rejected.

## Making an agent emit clickable refs

Claude Code: install the bundled plugin (`/plugin marketplace add
Zamua/openloc.nvim`, then `/plugin install openloc@openloc`). Its
SessionStart hook injects the instruction below automatically;
`OPENLOC_LINKS=off` in the environment disables it.

Any other agent, or without the plugin, add one line to the agent's
instructions:

```
When you reference a source location, render it as a markdown link whose
display text and p value are the SAME string:
[apps/web/src/app.ts:42](https://openloc.invalid/o?p=apps/web/src/app.ts:42)
PATH is the path as it resolves from the current working directory, or an
absolute path. Spell it exactly as it appears in tool output: do not
percent-encode it, do not abbreviate it, and do not shorten the display text.
```

Ctrl+click it in herdr and the link handler routes it to openloc. One string
written twice, with nothing to derive and nothing to keep in sync.

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
discovered sockets with deadline-bounded RPC, drops everything belonging to
another herdr session, filters what is left by the workspace's live pane map
when herdr is available, scores the rest (workspace match, file already open,
root ancestry, git root, cwd), then `tab drop` with line clamp. Stock Neovims
without the plugin work through the same inlined open.

Session scope comes first because herdr runs one server per named session and
each server numbers its workspaces from `w1` independently, so `w4` in one
session and `w4` in another name unrelated panes, and `herdr pane list` only
ever answers for one session. A pane's processes descend from the server that
owns them, so the nearest `herdr` ancestor of a pid identifies its session
without asking herdr anything; `--session PID` overrides that reading. Without
it, five editors in a sibling session read as five plausible candidates and
raise the chooser instead of letting the spawn fallback open one here.

## Troubleshooting

- `nvim -l bin/openloc doctor`: PATH, registry, socket length, CLI path.
- `:checkhealth openloc`: stale registry entries, wedged editors.
- `herdr plugin log list --plugin openloc`: what an action printed.
- A Neovim parked at a hit-enter or swapfile prompt answers no RPC: openloc
  reports it wedged (exit 5) instead of hanging. Press enter there, retry.
- A chooser offering editors from workspaces you do not recognise means those
  editors belong to another herdr session. `openloc list` prints `sess=` per
  candidate and `openloc doctor` prints the session it resolved for itself;
  a `-` in either means no `herdr` ancestor was found, and sibling sessions
  cannot be told apart.
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

