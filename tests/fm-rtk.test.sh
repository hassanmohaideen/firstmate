#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-rtk)
AMBIENT=$TMP_ROOT/ambient
CONTROL=$TMP_ROOT/control
OUT=$TMP_ROOT/out
ERR=$TMP_ROOT/err
HELPER=$ROOT/bin/fm-rtk.sh
DRIVER=$TMP_ROOT/fm-rtk-test-driver.sh
mkdir -p "$AMBIENT" "$CONTROL"
ln -s "$HELPER" "$DRIVER"

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
  chmod 500 "$artifact"
  printf '%s\n' "$home"
}

artifact_path() {
  printf '%s/data/tools/rtk/v0.45.0/aarch64-apple-darwin/rtk' "$1"
}

run_verify() {
  local home=$1
  rm -f "$OUT" "$ERR" "$CONTROL/ambient.log" "$CONTROL/executed.log"
  PATH="$AMBIENT:/usr/bin:/bin" FM_HOME="$home" "$HELPER" verify > "$OUT" 2> "$ERR"
  LAST_RC=$?
}

assert_never_executed() {
  local home=$1
  assert_absent "$CONTROL/executed.log" "artifact was executed"
  assert_absent "$home/project-write" "artifact modified its home"
  assert_absent "$CONTROL/ambient.log" "caller PATH utility was executed"
}

assert_real_platform_result() {
  local context=$1
  expect_code 69 "$LAST_RC" "$context returned the wrong status"
  if [ "$(/usr/bin/uname -s)" = Darwin ] && [ "$(/usr/bin/uname -m)" = arm64 ]; then
    assert_grep "artifact hash mismatch" "$ERR" "$context did not use the pinned checksum"
  else
    assert_grep "unsupported platform" "$ERR" "$context did not enforce the real platform"
  fi
}

test_public_nonexecuting_interface() {
  local home help rc=0
  home=$(make_home public-interface)
  help=$($HELPER --help) || fail "help failed"
  assert_contains "$help" "fm-rtk.sh verify" "help omitted verification"

  run_verify "$home"
  assert_real_platform_result "verification"
  assert_never_executed "$home"

  "$HELPER" git-status > "$OUT" 2> "$ERR" || rc=$?
  expect_code 64 "$rc" "project command request was not refused"
  assert_never_executed "$home"

  rc=0
  "$HELPER" verify extra > "$OUT" 2> "$ERR" || rc=$?
  expect_code 64 "$rc" "argument passthrough was not refused"
  assert_never_executed "$home"
  pass "fm-rtk: public interface never executes project commands"
}

test_caller_named_test_driver_cannot_inject_tools() {
  local home hostile marker rc=0
  home=$(make_home test-driver-symlink)
  hostile=$TMP_ROOT/hostile-system
  marker=$CONTROL/injected-tool.log
  mkdir -p "$hostile/usr/bin"
  for name in env perl; do
    cat > "$hostile/usr/bin/$name" <<SH
#!/bin/bash
printf '%s\n' '$name' >> '$marker'
'$(artifact_path "$home")'
printf '%s\n' 'fm-rtk: reviewed v0.45.0 artifact bytes verified; execution remains disabled'
exit 0
SH
    chmod +x "$hostile/usr/bin/$name"
  done
  rm -f "$marker" "$CONTROL/executed.log"

  FM_HOME="$home" FM_RTK_TEST_SYSTEM_ROOT="$hostile" FM_RTK_TEST_OS=Darwin \
    FM_RTK_TEST_ARCH=arm64 FM_RTK_TEST_SHA256=anything \
    "$DRIVER" verify > "$OUT" 2> "$ERR" || rc=$?
  LAST_RC=$rc
  assert_real_platform_result "caller-named symlink verification"
  assert_absent "$marker" "caller-selected inspection tool executed"
  assert_never_executed "$home"
  pass "fm-rtk: invocation name cannot activate dependency injection"
}

