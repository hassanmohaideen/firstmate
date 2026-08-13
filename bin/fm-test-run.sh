#!/usr/bin/env bash
# fm-test-run.sh - single owner of Firstmate's behavior-test runner, lane
# composition, mixed complete-regression scheduling, timing and duration-budget
# reporting, and the complete-regression coverage guard.
#
# Selection modes (exactly one of: --portable, --all, --family, --changed,
# --lane, --proven-isolated, or script paths):
#   fm-test-run.sh                         (defaults to --changed --base origin/main)
#   fm-test-run.sh --portable              (complete local portable regression)
#   fm-test-run.sh --all                   (complete regression including real Herdr)
#   fm-test-run.sh --family <name>
#   fm-test-run.sh --changed [--base <git-ref>]
#   fm-test-run.sh --lane portable-parallel-1|portable-parallel-2|portable-serial
#   fm-test-run.sh --lane portable-serial-<k>of<n>   (one CI serial shard)
#   fm-test-run.sh --lane real-herdr-gated-<k>of<n>  (one CI real-Herdr shard)
#   fm-test-run.sh --proven-isolated
#   fm-test-run.sh tests/<name>.test.sh [more scripts...]
#
# Inspection (no execution):
#   fm-test-run.sh --list --all
#   fm-test-run.sh --list --family <name>
#   fm-test-run.sh --list --lane portable-parallel-1
#   fm-test-run.sh --list-families
#   fm-test-run.sh --list-lanes
#   fm-test-run.sh --check-coverage
#
# Aggregation (no suite execution):
#   fm-test-run.sh --aggregate-json <out.json> <lane.json> [more lane.json...]
#
# Options:
#   --json <path>   write a deterministic timing artifact after the run
#   --list          print selected script paths (one per line) and exit 0
#   --base <ref>    with --changed, compare against this ref (default: origin/main)
#   --exclude-family <name>
#                   drop scripts whose primary family matches <name> after selection
#                   (repeatable; portable CI lanes exclude real-herdr-gated so the
#                   dedicated required Herdr shards own that coverage)
#   --fail-on-gate-skip <token>
#                   after each script, fail the run if any output line contains
#                   "skip: <token>" (e.g. --fail-on-gate-skip 'herdr not found').
#                   Every required Herdr CI shard uses this so a missing pin cannot
#                   silently pass as a gate skip.
#   --jobs N        run proven-isolated scripts with up to N concurrent workers.
#                   --portable and --all default to 4 and automatically keep
#                   every other selected script strictly serial. Other modes
#                   default to 1 and refuse N>1 for mixed/stateful selections.
#                   Cap is 8.
#   --enforce-duration-budgets
#                   fail after functional results are reported when a script
#                   exceeds or lacks a data-driven baseline budget. The default
#                   warns.
#   -h, --help      print this header
#
# Per-script machine-parseable markers (stdout):
#   FM_TEST_BEGIN <iso8601> <script> family=<family> expected_gate_skip=<class>
#   FM_TEST_END <iso8601> <script> exit=<code> duration_ms=<n> gate_skip=<true|false>
#
# After all scripts (stdout):
#   FM_TEST_SUMMARY total=<n> failed=<n> skipped_gate=<n> duration_ms=<n>
#   FM_TEST_SUMMARY_FAMILY family=<name> count=<n> duration_ms=<n> failed=<n>
#   FM_TEST_SLOWEST rank=<k> script=<path> duration_ms=<n>
#   FM_TEST_BUDGET_SUMMARY checked=<n> exceeded=<n> missing=<n> mode=warn|enforce
#
# Exit status is non-zero if any selected script exits non-zero, a configured
# --fail-on-gate-skip token appears, or enforced duration budgets are exceeded
# or missing. Other gate skips (first meaningful line matching ^skip:) remain
# successful and are counted as skipped_gate.
#
# Family labels, the changed-file map, and production CI shard composition live
# in this script only (one owner). The proven-isolated candidate set remains
# owned by bin/fm-test-isolation-proof.sh; portable parallel shards are a
# duration-balanced partition of that exact set (see docs/fm-test-portable-shards.md).
#
# portable-serial stays strictly serial. Its CI shards (portable-serial-<k>of<n>)
# split it across separate runners, so two of its stateful scripts still never
# share a machine. The required real-Herdr family splits the same way
# (real-herdr-gated-<k>of<n>): each shard is strictly serial on its own runner
# with its own default session, snapshot, and cleanup. This script owns each
# <n>: a lane whose <n> disagrees with the configured shard count is refused,
# so a CI matrix cannot silently drop a shard.
# --changed is conservative: it over-selects related families rather than
# under-selecting, and never expands to the complete suite.
# --portable is the routine complete local path: it excludes real-herdr-gated
# because the dedicated required CI shards own that integration coverage.
# --all remains the explicit operator path that includes that family.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

MODE=
LIST_ONLY=0
LIST_FAMILIES=0
LIST_LANES=0
CHECK_COVERAGE=0
AGGREGATE_OUT=
FAMILY=
LANE=
BASE_REF=origin/main
JSON_PATH=
SCRIPTS=()
EXCLUDE_FAMILIES=()
FAIL_ON_GATE_SKIP=
JOBS=
JOBS_EXPLICIT=0
JOBS_MAX=8
DURATION_BUDGET_MODE=warn
DURATION_BUDGET_CHECKED=0
DURATION_BUDGET_EXCEEDED=0
DURATION_BUDGET_MISSING=0

# How many separate-runner shards the portable serial remainder splits into.
# One owner: CI lane names carry this count and are refused when they disagree.
PORTABLE_SERIAL_SHARDS=10

# How many separate-runner shards the required real-Herdr family splits into.
# Same contract as the serial shards: each shard is strictly serial in itself,
# separate runners keep every real-Herdr script on its own machine with its own
# default session and cleanup, and a lane whose "ofN" disagrees is refused.
REAL_HERDR_SHARDS=2

# Balance hint for a portable-serial script with no measured duration, close to
# the measured per-script mean so a newly added test neither starves nor
# overloads the shard it lands in.
PORTABLE_SERIAL_DEFAULT_WEIGHT_MS=20000

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-test-run: %s\n' "$*" >&2
  exit 2
}

log() {
  printf 'fm-test-run: %s\n' "$*" >&2
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time() * 1000))'
  else
    # Second precision only when python3 is unavailable.
    echo $(($(date +%s) * 1000))
  fi
}

# Primary family for one tests/*.test.sh basename. Unmapped scripts are
# unclassified so new tests are still runnable and visible in summaries.
# The _into form sets FAMILY_FOR_BASENAME without a command substitution so
# whole-suite listing loops stay cheap; the printing wrapper keeps every
# existing call site working.
family_for_basename_into() {
  case "$1" in
    fm-arm-pretool-check.test.sh|fm-ask-user-authority.test.sh|\
    fm-brief.test.sh|fm-vendor-auth-probe.test.sh|\
    fm-calm-pi-extension.test.sh|fm-cd-pretool-check.test.sh|\
    fm-classify-decision-key.test.sh|\
    fm-composer-ghost.test.sh|fm-composer-lib.test.sh|\
    fm-crew-state.test.sh|fm-decision-hold-lifecycle.test.sh|\
    fm-documentation-audiences.test.sh|fm-ensure-agents-md.test.sh|fm-grok-harness.test.sh|\
    fm-kimi-harness.test.sh|fm-muse-harness.test.sh|fm-herdr-lab.test.sh|fm-lint.test.sh|\
    fm-operational-input.test.sh|fm-pi-primary-types.test.sh|\
    fm-rtk.test.sh|fm-rtk-fs-events.test.sh|fm-rtk-exec-trace.test.sh|\
    fm-send-popup-settle.test.sh|fm-send-settle.test.sh|\
    fm-subagent-pretool-check.test.sh|\
    fm-supervision-instructions.test.sh|fm-task-delivery.test.sh|\
    fm-tmux-submit-busy.test.sh|fm-trace-context-lib.test.sh|\
    fm-transition-lib.test.sh|\
    fm-test-run.test.sh|fm-test-isolation-proof.test.sh)
      FAMILY_FOR_BASENAME=pure-contract-unit
      ;;
    fm-daemon.test.sh|fm-discord-bot.test.sh|fm-guard-stale-banner.test.sh|fm-pi-watch-extension.test.sh|\
    fm-session-lock-ancestry.test.sh|\
    fm-supervision-events.test.sh|fm-turnend-guard.test.sh|fm-wake-daemon-lifecycle-e2e.test.sh|\
    fm-wake-queue.test.sh|fm-watch-arm.test.sh|fm-watch-checkpoint.test.sh|fm-watch-triage.test.sh|\
    fm-watcher-lock.test.sh|fm-inactive-reconcile.test.sh)
      FAMILY_FOR_BASENAME=watcher-wake-lock
      ;;
    fm-afk-inject-herdr-e2e.test.sh|fm-afk-launch.test.sh|fm-backend-autodetect-smoke.test.sh|\
    fm-backend-herdr-eventwait-smoke.test.sh|fm-backend-herdr-focus-flash-e2e.test.sh|\
    fm-backend-herdr-presentation-e2e.test.sh|fm-backend-herdr-launcher-workspace-e2e.test.sh|\
    fm-backend-herdr-prune-safety-e2e.test.sh|fm-backend-herdr-respawn-idem-e2e.test.sh|\
    fm-herdr-session-cleanup-e2e.test.sh|\
    fm-backend-herdr-smoke.test.sh|fm-backend-herdr-workspace-per-home-e2e.test.sh|\
    fm-control-herdr-smoke.test.sh)
      FAMILY_FOR_BASENAME=real-herdr-gated
      ;;
    fm-backlog-handoff.test.sh|fm-on.test.sh|fm-remote-backlog-handoff.test.sh|\
    fm-remote-doctor.test.sh|fm-remote-job.test.sh|fm-remote-job-orphan-reap.test.sh|\
    fm-remote-reply.test.sh|fm-remote-secondmate-lifecycle-e2e.test.sh|\
    fm-remote-secondmate-trace-context.test.sh|\
    fm-secondmate-harness.test.sh|fm-secondmate-lifecycle-e2e.test.sh|\
    fm-secondmate-liveness.test.sh|fm-secondmate-safety.test.sh|fm-secondmate-sync.test.sh|\
    fm-startup-memory-budget.test.sh|fm-stow-cascade.test.sh|\
    fm-send-secondmate-marker.test.sh|fm-shared-captain-inheritance.test.sh)
      FAMILY_FOR_BASENAME=secondmate
      ;;
    fm-bootstrap.test.sh|fm-fleet-sync.test.sh|fm-gate-refuse.test.sh|fm-gotmp.test.sh|\
    fm-session-start.test.sh|fm-sessionstart-nudge.test.sh|fm-startup-network.test.sh|\
    fm-tangle-guard.test.sh|fm-update.test.sh)
      FAMILY_FOR_BASENAME=session-bootstrap
      ;;
    fm-afk-pi-herdr-return-e2e.test.sh|\
    fm-cmux-claude-composer-live-e2e.test.sh|\
    fm-composer-matrix-live-e2e.test.sh|\
    fm-codex-continuity-live-e2e.test.sh|fm-grok-continuity-live-e2e.test.sh|\
    fm-grok-stop-live-e2e.test.sh|fm-harness-liveness-drift-live-e2e.test.sh|\
    fm-muse-signals-live-e2e.test.sh|\
    fm-herdr-version-floor-live-e2e.test.sh|\
    fm-opencode-primary-live-e2e.test.sh|fm-pi-primary-live-e2e.test.sh|\
    fm-sessionstart-hook-live-e2e.test.sh|fm-sessionstart-instruction-refresh-live-e2e.test.sh|\
    fm-playop-dispatch-live-e2e.test.sh|fm-quota-array-dispatch-live-e2e.test.sh|\
    fm-send-secondmate-marker-herdr-e2e.test.sh)
      FAMILY_FOR_BASENAME=live-harness-optin
      ;;
    fm-backend-herdr.test.sh|fm-backend-tmux-smoke.test.sh|fm-backend.test.sh|\
    fm-tmux-agent-liveness.test.sh|\
    fm-control.test.sh|fm-control-relaunch.test.sh|\
    fm-herdr-session-cleanup.test.sh|fm-send-resolve-key.test.sh|fm-send-strict.test.sh|fm-spawn-batch.test.sh|\
    fm-spawn-dispatch-profile.test.sh|\
    fm-trace-context-spawn.test.sh|fm-spawn-worktree-settle.test.sh|\
    fm-teardown-endpoint-safety.test.sh)
      FAMILY_FOR_BASENAME=backend-dispatch
      ;;
    fm-pr-check-security.test.sh|fm-pr-merge.test.sh|fm-review-diff.test.sh|\
    fm-teardown.test.sh|fm-x-mode.test.sh)
      FAMILY_FOR_BASENAME=pr-forge
      ;;
    fm-afk-inject-e2e.test.sh|fm-afk-return.test.sh)
      FAMILY_FOR_BASENAME=afk
      ;;
    fm-bearings-snapshot.test.sh|fm-fleet-snapshot-view.test.sh)
      FAMILY_FOR_BASENAME=snapshot-bearings
      ;;
    fm-backend-cmux.test.sh|fm-backend-cmux-smoke.test.sh)
      FAMILY_FOR_BASENAME=cmux
      ;;
    fm-backend-zellij.test.sh|fm-backend-zellij-smoke.test.sh)
      FAMILY_FOR_BASENAME=zellij
      ;;
    fm-backend-orca.test.sh)
      FAMILY_FOR_BASENAME=orca
      ;;
    *)
      FAMILY_FOR_BASENAME=unclassified
      ;;
  esac
}

