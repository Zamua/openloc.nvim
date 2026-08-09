#!/usr/bin/env bash
# Headless test runner: every tests/test_*.lua under `nvim -l`, in an
# isolated TMPDIR/XDG tree so discovery and the registry can never touch a
# real editor. Exits nonzero if any file fails.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NVIM="${OPENLOC_TEST_NVIM:-nvim}"
if ! command -v "$NVIM" >/dev/null 2>&1; then
  echo "tests/run.sh: nvim not found (set OPENLOC_TEST_NVIM)" >&2
  exit 1
fi

BASE="$(mktemp -d /tmp/oltest-run.XXXXXX)"
export OLTEST_ISOLATED=1
export OLTEST_BASE="$BASE"
export OLTEST_PIDFILE="$BASE/pids"
: >"$OLTEST_PIDFILE"

export TMPDIR="$BASE/tmp"
export XDG_CACHE_HOME="$BASE/xdg-cache"
export XDG_RUNTIME_DIR="$BASE/xdg-run"
export XDG_STATE_HOME="$BASE/xdg-state"
export XDG_DATA_HOME="$BASE/xdg-data"
mkdir -p "$TMPDIR" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR" "$XDG_STATE_HOME" "$XDG_DATA_HOME"
chmod 700 "$XDG_RUNTIME_DIR"

# The suite must behave the same on an operator box and in CI: no ambient
# herdr/openloc state may leak in. Tests that need herdr provide a stub.
unset HERDR_PLUGIN_CONTEXT_JSON HERDR_PLUGIN_CLICKED_URL HERDR_PLUGIN_ROOT \
  HERDR_PLUGIN_ACTION_ID HERDR_PLUGIN_LINK_HANDLER_ID HERDR_PLUGIN_CONFIG_DIR \
  HERDR_PLUGIN_STATE_DIR HERDR_WORKSPACE_ID HERDR_PANE_ID HERDR_TAB_ID \
  HERDR_ENV HERDR_BIN_PATH \
  OPENLOC_ALLOW OPENLOC_STRICT OPENLOC_SPAWN OPENLOC_NVIM OPENLOC_CLI 2>/dev/null || true

cleanup() {
  # reap only pids the tests recorded, then drop the scratch tree
  if [[ -s "$OLTEST_PIDFILE" ]]; then
    while IFS= read -r pid; do
      [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
    done <"$OLTEST_PIDFILE"
  fi
  rm -rf "$BASE"
}
trap cleanup EXIT

names=()
results=()
secs=()
fail=0
for t in tests/test_*.lua; do
  echo "=== $t ==="
  start=$(date +%s)
  if "$NVIM" -l "$t"; then
    code=0
  else
    code=$?
    fail=1
  fi
  end=$(date +%s)
  names+=("$t")
  secs+=("$((end - start))")
  if [[ $code -eq 0 ]]; then
    results+=("PASS")
  else
    results+=("FAIL($code)")
  fi
  echo
done

echo "== summary =="
printf '%-28s %-9s %s\n' "test" "result" "seconds"
for i in "${!names[@]}"; do
  printf '%-28s %-9s %s\n' "${names[$i]}" "${results[$i]}" "${secs[$i]}"
done
exit "$fail"
