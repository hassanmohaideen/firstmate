#!/usr/bin/env bash
# tests/fm-ci-deadlines.test.sh - unit tests for the single owner of the CI
# test-job deadline budget (bin/fm-ci-deadlines.sh). Pins the schedule, its
# ordering, its tie to the 10-minute timeout-minutes ceiling, and both the
# sourced (define-only) and executed (emit) contracts. Pure, no backend.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-ci-deadlines.sh"

# --- sourced contract: defines constants and a function, emits nothing --------

# shellcheck disable=SC1090
sourced_output=$(. "$SCRIPT")
[ -z "$sourced_output" ] || fail "sourcing must define only and print nothing, got: $sourced_output"

# shellcheck source=bin/fm-ci-deadlines.sh
. "$SCRIPT"

[ "$FM_CI_DEADLINE_OFFSET_ORDINARY" -eq 480 ] || fail "ordinary offset must be 480"
[ "$FM_CI_DEADLINE_OFFSET_TERMINAL" -eq 500 ] || fail "terminal offset must be 500"
[ "$FM_CI_DEADLINE_OFFSET_CLEANUP" -eq 530 ] || fail "cleanup offset must be 530"
[ "$FM_CI_DEADLINE_OFFSET_CEILING" -eq 600 ] || fail "ceiling offset must be 600"
pass "sourcing defines the four deadline offsets and prints nothing"

# The interior deadlines must be strictly ordered and the ceiling must equal the
# job's own timeout-minutes: 10 hard cap (10 * 60 = 600s), so the interior
# budget and the outer guillotine can never silently disagree.
[ "$FM_CI_DEADLINE_OFFSET_ORDINARY" -lt "$FM_CI_DEADLINE_OFFSET_TERMINAL" ] \
  && [ "$FM_CI_DEADLINE_OFFSET_TERMINAL" -lt "$FM_CI_DEADLINE_OFFSET_CLEANUP" ] \
  && [ "$FM_CI_DEADLINE_OFFSET_CLEANUP" -lt "$FM_CI_DEADLINE_OFFSET_CEILING" ] \
  || fail "deadline offsets must be strictly increasing ordinary<terminal<cleanup<ceiling"
[ "$FM_CI_DEADLINE_OFFSET_CEILING" -eq $((10 * 60)) ] \
  || fail "ceiling offset must equal the timeout-minutes: 10 hard cap in seconds"
pass "deadline offsets are strictly increasing and the ceiling matches the 10-minute job cap"

# --- fm_ci_deadline_env prints exactly the five assignments for a given T0 -----

expected_env() { # <t0>
  local t0=$1
  printf 'FM_TEST_JOB_T0_EPOCH=%s\n' "$t0"
  printf 'FM_TEST_ORDINARY_DEADLINE_EPOCH=%s\n' "$((t0 + 480))"
  printf 'FM_TEST_TERMINAL_DEADLINE_EPOCH=%s\n' "$((t0 + 500))"
  printf 'FM_TEST_CLEANUP_DEADLINE_EPOCH=%s\n' "$((t0 + 530))"
  printf 'FM_TEST_CEILING_DEADLINE_EPOCH=%s\n' "$((t0 + 600))"
}

[ "$(fm_ci_deadline_env 1000)" = "$(expected_env 1000)" ] \
  || fail "fm_ci_deadline_env produced the wrong schedule for T0=1000"
pass "fm_ci_deadline_env emits the five correct epoch assignments"

# --- executed contract: T0 from arg, from env, and from the clock -------------

[ "$("$SCRIPT" 1000)" = "$(expected_env 1000)" ] \
  || fail "executed with an explicit T0 arg produced the wrong schedule"

[ "$(FM_TEST_JOB_T0_EPOCH=2000 "$SCRIPT")" = "$(expected_env 2000)" ] \
  || fail "executed reading FM_TEST_JOB_T0_EPOCH produced the wrong schedule"
pass "executed mode anchors T0 from an argument or FM_TEST_JOB_T0_EPOCH"

# With neither arg nor env it anchors on the clock: five lines, integer T0, and
# the ceiling exactly 600s past T0.
clock_out=$(unset FM_TEST_JOB_T0_EPOCH; "$SCRIPT")
[ "$(printf '%s\n' "$clock_out" | grep -c .)" -eq 5 ] \
  || fail "clock-anchored run must print five assignments"
clock_t0=$(printf '%s\n' "$clock_out" | sed -n 's/^FM_TEST_JOB_T0_EPOCH=//p')
clock_ceiling=$(printf '%s\n' "$clock_out" | sed -n 's/^FM_TEST_CEILING_DEADLINE_EPOCH=//p')
case "$clock_t0" in '' | *[!0-9]*) fail "clock-anchored T0 must be an integer, got '$clock_t0'" ;; esac
[ "$((clock_ceiling - clock_t0))" -eq 600 ] \
  || fail "clock-anchored ceiling must be 600s past T0"
pass "executed mode with no input anchors T0 on the clock and keeps the 600s ceiling"

# --- executed contract: a non-integer T0 is refused RED, never silently used --

set +e
bad_out=$("$SCRIPT" not-a-number 2>&1)
bad_rc=$?
set -e 2>/dev/null || true
[ "$bad_rc" -eq 2 ] || fail "a non-integer T0 must exit 2, got $bad_rc"
printf '%s\n' "$bad_out" | grep -q 'non-negative integer' \
  || fail "a rejected T0 must explain the requirement: $bad_out"
pass "executed mode rejects a non-integer T0 with a clear non-zero failure"
