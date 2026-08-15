#!/usr/bin/env bash
# Guard every Firstmate-owned no-mistakes review response and audit review
# readiness against an append-preserving disposition ledger.
#
# This executable is the single authoritative owner of the review-response
# state machine, ledger schema, storage path, public no-mistakes queries, and
# readiness decision.
# Other Firstmate instructions should only require this executable at the
# response and ready-report boundaries instead of restating these mechanics.
#
# Usage:
#   fm-no-mistakes-review.sh respond --fix <id>[,<id>...] [--instructions <text>]
#   fm-no-mistakes-review.sh respond --approve <id>[,<id>...]
#   fm-no-mistakes-review.sh respond --reject <id>[,<id>...]
#   fm-no-mistakes-review.sh audit-ready
#   fm-no-mistakes-review.sh ledger-path
# Finding lists are comma-separated current review IDs; whitespace around IDs is
# ignored, order is preserved, and every current ID must occur exactly once.
# --instructions passes fix instructions verbatim and is valid only with --fix.
#
# Run it from the project worktree whose no-mistakes validation is being driven.
# It reads only documented public command output:
#   no-mistakes axi status
#   no-mistakes axi logs --run <run-id> --step review --full
#   no-mistakes axi logs --run <run-id> --step ci
# It invokes the underlying whole-step response only after every finding in the
# current review result has one explicit, uniform choice:
#   --fix     -> no-mistakes axi respond --step review --action fix --findings ...
#   --approve -> no-mistakes axi respond --step review --action approve
#   --reject  -> no-mistakes axi respond --step review --action skip
# A partial set, duplicate ID, unknown ID, or mixed choice is refused before the
# underlying response command and before any ledger write.
#
# The ledger is JSON at:
#   <project-worktree>/.no-mistakes/firstmate-review-ledger.json
# Its exact version-1 record shape is:
#   {"version":1,"runs":[{"id":"<run-id>","branch":"<branch>",
#   "rounds":[{"round":<integer>,"head":"<commit>"|null,
#   "result":<complete-review-object>,"fix_completed_after":<boolean>,
#   "dispositions":[{"finding_id":"<id>","finding":<finding-object>,
#   "kind":"fix"|"approve"|"reject","state":<state>,
#   "run_id":"<run-id>","branch":"<branch>","head":"<commit>"}]}]}]}
# runs and rounds are append-preserving, and result/finding retain the complete
# structured objects emitted by no-mistakes.
# Disposition <state> is requested, approved_as_is, rejected_or_skipped,
# fixed_and_confirmed, or survived_unchanged.
# A successful whole-step approve/skip confirms that explicit disposition.
# A selected fix remains merely requested until the public review log contains
# both a completed fix round and the authoritative next structured review result;
# it becomes fixed_and_confirmed only when the exact finding object does not
# survive unchanged into that result.
#
# The ledger lock is a sibling mkdir lock and every write is a same-directory
# atomic rename.
# A repeated or concurrent response never invokes the underlying CLI twice:
# once a disposition request exists, replay is refused and audit-ready performs
# any later public-evidence reconciliation.
# A failed underlying response leaves requested dispositions visible, so
# readiness refuses instead of guessing whether the external action landed.
#
# audit-ready refreshes the append-only public review history, then refuses for
# missing or rewritten history, stale run/branch/head context, malformed or
# duplicate findings, missing/duplicate/contradictory dispositions, requested
# but unconfirmed fixes, unchanged surviving fixes, or absent public PR/green-CI
# evidence.
# Historical clean reviews, tests, and CI never imply approval or rejection.
# If the full structured review history or any required context is absent or
# unparsable, the command exits nonzero with an actionable diagnostic.
# Successful respond output is:
#   recorded: run=<run-id> round=<integer> action=<fix|approve|reject> findings=<id,...>
# Successful audit-ready output is:
#   ready: <https-pr-url> run=<run-id> branch=<branch> head=<commit>
# Refusals exit nonzero and begin "fm-no-mistakes-review.sh: REFUSED:" on stderr.
#
# Environment used by hermetic tests only:
#   FM_NM_REVIEW_STATE_DIR  overrides the ledger directory.
set -eu

