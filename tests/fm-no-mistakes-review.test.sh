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

# The review step status no-mistakes records: an explicit fixture value, else
# parked at its gate before any response and completed afterwards.
review_status() {
  if [ -f "$state/review-status" ]; then cat "$state/review-status"
  elif [ "$phase" -gt 0 ]; then printf 'completed\n'
  else printf 'awaiting_approval\n'
  fi
}

# Rebuild the fake no-mistakes state store from the fixture files, exactly the
# shape the guard reads READ-ONLY: one review step_results row plus one
# step_rounds row per round (round 1 "initial", later rounds fix-triggered
# "auto_fix") carrying the round's recorded decision. The decisions file holds,
# per round, null (no decision), {"source":"user","ids":[...]} (a fix), or
# {"source":"user_declined"} (approve or skip). A no-store fixture has no store.
# The store is replaced atomically so a concurrent reader never sees a partial one.
rebuild_store() {
  local db="$state/state.sqlite" tmp="$state/state.sqlite.build.$$" decisions
  if [ -f "$state/no-store" ]; then rm -f "$db"; return 0; fi
  decisions=$(cat "$state/decisions" 2>/dev/null || printf '[]')
  rm -f "$tmp"
  jq -r --arg status "$(review_status)" --argjson decisions "$decisions" \
    -f "$(dirname "$0")/store.jq" "$state/rounds" | sqlite3 "$tmp"
  mv "$tmp" "$db"
}

record_decision() {  # <decision-json>: records the decision on the latest round
  local tmp="$state/decisions.tmp.$$" n
  n=$(jq 'length' "$state/rounds")
  jq -n --argjson d "$1" --argjson n "$n" --argjson cur "$(cat "$state/decisions" 2>/dev/null || printf '[]')" \
    '[range(0; $n) as $i | ($cur[$i] // null)] | .[$n - 1] = $d' > "$tmp"
  mv "$tmp" "$state/decisions"
}

# Append the prepared next review round, the result of the fix round that just ran.
append_fix_round() {
  local tmp
  git commit --allow-empty -qm 'fake no-mistakes fix'
  tmp="$state/rounds.tmp.$$"
  jq --slurpfile next "$state/next-result" '. + [$next[0]]' "$state/rounds" > "$tmp"
  mv "$tmp" "$state/rounds"
  tmp="$state/markers.tmp.$$"
  jq '. + [false] | .[-2] = true' "$state/markers" > "$tmp"
  mv "$tmp" "$state/markers"
  if [ "$(jq '[.findings[] | select(.action != "no-op")] | length' "$state/next-result")" -gt 0 ]; then
    printf 'fix_review\n' > "$state/review-status"
  else
    printf 'completed\n' > "$state/review-status"
  fi
}

if [ "$cmd" = __rebuild_store ]; then rebuild_store; exit 0; fi
if [ "$cmd" = __complete_fix ]; then append_fix_round; rebuild_store; exit 0; fi
rebuild_store

append_call() {
  local tmp="$state/calls.tmp.$$"
  jq --arg call "$*" '. + [$call]' "$state/calls" > "$tmp"
  mv "$tmp" "$state/calls"
}

emit_status() {
  local status=running pr='' outcome=''
  if [ "$phase" -gt 0 ]; then
    status=ci
    pr=$(cat "$state/pr")
  fi
  if [ -f "$state/status-head" ]; then head=$(cat "$state/status-head"); fi
  if [ -f "$state/status-branch" ]; then branch=$(cat "$state/status-branch"); fi
  if [ -f "$state/status-outcome" ]; then outcome=$(cat "$state/status-outcome"); fi
  # status-value overrides the run status the CI monitor reports (e.g. "running",
  # the v1.60.2+ TOON format, versus the pre-v1.60.2 "ci").
  if [ -f "$state/status-value" ]; then status=$(cat "$state/status-value"); fi
  # spawn-daemon models a CLI that starts a detached long-lived process (such as
  # the no-mistakes daemon), which inherits every descriptor this process holds.
  if [ -f "$state/spawn-daemon" ]; then
    nohup sleep 30 >/dev/null 2>&1 &
    printf '%s\n' "$!" >> "$state/daemon-pids"
  fi
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
    review,$(review_status),0,0
    pr,$([ "$phase" -gt 0 ] && printf completed || printf pending),0,0
    ci,$([ "$phase" -gt 0 ] && printf running || printf pending),0,0
EOF
  # branch-sync, when present, is the verbatim nested branch_sync object that
  # current-branch axi status prints after the run block.
  if [ -f "$state/branch-sync" ]; then cat "$state/branch-sync"; fi
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
        elif [ -f "$state/ci-declared-no-ci" ]; then
          printf '%s\n' 'repository declares no CI (no_ci: true) - treating as all checks passed - still monitoring until merged or closed'
        else
          printf '%s\n' 'all CI checks passed - still monitoring until merged or closed'
        fi
        ;;
      *) exit 2 ;;
    esac
    ;;
  "axi respond")
    append_call "$*"
    # respond-fail models the underlying client rejecting the request: it prints
    # its own diagnostic (which the driver redirects to its drive log) and exits
    # nonzero before any state change.
    if [ -f "$state/respond-fail" ]; then
      printf 'fake no-mistakes: review response rejected: bad findings selection\n' >&2
      exit 23
    fi
    # respond-hold blocks the client before it delivers its response until the
    # fixture writes a line to that FIFO.
    if [ -p "$state/respond-hold" ]; then IFS= read -r _ < "$state/respond-hold" || true; fi
    action= ids=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --action) action=$2; shift ;;
        --findings) ids=$2; shift ;;
      esac
      shift
    done
    # respond-nogate models a response that never reaches the daemon, so nothing
    # is recorded. Otherwise the daemon accepts exactly one response per open gate.
    if [ ! -f "$state/respond-nogate" ]; then
      case "$(review_status)" in
        awaiting_approval|fix_review) ;;
        *) printf 'fake no-mistakes: daemon rejected the response: no step awaiting approval\n' >&2; exit 1 ;;
      esac
      case "$action" in
        fix)
          record_decision "$(jq -cn --arg ids "$ids" '{source: "user", ids: ($ids | split(","))}')"
          # fix-defer-next leaves the fix round running: the decision is recorded
          # but the re-review result does not exist yet.
          if [ -f "$state/fix-defer-next" ]; then
            printf 'fixing\n' > "$state/review-status"
          else
            append_fix_round
          fi
          ;;
        approve)
          record_decision '{"source":"user_declined"}'
          printf 'completed\n' > "$state/review-status"
          ;;
        skip)
          record_decision '{"source":"user_declined"}'
          printf 'skipped\n' > "$state/review-status"
          ;;
        *) exit 2 ;;
      esac
      printf '1\n' > "$state/phase"
      rebuild_store
    fi
    # respond-sleep models no-mistakes' foreground CI-monitoring drive: the
    # response has already been recorded, and the client now blocks with no
    # client-side timeout until stopped. exec so a stopped client leaves no
    # orphaned sleep. Absent, the client returns immediately.
    if [ -f "$state/respond-sleep" ]; then exec sleep "$(cat "$state/respond-sleep")"; fi
    ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$dir/fakebin/no-mistakes"
  # SQL that rebuilds the fake state store from the fixture rounds and decisions.
  cat > "$dir/fakebin/store.jq" <<'JQ'
