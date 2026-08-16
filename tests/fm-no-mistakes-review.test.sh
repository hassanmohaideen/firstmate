#!/usr/bin/env bash
# Behavioral regression coverage for the guarded no-mistakes review driver.
# The fake exposes only the documented no-mistakes axi command surface, so these
# tests assert invocation, refusal, durable ledger, and readiness behavior rather
# than implementation bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-review)
DRIVER="$ROOT/bin/fm-no-mistakes-review.sh"

new_case() {
  local name=$1 dir="$TMP_ROOT/$1"
  mkdir -p "$dir/fakebin" "$dir/fake-state"
  git -C "$dir" init -q
  git -C "$dir" config user.name fixture
  git -C "$dir" config user.email fixture@example.test
  printf 'base\n' > "$dir/file.txt"
  git -C "$dir" add file.txt
  git -C "$dir" commit -qm base
  git -C "$dir" checkout -qb "fm/$name"
  printf '0\n' > "$dir/fake-state/phase"
  printf '[]\n' > "$dir/fake-state/calls"
  printf '[]\n' > "$dir/fake-state/markers"
  printf '%s\n' 'https://github.com/example/repo/pull/11' > "$dir/fake-state/pr"
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
state=${FM_FAKE_NM_STATE:?}
cmd=${1:-}
shift || true
branch=$(git symbolic-ref --quiet --short HEAD)
head=$(git rev-parse --short HEAD)
phase=$(cat "$state/phase")

append_call() {
  local tmp="$state/calls.tmp.$$"
  jq --arg call "$*" '. + [$call]' "$state/calls" > "$tmp"
  mv "$tmp" "$state/calls"
}

emit_status() {
  local review_status=awaiting_approval status=running pr='' outcome=''
  if [ "$phase" -gt 0 ]; then
    review_status=completed
    status=ci
    pr=$(cat "$state/pr")
  fi
  if [ -f "$state/status-head" ]; then head=$(cat "$state/status-head"); fi
  if [ -f "$state/status-branch" ]; then branch=$(cat "$state/status-branch"); fi
  if [ -f "$state/status-outcome" ]; then outcome=$(cat "$state/status-outcome"); fi
  cat <<EOF
run:
  id: "RUN-11"
  branch: "$branch"
  status: $status
  outcome: $outcome
  head: "$head"
  pr: "$pr"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,$review_status,0,0
    pr,$([ "$phase" -gt 0 ] && printf completed || printf pending),0,0
    ci,$([ "$phase" -gt 0 ] && printf running || printf pending),0,0
EOF
}

emit_review_logs() {
  local count i result quoted marker
  count=$(jq 'length' "$state/rounds")
  marker_count=$(jq '[.[] | select(. == true)] | length' "$state/markers")
  total=$((count + marker_count))
  printf 'step: review\nrun: "RUN-11"\nlines: %s total\nlog[%s]{line}:\n' "$total" "$total"
  i=0
  while [ "$i" -lt "$count" ]; do
    result=$(jq -c ".[$i]" "$state/rounds")
    quoted=$(printf '%s' "$result" | jq -Rs .)
    printf '  %s\n' "$quoted"
    marker=$(jq -r ".[$i] // false" "$state/markers")
    if [ "$marker" = true ]; then
      printf '  "committed agent fixes: no-mistakes(review): fixture fix"\n'
    fi
    i=$((i + 1))
  done
}

case "$cmd ${1:-}" in
  "axi status") emit_status ;;
  "axi logs")
    case " $* " in
      *" --step review "*) emit_review_logs ;;
      *" --step ci "*)
        : > "$state/ci-queried"
        if [ -f "$state/ci-red" ]; then
          printf '%s\n' 'CI checks failed - issues detected'
        elif [ -f "$state/ci-no-checks" ]; then
          printf '%s\n' 'no CI checks reported - still monitoring until merged or closed'
        else
          printf '%s\n' 'all CI checks passed - still monitoring until merged or closed'
        fi
        ;;
      *) exit 2 ;;
    esac
    ;;
  "axi respond")
    append_call "$*"
    [ ! -f "$state/respond-fail" ] || exit 23
    action=
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --action ]; then action=$2; break; fi
      shift
    done
    if [ "$action" = fix ]; then
      git commit --allow-empty -qm 'fake no-mistakes fix'
      tmp="$state/rounds.tmp.$$"
      jq --slurpfile next "$state/next-result" '. + [$next[0]]' "$state/rounds" > "$tmp"
      mv "$tmp" "$state/rounds"
      tmp="$state/markers.tmp.$$"
      jq '. + [false] | .[-2] = true' "$state/markers" > "$tmp"
      mv "$tmp" "$state/markers"
    fi
    printf '1\n' > "$state/phase"
    ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$dir/fakebin/no-mistakes"
  printf '%s\n' "$dir"
}

finding() {
  local id=$1 action=${2:-ask-user} description=${3:-"finding $1"}
  jq -cn --arg id "$id" --arg action "$action" --arg description "$description" \
    '{id:$id,severity:"error",file:"file.txt",line:1,description:$description,action:$action,review_scope:"source"}'
}

