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
  new-window)
    [ "${FM_FAKE_CREATE_FAIL:-0}" != 1 ] || exit 1
    [ -z "${FM_FAKE_ENDPOINT:-}" ] || : > "$FM_FAKE_ENDPOINT"
    printf '@1\n'
    exit 0
    ;;
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
  cat > "$fakebin/zellij" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_ZELLIJ_LOG:-/dev/null}"
case " $* " in
  *" --version "*) printf 'zellij 0.44.0\n'; exit 0 ;;
  *" list-sessions "*) printf 'firstmate\n'; exit 0 ;;
  *" action new-tab "*)
    [ -z "${FM_FAKE_ENDPOINT:-}" ] || : > "$FM_FAKE_ENDPOINT"
    if [ "${FM_FAKE_ZELLIJ_BAD_TAB_ID:-0}" = 1 ]; then
      printf 'unresolved\n'
    else
      printf '9\n'
    fi
    exit 0
    ;;
  *" action list-panes "*) printf '[]\n'; exit 0 ;;
  *" action close-tab-by-id "*) exit 1 ;;
  *" action list-tabs "*)
    countfile="${FM_FAKE_ZELLIJ_LIST_COUNT:?FM_FAKE_ZELLIJ_LIST_COUNT unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    [ "$n" -eq 1 ] && { printf '[]\n'; exit 0; }
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/zellij"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:-/dev/null}"
case "$*" in
  get*--lease*) printf '%s\n' "${FM_FAKE_PANE_PATH:?FM_FAKE_PANE_PATH unset}" ;;
  return*) [ "${FM_FAKE_TREEHOUSE_RETURN_FAIL:-0}" != 1 ] || exit 1 ;;
esac
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
  local -a spawn_args
  spawn_args=("$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  [ -z "${FM_FAKE_BACKEND:-}" ] || spawn_args+=(--backend "$FM_FAKE_BACKEND")
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    FM_REAL_GIT="${FM_REAL_GIT:-}" FM_FAKE_GIT_LOG="${FM_FAKE_GIT_LOG:-}" \
    FM_FAKE_GH_LOG="${FM_FAKE_GH_LOG:-}" FM_FAKE_SEND_LOG="${FM_FAKE_SEND_LOG:-}" \
    FM_FAKE_TREEHOUSE_LOG="${FM_FAKE_TREEHOUSE_LOG:-}" FM_FAKE_ENDPOINT="${FM_FAKE_ENDPOINT:-}" \
    FM_FAKE_ZELLIJ_LOG="${FM_FAKE_ZELLIJ_LOG:-}" FM_FAKE_ZELLIJ_LIST_COUNT="${FM_FAKE_ZELLIJ_LIST_COUNT:-}" \
    FM_FAKE_ZELLIJ_BAD_TAB_ID="${FM_FAKE_ZELLIJ_BAD_TAB_ID:-0}" \
    FM_FAKE_WINDOW="$id" FM_FAKE_KILL_FAIL="${FM_FAKE_KILL_FAIL:-0}" \
    FM_FAKE_READ_FAIL="${FM_FAKE_READ_FAIL:-0}" FM_FAKE_CREATE_FAIL="${FM_FAKE_CREATE_FAIL:-0}" \
    FM_FAKE_PERSIST_DIVERGENCE="${FM_FAKE_PERSIST_DIVERGENCE:-0}" \
    FM_FAKE_TREEHOUSE_RETURN_FAIL="${FM_FAKE_TREEHOUSE_RETURN_FAIL:-0}" FM_FAKE_FETCH_FAIL="${FM_FAKE_FETCH_FAIL:-0}" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "${spawn_args[@]}" 2>&1
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
  *" fetch "*) printf '%s\n' "$*" >> "$FM_FAKE_GIT_LOG"; [ "${FM_FAKE_FETCH_FAIL:-0}" != 1 ] ; exit $? ;;
  *" config --worktree --unset-all remote.origin.url "*)
    [ "${FM_FAKE_PERSIST_DIVERGENCE:-0}" != 1 ] || exit 1
    ;;
  *" config --worktree --unset-all branch."*)
    [ "${FM_FAKE_PERSIST_BRANCH_ROUTE:-0}" != 1 ] || exit 1
    ;;
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
  $REAL_GIT -C "$PROJ_DIR" remote set-url origin https://github.com/upstream/repo.git
  $REAL_GIT -C "$PROJ_DIR" remote set-url --add --push origin https://github.com/owner/repo.git
  install_github_gate_stubs "$FAKEBIN_DIR"
}

