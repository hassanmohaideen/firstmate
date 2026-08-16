#!/usr/bin/env bash
# tests/fm-control-herdr-smoke.test.sh - real-herdr smoke test for the agent
# lifecycle control plane (bin/fm-control.sh).
#
# tmux is the control plane's reference backend and is covered hermetically in
# tests/fm-control.test.sh. herdr is the OTHER backend whose recovery-grade
# agent-state classifier the control plane is allowed to trust, so its
# behavior is pinned here against the REAL binary rather than a stub: whether
# an agent is running, and therefore whether a lifecycle verb may act at all,
# comes from reconciling herdr's agent registry against the process herdr owns.
#
# A herdr 0.8.0 registration carries no pid, so it cannot by itself prove the
# TUI process still runs. This test reproduces the reported defect against the
# real binary: a registration retained after a worker's TUI exits to its task
# shell must reconcile to dead (not alive), so exit is idempotent and never
# types the harness exit command into the shell, while the SAME registration
# over a genuine non-shell foreground process still reads alive. No real agent
# is launched; `pane report-agent` and a foreground `sleep` stand in for the
# registration and the running process the classifier must tell apart.
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; the 2026-07-02 incident). Skips cleanly
# when herdr or jq is missing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-control-smoke-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/hsmoke"
printf '# brief\n' > "$HOME_DIR/data/hsmoke/brief.md"

# A real git worktree so the control plane's checkpoint has a real local copy.
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b hsmoke "$WT"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-hsmoke" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"

{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=hsmoke"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=pi"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/hsmoke.meta"

run_control() {
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# --- no registered agent: the endpoint exists but hosts no agent ------------

OUT=$(run_control hsmoke exit) || fail "exit against an agent-free herdr pane should be idempotent success: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "an agent-free herdr pane should report already-stopped, got: $OUT" ;;
esac
pass "real herdr: exit on a pane with no registered agent is idempotent success"

if OUT=$(run_control hsmoke interrupt 2>&1); then
  fail "interrupt should refuse when herdr reports no agent on the pane: $OUT"
fi
case "$OUT" in
  *"nothing to interrupt"*) : ;;
  *) fail "the interrupt refusal should say there is no agent, got: $OUT" ;;
esac
pass "real herdr: interrupt refuses when herdr's own agent registry reports no agent"

# --- the defect: a stale registration over an exited TUI (idle shell) --------
#
# The reported failure: a worker's TUI exits back to its task shell, but herdr
# keeps the pane's agent registration. A 0.8.0 registration carries no pid, so
# it cannot prove the TUI process still runs; reconciled against the pane's lone
# idle task shell, the agent is gone.

herdr pane report-agent "$PANE_ID" --source fm-control-smoke --agent fm-control-smoke-agent \
  --state idle --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not register a stale agent on the exited-TUI task pane"

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = dead ] \
  || fail "a registration left over an exited TUI (idle task shell) must reconcile to dead, got '$STATE'"
pass "real herdr: a stale registration over an exited TUI classifies dead, not alive"

# exit is therefore idempotent: it reports already-stopped and must NOT type the
# harness exit command (/quit) into the task shell as its proof mechanism.
OUT=$(run_control hsmoke exit) \
  || fail "exit against an exited-TUI pane should be idempotent success: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "an exited-TUI pane should report already-stopped, got: $OUT" ;;
esac
PANE_AFTER=$(herdr pane read "$PANE_ID" --source recent --lines 100 --session "$SESSION" 2>/dev/null)
case "$PANE_AFTER" in
  *"/quit"*) fail "the idempotent exit must not type the exit command into the task shell, but the pane shows: $PANE_AFTER" ;;
esac
pass "real herdr: exit on an exited-TUI pane is idempotent and never types /quit into the shell"

if OUT=$(run_control hsmoke interrupt 2>&1); then
  fail "interrupt should refuse when the pane's TUI has exited, even with a stale registration: $OUT"
fi
case "$OUT" in
  *"nothing to interrupt"*) : ;;
  *) fail "the interrupt refusal should say there is no agent, got: $OUT" ;;
esac
pass "real herdr: a stale registration cannot authorize interrupt on an exited-TUI pane"

# --- the counterfactual: the SAME registration over a running process --------
#
# Only the process changes. A genuine non-shell foreground process group makes
# the exact same registration classify alive, proving the classifier keys on
# process ownership rather than the registration herdr happened to retain.

herdr pane run "$PANE_ID" 'sleep 300' --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not start a foreground process in the task pane"
running=
for _ in $(seq 1 50); do
  info=$(herdr pane process-info --pane "$PANE_ID" --session "$SESSION" 2>/dev/null)
  shell_pid=$(printf '%s' "$info" | jq -r '.result.process_info.shell_pid // empty')
  fpgid=$(printf '%s' "$info" | jq -r '.result.process_info.foreground_process_group_id // empty')
  if [ -n "$shell_pid" ] && [ -n "$fpgid" ] && [ "$shell_pid" != "$fpgid" ]; then
    running=1; break
  fi
  sleep 0.1
done
[ -n "$running" ] || fail "the foreground process never became the pane's foreground group"

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = alive ] \
  || fail "the same registration over a running foreground process must classify alive, got '$STATE'"
pass "real herdr: the same registration over a running process classifies alive (process ownership decides)"

OUT=$(run_control hsmoke interrupt) || fail "interrupt against a running agent should succeed: $OUT"
case "$OUT" in
  *"interrupt-delivered hsmoke harness=pi backend=herdr verified=agent-alive cancel=unconfirmed"*) : ;;
  *) fail "interrupt should report the agent-alive proof on herdr, got: $OUT" ;;
esac
pass "real herdr: interrupt delivers the harness's key and proves the running agent survived it"

herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "the control plane must never remove the endpoint it was operating on"
[ -d "$WT" ] || fail "the control plane must never remove the task's local copy"
pass "real herdr: no control verb removed the endpoint or the task's local copy"

# Last, because it types the harness exit command into a pane whose foreground
# process cannot consume it: a running agent that does not actually stop must
# fail closed rather than be reported stopped.
if OUT=$(run_control hsmoke exit 2>&1); then
  fail "exit should fail closed when the agent does not stop: $OUT"
fi
case "$OUT" in
  *"did not stop"*) : ;;
  *) fail "the exit failure should say the agent did not stop, got: $OUT" ;;
esac
pass "real herdr: a running agent that does not stop fails closed instead of being reported as stopped"

fm_backend_herdr_kill "$SESSION:$PANE_ID" 2>/dev/null || true
