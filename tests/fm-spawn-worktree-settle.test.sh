#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
REAL_GIT=$(command -v git)
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message)
    if [[ " $* " == *" -t "* ]] && [ -n "${FM_FAKE_ENDPOINT:-}" ] && [ ! -e "$FM_FAKE_ENDPOINT" ]; then
      exit 1
    fi
    printf 'firstmate\n'
    exit 0
    ;;
  list-windows)
    [ "${FM_FAKE_READ_FAIL:-0}" != 1 ] || exit 2
    if [ -n "${FM_FAKE_ENDPOINT:-}" ] && [ -e "$FM_FAKE_ENDPOINT" ]; then
      printf '%s\n' "${FM_FAKE_WINDOW:?FM_FAKE_WINDOW unset}"
    fi
    exit 0
    ;;
  has-session|new-session) exit 0 ;;
  new-window) [ -z "${FM_FAKE_ENDPOINT:-}" ] || : > "$FM_FAKE_ENDPOINT"; exit 0 ;;
  kill-window)
    [ "${FM_FAKE_KILL_FAIL:-0}" != 1 ] || exit 1
    [ -z "${FM_FAKE_ENDPOINT:-}" ] || rm -f "$FM_FAKE_ENDPOINT"
    exit 0
    ;;
  send-keys) printf '%s\n' "$*" >> "${FM_FAKE_SEND_LOG:-/dev/null}"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:-/dev/null}"
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    FM_REAL_GIT="${FM_REAL_GIT:-}" FM_FAKE_GIT_LOG="${FM_FAKE_GIT_LOG:-}" \
    FM_FAKE_GH_LOG="${FM_FAKE_GH_LOG:-}" FM_FAKE_SEND_LOG="${FM_FAKE_SEND_LOG:-}" \
    FM_FAKE_TREEHOUSE_LOG="${FM_FAKE_TREEHOUSE_LOG:-}" FM_FAKE_ENDPOINT="${FM_FAKE_ENDPOINT:-}" \
    FM_FAKE_WINDOW="$id" FM_FAKE_KILL_FAIL="${FM_FAKE_KILL_FAIL:-0}" \
    FM_FAKE_READ_FAIL="${FM_FAKE_READ_FAIL:-0}" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read still only
# costs the loop's existing one-second inter-poll sleep to confirm - not an
# extra full cycle on top of that.
test_already_settled_pane_costs_one_confirm_sleep() {
  local rec id out status start end elapsed
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  start=$(date +%s)
  out=$(run_settle_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  [ "$elapsed" -le 5 ] || fail "already-settled pane took ${elapsed}s to confirm - expected close to the single inter-poll sleep"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

install_github_gate_stubs() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_GH_LOG"
case "$*" in
  *"auth status --help"*) printf '  --active, --hostname\n' ;;
  *"repos/"*) printf 'true\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" fetch "*) printf '%s\n' "$*" >> "$FM_FAKE_GIT_LOG"; exit 0 ;;
  *" remote set-head origin --auto "*) exit 0 ;;
esac
exec "$FM_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
}

prepare_github_gate_case() {
  local default
  default=$($REAL_GIT -C "$PROJ_DIR" symbolic-ref --short HEAD)
  $REAL_GIT -C "$WT_DIR" update-ref "refs/remotes/origin/$default" HEAD
  $REAL_GIT -C "$WT_DIR" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$default"
  $REAL_GIT -C "$PROJ_DIR" remote set-url origin https://github.com/owner/repo.git
  install_github_gate_stubs "$FAKEBIN_DIR"
}

