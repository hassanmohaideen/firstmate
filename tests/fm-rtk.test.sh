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
PYTHON3=$(command -v python3 2>/dev/null || true)
EVENT_MONITOR=$ROOT/tests/helpers/fs-event-monitor.py
MONITOR_AVAILABLE=0
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
assert_private_output() {
  local name=$1 content secret
  content=$(cat "$OUT" "$ERR")
  for secret in "$TMP_ROOT" needle-private-search private-fixture-name; do
    case "$content" in *"$secret"*) fail "$name disclosed private input: $secret" ;; esac
  done
}
assert_verification_failure() {
  local name=$1
  expect_code 65 "$LAST_RC" "$name was accepted"
  [ ! -s "$OUT" ] || fail "$name emitted stdout"
  [ "$(cat "$ERR")" = 'fm-rtk: artifact verification failed' ] \
    || fail "$name emitted an unexpected diagnostic"
  assert_private_output "$name"
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

  for args in '' 'git-status' 'verify extra' 'search needle-private-search private-fixture-name'; do
    rm -f "$CONTROL/artifact-executed"
    # shellcheck disable=SC2086 # Fixture rows intentionally encode public argv.
    FM_HOME="$home" FM_RTK_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" "$HELPER" $args >"$OUT" 2>"$ERR"
    expect_code 64 "$?" "non-verifier request was admitted: $args"
    [ ! -s "$OUT" ] || fail "refused request emitted stdout"
    [ "$(cat "$ERR")" = 'fm-rtk: refused request: only the argument verify is accepted' ] \
      || fail "refused request emitted an unexpected diagnostic"
    assert_private_output "refused request"
    assert_absent "$CONTROL/artifact-executed" "refused request executed the artifact"
  done
  FM_HOME="$home" FM_RTK_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" "$HELPER" --help private-fixture-name >"$OUT" 2>"$ERR"
  expect_code 64 "$?" "help accepted an extra argument"
  [ ! -s "$OUT" ] || fail "help refusal emitted stdout"
  [ "$(cat "$ERR")" = 'fm-rtk: refused request: help accepts no arguments' ] \
    || fail "help refusal emitted an unexpected diagnostic"
  assert_private_output "help refusal"

  FM_HOME=private-fixture-name FM_RTK_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" "$HELPER" verify >"$OUT" 2>"$ERR"
  expect_code 65 "$?" "relative FM_HOME was accepted"
  [ ! -s "$OUT" ] || fail "relative-home refusal emitted stdout"
  [ "$(cat "$ERR")" = 'fm-rtk: invalid absolute FM_HOME' ] \
    || fail "relative-home refusal emitted an unexpected diagnostic"
  assert_private_output "relative-home refusal"
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
  assert_verification_failure "intermediate home symlink"

  home=$TMP_ROOT/final-home-link
  ln -s "$outside" "$home"
  run_verify "$home" "$(artifact_sha "$outside")"
  assert_verification_failure "final home symlink"

  home=$TMP_ROOT/data-link
  mkdir -p "$home"
  ln -s "$outside/data" "$home/data"
  run_verify "$home" "$(artifact_sha "$outside")"
  assert_verification_failure "artifact parent symlink"

  home=$(make_home final-link)
  target=$(artifact_path "$home")
  mv "$target" "$target.real"
  ln -s rtk.real "$target"
  run_verify "$home" "$(/usr/bin/shasum -a 256 "$target.real" | /usr/bin/awk '{print $1}')"
  assert_verification_failure "artifact symlink"

  home=$(make_home non-executable)
  chmod 600 "$(artifact_path "$home")"
  run_verify "$home"
  assert_verification_failure "non-executable artifact"

  home=$(make_home owner-not-executable)
  chmod 401 "$(artifact_path "$home")"
  run_verify "$home"
  assert_verification_failure "caller-owned artifact without owner execute"

  home=$(make_home owner-executable)
  chmod 500 "$(artifact_path "$home")"
  run_verify "$home" "$(artifact_sha "$home")"
  expect_code 0 "$LAST_RC" "caller-owned artifact with owner execute was rejected"

  home=$(make_home directory-artifact)
  target=$(artifact_path "$home")
  rm "$target"; mkdir "$target"
  run_verify "$home" unavailable
  assert_verification_failure "directory artifact"

  home=$(make_home fifo-artifact)
  target=$(artifact_path "$home")
  rm "$target"; mkfifo "$target"
  run_verify "$home" unavailable
  assert_verification_failure "FIFO artifact"

  run_verify "$valid" 0000000000000000000000000000000000000000000000000000000000000000
  assert_verification_failure "hash mismatch"
  assert_absent "$CONTROL/artifact-executed" "failed identity check executed an artifact"
  assert_project_unchanged
  pass "fm-rtk: path, type, mode, and hash checks fail closed"
}

