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
  pass "fm-rtk: hostile shell and Perl startup state is removed"
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

test_public_nonexecuting_interface
test_caller_named_test_driver_cannot_inject_tools
test_hostile_startup_environments_are_removed
test_exact_path_type_and_permission_boundaries
test_intermediate_symlinks_are_rejected