def q: if . == null then "NULL" else "'" + (tostring | gsub("'"; "''")) + "'" end;
"CREATE TABLE step_results(id TEXT PRIMARY KEY, run_id TEXT, step_name TEXT, status TEXT);",
"CREATE TABLE step_rounds(id TEXT, step_result_id TEXT, round INTEGER, trigger_type TEXT, findings_json TEXT, selection_source TEXT, selected_finding_ids TEXT);",
"INSERT INTO step_results VALUES('srid-review','RUN-11','review',\($status | q));",
(to_entries[] | .key as $i | .value as $r | ($decisions[$i] // null) as $d
 | "INSERT INTO step_rounds VALUES(\("rd-\($i)" | q),'srid-review',\($i + 1),\((if $i == 0 then "initial" else "auto_fix" end) | q),\($r | tojson | q),\(($d.source // null) | q),\((if $d == null then null elif $d.source == "user" then ($d.ids | tojson) else "[]" end) | q));")
JQ
  # The fake gh answers only the readiness query, from fixture files: gh-rollup
  # (default one green check), gh-state (default OPEN), gh-head (default the
  # reported validation head), and gh-fail for an unreadable PR.
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
state=${FM_FAKE_NM_STATE:?}
[ "${1:-} ${2:-}" = "pr view" ] || exit 2
: > "$state/gh-queried"
if [ -f "$state/gh-fail" ]; then printf 'fake gh: HTTP 502\n' >&2; exit 1; fi
if [ -f "$state/gh-head" ]; then head=$(cat "$state/gh-head")
elif [ -f "$state/status-head" ]; then head=$(git rev-parse "$(cat "$state/status-head")")
else head=$(git rev-parse HEAD)
fi
pr_state=$(cat "$state/gh-state" 2>/dev/null || printf OPEN)
rollup=$(cat "$state/gh-rollup" 2>/dev/null \
  || printf '%s' '[{"__typename":"CheckRun","name":"test","workflowName":"CI","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-01T00:00:00Z"}]')
jq -cn --arg head "$head" --arg state "$pr_state" --argjson rollup "$rollup" \
  '{headRefOid: $head, state: $state, statusCheckRollup: $rollup}'
SH
  chmod +x "$dir/fakebin/gh"
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
  rm -f "$dir/fake-state/decisions"
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
  # host's real ~/.no-mistakes/state.sqlite. The fake rebuilds that store from the
  # fixture files on every invocation, for every review agent.
  (cd "$dir" && FM_FAKE_NM_STATE="$dir/fake-state" FM_NM_STATE_DB="$dir/fake-state/state.sqlite" \
    PATH="$dir/fakebin:$PATH" "$DRIVER" "$@")
}