test_effective_permission_branches() {
  local row
  for row in \
    '0100 501 501 20 20,80 1' '0001 501 501 20 20,80 0' \
    '0010 501 777 80 20,80 1' '0001 501 777 80 20,80 0' \
    '0010 501 777 90 20,80 0' '0001 501 777 90 20,80 1' \
    '0001 0 777 90 0 1' '0000 0 777 90 0 0'; do
    # shellcheck disable=SC2086 # Rows are deterministic synthetic identities.
    FM_RTK_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" "$HELPER" test-effective-executable $row >"$OUT" 2>"$ERR"
    expect_code 0 "$?" "effective execute permission branch failed for $row"
    [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "permission branch emitted output"
  done
  pass "fm-rtk: effective owner, group, other, and root permissions are exact"
}

run_public_launcher() {
  rm -f "$OUT" "$ERR"
  /usr/bin/env "$@" "$ROOT/bin/fm-rtk.sh" verify >"$OUT" 2>"$ERR"
  LAST_RC=$?
}

assert_launcher_baseline() {
  local name=$1 marker=$2
  expect_code "$PUBLIC_RC" "$LAST_RC" "$name changed launcher status"
  cmp -s "$PUBLIC_OUT" "$OUT" || fail "$name changed launcher stdout"
  cmp -s "$PUBLIC_ERR" "$ERR" || fail "$name changed launcher stderr"
  assert_absent "$marker" "$name executed attacker code"
  assert_absent "$CONTROL/artifact-executed" "$name executed the artifact"
  assert_project_unchanged
}

# Each caller-controlled environment boundary is exercised independently so an
# early interpreter failure cannot mask a later sanitization regression.
test_public_launcher_ignores_hostile_environment() {
  local home marker module_dir
  home=$(make_home hostile-env)
  module_dir=$CONTROL/perl-modules
  mkdir -p "$module_dir"
  FM_HOME="$home" run_public_launcher
  case "$(/usr/bin/uname -s):$(/usr/bin/uname -m)" in
    Darwin:arm64)
      expect_code 65 "$LAST_RC" "known-good launcher did not report the pinned-hash refusal"
      [ ! -s "$OUT" ] || fail "known-good launcher emitted unexpected stdout"
      [ "$(cat "$ERR")" = 'fm-rtk: artifact verification failed' ] \
        || fail "known-good launcher emitted unexpected verification refusal"
      ;;
    *)
      expect_code 69 "$LAST_RC" "known-good launcher did not report unsupported platform"
      [ ! -s "$OUT" ] || fail "known-good launcher emitted unexpected stdout"
      [ "$(cat "$ERR")" = 'fm-rtk: unsupported platform (requires Darwin arm64)' ] \
        || fail "known-good launcher emitted unexpected platform refusal"
      ;;
  esac
  PUBLIC_RC=$LAST_RC
  PUBLIC_OUT=$CONTROL/public.stdout
  PUBLIC_ERR=$CONTROL/public.stderr
  cp "$OUT" "$PUBLIC_OUT"
  cp "$ERR" "$PUBLIC_ERR"

  marker=$CONTROL/path-ran
  mkdir -p "$CONTROL/hostile-path"
  for tool in env perl bash uname; do
    printf '#!/bin/sh\ntouch %q\nexit 99\n' "$marker" > "$CONTROL/hostile-path/$tool"
    chmod +x "$CONTROL/hostile-path/$tool"
  done
  FM_HOME="$home" run_public_launcher PATH="$CONTROL/hostile-path"
  assert_launcher_baseline PATH "$marker"

  for variable in BASH_ENV ENV; do
    case "$variable" in BASH_ENV) marker=$CONTROL/bash-env-ran ;; ENV) marker=$CONTROL/env-ran ;; esac
    printf 'touch %q\n' "$marker" > "$CONTROL/$variable"
    FM_HOME="$home" run_public_launcher "$variable=$CONTROL/$variable"
    assert_launcher_baseline "$variable" "$marker"
  done

  marker=$CONTROL/perl5opt-ran
  cat > "$module_dir/Hostile.pm" <<EOF