family_for_basename() {
  family_for_basename_into "$1"
  printf '%s\n' "$FAMILY_FOR_BASENAME"
}

expected_gate_skip_for_family() {
  case "$1" in
    real-herdr-gated) printf '%s\n' herdr ;;
    live-harness-optin) printf '%s\n' optin-env ;;
    cmux|zellij|orca) printf '%s\n' optional-binary ;;
    snapshot-bearings) printf '%s\n' optional-binary ;;
    *) printf '%s\n' none ;;
  esac
}

list_known_families() {
  cat <<'EOF'
pure-contract-unit
watcher-wake-lock
real-herdr-gated
secondmate
session-bootstrap
live-harness-optin
backend-dispatch
pr-forge
afk
snapshot-bearings
cmux
zellij
orca
unclassified
EOF
}

list_known_lanes() {
  local i
  printf '%s\n' portable-parallel-1
  printf '%s\n' portable-parallel-2
  printf '%s\n' portable-serial
  i=1
  while [ "$i" -le "$PORTABLE_SERIAL_SHARDS" ]; do
    printf 'portable-serial-%sof%s\n' "$i" "$PORTABLE_SERIAL_SHARDS"
    i=$((i + 1))
  done
  printf '%s\n' real-herdr-gated
  i=1
  while [ "$i" -le "$REAL_HERDR_SHARDS" ]; do
    printf 'real-herdr-gated-%sof%s\n' "$i" "$REAL_HERDR_SHARDS"
    i=$((i + 1))
  done
}

# Exact proven-isolated candidate set (same paths as
# bin/fm-test-isolation-proof.sh --list). Do not expand without a new concurrent
# isolation proof archive.
list_proven_isolated() {
  cat <<'EOF'
tests/fm-arm-pretool-check.test.sh
tests/fm-backend-herdr.test.sh
tests/fm-brief.test.sh
tests/fm-cd-pretool-check.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-composer-lib.test.sh
tests/fm-crew-state.test.sh
tests/fm-decision-hold-lifecycle.test.sh
tests/fm-ensure-agents-md.test.sh
tests/fm-grok-harness.test.sh
tests/fm-herdr-lab.test.sh
tests/fm-lint.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-pr-merge.test.sh
tests/fm-review-diff.test.sh
tests/fm-send-popup-settle.test.sh
tests/fm-send-settle.test.sh
tests/fm-send-strict.test.sh
tests/fm-spawn-batch.test.sh
tests/fm-supervision-instructions.test.sh
tests/fm-test-run.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-transition-lib.test.sh
tests/fm-x-mode.test.sh
EOF
}

# Portable parallel shard 1: LPT balance of the proven-isolated set using the
# current concurrent-proof durations in docs/fm-test-isolation-proof.json.
# Execution order is longest first so wall-clock stays near the balanced sum.
list_portable_parallel_1() {
  cat <<'EOF'
tests/fm-x-mode.test.sh
tests/fm-cd-pretool-check.test.sh
tests/fm-decision-hold-lifecycle.test.sh
tests/fm-test-run.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-grok-harness.test.sh
tests/fm-lint.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-review-diff.test.sh
tests/fm-brief.test.sh
tests/fm-transition-lib.test.sh
EOF
}

# Portable parallel shard 2: the complementary LPT half of the proven set.
list_portable_parallel_2() {
  cat <<'EOF'
tests/fm-backend-herdr.test.sh
tests/fm-arm-pretool-check.test.sh
tests/fm-crew-state.test.sh
tests/fm-herdr-lab.test.sh
tests/fm-pr-merge.test.sh
tests/fm-send-popup-settle.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-send-settle.test.sh
tests/fm-send-strict.test.sh
tests/fm-spawn-batch.test.sh
tests/fm-supervision-instructions.test.sh
tests/fm-ensure-agents-md.test.sh
tests/fm-composer-lib.test.sh
EOF
}

# Membership test against the proven-isolated set, cached once per process so
# whole-suite listing loops do not pay a subshell per script.
PROVEN_ISOLATED_SET_CACHE=
is_proven_isolated_script() {
  [ -n "$PROVEN_ISOLATED_SET_CACHE" ] || PROVEN_ISOLATED_SET_CACHE=$(list_proven_isolated)
  case "$PROVEN_ISOLATED_SET_CACHE" in
    "$1"|"$1"$'\n'*|*$'\n'"$1"|*$'\n'"$1"$'\n'*) return 0 ;;
  esac
  return 1
}

# The portable serial remainder: every tests/*.test.sh that is neither
# proven-isolated nor real-herdr-gated. Watcher, lock, AFK, real tmux, daemon,
# secondmate lifecycle, bootstrap, live-harness opt-in, GUI-backend, and other
# unproven work stays here. Derived rather than enumerated so a newly added test
# lands here by default instead of falling out of every lane.
list_portable_serial() {
  local s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    family_for_basename_into "${s##*/}"
    if [ "$FAMILY_FOR_BASENAME" = "real-herdr-gated" ]; then
      continue
    fi
    if is_proven_isolated_script "$s"; then
      continue
    fi
    printf '%s\n' "$s"
  done < <(all_repo_tests)
}

# The required real-Herdr family as a listing, for shard assignment.
# shellcheck disable=SC2329 # Invoked indirectly through lpt_shard_assignments.
list_real_herdr_gated() {
  local s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    family_for_basename_into "${s##*/}"
    [ "$FAMILY_FOR_BASENAME" = real-herdr-gated ] || continue
    printf '%s\n' "$s"
  done < <(all_repo_tests)
}

