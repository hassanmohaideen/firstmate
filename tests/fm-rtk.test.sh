#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-rtk)
SYSTEM_ROOT=$TMP_ROOT/system
CONTROL=$TMP_ROOT/control
TASK_COPY=$TMP_ROOT/task-copy
HELPER=$TMP_ROOT/fm-rtk-test-driver.sh
OUT=$TMP_ROOT/out
ERR=$TMP_ROOT/err
RAW_LOG=$CONTROL/raw.log
LAST_RC=0
mkdir -p "$SYSTEM_ROOT/usr/bin" "$SYSTEM_ROOT/bin" "$SYSTEM_ROOT/usr/sbin" \
  "$SYSTEM_ROOT/sbin" "$CONTROL" "$TASK_COPY"
cp "$ROOT/lib/Firstmate/rtk-run" "$HELPER"
chmod +x "$HELPER"

for pair in /usr/bin/awk:usr/bin/awk /usr/bin/env:usr/bin/env /usr/bin/wc:usr/bin/wc \
  /usr/bin/tr:usr/bin/tr /usr/bin/mktemp:usr/bin/mktemp /usr/bin/shasum:usr/bin/shasum \
  /usr/bin/perl:usr/bin/perl /bin/rm:bin/rm /bin/chmod:bin/chmod \
  /bin/mkdir:bin/mkdir /bin/sleep:bin/sleep; do
  original=${pair%%:*}
  wrapper=$SYSTEM_ROOT/${pair#*:}
  printf '#!/bin/bash\nexec %q "$@"\n' "$original" > "$wrapper"
  chmod +x "$wrapper"
done
cat > "$SYSTEM_ROOT/usr/bin/uname" <<'SH'
#!/bin/bash
case "$1" in -s) printf 'Darwin\n' ;; -m) printf 'arm64\n' ;; *) exit 2 ;; esac
SH
chmod +x "$SYSTEM_ROOT/usr/bin/uname"

make_fake_git() {
  cat > "$SYSTEM_ROOT/usr/bin/git" <<SH
#!/bin/bash
printf '%q ' "\$@" > '$RAW_LOG'
printf '\n' >> '$RAW_LOG'
printf '%s\n' "OPTIONAL_LOCKS=\${GIT_OPTIONAL_LOCKS-}" "GLOBAL=\${GIT_CONFIG_GLOBAL-}" \
  "SYSTEM=\${GIT_CONFIG_NOSYSTEM-}" "LAZY=\${GIT_NO_LAZY_FETCH-}" "HOME=\${HOME-}" >> '$RAW_LOG'
printf 'raw stdout\n'
printf 'raw stderr\n' >&2
if [ -f '$CONTROL/raw-fail' ]; then read -r raw_fail < '$CONTROL/raw-fail'; exit "\$raw_fail"; fi
exit 0
SH
  chmod +x "$SYSTEM_ROOT/usr/bin/git"
}
make_fake_git