SCRIPT_NAME=${0##*/}
NM=${FM_NO_MISTAKES_BIN:-no-mistakes}
LOCK_HELD=0
LOCK_DIR=
WORK_FILE=
MODEL_FILE=
CAPTURE_STATUS=
CAPTURE_LOGS=
CAPTURE_MODEL=
CAPTURE_RUN_ID=
CAPTURE_BRANCH=
CAPTURE_HEAD=
CAPTURE_PR=
CAPTURE_STATUS_VALUE=
CAPTURE_OUTCOME=

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  printf '%s: REFUSED: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

cleanup() {
  [ -n "$WORK_FILE" ] && rm -f "$WORK_FILE"
  [ -n "$MODEL_FILE" ] && rm -f "$MODEL_FILE"
  if [ "$LOCK_HELD" -eq 1 ] && [ -n "$LOCK_DIR" ]; then
    rm -rf "$LOCK_DIR"
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

strip_value() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  case "$value" in
    \"*\") value=${value#\"}; value=${value%\"} ;;
  esac
  printf '%s' "$value"
}

status_field() {
  local key=$1 value
  value=$(printf '%s\n' "$CAPTURE_STATUS" \
    | sed -n "s/^[[:space:]]*$key:[[:space:]]*\(.*\)/\1/p" | head -1)
  strip_value "$value"
}

capture_public_history() {
  local declared table_count actual_run
  if ! CAPTURE_STATUS=$("$NM" axi status); then
    die "no-mistakes axi status failed; validation state was not changed"
  fi
  CAPTURE_RUN_ID=$(status_field id)
  CAPTURE_BRANCH=$(status_field branch)
  CAPTURE_HEAD=$(status_field head)
  CAPTURE_PR=$(status_field pr)
  CAPTURE_STATUS_VALUE=$(status_field status)
  CAPTURE_OUTCOME=$(status_field outcome)
  [ -n "$CAPTURE_RUN_ID" ] || die "axi status omitted the validation run ID"
  [ -n "$CAPTURE_BRANCH" ] || die "axi status omitted the validation branch for run $CAPTURE_RUN_ID"
  [ -n "$CAPTURE_HEAD" ] || die "axi status omitted the validation head for run $CAPTURE_RUN_ID"

  if ! CAPTURE_LOGS=$("$NM" axi logs --run "$CAPTURE_RUN_ID" --step review --full); then
    die "full public review history is unavailable for run $CAPTURE_RUN_ID"
  fi
  actual_run=$(printf '%s\n' "$CAPTURE_LOGS" | sed -n 's/^run:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}$/\1/p' | head -1)
  [ "$actual_run" = "$CAPTURE_RUN_ID" ] \
    || die "review log belongs to run ${actual_run:-unknown}, not current run $CAPTURE_RUN_ID"
  printf '%s\n' "$CAPTURE_LOGS" | grep -Eq '^lines: [0-9]+ total$' \
    || die "full review history for run $CAPTURE_RUN_ID is truncated or has an unrecognized lines header"
  declared=$(printf '%s\n' "$CAPTURE_LOGS" | sed -n 's/^lines: \([0-9][0-9]*\) total$/\1/p' | head -1)
  table_count=$(printf '%s\n' "$CAPTURE_LOGS" | sed -n 's/^log\[\([0-9][0-9]*\)\]{line}:$/\1/p' | head -1)
  [ -n "$table_count" ] && [ "$table_count" = "$declared" ] \
    || die "full review history for run $CAPTURE_RUN_ID has inconsistent line counts"

  CAPTURE_MODEL=$(printf '%s\n' "$CAPTURE_LOGS" | jq -Rsc \
    --arg id "$CAPTURE_RUN_ID" --arg branch "$CAPTURE_BRANCH" --arg head "$CAPTURE_HEAD" '
      def outer_decode:
        sub("^  "; "")
        | (try fromjson catch .);
      def review_object:
        if type == "object" then .
        elif type == "string" then (try fromjson catch null)
        else null
        end;
      (split("\n") | map(outer_decode)) as $lines
      | ([range(0; $lines | length) as $i
          | ($lines[$i] | review_object) as $candidate
          | select(($candidate | type) == "object"
                   and ($candidate | has("findings"))
                   and (($candidate.findings | type) == "array"))
          | {line: $i, result: $candidate}]) as $events
      | {
          run: {id: $id, branch: $branch, head: $head},
          rounds: [range(0; $events | length) as $n
            | ($events[$n]) as $event
            | (($events[$n + 1].line // ($lines | length))) as $next
            | {
                result: $event.result,
                fix_completed_after: any(
                  $lines[($event.line + 1):$next][]?;
                  type == "string" and startswith("committed agent fixes: no-mistakes(review):")
                )
              }
          ]
        }
    ') || die "public review log for run $CAPTURE_RUN_ID is not parseable structured output"

  printf '%s' "$CAPTURE_MODEL" | jq -e '
    (.rounds | length) > 0
    and all(.rounds[];
      (.result.findings | type) == "array"
      and all(.result.findings[];
        type == "object" and (.id | type) == "string" and (.id | length) > 0))
  ' >/dev/null 2>&1 || die "public review log for run $CAPTURE_RUN_ID contains no complete structured review result or has malformed findings"
}

validate_capture_context() {
  local local_branch local_head public_head
  local_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) \
    || die "validation requires an attached local branch"
  local_head=$(git rev-parse --verify HEAD 2>/dev/null) \
    || die "cannot resolve the local validation head"
  public_head=$(git rev-parse --verify "${CAPTURE_HEAD}^{commit}" 2>/dev/null) \
    || die "cannot resolve public validation head $CAPTURE_HEAD in the local worktree"
  [ "$local_branch" = "$CAPTURE_BRANCH" ] \
    || die "stale-run branch mismatch: local=$local_branch public=$CAPTURE_BRANCH"
  fm_nm_head_matches_worktree "$PROJECT_ROOT" "$CAPTURE_HEAD" \
    || die "stale-head mismatch: local=$local_head public=$public_head"
}

current_ids_json() {
  printf '%s' "$CAPTURE_MODEL" | jq -c '.rounds[-1].result.findings | map(.id)'
}

selection_json() {
  local raw=$1
  printf '%s' "$raw" | jq -Rsc '
    split(",")
    | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))
    | map(select(length > 0))
  '
}

validate_selection() {
  local kind=$1 raw=$2 selected current duplicate_count omitted extras count
  selected=$(selection_json "$raw") || die "cannot parse the explicit $kind finding list"
  count=$(printf '%s' "$selected" | jq 'length')
  [ "$count" -gt 0 ] || die "$kind requires at least one explicit finding ID"
  duplicate_count=$(printf '%s' "$selected" | jq 'length - (unique | length)')
  [ "$duplicate_count" -eq 0 ] || die "$kind finding list contains duplicate IDs"
  current=$(current_ids_json)
  duplicate_count=$(printf '%s' "$current" | jq 'length - (unique | length)')
  [ "$duplicate_count" -eq 0 ] || die "current review contains duplicate finding IDs; response would be ambiguous"
  omitted=$(jq -n --argjson current "$current" --argjson selected "$selected" '$current - $selected')
  extras=$(jq -n --argjson current "$current" --argjson selected "$selected" '$selected - $current')
  if [ "$(printf '%s' "$omitted" | jq 'length')" -gt 0 ] || [ "$(printf '%s' "$extras" | jq 'length')" -gt 0 ]; then
    printf '%s\n' "$omitted" | jq -r '.[] | "omitted finding: \(.)"' >&2
    printf '%s\n' "$extras" | jq -r '.[] | "unknown finding: \(.)"' >&2
    die "the explicit $kind set must account for every current finding; the underlying whole-review response was not invoked"
  fi
  SELECTED_JSON=$selected
}

acquire_lock() {
  local tries=0
  mkdir -p "$STATE_DIR"
  LOCK_DIR="$STATE_DIR/firstmate-review-ledger.lock"
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 200 ] || die "review ledger is busy; retry after the other guarded invocation finishes"
    sleep 0.05
  done
  LOCK_HELD=1
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
}

