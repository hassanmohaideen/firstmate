#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-rtk)
SYSTEM_ROOT=$TMP_ROOT/system
AMBIENT=$TMP_ROOT/ambient
CONTROL=$TMP_ROOT/control
RAW_LOG=$CONTROL/raw.log
OBSERVER_LOG=$CONTROL/observer.log
OUT=$TMP_ROOT/out
ERR=$TMP_ROOT/err
HELPER=$TMP_ROOT/fm-rtk-test-driver.sh
LAST_RC=0
mkdir -p "$SYSTEM_ROOT/usr/bin" "$SYSTEM_ROOT/bin" "$SYSTEM_ROOT/usr/sbin" "$SYSTEM_ROOT/sbin" \
  "$SYSTEM_ROOT/opt/homebrew/opt/ripgrep/bin" "$AMBIENT" "$CONTROL"
cp "$ROOT/lib/Firstmate/rtk-run" "$HELPER"
chmod +x "$HELPER"

for pair in \
  /usr/bin/awk:usr/bin/awk /usr/bin/env:usr/bin/env /usr/bin/wc:usr/bin/wc \
  /usr/bin/tr:usr/bin/tr /usr/bin/mktemp:usr/bin/mktemp /usr/bin/shasum:usr/bin/shasum \
  /bin/rm:bin/rm /bin/chmod:bin/chmod /bin/mkdir:bin/mkdir /bin/cp:bin/cp /bin/sleep:bin/sleep; do
  original=${pair%%:*}
  wrapper=$SYSTEM_ROOT/${pair#*:}
  printf '#!/bin/bash\nexec %q "$@"\n' "$original" > "$wrapper"
  chmod +x "$wrapper"
done

cat > "$SYSTEM_ROOT/usr/bin/uname" <<'SH'
#!/bin/bash
case "$1" in -s) printf 'Darwin\n' ;; -m) printf 'arm64\n' ;; *) exit 2 ;; esac
SH

make_raw_tool() {
  local path=$1 name=$2
  cat > "$path" <<SH
#!/bin/bash
printf '%s|' '$name' >> '$RAW_LOG'
printf '%q ' "\$@" >> '$RAW_LOG'
printf '\n' >> '$RAW_LOG'
printf 'raw stdout\n'
printf 'raw stderr\n' >&2
[ "\${RAW_FAIL:-0}" = 0 ] || exit "\$RAW_FAIL"
SH
  chmod +x "$path"
}
make_raw_tool "$SYSTEM_ROOT/usr/bin/git" git
make_raw_tool "$SYSTEM_ROOT/bin/ls" ls
make_raw_tool "$SYSTEM_ROOT/opt/homebrew/opt/ripgrep/bin/rg" rg
chmod +x "$SYSTEM_ROOT/usr/bin/uname"

for name in uname shasum env git rg ls; do
  cat > "$AMBIENT/$name" <<SH
#!/bin/bash
printf '%s\n' '$name' >> '$OBSERVER_LOG'
exit 91
SH
  chmod +x "$AMBIENT/$name"
done

make_home() {
  local name=$1 home artifact
  home=$TMP_ROOT/$name
  mkdir -p "$home/config" "$home/data/tools/rtk/v0.45.0/aarch64-apple-darwin"
  printf 'v0.45.0\n' > "$home/config/rtk"
  artifact=$home/data/tools/rtk/v0.45.0/aarch64-apple-darwin/rtk
  cat > "$artifact" <<SH
#!/bin/bash
count=0
mode=ok
[ ! -f '$CONTROL/version.count' ] || read -r count < '$CONTROL/version.count'
[ ! -f '$CONTROL/mode' ] || read -r mode < '$CONTROL/mode'
if [ "\${1:-}" = --version ]; then
  count=\$((count + 1))
  printf '%s\n' "\$count" > '$CONTROL/version.count'
  case "\$mode:\$count" in
    nonzero:*) exit 42 ;;
    wrong:*|second-wrong:2) printf 'rtk 9.9.9\n'; exit 0 ;;
    noisy:*) printf 'rtk 0.45.0\n'; printf 'noise\n' >&2; exit 0 ;;
    hang:*) while :; do /bin/sleep 1; done ;;
  esac
  printf 'rtk 0.45.0\n'
  exit 0
fi
printf '%s\n' "\$0" > '$CONTROL/executed-path'
printf '%s\n' "\$@" > '$CONTROL/compact-args'
printf '%s\n' "HOME=\$HOME" "PATH=\$PATH" "DB=\$RTK_DB_PATH" \
  "TELEMETRY=\$RTK_TELEMETRY_DISABLED" "TEE=\$RTK_TEE" "TOML=\$RTK_NO_TOML" \
  "PAGER=\$PAGER" "GIT_PAGER=\$GIT_PAGER" > '$CONTROL/compact-env'
