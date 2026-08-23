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
agent=$(cat "$state/agent" 2>/dev/null || echo pi)

# Rebuild the fake no-mistakes state store from the fixture's review rounds. This
# mirrors what no-mistakes records internally for a prose-log agent (e.g. claude),
# whose review log carries no per-round JSON object: one step_results row for the
# review step plus one step_rounds row per round, round 1 "initial" and every later
# round a fix-triggered "auto_fix". The guard reads this store READ-ONLY.
build_review_db() {
  local status=${1:-completed} db="$state/state.sqlite" n i obj trig esc
  rm -f "$db" "$db-wal" "$db-shm"
  sqlite3 "$db" 'CREATE TABLE step_results(id TEXT PRIMARY KEY, run_id TEXT, step_name TEXT, status TEXT); CREATE TABLE step_rounds(id TEXT, step_result_id TEXT, round INTEGER, trigger_type TEXT, findings_json TEXT);'
  sqlite3 "$db" "INSERT INTO step_results VALUES('srid-review','RUN-11','review','$status');"
  n=$(jq 'length' "$state/rounds")
  i=0
  while [ "$i" -lt "$n" ]; do
    obj=$(jq -c ".[$i]" "$state/rounds")
    esc=$(printf '%s' "$obj" | sed "s/'/''/g")
    if [ "$i" -eq 0 ]; then trig=initial; else trig=auto_fix; fi
    sqlite3 "$db" "INSERT INTO step_rounds(id,step_result_id,round,trigger_type,findings_json) VALUES('rd-$i','srid-review',$((i + 1)),'$trig','$esc');"
    i=$((i + 1))
  done
}

if [ "$cmd" = __build_db ]; then build_review_db "${1:-completed}"; exit 0; fi

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
  if [ "$agent" = claude ]; then
    # A prose-log agent narrates the review and echoes NO per-round JSON object.
    cat <<'PROSE'
step: review
run: "RUN-11"
lines: 4 total
log[4]{line}:
  reviewing changes...
  claude started pid=4242
  "I reviewed the diff in prose. The review is complete; no structured findings object is emitted to this log."
  claude exited pid=4242 status=success
PROSE
    return
  fi
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
    # respond-nogate models a daemon that never leaves the review gate (the IPC did
    # not land), so skip every gate-advancing state change. Absent, the fast IPC
    # lands and the gate advances exactly as before.
    if [ ! -f "$state/respond-nogate" ]; then
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
      # A prose-log agent's structured result lives in the state store, so keep it in
      # sync with the (possibly fix-extended) rounds; the review has advanced past its
      # gate, so the review step is now completed.
      if [ "$agent" = claude ]; then build_review_db completed; fi
    fi
    # respond-sleep models no-mistakes' foreground CI-monitoring drive: the fast IPC
    # has already landed (gate advanced above), and the client now blocks with no
    # client-side timeout until killed. exec so the killed client leaves no orphaned
    # sleep. Absent, the client returns immediately.
    if [ -f "$state/respond-sleep" ]; then exec sleep "$(cat "$state/respond-sleep")"; fi
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
  # Bind FM_NM_STATE_DB to the fixture's own store so no case can ever read the
  # host's real ~/.no-mistakes/state.sqlite. Structured-log (pi) cases never read
  # it; prose-log (claude) cases build it explicitly.
  (cd "$dir" && FM_FAKE_NM_STATE="$dir/fake-state" FM_NM_STATE_DB="$dir/fake-state/state.sqlite" \
    PATH="$dir/fakebin:$PATH" "$DRIVER" "$@")
}

# Turn a fixture into a prose-log (claude) case: the review log carries no
# structured findings object, so the guard must source the round model from the
# state store. The caller sets the rounds, then calls build_review_db.
claude_case() {
  local name=$1 d
  d=$(new_case "$name")
  printf 'claude\n' > "$d/fake-state/agent"
  printf '%s\n' "$d"
}

build_review_db() {  # <dir> <review-status>
  local d=$1 status=${2:-completed}
  (cd "$d" && FM_FAKE_NM_STATE="$d/fake-state" PATH="$d/fakebin:$PATH" \
    no-mistakes __build_db "$status")
}

