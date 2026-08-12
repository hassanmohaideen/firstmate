#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-rtk)
SYSTEM_ROOT=$TMP_ROOT/system
AMBIENT=$TMP_ROOT/ambient
CONTROL=$TMP_ROOT/control
OUT=$TMP_ROOT/out
ERR=$TMP_ROOT/err
HELPER=$TMP_ROOT/fm-rtk-test-driver.sh
mkdir -p "$SYSTEM_ROOT/usr/bin" "$AMBIENT" "$CONTROL"
cp "$ROOT/bin/fm-rtk.sh" "$HELPER"
chmod +x "$HELPER"

printf '#!/bin/bash\nexec /usr/bin/perl "$@"\n' > "$SYSTEM_ROOT/usr/bin/perl"
cat > "$SYSTEM_ROOT/usr/bin/uname" <<'SH'
#!/bin/bash
case "$1" in -s) printf '%s\n' "${TEST_OS:-Darwin}" ;; -m) printf '%s\n' "${TEST_ARCH:-arm64}" ;; *) exit 2 ;; esac
SH
chmod +x "$SYSTEM_ROOT/usr/bin/perl" "$SYSTEM_ROOT/usr/bin/uname"

for name in uname perl shasum env git rg ls; do
  cat > "$AMBIENT/$name" <<SH
#!/bin/bash
printf '%s\n' '$name' >> '$CONTROL/ambient.log'
exit 91
SH
  chmod +x "$AMBIENT/$name"
done

make_home() {
  local name=$1 home artifact
  home=$TMP_ROOT/$name
  artifact=$home/data/tools/rtk/v0.45.0/aarch64-apple-darwin/rtk
  mkdir -p "${artifact%/*}"
  cat > "$artifact" <<SH
#!/bin/bash
printf 'executed\n' >> '$CONTROL/executed.log'
touch '$home/project-write'
SH
  chmod +x "$artifact"
  printf '%s\n' "$home"
}

artifact_path() {
  printf '%s/data/tools/rtk/v0.45.0/aarch64-apple-darwin/rtk' "$1"
}

artifact_sha() {
  /usr/bin/shasum -a 256 "$(artifact_path "$1")" | /usr/bin/awk '{print $1}'
}

run_verify() {
  local home=$1 sha=${2:-}
  rm -f "$OUT" "$ERR" "$CONTROL/ambient.log" "$CONTROL/executed.log"
  [ -n "$sha" ] || sha=$(artifact_sha "$home")
  PATH="$AMBIENT:/usr/bin:/bin" FM_HOME="$home" FM_RTK_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" \
    FM_RTK_TEST_SHA256="$sha" "$HELPER" verify > "$OUT" 2> "$ERR"
  LAST_RC=$?
}

assert_never_executed() {
  local home=$1
  assert_absent "$CONTROL/executed.log" "artifact was executed"
  assert_absent "$home/project-write" "artifact modified the candidate home"
  assert_absent "$CONTROL/ambient.log" "caller PATH utility was executed"
}

test_public_interface_and_static_verification() {
  local home help rc=0
  home=$(make_home accepted)
  help=$($HELPER --help) || fail "help failed"
  assert_contains "$help" "fm-rtk.sh verify" "help omitted the verification interface"

  run_verify "$home"
  expect_code 0 "$LAST_RC" "reviewed artifact verification failed"
  assert_grep "execution remains disabled" "$OUT" "success did not state the execution boundary"
  assert_never_executed "$home"

  "$HELPER" git-status > "$OUT" 2> "$ERR" || rc=$?
  expect_code 64 "$rc" "project command request was not refused"
  assert_never_executed "$home"

  rc=0
  "$HELPER" verify extra > "$OUT" 2> "$ERR" || rc=$?
  expect_code 64 "$rc" "verification argument passthrough was not refused"
  assert_never_executed "$home"
  pass "fm-rtk: public interface only inspects reviewed artifact bytes"
}

test_platform_path_and_hash_boundaries() {
  local home artifact rc=0
  home=$(make_home boundaries)
  artifact=$(artifact_path "$home")

  rm -f "$CONTROL/executed.log"
  PATH="$AMBIENT:/usr/bin:/bin" FM_HOME="$home" FM_RTK_TEST_OS=Linux \
    FM_RTK_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" FM_RTK_TEST_SHA256="$(artifact_sha "$home")" \
    "$HELPER" verify > "$OUT" 2> "$ERR" || rc=$?
  expect_code 69 "$rc" "non-Darwin platform was accepted"
  assert_never_executed "$home"

  rc=0
  PATH="$AMBIENT:/usr/bin:/bin" FM_HOME="$home" FM_RTK_TEST_ARCH=x86_64 \
    FM_RTK_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" FM_RTK_TEST_SHA256="$(artifact_sha "$home")" \
    "$HELPER" verify > "$OUT" 2> "$ERR" || rc=$?
  expect_code 69 "$rc" "non-arm64 platform was accepted"
  assert_never_executed "$home"

  run_verify "$home" deadbeef
  expect_code 69 "$LAST_RC" "wrong checksum was accepted"
  assert_never_executed "$home"

  mv "$artifact" "$artifact.other"
  mkdir -p "$home/data/tools/rtk/v0.45.0/wrong-platform"
  mv "$artifact.other" "$home/data/tools/rtk/v0.45.0/wrong-platform/rtk"
  run_verify "$home" deadbeef
  expect_code 69 "$LAST_RC" "artifact outside the exact reviewed path was discovered"
  assert_never_executed "$home"
  pass "fm-rtk: platform, checksum, and exact artifact path are enforced"
}

test_type_mode_and_config_nonactivation() {
  local home artifact target started
  home=$(make_home shapes)
  artifact=$(artifact_path "$home")
  mkdir -p "$home/config"
  printf 'v0.45.0\n' > "$home/config/rtk"

  chmod -x "$artifact"
  run_verify "$home"
  expect_code 69 "$LAST_RC" "non-executable artifact was accepted"
  assert_never_executed "$home"
  chmod +x "$artifact"

  mv "$artifact" "$artifact.real"
  ln -s rtk.real "$artifact"
  run_verify "$home" "$(/usr/bin/shasum -a 256 "$artifact.real" | /usr/bin/awk '{print $1}')"
  expect_code 69 "$LAST_RC" "symlink artifact was accepted"
  assert_never_executed "$home"
  rm "$artifact"

  target=$artifact.real
  rm "$target"
  mkfifo "$artifact"
  started=$SECONDS
  run_verify "$home" deadbeef
  [ $((SECONDS - started)) -lt 3 ] || fail "FIFO artifact inspection was not bounded"
  expect_code 69 "$LAST_RC" "FIFO artifact was accepted"
  assert_never_executed "$home"
  rm "$artifact"

  home=$(make_home config-ignored)
  mkdir -p "$home/config"
  printf 'malicious activation\n' > "$home/config/rtk"
  run_verify "$home"
  expect_code 0 "$LAST_RC" "unrelated config data activated or blocked static inspection"
  assert_never_executed "$home"
  pass "fm-rtk: symlink, FIFO, mode, and config activation boundaries hold"
}

test_public_interface_and_static_verification
test_platform_path_and_hash_boundaries
test_type_mode_and_config_nonactivation