case "\$mode" in
  compact-fail) printf 'compact stdout\n'; printf 'compact stderr\n' >&2; exit 23 ;;
  compact-hang) trap 'exit 143' TERM; while :; do /bin/sleep 1; done ;;
  *) printf 'compact stdout\n'; printf 'compact stderr\n' >&2 ;;
esac
SH
  chmod +x "$artifact"
  printf '%s\n' "$home"
}

artifact_path() {
  printf '%s/data/tools/rtk/v0.45.0/aarch64-apple-darwin/rtk' "$1"
}

artifact_sha() {
  /usr/bin/shasum -a 256 "$(artifact_path "$1")" | awk '{print $1}'
}

reset_evidence() {
  rm -f "$RAW_LOG" "$OBSERVER_LOG" "$OUT" "$ERR" "$CONTROL/version.count" "$CONTROL/mode" \
    "$CONTROL/executed-path" "$CONTROL/compact-args" "$CONTROL/compact-env"
}

run_helper() {
  local home=$1 sha
  shift
  reset_evidence
  if [ -f "$(artifact_path "$home")" ] && [ ! -L "$(artifact_path "$home")" ]; then
    sha=$(artifact_sha "$home")
  else
    sha=unavailable
  fi
  printf '%s\n' "${RTK_TEST_MODE:-ok}" > "$CONTROL/mode"
  PATH="$AMBIENT:/usr/bin:/bin" FM_HOME="$home" FM_RTK_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" \
    FM_RTK_TEST_SHA256="$sha" "$HELPER" "$@" > "$OUT" 2> "$ERR"
  LAST_RC=$?
}

assert_raw() {
  local expected=$1
  assert_present "$RAW_LOG" "raw fallback did not run"
  assert_grep "$expected" "$RAW_LOG" "raw fallback argv was not exact"
  [ "$(wc -l < "$RAW_LOG" | tr -d '[:space:]')" = 1 ] || fail "raw fallback ran more than once"
}

assert_no_ambient() {
  assert_absent "$OBSERVER_LOG" "caller PATH wrapper was executed"
}

test_public_launcher_sanitizes_startup_environment() {
  local marker rc=0
  marker=$CONTROL/startup-injected
  cat > "$TMP_ROOT/startup-attacker" <<EOF
#!/bin/bash
touch '$marker'
EOF
  chmod +x "$TMP_ROOT/startup-attacker"
  BASH_ENV="$TMP_ROOT/startup-attacker" ENV="$TMP_ROOT/startup-attacker" \
    FM_RTK_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" FM_RTK_TEST_SHA256=spoofed \
    "$ROOT/bin/fm-rtk.sh" search --json > "$OUT" 2> "$ERR" || rc=$?
  expect_code 64 "$rc" "public admission refusal returned the wrong status"
  assert_absent "$marker" "caller shell startup code reached the RTK runner"
  assert_absent "$RAW_LOG" "public admission refusal ran raw"
  pass "fm-rtk: public launcher removes hostile startup and test overrides"
}

test_admission_and_trusted_raw() {
  local home rc
  home=$(make_home admission)
  reset_evidence
  PATH="$AMBIENT:/usr/bin:/bin" FM_HOME="$home" FM_RTK_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" \
    "$HELPER" search --json . > "$OUT" 2> "$ERR"; rc=$?
  expect_code 64 "$rc" "option-like search should be refused"
  assert_absent "$RAW_LOG" "admission refusal ran raw"
  assert_absent "$CONTROL/version.count" "admission refusal ran RTK"

  rm -f "$home/config/rtk"
  RAW_FAIL=37 run_helper "$home" git-status
  expect_code 37 "$LAST_RC" "raw status was not preserved"
  assert_raw 'git|status '
  assert_grep 'raw stdout' "$OUT" "raw stdout was lost"
  assert_grep 'raw stderr' "$ERR" "raw stderr was lost"
  assert_no_ambient
  pass "fm-rtk: admission executes nothing and fallback uses trusted exact argv once"
}

