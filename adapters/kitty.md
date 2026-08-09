# kitty

kitty routes clicked URLs through `open-actions.conf`, so an emitted
`https://openloc.invalid/...` link (OSC 8 or plain text) can invoke the
router. kitty has no regex linkifier for bare `path:line` text, so refs must
arrive as URLs (see the emitter snippet in the README).

Status: untested.

```
# ~/.config/kitty/open-actions.conf
protocol https
url ^https://openloc\.invalid/
action launch --type=background nvim -l /path/to/openloc.nvim/bin/openloc open-url ${URL}
```

Caveats:

- Needs OSC 8 links or plain-text URLs; bare `path:line` is never clickable
  in kitty.
- The launched command inherits kitty's cwd, not the pane's; resolution
  relies on absolute paths or the URL's `cwd` param.
- Depending on kitty config, links open on plain click or ctrl+shift+click.