prepare_work_files() {
  mkdir -p "$STATE_DIR"
  WORK_FILE=$(mktemp "$STATE_DIR/.firstmate-review-ledger.work.XXXXXX") \
    || die "cannot allocate an atomic ledger work file"
  MODEL_FILE=$(mktemp "$STATE_DIR/.firstmate-review-model.XXXXXX") \
    || die "cannot allocate an atomic review-history work file"
  printf '%s\n' "$CAPTURE_MODEL" > "$MODEL_FILE"
  if [ -e "$LEDGER" ]; then
    jq -e '.version == 1 and (.runs | type) == "array"' "$LEDGER" >/dev/null 2>&1 \
      || die "ledger $LEDGER is malformed or has an unsupported version"
  else
    printf '%s\n' '{"version":1,"runs":[]}' > "$WORK_FILE"
    mv "$WORK_FILE" "$LEDGER"
    WORK_FILE=$(mktemp "$STATE_DIR/.firstmate-review-ledger.work.XXXXXX") \
      || die "cannot allocate an atomic ledger work file"
  fi
}

sync_ledger() {
  local errors
  errors=$(jq -r --slurpfile model "$MODEL_FILE" '
    ($model[0]) as $m
    | (.runs | map(select(.id == $m.run.id))) as $matches
    | if ($matches | length) > 1 then "duplicate run records for \($m.run.id)"
      elif ($matches | length) == 1 and $matches[0].branch != $m.run.branch then
        "stale-run branch mismatch: ledger=\($matches[0].branch) public=\($m.run.branch)"
      elif ($matches | length) == 1 and ($matches[0].rounds | length) > ($m.rounds | length) then
        "public review history lost prior rounds for run \($m.run.id)"
      elif ($matches | length) == 1 and ([range(0; $matches[0].rounds | length) as $i
        | select($matches[0].rounds[$i].result != $m.rounds[$i].result)] | length) > 0 then
        "public review history contradicts a preserved round for run \($m.run.id)"
      elif ($matches | length) == 1 and ([range(0; $matches[0].rounds | length) as $i
        | select($matches[0].rounds[$i].fix_completed_after == true
        and $m.rounds[$i].fix_completed_after != true)] | length) > 0 then
        "public review history lost a preserved fix-round completion for run \($m.run.id)"
      elif ($matches | length) == 1
        and ($matches[0].rounds | length) == ($m.rounds | length)
        and ($matches[0].rounds | length) > 0
        and $matches[0].rounds[-1].head != $m.run.head then
        "stale-head review coverage: latest preserved review head \($matches[0].rounds[-1].head // "unknown") does not cover authoritative head \($m.run.head)"
      else empty end
  ' "$LEDGER") || die "cannot compare the disposition ledger with public review history"
  [ -z "$errors" ] || die "$errors"

  jq --slurpfile model "$MODEL_FILE" '
    ($model[0]) as $m
    | (.runs | map(.id) | index($m.run.id)) as $run_index
    | if $run_index == null then
        .runs += [{
          id: $m.run.id,
          branch: $m.run.branch,
          rounds: [range(0; $m.rounds | length) as $i
            | {
                round: ($i + 1),
                head: (if $i == (($m.rounds | length) - 1) then $m.run.head else null end),
                result: $m.rounds[$i].result,
                fix_completed_after: $m.rounds[$i].fix_completed_after,
                dispositions: []
              }]
        }]
      else
        .runs[$run_index].rounds as $old
        | .runs[$run_index].rounds = [range(0; $m.rounds | length) as $i
            | if $i < ($old | length) then
                ($old[$i]
                  | .fix_completed_after = $m.rounds[$i].fix_completed_after
                  | if .head == null and $i == (($m.rounds | length) - 1)
                    then .head = $m.run.head else . end)
              else
                {
                  round: ($i + 1),
                  head: (if $i == (($m.rounds | length) - 1) then $m.run.head else null end),
                  result: $m.rounds[$i].result,
                  fix_completed_after: $m.rounds[$i].fix_completed_after,
                  dispositions: []
                }
              end]
      end
    | (.runs | map(.id) | index($m.run.id)) as $ri
    | .runs[$ri].rounds as $rounds
    | .runs[$ri].rounds = [$rounds | to_entries[]
        | .key as $i
        | .value
        | if .fix_completed_after == true and ($i + 1) < ($rounds | length) then
            ($rounds[$i + 1].result.findings) as $next_findings
            | .dispositions = [.dispositions[]
                | . as $d
                | if .kind == "fix" and .state == "requested" then
                    if any($next_findings[]?; . == $d.finding)
                    then .state = "survived_unchanged"
                    else .state = "fixed_and_confirmed"
                    end
                  else . end]
          else . end]
  ' "$LEDGER" > "$WORK_FILE" || die "cannot extend the disposition ledger"
  mv "$WORK_FILE" "$LEDGER"
  WORK_FILE=$(mktemp "$STATE_DIR/.firstmate-review-ledger.work.XXXXXX") \
    || die "cannot allocate an atomic ledger work file"
}

current_round_number() {
  printf '%s' "$CAPTURE_MODEL" | jq '.rounds | length'
}

append_requested_dispositions() {
  local kind=$1 round=$2 errors
  errors=$(jq -r --arg run "$CAPTURE_RUN_ID" --argjson round "$round" '
    (.runs[] | select(.id == $run) | .rounds[] | select(.round == $round)) as $r
    | if $r.head == null then "current review round has no exact head context"
      elif ($r.dispositions | length) > 0 then
        "review round \($round) already has disposition records; refusing duplicate/replayed response"
      else empty end
  ' "$LEDGER") || die "cannot inspect current ledger round"
  [ -z "$errors" ] || die "$errors"

  jq --arg run "$CAPTURE_RUN_ID" --arg branch "$CAPTURE_BRANCH" \
    --arg kind "$kind" --argjson round "$round" '
      (.runs | map(.id) | index($run)) as $ri
      | (.runs[$ri].rounds | map(.round) | index($round)) as $rdi
      | .runs[$ri].rounds[$rdi] as $r
      | .runs[$ri].rounds[$rdi].dispositions = [
          $r.result.findings[]
          | {
              finding_id: .id,
              finding: .,
              kind: $kind,
              state: "requested",
              run_id: $run,
              branch: $branch,
              head: $r.head
            }
        ]
    ' "$LEDGER" > "$WORK_FILE" || die "cannot record explicit disposition requests"
  mv "$WORK_FILE" "$LEDGER"
  WORK_FILE=$(mktemp "$STATE_DIR/.firstmate-review-ledger.work.XXXXXX") \
    || die "cannot allocate an atomic ledger work file"
}

confirm_uniform_disposition() {
  local kind=$1 round=$2 final_state
  case "$kind" in
    approve) final_state=approved_as_is ;;
    reject) final_state=rejected_or_skipped ;;
    *) die "internal disposition confirmation error for $kind" ;;
  esac
  jq --arg run "$CAPTURE_RUN_ID" --argjson round "$round" --arg state "$final_state" '
      (.runs | map(.id) | index($run)) as $ri
      | (.runs[$ri].rounds | map(.round) | index($round)) as $rdi
      | .runs[$ri].rounds[$rdi].dispositions |= map(
          if .state == "requested" then .state = $state else . end)
    ' "$LEDGER" > "$WORK_FILE" || die "cannot confirm explicit $kind dispositions"
  mv "$WORK_FILE" "$LEDGER"
  WORK_FILE=$(mktemp "$STATE_DIR/.firstmate-review-ledger.work.XXXXXX") \
    || die "cannot allocate an atomic ledger work file"
}

