# Shared by openloc-herdr and openloc-choose; sourced, never run. The caller
# sets OPENLOC_PROG (its own name, for error prefixes) before sourcing.

# The CLI's "several editors score too close" exit status; must equal
# `ambiguous` in lua/openloc/cli/exit.lua (tests/test_contract.lua pins it).
OPENLOC_EXIT_AMBIGUOUS=6

err() { printf '%s: %s\n' "$OPENLOC_PROG" "$*" >&2; }

# nvim is frequently absent from the minimal PATH a server-spawned action gets.
resolve_nvim() {
  if [ -n "${OPENLOC_NVIM:-}" ] && [ -x "${OPENLOC_NVIM:-}" ]; then
    printf '%s\n' "$OPENLOC_NVIM"
    return 0
  fi
  if command -v nvim >/dev/null 2>&1; then
    command -v nvim
    return 0
  fi
  local cand
  for cand in /opt/homebrew/bin/nvim /usr/local/bin/nvim /usr/bin/nvim; do
    if [ -x "$cand" ]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

# HERDR_BIN_PATH may be unset in older herdr versions.
resolve_herdr() {
  if [ -n "${HERDR_BIN_PATH:-}" ] && [ -x "${HERDR_BIN_PATH:-}" ]; then
    printf '%s\n' "$HERDR_BIN_PATH"
    return 0
  fi
  command -v herdr
}

# The plugin root: herdr's, else the parent of this directory.
plugin_root() {
  printf '%s\n' "${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
}

# CLI entry under root: OPENLOC_CLI, else the subdir shim, else bin/openloc
# one level up (a full checkout).
resolve_cli() {
  local root="$1" cli="${OPENLOC_CLI:-$1/cli/openloc.lua}"
  [ -f "$cli" ] || cli="$root/../bin/openloc"
  [ -f "$cli" ] || return 1
  printf '%s\n' "$cli"
}