set_clean_round() {  # <dir>: a completed review with zero findings
  local d=$1
  printf '%s\n' '{"findings":[],"tested":[],"testing_summary":"clean","risk_level":"low","risk_rationale":"clean","risk_scope":"source"}' \
    | jq -s . > "$d/fake-state/rounds"
  printf '[]\n' > "$d/fake-state/markers"
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

inflight_marker() {
  printf '%s/.no-mistakes/.firstmate-review-inflight.%s.%s.%s\n' \
    "$1" "${2:-RUN-11}" "${3:-1}" "${4:-1}"
}

receipt_file() {
  printf '%s/.no-mistakes/.firstmate-review-receipt.%s.%s.json\n' \
    "$1" "${2:-RUN-11}" "${3:-1}"
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

test_idempotent_replay_does_not_reinvoke() {
  local d out f before after rc
  d=$(new_case replay)
  f=$(finding replay ask-user)
  set_round "$d" "$f"
  run_driver "$d" respond --approve replay >/dev/null 2>&1 || fail "initial replay fixture response failed"
  before=$(shasum -a 256 "$(ledger "$d")" | awk '{print $1}')
  out=$(run_driver "$d" respond --approve replay 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "an idempotent replay of a landed response was refused: $out"
  assert_contains "$out" 'action=approve findings=replay' "replay did not re-report the recorded disposition"
  [ "$(calls_count "$d")" -eq 1 ] || fail "an idempotent replay invoked the CLI a second time"
  after=$(shasum -a 256 "$(ledger "$d")" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "an idempotent replay changed the ledger"
  pass "replaying a landed response is idempotent and never re-invokes the CLI"
}

# The tripwire finding failed-response-remains-permanently-requested: a nonzero
# axi respond used to strand the finding as "requested" with no way to retry. The
# redesign records the attempt as failed, leaves no disposition, refuses readiness,
# and lets a later invocation retry to completion.
test_transient_failure_is_recoverable() {
  local d out f rc
  d=$(new_case underlying-failure)
  f=$(finding failure auto-fix)
  set_round "$d" "$f"
  set_next "$d"
  : > "$d/fake-state/respond-fail"
  out=$(run_driver "$d" respond --fix failure 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "underlying CLI failure was hidden"
  assert_contains "$out" 'exit 23' "underlying failure exit was not surfaced"
  assert_contains "$out" 'safely retried' "failed response did not advertise a recovery path"
  [ "$(jq '.runs[0].rounds[0].dispositions | length' "$(ledger "$d")")" -eq 0 ] \
    || fail "a failed response left a disposition that could be mistaken for a decision"
  [ "$(jq -r '.phase' "$(receipt_file "$d")")" = failed ] \
    || fail "a failed response did not record a durable failed receipt"
  out=$(run_driver "$d" audit-ready 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "readiness accepted a run with an unresolved failed response"
  assert_contains "$out" 'failed response attempt' "failed-response readiness lacked its diagnostic"

  rm -f "$d/fake-state/respond-fail"
  out=$(run_driver "$d" respond --fix failure 2>&1) \
    || fail "a transient failure could not be retried: $out"
  [ "$(calls_count "$d")" -eq 2 ] || fail "the retry did not invoke the CLI exactly once more"
  [ "$(jq -r '.runs[0].rounds[0].dispositions[0].state' "$(ledger "$d")")" = fixed_and_confirmed ] \
    || fail "the retried fix was not confirmed"
  run_driver "$d" audit-ready >/dev/null 2>&1 || fail "the recovered run did not audit ready"
  pass "a transiently failed response records failed and is safely retryable"
}

# The ledger lock must be held only for the fast respond IPC-landing window, never
# across no-mistakes' long foreground push/PR/CI drive. A fix whose drive blocks
# after the gate leaves returns promptly (the client is stopped once the IPC has
# landed), records the fix request durably, and is confirmed later by audit-ready.
test_fix_drive_landed_releases_lock_and_defers_confirmation() {
  local d f start elapsed out
  d=$(new_case drive-landed-fix)
  f=$(finding scope auto-fix)
  set_round "$d" "$f"
  set_next "$d"
  printf '8\n' > "$d/fake-state/respond-sleep"
  start=$(date +%s)
  out=$(run_driver "$d" respond --fix scope 2>&1) || fail "landed fix response failed: $out"
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 8 ] \
    || fail "respond held the caller ${elapsed}s across the CI drive instead of releasing after the IPC landed"
  assert_contains "$out" 'action=fix findings=scope' "landed fix did not report its recorded response"
  [ "$(jq -r '.phase' "$(receipt_file "$d")")" = landed ] \
    || fail "landed fix did not record a landed receipt"
  [ "$(jq -r '.runs[0].rounds[0].dispositions[0].state' "$(ledger "$d")")" = requested ] \
    || fail "landed fix confirmation was not deferred to audit-ready"
  out=$(run_driver "$d" audit-ready 2>&1) || fail "deferred fix did not reach readiness via audit-ready: $out"
  assert_contains "$out" 'ready: https://github.com/example/repo/pull/11' "deferred fix audit did not confirm readiness"
  [ "$(jq -r '.runs[0].rounds[0].dispositions[0].state' "$(ledger "$d")")" = fixed_and_confirmed ] \
    || fail "audit-ready did not confirm the deferred fix from the next review round"
  pass "a fix whose drive blocks releases the lock after the IPC lands and is confirmed by audit-ready"
}

# A decision needs no CI, so once its gate is consumed it finalizes immediately even
# while the client is still driving CI in the background. The gate-left state is
# specific proof this exact action landed (a rejected IPC would have returned fast).
test_decision_drive_landed_finalizes_immediately() {
  local d f start elapsed out
  d=$(new_case drive-landed-approve)
  f=$(finding decided ask-user)
  set_round "$d" "$f"
  printf '8\n' > "$d/fake-state/respond-sleep"
  start=$(date +%s)
  out=$(run_driver "$d" respond --approve decided 2>&1) || fail "landed approve response failed: $out"
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 8 ] || fail "approve held the caller ${elapsed}s across the CI drive"
  assert_contains "$out" 'action=approve findings=decided' "landed approve did not report its recorded response"
  [ "$(jq -r '.phase' "$(receipt_file "$d")")" = landed ] || fail "landed approve did not record a landed receipt"
  [ "$(jq -r '.runs[0].rounds[0].dispositions[0].state' "$(ledger "$d")")" = approved_as_is ] \
    || fail "a landed approve was not finalized immediately once its gate was consumed"
  out=$(run_driver "$d" audit-ready 2>&1) || fail "landed approve did not reach readiness: $out"
  assert_contains "$out" 'ready:' "landed approve audit did not confirm readiness"
  pass "a decision lands and finalizes the moment its gate is consumed, without awaiting CI"
}

# When the gate never leaves within the bounded budget the IPC landing is
# unconfirmed, so the guard refuses closed, leaves a reconcilable attempting receipt
# and its attempt marker, records no unproven disposition, and does not blindly
# retry an attempt that may still be in flight.
test_gate_never_leaves_times_out_fail_closed_and_stays_reconcilable() {
  local d f out rc
  d=$(new_case drive-timeout)
  f=$(finding stuck auto-fix)
  set_round "$d" "$f"
  set_next "$d"
  printf '1\n' > "$d/fake-state/respond-nogate"
  printf '10\n' > "$d/fake-state/respond-sleep"
  out=$(FM_NM_REVIEW_IPC_BUDGET=2 run_driver "$d" respond --fix stuck 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a response whose gate never left was accepted as landed"
  assert_contains "$out" 'review gate did not leave' "gate-stuck timeout refusal was not actionable"
  [ "$(jq -r '.phase' "$(receipt_file "$d")")" = attempting ] \
    || fail "a timed-out response did not leave a reconcilable attempting receipt"
  [ -e "$(inflight_marker "$d")" ] || fail "a timed-out response did not preserve its attempt marker"
  [ "$(jq '.runs[0].rounds[0].dispositions | length' "$(ledger "$d")")" -eq 0 ] \
    || fail "a timed-out response recorded an unproven disposition"
  out=$(FM_NM_REVIEW_IPC_BUDGET=2 run_driver "$d" respond --fix stuck 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an unconfirmed in-flight response was blindly retried"
  assert_contains "$out" 'in flight' "in-flight retry refusal was not fail-closed"
  pass "a response whose gate never leaves times out fail-closed and stays reconcilable"
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

# The guard-lock probe must refuse closed on an operational failure rather than
# mistake it for an active lock. A direct caller who plants an unopenable guard
# must not be granted entry.
test_probe_operational_error_refuses_closed() {
  local d out rc f guard
  d=$(new_case probe-error)
  f=$(finding accepted ask-user)
  set_round "$d" "$f"
  guard=$(guard_file "$d")
  mkdir -p "$d/.no-mistakes"
  : > "$guard"
  chmod 000 "$guard"
  out=$(run_driver "$d" __fm_review_lock_held respond --approve accepted 2>&1); rc=$?
  chmod 600 "$guard" 2>/dev/null || true
  [ "$rc" -ne 0 ] || fail "an unopenable guard was accepted as an active lock"
  assert_contains "$out" 'probe failed' "probe operational-error refusal was not actionable"
  [ ! -e "$(ledger "$d")" ] || fail "probe operational error still mutated the ledger"
  [ "$(calls_count "$d")" -eq 0 ] || fail "probe operational error still invoked no-mistakes"
  pass "a non-contention guard-lock probe error refuses closed instead of granting entry"
}

# The real invariant - the underlying no-mistakes response runs at most once per
# run and round - is enforced by an atomic in-flight marker. An already-claimed
# marker makes a duplicate response impossible, whatever process attempts it.
test_inflight_marker_blocks_duplicate_response() {
  local d out rc f marker
  d=$(new_case inflight-marker)
  f=$(finding accepted ask-user)
  set_round "$d" "$f"
  marker=$(inflight_marker "$d")
  mkdir -p "$d/.no-mistakes"
  : > "$marker"
  out=$(run_driver "$d" respond --approve accepted 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a response proceeded despite an already-claimed in-flight marker"
  assert_contains "$out" 'already in flight' "duplicate-response refusal was not actionable"
  [ "$(calls_count "$d")" -eq 0 ] || fail "a duplicate response invoked no-mistakes despite the in-flight marker"
  pass "an existing in-flight marker makes a duplicate no-mistakes response impossible"
}

# The finding-1 scenario: a direct reentry that piggybacks on an active guarded
# response (its probe sees contention and passes) still cannot duplicate the
# side effect, because the legitimate responder already claimed the in-flight
# marker for the run and round.
test_inflight_marker_prevents_duplicate_under_contention() {
  local d f release marker p out rc spins=0
  d=$(new_case inflight-contention)
  f=$(finding accepted auto-fix)
  set_round "$d" "$f"
  set_next "$d"
  release="$d/inflight-release"
  marker=$(inflight_marker "$d")
  mkfifo "$release"
  (FM_NM_REVIEW_TEST_INFLIGHT_FIFO="$release" run_driver "$d" respond --fix accepted >"$d/legit-out" 2>&1) & p=$!
  while [ ! -e "$marker" ]; do
    kill -0 "$p" 2>/dev/null || fail "the legitimate responder exited before claiming the in-flight marker"
    spins=$((spins + 1)); [ "$spins" -lt 1000000 ] || fail "the legitimate responder never claimed the in-flight marker"
  done
  out=$(run_driver "$d" __fm_review_lock_held respond --fix accepted 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a piggyback reentry duplicated the response under guard contention"
  assert_contains "$out" 'may still be in flight' "piggyback refusal was not the in-flight guard"
  printf 'release\n' > "$release"
  wait "$p" || fail "the legitimate guarded responder did not finish"
  [ "$(calls_count "$d")" -eq 1 ] \
    || fail "the underlying response ran $(calls_count "$d") times, not exactly once"
  pass "the atomic in-flight marker prevents a duplicate response even under guard contention"
}

# The second side-effect the piggyback could corrupt is the ledger itself: a copy
# computed from an old ledger must not overwrite a concurrent append. Optimistic-
# concurrency commits detect the changed ledger and recompute from it instead.
test_stale_ledger_commit_cannot_clobber_concurrent_append() {
  local d f release reached p spins=0 ledger_path other
  d=$(new_case ledger-cas)
  f=$(finding accepted ask-user)
  set_round "$d" "$f"
  ledger_path=$(ledger "$d")
  release="$d/commit-release"
  reached="$release.reached"
  mkfifo "$release"
  (FM_NM_REVIEW_TEST_LEDGER_COMMIT_FIFO="$release" run_driver "$d" respond --approve accepted >"$d/cas-out" 2>&1) & p=$!
  while [ ! -e "$reached" ]; do
    kill -0 "$p" 2>/dev/null || fail "the responder exited before reaching its ledger commit"
    spins=$((spins + 1)); [ "$spins" -lt 1000000 ] || fail "the responder never reached its ledger commit"
  done
  # While the responder is paused before its commit, append an unrelated run that
  # the responder's stale copy must not erase.
  other='{"id":"OTHER-RUN","branch":"fm/other","rounds":[]}'
  jq --argjson other "$other" '.runs += [$other]' "$ledger_path" > "$ledger_path.inject"
  mv "$ledger_path.inject" "$ledger_path"
  printf 'release\n' > "$release"
  wait "$p" || fail "the paused responder did not complete after release"
  [ "$(jq '[.runs[] | select(.id == "OTHER-RUN")] | length' "$ledger_path")" -eq 1 ] \
    || fail "the stale ledger copy clobbered the concurrent append"
  [ "$(jq -r '.runs[] | select(.id == "RUN-11") | .rounds[0].dispositions[0].state' "$ledger_path")" = approved_as_is ] \
    || fail "the responder did not record its own disposition after recomputing from the current ledger"
  pass "an optimistic-concurrency commit recomputes instead of clobbering a concurrent ledger append"
}

# The worktree-isolation gap: the pipeline validates in a per-run bare repo, so the
# authoritative head can be a fix commit this worktree never fetched. The guard must
# resolve it by importing objects READ-ONLY from that store, with no manual fetch.
test_isolated_pipeline_head_is_imported() {
  local d f store bare tree h0 h1 h2 out rc
  d=$(new_case iso)
  f=$(finding iso ask-user)
  set_round "$d" "$f"
  store="$d/nm-repos"
  bare="$store/2f00d15ea5ed.git"
  mkdir -p "$store"
  git clone --bare -q "$d" "$bare"
  git -C "$bare" config user.name fixture
  git -C "$bare" config user.email fixture@example.test
  tree=$(git -C "$d" rev-parse 'HEAD^{tree}')
  h0=$(git -C "$d" rev-parse HEAD)
  # The authoritative head h1 is a fix commit, and CI then advanced the branch tip
  # past it to h2 -- so h1 is a non-tip ancestor that only an exact-object import
  # (not a branch-tip fetch) can bind. Neither exists in the worktree.
  h1=$(git -C "$bare" commit-tree "$tree" -p "$h0" -m 'isolated pipeline fix')
  h2=$(git -C "$bare" commit-tree "$tree" -p "$h1" -m 'later CI fix')
  git -C "$bare" update-ref "refs/heads/fm/iso" "$h2"
  printf '%s\n' "$h1" > "$d/fake-state/status-head"

  # The isolated head is genuinely absent from the worktree before the guard runs.
  git -C "$d" rev-parse --verify --quiet "${h1}^{commit}" >/dev/null 2>&1 \
    && fail "the isolated pipeline head was unexpectedly already present in the worktree"

  out=$(cd "$d" && FM_FAKE_NM_STATE="$d/fake-state" FM_NM_REPOS_DIR="$store" \
    PATH="$d/fakebin:$PATH" "$DRIVER" respond --approve iso 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "the isolated pipeline head was not resolved for the response: $out"
  git -C "$d" rev-parse --verify --quiet "${h1}^{commit}" >/dev/null 2>&1 \
    || fail "the guard did not import the isolated pipeline head into the worktree"
  [ "$(jq -r '.runs[0].rounds[0].dispositions[0].head' "$(ledger "$d")")" = "$h1" ] \
    || fail "the disposition was not bound to the authoritative isolated head"
  out=$(cd "$d" && FM_FAKE_NM_STATE="$d/fake-state" FM_NM_REPOS_DIR="$store" \
    PATH="$d/fakebin:$PATH" "$DRIVER" audit-ready 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "readiness could not resolve the isolated pipeline head: $out"
  assert_contains "$out" "head=$h1" "readiness did not report the authoritative isolated head"
  pass "an isolated pipeline head is imported read-only and resolves across worktree isolation"
}

test_isolated_head_absent_everywhere_refuses() {
  local d f store out rc missing
  d=$(new_case iso-missing)
  f=$(finding gone ask-user)
  set_round "$d" "$f"
  store="$d/nm-repos-empty"
  mkdir -p "$store"
  # A head that exists in neither the worktree nor any per-run store.
  missing=0000000000000000000000000000000000000001
  printf '%s\n' "$missing" > "$d/fake-state/status-head"
  out=$(cd "$d" && FM_FAKE_NM_STATE="$d/fake-state" FM_NM_REPOS_DIR="$store" \
    PATH="$d/fakebin:$PATH" "$DRIVER" respond --approve gone 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an unresolvable head was accepted"
  assert_contains "$out" 'cannot resolve public validation head' "unresolvable-head refusal was not actionable"
  [ ! -e "$(ledger "$d")" ] || fail "an unresolvable head still mutated the ledger"
  [ "$(calls_count "$d")" -eq 0 ] || fail "an unresolvable head still invoked no-mistakes"
  pass "a head absent from the worktree and every per-run store refuses closed"
}

# Base-advance during a run buries the authoritative head below the run branch tip:
# the pipeline validated at h1 (a fix commit) and CI then advanced the branch two
# further commits, so h1 is a non-tip ancestor present only in the per-run store.
# Both respond and audit-ready must import and resolve it, and bind the disposition
# to the authoritative buried head, not to any tip.
test_isolated_head_resolves_under_deep_base_advance() {
  local d f store bare tree h0 h1 h2 h3 out rc
  d=$(new_case iso-deep)
  f=$(finding deep ask-user)
  set_round "$d" "$f"
  store="$d/nm-repos"
  bare="$store/deadbeefcafe.git"
  mkdir -p "$store"
  git clone --bare -q "$d" "$bare"
  git -C "$bare" config user.name fixture
  git -C "$bare" config user.email fixture@example.test
  tree=$(git -C "$d" rev-parse 'HEAD^{tree}')
  h0=$(git -C "$d" rev-parse HEAD)
  h1=$(git -C "$bare" commit-tree "$tree" -p "$h0" -m 'isolated fix')
  h2=$(git -C "$bare" commit-tree "$tree" -p "$h1" -m 'later CI fix')
  h3=$(git -C "$bare" commit-tree "$tree" -p "$h2" -m 'even later CI fix')
  git -C "$bare" update-ref "refs/heads/fm/iso-deep" "$h3"
  printf '%s\n' "$h1" > "$d/fake-state/status-head"
  git -C "$d" rev-parse --verify --quiet "${h1}^{commit}" >/dev/null 2>&1 \
    && fail "the buried isolated head was unexpectedly already present in the worktree"

  out=$(cd "$d" && FM_FAKE_NM_STATE="$d/fake-state" FM_NM_REPOS_DIR="$store" \
    PATH="$d/fakebin:$PATH" "$DRIVER" respond --approve deep 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "a head buried under a deep base advance was not resolved for the response: $out"
  [ "$(jq -r '.runs[0].rounds[0].dispositions[0].head' "$(ledger "$d")")" = "$h1" ] \
    || fail "the disposition was not bound to the authoritative buried head"
  out=$(cd "$d" && FM_FAKE_NM_STATE="$d/fake-state" FM_NM_REPOS_DIR="$store" \
    PATH="$d/fakebin:$PATH" "$DRIVER" audit-ready 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "audit-ready could not resolve the buried isolated head: $out"
  assert_contains "$out" "head=$h1" "readiness did not report the authoritative buried head"
  pass "a validation head buried under a deep base advance resolves from the per-run store"
}

# A crash after the attempting receipt but before the CLI leaves no attempt marker,
# proving the response never ran; the next invocation retries it to completion.
test_crash_before_respond_is_retryable() {
  local d f out rc
  d=$(new_case crash-before)
  f=$(finding cb auto-fix)
  set_round "$d" "$f"
  set_next "$d"
  FM_NM_REVIEW_TEST_CRASH_BEFORE_RESPOND=1 run_driver "$d" respond --fix cb >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "the crash-before-respond fixture unexpectedly completed"
  [ "$(jq -r '.phase' "$(receipt_file "$d")")" = attempting ] \
    && [ "$(calls_count "$d")" -eq 0 ] \
    || fail "the crash-before-respond fixture did not leave an untried attempting receipt"
  [ ! -e "$(inflight_marker "$d")" ] \
    || fail "an attempt that never ran the CLI still left an attempt marker"
  out=$(run_driver "$d" respond --fix cb 2>&1) \
    || fail "an unstarted attempt could not be retried: $out"
  [ "$(calls_count "$d")" -eq 1 ] || fail "the retry did not run the CLI exactly once"
  [ "$(jq -r '.runs[0].rounds[0].dispositions[0].state' "$(ledger "$d")")" = fixed_and_confirmed ] \
    || fail "the retried response was not confirmed"
  run_driver "$d" audit-ready >/dev/null 2>&1 || fail "the recovered run did not audit ready"
  pass "a crash before the CLI leaves no marker and is retried to completion"
}

# A crashed fix has action-specific evidence: its committed-fix marker and the
# next authoritative result. Readiness reconciles the now-prior receipt without a
# duplicate invocation.
test_crash_after_fix_reconciles_across_rounds() {
  local d f rc
  d=$(new_case crash-after-fix)
  f=$(finding ca auto-fix)
  set_round "$d" "$f"
  set_next "$d"
  FM_NM_REVIEW_TEST_CRASH_AFTER_RESPOND=1 run_driver "$d" respond --fix ca >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "the crash-after-fix fixture unexpectedly completed"
  [ "$(jq -r '.phase' "$(receipt_file "$d")")" = attempting ] \
    || fail "the crash-after-fix fixture did not leave an attempting receipt"
  [ "$(jq 'length' "$d/fake-state/rounds")" -eq 2 ] \
    || fail "the landed fix did not advance public history"
  [ "$(calls_count "$d")" -eq 1 ] || fail "the crashed fix did not land exactly once"
  run_driver "$d" audit-ready >/dev/null 2>&1 \
    || fail "readiness did not reconcile the prior-round landed fix"
  [ "$(calls_count "$d")" -eq 1 ] || fail "readiness duplicated the landed fix"
  [ "$(jq -r '.runs[0].rounds[0].dispositions[0].state' "$(ledger "$d")")" = fixed_and_confirmed ] \
    || fail "the prior-round fix was not finalized from its action-specific evidence"
  pass "a crashed fix is reconciled across rounds without duplication"
}

# Responding to the next round also reconciles an outstanding prior fix first.
test_new_response_reconciles_prior_fix() {
  local d first second rc
  d=$(new_case prior-fix)
  first=$(finding old auto-fix)
  second=$(finding new ask-user)
  set_round "$d" "$first"
  set_next "$d" "$second"
  FM_NM_REVIEW_TEST_CRASH_AFTER_RESPOND=1 run_driver "$d" respond --fix old >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "the prior-fix fixture unexpectedly completed"
  run_driver "$d" respond --approve new >/dev/null 2>&1 \
    || fail "a new response could not reconcile the outstanding prior fix"
  [ "$(calls_count "$d")" -eq 2 ] || fail "prior reconciliation duplicated or omitted a response"
  [ "$(jq -r '.runs[0].rounds[0].dispositions[0].state' "$(ledger "$d")")" = fixed_and_confirmed ] \
    && [ "$(jq -r '.runs[0].rounds[1].dispositions[0].state' "$(ledger "$d")")" = approved_as_is ] \
    || fail "cross-round response reconciliation did not finalize both rounds"
  run_driver "$d" audit-ready >/dev/null 2>&1 || fail "the cross-round response did not audit ready"
  pass "a new response reconciles an outstanding prior-round fix"
}

# Generic completion cannot identify whether our crashed approve/reject landed.
test_attempting_decision_not_finalized_from_generic_completion() {
  local kind action d f out rc
  for kind in approve reject; do
    d=$(new_case "attempting-$kind")
    f=$(finding generic ask-user)
    set_round "$d" "$f"
    action=--$kind
    FM_NM_REVIEW_TEST_CRASH_AFTER_RESPOND=1 run_driver "$d" respond "$action" generic >/dev/null 2>&1
    rc=$?
    [ "$rc" -ne 0 ] || fail "the crashed $kind fixture unexpectedly completed"
    out=$(run_driver "$d" audit-ready 2>&1); rc=$?
    [ "$rc" -ne 0 ] || fail "generic completion finalized a crashed $kind"
    assert_contains "$out" 'not landed' "crashed-$kind refusal lacked its diagnostic"
    [ "$(jq '.runs[0].rounds[0].dispositions | length' "$(ledger "$d")")" -eq 0 ] \
      || fail "generic completion created a final $kind disposition"
  done
  pass "generic completion never finalizes an attempting approve or reject"
}

# The tripwire finding completed-status-does-not-prove-response-action: a failed
# approve must never be recorded as landed just because the review later completes
# by some other means. The failed receipt keeps readiness fail-closed.
test_failed_action_not_finalized_from_generic_completion() {
  local d f out rc
  d=$(new_case failed-then-complete)
  f=$(finding fc ask-user)
  set_round "$d" "$f"
  : > "$d/fake-state/respond-fail"
  run_driver "$d" respond --approve fc >/dev/null 2>&1 \
    && fail "a failing approve unexpectedly succeeded"
  [ "$(jq -r '.phase' "$(receipt_file "$d")")" = failed ] \
    && [ "$(jq '.runs[0].rounds[0].dispositions | length' "$(ledger "$d")")" -eq 0 ] \
    || fail "a failed approve left a disposition or non-failed receipt"
  # The review completes out-of-band (e.g. a direct skip), so a generic completed
  # status now holds even though OUR approve never landed.
  printf '1\n' > "$d/fake-state/phase"
  out=$(run_driver "$d" audit-ready 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "readiness accepted a failed approve masked by a later completion"
  assert_contains "$out" 'failed response attempt' "failed-approve readiness lacked its diagnostic"
  [ "$(jq '[.runs[0].rounds[0].dispositions[] | select(.state == "approved_as_is")] | length' "$(ledger "$d")")" -eq 0 ] \
    || fail "a failed approve was recorded as approved from a generic completion"
  pass "a failed action is never finalized from a generic later completion"
}

# A prose-log agent (claude) emits no structured findings object to the review log.
# A clean review with zero findings must be recognized as a COMPLETE review result
# (empty finding set) and reach readiness, not refused as "no structured result".
test_claude_clean_zero_findings_is_ready() {
  local d out
  d=$(claude_case claude-clean)
  set_clean_round "$d"
  build_review_db "$d" completed
  printf '1\n' > "$d/fake-state/phase"
  out=$(run_driver "$d" audit-ready 2>&1) \
    || fail "a clean zero-findings claude review was refused readiness: $out"
  assert_contains "$out" 'ready: https://github.com/example/repo/pull/11' \
    "clean claude review did not reach public readiness"
  [ "$(jq '.runs[0].rounds[0].dispositions | length' "$(ledger "$d")")" -eq 0 ] \
    || fail "a zero-findings review invented dispositions"
  pass "a clean zero-findings claude review is a complete result and reaches readiness"
}

# Informational (no-op) findings never gate a review and require no disposition, so
# a claude review whose only findings are informational auto-passes to readiness.
test_claude_info_only_is_ready() {
  local d out note1 note2
  d=$(claude_case claude-info)
  note1=$(finding note-1 no-op 'informational note')
  note2=$(finding note-2 no-op 'another informational note')
  set_round "$d" "$note1" "$note2"
  build_review_db "$d" completed
  printf '1\n' > "$d/fake-state/phase"
  out=$(run_driver "$d" audit-ready 2>&1) \
    || fail "an info-only claude review was refused readiness: $out"
  assert_contains "$out" 'ready:' "info-only claude review did not reach readiness"
  [ "$(jq '.runs[0].rounds[0].result.findings | length' "$(ledger "$d")")" -eq 0 ] \
    || fail "informational no-op findings were treated as disposition-requiring"
  pass "an informational-only claude review requires no disposition and reaches readiness"
}

# A claude review WITH an actionable finding must be parsed from the state store so
# the finding is accounted: a partial response is refused, and an approval that
# accounts for every actionable finding records durably and reaches readiness. The
# co-present informational finding is not part of the disposition-requiring set.
test_claude_with_findings_respond_and_audit() {
  local d out blocking info
  d=$(claude_case claude-findings)
  blocking=$(finding review-1 auto-fix 'actionable installer footgun')
  info=$(finding review-2 no-op 'informational note')
  set_round "$d" "$blocking" "$info"
  build_review_db "$d" awaiting_approval

  # A response that omits the actionable finding is refused before any state change.
  out=$(run_driver "$d" respond --approve review-2 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an approval naming only an informational finding was accepted"
  assert_contains "$out" 'unknown finding: review-2' "no-op finding was wrongly treated as actionable"
  [ ! -e "$(ledger "$d")" ] || fail "a refused claude response changed ledger state"
  [ "$(calls_count "$d")" -eq 0 ] || fail "a refused claude response invoked the underlying response"

  out=$(run_driver "$d" respond --approve review-1 2>&1) \
    || fail "an approval accounting for every actionable claude finding failed: $out"
  assert_contains "$out" 'action=approve findings=review-1' "claude approval did not report its accounted set"
  [ "$(jq -r '.runs[0].rounds[0].dispositions[0].state' "$(ledger "$d")")" = approved_as_is ] \
    || fail "the claude approval was not durably recorded"
  out=$(run_driver "$d" audit-ready 2>&1) || fail "the accounted claude review did not audit ready: $out"
  assert_contains "$out" 'ready:' "the accounted claude review did not reach readiness"
  pass "a claude review with findings is parsed, accounted, and reaches readiness"
}

# A claude fix round is confirmed across rounds from the state store exactly as a
# structured-log fix is confirmed from the review log.
test_claude_fix_round_confirms_across_rounds() {
  local d out finding_obj
  d=$(claude_case claude-fix)
  finding_obj=$(finding review-1 auto-fix 'mechanical fix')
  set_round "$d" "$finding_obj"
  set_next "$d"
  build_review_db "$d" awaiting_approval
  out=$(run_driver "$d" respond --fix review-1 --instructions 'fix it' 2>&1) \
    || fail "a claude fix response failed: $out"
  [ "$(jq '.runs[0].rounds | length' "$(ledger "$d")")" -eq 2 ] \
    || fail "the claude fix round did not extend the run history"
  [ "$(jq -r '.runs[0].rounds[0].dispositions[0].state' "$(ledger "$d")")" = fixed_and_confirmed ] \
    || fail "the claude fix was not confirmed from the next-round state-store result"
  run_driver "$d" audit-ready >/dev/null 2>&1 || fail "the fixed claude review did not audit ready"
  pass "a claude fix round is confirmed across rounds from the state store"
}

# The state-store fallback must still refuse a genuinely incomplete review rather
# than mistake it for a clean pass: an in-progress review record is refused.
test_claude_incomplete_review_refuses() {
  local d out f
  d=$(claude_case claude-incomplete)
  f=$(finding review-1 ask-user 'pending')
  set_round "$d" "$f"
  build_review_db "$d" running
  out=$(run_driver "$d" audit-ready 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an in-progress claude review was accepted as complete"
  assert_contains "$out" 'has not produced a complete result' "in-progress refusal was not actionable"
  assert_not_contains "$out" 'ready:' "an incomplete claude review was reported ready"
  pass "an in-progress claude review record is refused, not mistaken for a clean pass"
}

# A ledger written by a pre-filter guard version preserved rounds WITH informational
# no-op findings (and their dispositions). Such a preserved round must compare equal
# to its no-op-filtered rebuild during sync, not hard-die as a contradiction and
# wedge the run.
test_legacy_noop_preserved_round_does_not_contradict() {
  local d out blocking info L tmp
  d=$(claude_case legacy-noop)
  blocking=$(finding review-1 ask-user 'actionable finding')
  info=$(finding review-2 no-op 'informational note')
  set_round "$d" "$blocking" "$info"
  build_review_db "$d" awaiting_approval
  out=$(run_driver "$d" respond --approve review-1 2>&1) \
    || fail "approval on the legacy-noop fixture failed: $out"
  L=$(ledger "$d")
  tmp="$L.tmp"
  jq --argjson info "$info" '
    .runs[0].rounds[0] |= (
      .result.findings += [$info]
      | .dispositions += [{finding_id: $info.id, finding: $info, kind: "approve",
          state: "approved_as_is", run_id: .dispositions[0].run_id,
          branch: .dispositions[0].branch, head: .head}])
  ' "$L" > "$tmp" \
    || fail "could not rewrite the fixture ledger into its legacy form"
  mv "$tmp" "$L" \
    || fail "could not rewrite the fixture ledger into its legacy form"
  out=$(run_driver "$d" audit-ready 2>&1) \
    || fail "a preserved round carrying a legacy no-op finding was refused: $out"
  assert_contains "$out" 'ready:' "the legacy no-op-bearing run did not reach readiness"
  assert_not_contains "$out" 'contradicts a preserved round' \
    "the legacy no-op-bearing round was reported as a contradiction"
  pass "a preserved round with a legacy no-op finding matches its filtered rebuild"
}

# A prose review log with no readable state store cannot invent a clean pass.
test_claude_missing_state_store_refuses() {
  local d out
  d=$(claude_case claude-no-store)
  set_clean_round "$d"
  # Deliberately do NOT build the state store; the prose log carries no result.
  printf '1\n' > "$d/fake-state/phase"
  out=$(run_driver "$d" audit-ready 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a prose review with no state store was accepted"
  assert_contains "$out" 'no-mistakes review record store is absent' "missing-store refusal was not actionable"
  assert_not_contains "$out" 'ready:' "a resultless claude review was reported ready"
  pass "a prose review log with no readable state store refuses closed"
}

test_all_findings_fixed_and_audited_ready
test_all_approved_and_explicit_rejection
# The prose-log (claude) coverage builds a fixture no-mistakes state store, which
# needs sqlite3. It is present on every supported target (macOS, Linux CI, and any
# host running no-mistakes, itself a sqlite app); note an honest skip otherwise.
if command -v sqlite3 >/dev/null 2>&1; then
  test_claude_clean_zero_findings_is_ready
  test_claude_info_only_is_ready
  test_claude_with_findings_respond_and_audit
  test_claude_fix_round_confirms_across_rounds
  test_claude_incomplete_review_refuses
  test_legacy_noop_preserved_round_does_not_contradict
  test_claude_missing_state_store_refuses
else
  pass "claude prose-log state-store tests skipped: sqlite3 unavailable"
fi
test_isolated_pipeline_head_is_imported
test_isolated_head_absent_everywhere_refuses
test_isolated_head_resolves_under_deep_base_advance
test_crash_before_respond_is_retryable
test_crash_after_fix_reconciles_across_rounds
test_new_response_reconciles_prior_fix
test_attempting_decision_not_finalized_from_generic_completion
test_failed_action_not_finalized_from_generic_completion
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
test_idempotent_replay_does_not_reinvoke
test_transient_failure_is_recoverable
test_fix_drive_landed_releases_lock_and_defers_confirmation
test_decision_drive_landed_finalizes_immediately
test_gate_never_leaves_times_out_fail_closed_and_stays_reconcilable
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
test_probe_operational_error_refuses_closed
test_inflight_marker_blocks_duplicate_response
test_inflight_marker_prevents_duplicate_under_contention
test_stale_ledger_commit_cannot_clobber_concurrent_append