test_divergent_allocated_worktree_destination_is_reset_before_launch() {
  local rec id out status git_log gh_log send_log treehouse_log endpoint
  id=allocated-github-reset-z3
  rec=$(make_settle_case allocated-github-reset "$id" 0)
  read_settle_record "$rec"
  prepare_github_gate_case
  $REAL_GIT -C "$PROJ_DIR" config extensions.worktreeConfig true
  $REAL_GIT -C "$WT_DIR" config --worktree remote.origin.url https://github.example/owner/repo.git
  $REAL_GIT -C "$WT_DIR" config --worktree remote.origin.pushurl https://github.example/owner/repo.git
  $REAL_GIT -C "$WT_DIR" config --worktree remote.pushDefault alternate
  $REAL_GIT -C "$WT_DIR" config --worktree "branch.fm/$id.pushRemote" alternate
  $REAL_GIT -C "$WT_DIR" config --worktree "branch.fm/$id.remote" alternate
  git_log="$TMP_ROOT/reset-git.log"
  gh_log="$TMP_ROOT/reset-gh.log"
  send_log="$TMP_ROOT/reset-send.log"
  treehouse_log="$TMP_ROOT/reset-treehouse.log"
  endpoint="$TMP_ROOT/reset-endpoint"
  : > "$git_log"; : > "$gh_log"; : > "$send_log"; : > "$treehouse_log"

  out=$(FM_REAL_GIT="$REAL_GIT" FM_FAKE_GIT_LOG="$git_log" FM_FAKE_GH_LOG="$gh_log" FM_FAKE_SEND_LOG="$send_log" FM_FAKE_TREEHOUSE_LOG="$treehouse_log" FM_FAKE_ENDPOINT="$endpoint" run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "a divergent pooled destination should be reset and launch"
  assert_contains "$out" "spawned $id" "the reset pooled worktree did not launch"
  [ "$($REAL_GIT -C "$WT_DIR" remote get-url origin)" = https://github.com/upstream/repo.git ] || fail "the pooled worktree did not inherit the primary fetch destination"
  [ "$($REAL_GIT -C "$WT_DIR" remote get-url --push origin)" = https://github.com/owner/repo.git ] || fail "the pooled worktree did not inherit the verified primary push destination"
  [ "$($REAL_GIT -C "$PROJ_DIR" remote get-url origin)" = https://github.com/upstream/repo.git ] || fail "the pool reset changed the shared primary fetch URL"
  [ "$($REAL_GIT -C "$PROJ_DIR" remote get-url --push origin)" = https://github.com/owner/repo.git ] || fail "the pool reset changed the shared primary push URL"
  [ -z "$($REAL_GIT -C "$WT_DIR" config --worktree --get remote.pushDefault 2>/dev/null || true)" ] || fail "the pool reset retained a worktree-specific push default"
  [ -z "$($REAL_GIT -C "$WT_DIR" config --worktree --get "branch.fm/$id.pushRemote" 2>/dev/null || true)" ] || fail "the pool reset retained a future-branch push remote"
  [ -z "$($REAL_GIT -C "$WT_DIR" config --worktree --get "branch.fm/$id.remote" 2>/dev/null || true)" ] || fail "the pool reset retained a future-branch tracking remote"
  assert_grep 'encode launch-brief' "$send_log" "the reset pooled worktree did not start the worker"
  [ "$(grep -c 'repos/owner/repo' "$gh_log")" -eq 1 ] || fail "resetting the pooled destination triggered a second GitHub probe"
  assert_no_grep 'return --force' "$treehouse_log" "a launched pooled worktree was returned during spawn"
  pass "a divergent pooled destination is reset before endpoint creation"
}

test_unverifiable_pool_reset_blocks_before_endpoint_creation() {
  local rec id out status git_log gh_log send_log treehouse_log endpoint
  id=allocated-github-reset-failure-z4
  rec=$(make_settle_case allocated-github-reset-failure "$id" 0)
  read_settle_record "$rec"
  prepare_github_gate_case
  $REAL_GIT -C "$PROJ_DIR" config extensions.worktreeConfig true
  $REAL_GIT -C "$WT_DIR" config --worktree remote.origin.url https://github.example/owner/repo.git
  $REAL_GIT -C "$WT_DIR" config --worktree remote.origin.pushurl https://github.example/owner/repo.git
  git_log="$TMP_ROOT/reset-failure-git.log"
  gh_log="$TMP_ROOT/reset-failure-gh.log"
  send_log="$TMP_ROOT/reset-failure-send.log"
  treehouse_log="$TMP_ROOT/reset-failure-treehouse.log"
  endpoint="$TMP_ROOT/reset-failure-endpoint"
  : > "$git_log"; : > "$gh_log"; : > "$send_log"; : > "$treehouse_log"

  out=$(FM_REAL_GIT="$REAL_GIT" FM_FAKE_GIT_LOG="$git_log" FM_FAKE_GH_LOG="$gh_log" FM_FAKE_SEND_LOG="$send_log" FM_FAKE_TREEHOUSE_LOG="$treehouse_log" FM_FAKE_ENDPOINT="$endpoint" FM_FAKE_PERSIST_DIVERGENCE=1 run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "an unverifiable pooled destination reset must block"
  assert_contains "$out" "worker launch is waiting" "the unverifiable pooled reset did not report a blocked launch"
  [ ! -e "$endpoint" ] || fail "the blocked pooled reset created an endpoint"
  assert_no_grep 'encode launch-brief' "$send_log" "the blocked pooled reset started the worker"
  assert_grep "return --force $WT_DIR" "$treehouse_log" "the blocked pre-endpoint allocation was not returned"
  pass "an unverifiable pooled reset blocks before creating an endpoint"
}

test_persistent_future_branch_route_blocks_before_endpoint_creation() {
  local rec id out status git_log gh_log send_log treehouse_log endpoint
  id=allocated-github-future-route-z9
  rec=$(make_settle_case allocated-github-future-route "$id" 0)
  read_settle_record "$rec"
  prepare_github_gate_case
  $REAL_GIT -C "$PROJ_DIR" config extensions.worktreeConfig true
  $REAL_GIT -C "$WT_DIR" config --worktree "branch.fm/$id.pushRemote" alternate
  git_log="$TMP_ROOT/future-route-git.log"
  gh_log="$TMP_ROOT/future-route-gh.log"
  send_log="$TMP_ROOT/future-route-send.log"
  treehouse_log="$TMP_ROOT/future-route-treehouse.log"
  endpoint="$TMP_ROOT/future-route-endpoint"
  : > "$git_log"; : > "$gh_log"; : > "$send_log"; : > "$treehouse_log"

  out=$(FM_REAL_GIT="$REAL_GIT" FM_FAKE_GIT_LOG="$git_log" FM_FAKE_GH_LOG="$gh_log" FM_FAKE_SEND_LOG="$send_log" FM_FAKE_TREEHOUSE_LOG="$treehouse_log" FM_FAKE_ENDPOINT="$endpoint" FM_FAKE_PERSIST_BRANCH_ROUTE=1 run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a persistent future-branch push route must block"
  assert_contains "$out" "worker launch is waiting" "the persistent future-branch route did not report a blocked launch"
  [ ! -e "$endpoint" ] || fail "the future-branch route block created an endpoint"
  assert_no_grep 'encode launch-brief' "$send_log" "the future-branch route block started the worker"
  assert_grep "return --force $WT_DIR" "$treehouse_log" "the blocked future-branch allocation was not returned"
  pass "a persistent future-branch push route blocks before endpoint creation"
}

test_failed_pre_endpoint_lease_return_retains_recovery_record() {
  local rec id out status git_log gh_log send_log treehouse_log endpoint
  id=allocated-github-return-failure-z5
  rec=$(make_settle_case allocated-github-return-failure "$id" 0)
  read_settle_record "$rec"
  prepare_github_gate_case
  $REAL_GIT -C "$PROJ_DIR" config extensions.worktreeConfig true
  $REAL_GIT -C "$WT_DIR" config --worktree remote.origin.url https://github.example/owner/repo.git
  git_log="$TMP_ROOT/return-failure-git.log"
  gh_log="$TMP_ROOT/return-failure-gh.log"
  send_log="$TMP_ROOT/return-failure-send.log"
  treehouse_log="$TMP_ROOT/return-failure-treehouse.log"
  endpoint="$TMP_ROOT/return-failure-endpoint"
  : > "$git_log"; : > "$gh_log"; : > "$send_log"; : > "$treehouse_log"

  out=$(FM_REAL_GIT="$REAL_GIT" FM_FAKE_GIT_LOG="$git_log" FM_FAKE_GH_LOG="$gh_log" FM_FAKE_SEND_LOG="$send_log" FM_FAKE_TREEHOUSE_LOG="$treehouse_log" FM_FAKE_ENDPOINT="$endpoint" FM_FAKE_PERSIST_DIVERGENCE=1 FM_FAKE_TREEHOUSE_RETURN_FAIL=1 run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a blocked spawn with a failed lease return must fail"
  assert_contains "$out" "lease and recovery metadata were retained" "the failed lease return was not reported"
  [ -d "$WT_DIR" ] || fail "the failed lease return discarded the allocated worktree"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "the failed lease return did not retain recoverable worktree metadata"
  [ ! -e "$endpoint" ] || fail "the pre-endpoint lease failure created an endpoint"
  pass "a failed pre-endpoint lease return retains recovery metadata"
}

test_failed_endpoint_creation_retains_recoverable_lease() {
  local rec id out status git_log gh_log send_log treehouse_log endpoint
  id=allocated-github-create-failure-z6
  rec=$(make_settle_case allocated-github-create-failure "$id" 0)
  read_settle_record "$rec"
  prepare_github_gate_case
  git_log="$TMP_ROOT/create-failure-git.log"
  gh_log="$TMP_ROOT/create-failure-gh.log"
  send_log="$TMP_ROOT/create-failure-send.log"
  treehouse_log="$TMP_ROOT/create-failure-treehouse.log"
  endpoint="$TMP_ROOT/create-failure-endpoint"
  : > "$git_log"; : > "$gh_log"; : > "$send_log"; : > "$treehouse_log"

  out=$(FM_REAL_GIT="$REAL_GIT" FM_FAKE_GIT_LOG="$git_log" FM_FAKE_GH_LOG="$gh_log" FM_FAKE_SEND_LOG="$send_log" FM_FAKE_TREEHOUSE_LOG="$treehouse_log" FM_FAKE_ENDPOINT="$endpoint" FM_FAKE_CREATE_FAIL=1 run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a failed endpoint creation must fail the spawn"
  assert_contains "$out" "endpoint creation was not confirmed" "the unconfirmed endpoint creation was not reported"
  assert_no_grep 'return --force' "$treehouse_log" "an unconfirmed endpoint creation returned its worktree lease"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "the endpoint creation failure did not retain recoverable lease metadata"
  assert_grep "endpoint_task_id=$id" "$HOME_DIR/state/$id.meta" "the endpoint creation failure did not retain endpoint recovery identity"
  pass "a failed endpoint creation retains endpoint and lease recovery metadata"
}

test_unconfirmed_zellij_partial_endpoint_retains_lease_without_recovery_meta() {
  local rec id out status git_log gh_log send_log treehouse_log endpoint zellij_log list_count
  id=allocated-github-zellij-partial-z7
  rec=$(make_settle_case allocated-github-zellij-partial "$id" 0)
  read_settle_record "$rec"
  prepare_github_gate_case
  git_log="$TMP_ROOT/zellij-partial-git.log"
  gh_log="$TMP_ROOT/zellij-partial-gh.log"
  send_log="$TMP_ROOT/zellij-partial-send.log"
  treehouse_log="$TMP_ROOT/zellij-partial-treehouse.log"
  endpoint="$TMP_ROOT/zellij-partial-endpoint"
  zellij_log="$TMP_ROOT/zellij-partial-cli.log"
  list_count="$TMP_ROOT/zellij-partial-list-count"
  : > "$git_log"; : > "$gh_log"; : > "$send_log"; : > "$treehouse_log"; : > "$zellij_log"

  out=$(FM_REAL_GIT="$REAL_GIT" FM_FAKE_GIT_LOG="$git_log" FM_FAKE_GH_LOG="$gh_log" FM_FAKE_SEND_LOG="$send_log" FM_FAKE_TREEHOUSE_LOG="$treehouse_log" FM_FAKE_ENDPOINT="$endpoint" FM_FAKE_BACKEND=zellij FM_FAKE_ZELLIJ_LOG="$zellij_log" FM_FAKE_ZELLIJ_LIST_COUNT="$list_count" run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "an unconfirmed Zellij partial endpoint must fail the spawn"
  assert_contains "$out" "zellij may have left partial tab 9" "the possible Zellij orphan was not named"
  assert_contains "$out" "retained pooled-worktree lease '$WT_DIR' needs manual attention" "the retained pooled lease was not reported"
  assert_grep 'close-tab-by-id 9' "$zellij_log" "the partial Zellij endpoint was not cleaned up best-effort"
  assert_no_grep 'return --force' "$treehouse_log" "the possible orphan's pooled-worktree lease was returned"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "an unusable partial-endpoint recovery record was persisted"
  pass "an unconfirmed Zellij partial endpoint fails loudly without persisting unusable recovery metadata"
}

test_unresolved_endpoint_identity_never_persists_unusable_recovery() {
  local rec id out status git_log gh_log send_log treehouse_log endpoint zellij_log list_count
  id=allocated-github-zellij-unresolved-z8
  rec=$(make_settle_case allocated-github-zellij-unresolved "$id" 0)
  read_settle_record "$rec"
  prepare_github_gate_case
  git_log="$TMP_ROOT/zellij-unresolved-git.log"
  gh_log="$TMP_ROOT/zellij-unresolved-gh.log"
  send_log="$TMP_ROOT/zellij-unresolved-send.log"
  treehouse_log="$TMP_ROOT/zellij-unresolved-treehouse.log"
  endpoint="$TMP_ROOT/zellij-unresolved-endpoint"
  zellij_log="$TMP_ROOT/zellij-unresolved-cli.log"
  list_count="$TMP_ROOT/zellij-unresolved-list-count"
  : > "$git_log"; : > "$gh_log"; : > "$send_log"; : > "$treehouse_log"; : > "$zellij_log"

  out=$(FM_REAL_GIT="$REAL_GIT" FM_FAKE_GIT_LOG="$git_log" FM_FAKE_GH_LOG="$gh_log" FM_FAKE_SEND_LOG="$send_log" FM_FAKE_TREEHOUSE_LOG="$treehouse_log" FM_FAKE_ENDPOINT="$endpoint" FM_FAKE_BACKEND=zellij FM_FAKE_ZELLIJ_LOG="$zellij_log" FM_FAKE_ZELLIJ_LIST_COUNT="$list_count" FM_FAKE_ZELLIJ_BAD_TAB_ID=1 run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "an unresolved Zellij endpoint identity must fail the spawn"
  assert_contains "$out" "without recoverable exact identity" "the unresolved endpoint identity was not reported loudly"
  assert_contains "$out" "retained pooled-worktree lease '$WT_DIR' needs manual attention" "the retained lease was not named"
  assert_grep 'action list-tabs --json' "$zellij_log" "the unresolved partial endpoint did not receive best-effort cleanup discovery"
  assert_no_grep 'return --force' "$treehouse_log" "an unresolved endpoint's pooled lease was returned"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "an unusable unresolved-endpoint recovery record was persisted"
  pass "an unresolved endpoint identity fails loudly without unusable recovery metadata"
}

test_post_endpoint_failure_does_not_force_return_lease() {
  local rec id out status git_log gh_log send_log treehouse_log endpoint
  id=allocated-github-post-endpoint-failure-z7
  rec=$(make_settle_case allocated-github-post-endpoint-failure "$id" 0)
  read_settle_record "$rec"
  prepare_github_gate_case
  git_log="$TMP_ROOT/post-endpoint-git.log"
  gh_log="$TMP_ROOT/post-endpoint-gh.log"
  send_log="$TMP_ROOT/post-endpoint-send.log"
  treehouse_log="$TMP_ROOT/post-endpoint-treehouse.log"
  endpoint="$TMP_ROOT/post-endpoint"
  : > "$git_log"; : > "$gh_log"; : > "$send_log"; : > "$treehouse_log"

  out=$(FM_REAL_GIT="$REAL_GIT" FM_FAKE_GIT_LOG="$git_log" FM_FAKE_GH_LOG="$gh_log" FM_FAKE_SEND_LOG="$send_log" FM_FAKE_TREEHOUSE_LOG="$treehouse_log" FM_FAKE_ENDPOINT="$endpoint" FM_FAKE_FETCH_FAIL=1 run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a failed post-endpoint refresh must fail the spawn"
  [ -e "$endpoint" ] || fail "the fixture did not reach endpoint creation before failing"
  assert_no_grep 'return --force' "$treehouse_log" "a post-endpoint failure force-returned the live endpoint's worktree"
  pass "automatic lease return is disarmed after endpoint creation"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_divergent_allocated_worktree_destination_is_reset_before_launch
test_unverifiable_pool_reset_blocks_before_endpoint_creation
test_persistent_future_branch_route_blocks_before_endpoint_creation
test_failed_pre_endpoint_lease_return_retains_recovery_record
test_failed_endpoint_creation_retains_recoverable_lease
test_unconfirmed_zellij_partial_endpoint_retains_lease_without_recovery_meta
test_unresolved_endpoint_identity_never_persists_unusable_recovery
test_post_endpoint_failure_does_not_force_return_lease

echo "# all fm-spawn-worktree-settle tests passed"