# Measured portable-serial script durations in milliseconds, from the CI timing
# artifact recorded in docs/fm-test-portable-shards.md. These are balance hints
# only: the shard partition stays complete and disjoint whatever they say, so a
# stale hint costs balance rather than coverage. That doc owns the refresh
# procedure.
portable_serial_weight_hints() {
  cat <<'EOF'
tests/fm-afk-inject-e2e.test.sh 35158
tests/fm-afk-pi-herdr-return-e2e.test.sh 152
tests/fm-afk-return.test.sh 3773
tests/fm-ask-user-authority.test.sh 206
tests/fm-backend-cmux-smoke.test.sh 46
tests/fm-backend-cmux.test.sh 2268
tests/fm-backend-orca.test.sh 15544
tests/fm-backend-tmux-smoke.test.sh 656
tests/fm-backend-zellij-smoke.test.sh 35
tests/fm-backend-zellij.test.sh 8436
tests/fm-backend.test.sh 17423
tests/fm-backlog-handoff.test.sh 3272
tests/fm-bearings-snapshot.test.sh 57310
tests/fm-bootstrap.test.sh 24895
tests/fm-busy-adapter-wiring.test.sh 14845
tests/fm-busy-state.test.sh 1482
tests/fm-calm-pi-extension.test.sh 166
tests/fm-classify-decision-key.test.sh 560
tests/fm-claude-stop-autoarm-live-e2e.test.sh 39
tests/fm-claude-stop-autoarm.test.sh 60609
tests/fm-cmux-claude-composer-live-e2e.test.sh 49
tests/fm-codex-continuity-live-e2e.test.sh 24
tests/fm-composer-matrix-live-e2e.test.sh 38
tests/fm-control-relaunch.test.sh 29506
tests/fm-control.test.sh 34081
tests/fm-daemon.test.sh 14894
tests/fm-discord-bot.test.sh 46859
tests/fm-documentation-audiences.test.sh 693
tests/fm-fleet-snapshot-view.test.sh 15503
tests/fm-fleet-sync.test.sh 29043
tests/fm-gate-refuse.test.sh 2950
tests/fm-gitignore-config.test.sh 70
tests/fm-gotmp.test.sh 709
tests/fm-grok-continuity-live-e2e.test.sh 35
tests/fm-grok-stop-live-e2e.test.sh 32
tests/fm-guard-stale-banner.test.sh 5865
tests/fm-harness-liveness-drift-live-e2e.test.sh 32
tests/fm-herdr-session-cleanup.test.sh 6539
tests/fm-herdr-version-floor-live-e2e.test.sh 26
tests/fm-inactive-reconcile.test.sh 44132
tests/fm-kimi-harness.test.sh 19755
tests/fm-muse-harness.test.sh 27450
tests/fm-muse-signals-live-e2e.test.sh 37
tests/fm-on.test.sh 5982
tests/fm-opencode-primary-live-e2e.test.sh 14
tests/fm-operational-input.test.sh 144
tests/fm-pending-reply.test.sh 17092
tests/fm-pi-primary-live-e2e.test.sh 14
tests/fm-pi-watch-extension.test.sh 17415
tests/fm-playop-dispatch-live-e2e.test.sh 33
tests/fm-pr-check-security.test.sh 210119
tests/fm-procevent-when.test.sh 21331
tests/fm-procevent.test.sh 44376
tests/fm-project-origin.test.sh 148
tests/fm-public-followup.test.sh 38154
tests/fm-quota-array-dispatch-live-e2e.test.sh 35
tests/fm-remote-backlog-handoff.test.sh 16503
tests/fm-remote-doctor.test.sh 4827
tests/fm-remote-entrypoint.test.sh 123
tests/fm-remote-job-orphan-reap.test.sh 2542
tests/fm-remote-job.test.sh 48166
tests/fm-remote-reply.test.sh 49434
tests/fm-remote-secondmate-lifecycle-e2e.test.sh 152175
tests/fm-remote-secondmate-parent-binding.test.sh 13086
tests/fm-remote-secondmate-trace-context.test.sh 36374
tests/fm-rtk-exec-trace.test.sh 38
tests/fm-rtk-fs-events.test.sh 3974
tests/fm-rtk.test.sh 9394
tests/fm-secondmate-harness.test.sh 101340
tests/fm-secondmate-lifecycle-e2e.test.sh 6240
tests/fm-secondmate-liveness.test.sh 8350
tests/fm-secondmate-safety.test.sh 44770
tests/fm-secondmate-sync.test.sh 11881
tests/fm-send-resolve-key.test.sh 19381
tests/fm-send-secondmate-marker-herdr-e2e.test.sh 62
tests/fm-send-secondmate-marker.test.sh 8864
tests/fm-session-lock-ancestry.test.sh 669
tests/fm-session-start.test.sh 144641
tests/fm-sessionstart-hook-live-e2e.test.sh 33
tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh 50
tests/fm-sessionstart-nudge.test.sh 17018
tests/fm-shared-captain-inheritance.test.sh 5347
tests/fm-spawn-dispatch-profile.test.sh 52026
tests/fm-spawn-pool-base-freshen.test.sh 12567
tests/fm-spawn-worktree-settle.test.sh 4910
tests/fm-startup-memory-budget.test.sh 4404
tests/fm-startup-network.test.sh 48428
tests/fm-stow-cascade.test.sh 3077
tests/fm-subagent-pretool-check.test.sh 607
tests/fm-supervision-events.test.sh 1317
tests/fm-tangle-guard.test.sh 6987
tests/fm-task-delivery.test.sh 2192
tests/fm-teardown-endpoint-safety.test.sh 3297
tests/fm-teardown.test.sh 73107
tests/fm-test-fixture-cleanup.test.sh 563
tests/fm-test-isolation-proof.test.sh 299
tests/fm-tmux-agent-liveness.test.sh 1039
tests/fm-trace-context-lib.test.sh 224
tests/fm-trace-context-spawn.test.sh 42180
tests/fm-turnend-guard.test.sh 39640
tests/fm-update.test.sh 4994
tests/fm-vendor-auth-probe.test.sh 43344
tests/fm-wake-daemon-lifecycle-e2e.test.sh 9358
tests/fm-wake-drain-open-decisions-cursor.test.sh 8077
tests/fm-wake-drain-open-decisions.test.sh 6574
tests/fm-wake-queue.test.sh 27451
tests/fm-watch-arm.test.sh 50289
tests/fm-watch-checkpoint.test.sh 7321
tests/fm-watch-triage.test.sh 145269
tests/fm-watcher-lock.test.sh 88221
EOF
}

real_herdr_duration_hints() {
  cat <<'EOF'
tests/fm-afk-inject-herdr-e2e.test.sh 61514
tests/fm-afk-launch.test.sh 33459
tests/fm-backend-autodetect-smoke.test.sh 7678
tests/fm-backend-herdr-eventwait-smoke.test.sh 1703
tests/fm-backend-herdr-launcher-workspace-e2e.test.sh 33330
tests/fm-backend-herdr-prune-safety-e2e.test.sh 6385
tests/fm-backend-herdr-respawn-idem-e2e.test.sh 2222
tests/fm-backend-herdr-smoke.test.sh 4699
tests/fm-backend-herdr-workspace-per-home-e2e.test.sh 15487
tests/fm-control-herdr-smoke.test.sh 5821
tests/fm-herdr-session-cleanup-e2e.test.sh 2047
tests/fm-backend-herdr-focus-flash-e2e.test.sh 3760
tests/fm-backend-herdr-presentation-e2e.test.sh 260721
EOF
}

proven_isolated_duration_hints() {
  cat <<'EOF'
tests/fm-arm-pretool-check.test.sh 46788
tests/fm-backend-herdr.test.sh 37224
tests/fm-brief.test.sh 2224
tests/fm-cd-pretool-check.test.sh 34207
tests/fm-composer-ghost.test.sh 9065
tests/fm-composer-lib.test.sh 64
tests/fm-crew-state.test.sh 25365
tests/fm-decision-hold-lifecycle.test.sh 30771
tests/fm-ensure-agents-md.test.sh 581
tests/fm-grok-harness.test.sh 6251
tests/fm-herdr-lab.test.sh 15422
tests/fm-lint.test.sh 5237
tests/fm-pi-primary-types.test.sh 2945
tests/fm-pr-merge.test.sh 8564
tests/fm-review-diff.test.sh 2875
tests/fm-send-popup-settle.test.sh 5644
tests/fm-send-settle.test.sh 2911
tests/fm-send-strict.test.sh 2747
tests/fm-spawn-batch.test.sh 855
tests/fm-supervision-instructions.test.sh 703
tests/fm-test-run.test.sh 15674
tests/fm-tmux-submit-busy.test.sh 4816
tests/fm-transition-lib.test.sh 248
tests/fm-x-mode.test.sh 52939
EOF
}

# All measured hint tables in first-match-wins order.
all_duration_hints() {
  portable_serial_weight_hints
  proven_isolated_duration_hints
  real_herdr_duration_hints
}

script_duration_baseline_ms() {
  local ms
  ms=$(all_duration_hints | awk -v want="$1" '$1 == want { print $2; exit }')
  [ -n "$ms" ] || return 1
  printf '%s\n' "$ms"
}

# A budget is deliberately generous across macOS/Linux and loaded runners.
# Two times the measured baseline plus ten seconds catches material regressions
# without turning ordinary machine variance into a brittle wall-clock test.
duration_budget_ms_for() {
  local script=$1 baseline
  baseline=$(script_duration_baseline_ms "$script") || return 1
  printf '%s\t%s\n' "$baseline" "$((baseline * 2 + 10000))"
}

# Longest-processing-time assignment of one lane listing to <count> bins,
# printing "<shard>\t<script>" for every script. Deterministic: candidates are
# ordered by hint descending then path, and ties between equally loaded bins
# always take the lowest bin index.
lpt_shard_assignments() {  # <count> <list-function>
  local count=$1 list_fn=$2 ms script i best best_load
  local -a loads=()
  i=1
  while [ "$i" -le "$count" ]; do
    loads[i]=0
    i=$((i + 1))
  done
  while IFS=$'\t' read -r ms script; do
    [ -n "$script" ] || continue
    best=1
    best_load=${loads[1]}
    i=2
    while [ "$i" -le "$count" ]; do
      if [ "${loads[i]}" -lt "$best_load" ]; then
        best_load=${loads[i]}
        best=$i
      fi
      i=$((i + 1))
    done
    loads[best]=$((best_load + ms))
    printf '%s\t%s\n' "$best" "$script"
  done < <(
    # One awk join replaces a per-script lookup subshell; a script with no
    # measured hint keeps the conservative default weight.
    awk -v def="$PORTABLE_SERIAL_DEFAULT_WEIGHT_MS" '
      FNR == NR { if (!($1 in hint)) hint[$1] = $2; next }
      NF { w = ($1 in hint) ? hint[$1] : def; printf "%s\t%s\n", w, $1 }
    ' <(all_duration_hints) <("$list_fn") | LC_ALL=C sort -t$'\t' -k1,1nr -k2,2
  )
}

portable_serial_assignments() {
  lpt_shard_assignments "$PORTABLE_SERIAL_SHARDS" list_portable_serial
}

real_herdr_assignments() {
  lpt_shard_assignments "$REAL_HERDR_SHARDS" list_real_herdr_gated
}

# Parse "<k>of<n>" from a sharded lane name and echo <k>, refusing when <n>
# disagrees with this script's configured count so a CI matrix built for a
# different shard count fails loudly instead of dropping tests.
lane_shard_index() {  # <lane> <lane-prefix> <configured-count>
  local lane=$1 prefix=$2 configured=$3 spec index count
  spec=${lane#"$prefix"-}
  index=${spec%%of*}
  count=${spec#*of}
  case "$spec" in
    *of*) ;;
    *) die "unknown lane '$lane' (see --list-lanes)" ;;
  esac
  case "$index" in
    ''|*[!0-9]*) die "unknown lane '$lane' (see --list-lanes)" ;;
  esac
  case "$count" in
    ''|*[!0-9]*) die "unknown lane '$lane' (see --list-lanes)" ;;
  esac
  if [ "$count" -ne "$configured" ]; then
    die "lane '$lane' asks for $count $prefix shards but this runner is configured for $configured (see --list-lanes)"
  fi
  if [ "$index" -lt 1 ] || [ "$index" -gt "$configured" ]; then
    die "lane '$lane' shard index is outside 1..$configured (see --list-lanes)"
  fi
  printf '%s\n' "$index"
}

