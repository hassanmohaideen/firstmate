#!/usr/bin/env bash
# tests/fm-background-wait-live-e2e.test.sh - the live background-wait guard
# (live-harness-optin family).
#
# fm_busy_background_wait_tail (bin/fm-busy-lib.sh) reads a vendor-rendered
# shape, so per .agents/skills/firstmate-coding-guidelines it must be proven
# against the REAL harness: a stub can only confirm the assumption already
# written into the stub. This guard launches every installed harness whose
# shape the predicate claims (today only Claude Code) in an isolated tmux
# server, asks it to start one background shell and end its turn, and requires
# that the idle pane is read as a background wait through each independent
# signal (turn-summary row and mode footer), failing loudly with the harness
# name and version. It then confirms the same pane, once the shell has been
# stopped and the turn has settled, is no longer read as a background wait.
#
# The launched agent runs with every FM_* variable removed so its turn-end
# hooks never wake a supervising firstmate.
#
# Run explicitly with FM_BACKGROUND_WAIT_LIVE=1. One short prompt is submitted,
# so a small number of model tokens are spent; FM_BACKGROUND_WAIT_LIVE_MODEL
# picks the model (default claude-haiku-4-5-20251001). An absent harness is
# reported explicitly and skipped; a run that verified nothing fails rather than
# passing vacuously. Refresh docs/verification/supervision.md ("Background-wait
# shape") from this guard's output after any harness upgrade.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${FM_BACKGROUND_WAIT_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_BACKGROUND_WAIT_LIVE=1 to run the live background-wait guard"
  exit 0
fi

command -v tmux >/dev/null 2>&1 || { echo "not ok - FM_BACKGROUND_WAIT_LIVE=1 but tmux is not installed" >&2; exit 1; }

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

SOCKET="fm-bgw-live-$$"
SESSION="bgwlive"
WIN="$SESSION:claude"
MODEL=${FM_BACKGROUND_WAIT_LIVE_MODEL:-claude-haiku-4-5-20251001}
POLLS=${FM_BACKGROUND_WAIT_LIVE_POLLS:-90}
CHECKED=0

cleanup() {
  local sock
  sock=$(tmux -L "$SOCKET" display-message -p '#{socket_path}' 2>/dev/null || true)
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  [ -z "$sock" ] || rm -f "$sock"
}
trap cleanup EXIT
fail() { printf 'not ok - %s\n' "$1" >&2; dump; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }
cap() { tmux -L "$SOCKET" capture-pane -p -t "$WIN" 2>/dev/null; }
dump() { cap | grep '[^[:space:]]' | tail -10 | sed 's/^/#   /' >&2 || true; }
tick() { sleep 1; }

# wait_for <polls> <predicate-fn>: 0 once the predicate holds on a capture.
wait_for() {
  local limit=$1 fn=$2 i=0
  while [ "$i" -lt "$limit" ]; do
    "$fn" && return 0
    i=$((i + 1))
    tick
  done
  return 1
}
idle_with_hint() { local c; c=$(cap); ! printf '%s' "$c" | grep -q 'esc to interrupt' && printf '%s' "$c" | fm_busy_background_wait_tail claude; }
idle_no_hint() { local c; c=$(cap); ! printf '%s' "$c" | grep -q 'esc to interrupt' && ! printf '%s' "$c" | fm_busy_background_wait_tail claude; }
composer_ready() { cap | grep -q 'bypass permissions'; }

submit() {  # <text>
  tmux -L "$SOCKET" send-keys -t "$WIN" -l "$1"
  sleep 0.5
  tmux -L "$SOCKET" send-keys -t "$WIN" Enter
}

if ! command -v claude >/dev/null 2>&1; then
  note "harness absent, not verified here: claude"
else
  version=$(claude --version 2>/dev/null | head -1 || printf 'version-unknown')
  # The probe must never reach a supervising firstmate: strip every FM_*
  # variable this shell carries (FM_HOME, FM_STATE_OVERRIDE, task ids) so the
  # repo's turn-end hooks cannot write into a live home's state.
  strip=(-u CLAUDE_CODE_CHILD_SESSION)
  while IFS= read -r var; do strip+=(-u "$var"); done < <(compgen -e | grep '^FM_' || true)
  tmux -L "$SOCKET" new-session -d -s "$SESSION" -n claude -x 200 -y 50 -c "$ROOT" \
    -- env "${strip[@]}" claude --dangerously-skip-permissions --model "$MODEL" \
    || fail "claude ($version): could not launch in the isolated tmux server"
  wait_for 45 composer_ready || fail "claude ($version): composer never became ready (a trust dialog fails this check)"
  if idle_with_hint; then
    fail "claude ($version): a fresh idle pane with no background shell already reads as a background wait"
  fi
  submit 'Use the Bash tool with run_in_background=true to run exactly: sleep 600. Do not wait for it. Then end your turn with a one-word reply.'
  wait_for "$POLLS" idle_with_hint \
    || fail "claude ($version): an idle turn with a running background shell was not read as a background wait"
  tail_now=$(cap | grep -v '^[[:space:]]*$' | tail -12)
  summary_rows=$(printf '%s\n' "$tail_now" | grep -E '[0-9]+ shells? still running' || true)
  footer_rows=$(printf '%s\n' "$tail_now" | grep -E '·[[:space:]]*[0-9]+ shells?[[:space:]]*(·|$)' | grep -v 'still running' || true)
  [ -n "$summary_rows" ] || fail "claude ($version): the turn-summary signal ('N shell still running') is gone"
  [ -n "$footer_rows" ] || fail "claude ($version): the mode-footer signal ('· N shell ·') is gone"
  printf '%s\n' "$summary_rows" | fm_busy_background_wait_tail claude \
    || fail "claude ($version): the turn-summary signal alone no longer carries the verdict"
  printf '%s\n' "$footer_rows" | fm_busy_background_wait_tail claude \
    || fail "claude ($version): the mode-footer signal alone no longer carries the verdict"
  CHECKED=$((CHECKED + 1))
  pass "claude ($version): idle with a background shell reads as a background wait through both independent signals"

  submit 'Stop every background shell you started (use the tool that kills background tasks), then end your turn with a one-word reply.'
  wait_for "$POLLS" idle_no_hint \
    || fail "claude ($version): the pane still reads as a background wait after its shell was stopped"
  CHECKED=$((CHECKED + 1))
  pass "claude ($version): a settled turn with no background shell is not read as a background wait"
fi

[ "$CHECKED" -gt 0 ] || { echo "not ok - no installed harness was verified; refusing a vacuous pass" >&2; exit 1; }
echo "all fm-background-wait-live-e2e checks passed ($CHECKED)"