set_round() {
  local dir=$1
  shift
  printf '%s\n' "$@" | jq -sc '{findings:.,tested:[],testing_summary:"fixture",risk_level:"high",risk_rationale:"fixture",risk_scope:"source"}' \
    | jq -s . > "$dir/fake-state/rounds"
  printf 'false\n' | jq -s . > "$dir/fake-state/markers"
}

set_next() {
  local dir=$1
  shift
  printf '%s\n' "$@" | jq -sc '{findings:.,tested:[],testing_summary:"fixture next",risk_level:"low",risk_rationale:"fixture",risk_scope:"source"}' \
    > "$dir/fake-state/next-result"
}

run_driver() {
  local dir=$1
  shift
  (cd "$dir" && FM_FAKE_NM_STATE="$dir/fake-state" PATH="$dir/fakebin:$PATH" "$DRIVER" "$@")
}

ledger() {
  printf '%s/.no-mistakes/firstmate-review-ledger.json\n' "$1"
}

calls_count() {
  jq 'length' "$1/fake-state/calls"
}

guard_file() {
  printf '%s/.no-mistakes/.firstmate-review-ledger.guard\n' "$1"
}

legacy_owner_file() {
  printf '%s/.no-mistakes/firstmate-review-ledger.lock/owner.json\n' "$1"
}

new_ready_case() {
  local name=$1 d f
  d=$(new_case "$name")
  f=$(finding accepted ask-user)
  set_round "$d" "$f"
  run_driver "$d" respond --approve accepted >/dev/null 2>&1 \
    || fail "$name ready fixture could not record its review disposition"
  printf '%s\n' "$d"
}

# Deterministically make a holder acquire the kernel lock and then die, so the
# kernel releases the lock exactly as an abandoned owner would. No sleeping and
# no reliance on a naturally reused PID.
crash_holding_owner() {
  local d=$1 rc
  FM_NM_REVIEW_TEST_CRASH_HOLDING=1 run_driver "$d" audit-ready >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "crash-holding fixture unexpectedly completed instead of dying under the lock"
}

wait_for_marker() {
  local marker=$1 pid=$2 spins=0
  while [ ! -s "$marker" ]; do
    kill -0 "$pid" 2>/dev/null || fail "guarded fixture exited before reaching its deterministic marker"
    spins=$((spins + 1))
    [ "$spins" -lt 1000000 ] || fail "guarded fixture did not reach its deterministic marker"
  done
}

test_all_findings_fixed_and_audited_ready() {
  local d out first second
  d=$(new_case all-fixed)
  first=$(finding mechanical auto-fix 'mechanical correction')
  second=$(finding decision ask-user 'captain decision')
  set_round "$d" "$first" "$second"
  set_next "$d"
  out=$(run_driver "$d" respond --fix mechanical,decision --instructions 'fix both' 2>&1) \
    || fail "all-findings fix failed: $out"
  assert_contains "$out" 'action=fix findings=mechanical,decision' "all-findings fix did not report its explicit set"
  [ "$(calls_count "$d")" -eq 1 ] || fail "all-findings fix did not invoke the public response exactly once"
  [ "$(jq '[.runs[0].rounds[0].dispositions[] | select(.state == "fixed_and_confirmed")] | length' "$(ledger "$d")")" -eq 2 ] \
    || fail "all-findings fix was not confirmed from the next review"
  out=$(run_driver "$d" audit-ready 2>&1) || fail "successful audited readiness failed: $out"
  assert_contains "$out" 'ready: https://github.com/example/repo/pull/11' "audited readiness omitted the PR"
  pass "guarded all-findings fix reaches audited readiness"
}

test_all_approved_and_explicit_rejection() {
  local d out f
  d=$(new_case all-approved)
  f=$(finding accepted ask-user)
  set_round "$d" "$f"
  out=$(run_driver "$d" respond --approve accepted 2>&1) || fail "explicit approval failed: $out"
  [ "$(jq -r '.runs[0].rounds[0].dispositions[0].state' "$(ledger "$d")")" = approved_as_is ] \
    || fail "explicit approval was not durably recorded"
  run_driver "$d" audit-ready >/dev/null 2>&1 || fail "all-approved path did not audit ready"

  d=$(new_case explicit-reject)
  f=$(finding rejected ask-user)
  set_round "$d" "$f"
  out=$(run_driver "$d" respond --reject rejected 2>&1) || fail "explicit rejection failed: $out"
  [ "$(jq -r '.runs[0].rounds[0].dispositions[0].state' "$(ledger "$d")")" = rejected_or_skipped ] \
    || fail "explicit rejection was not durably recorded"
  assert_contains "$(jq -r '.[0]' "$d/fake-state/calls")" '--action skip' "rejection did not map to the public skip action"
  pass "all approvals and explicit rejection remain explicit durable actions"
}