respond() {
  local fix='' approve='' reject='' instructions='' want='' kind='' raw='' selected_csv round rc modes=0
  shift
  while [ "$#" -gt 0 ]; do
    if [ -n "$want" ]; then
      case "$1" in --*) die "--$want requires a value" ;; esac
      case "$want" in
        fix) fix=$1 ;;
        approve) approve=$1 ;;
        reject) reject=$1 ;;
        instructions) instructions=$1 ;;
      esac
      want=
      shift
      continue
    fi
    case "$1" in
      --fix) want=fix ;;
      --approve) want=approve ;;
      --reject) want=reject ;;
      --instructions) want=instructions ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown respond argument: $1" ;;
    esac
    shift
  done
  [ -z "$want" ] || die "--$want requires a value"
  [ -n "$fix" ] && modes=$((modes + 1)) && kind=fix && raw=$fix
  [ -n "$approve" ] && modes=$((modes + 1)) && kind=approve && raw=$approve
  [ -n "$reject" ] && modes=$((modes + 1)) && kind=reject && raw=$reject
  [ "$modes" -eq 1 ] || die "mixed or missing per-finding choices cannot be represented by no-mistakes' whole-review response; choose exactly one of --fix, --approve, or --reject for every finding"
  [ "$kind" = fix ] || [ -z "$instructions" ] \
    || die "--instructions is valid only with --fix"

  command -v "$NM" >/dev/null 2>&1 || die "no-mistakes command is unavailable"
  command -v jq >/dev/null 2>&1 || die "jq is required"
  capture_public_history
  validate_capture_context
  validate_selection "$kind" "$raw"

  acquire_lock
  capture_public_history
  validate_capture_context
  validate_selection "$kind" "$raw"
  prepare_work_files
  sync_ledger
  round=$(current_round_number)
  append_requested_dispositions "$kind" "$round"
  selected_csv=$(printf '%s' "$SELECTED_JSON" | jq -r 'join(",")')

  rc=0
  case "$kind" in
    fix)
      if [ -n "$instructions" ]; then
        "$NM" axi respond --step review --action fix --findings "$selected_csv" --instructions "$instructions" || rc=$?
      else
        "$NM" axi respond --step review --action fix --findings "$selected_csv" || rc=$?
      fi
      ;;
    approve) "$NM" axi respond --step review --action approve || rc=$? ;;
    reject) "$NM" axi respond --step review --action skip || rc=$? ;;
  esac
  [ "$rc" -eq 0 ] || die "underlying no-mistakes response failed with exit $rc; requested dispositions remain unconfirmed and replay is refused"

  if [ "$kind" = fix ]; then
    capture_public_history
    validate_capture_context
    printf '%s\n' "$CAPTURE_MODEL" > "$MODEL_FILE"
    sync_ledger
    errors=$(jq -r --arg run "$CAPTURE_RUN_ID" --argjson round "$round" '
      .runs[] | select(.id == $run) | .rounds[] | select(.round == $round)
      | .dispositions[]
      | select(.state != "fixed_and_confirmed")
      | "finding \(.finding_id) fix is \(.state), not fixed_and_confirmed"
    ' "$LEDGER") || die "cannot verify completed fixes"
    [ -z "$errors" ] || die "$errors"
  else
    confirm_uniform_disposition "$kind" "$round"
  fi
  printf 'recorded: run=%s round=%s action=%s findings=%s\n' \
    "$CAPTURE_RUN_ID" "$round" "$kind" "$selected_csv"
}