# Run the fake no-mistakes directly, as a direct (unguarded) caller would.
fake_nm() {  # <dir> <args...>
  local d=$1
  shift
  (cd "$d" && FM_FAKE_NM_STATE="$d/fake-state" PATH="$d/fakebin:$PATH" no-mistakes "$@")
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

build_review_db() {  # <dir> <review-status>: records the review step status and rebuilds the store
  local d=$1 status=${2:-completed}
  printf '%s\n' "$status" > "$d/fake-state/review-status"
  fake_nm "$d" __rebuild_store
}

# Finish a fix round that fix-defer-next left running: commit the fix and
# publish its re-review result.
complete_deferred_fix() {  # <dir>
  rm -f "$1/fake-state/fix-defer-next"
  fake_nm "$1" __complete_fix
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

receipt_client_pid() {  # <dir> [round]
  jq -r '.client.pid // empty' "$(receipt_file "$1" RUN-11 "${2:-1}")"
}

wait_process_gone() {  # <pid>
  local pid=$1 spins=0
  while kill -0 "$pid" 2>/dev/null; do
    spins=$((spins + 1))
    [ "$spins" -lt 600 ] || fail "process $pid did not exit"
    sleep 0.05
  done
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

test_audit_ready_accepts_running_ci_monitor_status() {
  # v1.60.2+ no-mistakes reports the run status as "running" while the CI monitor
  # is active, whereas pre-v1.60.2 reported "ci". audit_ready must accept both, so
  # a green public CI reaches readiness regardless of which format the run emits.
  local d out first second
  d=$(new_case running-status)
  first=$(finding mechanical auto-fix 'mechanical correction')
  second=$(finding decision ask-user 'captain decision')
  set_round "$d" "$first" "$second"
  set_next "$d"
  out=$(run_driver "$d" respond --fix mechanical,decision --instructions 'fix both' 2>&1) \
    || fail "all-findings fix failed: $out"
  printf 'running\n' > "$d/fake-state/status-value"
  out=$(run_driver "$d" audit-ready 2>&1) \
    || fail "audit-ready refused the running CI-monitor status: $out"
  assert_contains "$out" 'ready: https://github.com/example/repo/pull/11' \
    "audited readiness under the running status omitted the PR"
  pass "audit-ready accepts the v1.60.2+ running CI-monitor status, not just ci"
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

# Write the nested branch_sync object current-branch axi status reports while the
# pipeline owns the branch. Arguments override one field each, as key=value.
write_branch_sync() {  # <dir> <submitted> <current> [state=..] [run=..] [clean=..] [local_head=..]
  local d=$1 submitted=$2 current=$3 state=pipeline_owned run=RUN-11 clean=true local_head kv
  local_head=$(git -C "$d" rev-parse HEAD)
  shift 3
  for kv in "$@"; do
    case "$kv" in
      state=*) state=${kv#state=} ;;
      run=*) run=${kv#run=} ;;
      clean=*) clean=${kv#clean=} ;;
      local_head=*) local_head=${kv#local_head=} ;;
    esac
  done
  cat > "$d/fake-state/branch-sync" <<EOF
branch_sync:
  state: $state
  changed: false
  local:
    branch: $(git -C "$d" symbolic-ref --short HEAD)
    head: $local_head
    clean: $clean
  pipeline:
    run: "$run"
    status: running
    phase: pre_push
    submitted_head: $submitted
    current_head: $current
    pushed_head: ""
  relation: diverged
  safety: blocked_pipeline_owned
  next_action:
    code: continue_active_run
    command: no-mistakes axi status
EOF
}

# A pipeline-owned rebase that rewrote history: a new base commit plus the run's
# change replayed on it, so the rebased head does not descend from local HEAD.
rebased_pipeline_head() {  # <dir>
  local d=$1 base tree newbase
  base=$(git -C "$d" rev-parse HEAD^)
  tree=$(git -C "$d" rev-parse 'HEAD^{tree}')
  newbase=$(printf 'upstream advance\n' | git -C "$d" commit-tree "$(git -C "$d" rev-parse "$base^{tree}")" -p "$base")
  printf 'rebased change\n' | git -C "$d" commit-tree "$tree" -p "$newbase"
}

new_rebased_case() {  # <name>; prints "<dir> <local-head> <rebased-head>"
  local d f local_head rebased
  d=$(new_case "$1")
  f=$(finding rebased ask-user)
  set_round "$d" "$f"
  git -C "$d" commit --allow-empty -qm 'run change'
  local_head=$(git -C "$d" rev-parse HEAD)
  rebased=$(rebased_pipeline_head "$d")
  git -C "$d" merge-base --is-ancestor "$local_head" "$rebased" \
    && fail "fixture rebased head unexpectedly descends from local HEAD"
  printf '%s\n' "$rebased" > "$d/fake-state/status-head"
  printf '%s %s %s\n' "$d" "$local_head" "$rebased"
}

test_pipeline_owned_rebased_head_is_accepted() {
  local d local_head rebased out
  read -r d local_head rebased <<<"$(new_rebased_case pipeline-owned-rebase)"
  write_branch_sync "$d" "$local_head" "$rebased"

  out=$(run_driver "$d" respond --approve rebased 2>&1) \
    || fail "pipeline-owned rebased head was refused: $out"
  [ "$(calls_count "$d")" -eq 1 ] || fail "accepted pipeline-owned rebase did not invoke the response"
  [ "$(jq -r '.runs[0].rounds[0].head' "$(ledger "$d")")" = "$rebased" ] \
    || fail "pipeline-owned rebased head was not attached to the disposition"
  out=$(run_driver "$d" audit-ready 2>&1) \
    || fail "pipeline-owned rebased head was refused during audit: $out"
  assert_contains "$out" "head=$rebased" "readiness did not report the pipeline-owned rebased head"
  pass "a pipeline-owned pre-push rebase head is accepted when local HEAD is the submitted head"
}

test_pipeline_owned_rebase_refusals_are_preserved() {
  local d local_head rebased out rc label other
  for label in no-sync not-owned other-run dirty local-advanced current-mismatch reported-local-mismatch; do
    read -r d local_head rebased <<<"$(new_rebased_case "owned-refuse-$label")"
    case "$label" in
      no-sync) ;;
      not-owned) write_branch_sync "$d" "$local_head" "$rebased" state=custody_returned ;;
      other-run) write_branch_sync "$d" "$local_head" "$rebased" run=RUN-OTHER ;;
      dirty) write_branch_sync "$d" "$local_head" "$rebased" clean=false ;;
      local-advanced)
        write_branch_sync "$d" "$local_head" "$rebased"
        git -C "$d" commit --allow-empty -qm 'local work outside the run'
        write_branch_sync "$d" "$local_head" "$rebased"
        ;;
      current-mismatch)
        other=$(printf 'unrelated\n' | git -C "$d" commit-tree "$(git -C "$d" rev-parse 'HEAD^{tree}')")
        write_branch_sync "$d" "$local_head" "$other"
        ;;
      reported-local-mismatch)
        write_branch_sync "$d" "$local_head" "$rebased" local_head="$rebased"
        ;;
    esac
    out=$(run_driver "$d" respond --approve rebased 2>&1); rc=$?
    [ "$rc" -ne 0 ] || fail "$label: an unbound head move was accepted for response"
    assert_contains "$out" 'stale-head mismatch' "$label: refusal was not a stale-head mismatch"
    [ "$(calls_count "$d")" -eq 0 ] || fail "$label: refusal invoked the underlying response"
    [ ! -e "$(ledger "$d")" ] || fail "$label: refusal changed ledger state"
  done
  pass "head moves not bound to this run's pipeline-owned custody still refuse as stale"
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

check_run() {  # <name> <status> <conclusion> [started-at]
  jq -cn --arg name "$1" --arg status "$2" --arg conclusion "$3" --arg started "${4:-2026-01-01T00:00:00Z}" \
    '{__typename: "CheckRun", name: $name, workflowName: "CI", status: $status,
      conclusion: (if $conclusion == "" then null else $conclusion end), startedAt: $started}'
}

set_rollup() {  # <dir> <check-json>...
  local d=$1
  shift
  if [ "$#" -eq 0 ]; then printf '[]\n' > "$d/fake-state/gh-rollup"; return 0; fi
  printf '%s\n' "$@" | jq -s . > "$d/fake-state/gh-rollup"
}

