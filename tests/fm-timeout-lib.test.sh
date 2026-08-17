#!/usr/bin/env bash
# tests/fm-timeout-lib.test.sh - unit tests for the bounded-execution primitive
# (bin/fm-timeout-lib.sh) that underlies CI hung-test containment. A hung test
# must surface as a RED failure (exit 124), never a skip or a silent pass, and a
# grandchild that ignores TERM must not outlive the bound. Pure processes, no
# harness and no backend. Exercised under both the auto-detected mechanism and
# the dependency-free bash fallback so the guarantee holds on every runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

# A positive bound is a hard requirement of the primitive; the library's own
# header calls out that a non-positive bound disables the deadline. These tests
# only pass positive bounds.

run_timed_rc() { # <seconds> <command...> -> echoes the resulting rc
  local rc=0
  fm_run_timed "$@" >/dev/null 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

# --- the mechanism selector honors the dependency-free override ---------------

[ "$(FM_TIMEOUT_MECHANISM_OVERRIDE=bash fm_timeout_mechanism)" = bash ] \
  || fail "FM_TIMEOUT_MECHANISM_OVERRIDE=bash must force the bash fallback"
case "$(fm_timeout_mechanism)" in
  timeout | gtimeout | perl | bash) : ;;
  *) fail "fm_timeout_mechanism must name a known mechanism" ;;
esac
pass "fm_timeout_mechanism selects a known mechanism and honors the bash override"

# --- the core guarantee, proven under each available mechanism ----------------
#
# Run the same battery under the auto-detected mechanism and, separately, under
# the forced bash fallback. A runner that has GNU timeout still gets the
# fallback path exercised, so no single mechanism is load-bearing.

assert_mechanism() { # <label> [override]
  local label=$1 override=${2:-}
  local tmp rc pidfile grandchild waited

  if [ -n "$override" ]; then
    export FM_TIMEOUT_MECHANISM_OVERRIDE="$override"
  else
    unset FM_TIMEOUT_MECHANISM_OVERRIDE
  fi

  # A fast command returns its own success.
  rc=$(run_timed_rc 5 true)
  [ "$rc" -eq 0 ] || fail "$label: a fast successful command must return 0, got $rc"

  # A fast command returns its own non-zero exit, distinct from the bound code.
  rc=$(run_timed_rc 5 bash -c 'exit 3')
  [ "$rc" -eq 3 ] || fail "$label: a fast failing command must return its own 3, got $rc"

  # An overrunning command hits the bound and returns 124 (RED), not 0.
  rc=$(run_timed_rc 1 sleep 30)
  [ "$rc" -eq 124 ] || fail "$label: an overrun must return the bound code 124, got $rc"

  # A command that ignores TERM in its own process group is still killed and
  # still returns 124: a hung test cannot wedge the run by swallowing TERM.
  tmp=$(fm_test_tmproot "fm-timeout-$label")
  pidfile="$tmp/grandchild.pid"
  cat >"$tmp/hang.sh" <<SH
#!/usr/bin/env bash
trap '' TERM
sleep 300 &
echo \$! > "$pidfile"
wait
SH
  chmod +x "$tmp/hang.sh"
  rc=$(run_timed_rc 1 bash "$tmp/hang.sh")
  [ "$rc" -eq 124 ] \
    || fail "$label: a TERM-ignoring hang must still return 124, got $rc"

  # The grandchild sleep shared the bounded process group, so the group KILL
  # reaped it too - no orphaned worker survives the bound.
  [ -s "$pidfile" ] || fail "$label: hang fixture never recorded its grandchild pid"
  grandchild=$(cat "$pidfile")
  waited=0
  while kill -0 "$grandchild" 2>/dev/null; do
    [ "$waited" -lt 200 ] || fail "$label: grandchild $grandchild outlived the bound"
    sleep 0.05
    waited=$((waited + 1))
  done

  unset FM_TIMEOUT_MECHANISM_OVERRIDE
  pass "$label: fast success/failure pass through, overrun and TERM-ignoring hang are contained RED with no surviving grandchild"
}

assert_mechanism auto
assert_mechanism bash-fallback bash
