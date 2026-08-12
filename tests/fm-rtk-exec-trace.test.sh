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

assert_trace_clean() {
  local name=$1 trace=$2
  if ! /usr/bin/python3 - "$trace" "$VERIFIER" "$ARTIFACT" <<'PY'
import os
import re
import sys

trace_path, verifier, artifact = sys.argv[1:]
quoted = re.compile(r'"((?:\\.|[^"\\])*)"')
for line in open(trace_path, encoding="utf-8", errors="replace"):
    if "execve(" not in line:
        continue
    values = []
    for raw in quoted.findall(line):
        value = re.sub(r"\\0+$", "", raw)
        value = value.replace(r'\\"', '"').replace(r"\\\\", "\\")
        values.append(value)
    if not values:
        continue
    argv = [os.path.normpath(value) if value.startswith("/") else value for value in values]
    forbidden_paths = {os.path.normpath(verifier), os.path.normpath(artifact)}
    if any(value in forbidden_paths for value in argv):
        raise SystemExit(1)
    if any(os.path.basename(value) == "rtk" for value in argv):
        raise SystemExit(1)
    git_positions = [index for index, value in enumerate(argv) if os.path.basename(value) == "git"]
    if any(any(arg in {"status", "diff", "log"} for arg in argv[index + 1:]) for index in git_positions):
        raise SystemExit(1)
PY
  then
    fail "$name trace observed verifier, artifact, RTK, or project-orientation Git execution"
  fi
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
