#!/usr/bin/env bash
# tests/home-isolation.sh - drop inherited Firstmate home routing before a test.
#
# Source this first from every test file (tests/lib.sh sources it for you):
#   # shellcheck source=tests/home-isolation.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/home-isolation.sh"
#
# A test run directly from a Firstmate operator or worker session inherits that
# session's home routing. A fixture that then sets only FM_HOME to its scratch
# home still resolves state through an inherited FM_STATE_OVERRIDE, and every
# script that defaults FM_HOME resolves the live home, so the test writes into
# a real home. The contained CI runner never forwards these variables
# (bin/fm-test-supervisor.py builds a default-deny child environment), so
# removing them here makes a direct run resolve exactly what CI resolves.
#
# Removed: FM_HOME, FM_SESSION_START_STAGE_FILE, and every FM_*_OVERRIDE,
# FM_*_HOME, and FM_*_ROOT selector. FM_TEST_* harness inputs and every other
# FM_* setting (for example a live test's operator-supplied binary path) are
# kept, so opt-in configuration still reaches the tests that read it.

fm_test_drop_inherited_home_routing() {
  local name
  while IFS= read -r name; do
    case "$name" in
      FM_TEST_*) ;;
      FM_HOME|FM_SESSION_START_STAGE_FILE|FM_*_OVERRIDE|FM_*_HOME|FM_*_ROOT)
        unset "$name"
        ;;
    esac
  done < <(compgen -e)
}

fm_test_drop_inherited_home_routing