make_home() {
  local name=$1 home artifact
  home=$TMP_ROOT/$name
  mkdir -p "$home/config" "$home/data/tools/rtk/v0.45.0/aarch64-apple-darwin"
  printf 'v0.45.0\n' > "$home/config/rtk"
  artifact=$home/data/tools/rtk/v0.45.0/aarch64-apple-darwin/rtk
  cat > "$artifact" <<SH
#!/bin/bash
if [ "\${1:-}" = --version ]; then printf 'rtk 0.45.0\n'; exit 0; fi
printf '%s\n' "\$@" > '$CONTROL/compact-args'
printf '%s\n' "OPTIONAL_LOCKS=\$GIT_OPTIONAL_LOCKS" "GLOBAL=\$GIT_CONFIG_GLOBAL" \
  "SYSTEM=\$GIT_CONFIG_NOSYSTEM" "LAZY=\$GIT_NO_LAZY_FETCH" > '$CONTROL/compact-env'
printf 'compact stdout\n'
printf 'compact stderr\n' >&2
exit "\${COMPACT_FAIL:-0}"
SH
  chmod +x "$artifact"
  printf '%s\n' "$home"
}
artifact_path() { printf '%s/data/tools/rtk/v0.45.0/aarch64-apple-darwin/rtk' "$1"; }
artifact_sha() { /usr/bin/shasum -a 256 "$(artifact_path "$1")" | /usr/bin/awk '{print $1}'; }
reset_evidence() { rm -f "$OUT" "$ERR" "$RAW_LOG" "$CONTROL/compact-args" "$CONTROL/compact-env" "$CONTROL/attacker-ran"; }
run_helper_at() {
  local directory=$1 home=$2 sha
  shift 2
  reset_evidence
  sha=$(artifact_sha "$home" 2>/dev/null || printf unavailable)
  (cd "$directory" && FM_HOME="$home" FM_RTK_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" \
    FM_RTK_TEST_SHA256="$sha" "$HELPER" "$@") > "$OUT" 2> "$ERR"
  LAST_RC=$?
}
run_helper() { local home=$1; shift; run_helper_at "$TASK_COPY" "$home" "$@"; }

assert_raw_once() {
  assert_present "$RAW_LOG" "raw Git did not run"
  [ "$(grep -c '^OPTIONAL_LOCKS=' "$RAW_LOG")" = 1 ] || fail "raw Git ran more than once"
  assert_grep 'OPTIONAL_LOCKS=0' "$RAW_LOG" "raw Git allowed optional locks"
  assert_grep 'GLOBAL=/dev/null' "$RAW_LOG" "raw Git allowed global config"
  assert_grep 'SYSTEM=1' "$RAW_LOG" "raw Git allowed system config"
  assert_grep 'LAZY=1' "$RAW_LOG" "raw Git allowed lazy fetch"
  assert_grep 'HOME=/var/empty' "$RAW_LOG" "raw Git inherited caller HOME"
}

test_removed_and_generic_verbs_execute_nothing() {
  local home invocation rc
  home=$(make_home admission)
  for invocation in 'search needle .' 'list .' 'exec git status' 'git-status extra'; do
    reset_evidence
    # shellcheck disable=SC2086 # Rows intentionally encode public argv.
    FM_HOME="$home" FM_RTK_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" "$HELPER" $invocation > "$OUT" 2> "$ERR"
    rc=$?
    expect_code 64 "$rc" "$invocation should be refused"
    assert_absent "$RAW_LOG" "$invocation executed raw Git"
    assert_absent "$CONTROL/compact-args" "$invocation executed RTK"
  done
  pass "fm-rtk: removed and generic verbs execute nothing"
}

test_raw_and_compact_git_share_hardening() {
  local home actual expected config
  home=$(make_home shared-env)
  config='-c core.fsmonitor=false -c core.hooksPath=/dev/null -c core.pager=cat -c pager.log=false -c pager.diff=false -c pager.status=false -c diff.external= -c diff.trustExitCode=false -c interactive.diffFilter= -c status.submoduleSummary=false -c protocol.allow=never'
  run_helper "$home" git-status
  expect_code 0 "$LAST_RC" "compact git-status failed"
  assert_absent "$RAW_LOG" "compact git-status also ran raw"
  assert_grep 'OPTIONAL_LOCKS=0' "$CONTROL/compact-env" "compact Git allowed optional locks"
  assert_grep 'LAZY=1' "$CONTROL/compact-env" "compact Git allowed lazy fetch"
  actual=$(tr '\n' ' ' < "$CONTROL/compact-args"); actual=${actual% }
  expected="git $config status"
  [ "$actual" = "$expected" ] || fail "compact git-status argv changed: $actual"

  rm "$home/config/rtk"
  printf '37\n' > "$CONTROL/raw-fail"
  run_helper "$home" git-status
  rm -f "$CONTROL/raw-fail"
  expect_code 37 "$LAST_RC" "raw Git status was not preserved"
  assert_raw_once
  assert_grep 'raw stdout' "$OUT" "raw stdout was lost"
  assert_grep 'raw stderr' "$ERR" "raw stderr was lost"
  pass "fm-rtk: raw and compact Git share fixed hardening"
}

test_home_component_symlinks_never_execute_artifact() {
  local outside home
  outside=$TMP_ROOT/outside
  mkdir -p "$outside/config" "$outside/data/tools/rtk/v0.45.0/aarch64-apple-darwin"
  printf 'v0.45.0\n' > "$outside/config/rtk"
  cat > "$outside/data/tools/rtk/v0.45.0/aarch64-apple-darwin/rtk" <<SH
#!/bin/bash
touch '$CONTROL/attacker-ran'
SH
  chmod +x "$outside/data/tools/rtk/v0.45.0/aarch64-apple-darwin/rtk"

  home=$TMP_ROOT/symlink-config
  mkdir -p "$home/data"
  ln -s "$outside/config" "$home/config"
  ln -s "$outside/data/tools" "$home/data/tools"
  run_helper "$home" git-status
  expect_code 0 "$LAST_RC" "symlink config should fall back"
  assert_raw_once
  assert_absent "$CONTROL/attacker-ran" "artifact behind symlinked config executed"

  home=$TMP_ROOT/symlink-data
  mkdir -p "$home/config"
  printf 'v0.45.0\n' > "$home/config/rtk"
  ln -s "$outside/data" "$home/data"
  run_helper "$home" git-status
  expect_code 0 "$LAST_RC" "symlink artifact parent should fall back"
  assert_raw_once
  assert_absent "$CONTROL/attacker-ran" "artifact behind symlinked parent executed"
  pass "fm-rtk: opened no-follow home walk rejects parent symlinks"
}

test_fallback_git_cannot_execute_config_or_change_index() {
  local home repo marker real_git before_index after_index before_tree after_tree
  home=$(make_home git-safety)
  rm "$home/config/rtk"
  repo=$TASK_COPY/repo
  marker=$CONTROL/attacker-ran
  real_git=$(command -v git)
  mkdir -p "$repo"
  "$real_git" -C "$repo" init -q
  "$real_git" -C "$repo" config user.name fixture
  "$real_git" -C "$repo" config user.email fixture@example.invalid
  printf 'one\n' > "$repo/tracked"
  printf 'tracked diff=hostile\n' > "$repo/.gitattributes"
  "$real_git" -C "$repo" add tracked .gitattributes
  "$real_git" -C "$repo" commit -qm initial
  printf 'two\n' >> "$repo/tracked"
  cat > "$CONTROL/attacker" <<SH
#!/bin/bash
touch '$marker'
cat
SH
  chmod +x "$CONTROL/attacker"
  "$real_git" -C "$repo" config core.fsmonitor "$CONTROL/attacker"
  "$real_git" -C "$repo" config diff.external "$CONTROL/attacker"
  "$real_git" -C "$repo" config diff.hostile.textconv "$CONTROL/attacker"
  printf '#!/bin/bash\nexec %q "$@"\n' "$real_git" > "$SYSTEM_ROOT/usr/bin/git"
  chmod +x "$SYSTEM_ROOT/usr/bin/git"

  before_index=$(/usr/bin/shasum -a 256 "$repo/.git/index")
  before_tree=$(find "$repo" -type f -not -path '*/.git/*' -exec /usr/bin/shasum -a 256 {} \; | LC_ALL=C sort)
  run_helper_at "$repo" "$home" git-status
  expect_code 0 "$LAST_RC" "fallback git-status failed"
  assert_grep 'Changes not staged for commit' "$OUT" "fallback git-status lost output"
  assert_absent "$marker" "fallback git-status executed fsmonitor"
  run_helper_at "$repo" "$home" git-diff
  expect_code 0 "$LAST_RC" "fallback git-diff failed"
  assert_grep 'diff --git ' "$OUT" "fallback git-diff lost output"
  assert_absent "$marker" "fallback git-diff executed configured code"
  after_index=$(/usr/bin/shasum -a 256 "$repo/.git/index")
  after_tree=$(find "$repo" -type f -not -path '*/.git/*' -exec /usr/bin/shasum -a 256 {} \; | LC_ALL=C sort)
  [ "$before_index" = "$after_index" ] || fail "fallback Git changed index bytes"
  [ "$before_tree" = "$after_tree" ] || fail "fallback Git changed project bytes"
  make_fake_git
  pass "fm-rtk: fallback Git executes no config and changes no bytes"
}

test_removed_and_generic_verbs_execute_nothing
test_raw_and_compact_git_share_hardening
test_home_component_symlinks_never_execute_artifact
test_fallback_git_cannot_execute_config_or_change_index