package Hostile;
BEGIN { system('/usr/bin/touch', '$marker') }
1;
EOF
  FM_HOME="$home" run_public_launcher "PERL5OPT=-I$module_dir -MHostile"
  assert_launcher_baseline PERL5OPT "$marker"

  for variable in PERL5LIB PERLLIB; do
    case "$variable" in PERL5LIB) marker=$CONTROL/perl5lib-ran ;; PERLLIB) marker=$CONTROL/perllib-ran ;; esac
    cat > "$module_dir/Cwd.pm" <<EOF
package Cwd;
BEGIN { system('/usr/bin/touch', '$marker') }
sub import { }
1;
EOF
    FM_HOME="$home" run_public_launcher "$variable=$module_dir"
    assert_launcher_baseline "$variable" "$marker"
  done

  marker=$CONTROL/shellopts-ran
  FM_HOME="$home" run_public_launcher SHELLOPTS=xtrace "PS4=\$(/usr/bin/touch '$marker')"
  assert_launcher_baseline SHELLOPTS "$marker"

  marker=$CONTROL/bashopts-ran
  FM_HOME="$home" run_public_launcher BASHOPTS=extdebug "BASH_COMPAT=\$(/usr/bin/touch '$marker')"
  assert_launcher_baseline BASHOPTS "$marker"

  marker=$CONTROL/function-ran
  eval "cd() { /usr/bin/touch '$marker'; builtin cd \"\$@\"; }"
  export -f cd
  FM_HOME="$home" run_public_launcher
  export -n -f cd
  unset -f cd
  assert_launcher_baseline exported-function "$marker"

  marker=$CONTROL/sentinel-ran
  FM_HOME="$home" run_public_launcher "FM_RTK_STARTED=$marker"
  assert_launcher_baseline former-sentinel "$marker"

  marker=$CONTROL/system-seam-ran
  cat > "$SYSTEM_ROOT/usr/bin/uname" <<EOF
#!/bin/sh
/usr/bin/touch '$marker'
printf 'Darwin\n'
EOF
  chmod +x "$SYSTEM_ROOT/usr/bin/uname"
  FM_HOME="$home" run_public_launcher "FM_RTK_TEST_SYSTEM_ROOT=$SYSTEM_ROOT"
  assert_launcher_baseline system-test-seam "$marker"

  marker=$CONTROL/hash-seam-ran
  FM_HOME="$home" run_public_launcher "FM_RTK_TEST_SHA256=$(artifact_sha "$home")" \
    "FM_RTK_TEST_MARKER=$marker"
  assert_launcher_baseline hash-test-seam "$marker"

  marker=$CONTROL/tmpdir-ran
  FM_HOME="$home" run_public_launcher "TMPDIR=$PROJECT" "FM_RTK_TEST_MARKER=$marker"
  assert_launcher_baseline TMPDIR "$marker"
  pass "fm-rtk: public launcher independently sanitizes caller environment"
}

make_trap_tools() {
  local fakebin=$1 tool
  mkdir -p "$fakebin"
  for tool in rtk fm-rtk.sh git-status git-log git-diff search list brew npm installer \
    curl wget activate pre-commit post-checkout rtk-hook; do
    cat > "$fakebin/$tool" <<EOF
#!/bin/sh
printf '%s\\n' '$tool' >> '$CONTROL/lifecycle-calls'
exit 97
EOF
    chmod +x "$fakebin/$tool"
  done
  cat > "$fakebin/git" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" >> '$CONTROL/lifecycle-git-calls'
exec /usr/bin/git "\$@"
EOF
  chmod +x "$fakebin/git"
}