test_divergent_allocated_worktree_destination_blocks_before_fetch_or_launch() {
  local rec id out status git_log gh_log send_log treehouse_log endpoint
  id=allocated-github-divergent-z3
  rec=$(make_settle_case allocated-github-divergent "$id" 0)
  read_settle_record "$rec"
  prepare_github_gate_case
  $REAL_GIT -C "$PROJ_DIR" config extensions.worktreeConfig true
  $REAL_GIT -C "$WT_DIR" config --worktree remote.origin.url https://github.example/owner/repo.git
  git_log="$TMP_ROOT/divergent-git.log"
  gh_log="$TMP_ROOT/divergent-gh.log"
  send_log="$TMP_ROOT/divergent-send.log"
  treehouse_log="$TMP_ROOT/divergent-treehouse.log"
  endpoint="$TMP_ROOT/divergent-endpoint"
  : > "$git_log"; : > "$gh_log"; : > "$send_log"; : > "$treehouse_log"

  out=$(FM_REAL_GIT="$REAL_GIT" FM_FAKE_GIT_LOG="$git_log" FM_FAKE_GH_LOG="$gh_log" FM_FAKE_SEND_LOG="$send_log" FM_FAKE_TREEHOUSE_LOG="$treehouse_log" FM_FAKE_ENDPOINT="$endpoint" run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a divergent allocated worktree destination must block"
  assert_contains "$out" "worker launch is waiting" "a divergent allocated worktree did not report a blocked launch"
  [ ! -s "$git_log" ] || fail "a divergent allocated worktree fetched before destination verification"
  assert_no_grep 'encode launch-brief' "$send_log" "a divergent allocated worktree started the worker"
  [ "$(grep -c 'repos/owner/repo' "$gh_log")" -eq 1 ] || fail "a divergent allocated worktree should only probe the selected project destination"
  [ ! -e "$endpoint" ] || fail "a divergent allocated worktree left its task endpoint behind"
  assert_grep "return --force $WT_DIR" "$treehouse_log" "a divergent allocated worktree was not returned after the block"
  pass "a divergent allocated worktree destination blocks without leaving an endpoint or lease"
}

test_failed_endpoint_removal_retains_lease_and_recovery_record() {
  local rec id out status git_log gh_log send_log treehouse_log endpoint
  id=allocated-github-cleanup-failure-z4
  rec=$(make_settle_case allocated-github-cleanup-failure "$id" 0)
  read_settle_record "$rec"
  prepare_github_gate_case
  $REAL_GIT -C "$PROJ_DIR" config extensions.worktreeConfig true
  $REAL_GIT -C "$WT_DIR" config --worktree remote.origin.url https://github.example/owner/repo.git
  git_log="$TMP_ROOT/cleanup-failure-git.log"
  gh_log="$TMP_ROOT/cleanup-failure-gh.log"
  send_log="$TMP_ROOT/cleanup-failure-send.log"
  treehouse_log="$TMP_ROOT/cleanup-failure-treehouse.log"
  endpoint="$TMP_ROOT/cleanup-failure-endpoint"
  : > "$git_log"; : > "$gh_log"; : > "$send_log"; : > "$treehouse_log"

  out=$(FM_REAL_GIT="$REAL_GIT" FM_FAKE_GIT_LOG="$git_log" FM_FAKE_GH_LOG="$gh_log" FM_FAKE_SEND_LOG="$send_log" FM_FAKE_TREEHOUSE_LOG="$treehouse_log" FM_FAKE_ENDPOINT="$endpoint" FM_FAKE_KILL_FAIL=1 FM_FAKE_READ_FAIL=1 run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a divergent allocated worktree destination must block when endpoint cleanup fails"
  assert_contains "$out" "could not confirm removal of blocked task $id's endpoint" "unreadable endpoint cleanup failure was not reported"
  assert_contains "$out" "endpoint_state=unreadable" "endpoint cleanup did not report its unreadable confirmation"
  assert_contains "$out" "$WT_DIR" "endpoint cleanup failure did not name the retained worktree"
  [ -e "$endpoint" ] || fail "the cleanup-failure fixture did not retain the endpoint"
  assert_no_grep "return --force $WT_DIR" "$treehouse_log" "a worktree was returned while endpoint absence was unreadable"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "cleanup failure did not retain recoverable worktree metadata"
  assert_grep 'gh_gated=1' "$HOME_DIR/state/$id.meta" "cleanup failure did not retain the gated classification"
  pass "failed endpoint removal and unreadable liveness retain the lease and recovery record"
}

test_matching_allocated_worktree_destination_fast_paths_without_reprobe() {
  local rec id out status git_log gh_log send_log
  id=allocated-github-matching-z5
  rec=$(make_settle_case allocated-github-matching "$id" 0)
  read_settle_record "$rec"
  prepare_github_gate_case
  git_log="$TMP_ROOT/matching-git.log"
  gh_log="$TMP_ROOT/matching-gh.log"
  send_log="$TMP_ROOT/matching-send.log"
  : > "$git_log"; : > "$gh_log"; : > "$send_log"

  out=$(FM_REAL_GIT="$REAL_GIT" FM_FAKE_GIT_LOG="$git_log" FM_FAKE_GH_LOG="$gh_log" FM_FAKE_SEND_LOG="$send_log" run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "a matching allocated worktree should launch"
  assert_contains "$out" "spawned $id" "a matching allocated worktree did not report success"
  [ -s "$git_log" ] || fail "the matching allocated worktree did not proceed to refresh its base"
  assert_grep 'encode launch-brief' "$send_log" "the matching allocated worktree did not start the worker"
  [ "$(grep -c 'repos/owner/repo' "$gh_log")" -eq 1 ] || fail "a matching allocated worktree triggered a second GitHub probe"
  pass "a matching allocated worktree launches through the verified fast path"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_divergent_allocated_worktree_destination_blocks_before_fetch_or_launch
test_failed_endpoint_removal_retains_lease_and_recovery_record
test_matching_allocated_worktree_destination_fast_paths_without_reprobe

echo "# all fm-spawn-worktree-settle tests passed"
