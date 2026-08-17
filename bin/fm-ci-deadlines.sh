#!/usr/bin/env bash
# fm-ci-deadlines.sh - single owner of the CI test-job deadline budget.
#
# Both sourced and executed.
#
# Executed:  bin/fm-ci-deadlines.sh [t0_epoch] >> "$GITHUB_ENV"
#     Prints the five FM_TEST_*_EPOCH assignments a test job exports so
#     bin/fm-test-run.sh and the credential-domain executor share one absolute
#     schedule. With no argument it reads FM_TEST_JOB_T0_EPOCH (the T0 a job
#     anchors before checkout) and falls back to the current second.
#
# Sourced:   defines FM_CI_DEADLINE_OFFSET_{ORDINARY,TERMINAL,CLEANUP,CEILING}
#     and fm_ci_deadline_env, so bin/fm-test-run.sh derives its local-run
#     defaults from the same constants instead of re-hardcoding them, and so
#     tests can assert the schedule without scraping this file.
#
# The schedule sits under the GitHub `timeout-minutes: 10` hard ceiling that
# every test job declares. timeout-minutes is the outer guillotine: it fails a
# hung job RED, but it kills mid-step and loses cleanup and evidence. These
# interior deadlines are the graceful inner bounds - the executor terminalizes a
# hung test as a RED incomplete result at its own per-test deadline, and these
# job deadlines reserve time to finish publications, drop credentials, and
# upload evidence before the guillotine falls:
#
#     ordinary  T0+430s (7:10)  stop scheduling / running ordinary test work
#     terminal  T0+450s (7:30)  finish terminal publications
#     cleanup   T0+480s (8:00)  credential and process cleanup must be done
#     ceiling   T0+600s (10:00) matches the job's own timeout-minutes hard cap
#
# A single hung test therefore cannot wedge the whole job: it is bounded and
# terminalized RED at its own deadline, and these job deadlines plus
# timeout-minutes are the backstops if an entire lane overruns. Anchor T0 as the
# first step of a job, before checkout, so the budget covers checkout and tool
# setup and not only the test run itself.

FM_CI_DEADLINE_OFFSET_ORDINARY=430
FM_CI_DEADLINE_OFFSET_TERMINAL=450
FM_CI_DEADLINE_OFFSET_CLEANUP=480
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
