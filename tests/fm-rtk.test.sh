#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-rtk)
TMP_ROOT=$(CDPATH='' cd -- "$TMP_ROOT" && pwd -P)
SYSTEM_ROOT=$TMP_ROOT/system
CONTROL=$TMP_ROOT/control
PROJECT=$TMP_ROOT/project
HELPER=$TMP_ROOT/fm-rtk-test-driver.sh
OUT=$TMP_ROOT/out
ERR=$TMP_ROOT/err
LAST_RC=0
mkdir -p "$SYSTEM_ROOT/usr/bin" "$CONTROL" "$PROJECT"
cp "$ROOT/lib/Firstmate/rtk-run" "$HELPER"
chmod +x "$HELPER"
cat > "$SYSTEM_ROOT/usr/bin/uname" <<'SH'
#!/bin/bash
case "$1" in -s) printf 'Darwin\n' ;; -m) printf 'arm64\n' ;; *) exit 2 ;; esac
SH
chmod +x "$SYSTEM_ROOT/usr/bin/uname"

artifact_path() { printf '%s/data/tools/rtk/v0.45.0/aarch64-apple-darwin/rtk' "$1"; }
make_home() {
  local home=$TMP_ROOT/$1 artifact
  mkdir -p "$home/data/tools/rtk/v0.45.0/aarch64-apple-darwin"
  artifact=$(artifact_path "$home")
  cat > "$artifact" <<SH
#!/bin/bash
touch '$CONTROL/artifact-executed'
printf 'hostile artifact ran\n'
SH
  chmod +x "$artifact"
  printf '%s\n' "$home"
}
artifact_sha() { /usr/bin/shasum -a 256 "$(artifact_path "$1")" | /usr/bin/awk '{print $1}'; }
run_verify() {
  local home=$1 sha=${2:-}
  rm -f "$OUT" "$ERR" "$CONTROL/artifact-executed"
  [ -n "$sha" ] || sha=$(artifact_sha "$home" 2>/dev/null || printf unavailable)
  (cd "$PROJECT" && FM_HOME="$home" FM_RTK_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" \
    FM_RTK_TEST_SHA256="$sha" TMPDIR="$PROJECT" PATH=/usr/bin:/bin \
    "$HELPER" verify) >"$OUT" 2>"$ERR"
  LAST_RC=$?
}
assert_project_unchanged() {
  local after
  after=$(find "$PROJECT" -mindepth 1 -print | LC_ALL=C sort)
  [ -z "$after" ] || fail "verifier wrote inside the project: $after"
}

# The public verifier has one exact non-executing operation and deterministic output.
test_exact_verification_contract() {
  local home sha
  home=$(make_home accepted)
  sha=$(artifact_sha "$home")
  run_verify "$home" "$sha"
  expect_code 0 "$LAST_RC" "valid pinned artifact was rejected"
  [ "$(cat "$OUT")" = 'fm-rtk: verified RTK v0.45.0 artifact (not executed)' ] \
    || fail "verification success output changed"
  [ ! -s "$ERR" ] || fail "verification success emitted stderr"
  assert_absent "$CONTROL/artifact-executed" "verifier executed the artifact"
  assert_project_unchanged

  for args in '' 'git-status' 'verify extra' 'search token .'; do
    rm -f "$CONTROL/artifact-executed"
    # shellcheck disable=SC2086 # Fixture rows intentionally encode public argv.
    FM_HOME="$home" FM_RTK_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" "$HELPER" $args >"$OUT" 2>"$ERR"
    expect_code 64 "$?" "non-verifier request was admitted: $args"
    assert_absent "$CONTROL/artifact-executed" "refused request executed the artifact"
  done
  pass "fm-rtk: exact verification contract is non-executing"
}

# Every home and artifact component is opened relative to an already-opened parent.
test_types_and_symlinks_fail_closed() {
  local valid outside home target
  valid=$(make_home valid-components)
  outside=$(make_home outside-components)

  home=$TMP_ROOT/home-through-link
  mkdir -p "$TMP_ROOT/real-parent"
  mv "$outside" "$TMP_ROOT/real-parent/home"
  outside=$TMP_ROOT/real-parent/home
  ln -s "$TMP_ROOT/real-parent" "$TMP_ROOT/linked-parent"
  run_verify "$TMP_ROOT/linked-parent/home" "$(artifact_sha "$outside")"
  expect_code 65 "$LAST_RC" "intermediate home symlink was accepted"

  home=$TMP_ROOT/final-home-link
  ln -s "$outside" "$home"
  run_verify "$home" "$(artifact_sha "$outside")"
  expect_code 65 "$LAST_RC" "final home symlink was accepted"

  home=$TMP_ROOT/data-link
  mkdir -p "$home"
  ln -s "$outside/data" "$home/data"
  run_verify "$home" "$(artifact_sha "$outside")"
  expect_code 65 "$LAST_RC" "artifact parent symlink was accepted"

  home=$(make_home final-link)
  target=$(artifact_path "$home")
  mv "$target" "$target.real"
  ln -s rtk.real "$target"
  run_verify "$home" "$(/usr/bin/shasum -a 256 "$target.real" | /usr/bin/awk '{print $1}')"
  expect_code 65 "$LAST_RC" "artifact symlink was accepted"

  home=$(make_home non-executable)
  chmod 600 "$(artifact_path "$home")"
  run_verify "$home"
  expect_code 65 "$LAST_RC" "non-executable artifact was accepted"

  home=$(make_home directory-artifact)
  target=$(artifact_path "$home")
  rm "$target"; mkdir "$target"
  run_verify "$home" unavailable
  expect_code 65 "$LAST_RC" "directory artifact was accepted"

  home=$(make_home fifo-artifact)
  target=$(artifact_path "$home")
  rm "$target"; mkfifo "$target"
  run_verify "$home" unavailable
  expect_code 65 "$LAST_RC" "FIFO artifact was accepted"

  run_verify "$valid" 0000000000000000000000000000000000000000000000000000000000000000
  expect_code 65 "$LAST_RC" "hash mismatch was accepted"
  assert_absent "$CONTROL/artifact-executed" "failed identity check executed an artifact"
  assert_project_unchanged
  pass "fm-rtk: path, type, mode, and hash checks fail closed"
}

# Production launch sanitizes startup, PATH, Perl, test-seam, and temporary overrides.
test_public_launcher_ignores_hostile_environment() {
  local home before after rc
  home=$(make_home hostile-env)
  printf 'touch %q\n' "$CONTROL/startup-ran" > "$CONTROL/startup"
  before=$(find "$PROJECT" -mindepth 1 -print | LC_ALL=C sort)
  FM_HOME="$home" FM_RTK_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" FM_RTK_TEST_SHA256="$(artifact_sha "$home")" \
    TMPDIR="$PROJECT" PATH="$CONTROL" PERL5OPT='-e system("touch '$CONTROL'/perl-ran")' \
    BASH_ENV="$CONTROL/startup" ENV="$CONTROL/startup" \
    "$ROOT/bin/fm-rtk.sh" verify >"$OUT" 2>"$ERR"
  rc=$?
  [ "$rc" -ne 0 ] || fail "test seams bypassed the production platform or hash pin"
  after=$(find "$PROJECT" -mindepth 1 -print | LC_ALL=C sort)
  [ "$before" = "$after" ] || fail "caller TMPDIR caused a project write"
  assert_absent "$CONTROL/startup-ran" "launcher sourced hostile shell startup"
  assert_absent "$CONTROL/perl-ran" "launcher honored hostile Perl startup"
  assert_absent "$CONTROL/artifact-executed" "launcher executed the artifact"
  pass "fm-rtk: public launcher sanitizes hostile caller overrides"
}

# Platform rejection occurs before any artifact access.
test_platform_rejection() {
  local home
  home=$(make_home platform)
  cat > "$SYSTEM_ROOT/usr/bin/uname" <<'SH'
#!/bin/bash
case "$1" in -s) printf 'Linux\n' ;; -m) printf 'x86_64\n' ;; esac
SH
  chmod +x "$SYSTEM_ROOT/usr/bin/uname"
  run_verify "$home"
  expect_code 69 "$LAST_RC" "unsupported platform was accepted"
  [ "$(cat "$ERR")" = 'fm-rtk: unsupported platform (requires Darwin arm64)' ] \
    || fail "platform refusal output changed"
  assert_absent "$CONTROL/artifact-executed" "platform rejection executed artifact"
  assert_project_unchanged
  pass "fm-rtk: unsupported platform fails before inspection"
}

test_exact_verification_contract
test_types_and_symlinks_fail_closed
test_public_launcher_ignores_hostile_environment
test_platform_rejection