# The checks-passed outcome is no-mistakes' own claim, and it is also reported
# when a trusted no_ci declaration lets zero checks count as passing. Readiness
# therefore requires independent public CI evidence from the PR, bound to the
# authoritative head, and refuses whenever that green-CI fact is absent.
test_checks_passed_requires_public_green_ci() {
  local d out rc label
  for label in zero-checks no_ci-zero-checks unreadable pending queued-rerun-null queued-rerun-zero-time \
      status-pending failing head-mismatch merged truncated unnamed; do
    d=$(new_ready_case "ci-evidence-$label")
    printf 'checks-passed\n' > "$d/fake-state/status-outcome"
    case "$label" in
      zero-checks) set_rollup "$d" ;;
      no_ci-zero-checks) set_rollup "$d"; : > "$d/fake-state/ci-declared-no-ci" ;;
      unreadable) : > "$d/fake-state/gh-fail" ;;
      pending) set_rollup "$d" "$(check_run test COMPLETED SUCCESS)" "$(check_run lint IN_PROGRESS '')" ;;
      queued-rerun-null)
        set_rollup "$d" "$(check_run test COMPLETED SUCCESS)" "$(check_run lint COMPLETED SUCCESS)" \
          "$(check_run lint QUEUED '' | jq -c '.startedAt = null')"
        ;;
      queued-rerun-zero-time)
        set_rollup "$d" "$(check_run test COMPLETED SUCCESS)" "$(check_run lint COMPLETED SUCCESS)" \
          "$(check_run lint QUEUED '' 0001-01-01T00:00:00Z)"
        ;;
      status-pending)
        set_rollup "$d" "$(check_run test COMPLETED SUCCESS)" \
          '{"__typename":"StatusContext","context":"lint","state":"PENDING","createdAt":"2026-01-01T00:00:00Z"}'
        ;;
      failing) set_rollup "$d" "$(check_run test COMPLETED SUCCESS)" "$(check_run lint COMPLETED FAILURE)" ;;
      head-mismatch) printf '%s\n' 0123456789abcdef0123456789abcdef01234567 > "$d/fake-state/gh-head" ;;
      merged) printf 'MERGED\n' > "$d/fake-state/gh-state" ;;
      truncated)
        jq -n '[range(0; 100) | {__typename: "CheckRun", name: "check-\(.)", workflowName: "CI",
          status: "COMPLETED", conclusion: "SUCCESS", startedAt: "2026-01-01T00:00:00Z"}]' \
          > "$d/fake-state/gh-rollup"
        ;;
      unnamed) printf '%s\n' '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]' > "$d/fake-state/gh-rollup" ;;
    esac
    out=$(run_driver "$d" audit-ready 2>&1); rc=$?
    [ "$rc" -ne 0 ] || fail "$label: readiness was granted without verified green public CI"
    assert_contains "$out" 'REFUSED:' "$label: CI-evidence refusal lacked its diagnostic"
    assert_not_contains "$out" 'ready:' "$label: run was visibly reported ready"
    [ -e "$d/fake-state/gh-queried" ] || fail "$label: readiness did not query public CI evidence"
    case "$label" in
      zero-checks|no_ci-zero-checks) assert_contains "$out" 'zero CI checks' "$label: zero-check refusal was not explicit" ;;
      unreadable) assert_contains "$out" 'cannot read public CI evidence' "$label: unreadable-CI refusal was not explicit" ;;
      pending|queued-rerun-*|status-pending|failing) assert_contains "$out" 'public CI is not green: lint' "$label: refusal did not name the non-green check" ;;
      head-mismatch) assert_contains "$out" 'is not the authoritative head' "$label: head-mismatch refusal was not explicit" ;;
      merged) assert_contains "$out" 'MERGED, not open' "$label: closed-PR refusal was not explicit" ;;
      truncated) assert_contains "$out" 'truncated' "$label: truncated-rollup refusal was not explicit" ;;
      unnamed) assert_contains "$out" 'unnamed entry' "$label: malformed-rollup refusal was not explicit" ;;
    esac
  done

  # The latest attempt of a check name decides it, so a rerun that went green
  # supersedes its earlier failure, and neutral or skipped checks do not block.
  d=$(new_ready_case ci-evidence-green)
  printf 'checks-passed\n' > "$d/fake-state/status-outcome"
  set_rollup "$d" "$(check_run test COMPLETED FAILURE 2026-01-01T00:00:00Z)" \
    "$(check_run test COMPLETED SUCCESS 2026-01-01T01:00:00Z)" "$(check_run docs COMPLETED SKIPPED)"
  out=$(run_driver "$d" audit-ready 2>&1) || fail "verified green public CI was refused: $out"
  assert_contains "$out" 'ready: https://github.com/example/repo/pull/11' "green public CI did not reach readiness"

  d=$(new_ready_case ci-evidence-only-skipped)
  printf 'checks-passed\n' > "$d/fake-state/status-outcome"
  set_rollup "$d" "$(check_run docs COMPLETED SKIPPED)"
  out=$(run_driver "$d" audit-ready 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "readiness accepted a rollup with no successful check"
  assert_contains "$out" 'no PR check reports success' "all-skipped refusal was not explicit"
  pass "checks-passed readiness requires verified, non-empty, green public CI at the authoritative head"
}

