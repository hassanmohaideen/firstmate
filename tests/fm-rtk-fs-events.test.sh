#!/usr/bin/env bash
set -u

ROOT=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
PYTHON3=$(command -v python3 2>/dev/null || true)
MONITOR=$ROOT/tests/helpers/fs-event-monitor.py
if [ -z "$PYTHON3" ]; then
  printf 'skip: RTK filesystem-event gate requires python3\n'
  exit 0
fi
if ! "$PYTHON3" "$MONITOR" --probe >/dev/null 2>&1; then
  printf 'skip: RTK filesystem-event gate requires usable kqueue or inotify\n'
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-rtk-fs-events)
TMP_ROOT=$(CDPATH='' cd -- "$TMP_ROOT" && pwd -P)
CONTROL=$TMP_ROOT/control
PROJECT=$TMP_ROOT/project
HOME_ROOT=$TMP_ROOT/home
LIFECYCLE_ROOT=$TMP_ROOT/lifecycle-root
FAKEBIN=$TMP_ROOT/fakebin
mkdir -p "$CONTROL" "$PROJECT" "$HOME_ROOT/config" "$HOME_ROOT/state/.lock" \
  "$LIFECYCLE_ROOT" "$FAKEBIN"

begin_monitor() {
  local name=$1
  shift
  READY=$CONTROL/$name.ready
  EVENTS=$CONTROL/$name.events
  STOP=$CONTROL/$name.stop
  rm -f "$READY" "$EVENTS" "$STOP" "$STOP.observed"
  "$PYTHON3" "$MONITOR" --ready "$READY" --events "$EVENTS" --stop "$STOP" "$@" \
    >"$CONTROL/$name.out" 2>"$CONTROL/$name.err" &
  MONITOR_PID=$!
  local attempts=0
  while [ ! -e "$READY" ] && [ "$attempts" -lt 200 ]; do
    kill -0 "$MONITOR_PID" 2>/dev/null || break
    sleep 0.01
    attempts=$((attempts + 1))
  done
  [ -e "$READY" ] || fail "$name filesystem monitor did not become ready"
}

end_monitor() {
  local name=$1 expectation=$2 rc
  : > "$STOP"
  wait "$MONITOR_PID"
  rc=$?
  expect_code 0 "$rc" "$name filesystem monitor failed"
  case "$expectation" in
    clean) [ ! -s "$EVENTS" ] || fail "$name emitted a filesystem write event" ;;
    changed) [ -s "$EVENTS" ] || fail "$name filesystem mutation was not observed" ;;
  esac
}

self_test_monitor() {
  local watched=$TMP_ROOT/self-test attempts
  mkdir -p "$watched"
  printf 'same bytes\n' >"$watched/file"

  begin_monitor same-byte "$watched"
  printf 'same bytes\n' >"$watched/file"
  end_monitor same-byte changed

  begin_monitor replacement "$watched"
  printf 'same bytes\n' >"$watched/replacement"
  mv "$watched/replacement" "$watched/file"
  end_monitor replacement changed

  begin_monitor transient "$watched"
  : >"$watched/transient"
  rm "$watched/transient"
  end_monitor transient changed

  begin_monitor stop-time "$watched"
  : >"$STOP"
  attempts=0
  while [ ! -e "$STOP.observed" ] && [ "$attempts" -lt 200 ]; do
    kill -0 "$MONITOR_PID" 2>/dev/null || break
    sleep 0.01
    attempts=$((attempts + 1))
  done
  [ -e "$STOP.observed" ] || fail "stop-time monitor handshake was not observed"
  printf 'same bytes\n' >"$watched/file"
  end_monitor stop-time changed
}

prepare_lifecycle() {
  local tool
  cp -R "$ROOT/bin" "$ROOT/lib" "$LIFECYCLE_ROOT/"
  cat >"$LIFECYCLE_ROOT/lib/Firstmate/rtk-run" <<EOF
#!/bin/sh
/usr/bin/touch '$CONTROL/verifier-called'
exit 97
EOF
  chmod +x "$LIFECYCLE_ROOT/lib/Firstmate/rtk-run"
  printf 'disabled\n' >"$HOME_ROOT/config/rtk"
  printf 'private-config\n' >"$HOME_ROOT/config/sentinel"
  for tool in rtk fm-rtk.sh brew npm installer curl wget activate pre-commit post-checkout; do
    cat >"$FAKEBIN/$tool" <<EOF
#!/bin/sh
/usr/bin/touch '$CONTROL/forbidden-called'
exit 97
EOF
    chmod +x "$FAKEBIN/$tool"
  done
  cat >"$FAKEBIN/git" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>'$CONTROL/git-calls'
exec /usr/bin/git "\$@"
EOF
  chmod +x "$FAKEBIN/git"
}

run_monitored_lifecycle() {
  local name=$1 rc
  shift
  rm -f "$CONTROL/verifier-called" "$CONTROL/forbidden-called" "$CONTROL/git-calls"
  begin_monitor "$name" "$PROJECT" "$HOME_ROOT/config"
  (cd "$PROJECT" && FM_HOME="$HOME_ROOT" PATH="$FAKEBIN:/usr/bin:/bin" "$@") \
    >"$CONTROL/$name.stdout" 2>"$CONTROL/$name.stderr"
  rc=$?
  end_monitor "$name" clean
  expect_code 0 "$rc" "$name failed"
  assert_absent "$CONTROL/verifier-called" "$name invoked the RTK verifier"
  assert_absent "$CONTROL/forbidden-called" "$name invoked a forbidden lifecycle command"
  if [ -s "$CONTROL/git-calls" ] && grep -E '(^| )(status|diff|log)( |$)' "$CONTROL/git-calls" >/dev/null; then
    fail "$name invoked a project-orientation Git command"
  fi
}

self_test_monitor
prepare_lifecycle
run_monitored_lifecycle bootstrap env FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip \
  "$LIFECYCLE_ROOT/bin/fm-bootstrap.sh"
run_monitored_lifecycle session-start env FM_SESSION_START_TIMEOUT=20 \
  "$LIFECYCLE_ROOT/bin/fm-session-start.sh"
pass "fm-rtk: filesystem events prove lifecycle write inertness"