begin_write_monitor() {
  local name=$1
  shift
  MONITOR_READY=$CONTROL/monitor-$name.ready
  MONITOR_EVENTS=$CONTROL/monitor-$name.events
  MONITOR_STOP=$CONTROL/monitor-$name.stop
  rm -f "$MONITOR_READY" "$MONITOR_EVENTS" "$MONITOR_STOP"
  "$PYTHON3" "$EVENT_MONITOR" --ready "$MONITOR_READY" --events "$MONITOR_EVENTS" \
    --stop "$MONITOR_STOP" "$@" >"$CONTROL/monitor-$name.out" \
    2>"$CONTROL/monitor-$name.err" &
  MONITOR_PID=$!
  local attempts=0
  while [ ! -e "$MONITOR_READY" ] && [ "$attempts" -lt 200 ]; do
    kill -0 "$MONITOR_PID" 2>/dev/null || break
    sleep 0.01
    attempts=$((attempts + 1))
  done
  [ -e "$MONITOR_READY" ] || fail "$name filesystem monitor did not become ready"
}

end_write_monitor() {
  local name=$1 expectation=$2 rc
  : > "$MONITOR_STOP"
  wait "$MONITOR_PID"
  rc=$?
  expect_code 0 "$rc" "$name filesystem monitor failed"
  case "$expectation" in
    clean) [ ! -s "$MONITOR_EVENTS" ] || fail "$name emitted a filesystem write event" ;;
    changed) [ -s "$MONITOR_EVENTS" ] || fail "$name filesystem mutation was not observed" ;;
  esac
}

self_test_write_monitor() {
  local root=$CONTROL/monitor-self-root
  [ "$MONITOR_AVAILABLE" -eq 1 ] || {
    pass "fm-rtk: transient-write monitor unavailable # SKIP no kqueue/inotify facility"
    return
  }
  mkdir -p "$root"
  printf 'same bytes\n' > "$root/file"
  begin_write_monitor same-byte-rewrite "$root"
  printf 'same bytes\n' > "$root/file"
  end_write_monitor same-byte-rewrite changed

  begin_write_monitor equivalent-replacement "$root"
  printf 'same bytes\n' > "$root/replacement"
  mv "$root/replacement" "$root/file"
  end_write_monitor equivalent-replacement changed

  begin_write_monitor transient-entry "$root"
  : > "$root/transient"
  rm "$root/transient"
  end_write_monitor transient-entry changed
  pass "fm-rtk: transient-write monitor detects restored mutations"
}

assert_trace_has_no_orientation_exec() {
  local home=$1 fakebin=$2 lifecycle_root=$3 probe=$CONTROL/dtruss-probe trace=$CONTROL/dtruss-trace rc
  [ "$(/usr/bin/uname -s)" = Darwin ] && [ -x /usr/bin/dtruss ] || return 0
  /usr/bin/dtruss -f -t execve /usr/bin/printf '%s' fm-rtk-argv-probe >/dev/null 2>"$probe" || return 0
  /usr/bin/grep -F fm-rtk-argv-probe "$probe" >/dev/null || return 0
  [ "$MONITOR_AVAILABLE" -eq 0 ] || begin_write_monitor traced-session "$PROJECT" "$home/config"
  (cd "$PROJECT" && /usr/bin/dtruss -f -t execve /usr/bin/env \
    FM_HOME="$home" FM_SESSION_START_TIMEOUT=20 PATH="$fakebin:/usr/bin:/bin" \
    "$lifecycle_root/bin/fm-session-start.sh") >/dev/null 2>"$trace"
  rc=$?
  [ "$MONITOR_AVAILABLE" -eq 0 ] || end_write_monitor traced-session clean
  expect_code 0 "$rc" "execution-traced session start failed"
  if /usr/bin/grep -E 'execve\([^)]*(/git|fm-rtk)[^)]*(status|diff|log|verify)' "$trace" >/dev/null; then
    fail "session-start trace observed forbidden verifier or project-orientation execution"
  fi
}