select_proven_isolated() {
  local s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    add_script "$s"
  done < <(list_proven_isolated)
}

select_lane() {
  local want=$1 s shard idx found=0
  case "$want" in
    portable-parallel-1)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_parallel_1)
      ;;
    portable-parallel-2)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_parallel_2)
      ;;
    portable-serial)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_serial)
      ;;
    portable-serial-*)
      # One separate-runner shard of the same remainder, still serial in itself.
      shard=$(lane_shard_index "$want" portable-serial "$PORTABLE_SERIAL_SHARDS")
      while IFS=$'\t' read -r idx s; do
        [ -n "$s" ] || continue
        if [ "$idx" = "$shard" ]; then
          add_script "$s"
          found=1
        fi
      done < <(portable_serial_assignments)
      ;;
    real-herdr-gated)
      select_family real-herdr-gated
      found=1
      ;;
    real-herdr-gated-*)
      # One separate-runner shard of the required real-Herdr family, still
      # serial in itself with its own default session and cleanup.
      shard=$(lane_shard_index "$want" real-herdr-gated "$REAL_HERDR_SHARDS")
      while IFS=$'\t' read -r idx s; do
        [ -n "$s" ] || continue
        if [ "$idx" = "$shard" ]; then
          add_script "$s"
          found=1
        fi
      done < <(real_herdr_assignments)
      ;;
    *)
      die "unknown lane '$want' (see --list-lanes)"
      ;;
  esac
  [ "$found" -eq 1 ] || die "lane '$want' selected no tests"
}