test_spoofing_and_private_execution() {
  local home path root hostile
  home=$(make_home compact)
  # shellcheck disable=SC2016 # The command substitution is hostile literal test data.
  hostile='needle;$(touch LEAK)|private/path'
  run_helper "$home" search "$hostile" "$TMP_ROOT"
  expect_code 0 "$LAST_RC" "compact search failed"
  assert_no_ambient
  assert_absent "$RAW_LOG" "successful compact command also ran raw"
  assert_grep 'rg' "$CONTROL/compact-args" "compact search verb changed"
  assert_grep "$hostile" "$CONTROL/compact-args" "hostile data was not preserved"
  assert_no_grep "$hostile" "$ERR" "argument data leaked to diagnostics"
  path=$(< "$CONTROL/executed-path")
  case "$path" in */fm-rtk.*/invocation/rtk) ;; *) fail "RTK did not execute from the private copy: $path" ;; esac
  [ "$path" != "$(artifact_path "$home")" ] || fail "source artifact executed directly"
  root=${path%/invocation/rtk}
  assert_absent "$root" "private invocation root was not cleaned"
  assert_grep "HOME=$root/home" "$CONTROL/compact-env" "HOME was not private"
  assert_grep "PATH=$SYSTEM_ROOT/opt/homebrew/opt/ripgrep/bin:$SYSTEM_ROOT/usr/bin:$SYSTEM_ROOT/bin:$SYSTEM_ROOT/usr/sbin:$SYSTEM_ROOT/sbin" \
    "$CONTROL/compact-env" "caller PATH reached RTK"
  assert_grep 'TELEMETRY=1' "$CONTROL/compact-env" "telemetry was not disabled"
  assert_grep 'TEE=0' "$CONTROL/compact-env" "tee was not disabled"
  assert_grep 'TOML=1' "$CONTROL/compact-env" "project filters were not disabled"
  pass "fm-rtk: spoofed PATH is ignored and only a private verified copy executes"
}

test_fixed_semantic_verbs() {
  local home expected actual
  home=$(make_home verbs)
  while IFS='|' read -r invocation expected; do
    # shellcheck disable=SC2086 # Fixture rows intentionally encode the public argv.
    run_helper "$home" $invocation
    expect_code 0 "$LAST_RC" "$invocation failed"
    actual=$(tr '\n' ' ' < "$CONTROL/compact-args")
    actual=${actual% }
    [ "$actual" = "$expected" ] || fail "$invocation mapped to unexpected compact argv: $actual"
    assert_absent "$RAW_LOG" "$invocation also ran raw"
  done <<ROWS
git-log|git log -n 50 --decorate
git-diff|git diff
git-diff --cached|git diff --cached
git-status|git status
list $TMP_ROOT|ls $TMP_ROOT
search needle $TMP_ROOT|rg needle $TMP_ROOT
ROWS

  reset_evidence
  PATH="$AMBIENT:/usr/bin:/bin" FM_HOME="$home" FM_RTK_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" \
    "$HELPER" exec git status > "$OUT" 2> "$ERR"; LAST_RC=$?
  expect_code 64 "$LAST_RC" "generic command escape should be refused"
  assert_absent "$RAW_LOG" "generic command refusal ran raw"
  assert_absent "$CONTROL/version.count" "generic command refusal ran RTK"
  pass "fm-rtk: every fixed semantic verb maps exactly and generic execution is refused"
}

test_artifact_and_version_failures() {
  local home artifact mode started
  home=$(make_home failures)
  artifact=$(artifact_path "$home")

  mv "$artifact" "$artifact.real"; ln -s rtk.real "$artifact"
  run_helper "$home" git-status
  assert_raw 'git|status '
  assert_absent "$CONTROL/version.count" "symlink artifact executed"
  rm "$artifact"; mv "$artifact.real" "$artifact"

  rm "$artifact"; mkfifo "$artifact"
  run_helper "$home" git-status
  assert_raw 'git|status '
  assert_absent "$CONTROL/version.count" "FIFO artifact executed"
  rm "$artifact"; home=$(make_home failures)

  for mode in wrong nonzero noisy second-wrong; do
    RTK_TEST_MODE=$mode run_helper "$home" git-status
    expect_code 0 "$LAST_RC" "$mode preflight should fall back"
    assert_raw 'git|status '
    assert_absent "$CONTROL/executed-path" "$mode preflight started compact execution"
  done

  started=$(date +%s)
  RTK_TEST_MODE=hang run_helper "$home" git-status
  [ $(( $(date +%s) - started )) -lt 9 ] || fail "version preflight was not bounded"
  assert_raw 'git|status '
  assert_absent "$CONTROL/executed-path" "hanging version started compact execution"
  pass "fm-rtk: invalid artifacts and bounded version failures fall back once"
}