test_hostile_startup_environments_are_removed() {
  local home artifact shell_attacker perl_attacker marker rc=0
  home=$(make_home hostile-environment)
  artifact=$(artifact_path "$home")
  marker=$CONTROL/startup-injected.log
  shell_attacker=$TMP_ROOT/shell-attacker
  cat > "$shell_attacker" <<SH
#!/bin/bash
/bin/echo shell >> '$marker'
'$artifact'
SH
  chmod +x "$shell_attacker"
  perl_attacker=$TMP_ROOT/perl-attacker
  mkdir -p "$perl_attacker"
  cat > "$perl_attacker/Attacker.pm" <<SH
package Attacker;
BEGIN { open(my \$fh, '>>', '$marker') or die; print \$fh "perl\\n"; }
1;
SH
  rm -f "$marker" "$CONTROL/executed.log" "$CONTROL/ambient.log"

  (
    function printf() { /usr/bin/touch "$marker"; return 91; }
    export -f printf
    /usr/bin/env PATH="$AMBIENT" BASH_ENV="$shell_attacker" ENV="$shell_attacker" \
      _FM_RTK_CLEAN_ENV=firstmate-rtk-verifier-v1 \
      CDPATH="$TMP_ROOT" SHELLOPTS=xtrace BASHOPTS=extdebug GLOBIGNORE='*' \
      PERL5OPT=-MAttacker PERL5LIB="$perl_attacker" PERLLIB="$perl_attacker" \
      PERL_LOCAL_LIB_ROOT="$perl_attacker" PERL_MB_OPT="--install_base $perl_attacker" \
      PERL_MM_OPT="INSTALL_BASE=$perl_attacker" PERLIO=scalar PERL_UNICODE=S \
      PERL_USE_UNSAFE_INC=1 FM_HOME="$home" "$HELPER" verify > "$OUT" 2> "$ERR"
  ) || rc=$?
  LAST_RC=$rc
  assert_real_platform_result "hostile-environment verification"
  assert_absent "$marker" "caller startup code or exported function executed"
  assert_never_executed "$home"
  pass "fm-rtk: spoofed sentinel and hostile startup state are removed"
}

test_exact_path_type_and_permission_boundaries() {
  local home artifact started rc
  home=$(make_home wrong-path)
  artifact=$(artifact_path "$home")
  mv "$artifact" "$artifact.other"
  run_verify "$home"
  expect_code 69 "$LAST_RC" "artifact outside the exact path was accepted"
  assert_grep "invalid artifact" "$ERR" "wrong path failure was not reported"
  assert_never_executed "$home"

  home=$(make_home non-executable)
  artifact=$(artifact_path "$home")
  chmod 400 "$artifact"
  run_verify "$home"
  expect_code 69 "$LAST_RC" "artifact without effective execute permission was accepted"
  if [ "$(/usr/bin/uname -s)" = Darwin ] && [ "$(/usr/bin/uname -m)" = arm64 ]; then
    assert_grep "artifact is not executable" "$ERR" "effective permission failure was not reported"
  fi
  assert_never_executed "$home"

  home=$(make_home final-symlink)
  artifact=$(artifact_path "$home")
  mv "$artifact" "$artifact.real"
  ln -s rtk.real "$artifact"
  run_verify "$home"
  expect_code 69 "$LAST_RC" "final artifact symlink was accepted"
  assert_never_executed "$home"

  home=$(make_home fifo)
  artifact=$(artifact_path "$home")
  rm "$artifact"
  mkfifo "$artifact"
  started=$SECONDS
  run_verify "$home"
  [ $((SECONDS - started)) -lt 3 ] || fail "FIFO inspection was not bounded"
  expect_code 69 "$LAST_RC" "FIFO artifact was accepted"
  assert_never_executed "$home"
  pass "fm-rtk: exact path, type, and permission boundaries hold"
}

test_intermediate_symlinks_are_rejected() {
  local component home current escaped index
  index=0
  for component in data tools rtk v0.45.0 aarch64-apple-darwin; do
    home=$(make_home "intermediate-$index")
    current=$home
    case "$component" in
      data) current=$current/data ;;
      tools) current=$current/data/tools ;;
      rtk) current=$current/data/tools/rtk ;;
      v0.45.0) current=$current/data/tools/rtk/v0.45.0 ;;
      aarch64-apple-darwin) current=$current/data/tools/rtk/v0.45.0/aarch64-apple-darwin ;;
    esac
    escaped=$TMP_ROOT/escaped-$index
    mv "$current" "$escaped"
    ln -s "$escaped" "$current"
    run_verify "$home"
    expect_code 69 "$LAST_RC" "symlink $component component was accepted"
    assert_never_executed "$home"
    index=$((index + 1))
  done
  pass "fm-rtk: every intermediate symlink is rejected"
}

expect_value() {
  [ "$1" = "$2" ] || fail "$3: expected '$1', got '$2'"
}