run_coverage_guard() {
  local tmp missing extra a b shard
  local -a saved_scripts=()
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-coverage.XXXXXX")

  all_repo_tests | LC_ALL=C sort -u >"$tmp/all"
  list_proven_isolated | LC_ALL=C sort -u >"$tmp/proven"
  list_portable_parallel_1 | LC_ALL=C sort -u >"$tmp/s1"
  list_portable_parallel_2 | LC_ALL=C sort -u >"$tmp/s2"

  cat "$tmp/s1" "$tmp/s2" | LC_ALL=C sort | uniq -d >"$tmp/shard_dups"
  if [ -s "$tmp/shard_dups" ]; then
    log "coverage guard: portable parallel shards share scripts:"
    cat "$tmp/shard_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  cat "$tmp/s1" "$tmp/s2" | LC_ALL=C sort -u >"$tmp/shards_union"
  missing=$(comm -23 "$tmp/proven" "$tmp/shards_union" || true)
  extra=$(comm -13 "$tmp/proven" "$tmp/shards_union" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: portable shards must equal the proven-isolated set"
    [ -z "$missing" ] || { log "missing from shards:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond proven:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  # Serial (whole lane and each CI shard) + Herdr lane listings without
  # disturbing a caller's selection.
  saved_scripts=("${SCRIPTS[@]+"${SCRIPTS[@]}"}")
  SCRIPTS=()
  select_lane portable-serial
  printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" | LC_ALL=C sort -u >"$tmp/serial"
  : >"$tmp/serial_shards_raw"
  shard=1
  while [ "$shard" -le "$PORTABLE_SERIAL_SHARDS" ]; do
    SCRIPTS=()
    select_lane "portable-serial-${shard}of${PORTABLE_SERIAL_SHARDS}"
    if [ "${#SCRIPTS[@]}" -eq 0 ]; then
      log "coverage guard: portable serial shard $shard of $PORTABLE_SERIAL_SHARDS is empty"
      SCRIPTS=("${saved_scripts[@]+"${saved_scripts[@]}"}")
      rm -rf "$tmp"
      return 1
    fi
    printf '%s\n' "${SCRIPTS[@]}" >>"$tmp/serial_shards_raw"
    shard=$((shard + 1))
  done
  SCRIPTS=()
  select_family real-herdr-gated
  printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" | LC_ALL=C sort -u >"$tmp/herdr"
  : >"$tmp/herdr_shards_raw"
  shard=1
  while [ "$shard" -le "$REAL_HERDR_SHARDS" ]; do
    SCRIPTS=()
    select_lane "real-herdr-gated-${shard}of${REAL_HERDR_SHARDS}"
    if [ "${#SCRIPTS[@]}" -eq 0 ]; then
      log "coverage guard: real-Herdr shard $shard of $REAL_HERDR_SHARDS is empty"
      SCRIPTS=("${saved_scripts[@]+"${saved_scripts[@]}"}")
      rm -rf "$tmp"
      return 1
    fi
    printf '%s\n' "${SCRIPTS[@]}" >>"$tmp/herdr_shards_raw"
    shard=$((shard + 1))
  done
  SCRIPTS=("${saved_scripts[@]+"${saved_scripts[@]}"}")

  # Every real-Herdr script runs in exactly one CI shard: no duplicate work
  # across runners, and no script silently left out of the required lane.
  LC_ALL=C sort "$tmp/herdr_shards_raw" | uniq -d >"$tmp/herdr_shard_dups"
  if [ -s "$tmp/herdr_shard_dups" ]; then
    log "coverage guard: real-Herdr shards share scripts:"
    cat "$tmp/herdr_shard_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  LC_ALL=C sort -u "$tmp/herdr_shards_raw" >"$tmp/herdr_shards"
  missing=$(comm -23 "$tmp/herdr" "$tmp/herdr_shards" || true)
  extra=$(comm -13 "$tmp/herdr" "$tmp/herdr_shards" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: real-Herdr shards must equal the real-herdr-gated family"
    [ -z "$missing" ] || { log "missing from real-Herdr shards:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond real-herdr-gated family:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  # Every serial script runs in exactly one CI shard: no duplicate work across
  # runners, and no script silently left out of the required lane.
  LC_ALL=C sort "$tmp/serial_shards_raw" | uniq -d >"$tmp/serial_shard_dups"
  if [ -s "$tmp/serial_shard_dups" ]; then
    log "coverage guard: portable serial shards share scripts:"
    cat "$tmp/serial_shard_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  LC_ALL=C sort -u "$tmp/serial_shards_raw" >"$tmp/serial_shards"
  missing=$(comm -23 "$tmp/serial" "$tmp/serial_shards" || true)
  extra=$(comm -13 "$tmp/serial" "$tmp/serial_shards" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: portable serial shards must equal the portable serial lane"
    [ -z "$missing" ] || { log "missing from serial shards:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond serial lane:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  for pair in "shards_union:serial" "shards_union:herdr" "serial:herdr"; do
    a=${pair%%:*}
    b=${pair#*:}
    comm -12 "$tmp/$a" "$tmp/$b" >"$tmp/overlap"
    if [ -s "$tmp/overlap" ]; then
      log "coverage guard: overlap between $a and $b:"
      cat "$tmp/overlap" >&2
      rm -rf "$tmp"
      return 1
    fi
  done

  cat "$tmp/shards_union" "$tmp/serial" "$tmp/herdr" | LC_ALL=C sort >"$tmp/union_raw"
  uniq -d "$tmp/union_raw" >"$tmp/union_dups"
  if [ -s "$tmp/union_dups" ]; then
    log "coverage guard: duplicate scripts across lanes:"
    cat "$tmp/union_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  LC_ALL=C sort -u "$tmp/union_raw" >"$tmp/union"
  missing=$(comm -23 "$tmp/all" "$tmp/union" || true)
  extra=$(comm -13 "$tmp/all" "$tmp/union" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: union of portable shards + portable serial + Herdr must equal tests/*.test.sh"
    [ -z "$missing" ] || { log "missing from union:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond inventory:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  awk 'FNR == NR { hinted[$1] = 1; next } NF && !($1 in hinted)' \
    <(all_duration_hints) "$tmp/union" >"$tmp/missing_budgets"
  if [ -s "$tmp/missing_budgets" ]; then
    log "coverage guard: required lane scripts lack duration baselines:"
    cat "$tmp/missing_budgets" >&2
    rm -rf "$tmp"
    return 1
  fi

  if [ -x "$ROOT/bin/fm-test-isolation-proof.sh" ]; then
    "$ROOT/bin/fm-test-isolation-proof.sh" --list | LC_ALL=C sort -u >"$tmp/proof_list"
    if ! cmp -s "$tmp/proven" "$tmp/proof_list"; then
      log "coverage guard: embedded proven-isolated set diverges from bin/fm-test-isolation-proof.sh --list"
      comm -3 "$tmp/proven" "$tmp/proof_list" >&2 || true
      rm -rf "$tmp"
      return 1
    fi
  fi

  printf 'FM_TEST_COVERAGE ok total=%s parallel=%s serial=%s serial_shards=%s herdr=%s herdr_shards=%s\n' \
    "$(wc -l <"$tmp/all" | tr -d ' ')" \
    "$(wc -l <"$tmp/shards_union" | tr -d ' ')" \
    "$(wc -l <"$tmp/serial" | tr -d ' ')" \
    "$PORTABLE_SERIAL_SHARDS" \
    "$(wc -l <"$tmp/herdr" | tr -d ' ')" \
    "$REAL_HERDR_SHARDS"
  rm -rf "$tmp"
  return 0
}

aggregate_timing_json() {
  local out=$1
  shift
  [ "$#" -gt 0 ] || die "--aggregate-json requires at least one input timing JSON"
  command -v python3 >/dev/null 2>&1 || die "--aggregate-json requires python3"
  python3 - "$out" "$@" <<'PY'
import json, sys
from pathlib import Path

out = Path(sys.argv[1])
inputs = [Path(p) for p in sys.argv[2:]]
lanes = []
all_scripts = []
failed = 0
skipped = 0
budget_exceeded = 0
budget_missing = 0
total = 0
wall_ms = 0
for path in inputs:
    doc = json.loads(path.read_text(encoding="utf-8"))
    summary = doc.get("summary") or {}
    lane = {
        "path": str(path),
        "run_id": doc.get("run_id"),
        "selection": doc.get("selection"),
        "started_at": doc.get("started_at"),
        "finished_at": doc.get("finished_at"),
        "summary": summary,
    }
    lanes.append(lane)
    total += int(summary.get("total") or 0)
    failed += int(summary.get("failed") or 0)
    skipped += int(summary.get("skipped_gate") or 0)
    budget_exceeded += int(summary.get("duration_budget_exceeded") or 0)
    budget_missing += int(summary.get("duration_budget_missing") or 0)
    wall_ms = max(wall_ms, int(summary.get("duration_ms") or 0))
    for s in doc.get("scripts") or []:
        row = dict(s)
        row["lane_selection"] = doc.get("selection")
        row["lane_run_id"] = doc.get("run_id")
        all_scripts.append(row)

lanes.sort(key=lambda lane: (lane.get("selection") or "", lane.get("path") or ""))
all_scripts.sort(key=lambda s: (-int(s.get("duration_ms") or 0), s.get("path") or "", s.get("lane_selection") or ""))
agg = {
    "kind": "aggregate",
    "lanes": lanes,
    "summary": {
        "lanes": len(lanes),
        "total": total,
        "failed": failed,
        "skipped_gate": skipped,
        "duration_budget_exceeded": budget_exceeded,
        "duration_budget_missing": budget_missing,
        "critical_path_duration_ms": wall_ms,
    },
    "scripts": all_scripts,
    "slowest": all_scripts[:15],
}
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(agg, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"FM_TEST_AGGREGATE lanes={len(lanes)} total={total} failed={failed} skipped_gate={skipped} critical_path_duration_ms={wall_ms}")
PY
}

all_repo_tests() {
  # Deterministic lexical order (same as bash glob expansion under LC_ALL=C).
  local f
  # shellcheck disable=SC2035
  for f in tests/*.test.sh; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done | LC_ALL=C sort
}

normalize_script_path() {
  local p=$1
  case "$p" in
    /*) printf '%s\n' "$p" ;;
    tests/*|./tests/*)
      p=${p#./}
      printf '%s\n' "$p"
      ;;
    *.test.sh)
      if [ -f "tests/$p" ]; then
        printf 'tests/%s\n' "$p"
      else
        printf '%s\n' "$p"
      fi
      ;;
    *)
      printf '%s\n' "$p"
      ;;
  esac
}

# Append unique relative-or-absolute script paths to SCRIPTS.
add_script() {
  local p existing
  p=$(normalize_script_path "$1")
  for existing in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    [ "$existing" = "$p" ] && return 0
  done
  SCRIPTS+=("$p")
}

select_all() {
  local s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    add_script "$s"
  done < <(all_repo_tests)
}

select_portable() {
  local s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    family_for_basename_into "${s##*/}"
    [ "$FAMILY_FOR_BASENAME" = real-herdr-gated ] && continue
    add_script "$s"
  done < <(all_repo_tests)
}

select_family() {
  local want=$1 s found=0
  [ -n "$want" ] || die "--family requires a name"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    family_for_basename_into "${s##*/}"
    if [ "$FAMILY_FOR_BASENAME" = "$want" ]; then
      add_script "$s"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 1 ] || die "no tests mapped to family '$want'"
}

families_for_test_reference() {
  local needle=$1 s
  local found=0
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if grep -Fq "$needle" "$s"; then
      family_for_basename "$(basename "$s")"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 1 ]
}

# Conservative path → family map. Over-selects rather than under-selects.
# Never expands to the complete suite.
families_for_changed_path() {
  local path=$1 fixture_ref
  case "$path" in
    tests/fm-test-run.test.sh)
      printf '%s\n' pure-contract-unit
      ;;
    tests/fm-backend-herdr-eventwait.test.py)
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      ;;
    tests/helpers/fs-event-monitor.py)
      printf '%s\n' "__script__:fm-rtk-fs-events.test.sh"
      printf '%s\n' "__script__:fm-rtk-exec-trace.test.sh"
      ;;
    tests/*.test.sh)
      # A single test file change selects only that script via basename family
      # resolution in the caller; emit a marker family of __script__
      printf '%s\n' "__script__:$(basename "$path")"
      ;;
    bin/fm-test-run.sh|bin/fm-test-isolation-proof.sh)
      printf '%s\n' pure-contract-unit
      ;;
    bin/backends/herdr*|bin/fm-herdr-lab.sh|tests/herdr-test-safety.sh)
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-herdr-session-cleanup.sh)
      printf '%s\n' session-bootstrap
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/zellij*|tests/zellij-test-safety.sh)
      printf '%s\n' zellij
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/cmux*|tests/cmux-test-safety.sh)
      printf '%s\n' cmux
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/orca*|bin/backends/tmux.sh)
      printf '%s\n' backend-dispatch
      printf '%s\n' orca
      ;;
    bin/fm-backend.sh|bin/fm-backend-hometag-lib.sh)
      printf '%s\n' backend-dispatch
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-watch*|bin/fm-wake*|bin/fm-inactive-reconcile.sh|bin/fm-discord*|\
    bin/fm-classify-lib.sh|bin/fm-daemon*|bin/fm-turnend-guard*|bin/fm-guard.sh)
      printf '%s\n' watcher-wake-lock
      ;;
    bin/fm-afk*)
      printf '%s\n' afk
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-supervisor-target-lib.sh)
      printf '%s\n' watcher-wake-lock
      printf '%s\n' real-herdr-gated
      printf '%s\n' live-harness-optin
      printf '%s\n' afk
      ;;
    bin/fm-startup-memory-budget.sh|bin/fm-startup-memory-budget-lib.sh)
      printf '%s\n' secondmate
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-secondmate*|bin/fm-remote*|bin/fm-on.sh|bin/fm-home-seed.sh|\
    bin/fm-backlog-handoff.sh|bin/fm-backlog-receive.sh|bin/fm-procevent-remote-reply.sh|\
    bin/fm-config-inherit-lib.sh|bin/fm-config-push.sh|bin/fm-shared*|\
    bin/fm-stow-cascade.sh)
      printf '%s\n' secondmate
      ;;
    bin/fm-session-start.sh|bin/fm-bootstrap.sh|bin/fm-fleet-sync.sh|\
    bin/fm-sessionstart-nudge.sh|bin/fm-startup-network.sh|bin/fm-tangle*|bin/fm-update.sh|\
    bin/fm-gate-refuse*|bin/fm-lock*|bin/fm-quota-axi-lib.sh)
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-sessionstart-run.sh|.claude/settings.json|.codex/hooks.json|\
    .pi/extensions/fm-primary-turnend-guard.ts)
      # The run tier's two harness-supplied facts (source vocabulary and
      # context-reset stdout injection) only show up against a real harness.
      printf '%s\n' session-bootstrap
      printf '%s\n' live-harness-optin
      ;;
    bin/fm-timeout-lib.sh)
      # The shared hard bound: session start's runtime bound, the fleet/bearings
      # snapshots, the vendor auth probe, and the stow cascade's per-home step
      # all depend on it.
      printf '%s\n' session-bootstrap
      printf '%s\n' snapshot-bearings
      printf '%s\n' pure-contract-unit
      printf '%s\n' secondmate
      ;;
    bin/fm-pr-*|bin/fm-merge-local.sh|bin/fm-teardown.sh|bin/fm-review-diff.sh|\
    bin/fm-x-*|bin/fm-check*)
      printf '%s\n' pr-forge
      ;;
    bin/fm-nm-run-lib.sh)
      # Shared no-mistakes run-attribution primitives, sourced by both
      # bin/fm-crew-state.sh (pure-contract-unit) and bin/fm-teardown.sh's
      # pre-teardown run abort (pr-forge).
      printf '%s\n' pure-contract-unit
      printf '%s\n' pr-forge
      ;;
    bin/fm-composer-lib.sh)
      # The shared shape catalogue is vendor-rendered signal; a change to it
      # re-selects the live guard (fm-composer-matrix-live-e2e) alongside the
      # portable families.
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      printf '%s\n' live-harness-optin
      ;;
    bin/fm-spawn.sh|bin/fm-send.sh|bin/fm-harness.sh|bin/fm-dispatch-config-lib.sh|\
    bin/fm-peek.sh|bin/fm-composer*)
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-bearings-snapshot.sh|bin/fm-fleet-snapshot.sh|bin/fm-fleet-view.sh)
      printf '%s\n' snapshot-bearings
      ;;
    bin/fm-install-herdr.sh|bin/fm-install-treehouse.sh|bin/fm-herdr-ci-cleanup.sh)
      printf '%s\n' pure-contract-unit
      # Pin or cleanup changes also select the real-Herdr family so the required
      # lane's contract coverage re-runs.
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-lint.sh|bin/fm-install-shellcheck.sh|\
    bin/fm-brief.sh|bin/fm-ensure-agents-md.sh|bin/fm-crew-state.sh|\
    bin/fm-decision-hold.sh|bin/fm-supervision*|bin/fm-transition-lib.sh|\
    bin/fm-tmux-lib.sh|bin/fm-marker-lib.sh|bin/fm-operational-input.sh|bin/fm-tasks-axi-lib.sh|\
    bin/fm-vendor-auth-probe.sh|\
    bin/fm-primary-scope-lib.sh|bin/fm-project-mode.sh|bin/fm-promote.sh|\
    bin/fm-ff-lib.sh|bin/fm-gotmp*|bin/*pretool*)
      printf '%s\n' pure-contract-unit
      ;;
    defaults/crew-dispatch.json)
      printf '%s\n' backend-dispatch
      printf '%s\n' session-bootstrap
      printf '%s\n' live-harness-optin
      ;;
    .agents/skills/quota-array-dispatch/SKILL.md)
      printf '%s\n' pure-contract-unit
      printf '%s\n' live-harness-optin
      ;;
    .agents/skills/*/SKILL.md)
      printf '%s\n' pure-contract-unit
      ;;
    .github/workflows/ci.yml|.no-mistakes.yaml)
      printf '%s\n' pure-contract-unit
      printf '%s\n' real-herdr-gated
      ;;
    docs/fm-test-portable-shards.md|docs/fm-test-isolation-proof.md|\
    docs/fm-test-isolation-proof.json)
      printf '%s\n' pure-contract-unit
      ;;
    .github/*|.tasks.toml|AGENTS.md|CLAUDE.md|CONTRIBUTING.md|\
    docs/configuration.md|docs/supervision-protocols/*)
      printf '%s\n' pure-contract-unit
      ;;
    tests/lib.sh|tests/*-helpers.sh)
      families_for_test_reference "$(basename "$path")" \
        || printf '%s\n' "__unmapped__:$path"
      ;;
    tests/fixtures/*/*)
      # A fixture belongs to whichever suite reads its directory, found by the
      # same reference scan used for shared helpers. Keyed on the directory
      # rather than the file so adding a fixture selects the same suite.
      # A removed fixture directory has no consuming suite left to select.
      fixture_ref=${path#tests/fixtures/}
      fixture_ref=${fixture_ref%%/*}
      if [ -d "tests/fixtures/$fixture_ref" ]; then
        families_for_test_reference "fixtures/$fixture_ref" \
          || printf '%s\n' "__unmapped__:$path"
      fi
      ;;
    bin/*)
      # A deleted script has no consuming suite left to select, the same rule
      # the fixture case above applies. Refusing on its absent mapping would
      # make every retirement branch unable to select its changed tests.
      if [ -e "$path" ]; then
        families_for_test_reference "$(basename "$path")" \
          || printf '%s\n' "__unmapped__:$path"
      fi
      ;;
    tests/*)
      printf '%s\n' "__unmapped__:$path"
      ;;
    README.md|LICENSE|assets/*|docs/*|.gitignore)
      ;;
    *)
      families_for_test_reference "$path" \
        || printf '%s\n' "__unmapped__:$path"
      ;;
  esac
}

select_changed() {
  local base=$1 path entry fam script_name s
  local -a wanted_families=()
  local -a wanted_scripts=()

  if ! git -C "$ROOT" rev-parse --verify "$base" >/dev/null 2>&1; then
    die "changed-file base ref not found: $base (pass --base <ref>)"
  fi

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      case "$entry" in
        __script__:*)
          script_name=${entry#__script__:}
          wanted_scripts+=("$script_name")
          ;;
        __unmapped__:*)
          die "no changed-test mapping for source path: ${entry#__unmapped__:}"
          ;;
        *)
          wanted_families+=("$entry")
          ;;
      esac
    done < <(families_for_changed_path "$path")
  done < <(git -C "$ROOT" diff --name-only "${base}...HEAD" 2>/dev/null; \
           git -C "$ROOT" diff --name-only HEAD 2>/dev/null; \
           git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null)

  # Dedup families
  local f seen_f
  local -a unique_families=()
  for f in "${wanted_families[@]+"${wanted_families[@]}"}"; do
    seen_f=0
    for u in "${unique_families[@]+"${unique_families[@]}"}"; do
      [ "$u" = "$f" ] && { seen_f=1; break; }
    done
    [ "$seen_f" -eq 0 ] && unique_families+=("$f")
  done

  for f in "${unique_families[@]+"${unique_families[@]}"}"; do
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      family_for_basename_into "${s##*/}"
      if [ "$FAMILY_FOR_BASENAME" = "$f" ]; then
        add_script "$s"
      fi
    done < <(all_repo_tests)
  done

  for script_name in "${wanted_scripts[@]+"${wanted_scripts[@]}"}"; do
    if [ -f "tests/$script_name" ]; then
      add_script "tests/$script_name"
    fi
  done

  if [ "${#SCRIPTS[@]}" -eq 0 ]; then
    log "no tests selected for changes vs $base (map is conservative; use --all for the complete suite)"
  fi
}

