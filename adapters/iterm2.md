# iTerm2

Semantic History gives Cmd+click on plain text file refs with per-line cwd,
the best click context of any terminal. Plain text only, no OSC 8 needed.

Status: untested.

1. Install iTerm2 Shell Integration (required for the per-line cwd `\5`).
2. Settings > Profiles > Advanced > Semantic History: select
   "Run command..." and set:

```
/opt/homebrew/bin/nvim -l /path/to/openloc.nvim/bin/openloc open \1 --line \2 --cwd \5
```

Substitutions: `\1` clicked filename, `\2` line number, `\5` working
directory of the clicked line.

Caveats: the click is Cmd+click and iTerm2 handles it natively (herdr and its
Ctrl-click rule are not involved); Semantic History does not run a login
shell, so use absolute binary paths.
