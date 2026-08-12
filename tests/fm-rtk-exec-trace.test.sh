#!/usr/bin/env bash
set -u

ROOT=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
if [ "$(/usr/bin/uname -s 2>/dev/null)" != Darwin ]; then
  printf 'skip: RTK absolute-exec gate requires Darwin dtruss\n'
  exit 0
fi
if [ ! -x /usr/bin/dtruss ]; then
  printf 'skip: RTK absolute-exec gate requires /usr/bin/dtruss\n'
  exit 0
fi
PROBE=$(mktemp /tmp/fm-rtk-dtruss-probe.XXXXXX 2>/dev/null) || {
  printf 'skip: RTK absolute-exec gate cannot create probe output\n'
  exit 0
}
trap 'rm -f "$PROBE"' EXIT INT TERM
if ! /usr/bin/dtruss -f -t execve /usr/bin/printf '%s' fm-rtk-argv-probe \
  >/dev/null 2>"$PROBE"; then
  printf 'skip: RTK absolute-exec gate lacks dtruss permission\n'
  exit 0
fi
if ! /usr/bin/grep -F fm-rtk-argv-probe "$PROBE" >/dev/null; then
  printf 'skip: RTK absolute-exec gate lacks dtruss argv visibility\n'
  exit 0
fi
rm -f "$PROBE"
trap - EXIT INT TERM

# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-rtk-exec-trace)
TMP_ROOT=$(CDPATH='' cd -- "$TMP_ROOT" && pwd -P)
CONTROL=$TMP_ROOT/control
PROJECT=$TMP_ROOT/project
HOME_ROOT=$TMP_ROOT/home
LIFECYCLE_ROOT=$TMP_ROOT/lifecycle-root
FAKEBIN=$TMP_ROOT/fakebin
mkdir -p "$CONTROL" "$PROJECT" "$HOME_ROOT/config" "$HOME_ROOT/data" \
  "$HOME_ROOT/state/.lock" "$LIFECYCLE_ROOT" "$FAKEBIN"
cp -R "$ROOT/bin" "$ROOT/lib" "$LIFECYCLE_ROOT/"
VERIFIER=$LIFECYCLE_ROOT/lib/Firstmate/rtk-run
ARTIFACT=$HOME_ROOT/data/rtk
cat >"$VERIFIER" <<EOF
#!/bin/sh
/usr/bin/touch '$CONTROL/verifier-called'
exit 97
EOF
chmod +x "$VERIFIER"
cat >"$ARTIFACT" <<EOF
#!/bin/sh
/usr/bin/touch '$CONTROL/artifact-called'
exit 98
EOF
chmod +x "$ARTIFACT"
printf 'disabled\n' >"$HOME_ROOT/config/rtk"
cat >"$FAKEBIN/git" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>'$CONTROL/git-calls'
exec /usr/bin/git "\$@"
EOF
chmod +x "$FAKEBIN/git"

check_trace() {
  /usr/bin/python3 - "$1" "$VERIFIER" "$ARTIFACT" <<'PY'
import os
import re
import sys

trace_path, verifier, artifact = sys.argv[1:]
quoted = re.compile(r'"((?:\\.|[^"\\])*)"')
records = []
for line in open(trace_path, encoding="utf-8", errors="replace"):
    if "execve(" not in line:
        continue
    values = []
    for raw in quoted.findall(line):
        value = re.sub(r"\\0+$", "", raw)
        value = value.replace(r'\\"', '"').replace(r"\\\\", "\\")
        values.append(os.path.normpath(value) if value.startswith("/") else value)
    if values:
        records.append((values[0], values[1:]))

if not records or not any(argv for _, argv in records):
    raise SystemExit(2)

for executable, argv in records:
    argv0 = argv[0] if argv else executable
    forbidden_paths = {os.path.normpath(verifier), os.path.normpath(artifact)}
    if executable in forbidden_paths or any(value in forbidden_paths for value in argv):
        raise SystemExit(1)
    if os.path.basename(executable) == "rtk" or os.path.basename(argv0) == "rtk":
        raise SystemExit(1)
    if os.path.basename(executable) == "git" or os.path.basename(argv0) == "git":
        arguments = argv[1:] if argv else []
        if any(argument in {"status", "diff", "log"} for argument in arguments):
            raise SystemExit(1)
PY
}

printf '%s\n' 'execve("/bin/echo\0", "echo\0", "/private/harmless/rtk\0") = 0' \
  >"$CONTROL/parser-harmless.trace"
printf '%s\n' 'execve("/private/tools/rtk\0", "rtk\0") = 0' \
  >"$CONTROL/parser-rtk.trace"
printf '%s\n' 'execve("/usr/bin/git\0", "git\0", "status\0") = 0' \
  >"$CONTROL/parser-git.trace"
check_trace "$CONTROL/parser-harmless.trace"
expect_code 0 "$?" "trace parser rejected a harmless argument ending in /rtk"
check_trace "$CONTROL/parser-rtk.trace"
expect_code 1 "$?" "trace parser missed RTK as the executed program"
check_trace "$CONTROL/parser-git.trace"
expect_code 1 "$?" "trace parser missed a forbidden Git command tuple"

assert_trace_clean() {
  local name=$1 trace=$2 rc
  check_trace "$trace"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    printf 'skip: RTK absolute-exec gate lacks parseable dtruss argv records\n'
    exit 0
  fi
  [ "$rc" -eq 0 ] \
    || fail "$name trace observed verifier, artifact, RTK, or project-orientation Git execution"
  assert_absent "$CONTROL/verifier-called" "$name invoked the tracked verifier"
  assert_absent "$CONTROL/artifact-called" "$name invoked the private artifact"
  if [ -s "$CONTROL/git-calls" ] && /usr/bin/grep -E '(^| )(status|diff|log)( |$)' "$CONTROL/git-calls" >/dev/null; then
    fail "$name invoked a PATH project-orientation Git command"
  fi
}

trace_lifecycle() {
  local name=$1 rc trace=$CONTROL/$1.trace
  shift
  rm -f "$CONTROL/verifier-called" "$CONTROL/artifact-called" "$CONTROL/git-calls"
  (cd "$PROJECT" && /usr/bin/dtruss -f -t execve /usr/bin/env \
    FM_HOME="$HOME_ROOT" PATH="$FAKEBIN:/usr/bin:/bin" "$@") \
    >"$CONTROL/$name.stdout" 2>"$trace"
  rc=$?
  expect_code 0 "$rc" "$name failed under execution tracing"
  assert_trace_clean "$name" "$trace"
}

trace_lifecycle bootstrap env FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip \
  "$LIFECYCLE_ROOT/bin/fm-bootstrap.sh"
trace_lifecycle session-start env FM_SESSION_START_TIMEOUT=20 \
  "$LIFECYCLE_ROOT/bin/fm-session-start.sh"
pass "fm-rtk: absolute execution traces prove lifecycle inertness"