snapshot_tree() {
  if [ -n "$PYTHON3" ]; then
    "$PYTHON3" "$EVENT_MONITOR" --snapshot "$1"
    return
  fi
  /usr/bin/perl -MDigest::SHA -MFile::Find -MFcntl=:mode -MTime::HiRes=lstat -e '
    use strict;
    use warnings;
    my $root = shift;
    my @records;
    find({
      no_chdir => 1,
      wanted => sub {
        my $path = $File::Find::name;
        my @stat = lstat($path);
        die "lstat failed\n" unless @stat;
        my $mode = $stat[2];
        my $relative = $path eq $root ? "." : substr($path, length($root) + 1);
        my ($type, $detail) = ("unknown", "");
        if (S_ISREG($mode)) {
          open my $file, "<", $path or die "open failed\n";
          binmode $file;
          $type = "file";
          $detail = Digest::SHA->new(256)->addfile($file)->hexdigest;
          close $file or die "close failed\n";
        } elsif (S_ISDIR($mode)) {
          $type = "directory";
        } elsif (S_ISLNK($mode)) {
          $type = "symlink";
          my $target = readlink($path);
          die "readlink failed\n" unless defined $target;
          $detail = unpack("H*", $target);
        } elsif (S_ISFIFO($mode)) {
          $type = "fifo";
        } elsif (S_ISSOCK($mode)) {
          $type = "socket";
        } elsif (S_ISBLK($mode)) {
          $type = "block";
          $detail = $stat[6];
        } elsif (S_ISCHR($mode)) {
          $type = "character";
          $detail = $stat[6];
        }
        push @records, join("|", unpack("H*", $relative), $type,
          sprintf("%04o", $mode & 07777), $stat[4], $stat[5], $stat[0], $stat[1],
          sprintf("%.9f", $stat[9]), sprintf("%.9f", $stat[10]), "-", $detail);
      }
    }, $root);
    print join("\n", sort @records), "\n";
  ' "$1"
}

assert_lifecycle_inert() {
  local name=$1 project_before=$2 config_before=$3 project_after config_after
  project_after=$(snapshot_tree "$PROJECT") || fail "$name could not snapshot project tree"
  config_after=$(snapshot_tree "$CONTROL/lifecycle-home/config") \
    || fail "$name could not snapshot private config tree"
  [ "$project_before" = "$project_after" ] || fail "$name changed project tree"
  [ "$config_before" = "$config_after" ] || fail "$name changed private config tree"
  assert_absent "$CONTROL/lifecycle-calls" "$name called an RTK, installer, network, hook, or activation command"
  if [ -f "$CONTROL/lifecycle-git-calls" ] && /usr/bin/grep -E '(^| )(status|diff|log)( |$)' "$CONTROL/lifecycle-git-calls" >/dev/null; then
    fail "$name ran a forbidden project-orientation git command"
  fi
  assert_absent "$CONTROL/verifier-called" "$name called the tracked RTK verifier"
  assert_absent "$CONTROL/artifact-executed" "$name executed the private artifact"
}