# The legacy CI-monitor path must not treat the no_ci declaration as green.
test_declared_no_ci_monitor_line_refuses_readiness() {
  local d out rc
  d=$(new_ready_case declared-no-ci)
  : > "$d/fake-state/ci-declared-no-ci"
  out=$(run_driver "$d" audit-ready 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "readiness accepted a run that only declares no CI"
  assert_contains "$out" 'no_ci declaration' "declared-no-CI refusal was not explicit"
  pass "the no_ci declaration never authorizes readiness"
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
    [ ! -e "$d/fake-state/ci-queried" ] && [ ! -e "$d/fake-state/gh-queried" ] \
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
# axi respond used to strand the finding as "requested" with no way to retry. A
# client that fails leaves the round unresolved in no-mistakes' own record, so the
# attempt stays recorded with its client proven stopped, readiness refuses, and a
# later invocation retries it to its final state.
test_transient_failure_is_recoverable() {
  local d out f rc
  d=$(new_case underlying-failure)
  f=$(finding failure auto-fix)
  set_round "$d" "$f"
  set_next "$d"
  : > "$d/fake-state/respond-fail"
  out=$(run_driver "$d" respond --fix failure 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "underlying CLI failure was hidden"
  assert_contains "$out" 'client exit 23' "underlying failure exit was not surfaced"
  assert_contains "$out" 'safely retried' "failed response did not advertise a recovery path"
  assert_contains "$out" 'review response rejected' "failed response swallowed the client's own diagnostic from the drive log"
  [ "$(jq '.runs[0].rounds[0].dispositions | length' "$(ledger "$d")")" -eq 0 ] \
    || fail "a failed response left a disposition that could be mistaken for a decision"
  [ "$(jq -r '.phase' "$(receipt_file "$d")")" = attempting ] \
    && [ -n "$(receipt_client_pid "$d")" ] \
    || fail "a failed response did not leave a durable attempting receipt naming its client"
  out=$(run_driver "$d" audit-ready 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "readiness accepted a run with an unresolved failed response"
  assert_contains "$out" 'has not landed' "failed-response readiness lacked its diagnostic"

  rm -f "$d/fake-state/respond-fail"
  out=$(run_driver "$d" respond --fix failure 2>&1) \
    || fail "a transient failure could not be retried: $out"
  [ "$(calls_count "$d")" -eq 2 ] || fail "the retry did not invoke the CLI exactly once more"
  [ "$(jq -r '.attempt' "$(receipt_file "$d")")" -eq 2 ] || fail "the retry did not record a new attempt"
  [ "$(jq -r '.runs[0].rounds[0].dispositions[0].state' "$(ledger "$d")")" = fixed_and_confirmed ] \
    || fail "the retried fix was not confirmed"
  run_driver "$d" audit-ready >/dev/null 2>&1 || fail "the recovered run did not audit ready"
  pass "a transiently failed response stays recorded, refuses readiness, and is safely retried to its final state"
}

# The ledger lock must be held only until no-mistakes records the response, never
# across its long foreground push/PR/CI drive. A fix whose drive blocks returns
# promptly (the client is stopped once the decision is recorded) with a landed
# receipt and a requested disposition; it is confirmed only once the re-review
# exists, so readiness refuses until then and succeeds after.
test_fix_drive_landed_releases_lock_and_defers_confirmation() {
  local d f start elapsed out rc
  d=$(new_case drive-landed-fix)
  f=$(finding scope auto-fix)
  set_round "$d" "$f"
  set_next "$d"
  : > "$d/fake-state/fix-defer-next"
  printf '8\n' > "$d/fake-state/respond-sleep"
  start=$(date +%s)
  out=$(run_driver "$d" respond --fix scope 2>&1) || fail "landed fix response failed: $out"
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 8 ] \
    || fail "respond held the caller ${elapsed}s across the CI drive instead of releasing once the response was recorded"
  assert_contains "$out" 'action=fix findings=scope' "landed fix did not report its recorded response"
  assert_contains "$out" 'confirmed once no-mistakes re-reviews' "landed fix did not explain its pending confirmation"
  [ "$(jq -r '.phase' "$(receipt_file "$d")")" = landed ] \
    || fail "a fix recorded by no-mistakes did not leave a landed receipt"
  [ "$(jq -r '.runs[0].rounds[0].dispositions[0].state' "$(ledger "$d")")" = requested ] \
    || fail "a landed fix was not recorded as requested pending its re-review"
  out=$(run_driver "$d" audit-ready 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "readiness accepted a fix whose re-review does not exist yet"
  assert_contains "$out" 'merely requested for fix' "unconfirmed fix readiness lacked its diagnostic"
  complete_deferred_fix "$d"
  out=$(run_driver "$d" audit-ready 2>&1) || fail "deferred fix did not reach readiness via audit-ready: $out"
  assert_contains "$out" 'ready: https://github.com/example/repo/pull/11' "deferred fix audit did not confirm readiness"
  [ "$(jq -r '.runs[0].rounds[0].dispositions[0].state' "$(ledger "$d")")" = fixed_and_confirmed ] \
    || fail "audit-ready did not confirm the deferred fix from the next review round"
  [ "$(calls_count "$d")" -eq 1 ] || fail "confirming a deferred fix invoked the response again"
  pass "a fix whose drive blocks releases the lock once recorded and is confirmed by its re-review"
}

# A decision needs no CI, so once no-mistakes records it the guard finalizes it
# immediately, even while the client is still driving CI in the background.
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
  pass "a decision lands and finalizes the moment no-mistakes records it, without awaiting CI"
}

# When no-mistakes never records the response within the bounded budget, the guard
# stops the client and refuses closed with no unproven disposition. Because the
# stopped client is durably identified and proven gone, the attempt is not a
# permanent wedge: the next invocation safely retries it to its final state.
test_gate_never_leaves_times_out_fail_closed_and_stays_reconcilable() {
  local d f out rc pid
  d=$(new_case drive-timeout)
  f=$(finding stuck auto-fix)
  set_round "$d" "$f"
  set_next "$d"
  printf '1\n' > "$d/fake-state/respond-nogate"
  printf '10\n' > "$d/fake-state/respond-sleep"
  out=$(FM_NM_REVIEW_IPC_BUDGET=2 run_driver "$d" respond --fix stuck 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a response that no-mistakes never recorded was accepted as landed"
  assert_contains "$out" 'did not land within 2s' "unrecorded-response timeout refusal was not actionable"
  [ "$(jq -r '.phase' "$(receipt_file "$d")")" = attempting ] \
    || fail "a timed-out response did not leave a reconcilable attempting receipt"
  pid=$(receipt_client_pid "$d")
  [ -n "$pid" ] || fail "a timed-out response did not record its client identity"
  kill -0 "$pid" 2>/dev/null && fail "a timed-out response left its client running"
  [ "$(jq '.runs[0].rounds[0].dispositions | length' "$(ledger "$d")")" -eq 0 ] \
    || fail "a timed-out response recorded an unproven disposition"
  rm -f "$d/fake-state/respond-nogate" "$d/fake-state/respond-sleep"
  out=$(run_driver "$d" respond --fix stuck 2>&1) \
    || fail "a timed-out attempt with a stopped client could not be retried: $out"
  [ "$(calls_count "$d")" -eq 2 ] || fail "the timed-out retry did not invoke the response exactly once more"
  [ "$(jq -r '.runs[0].rounds[0].dispositions[0].state' "$(ledger "$d")")" = fixed_and_confirmed ] \
    || fail "the retried response did not reach its final state"
  pass "an unrecorded response times out closed, stops its client, and stays safely retryable"
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

# The lock is taken in-process on the guard's own descriptor, so there is no
# separately invokable lock-held entry point a caller could enter without it.
test_no_unlocked_internal_entry_point() {
  local d f out rc
  d=$(new_case no-internal-entry)
  f=$(finding accepted ask-user)
  set_round "$d" "$f"
  out=$(run_driver "$d" __fm_review_lock_held respond --approve accepted 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an internal entry point accepted a response without the kernel lock"
  assert_contains "$out" 'unknown command' "the removed internal entry point was not refused as unknown"
  [ "$(calls_count "$d")" -eq 0 ] || fail "an internal entry attempt invoked no-mistakes"
  [ ! -e "$(ledger "$d")" ] || fail "an internal entry attempt changed ledger state"
  pass "no internal entry point can reach the ledger without the kernel lock"
}

# A guard path that cannot hold the kernel lock refuses closed rather than
# proceeding without exclusion.
test_unusable_guard_file_refuses_closed() {
  local d f out rc
  d=$(new_case guard-not-file)
  f=$(finding accepted ask-user)
  set_round "$d" "$f"
  mkdir -p "$(guard_file "$d")"
  out=$(run_driver "$d" respond --approve accepted 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a response proceeded with an unusable kernel guard"
  assert_contains "$out" 'not a regular private file' "unusable-guard refusal was not actionable"
  [ "$(calls_count "$d")" -eq 0 ] || fail "an unusable guard still invoked no-mistakes"
  [ ! -e "$(ledger "$d")" ] || fail "an unusable guard still mutated the ledger"
  pass "an unusable kernel guard refuses closed without mutation"
}

# no-mistakes may start its daemon (and git may detach maintenance) from inside a
# guarded invocation. Such a detached process inherits whatever descriptors the
# command had, so it must never receive the lock descriptor: otherwise it would
# keep the ledger locked long after the guard exited.
test_lock_never_outlives_the_guard_through_detached_processes() {
  local d out pid rc
  d=$(new_ready_case detached-daemon)
  : > "$d/fake-state/spawn-daemon"
  out=$(run_driver "$d" audit-ready 2>&1) || fail "audit with a detached daemon start failed: $out"
  [ -s "$d/fake-state/daemon-pids" ] || fail "the fixture did not start a detached process"
  pid=$(tail -n 1 "$d/fake-state/daemon-pids")
  kill -0 "$pid" 2>/dev/null || fail "the detached fixture process is not running"
  rm -f "$d/fake-state/spawn-daemon"
  out=$(run_driver "$d" audit-ready 2>&1); rc=$?
  while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$d/fake-state/daemon-pids"
  [ "$rc" -eq 0 ] || fail "a detached process started under the guard kept the ledger locked: $out"
  assert_not_contains "$out" 'live owner' "a detached process inherited the review lock"
  pass "a detached process started under the guard never inherits the review lock"
}

# The guard is killed once its client is authorized, so the client keeps running
# with its response still undelivered. The client never holds the lock, so the
# next invocation enters, but it refuses to re-send while that recorded client
# lives. Once the client delivers and exits, the response finalizes from the
# authoritative record without a second invocation.
test_orphaned_client_blocks_only_its_retry_until_proven_stopped() {
  local d f out rc pid
  d=$(new_case orphaned-client)
  f=$(finding held ask-user)
  set_round "$d" "$f"
  mkfifo "$d/fake-state/respond-hold"
  TZ=UTC0 FM_NM_REVIEW_TEST_CRASH_AFTER_LAUNCH=1 run_driver "$d" respond --approve held >/dev/null 2>&1 \
    && fail "the crash-after-launch fixture unexpectedly completed"
  pid=$(receipt_client_pid "$d")
  [ -n "$pid" ] || fail "the authorized client identity was not recorded before the crash"
  kill -0 "$pid" 2>/dev/null || fail "the orphaned client is not running"
  out=$(TZ=Asia/Kolkata LC_ALL=C run_driver "$d" respond --approve held 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a response was re-sent while the recorded client could still deliver it"
  assert_contains "$out" 'still running' "live-client refusal under a different TZ was not actionable"
  assert_not_contains "$out" 'live owner' "the orphaned response client held the review lock"
  out=$(TZ=America/Los_Angeles run_driver "$d" audit-ready 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "readiness accepted an undelivered response"
  printf 'deliver\n' > "$d/fake-state/respond-hold"
  wait_process_gone "$pid"
  out=$(run_driver "$d" respond --approve held 2>&1) \
    || fail "the delivered response was not finalized after its client exited: $out"
  [ "$(calls_count "$d")" -eq 1 ] || fail "the orphaned response was delivered more than once"
  [ "$(jq -r '.runs[0].rounds[0].dispositions[0].state' "$(ledger "$d")")" = approved_as_is ] \
    || fail "the orphaned client's approval was not finalized from the authoritative record"
  run_driver "$d" audit-ready >/dev/null 2>&1 || fail "the recovered orphaned response did not audit ready"
  pass "an orphaned client never holds the lock, blocks only its own retry, and finalizes once delivered"
}

# The guard is killed after launching the gated client but before recording its
# identity. The unrecorded client never responds, so the attempt is retried
# exactly once.
test_crash_before_client_identity_never_responds() {
  local d f out receipt spins=0
  d=$(new_case crash-before-identity)
  f=$(finding gated ask-user)
  set_round "$d" "$f"
  FM_NM_REVIEW_TEST_CRASH_BEFORE_IDENTITY=1 run_driver "$d" respond --approve gated >/dev/null 2>&1 \
    && fail "the crash-before-identity fixture unexpectedly completed"
  receipt=$(receipt_file "$d")
  [ "$(jq -r '.client' "$receipt")" = null ] || fail "a client identity was recorded despite the crash"
  while pgrep -f "$receipt" >/dev/null 2>&1; do
    spins=$((spins + 1))
    [ "$spins" -lt 600 ] || fail "the unauthorized gated client did not exit"
    sleep 0.05
  done
  [ "$(calls_count "$d")" -eq 0 ] || fail "a client whose identity was never recorded still responded"
  out=$(run_driver "$d" respond --approve gated 2>&1) \
    || fail "an attempt that never launched an authorized client could not be retried: $out"
  [ "$(calls_count "$d")" -eq 1 ] || fail "the retry did not respond exactly once"
  pass "a client launched without a recorded identity never responds and the attempt is retried once"
}

# A landed round is final: a different choice for it is refused without a second
# response, while an attempt that never landed may still change its choice.
test_landed_round_is_never_answered_twice() {
  local d f out rc
  d=$(new_case landed-final)
  f=$(finding decided ask-user)
  set_round "$d" "$f"
  run_driver "$d" respond --approve decided >/dev/null 2>&1 || fail "landed-final fixture approval failed"
  out=$(run_driver "$d" respond --reject decided 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a landed round accepted a different response"
  assert_contains "$out" 'already resolved by the recorded approve response' "landed-round refusal was not actionable"
  [ "$(calls_count "$d")" -eq 1 ] || fail "a landed round was answered twice"

  d=$(new_case unlanded-change)
  f=$(finding undecided ask-user)
  set_round "$d" "$f"
  : > "$d/fake-state/respond-fail"
  run_driver "$d" respond --approve undecided >/dev/null 2>&1 && fail "a failing approve unexpectedly succeeded"
  rm -f "$d/fake-state/respond-fail"
  out=$(run_driver "$d" respond --reject undecided 2>&1) \
    || fail "an unlanded attempt could not change its explicit choice: $out"
  [ "$(jq -r '.runs[0].rounds[0].dispositions[0].state' "$(ledger "$d")")" = rejected_or_skipped ] \
    || fail "the changed choice was not recorded from the authoritative skip"
  pass "a landed round is never answered twice, while an unlanded attempt may change its choice"
}

# A writer that bypassed the guard could still corrupt the ledger: a copy
# computed from an old ledger must not overwrite a concurrent append.
# Optimistic-concurrency commits detect the changed ledger and recompute from it.
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

  out=$(FM_NM_REPOS_DIR="$store" run_driver "$d" respond --approve iso 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "the isolated pipeline head was not resolved for the response: $out"
  git -C "$d" rev-parse --verify --quiet "${h1}^{commit}" >/dev/null 2>&1 \
    || fail "the guard did not import the isolated pipeline head into the worktree"
  [ "$(jq -r '.runs[0].rounds[0].dispositions[0].head' "$(ledger "$d")")" = "$h1" ] \
    || fail "the disposition was not bound to the authoritative isolated head"
  out=$(FM_NM_REPOS_DIR="$store" run_driver "$d" audit-ready 2>&1); rc=$?
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
  out=$(FM_NM_REPOS_DIR="$store" run_driver "$d" respond --approve gone 2>&1); rc=$?
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

  out=$(FM_NM_REPOS_DIR="$store" run_driver "$d" respond --approve deep 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "a head buried under a deep base advance was not resolved for the response: $out"
  [ "$(jq -r '.runs[0].rounds[0].dispositions[0].head' "$(ledger "$d")")" = "$h1" ] \
    || fail "the disposition was not bound to the authoritative buried head"
  out=$(FM_NM_REPOS_DIR="$store" run_driver "$d" audit-ready 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "audit-ready could not resolve the buried isolated head: $out"
  assert_contains "$out" "head=$h1" "readiness did not report the authoritative buried head"
  pass "a validation head buried under a deep base advance resolves from the per-run store"
}

# A crash after the intent receipt but before any client launch leaves a null
# client, proving no response was sent; the next invocation retries it to completion.
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
    && [ "$(jq -r '.client' "$(receipt_file "$d")")" = null ] \
    && [ "$(calls_count "$d")" -eq 0 ] \
    || fail "the crash-before-respond fixture did not leave an untried attempting receipt"
  out=$(run_driver "$d" respond --fix cb 2>&1) \
    || fail "an unstarted attempt could not be retried: $out"
  [ "$(calls_count "$d")" -eq 1 ] || fail "the retry did not run the CLI exactly once"
  [ "$(jq -r '.runs[0].rounds[0].dispositions[0].state' "$(ledger "$d")")" = fixed_and_confirmed ] \
    || fail "the retried response was not confirmed"
  run_driver "$d" audit-ready >/dev/null 2>&1 || fail "the recovered run did not audit ready"
  pass "a crash before any client launch is retried to completion"
}

# A crash after no-mistakes recorded a fix but before the guard did leaves an
# attempting receipt. Readiness finalizes it from the authoritative per-round
# record and confirms it against the re-review without a duplicate invocation.
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

# The crash between a successful response and the durable disposition write: the
# response landed in no-mistakes but the guard died before recording it. Both
# readiness and a replayed response recover the exact final state from the
# authoritative per-round record, without invoking the response again.
test_crash_after_landed_decision_recovers_final_state() {
  local kind action d f out state entry
  for entry in approve:approved_as_is reject:rejected_or_skipped; do
    kind=${entry%%:*}
    state=${entry#*:}
    for action in audit-ready respond; do
      d=$(new_case "crash-landed-$kind-$action")
      f=$(finding landed ask-user)
      set_round "$d" "$f"
      FM_NM_REVIEW_TEST_CRASH_AFTER_RESPOND=1 run_driver "$d" respond "--$kind" landed >/dev/null 2>&1 \
        && fail "the crashed $kind fixture unexpectedly completed"
      [ "$(jq -r '.phase' "$(receipt_file "$d")")" = attempting ] \
        && [ "$(jq '.runs[0].rounds[0].dispositions | length' "$(ledger "$d")")" -eq 0 ] \
        || fail "the crashed $kind fixture did not crash between landing and recording"
      if [ "$action" = respond ]; then
        out=$(run_driver "$d" respond "--$kind" landed 2>&1) \
          || fail "a replayed $kind did not recover the landed response: $out"
        assert_contains "$out" "action=$kind findings=landed" "the recovered $kind replay did not report its response"
      fi
      out=$(run_driver "$d" audit-ready 2>&1) \
        || fail "readiness did not recover the landed $kind after the crash ($action): $out"
      assert_contains "$out" 'ready:' "the recovered $kind did not reach readiness ($action)"
      [ "$(jq -r '.runs[0].rounds[0].dispositions[0].state' "$(ledger "$d")")" = "$state" ] \
        || fail "the landed $kind was not recovered to $state ($action)"
      [ "$(jq -r '.phase' "$(receipt_file "$d")")" = landed ] || fail "the recovered $kind receipt is not landed ($action)"
      [ "$(calls_count "$d")" -eq 1 ] || fail "recovering the landed $kind invoked the response again ($action)"
    done
  done
  pass "a crash between a landed response and its durable record recovers the exact final state"
}

# The tripwire finding completed-status-does-not-prove-response-action: a guarded
# approve that failed must never be recorded as approved just because the review
# later finished by other means. A direct skip is resolved as skip, and a review
# that closed with no recorded human decision is unverifiable; both refuse.
test_failed_action_not_finalized_from_generic_completion() {
  local d f out rc
  d=$(new_case failed-then-skip)
  f=$(finding fc ask-user)
  set_round "$d" "$f"
  : > "$d/fake-state/respond-fail"
  run_driver "$d" respond --approve fc >/dev/null 2>&1 \
    && fail "a failing approve unexpectedly succeeded"
  [ "$(jq -r '.phase' "$(receipt_file "$d")")" = attempting ] \
    && [ "$(jq '.runs[0].rounds[0].dispositions | length' "$(ledger "$d")")" -eq 0 ] \
    || fail "a failed approve left a disposition or non-attempting receipt"
  rm -f "$d/fake-state/respond-fail"
  fake_nm "$d" axi respond --step review --action skip >/dev/null 2>&1 \
    || fail "the out-of-band direct skip fixture failed"
  out=$(run_driver "$d" audit-ready 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "readiness accepted a failed approve followed by a direct skip"
  assert_contains "$out" "resolved as 'skip' outside the guarded approve" "out-of-band skip refusal was not actionable"
  assert_not_contains "$out" 'ready:' "a failed approve masked by a direct skip was reported ready"
  [ "$(jq '[.runs[0].rounds[0].dispositions[] | select(.state == "approved_as_is")] | length' "$(ledger "$d")")" -eq 0 ] \
    || fail "a failed approve was recorded as approved after a direct skip"
  out=$(run_driver "$d" respond --approve fc 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a response was re-sent into a round resolved out of band"

  d=$(new_case failed-then-complete)
  f=$(finding fc ask-user)
  set_round "$d" "$f"
  : > "$d/fake-state/respond-fail"
  run_driver "$d" respond --approve fc >/dev/null 2>&1 \
    && fail "a failing approve unexpectedly succeeded"
  # The review step reports completed, yet no-mistakes recorded no decision for it.
  printf 'completed\n' > "$d/fake-state/review-status"
  printf '1\n' > "$d/fake-state/phase"
  out=$(run_driver "$d" audit-ready 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "readiness accepted a failed approve masked by a generic completed status"
  assert_contains "$out" 'without a recorded human decision' "generic-completion refusal was not actionable"
  [ "$(jq '[.runs[0].rounds[0].dispositions[] | select(.state == "approved_as_is")] | length' "$(ledger "$d")")" -eq 0 ] \
    || fail "a failed approve was recorded as approved from a generic completed status"
  pass "a failed action is never finalized from a direct skip or a generic later completion"
}

# A disposition already in the ledger is accepted only while no-mistakes'
# authoritative record of that round shows the same action, so a ledger finalized
# from weaker evidence cannot carry an approval the run never received.
test_recorded_disposition_must_match_authoritative_resolution() {
  local d out rc
  d=$(new_ready_case disposition-mismatch)
  printf 'skipped\n' > "$d/fake-state/review-status"
  out=$(run_driver "$d" audit-ready 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "readiness accepted an approval contradicted by the authoritative record"
  assert_contains "$out" "resolved as 'skip' outside the guarded approve" "disposition-mismatch refusal was not actionable"
  # A ledger written with no receipt (an earlier guard version) is checked too.
  rm -f "$(receipt_file "$d")"
  out=$(run_driver "$d" audit-ready 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "readiness accepted a receipt-less approval contradicted by the authoritative record"
  assert_contains "$out" "contradicts the no-mistakes record 'skip'" "receipt-less disposition mismatch was not actionable"
  pass "a recorded disposition must match the authoritative resolution of its round"
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

test_fix_review_gate_accepts_responses() {
  local d out f agent
  for agent in pi claude; do
    if [ "$agent" = claude ]; then d=$(claude_case "fix-review-$agent"); else d=$(new_case "fix-review-$agent"); fi
    f=$(finding fr-1 ask-user 'survived the fix re-check')
    set_round "$d" "$f"
    printf 'fix_review\n' > "$d/fake-state/review-status"
    [ "$agent" != claude ] || build_review_db "$d" fix_review
    out=$(run_driver "$d" respond --approve fr-1 2>&1) \
      || fail "$agent: a response at the fix_review gate was refused: $out"
    assert_contains "$out" 'recorded: run=RUN-11 round=1 action=approve findings=fr-1' \
      "$agent: fix_review response was not recorded"
    [ "$(calls_count "$d")" -eq 1 ] || fail "$agent: fix_review response did not invoke no-mistakes exactly once"
    [ "$(jq -r '.runs[0].rounds[0].dispositions[0].state' "$(ledger "$d")")" = approved_as_is ] \
      || fail "$agent: fix_review approval was not finalized in the ledger"
  done
  pass "the fix_review gate accepts the same guarded responses as awaiting_approval"
}

test_claude_fixing_review_still_refuses() {
  local d out f
  d=$(claude_case claude-fixing)
  f=$(finding review-1 ask-user 'mid-fix')
  set_round "$d" "$f"
  printf 'fixing\n' > "$d/fake-state/review-status"
  build_review_db "$d" fixing
  out=$(run_driver "$d" respond --approve review-1 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a claude review still applying a fix was accepted for response"
  assert_contains "$out" 'has not produced a complete result' "mid-fix refusal was not actionable"
  [ "$(calls_count "$d")" -eq 0 ] || fail "mid-fix refusal invoked the underlying response"
  [ ! -e "$(ledger "$d")" ] || fail "mid-fix refusal changed ledger state"
  pass "a review still applying a fix is refused rather than answered"
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
  # Deliberately have no state store; the prose log carries no result.
  : > "$d/fake-state/no-store"
  printf '1\n' > "$d/fake-state/phase"
  out=$(run_driver "$d" audit-ready 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a prose review with no state store was accepted"
  assert_contains "$out" 'no-mistakes review record store is absent' "missing-store refusal was not actionable"
  assert_not_contains "$out" 'ready:' "a resultless claude review was reported ready"
  pass "a prose review log with no readable state store refuses closed"
}

# Every response and readiness decision reads the no-mistakes state store, so the
# fixture store needs sqlite3. It is present on every supported target (macOS,
# Linux CI, and any host running no-mistakes, itself a sqlite app); without it
# this suite would check nothing, so refuse rather than skip.
command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 is required to exercise the review guard"
test_all_findings_fixed_and_audited_ready
test_audit_ready_accepts_running_ci_monitor_status
test_all_approved_and_explicit_rejection
test_claude_clean_zero_findings_is_ready
test_claude_info_only_is_ready
test_claude_with_findings_respond_and_audit
test_claude_fix_round_confirms_across_rounds
test_claude_incomplete_review_refuses
test_legacy_noop_preserved_round_does_not_contradict
test_claude_missing_state_store_refuses
test_isolated_pipeline_head_is_imported
test_isolated_head_absent_everywhere_refuses
test_isolated_head_resolves_under_deep_base_advance
test_crash_before_respond_is_retryable
test_crash_after_fix_reconciles_across_rounds
test_new_response_reconciles_prior_fix
test_crash_after_landed_decision_recovers_final_state
test_failed_action_not_finalized_from_generic_completion
test_recorded_disposition_must_match_authoritative_resolution
test_pr11_partial_fix_reproduction_and_proven_path
test_mixed_choices_are_unrepresentable
test_multiple_fix_rounds_preserve_history
test_surviving_finding_refuses_readiness
test_clean_current_status_cannot_erase_unresolved_history
test_response_refuses_fallback_branch_and_stale_head_without_state_changes
test_pipeline_descendant_head_is_accepted
test_pipeline_owned_rebased_head_is_accepted
test_pipeline_owned_rebase_refusals_are_preserved
test_fix_review_gate_accepts_responses
test_claude_fixing_review_still_refuses
test_post_review_pipeline_commit_refuses_readiness
test_no_ci_checks_refuses_readiness
test_checks_passed_requires_public_green_ci
test_declared_no_ci_monitor_line_refuses_readiness
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
test_no_unlocked_internal_entry_point
test_unusable_guard_file_refuses_closed
test_lock_never_outlives_the_guard_through_detached_processes
test_orphaned_client_blocks_only_its_retry_until_proven_stopped
test_crash_before_client_identity_never_responds
test_landed_round_is_never_answered_twice
test_stale_ledger_commit_cannot_clobber_concurrent_append