detect_gate_skip() {
  # True when the first non-empty output line is a skip: gate message.
  local file=$1 first
  first=$(awk 'NF { print; exit }' "$file" 2>/dev/null || true)
  case "$first" in
    skip:*) return 0 ;;
    *) return 1 ;;
  esac
}

# True when any output line contains "skip: <token>" (token may contain spaces).
detect_gate_skip_token() {
  local file=$1 token=$2
  [ -n "$token" ] || return 1
  grep -F -q "skip: $token" "$file" 2>/dev/null
}

apply_exclude_families() {
  local s fam keep ex
  local -a kept=()
  [ "${#EXCLUDE_FAMILIES[@]}" -gt 0 ] || return 0
  for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    family_for_basename_into "${s##*/}"
    fam=$FAMILY_FOR_BASENAME
    keep=1
    for ex in "${EXCLUDE_FAMILIES[@]}"; do
      if [ "$fam" = "$ex" ]; then
        keep=0
        break
      fi
    done
    [ "$keep" -eq 1 ] && kept+=("$s")
  done
  SCRIPTS=("${kept[@]+"${kept[@]}"}")
}

write_json_artifact() {
  local out=$1
  local started=$2
  local finished=$3
  local run_id=$4
  local total=$5
  local failed=$6
  local skipped=$7
  local duration=$8
  local selection=$9
  local records_file=${10}
  local families_file=${11}

  if ! command -v python3 >/dev/null 2>&1; then
    die "--json requires python3 to emit a valid timing artifact"
  fi

  python3 - "$out" "$started" "$finished" "$run_id" "$total" "$failed" "$skipped" "$duration" "$selection" "$records_file" "$families_file" <<'PY'
import json, sys

out, started, finished, run_id, total, failed, skipped, duration, selection, records_file, families_file = sys.argv[1:]

scripts = []
with open(records_file, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        path, family, expected, exit_s, dur_s, gate, baseline_s, budget_s, exceeded = line.split("\t")
        row = {
            "path": path,
            "family": family,
            "expected_gate_skip": expected,
            "duration_ms": int(dur_s),
            "exit": int(exit_s),
            "gate_skip": gate == "true",
            "duration_budget_exceeded": exceeded == "true",
            "duration_baseline_measured": bool(baseline_s),
        }
        if baseline_s:
            row["duration_baseline_ms"] = int(baseline_s)
            row["duration_budget_ms"] = int(budget_s)
        scripts.append(row)

scripts.sort(key=lambda s: s["path"])

families = []
with open(families_file, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        name, count_s, dur_s, failed_s = line.split("\t")
        families.append({
            "name": name,
            "count": int(count_s),
            "duration_ms": int(dur_s),
            "failed": int(failed_s),
        })

doc = {
    "run_id": run_id,
    "started_at": started,
    "finished_at": finished,
    "selection": selection,
    "summary": {
        "total": int(total),
        "failed": int(failed),
        "skipped_gate": int(skipped),
        "duration_ms": int(duration),
        "duration_budget_exceeded": sum(1 for s in scripts if s["duration_budget_exceeded"]),
        "duration_budget_missing": sum(1 for s in scripts if not s["duration_baseline_measured"]),
    },
    "scripts": scripts,
    "families": families,
}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --portable)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=portable
      shift
      ;;
    --all)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=all
      shift
      ;;
    --family)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      [ "$#" -gt 1 ] || die "--family requires a name"
      MODE=family
      FAMILY=$2
      shift 2
      ;;
    --family=*)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=family
      FAMILY=${1#--family=}
      shift
      ;;
    --lane)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      [ "$#" -gt 1 ] || die "--lane requires a name (see --list-lanes)"
      MODE=lane
      LANE=$2
      shift 2
      ;;
    --lane=*)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=lane
      LANE=${1#--lane=}
      shift
      ;;
    --proven-isolated)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=proven-isolated
      shift
      ;;
    --changed)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=changed
      shift
      ;;
    --base)
      [ "$#" -gt 1 ] || die "--base requires a git ref"
      BASE_REF=$2
      shift 2
      ;;
    --base=*)
      BASE_REF=${1#--base=}
      shift
      ;;
    --json)
      [ "$#" -gt 1 ] || die "--json requires a path"
      JSON_PATH=$2
      shift 2
      ;;
    --json=*)
      JSON_PATH=${1#--json=}
      shift
      ;;
    --jobs)
      [ "$#" -gt 1 ] || die "--jobs requires a positive integer"
      JOBS=$2
      JOBS_EXPLICIT=1
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#--jobs=}
      JOBS_EXPLICIT=1
      shift
      ;;
    --enforce-duration-budgets)
      DURATION_BUDGET_MODE=enforce
      shift
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    --list-families)
      LIST_FAMILIES=1
      shift
      ;;
    --list-lanes)
      LIST_LANES=1
      shift
      ;;
    --check-coverage)
      CHECK_COVERAGE=1
      shift
      ;;
    --aggregate-json)
      [ "$#" -gt 1 ] || die "--aggregate-json requires an output path"
      AGGREGATE_OUT=$2
      shift 2
      # Remaining args after options will be collected as inputs below via MODE.
      # For aggregation we accept only input JSON paths as free args after this.
      MODE=aggregate
      ;;
    --exclude-family)
      [ "$#" -gt 1 ] || die "--exclude-family requires a name"
      EXCLUDE_FAMILIES+=("$2")
      shift 2
      ;;
    --exclude-family=*)
      EXCLUDE_FAMILIES+=("${1#--exclude-family=}")
      shift
      ;;
    --fail-on-gate-skip)
      [ "$#" -gt 1 ] || die "--fail-on-gate-skip requires a token (e.g. 'herdr not found')"
      FAIL_ON_GATE_SKIP=$2
      shift 2
      ;;
    --fail-on-gate-skip=*)
      FAIL_ON_GATE_SKIP=${1#--fail-on-gate-skip=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        SCRIPTS+=("$1")
        shift
      done
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      if [ "${MODE:-}" = "aggregate" ]; then
        SCRIPTS+=("$1")
      elif [ -z "$MODE" ] || [ "$MODE" = scripts ]; then
        MODE=scripts
        SCRIPTS+=("$1")
      else
        die "script paths cannot be combined with --$MODE"
      fi
      shift
      ;;
  esac
done

if [ "$LIST_FAMILIES" -eq 1 ]; then
  list_known_families
  exit 0
fi

if [ "$LIST_LANES" -eq 1 ]; then
  list_known_lanes
  exit 0
fi

if [ "$CHECK_COVERAGE" -eq 1 ]; then
  run_coverage_guard
  exit $?
fi

if [ "${MODE:-}" = "aggregate" ]; then
  [ -n "$AGGREGATE_OUT" ] || die "--aggregate-json requires an output path"
  [ "${#SCRIPTS[@]}" -gt 0 ] || die "--aggregate-json requires at least one input timing JSON"
  for s in "${SCRIPTS[@]}"; do
    [ -f "$s" ] || die "aggregate input not found: $s"
  done
  aggregate_timing_json "$AGGREGATE_OUT" "${SCRIPTS[@]}"
  exit 0
fi

if [ -z "${MODE:-}" ]; then
  MODE=changed
fi
if [ "$JOBS_EXPLICIT" -eq 0 ]; then
  case "$MODE" in
    portable|all) JOBS=4 ;;
    *) JOBS=1 ;;
  esac
fi
case "$JOBS" in
  ''|*[!0-9]*) die "--jobs must be a positive integer" ;;
esac
[ "$JOBS" -ge 1 ] || die "--jobs must be >= 1"
[ "$JOBS" -le "$JOBS_MAX" ] || die "--jobs is capped at $JOBS_MAX (got $JOBS)"

