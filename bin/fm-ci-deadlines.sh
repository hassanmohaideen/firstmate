#!/usr/bin/env bash
# fm-ci-deadlines.sh - single owner of the CI test-job deadline budget.
#
# Both sourced and executed.
#
# Executed:  bin/fm-ci-deadlines.sh [t0_epoch] >> "$GITHUB_ENV"
#     Prints the five FM_TEST_*_EPOCH assignments a deadline-consuming test job
#     exports so bin/fm-test-run.sh and the credential-domain executor share one
#     absolute schedule. With no argument it reads FM_TEST_JOB_T0_EPOCH (the T0
#     a job anchors before checkout) and falls back to the current second.
#
# Sourced:   defines FM_CI_DEADLINE_OFFSET_{ORDINARY,TERMINAL,CLEANUP,CEILING}
#     and fm_ci_deadline_env, so bin/fm-test-run.sh derives its local-run
#     defaults from the same constants instead of re-hardcoding them, and so
#     tests can assert the schedule without scraping this file.
#
# The schedule sits under the GitHub `timeout-minutes: 10` hard ceiling that
# every CI job declares. timeout-minutes is the outer guillotine: it fails a
# hung job RED, but it kills mid-step and loses cleanup and evidence. These
# interior deadlines are the graceful inner bounds - the executor terminalizes a
# hung test as a RED incomplete result at its own per-test deadline, and these
# job deadlines reserve time to finish publications, drop credentials, and
# upload evidence before the guillotine falls:
#
#     ordinary  T0+480s (8:00)  stop scheduling / running ordinary test work
#     terminal  T0+500s (8:20)  finish terminal publications
#     cleanup   T0+530s (8:50)  credential and process cleanup must be done
#     ceiling   T0+600s (10:00) matches the job's own timeout-minutes hard cap
#
# The ordinary bound sets each required serial test's per-test kill deadline
# (execution_deadline minus the time reserved for the tests still queued behind
# it). The heaviest test in a balanced serial shard runs first with its whole
# tail reserved, so it gets the least allowance of any test in the shard; that
# allowance must stay comfortably above the test's own duration budget (2x its
# measured baseline) or ordinary CI runner variance terminalizes a non-regressed
# test RED. As the serial lane grew, the ordinary bound at T0+430s left the
# heaviest-first tests only ~58s of margin over baseline - below their 2x
# budgets - so a slow-but-healthy runner killed them. T0+480s restores that
# margin for every shard at once without reshuffling the balanced packing.
#
# A single hung test therefore cannot wedge the whole job: it is bounded and
# terminalized RED at its own deadline, and these job deadlines plus
# timeout-minutes are the backstops if an entire lane overruns. A consuming job
# anchors T0 as its first step, before checkout, so the budget covers checkout
# and tool setup and not only the test run itself.

FM_CI_DEADLINE_OFFSET_ORDINARY=480
FM_CI_DEADLINE_OFFSET_TERMINAL=500
FM_CI_DEADLINE_OFFSET_CLEANUP=530
FM_CI_DEADLINE_OFFSET_CEILING=600

# fm_ci_deadline_env <t0_epoch>
# Print the five NAME=VALUE deadline assignments for the given T0 epoch.
fm_ci_deadline_env() {
  local t0=$1
  printf 'FM_TEST_JOB_T0_EPOCH=%s\n' "$t0"
  printf 'FM_TEST_ORDINARY_DEADLINE_EPOCH=%s\n' "$((t0 + FM_CI_DEADLINE_OFFSET_ORDINARY))"
  printf 'FM_TEST_TERMINAL_DEADLINE_EPOCH=%s\n' "$((t0 + FM_CI_DEADLINE_OFFSET_TERMINAL))"
  printf 'FM_TEST_CLEANUP_DEADLINE_EPOCH=%s\n' "$((t0 + FM_CI_DEADLINE_OFFSET_CLEANUP))"
  printf 'FM_TEST_CEILING_DEADLINE_EPOCH=%s\n' "$((t0 + FM_CI_DEADLINE_OFFSET_CEILING))"
}

# Executed directly: emit the assignments. Sourced: define only, mutate nothing.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -eu
  t0=${1:-${FM_TEST_JOB_T0_EPOCH:-$(date +%s)}}
  case "$t0" in
    '' | *[!0-9]*)
      printf 'fm-ci-deadlines.sh: T0 epoch must be a non-negative integer, got %s\n' "$t0" >&2
      exit 2
      ;;
  esac
  fm_ci_deadline_env "$t0"
fi