test_copy_race_and_copy_failure() {
  local home artifact sha real_shasum
  home=$(make_home race)
  artifact=$(artifact_path "$home")
  sha=$(artifact_sha "$home")
  real_shasum=$SYSTEM_ROOT/usr/bin/shasum.real
  mv "$SYSTEM_ROOT/usr/bin/shasum" "$real_shasum"
  cat > "$SYSTEM_ROOT/usr/bin/shasum" <<SH
#!/bin/bash
'$real_shasum' "\$@"
if [ "\${REPLACE_AFTER_HASH:-0}" = 1 ] && [ ! -f '$CONTROL/replaced' ]; then
  : > '$CONTROL/replaced'
  printf '#!/bin/bash\nprintf malicious > %q\n' '$CONTROL/malicious-ran' > '$artifact'
  chmod +x '$artifact'
fi
SH
  chmod +x "$SYSTEM_ROOT/usr/bin/shasum"
  reset_evidence
  rm -f "$CONTROL/replaced" "$CONTROL/malicious-ran"
  PATH="$AMBIENT:/usr/bin:/bin" FM_HOME="$home" FM_RTK_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" \
    FM_RTK_TEST_SHA256="$sha" REPLACE_AFTER_HASH=1 "$HELPER" git-status > "$OUT" 2> "$ERR"
  LAST_RC=$?
  expect_code 0 "$LAST_RC" "replacement race should fall back"
  assert_raw 'git|status '
  assert_absent "$CONTROL/malicious-ran" "replacement artifact executed"
  assert_absent "$CONTROL/executed-path" "replacement reached compact execution"
  mv "$real_shasum" "$SYSTEM_ROOT/usr/bin/shasum"

  home=$(make_home copy-fail)
  mv "$SYSTEM_ROOT/bin/cp" "$SYSTEM_ROOT/bin/cp.real"
  printf '#!/bin/bash\nexit 1\n' > "$SYSTEM_ROOT/bin/cp"
  chmod +x "$SYSTEM_ROOT/bin/cp"
  run_helper "$home" git-status
  assert_raw 'git|status '
  assert_absent "$CONTROL/version.count" "copy failure executed RTK"
  mv "$SYSTEM_ROOT/bin/cp.real" "$SYSTEM_ROOT/bin/cp"

  home=$(make_home utility-fail)
  mv "$SYSTEM_ROOT/usr/bin/shasum" "$SYSTEM_ROOT/usr/bin/shasum.missing"
  run_helper "$home" git-status
  expect_code 0 "$LAST_RC" "missing compact-only utility should fall back"
  assert_raw 'git|status '
  assert_absent "$CONTROL/version.count" "missing compact-only utility executed RTK"
  mv "$SYSTEM_ROOT/usr/bin/shasum.missing" "$SYSTEM_ROOT/usr/bin/shasum"
  pass "fm-rtk: replacement races and setup failures fall back without executing candidates"
}

test_post_start_no_rerun_and_signal_cleanup() {
  local home pid path root rc=0 i=0 sha
  home=$(make_home outcomes)
  RTK_TEST_MODE=compact-fail run_helper "$home" git-status
  expect_code 23 "$LAST_RC" "compact failure status was not preserved"
  assert_grep 'compact stdout' "$OUT" "compact stdout was lost"
  assert_grep 'compact stderr' "$ERR" "compact stderr was lost"
  assert_absent "$RAW_LOG" "compact failure reran raw"

  reset_evidence
  sha=$(artifact_sha "$home")
  printf 'compact-hang\n' > "$CONTROL/mode"
  PATH="$AMBIENT:/usr/bin:/bin" FM_HOME="$home" FM_RTK_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" \
    FM_RTK_TEST_SHA256="$sha" "$HELPER" git-status > "$OUT" 2> "$ERR" &
  pid=$!
  while [ ! -f "$CONTROL/executed-path" ] && [ "$i" -lt 100 ]; do /bin/sleep 0.05; i=$((i + 1)); done
  assert_present "$CONTROL/executed-path" "signal fixture did not start compact execution"
  path=$(< "$CONTROL/executed-path"); root=${path%/invocation/rtk}
  kill -TERM "$pid"
  wait "$pid" || rc=$?
  expect_code 143 "$rc" "TERM status was not preserved"
  assert_absent "$root" "TERM left the private root behind"
  assert_absent "$RAW_LOG" "TERM reran raw"
  pass "fm-rtk: compact outcomes preserve streams/status and signals clean without rerun"
}

test_public_launcher_sanitizes_startup_environment
test_admission_and_trusted_raw
test_spoofing_and_private_execution
test_fixed_semantic_verbs
test_artifact_and_version_failures
test_copy_race_and_copy_failure
test_post_start_no_rerun_and_signal_cleanup