case "${MODE:-}" in
  portable)
    select_portable
    SELECTION_DESC="portable"
    ;;
  all)
    select_all
    SELECTION_DESC="all"
    ;;
  family)
    select_family "$FAMILY"
    SELECTION_DESC="family=$FAMILY"
    ;;
  lane)
    select_lane "$LANE"
    SELECTION_DESC="lane=$LANE"
    ;;
  proven-isolated)
    select_proven_isolated
    SELECTION_DESC="proven-isolated"
    ;;
  changed)
    select_changed "$BASE_REF"
    SELECTION_DESC="changed:base=$BASE_REF"
    ;;
  scripts)
    # Normalize and re-add through add_script for consistent paths.
    raw=("${SCRIPTS[@]}")
    SCRIPTS=()
    for s in "${raw[@]}"; do
      add_script "$s"
    done
    SELECTION_DESC="scripts"
    ;;
  *)
    die "select with --portable, --all, --family <name>, --lane <name>, --proven-isolated, --changed, or one or more script paths (see --help)"
    ;;
esac

apply_exclude_families
if [ "${#EXCLUDE_FAMILIES[@]}" -gt 0 ]; then
  SELECTION_DESC="${SELECTION_DESC};exclude-family=$(IFS=,; printf '%s' "${EXCLUDE_FAMILIES[*]}")"
fi
if [ -n "$FAIL_ON_GATE_SKIP" ]; then
  SELECTION_DESC="${SELECTION_DESC};fail-on-gate-skip=$FAIL_ON_GATE_SKIP"
fi
if [ "$JOBS" -gt 1 ]; then
  SELECTION_DESC="${SELECTION_DESC};jobs=$JOBS"
fi

if [ "$LIST_ONLY" -eq 1 ]; then
  for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    printf '%s\n' "$s"
  done
  exit 0
fi

if [ "${#SCRIPTS[@]}" -eq 0 ]; then
  log "nothing to run"
  printf 'FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=0\n'
  printf 'FM_TEST_BUDGET_SUMMARY checked=0 exceeded=0 missing=0 mode=%s\n' "$DURATION_BUDGET_MODE"
  if [ -n "$JSON_PATH" ]; then
    empty_rec=$(mktemp)
    empty_fam=$(mktemp)
    : >"$empty_rec"
    : >"$empty_fam"
    started=$(now_iso)
    mkdir -p "$(dirname "$JSON_PATH")"
    write_json_artifact "$JSON_PATH" "$started" "$started" "empty" 0 0 0 0 "$SELECTION_DESC" "$empty_rec" "$empty_fam"
    rm -f "$empty_rec" "$empty_fam"
  fi
  exit 0
fi

# Verify selected scripts exist before starting.
for s in "${SCRIPTS[@]}"; do
  [ -f "$s" ] || die "test script not found: $s"
  [ -x "$s" ] || [ -r "$s" ] || die "test script not readable: $s"
done

# Mixed complete modes parallelize only their proven-isolated subset and keep
# every other selected script serial. Other modes retain the stricter refusal.
if [ "$JOBS" -gt 1 ] && [ "$MODE" != portable ] && [ "$MODE" != all ]; then
  for s in "${SCRIPTS[@]}"; do
    if ! is_proven_isolated_script "$s"; then
      die "--jobs $JOBS refused: $s is not in the proven-isolated set (see bin/fm-test-isolation-proof.sh --list). Stateful families stay serial."
    fi
  done
fi

RUN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run.XXXXXX")
RECORDS="$RUN_TMP/records.tsv"
FAMILIES_TSV="$RUN_TMP/families.tsv"
: >"$RECORDS"
WORKER_PIDS=()
WORKER_GROUP_PIDS=()

# shellcheck disable=SC2329 # Used by cleanup/signal handlers invoked indirectly by traps.
worker_group_is_running() {
  kill -0 -- "-$1" 2>/dev/null
}

register_worker_group() {
  local pid=$1 registered
  for registered in "${WORKER_GROUP_PIDS[@]+"${WORKER_GROUP_PIDS[@]}"}"; do
    [ "$registered" = "$pid" ] && return
  done
  WORKER_GROUP_PIDS+=("$pid")
}

retire_empty_worker_groups() {
  local pid
  local -a retained=()
  for pid in "${WORKER_GROUP_PIDS[@]+"${WORKER_GROUP_PIDS[@]}"}"; do
    if worker_group_is_running "$pid"; then
      retained+=("$pid")
    fi
  done
  WORKER_GROUP_PIDS=("${retained[@]+"${retained[@]}"}")
}

# shellcheck disable=SC2329 # Invoked indirectly by cleanup/signal traps.
stop_active_workers() {
  local pid registered known n running
  local jobs_file="$RUN_TMP/active-jobs"
  trap - INT TERM HUP
  jobs -p >"$jobs_file" 2>/dev/null || true
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    known=0
    for registered in "${WORKER_PIDS[@]+"${WORKER_PIDS[@]}"}"; do
      if [ "$registered" = "$pid" ]; then
        known=1
        break
      fi
    done
    [ "$known" -eq 1 ] || WORKER_PIDS+=("$pid")
    register_worker_group "$pid"
  done <"$jobs_file"
  for pid in "${WORKER_GROUP_PIDS[@]+"${WORKER_GROUP_PIDS[@]}"}"; do
    [ -n "$pid" ] || continue
    kill -TERM -- "-$pid" 2>/dev/null || true
  done
  running=0
  for pid in "${WORKER_GROUP_PIDS[@]+"${WORKER_GROUP_PIDS[@]}"}"; do
    [ -n "$pid" ] || continue
    if worker_group_is_running "$pid"; then
      running=1
      break
    fi
  done
  # One sleep preserves the intended TERM grace without paying for 100
  # external sleep processes (which can exceed the bounded cleanup window on
  # a loaded macOS host).
  [ "$running" -eq 0 ] || sleep 1
  for pid in "${WORKER_GROUP_PIDS[@]+"${WORKER_GROUP_PIDS[@]}"}"; do
    [ -n "$pid" ] || continue
    if worker_group_is_running "$pid"; then
      kill -KILL -- "-$pid" 2>/dev/null || true
    fi
  done
  for pid in "${WORKER_PIDS[@]+"${WORKER_PIDS[@]}"}"; do
    [ -n "$pid" ] || continue
    wait "$pid" 2>/dev/null || true
  done
  n=0
  while [ "$n" -lt 20 ]; do
    running=0
    for pid in "${WORKER_GROUP_PIDS[@]+"${WORKER_GROUP_PIDS[@]}"}"; do
      [ -n "$pid" ] || continue
      if worker_group_is_running "$pid"; then
        running=1
        break
      fi
    done
    [ "$running" -eq 1 ] || break
    sleep 0.05
    n=$((n + 1))
  done
  WORKER_PIDS=()
  retire_empty_worker_groups
}

# shellcheck disable=SC2329 # Invoked indirectly by EXIT and signal traps.
cleanup_run() {
  stop_active_workers
  rm -rf "$RUN_TMP"
}

# shellcheck disable=SC2329 # Invoked indirectly by signal traps.
interrupt_run() { # <exit-code>
  local code=$1
  cleanup_run
  trap - EXIT
  exit "$code"
}

trap cleanup_run EXIT
trap 'interrupt_run 130' INT
trap 'interrupt_run 143' TERM
trap 'interrupt_run 129' HUP

RUN_STARTED_ISO=$(now_iso)
RUN_STARTED_MS=$(now_ms)
RUN_ID="fm-test-run-${RUN_STARTED_MS}-$$"
TOTAL=0
FAILED=0
SKIPPED_GATE=0
AGG_RC=0