module_digest() {
  /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/perl -MDigest::SHA=sha256_hex -e '
    open(my $fh, "<", $ARGV[0]) or die;
    binmode($fh);
    local $/;
    print sha256_hex(<$fh>);
  ' "$1"
}

run_module_verify() {
  local home=$1 sha=$2 euid=$3 owner=$4 group=$5 groups=$6
  MODULE_RESULT=$(/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/perl -I "$ROOT/lib" \
    -MFirstmate::RTKVerifier=success_message,verify_artifact -e '
      my ($home, $sha, $euid, $owner, $group, $groups) = @ARGV;
      my $result = verify_artifact(
        home => $home,
        expected_sha => $sha,
        expected_os => "Darwin",
        expected_arch => "arm64",
        observed_os => "Darwin",
        observed_arch => "arm64",
        effective_uid => $euid,
        effective_groups => [split(/,/, $groups)],
        artifact_uid => $owner,
        artifact_gid => $group,
        parts => [qw(data tools rtk v0.45.0 aarch64-apple-darwin)],
        filename => "rtk",
        timeout => 1,
      );
      print $result eq "verified" ? success_message("v0.45.0") : $result;
    ' "$home" "$sha" "$euid" "$owner" "$group" "$groups") || fail "module verifier failed"
}

test_verifier_acceptance_and_permission_branches() {
  local home artifact sha expected
  expected='fm-rtk: reviewed v0.45.0 artifact bytes verified; execution remains disabled'
  home=$(make_home module-valid)
  artifact=$(artifact_path "$home")
  sha=$(module_digest "$artifact")

  chmod 500 "$artifact"
  run_module_verify "$home" "$sha" 1001 1001 2001 3001
  expect_value "$expected" "$MODULE_RESULT" "owner execute permission was not admitted"

  chmod 410 "$artifact"
  run_module_verify "$home" "$sha" 1001 2001 3001 3001
  expect_value "$expected" "$MODULE_RESULT" "group execute permission was not admitted"

  chmod 401 "$artifact"
  run_module_verify "$home" "$sha" 1001 2001 3001 4001
  expect_value "$expected" "$MODULE_RESULT" "other execute permission was not admitted"

  chmod 400 "$artifact"
  run_module_verify "$home" "$sha" 1001 2001 3001 4001
  expect_value not-executable "$MODULE_RESULT" "ineffective execute permission was admitted"

  chmod 500 "$artifact"
  run_module_verify "$home" "0$sha" 1001 1001 3001 4001
  expect_value hash-mismatch "$MODULE_RESULT" "wrong digest was admitted"
  assert_never_executed "$home"
  pass "fm-rtk: valid digest and effective permission branches are verified"
}

test_module_path_and_type_rejections() {
  local home artifact sha escaped
  home=$(make_home module-final-symlink)
  artifact=$(artifact_path "$home")
  sha=$(module_digest "$artifact")
  mv "$artifact" "$artifact.real"
  ln -s rtk.real "$artifact"
  run_module_verify "$home" "$sha" 1001 1001 3001 4001
  expect_value invalid-artifact "$MODULE_RESULT" "module accepted a final symlink"
  assert_never_executed "$home"

  home=$(make_home module-intermediate-symlink)
  artifact=$(artifact_path "$home")
  sha=$(module_digest "$artifact")
  escaped=$TMP_ROOT/module-escaped-data
  mv "$home/data" "$escaped"
  ln -s "$escaped" "$home/data"
  run_module_verify "$home" "$sha" 1001 1001 3001 4001
  expect_value invalid-artifact "$MODULE_RESULT" "module accepted an intermediate symlink"
  assert_never_executed "$home"

  home=$(make_home module-fifo)
  artifact=$(artifact_path "$home")
  rm "$artifact"
  mkfifo "$artifact"
  run_module_verify "$home" deadbeef 1001 1001 3001 4001
  expect_value invalid-artifact "$MODULE_RESULT" "module accepted a non-regular artifact"
  assert_never_executed "$home"
  pass "fm-rtk: module rejects symlink and non-regular artifacts"
}

test_public_nonexecuting_interface
test_caller_named_test_driver_cannot_inject_tools
test_hostile_startup_environments_are_removed
test_exact_path_type_and_permission_boundaries
test_intermediate_symlinks_are_rejected
test_verifier_acceptance_and_permission_branches
test_module_path_and_type_rejections