audit_ready() {
  local errors ci_logs marker
  command -v "$NM" >/dev/null 2>&1 || die "no-mistakes command is unavailable"
  command -v jq >/dev/null 2>&1 || die "jq is required"
  capture_public_history
  validate_capture_context
  acquire_lock
  capture_public_history
  validate_capture_context
  prepare_work_files
  sync_ledger

  errors=$(jq -r --arg run "$CAPTURE_RUN_ID" --arg branch "$CAPTURE_BRANCH" '
    (.runs | map(select(.id == $run))) as $matches
    | if ($matches | length) != 1 then
        ["missing or duplicate ledger run for \($run)"]
      else
        ($matches[0]) as $r
        | [
            (if $r.branch != $branch then
              "stale-run ledger branch mismatch: \($r.branch)"
             else empty end),
            ($r.rounds[]
              | . as $round
              | ([$round.result.findings[].id] | group_by(.)[] | select(length > 1) | .[0]) as $duplicate
              | "round \($round.round) has duplicate finding ID \($duplicate)"),
            ($r.rounds[]
              | select((.result.findings | length) > 0 and (.head == null or (.head | type) != "string" or (.head | length) == 0))
              | "round \(.round) has findings but no exact head context"),
            ($r.rounds[]
              | . as $round
              | $round.result.findings[]
              | . as $finding
              | ([$round.dispositions[] | select(.finding_id == $finding.id and .finding == $finding)]) as $ds
              | if ($ds | length) == 0 then
                  "round \($round.round) finding \($finding.id) has no explicit disposition"
                elif ($ds | length) > 1 then
                  "round \($round.round) finding \($finding.id) has duplicate dispositions"
                else empty end),
            ($r.rounds[]
              | . as $round
              | $round.dispositions[]
              | . as $d
              | if $d.run_id != $run or $d.branch != $r.branch then
                  "round \($round.round) finding \($d.finding_id) has stale-run disposition context"
                elif $d.head != $round.head then
                  "round \($round.round) finding \($d.finding_id) has stale-head disposition context"
                elif (["fix", "approve", "reject"] | index($d.kind)) == null then
                  "round \($round.round) finding \($d.finding_id) has contradictory disposition kind \($d.kind)"
                elif $d.kind == "fix" and $d.state == "requested" then
                  "round \($round.round) finding \($d.finding_id) was merely requested for fix and is unconfirmed"
                elif $d.kind == "fix" and $d.state == "survived_unchanged" then
                  "round \($round.round) finding \($d.finding_id) survived unchanged after its fix round"
                elif $d.kind == "fix" and $d.state != "fixed_and_confirmed" then
                  "round \($round.round) finding \($d.finding_id) has contradictory fix state \($d.state)"
                elif $d.kind == "approve" and $d.state != "approved_as_is" then
                  "round \($round.round) finding \($d.finding_id) lacks explicit confirmed approval"
                elif $d.kind == "reject" and $d.state != "rejected_or_skipped" then
                  "round \($round.round) finding \($d.finding_id) lacks explicit confirmed rejection"
                else empty end),
            ($r.rounds[]
              | . as $round
              | $round.dispositions[]
              | . as $d
              | select((["requested", "approved_as_is", "rejected_or_skipped", "fixed_and_confirmed", "survived_unchanged"] | index($d.state)) == null)
              | "round \($round.round) finding \($d.finding_id) has unknown disposition state \($d.state)"),
            ($r.rounds[]
              | . as $round
              | $round.dispositions[]
              | . as $d
              | select((any($round.result.findings[]?; . == $d.finding)) | not)
              | "round \($round.round) has a disposition for an absent or contradictory finding \($d.finding_id)")
          ]
      end
    | .[]
  ' "$LEDGER") || die "cannot audit the disposition ledger"
  if [ -n "$errors" ]; then
    printf '%s\n' "$errors" >&2
    die "review findings are not fully and unambiguously accounted"
  fi

  [ -n "$CAPTURE_PR" ] || die "axi status has no PR URL; readiness is not public"
  case "$CAPTURE_PR" in https://*) ;; *) die "axi status PR is not a full https URL: $CAPTURE_PR" ;; esac
  case "$CAPTURE_OUTCOME" in
    checks-passed) ;;
    failed|cancelled)
      die "authoritative validation run outcome is $CAPTURE_OUTCOME; historical CI evidence cannot authorize readiness"
      ;;
    passed)
      die "authoritative validation run outcome is passed; the PR is no longer awaiting readiness"
      ;;
    "")
      [ "$CAPTURE_STATUS_VALUE" = ci ] \
        || die "authoritative validation run is not in the active CI monitor: ${CAPTURE_STATUS_VALUE:-unknown}"
      if ! ci_logs=$("$NM" axi logs --run "$CAPTURE_RUN_ID" --step ci); then
        die "public CI log is unavailable for run $CAPTURE_RUN_ID"
      fi
      marker=$(printf '%s\n' "$ci_logs" \
        | grep -E 'CI checks passed|no CI checks reported - still monitoring|no CI checks reported yet|checks failed|issues detected|CI checks running|base branch advanced.*re-arming CI monitor timeout' \
        | tail -1 || true)
      case "$marker" in
        *"checks passed"*) ;;
        "") die "public CI history has no recognized readiness result" ;;
        *) die "latest public CI result is not green: $marker" ;;
      esac
      ;;
    *) die "authoritative validation run has unrecognized outcome: $CAPTURE_OUTCOME" ;;
  esac

  printf 'ready: %s run=%s branch=%s head=%s\n' \
    "$CAPTURE_PR" "$CAPTURE_RUN_ID" "$CAPTURE_BRANCH" "$CAPTURE_HEAD"
}

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
  || die "run this command inside the project worktree"
STATE_DIR=${FM_NM_REVIEW_STATE_DIR:-$PROJECT_ROOT/.no-mistakes}
[ ! -L "$STATE_DIR" ] || die "review state directory must not be a symlink: $STATE_DIR"
[ ! -e "$STATE_DIR" ] || [ -d "$STATE_DIR" ] \
  || die "review state path is not a directory: $STATE_DIR"
LEDGER="$STATE_DIR/firstmate-review-ledger.json"

case "${1:-}" in
  respond) respond "$@" ;;
  audit-ready) [ "$#" -eq 1 ] || die "audit-ready accepts no arguments"; audit_ready ;;
  ledger-path) [ "$#" -eq 1 ] || die "ledger-path accepts no arguments"; printf '%s\n' "$LEDGER" ;;
  -h|--help) usage ;;
  "") usage >&2; exit 2 ;;
  *) die "unknown command: $1" ;;
esac