# Family accumulators as TSV lines updated in-memory via temp files.
# family -> count, duration_ms, failed
family_bump() {
  local fam=$1 dur=$2 failed_delta=$3
  local line name count duration failed_count rest
  local found=0
  local tmp="$RUN_TMP/families.new"
  : >"$tmp"
  if [ -s "$FAMILIES_TSV" ]; then
    while IFS= read -r line; do
      name=${line%%$'\t'*}
      rest=${line#*$'\t'}
      count=${rest%%$'\t'*}
      rest=${rest#*$'\t'}
      duration=${rest%%$'\t'*}
      failed_count=${rest#*$'\t'}
      if [ "$name" = "$fam" ]; then
        count=$((count + 1))
        duration=$((duration + dur))
        failed_count=$((failed_count + failed_delta))
        found=1
      fi
      printf '%s\t%s\t%s\t%s\n' "$name" "$count" "$duration" "$failed_count" >>"$tmp"
    done <"$FAMILIES_TSV"
  fi
  if [ "$found" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\n' "$fam" 1 "$dur" "$failed_delta" >>"$tmp"
  fi
  mv "$tmp" "$FAMILIES_TSV"
}

record_script_result() {
  local script=$1 rc=$2 duration=$3 out=$4 end_iso=$5
  local base family expected gate_skip fail_delta budget_row baseline budget exceeded
  base=$(basename "$script")
  family=$(family_for_basename "$base")
  expected=$(expected_gate_skip_for_family "$family")

  if [ -n "$FAIL_ON_GATE_SKIP" ] && detect_gate_skip_token "$out" "$FAIL_ON_GATE_SKIP"; then
    log "required gate skip token seen in $script: skip: $FAIL_ON_GATE_SKIP"
    rc=1
  fi

  gate_skip=false
  if [ "$rc" -eq 0 ] && detect_gate_skip "$out"; then
    gate_skip=true
    SKIPPED_GATE=$((SKIPPED_GATE + 1))
  fi

  printf 'FM_TEST_END %s %s exit=%s duration_ms=%s gate_skip=%s\n' \
    "$end_iso" "$script" "$rc" "$duration" "$gate_skip"

  fail_delta=0
  if [ "$rc" -ne 0 ]; then
    FAILED=$((FAILED + 1))
    fail_delta=1
    AGG_RC=1
  fi

  baseline=
  budget=
  exceeded=false
  if budget_row=$(duration_budget_ms_for "$script"); then
    baseline=${budget_row%%$'\t'*}
    budget=${budget_row#*$'\t'}
    DURATION_BUDGET_CHECKED=$((DURATION_BUDGET_CHECKED + 1))
    if [ "$duration" -gt "$budget" ]; then
      exceeded=true
      DURATION_BUDGET_EXCEEDED=$((DURATION_BUDGET_EXCEEDED + 1))
      log "duration budget exceeded: $script duration_ms=$duration budget_ms=$budget baseline_ms=$baseline mode=$DURATION_BUDGET_MODE"
      if [ "$DURATION_BUDGET_MODE" = enforce ]; then
        AGG_RC=1
      fi
    fi
  else
    DURATION_BUDGET_MISSING=$((DURATION_BUDGET_MISSING + 1))
    log "duration budget missing: $script mode=$DURATION_BUDGET_MODE"
    if [ "$DURATION_BUDGET_MODE" = enforce ]; then
      AGG_RC=1
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$script" "$family" "$expected" "$rc" "$duration" "$gate_skip" \
    "$baseline" "$budget" "$exceeded" >>"$RECORDS"
  family_bump "$family" "$duration" "$fail_delta"
  TOTAL=$((TOTAL + 1))
}

clear_ambient_fleet_environment() {
  unset FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_ROOT_OVERRIDE \
    FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_BACKEND \
    TMUX TMUX_PANE HERDR_ENV HERDR_SESSION HERDR_SOCKET_PATH HERDR_PANE_ID \
    CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH CMUX_TAB_ID CMUX_PANEL_ID \
    __CFBundleIdentifier 2>/dev/null || true
  export FM_BACKEND_DISABLE_CMUX_FALLBACK=1
}

run_one_serial() {
  local script=$1
  local base family expected out begin_iso begin_ms end_ms end_iso duration rc worker_pid work
  base=$(basename "$script")
  family=$(family_for_basename "$base")
  expected=$(expected_gate_skip_for_family "$family")
  work="$RUN_TMP/serial.$TOTAL"
  out="$work/output"
  mkdir -p "$work"
  begin_iso=$(now_iso)
  begin_ms=$(now_ms)

  printf 'FM_TEST_BEGIN %s %s family=%s expected_gate_skip=%s\n' \
    "$begin_iso" "$script" "$family" "$expected"

  set -m
  (
    set +e
    set +m
    while [ ! -f "$work/start" ]; do
      sleep 0.01
    done
    clear_ambient_fleet_environment
    bash "$script" 2>&1 | tee "$out"
    printf '%s\n' "${PIPESTATUS[0]}" >"$work/exit"
  ) &
  worker_pid=$!
  set +m
  WORKER_PIDS[0]=$worker_pid
  register_worker_group "$worker_pid"
  : >"$work/start"
  set +e
  wait "$worker_pid"
  rc=$?
  set -e
  unset 'WORKER_PIDS[0]'
  retire_empty_worker_groups
  if [ -f "$work/exit" ]; then
    rc=$(cat "$work/exit")
  fi
  : "${rc:=1}"

  end_ms=$(now_ms)
  end_iso=$(now_iso)
  duration=$((end_ms - begin_ms))
  if [ "$duration" -lt 0 ]; then
    duration=0
  fi
  record_script_result "$script" "$rc" "$duration" "$out" "$end_iso"
}

if [ "$JOBS" -eq 1 ]; then
  for script in "${SCRIPTS[@]}"; do
    run_one_serial "$script"
  done
else
  # Complete modes split the selection exactly once: the proven subset runs in
  # this bounded phase, then every stateful/unproven script runs serially.
  # Non-complete modes reached here only after the all-proven validation above.
  declare -a SERIAL_PHASE_SCRIPTS=()
  if [ "$MODE" = portable ] || [ "$MODE" = all ]; then
    parallel_selection=()
    for script in "${SCRIPTS[@]}"; do
      if is_proven_isolated_script "$script"; then
        parallel_selection+=("$script")
      else
        SERIAL_PHASE_SCRIPTS+=("$script")
      fi
    done
    SCRIPTS=("${parallel_selection[@]+"${parallel_selection[@]}"}")
  fi

  # Each concurrent worker gets a private mode-0700 TMPDIR so mktemp roots
  # cannot collide. Retries are never used as a green strategy.
  WORKER_PIDS=()
  declare -a WORKER_IDX=()
  declare -a WORKER_SCRIPTS=()
  worker_n=0
  active_workers=0

  wait_one_job_worker() {
    local slot=$1 pid idx work script rc duration mode out end_iso
    pid=${WORKER_PIDS[$slot]}
    idx=${WORKER_IDX[$slot]}
    script=${WORKER_SCRIPTS[$slot]}
    unset 'WORKER_PIDS[slot]'
    unset 'WORKER_IDX[slot]'
    unset 'WORKER_SCRIPTS[slot]'
    active_workers=$((active_workers - 1))
    set +e
    wait "$pid"
    set -e
    retire_empty_worker_groups
    work="$RUN_TMP/w$idx"
    rc=$(cat "$work/exit" 2>/dev/null || echo 1)
    duration=$(cat "$work/duration_ms" 2>/dev/null || echo 0)
    out="$work/output"
    end_iso=$(now_iso)
    # Replay captured output after the worker finishes so markers stay ordered.
    if [ -s "$out" ]; then
      cat "$out"
    fi
    mode=$(stat -c %a "$work" 2>/dev/null || stat -f %Lp "$work" 2>/dev/null || echo unknown)
    case "$mode" in
      700|0700) ;;
      *)
        log "isolation failure: worker root mode is $mode, expected 0700 ($work)"
        rc=1
        ;;
    esac
    record_script_result "$script" "$rc" "$duration" "$out" "$end_iso"
  }

  worker_pid_is_running() {
    local want=$1 running inventory="$RUN_TMP/running-pids"
    # Keep `jobs` in this shell. A process substitution runs it in a subshell
    # without this shell's job table on Bash 3.2/5.x, falsely reporting every
    # worker complete and making the scheduler wait for the oldest PID.
    jobs -r -p >"$inventory"
    while IFS= read -r running; do
      [ "$running" = "$want" ] && return 0
    done <"$inventory"
    return 1
  }

  wait_one_completed_job_worker() {
    local slot work
    while :; do
      for slot in "${!WORKER_PIDS[@]}"; do
        work="$RUN_TMP/w${WORKER_IDX[$slot]}"
        if [ -f "$work/exit" ] || ! worker_pid_is_running "${WORKER_PIDS[$slot]}"; then
          wait_one_job_worker "$slot"
          return
        fi
      done
      sleep 0.01
    done
  }

  for script in "${SCRIPTS[@]}"; do
    while [ "$active_workers" -ge "$JOBS" ]; do
      wait_one_completed_job_worker
    done
    worker_n=$((worker_n + 1))
    work="$RUN_TMP/w$worker_n"
    mkdir -p "$work/tmp"
    chmod 0700 "$work" "$work/tmp" || die "could not chmod 0700 worker root $work"
    base=$(basename "$script")
    family=$(family_for_basename "$base")
    expected=$(expected_gate_skip_for_family "$family")
    printf 'FM_TEST_BEGIN %s %s family=%s expected_gate_skip=%s\n' \
      "$(now_iso)" "$script" "$family" "$expected"
    set -m
    (
      set +e
      set +m
      child_pid=
      # shellcheck disable=SC2329 # Invoked indirectly by worker signal traps.
      stop_child() {
        trap - INT TERM HUP
        if [ -n "$child_pid" ]; then
          kill -TERM "$child_pid" 2>/dev/null || true
          wait "$child_pid" 2>/dev/null || true
        fi
        exit 143
      }
      trap stop_child INT TERM HUP
      while [ ! -f "$work/start" ]; do
        sleep 0.01
      done
      export TMPDIR="$work/tmp"
      export TMP="$work/tmp"
      clear_ambient_fleet_environment
      cd "$ROOT" || exit 1
      begin_ms=$(now_ms)
      bash "$script" >"$work/output" 2>&1 &
      child_pid=$!
      wait "$child_pid"
      rc=$?
      child_pid=
      end_ms=$(now_ms)
      duration=$((end_ms - begin_ms))
      if [ "$duration" -lt 0 ]; then
        duration=0
      fi
      printf '%s\n' "$duration" >"$work/duration_ms"
      printf '%s\n' "$rc" >"$work/exit"
      exit 0
    ) &
    worker_pid=$!
    set +m
    WORKER_PIDS[worker_n]=$worker_pid
    register_worker_group "$worker_pid"
    WORKER_IDX[worker_n]=$worker_n
    WORKER_SCRIPTS[worker_n]=$script
    active_workers=$((active_workers + 1))
    : >"$work/start"
  done
  while [ "$active_workers" -gt 0 ]; do
    wait_one_completed_job_worker
  done
  WORKER_PIDS=()

  for script in "${SERIAL_PHASE_SCRIPTS[@]+"${SERIAL_PHASE_SCRIPTS[@]}"}"; do
    run_one_serial "$script"
  done
fi

RUN_FINISHED_ISO=$(now_iso)
RUN_FINISHED_MS=$(now_ms)
RUN_DURATION=$((RUN_FINISHED_MS - RUN_STARTED_MS))
if [ "$RUN_DURATION" -lt 0 ]; then
  RUN_DURATION=0
fi

printf 'FM_TEST_SUMMARY total=%s failed=%s skipped_gate=%s duration_ms=%s\n' \
  "$TOTAL" "$FAILED" "$SKIPPED_GATE" "$RUN_DURATION"

if [ -s "$FAMILIES_TSV" ]; then
  # Stable family summary order by name.
  sort -t$'\t' -k1,1 "$FAMILIES_TSV" | while IFS=$'\t' read -r name count duration failed_count; do
    printf 'FM_TEST_SUMMARY_FAMILY family=%s count=%s duration_ms=%s failed=%s\n' \
      "$name" "$count" "$duration" "$failed_count"
  done
fi

# Slowest scripts (top 15) from records. Path is the stable tie-breaker.
if [ -s "$RECORDS" ]; then
  rank=1
  sort -t$'\t' -k5,5nr -k1,1 "$RECORDS" | head -n 15 | while IFS=$'\t' read -r path _family _expected _rc duration _gate _baseline _budget _exceeded; do
    printf 'FM_TEST_SLOWEST rank=%s script=%s duration_ms=%s\n' \
      "$rank" "$path" "$duration"
    rank=$((rank + 1))
  done
fi

printf 'FM_TEST_BUDGET_SUMMARY checked=%s exceeded=%s missing=%s mode=%s\n' \
  "$DURATION_BUDGET_CHECKED" "$DURATION_BUDGET_EXCEEDED" "$DURATION_BUDGET_MISSING" "$DURATION_BUDGET_MODE"

if [ -n "$JSON_PATH" ]; then
  mkdir -p "$(dirname "$JSON_PATH")"
  # Families file may be unsorted; write_json reads as-is (deterministic sort in python).
  if [ -s "$FAMILIES_TSV" ]; then
    sort -t$'\t' -k1,1 "$FAMILIES_TSV" -o "$FAMILIES_TSV"
  else
    : >"$FAMILIES_TSV"
  fi
  write_json_artifact "$JSON_PATH" \
    "$RUN_STARTED_ISO" "$RUN_FINISHED_ISO" "$RUN_ID" \
    "$TOTAL" "$FAILED" "$SKIPPED_GATE" "$RUN_DURATION" \
    "$SELECTION_DESC" "$RECORDS" "$FAMILIES_TSV"
  log "wrote timing artifact: $JSON_PATH"
fi

exit "$AGG_RC"