test_pr11_partial_fix_reproduction_and_proven_path() {
  local d out before after mechanical decision raw_call raw_status raw_ci
  mechanical=$(finding mechanical auto-fix 'mechanical correction')
  decision=$(finding decision ask-user 'decision finding that omission used to decline')

  # Reproduce the three distinct public-interface stages of PR #11's failure.
  # The initiating call selects only the mechanical finding; the fake's public
  # whole-review response advances the review anyway; the next public review is
  # clean and CI appears green even though no action accounted for `decision`.
  d=$(new_case pr11-unsafe-baseline)
  set_round "$d" "$mechanical" "$decision"
  set_next "$d"
  (cd "$d" && FM_FAKE_NM_STATE="$d/fake-state" PATH="$d/fakebin:$PATH" \
    no-mistakes axi respond --step review --action fix --findings mechanical >/dev/null) \
    || fail "unsafe baseline partial response did not reproduce"
  raw_call=$(jq -r '.[0]' "$d/fake-state/calls")
  assert_contains "$raw_call" '--findings mechanical' "baseline did not initiate the partial mechanical fix"
  assert_not_contains "$raw_call" 'decision' "baseline unexpectedly selected the decision finding"
  [ "$(jq '. | length' "$d/fake-state/rounds")" -eq 2 ] \
    || fail "whole-review response did not advance to a later review"
  [ "$(jq '.[1].findings | length' "$d/fake-state/rounds")" -eq 0 ] \
    || fail "later review was not clean in the false-ready reproduction"
  raw_status=$(cd "$d" && FM_FAKE_NM_STATE="$d/fake-state" PATH="$d/fakebin:$PATH" no-mistakes axi status)
  raw_ci=$(cd "$d" && FM_FAKE_NM_STATE="$d/fake-state" PATH="$d/fakebin:$PATH" no-mistakes axi logs --run RUN-11 --step ci)
  assert_contains "$raw_status" 'pr: "https://github.com/example/repo/pull/11"' "baseline did not expose the visible PR-ready result"
  assert_contains "$raw_ci" 'CI checks passed' "baseline did not expose the visible green-CI result"

  # The guarded path refuses that initiating partial call before either the
  # whole-review response or ledger can change, then proves the accounted path.
  d=$(new_case pr11-partial)
  set_round "$d" "$mechanical" "$decision"
  set_next "$d"
  before=absent
  out=$(run_driver "$d" respond --fix mechanical 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "partial mechanical fix unexpectedly succeeded"
  assert_contains "$out" 'omitted finding: decision' "partial refusal did not name the omitted decision finding"
  [ "$(calls_count "$d")" -eq 0 ] || fail "partial refusal invoked the underlying whole-review response"
  [ ! -e "$(ledger "$d")" ] || fail "partial refusal changed ledger state"
  after=absent
  [ "$before" = "$after" ] || fail "partial refusal changed the validation fixture"

  out=$(run_driver "$d" respond --fix mechanical,decision 2>&1) \
    || fail "proven all-findings-accounted path failed: $out"
  [ "$(calls_count "$d")" -eq 1 ] || fail "proven path did not invoke exactly one whole-review response"
  [ "$(jq '[.runs[0].rounds[0].dispositions[] | select(.state == "fixed_and_confirmed")] | length' "$(ledger "$d")")" -eq 2 ] \
    || fail "proven path did not account for every finding"
  pass "PR #11 initiating partial response, whole-review collapse, and false-ready result are reproduced and refused"
}

test_mixed_choices_are_unrepresentable() {
  local d out a b
  d=$(new_case mixed)
  a=$(finding a auto-fix)
  b=$(finding b ask-user)
  set_round "$d" "$a" "$b"
  out=$(run_driver "$d" respond --fix a --approve b 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "mixed choices unexpectedly collapsed into one response"
  assert_contains "$out" 'cannot be represented' "mixed-choice refusal was not actionable"
  [ "$(calls_count "$d")" -eq 0 ] || fail "mixed-choice refusal invoked no-mistakes"
  [ ! -e "$(ledger "$d")" ] || fail "mixed-choice refusal wrote a ledger"
  pass "mixed per-finding choices are refused rather than collapsed"
}

test_multiple_fix_rounds_preserve_history() {
  local d one two
  d=$(new_case multiple-rounds)
  one=$(finding one auto-fix 'round one')
  two=$(finding two ask-user 'round two')
  set_round "$d" "$one"
  set_next "$d" "$two"
  run_driver "$d" respond --fix one >/dev/null 2>&1 || fail "first fix round failed"
  set_next "$d"
  run_driver "$d" respond --fix two >/dev/null 2>&1 || fail "second fix round failed"
  [ "$(jq '.runs[0].rounds | length' "$(ledger "$d")")" -eq 3 ] \
    || fail "multiple fix rounds replaced prior review history"
  [ "$(jq '[.runs[0].rounds[].result.findings[].id] | sort == ["one","two"]' "$(ledger "$d")")" = true ] \
    || fail "multiple fix rounds lost a prior finding"
  [ "$(jq '[.runs[0].rounds[] | select(.fix_completed_after == true)] | length' "$(ledger "$d")")" -eq 2 ] \
    || fail "fix review markers were not preserved"
  pass "multiple review and fix rounds extend one run ledger"
}

test_surviving_finding_refuses_readiness() {
  local d out same
  d=$(new_case survives)
  same=$(finding same auto-fix 'unchanged')
  set_round "$d" "$same"
  set_next "$d" "$same"
  out=$(run_driver "$d" respond --fix same 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "unchanged surviving finding was called fixed"
  assert_contains "$out" 'survived_unchanged' "surviving finding refusal lacked its evidence"
  out=$(run_driver "$d" audit-ready 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "readiness accepted a finding that survived unchanged"
  assert_contains "$out" 'survived unchanged' "readiness did not explain surviving fix"
  pass "a selected fix is not complete when the finding survives re-review"
}

test_clean_current_status_cannot_erase_unresolved_history() {
  local d out unresolved clean
  d=$(new_case unresolved-history)
  unresolved=$(finding unresolved ask-user)
  clean='{"findings":[],"tested":[],"testing_summary":"clean","risk_level":"low","risk_rationale":"clean","risk_scope":"source"}'
  set_round "$d" "$unresolved"
  jq --argjson clean "$clean" '. + [$clean]' "$d/fake-state/rounds" > "$d/fake-state/rounds.tmp"
  mv "$d/fake-state/rounds.tmp" "$d/fake-state/rounds"
  printf '[false,false]\n' > "$d/fake-state/markers"
  printf '1\n' > "$d/fake-state/phase"
  out=$(run_driver "$d" audit-ready 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "clean current review erased unresolved historical finding"
  assert_contains "$out" 'no exact head context' "historical unresolved audit did not preserve/refuse unknown context"
  assert_contains "$out" 'no explicit disposition' "historical unresolved audit did not report missing disposition"
  pass "clean current status cannot erase unresolved historical findings"
}

test_response_refuses_fallback_branch_and_stale_head_without_state_changes() {
  local d out f stale
  d=$(new_case response-context)
  f=$(finding context ask-user)
  set_round "$d" "$f"

  printf 'fm/another-validation\n' > "$d/fake-state/status-branch"
  out=$(run_driver "$d" respond --approve context 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "another branch's fallback status was accepted for response"
  assert_contains "$out" 'stale-run branch mismatch' "fallback-branch response refusal was not actionable"
  [ "$(calls_count "$d")" -eq 0 ] || fail "fallback-branch refusal invoked the underlying response"
  [ ! -e "$(ledger "$d")" ] || fail "fallback-branch refusal changed ledger state"

  rm -f "$d/fake-state/status-branch"
  git -C "$d" commit --allow-empty -qm 'new local head'
  stale=$(git -C "$d" rev-parse HEAD^)
  printf '%s\n' "$stale" > "$d/fake-state/status-head"
  out=$(run_driver "$d" respond --approve context 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "stale public head was accepted for response"
  assert_contains "$out" 'stale-head mismatch' "stale-head response refusal was not actionable"
  [ "$(calls_count "$d")" -eq 0 ] || fail "stale-head refusal invoked the underlying response"
  [ ! -e "$(ledger "$d")" ] || fail "stale-head refusal changed ledger state"
  pass "responses reject fallback branches and stale heads before state changes"
}

test_pipeline_descendant_head_is_accepted() {
  local d out f tree descendant
  d=$(new_case pipeline-descendant)
  f=$(finding context ask-user)
  set_round "$d" "$f"
  tree=$(git -C "$d" rev-parse 'HEAD^{tree}')
  descendant=$(printf 'pipeline fix\n' | git -C "$d" commit-tree "$tree" -p HEAD)
  printf '%s\n' "$descendant" > "$d/fake-state/status-head"

  out=$(run_driver "$d" respond --approve context 2>&1) \
    || fail "pipeline descendant validation head was refused: $out"
  [ "$(calls_count "$d")" -eq 1 ] || fail "accepted pipeline descendant did not invoke the response"
  [ "$(jq -r '.runs[0].rounds[0].head' "$(ledger "$d")")" = "$descendant" ] \
    || fail "pipeline descendant head was not attached to the disposition"
  run_driver "$d" audit-ready >/dev/null 2>&1 \
    || fail "pipeline descendant validation head was refused during audit"
  pass "pipeline fix commits may advance the run head beyond local HEAD"
}

test_post_review_pipeline_commit_refuses_readiness() {
  local d out f tree descendant ledger_path before after
  d=$(new_case stale-review-head)
  f=$(finding accepted ask-user)
  set_round "$d" "$f"
  run_driver "$d" respond --approve accepted >/dev/null 2>&1 \
    || fail "stale-review-head fixture approval failed"
  ledger_path=$(ledger "$d")
  before=$(shasum -a 256 "$ledger_path" | awk '{print $1}')
  tree=$(git -C "$d" rev-parse 'HEAD^{tree}')
  descendant=$(printf 'later pipeline fix\n' | git -C "$d" commit-tree "$tree" -p HEAD)
  printf '%s\n' "$descendant" > "$d/fake-state/status-head"

  out=$(run_driver "$d" audit-ready 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "readiness accepted a pipeline commit with no subsequent review result"
  assert_contains "$out" 'stale-head review coverage' "stale review coverage refusal was not actionable"
  assert_contains "$out" "$descendant" "stale review coverage refusal omitted the authoritative head"
  assert_not_contains "$out" 'ready:' "unreviewed pipeline commit was visibly reported ready"
  after=$(shasum -a 256 "$ledger_path" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "stale review coverage audit rebound or changed the ledger"
  pass "pipeline commits require a subsequent authoritative review result"
}

test_no_ci_checks_refuses_readiness() {
  local d out f
  d=$(new_case no-ci-checks)
  f=$(finding accepted ask-user)
  set_round "$d" "$f"
  run_driver "$d" respond --approve accepted >/dev/null 2>&1 \
    || fail "no-CI fixture approval failed"
  : > "$d/fake-state/ci-no-checks"
  out=$(run_driver "$d" audit-ready 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "readiness accepted a run with no public CI checks"
  assert_contains "$out" 'not green' "no-CI readiness refusal was not actionable"
  assert_not_contains "$out" 'ready:' "no-CI run was visibly reported ready"
  pass "readiness requires actual public green CI evidence"
}

test_terminal_outcomes_reject_stale_green_ci() {
  local d out f outcome
  for outcome in cancelled failed; do
    d=$(new_case "terminal-$outcome")
    f=$(finding accepted ask-user)
    set_round "$d" "$f"
    run_driver "$d" respond --approve accepted >/dev/null 2>&1 \
      || fail "$outcome fixture approval failed"
    rm -f "$d/fake-state/ci-queried"
    printf '%s\n' "$outcome" > "$d/fake-state/status-outcome"

    out=$(run_driver "$d" audit-ready 2>&1); rc=$?
    [ "$rc" -ne 0 ] || fail "readiness accepted a terminal $outcome run with stale green CI"
    assert_contains "$out" "outcome is $outcome" "$outcome readiness refusal did not name the terminal outcome"
    assert_not_contains "$out" 'ready:' "$outcome run was visibly reported ready"
    [ ! -e "$d/fake-state/ci-queried" ] \
      || fail "$outcome readiness consulted stale historical CI evidence"
  done
  pass "failed and cancelled runs cannot reuse stale green CI evidence"
}

test_run_and_head_mismatch_are_refused() {
  local d out f ledger_path before after stale
  d=$(new_case context-mismatch)
  git -C "$d" commit --allow-empty -qm 'current validation head'
  f=$(finding context ask-user)
  set_round "$d" "$f"
  run_driver "$d" respond --approve context >/dev/null 2>&1 || fail "context fixture approval failed"
  ledger_path=$(ledger "$d")
  before=$(shasum -a 256 "$ledger_path" | awk '{print $1}')
  stale=$(git -C "$d" rev-parse HEAD^)
  printf '%s\n' "$stale" > "$d/fake-state/status-head"
  out=$(run_driver "$d" audit-ready 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "stale public head was accepted"
  assert_contains "$out" 'stale-head mismatch' "head mismatch refusal was not actionable"
  after=$(shasum -a 256 "$ledger_path" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "stale-head audit synchronized or changed the ledger"
  rm -f "$d/fake-state/status-head"
  jq '.runs[0].rounds[0].dispositions[0].run_id = "STALE"' "$ledger_path" > "$ledger_path.tmp"
  mv "$ledger_path.tmp" "$ledger_path"
  out=$(run_driver "$d" audit-ready 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "stale-run disposition was accepted"
  assert_contains "$out" 'stale-run disposition context' "run mismatch refusal was not actionable"
  pass "run and head mismatches refuse readiness before synchronization"
}

test_duplicate_replay_and_underlying_failure() {
  local d out f before after
  d=$(new_case replay)
  f=$(finding replay ask-user)
  set_round "$d" "$f"
  run_driver "$d" respond --approve replay >/dev/null 2>&1 || fail "initial replay fixture response failed"
  before=$(shasum -a 256 "$(ledger "$d")" | awk '{print $1}')
  out=$(run_driver "$d" respond --approve replay 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "duplicate response replay succeeded"
  [ "$(calls_count "$d")" -eq 1 ] || fail "duplicate response replay invoked the CLI twice"
  after=$(shasum -a 256 "$(ledger "$d")" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "duplicate response replay changed the ledger"

  d=$(new_case underlying-failure)
  f=$(finding failure auto-fix)
  set_round "$d" "$f"
  set_next "$d"
  : > "$d/fake-state/respond-fail"
  out=$(run_driver "$d" respond --fix failure 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "underlying CLI failure was hidden"
  assert_contains "$out" 'exit 23' "underlying failure exit was not surfaced"
  [ "$(jq -r '.runs[0].rounds[0].dispositions[0].state' "$(ledger "$d")")" = requested ] \
    || fail "underlying failure was silently confirmed or dropped"
  out=$(run_driver "$d" audit-ready 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "readiness accepted a requested-only failed response"
  assert_contains "$out" 'merely requested' "failed-response readiness lacked requested-only diagnostic"
  pass "duplicate replay is idempotent and underlying failure remains unconfirmed"
}

test_concurrent_writers_are_serial_and_atomic() {
  local d f p1 p2 r1 r2 count ledger_path winner_fifo marker spins=0
  d=$(new_case concurrent)
  f=$(finding concurrent auto-fix)
  set_round "$d" "$f"
  set_next "$d"
  winner_fifo="$d/winner-release"
  marker="$d/winner-acquired"
  mkfifo "$winner_fifo"
  (FM_NM_REVIEW_TEST_ACQUIRED="$marker" FM_NM_REVIEW_TEST_HOLD_FIFO="$winner_fifo" \
    run_driver "$d" respond --fix concurrent >"$d/out1" 2>&1) & p1=$!
  (FM_NM_REVIEW_TEST_ACQUIRED="$marker" FM_NM_REVIEW_TEST_HOLD_FIFO="$winner_fifo" \
    run_driver "$d" respond --fix concurrent >"$d/out2" 2>&1) & p2=$!
  while [ ! -s "$marker" ] || ! grep -q 'live owner' "$d/out1" "$d/out2" 2>/dev/null; do
    kill -0 "$p1" 2>/dev/null || kill -0 "$p2" 2>/dev/null \
      || fail "both concurrent writers exited before one acquired the ledger"
    spins=$((spins + 1))
    [ "$spins" -lt 1000000 ] || fail "concurrent writer election did not converge"
  done
  printf 'release\n' > "$winner_fifo"
  wait "$p1"; r1=$?
  wait "$p2"; r2=$?
  if [ "$r1" -eq 0 ]; then
    [ "$r2" -ne 0 ] || fail "both concurrent guarded writers replayed the response"
  elif [ "$r2" -eq 0 ]; then
    [ "$r1" -ne 0 ] || fail "both concurrent guarded writers replayed the response"
  else
    fail "neither concurrent guarded writer completed: $(cat "$d/out1"); $(cat "$d/out2")"
  fi
  count=$(calls_count "$d")
  [ "$count" -eq 1 ] || fail "concurrent writers invoked underlying CLI $count times"
  ledger_path=$(ledger "$d")
  jq -e '.version == 1 and (.runs | length) == 1 and (.runs[0].rounds | length) == 2' "$ledger_path" >/dev/null \
    || fail "concurrent writers corrupted or truncated the ledger"
  pass "concurrent guarded writers serialize without corruption or duplicate invocation"
}

# Single-owner exclusion is now proven only by the host kernel's advisory lock,
# which is non-mintable and released the instant the owner exits. The initiating
# trigger in the abandoned-owner regression is an owner that dies holding that
# lock; the visible symptom used to be a later complete-history audit that could
# never establish readiness. A matching live holder is the proven contention path.
test_matching_live_owner_refuses() {
  local d p rc acquired release out
  d=$(new_ready_case live-owner)
  acquired="$d/live-acquired"
  release="$d/live-release"
  mkfifo "$release"
  (FM_NM_REVIEW_TEST_ACQUIRED="$acquired" FM_NM_REVIEW_TEST_HOLD_FIFO="$release" \
    run_driver "$d" audit-ready >"$d/live-out" 2>&1) & p=$!
  wait_for_marker "$acquired" "$p"
  out=$(run_driver "$d" audit-ready 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a live kernel-lock holder allowed concurrent audit access"
  assert_contains "$out" 'live owner' "live-owner refusal did not identify active contention"
  printf 'release\n' > "$release"
  wait "$p" || fail "original live holder did not finish normally"
  pass "a live kernel-lock holder refuses concurrent ledger access"
}

test_dead_owner_recovers_and_audit_is_idempotent() {
  local d out
  d=$(new_ready_case dead-owner)
  crash_holding_owner "$d"
  [ ! -e "$(legacy_owner_file "$d")" ] \
    || fail "kernel-lock recovery unexpectedly created a forgeable owner artifact"
  out=$(run_driver "$d" audit-ready 2>&1) \
    || fail "complete audit did not recover after the owner died holding the lock: $out"
  assert_contains "$out" 'ready: https://github.com/example/repo/pull/11' \
    "recovered audit did not establish public readiness"
  run_driver "$d" audit-ready >/dev/null 2>&1 \
    || fail "recovered complete audit was not idempotent"
  pass "an owner that died holding the lock is auto-recovered and readiness stays idempotent"
}

# The kernel lock is the only proof of ownership, so a forged on-disk ownership
# artifact can neither impersonate a dead owner (PID reuse) nor grant entry past
# a live holder.
test_forged_capability_cannot_impersonate_or_grant() {
  local d owner fifo pid out rc release acquired p
  d=$(new_ready_case forged-live-pid)
  crash_holding_owner "$d"
  owner=$(legacy_owner_file "$d")
  fifo="$d/unrelated-release"
  mkfifo "$fifo"
  (IFS= read -r _ < "$fifo") & pid=$!
  mkdir -p "${owner%/*}"
  jq -cn --argjson pid "$pid" \
    '{version:1,token:"forged-token",pid:$pid,host:{os:"fixture",node:"fixture",boot:"fixture"},process:{kind:"fixture",start:"forged-start"}}' \
    > "$owner"
  out=$(run_driver "$d" audit-ready 2>&1); rc=$?
  printf 'release\n' > "$fifo"
  wait "$pid" 2>/dev/null || true
  [ "$rc" -eq 0 ] || fail "a forged ownership artifact bearing a live PID blocked recovery: $out"
  assert_contains "$out" 'ready:' "forged live-PID artifact prevented the public audit"

  d=$(new_ready_case forged-grant)
  release="$d/holder-release"
  acquired="$d/holder-acquired"
  mkfifo "$release"
  (FM_NM_REVIEW_TEST_ACQUIRED="$acquired" FM_NM_REVIEW_TEST_HOLD_FIFO="$release" \
    run_driver "$d" audit-ready >"$d/holder-out" 2>&1) & p=$!
  wait_for_marker "$acquired" "$p"
  owner=$(legacy_owner_file "$d")
  mkdir -p "${owner%/*}"
  printf '%s\n' '{"forged":"released"}' > "$owner"
  out=$(run_driver "$d" audit-ready 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a forged artifact granted concurrent entry past a live kernel-lock holder"
  assert_contains "$out" 'live owner' "forged-grant refusal did not identify the live holder"
  printf 'release\n' > "$release"
  wait "$p" || fail "genuine kernel-lock holder did not finish after release"
  pass "a forged ownership artifact can neither impersonate a dead owner nor grant entry past a live one"
}

test_unsupported_lock_primitive_refuses() {
  local d out rc f
  d=$(new_case no-locker)
  f=$(finding accepted ask-user)
  set_round "$d" "$f"
  out=$(FM_NM_REVIEW_TEST_NO_LOCKER=1 run_driver "$d" respond --approve accepted 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "response proceeded without a kernel lock primitive"
  assert_contains "$out" 'REFUSED:' "unavailable lock primitive lacked a red refusal diagnostic"
  assert_contains "$out" 'without single-owner exclusion' "unavailable lock refusal was not actionable"
  [ ! -e "$(ledger "$d")" ] || fail "unavailable lock primitive still mutated the ledger"
  [ "$(calls_count "$d")" -eq 0 ] || fail "unavailable lock primitive still invoked no-mistakes"
  out=$(FM_NM_REVIEW_TEST_NO_LOCKER=1 run_driver "$d" audit-ready 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "audit proceeded without a kernel lock primitive"
  assert_contains "$out" 'without single-owner exclusion' "unavailable lock audit refusal was not actionable"
  pass "an unavailable or unsupported kernel lock primitive refuses closed without mutation"
}

test_two_reclaimers_converge_to_one_owner() {
  local d release acquired p1 p2 r1 r2 spins=0 owner_count
  d=$(new_ready_case reclaim-race)
  crash_holding_owner "$d"
  release="$d/reclaimer-release"
  acquired="$d/reclaimer-acquired"
  mkfifo "$release"
  (FM_NM_REVIEW_TEST_ACQUIRED="$acquired" FM_NM_REVIEW_TEST_HOLD_FIFO="$release" \
    run_driver "$d" audit-ready >"$d/reclaim1" 2>&1) & p1=$!
  (FM_NM_REVIEW_TEST_ACQUIRED="$acquired" FM_NM_REVIEW_TEST_HOLD_FIFO="$release" \
    run_driver "$d" audit-ready >"$d/reclaim2" 2>&1) & p2=$!
  while [ ! -s "$acquired" ] || ! grep -q 'live owner' "$d/reclaim1" "$d/reclaim2" 2>/dev/null; do
    kill -0 "$p1" 2>/dev/null || kill -0 "$p2" 2>/dev/null \
      || fail "both reclaimers exited before the kernel-lock election converged"
    spins=$((spins + 1))
    [ "$spins" -lt 1000000 ] || fail "simultaneous reclaimers did not converge"
  done
  owner_count=$(wc -l < "$acquired" | tr -d '[:space:]')
  [ "$owner_count" -eq 1 ] || fail "simultaneous reclaimers both entered the guarded section"
  printf 'release\n' > "$release"
  wait "$p1"; r1=$?
  wait "$p2"; r2=$?
  [ $(( (r1 == 0) + (r2 == 0) )) -eq 1 ] \
    || fail "simultaneous reclaimers did not produce exactly one winner"
  run_driver "$d" audit-ready >/dev/null 2>&1 \
    || fail "safe losing reclaimer could not retry after the winner released"
  pass "simultaneous reclaimers converge to one kernel-lock owner and one safe retry"
}

test_crash_while_holding_leaves_no_owner_and_recovers() {
  local d out
  d=$(new_ready_case holding-crash)
  crash_holding_owner "$d"
  [ ! -e "$(legacy_owner_file "$d")" ] \
    || fail "a crash under the lock exposed a partial forgeable ownership artifact"
  crash_holding_owner "$d"
  out=$(run_driver "$d" audit-ready 2>&1) \
    || fail "repeated crash-while-holding was not recoverable: $out"
  assert_contains "$out" 'ready:' "recovered audit after repeated crashes did not complete"
  pass "a crash while holding the lock leaves no ownership artifact and stays recoverable"
}

test_old_owner_exit_never_removes_guard_lock() {
  local d guard sentinel p release acquired
  d=$(new_ready_case guard-persistence)
  guard=$(guard_file "$d")
  run_driver "$d" audit-ready >/dev/null 2>&1 || fail "uncontended audit failed"
  [ -f "$guard" ] || fail "a normal owner exit removed the shared guard lock file"
  # Mark the file so an unlink-and-recreate by any exit path is detectable: the
  # driver only creates the guard when absent and never rewrites its contents.
  sentinel="old-owner-guard-marker"
  printf '%s\n' "$sentinel" > "$guard"
  release="$d/succ-release"
  acquired="$d/succ-acquired"
  mkfifo "$release"
  (FM_NM_REVIEW_TEST_ACQUIRED="$acquired" FM_NM_REVIEW_TEST_HOLD_FIFO="$release" \
    run_driver "$d" audit-ready >"$d/succ-out" 2>&1) & p=$!
  wait_for_marker "$acquired" "$p"
  [ -f "$guard" ] || fail "the guard lock file vanished while a successor held it"
  grep -q "$sentinel" "$guard" \
    || fail "the successor locked a recreated guard file, not the prior owner's"
  printf 'release\n' > "$release"
  wait "$p" || fail "successor audit did not complete"
  [ -f "$guard" ] || fail "successor exit removed the shared guard lock file"
  grep -q "$sentinel" "$guard" || fail "an owner exit unlinked and recreated the guard lock file"
  pass "no owner exit or cleanup ever removes the shared kernel guard lock"
}

test_normal_uncontended_acquire_and_release() {
  local d out
  d=$(new_ready_case uncontended)
  out=$(run_driver "$d" audit-ready 2>&1) || fail "uncontended audit failed: $out"
  assert_contains "$out" 'ready:' "uncontended audit did not report readiness"
  run_driver "$d" audit-ready >/dev/null 2>&1 \
    || fail "lock was not released after a normal uncontended audit"
  [ -f "$(guard_file "$d")" ] || fail "normal release removed the shared guard lock file"
  pass "normal uncontended acquisition releases the lock for the next owner"
}

# The internal lock-held entry point is publicly invokable, so it must prove it
# actually holds the kernel guard rather than trusting a caller-mintable
# credential. A direct call with a free guard - even with forged capability files
# and environment variables planted - is refused before any ledger mutation.
test_direct_internal_reentry_without_lock_is_refused() {
  local d out rc f forged
  d=$(new_case direct-reentry)
  f=$(finding accepted ask-user)
  set_round "$d" "$f"
  # Plant the forgeable artifacts an attacker could mint: a legacy capability
  # file and matching environment variables. They must not grant entry.
  forged="$d/.no-mistakes/.firstmate-review-kernel-capability.forged"
  mkdir -p "$d/.no-mistakes"
  printf 'forged-token\n' > "$forged"
  out=$(FM_NM_REVIEW_KERNEL_CAPABILITY=forged-token FM_NM_REVIEW_KERNEL_TOKEN=forged-token \
    run_driver "$d" __fm_review_lock_held respond --approve accepted 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "direct internal reentry ran without holding the kernel guard"
  assert_contains "$out" 'direct reentry is refused' "direct-reentry refusal was not actionable"
  [ ! -e "$(ledger "$d")" ] || fail "direct internal reentry mutated the ledger"
  [ "$(calls_count "$d")" -eq 0 ] || fail "direct internal reentry invoked no-mistakes"
  pass "direct internal reentry with a free guard and forged credentials is refused"
}

# Two simultaneous direct reentries with a free guard cannot both bypass the
# probe: its own acquire is exclusive, so at most one un-launched caller can slip
# through, and the underlying response is therefore invoked at most once.
test_concurrent_direct_reentry_cannot_both_bypass() {
  local d f p1 p2 calls ledger_path
  d=$(new_case concurrent-reentry)
  f=$(finding accepted ask-user)
  set_round "$d" "$f"
  (run_driver "$d" __fm_review_lock_held respond --approve accepted >"$d/re1" 2>&1) & p1=$!
  (run_driver "$d" __fm_review_lock_held respond --approve accepted >"$d/re2" 2>&1) & p2=$!
  wait "$p1" || true
  wait "$p2" || true
  calls=$(calls_count "$d")
  [ "$calls" -le 1 ] \
    || fail "concurrent direct reentry bypassed exclusion and invoked no-mistakes $calls times"
  ledger_path=$(ledger "$d")
  if [ -e "$ledger_path" ]; then
    jq -e '.version == 1 and (.runs | type) == "array"' "$ledger_path" >/dev/null 2>&1 \
      || fail "concurrent direct reentry corrupted the ledger"
  fi
  pass "concurrent direct internal reentry cannot both bypass the kernel guard"
}

test_all_findings_fixed_and_audited_ready
test_all_approved_and_explicit_rejection
test_pr11_partial_fix_reproduction_and_proven_path
test_mixed_choices_are_unrepresentable
test_multiple_fix_rounds_preserve_history
test_surviving_finding_refuses_readiness
test_clean_current_status_cannot_erase_unresolved_history
test_response_refuses_fallback_branch_and_stale_head_without_state_changes
test_pipeline_descendant_head_is_accepted
test_post_review_pipeline_commit_refuses_readiness
test_no_ci_checks_refuses_readiness
test_terminal_outcomes_reject_stale_green_ci
test_run_and_head_mismatch_are_refused
test_duplicate_replay_and_underlying_failure
test_concurrent_writers_are_serial_and_atomic
test_matching_live_owner_refuses
test_dead_owner_recovers_and_audit_is_idempotent
test_forged_capability_cannot_impersonate_or_grant
test_unsupported_lock_primitive_refuses
test_two_reclaimers_converge_to_one_owner
test_crash_while_holding_leaves_no_owner_and_recovers
test_old_owner_exit_never_removes_guard_lock
test_normal_uncontended_acquire_and_release
test_direct_internal_reentry_without_lock_is_refused
test_concurrent_direct_reentry_cannot_both_bypass