# Bootstrap and session start are driven as public commands with executable
# traps; source-level absence is not used as evidence for lifecycle inertness.
test_lifecycle_never_activates_rtk() {
  local home fakebin project_before config_before rc lifecycle_root
  if [ -n "$PYTHON3" ] && "$PYTHON3" "$EVENT_MONITOR" --probe >/dev/null 2>&1; then
    MONITOR_AVAILABLE=1
  fi
  self_test_write_monitor
  home=$CONTROL/lifecycle-home
  fakebin=$CONTROL/lifecycle-fakebin
  lifecycle_root=$CONTROL/lifecycle-root
  mkdir -p "$lifecycle_root" "$home/config" "$home/state/.lock" "$home/data" "$home/data/tools/rtk/v0.45.0/aarch64-apple-darwin"
  cp -R "$ROOT/bin" "$ROOT/lib" "$lifecycle_root/"
  cat > "$lifecycle_root/lib/Firstmate/rtk-run" <<EOF
#!/bin/sh
/usr/bin/touch '$CONTROL/verifier-called'
exit 97
EOF
  chmod +x "$lifecycle_root/lib/Firstmate/rtk-run"
  printf 'disabled\n' > "$home/config/rtk"
  printf 'private-config\n' > "$home/config/sentinel"
  cat > "$home/data/tools/rtk/v0.45.0/aarch64-apple-darwin/rtk" <<EOF
#!/bin/sh
/usr/bin/touch '$CONTROL/artifact-executed'
EOF
  chmod +x "$home/data/tools/rtk/v0.45.0/aarch64-apple-darwin/rtk"
  make_trap_tools "$fakebin"
  project_before=$(snapshot_tree "$PROJECT") || fail "could not snapshot project tree"
  config_before=$(snapshot_tree "$home/config") || fail "could not snapshot private config tree"

  rm -f "$CONTROL/lifecycle-calls" "$CONTROL/lifecycle-git-calls" \
    "$CONTROL/verifier-called" "$CONTROL/artifact-executed"
  [ "$MONITOR_AVAILABLE" -eq 0 ] || begin_write_monitor bootstrap "$PROJECT" "$home/config"
  (cd "$PROJECT" && FM_HOME="$home" FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip \
    PATH="$fakebin:/usr/bin:/bin" "$lifecycle_root/bin/fm-bootstrap.sh") >"$OUT" 2>"$ERR"
  rc=$?
  [ "$MONITOR_AVAILABLE" -eq 0 ] || end_write_monitor bootstrap clean
  expect_code 0 "$rc" "detect-only bootstrap failed"
  assert_lifecycle_inert bootstrap "$project_before" "$config_before"

  rm -f "$CONTROL/lifecycle-calls" "$CONTROL/lifecycle-git-calls" \
    "$CONTROL/verifier-called" "$CONTROL/artifact-executed"
  [ "$MONITOR_AVAILABLE" -eq 0 ] || begin_write_monitor session-start "$PROJECT" "$home/config"
  (cd "$PROJECT" && FM_HOME="$home" FM_SESSION_START_TIMEOUT=20 \
    PATH="$fakebin:/usr/bin:/bin" "$lifecycle_root/bin/fm-session-start.sh") >"$OUT" 2>"$ERR"
  rc=$?
  [ "$MONITOR_AVAILABLE" -eq 0 ] || end_write_monitor session-start clean
  expect_code 0 "$rc" "read-only session start failed"
  assert_lifecycle_inert session-start "$project_before" "$config_before"
  assert_trace_has_no_orientation_exec "$home" "$fakebin" "$lifecycle_root"
  assert_lifecycle_inert traced-session-start "$project_before" "$config_before"
  pass "fm-rtk: bootstrap and session start remain lifecycle-inert"
}

# Platform rejection occurs before any artifact access.
test_platform_rejection() {
  local home
  home=$(make_home platform)
  mv "$SYSTEM_ROOT/usr/bin/uname" "$SYSTEM_ROOT/usr/bin/uname.saved"
  run_verify "$home"
  expect_code 69 "$LAST_RC" "missing trusted utility was accepted"
  [ ! -s "$OUT" ] || fail "trusted-utility refusal emitted stdout"
  [ "$(cat "$ERR")" = 'fm-rtk: trusted system utility unavailable' ] \
    || fail "trusted-utility refusal output changed"
  assert_private_output "trusted-utility refusal"
  mv "$SYSTEM_ROOT/usr/bin/uname.saved" "$SYSTEM_ROOT/usr/bin/uname"
  cat > "$SYSTEM_ROOT/usr/bin/uname" <<'SH'
#!/bin/bash
case "$1" in -s) printf 'Linux\n' ;; -m) printf 'x86_64\n' ;; esac
SH
  chmod +x "$SYSTEM_ROOT/usr/bin/uname"
  run_verify "$home"
  expect_code 69 "$LAST_RC" "unsupported platform was accepted"
  [ ! -s "$OUT" ] || fail "platform refusal emitted stdout"
  [ "$(cat "$ERR")" = 'fm-rtk: unsupported platform (requires Darwin arm64)' ] \
    || fail "platform refusal output changed"
  assert_private_output "platform refusal"
  assert_absent "$CONTROL/artifact-executed" "platform rejection executed artifact"
  assert_project_unchanged
  pass "fm-rtk: unsupported platform fails before inspection"
}

test_exact_verification_contract
test_types_and_symlinks_fail_closed
test_effective_permission_branches
test_public_launcher_ignores_hostile_environment
test_lifecycle_never_activates_rtk
test_platform_rejection
