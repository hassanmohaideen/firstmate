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
# It reads documented public command output:
#   no-mistakes axi status
#   no-mistakes axi logs --run <run-id> --step review --full
#   no-mistakes axi logs --run <run-id> --step ci
#   gh pr view <pr-url> --json headRefOid,state,statusCheckRollup
# and reads no-mistakes' own durable state store strictly READ-ONLY
# (~/.no-mistakes/state.sqlite, overridable with FM_NM_STATE_DB) for the
# per-round review record described under "Authoritative review resolution".
# It never writes to that store and never contacts the network except for the
# gh query at the readiness boundary.
# The per-round structured review result comes from one of two shapes, because
# review agents differ in what they echo to the review log:
#   - Structured-log agents (e.g. codex/gpt/pi) emit one JSON review object per
#     round into the review log; the guard reconstructs the round model from the
#     log.
#   - Prose-log agents (e.g. claude) narrate the review in prose and echo NO
#     per-round JSON object to the log, so the guard sources the identical round
#     model from the state store's review rounds.
# Both shapes produce the same round model, so every disposition, ledger, and
# readiness check below applies uniformly regardless of the review agent. A review
# whose result is genuinely missing, truncated, or not yet produced still refuses.
# Informational findings (action "no-op") never gate a review and require no
# disposition, so they are excluded from the disposition-requiring finding set of
# each round; every actionable finding (any other action) must still be accounted.
# The pipeline validates in an isolated per-run repository, so the authoritative
# head reported by axi status can be a fix commit this worktree never fetched.
# Before verifying run context, the guard makes that head resolvable locally by
# importing the missing objects READ-ONLY from the no-mistakes per-run object
# store (~/.no-mistakes/repos/<hash>.git, overridable with FM_NM_REPOS_DIR) into
# this worktree's object database. It never writes to that store, never moves a
# local branch, and never contacts the network; if the head cannot be resolved
# from the worktree or that store the command refuses closed.
# The local branch must be the public head or an ancestor of it, with one bound
# exception: a pre-push pipeline-owned head move (the rebase step or a
# pipeline-owned rebase-conflict resolution rewrites history). It is accepted only
# when axi status branch_sync reports state pipeline_owned for this exact run, a
# clean local branch still at the run's submitted_head, and a pipeline
# current_head equal to the public head; any other head refuses as stale.
# Only review-step findings are mapped; a finding from another step (e.g. ci) is
# refused as an unknown finding.
# It invokes the underlying whole-step response only after every finding in the
# current review result has one explicit, uniform choice:
#   --fix     -> no-mistakes axi respond --step review --action fix --findings ...
#   --approve -> no-mistakes axi respond --step review --action approve
#   --reject  -> no-mistakes axi respond --step review --action skip
# A partial set, duplicate ID, unknown ID, or mixed choice is refused before the
# underlying response command and before any ledger write.
#
# Authoritative review resolution.
# Whether a response landed is decided only from no-mistakes' own durable record
# of how that exact review round was resolved, never from this guard's in-process
# observations, the response client's exit status, the review gate leaving, or a
# generic completed status. For round N of the run's latest review step, whose
# recorded actionable finding IDs must equal round N of the public review history,
# the resolution is:
#   fix:<ids>  round N records selection source "user" with exactly <ids>;
#   approve    round N records "user_declined" and the step completed at round N,
#              or a later round exists (a skipped review is never re-run);
#   skip       round N records "user_declined" and the step is skipped;
#   pending    round N is the latest round, records no decision, and the step is
#              parked at awaiting_approval or fix_review;
#   transient  a response was accepted and is still being recorded (for example
#              the step is fixing, or the decision is recorded but the step has
#              not yet completed or skipped);
#   anything else - an auto_fix selection, an abort, a round closed without a
#   recorded human decision, a round whose findings differ from the public
#   history, or an unreadable store - is out-of-band or unknown and refuses.
# --fix, --approve, and --reject land only on fix:<their exact ids>, approve, and
# skip respectively, so a guarded approve that failed followed by a direct skip
# can never be recorded as approved_as_is.
# The per-round decision record exists from no-mistakes v1.55.1; an older store
# records no approve or skip decision, so its rounds refuse as unverifiable.
#
# Response boundary.
# Each response for a run and round is governed by a durable receipt at:
#   <project-worktree>/.no-mistakes/.firstmate-review-receipt.<run-id>.<round>.json
# written only by same-directory atomic rename in this exact version-2 shape:
#   {"version":2,"run":"<run-id>","branch":"<branch>","round":<integer>,
#   "action":"fix"|"approve"|"reject","findings":["<id>",...],
#   "attempt":<integer>,"head":"<commit>","phase":"attempting"|"landed",
#   "client":{"pid":<integer>,"start":"<process-start-time>"}|null}
# A new response is sent only into a round whose resolution is pending.
# The guard records the intent with a null client before launching anything,
# then launches the no-mistakes response client gated: the client may contact
# no-mistakes only after the receipt names its own PID and process start time,
# and it exits without responding if this guard dies first or that authorization
# never arrives. So every client that could ever have sent a response is
# durably identified, and a null client proves none did.
# The guard then waits, bounded by FM_NM_REVIEW_IPC_BUDGET, for the round's
# authoritative resolution, stops the client (after its response the client only
# observes the run; stopping it never cancels the daemon's run, which keeps
# driving push, PR, and CI), and re-reads the resolution with the client proven
# stopped:
#   matches the recorded action -> receipt landed, then the ledger disposition;
#   pending   -> refuses; the attempt is recorded and can be safely retried;
#   transient -> refuses; rerun the same command to confirm it;
#   otherwise -> refuses as out-of-band or unverifiable.
# Every later invocation, respond and audit-ready alike, reconciles every receipt
# of the run the same way before acting, so a crash or failure at any point
# converges: a response that landed is finalized from the record without a second
# invocation, and an unlanded one is retried only when its recorded client is
# proven stopped (null, or no live process with that PID and start time), never
# while a client that could still deliver it is running. An unlanded attempt may
# be retried with the same or a different explicit choice; a landed round is never
# answered twice. no-mistakes accepts at most one response per open review gate,
# so a retry that races a late delivery of the same response is accepted at most
# once, and a round resolved without a matching receipt refuses readiness.
# A receipt written by an earlier guard version (no version or client field) is
# reconciled the same way: it finalizes when its action matches the record, an
# unlanded "failed" one is retryable because its client had returned, and any
# other unlanded one refuses because its client cannot be proven stopped.
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
# Dispositions are written only after the round's resolution matched its receipt.
# A landed approve or reject is written straight to approved_as_is or
# rejected_or_skipped in one ledger commit.
# A landed fix is written requested and is confirmed against the next review
# round of the public history: fixed_and_confirmed when the exact finding object
# does not survive unchanged into it, otherwise survived_unchanged. Until that
# round exists the fix stays requested and readiness refuses.
# Every ledger write is a same-directory atomic rename, so a crash mid-write
# leaves the ledger at its prior or next complete state. Ledger commits also
# re-check the content hash read at mutation time and recompute rather than
# overwrite a ledger that changed underneath them.
#
# Single-owner exclusion.
# respond and audit-ready hold an exclusive, nonblocking kernel advisory lock
# (flock(2): flock(1) on Linux, perl on macOS) for the whole invocation on an
# open file description of
#   <project-worktree>/.no-mistakes/.firstmate-review-ledger.guard
# that the guard process itself owns. Acquiring the lock and owning it are one
# kernel operation, so there is no on-disk owner record, PID, or token to be lost,
# forged, or left half-written: the lock exists only while its owning process
# lives, the kernel releases it the instant that process exits for any reason
# including SIGKILL, and a live owner can never be preempted. A contender refuses
# ("live owner") and retries later. Commands that can start long-lived detached
# processes - no-mistakes, which may start its daemon, git, and gh - and the
# response client always run with that descriptor closed, so the lock can never
# outlive the guard. If the kernel lock primitive is unavailable the command
# refuses instead of proceeding without exclusion.
#
# audit-ready refreshes the append-only public review history, reconciles every
# outstanding response receipt without invoking a response, and refuses any
# unlanded, in-flight, out-of-band, or unverifiable attempt. It then refuses for
# missing or rewritten history, stale run/branch/head context, malformed or
# duplicate findings, missing/duplicate/contradictory dispositions, requested
# but unconfirmed fixes, unchanged surviving fixes, or any dispositioned round
# whose authoritative resolution does not match its disposition kind.
# Readiness then requires the run to report CI readiness (outcome checks-passed,
# or the active CI monitor whose latest public CI line reports green checks,
# never the no_ci declaration) and independent public CI evidence from the PR:
# it must be open with headRefOid equal to the authoritative head and report at
# least one check; the latest result of every check name must be completed and
# successful, neutral, or skipped, with at least one success; and a rollup of 100
# or more entries refuses as possibly truncated. Absent, unreadable, pending,
# failing, or zero-check evidence refuses, including a trusted no_ci declaration.
# Historical clean reviews, tests, and CI never imply approval or rejection.
# If the full structured review history or any required context is absent or
# unparsable, the command exits nonzero with an actionable diagnostic.
# Successful respond output is:
#   recorded: run=<run-id> round=<integer> action=<fix|approve|reject> findings=<id,...>
# Successful audit-ready output is:
#   ready: <https-pr-url> run=<run-id> branch=<branch> head=<commit>
# Refusals exit nonzero and begin "fm-no-mistakes-review.sh: REFUSED:" on stderr.
#
# Environment:
#   FM_NM_REPOS_DIR                  overrides the no-mistakes per-run object-store
#                                    root used to import an isolated pipeline head
#                                    (default: ~/.no-mistakes/repos).
#   FM_NM_STATE_DB                   overrides the no-mistakes state store read
#                                    READ-ONLY for review rounds and resolutions
#                                    (default: ~/.no-mistakes/state.sqlite).
#   FM_NM_REVIEW_IPC_BUDGET          maximum whole seconds to wait for the
#                                    authoritative record of a response before
#                                    stopping its client and refusing closed; the
#                                    long push/PR/CI drive is never awaited
#                                    (default: 60).
# Environment used by hermetic tests only:
#   FM_NM_REVIEW_STATE_DIR           overrides the ledger directory.
#   FM_NM_REVIEW_TEST_ACQUIRED       appends this PID once the kernel lock is held.
#   FM_NM_REVIEW_TEST_HOLD_FIFO      blocks the lock holder on a fixture FIFO.
#   FM_NM_REVIEW_TEST_CRASH_HOLDING  kills the holder just after it takes the lock.
#   FM_NM_REVIEW_TEST_NO_LOCKER      simulates an unavailable kernel lock primitive.
#   FM_NM_REVIEW_TEST_LEDGER_COMMIT_FIFO  blocks a ledger mutation once before its first commit.
#   FM_NM_REVIEW_TEST_CRASH_BEFORE_RESPOND  kills a responder after it records the
#                                    intent receipt but before launching a client.
#   FM_NM_REVIEW_TEST_CRASH_BEFORE_IDENTITY kills a responder after it launches the
#                                    gated client but before recording its identity.
#   FM_NM_REVIEW_TEST_CRASH_AFTER_LAUNCH    kills a responder once its client is
#                                    authorized, leaving that client running.
#   FM_NM_REVIEW_TEST_CRASH_AFTER_RESPOND   kills a responder after the response
#                                    landed but before the receipt and ledger record it.
set -eu

SCRIPT_NAME=${0##*/}
NM=${FM_NO_MISTAKES_BIN:-no-mistakes}
LOCK_GUARD=
LEDGER_COMMIT_HOOK_FIRED=0
WORK_FILE=
MODEL_FILE=
DRIVE_LOG=
CLIENT_PID=
CLIENT_ID_PID=
CLIENT_START=
CLIENT_RC=
RESOLUTION=
RECONCILE=
RECONCILE_ATTEMPT=
RECEIPT_ACTION=
RECEIPT_FINDINGS=
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

# The review lock lives on file descriptor 9 of this process, and every process
# that inherits that descriptor shares the lock. These commands can start
# long-lived detached processes (the no-mistakes daemon, detached git
# maintenance), so they always run with descriptor 9 closed and the lock can
# never outlive the guard. The overrides also cover git calls made by the sourced
# run library.
nm_cli() { "$NM" "$@" 9>&-; }
git() { command git "$@" 9>&-; }
gh() { command gh "$@" 9>&-; }

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
  # The kernel advisory lock is released automatically when this process exits,
  # so cleanup only stops a still-running response client and removes this
  # invocation's private temporary work files. It never touches the shared guard
  # file, receipts, or the ledger. Stopping the client never cancels the daemon's run.
  if [ -n "$CLIENT_PID" ]; then
    kill -TERM "$CLIENT_PID" 2>/dev/null || true
    CLIENT_PID=
  fi
  [ -z "$WORK_FILE" ] || rm -f "$WORK_FILE"
  [ -z "$MODEL_FILE" ] || rm -f "$MODEL_FILE"
  [ -z "$DRIVE_LOG" ] || rm -f "$DRIVE_LOG"
  return 0
}

finish() {
  local rc=$?
  trap - EXIT INT TERM
  if ! cleanup && [ "$rc" -eq 0 ]; then
    rc=1
  fi
  exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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

require_safe_run_id() {
  case "$CAPTURE_RUN_ID" in
    ''|*[!A-Za-z0-9._-]*) die "unsupported validation run id '$CAPTURE_RUN_ID'" ;;
  esac
}

capture_public_history() {
  local declared table_count actual_run
  if ! CAPTURE_STATUS=$(nm_cli axi status); then
    die "no-mistakes axi status failed; validation state was not changed"
  fi
  CAPTURE_RUN_ID=$(status_field id)
  CAPTURE_BRANCH=$(status_field branch)
  CAPTURE_HEAD=$(status_field head)
  CAPTURE_PR=$(status_field pr)
  CAPTURE_STATUS_VALUE=$(status_field status)
  CAPTURE_OUTCOME=$(status_field outcome)
  [ -n "$CAPTURE_RUN_ID" ] || die "axi status omitted the validation run ID"
  require_safe_run_id
  [ -n "$CAPTURE_BRANCH" ] || die "axi status omitted the validation branch for run $CAPTURE_RUN_ID"
  [ -n "$CAPTURE_HEAD" ] || die "axi status omitted the validation head for run $CAPTURE_RUN_ID"

  if ! CAPTURE_LOGS=$(nm_cli axi logs --run "$CAPTURE_RUN_ID" --step review --full); then
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
      # Informational findings (action "no-op") never gate a review and require no
      # disposition; drop them so a round holds only actionable findings.
      def actionable: .findings = [(.findings // [])[] | select(.action != "no-op")];
      (split("\n") | map(outer_decode)) as $lines
      | ([range(0; $lines | length) as $i
          | ($lines[$i] | review_object) as $candidate
          | select(($candidate | type) == "object"
                   and ($candidate | has("findings"))
                   and (($candidate.findings | type) == "array"))
          | {line: $i, result: ($candidate | actionable)}]) as $events
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

  # A prose review log (e.g. claude) echoes no per-round JSON object, so the log
  # parser yields no rounds. Source the identical round model from no-mistakes'
  # durable state store instead. A structured-log review whose per-round JSON
  # object is absent (e.g. truncation that still passes the line-count checks)
  # also lands here; the store is authoritative and fails closed on a missing or
  # incomplete record.
  if [ "$(printf '%s' "$CAPTURE_MODEL" | jq '.rounds | length')" -eq 0 ]; then
    capture_review_model_from_state_store
  fi

  printf '%s' "$CAPTURE_MODEL" | jq -e '
    (.rounds | length) > 0
    and all(.rounds[];
      (.result.findings | type) == "array"
      and all(.result.findings[];
        type == "object" and (.id | type) == "string" and (.id | length) > 0))
  ' >/dev/null 2>&1 || die "review result for run $CAPTURE_RUN_ID contains no complete structured review result or has malformed findings"
}

store_ready_or_die() {
  command -v sqlite3 >/dev/null 2>&1 \
    || die "sqlite3 is required to read the authoritative no-mistakes review record for run $CAPTURE_RUN_ID"
  [ -f "$NM_STATE_DB" ] \
    || die "the no-mistakes review record store is absent at $NM_STATE_DB; cannot verify run $CAPTURE_RUN_ID"
}

capture_review_model_from_state_store() {
  # Prose-log fallback source for the structured per-round review model. no-mistakes
  # records every review round's authoritative structured result (the same JSON
  # object a structured-log agent echoes to the review log) in its own state store,
  # so when the review log carries no per-round object the guard reads the identical
  # round model from that store. The read is strictly READ-ONLY (sqlite3 -readonly).
  # It refuses closed when the tool, store, or a completed review record is
  # genuinely absent, so a missing or in-progress review is never mistaken for a
  # clean pass.
  local srid rstatus rounds_json
  store_ready_or_die
  # A brief busy timeout tolerates a transient lock from a concurrent writer rather
  # than refusing spuriously; the store is WAL, so read-only readers do not block.
  srid=$(sqlite3 -readonly -cmd '.timeout 2000' "$NM_STATE_DB" \
    "SELECT id FROM step_results WHERE run_id='$CAPTURE_RUN_ID' AND step_name='review' ORDER BY rowid DESC LIMIT 1;" 2>/dev/null) \
    || die "cannot read the review record for run $CAPTURE_RUN_ID from the no-mistakes state store"
  [ -n "$srid" ] \
    || die "the no-mistakes state store has no review step for run $CAPTURE_RUN_ID; the review result is missing"
  rstatus=$(sqlite3 -readonly -cmd '.timeout 2000' "$NM_STATE_DB" \
    "SELECT status FROM step_results WHERE id='$srid';" 2>/dev/null) \
    || die "cannot read the review status for run $CAPTURE_RUN_ID from the no-mistakes state store"
  # awaiting_approval and fix_review are parked gates whose latest round carries the
  # result to answer; completed and skipped steps have finished every round.
  case "$rstatus" in
    completed|skipped|awaiting_approval|fix_review) ;;
    *) die "review step for run $CAPTURE_RUN_ID has not produced a complete result (state: ${rstatus:-unknown}); refusing an incomplete or in-progress review" ;;
  esac
  rounds_json=$(sqlite3 -readonly -cmd '.timeout 2000' -json "$NM_STATE_DB" \
    "SELECT round, trigger_type, findings_json FROM step_rounds WHERE step_result_id='$srid' ORDER BY round;" 2>/dev/null) \
    || die "cannot read the review rounds for run $CAPTURE_RUN_ID from the no-mistakes state store"
  [ -n "$rounds_json" ] && [ "$rounds_json" != "[]" ] \
    || die "the no-mistakes state store has no recorded review rounds for run $CAPTURE_RUN_ID; the review result is missing or incomplete"
  # Build the identical round model the structured-log path produces: one round per
  # recorded review round, actionable findings only, and fix_completed_after true
  # when the next round was triggered by a committed fix.
  CAPTURE_MODEL=$(printf '%s' "$rounds_json" | jq -c \
    --arg id "$CAPTURE_RUN_ID" --arg branch "$CAPTURE_BRANCH" --arg head "$CAPTURE_HEAD" '
      def actionable: .findings = [(.findings // [])[] | select(.action != "no-op")];
      . as $rows
      | {
          run: {id: $id, branch: $branch, head: $head},
          rounds: [range(0; $rows | length) as $i
            | ($rows[$i].findings_json | fromjson | actionable) as $result
            | {
                result: $result,
                fix_completed_after: (($i + 1) < ($rows | length)
                  and ((["auto_fix", "user_fix"] | index($rows[$i + 1].trigger_type)) != null))
              }]
        }') \
    || die "the recorded review result for run $CAPTURE_RUN_ID is not parseable structured output"
}

import_public_head() {
  # Make the authoritative pipeline head resolvable in this worktree even when the
  # pipeline created it in its isolated per-run object store rather than here.
  # Read-only: imports objects FROM the no-mistakes per-run repo INTO this
  # worktree's object database via a local fetch; it never writes to that repo,
  # never moves a local branch, and never contacts the network. Returns 0 once the
  # head resolves locally, nonzero if it cannot be found in the worktree or store.
  local head=$1 repo
  git rev-parse --verify --quiet "${head}^{commit}" >/dev/null 2>&1 && return 0
  [ -d "$NM_REPOS_DIR" ] || return 1
  for repo in "$NM_REPOS_DIR"/*.git; do
    [ -d "$repo" ] || continue
    git --git-dir="$repo" cat-file -e "${head}^{commit}" 2>/dev/null || continue
    # This per-run store holds the object. Import it without creating a local ref
    # or touching HEAD: fetch the exact commit (a reachable-SHA fetch over the
    # local protocol), falling back to the run branch that carries it.
    git -c protocol.file.allow=always \
        -c uploadpack.allowAnySHA1InWant=true \
        -c uploadpack.allowReachableSHA1InWant=true \
        fetch --no-tags --no-write-fetch-head --quiet "$repo" "$head" 2>/dev/null || true
    git rev-parse --verify --quiet "${head}^{commit}" >/dev/null 2>&1 && return 0
    if [ -n "$CAPTURE_BRANCH" ] \
       && git --git-dir="$repo" show-ref --verify --quiet "refs/heads/$CAPTURE_BRANCH"; then
      git -c protocol.file.allow=always \
          fetch --no-tags --no-write-fetch-head --quiet "$repo" \
          "refs/heads/$CAPTURE_BRANCH" 2>/dev/null || true
    fi
    git rev-parse --verify --quiet "${head}^{commit}" >/dev/null 2>&1 && return 0
  done
  return 1
}

validate_capture_context() {
  local local_branch local_head public_head
  local_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) \
    || die "validation requires an attached local branch"
  local_head=$(git rev-parse --verify HEAD 2>/dev/null) \
    || die "cannot resolve the local validation head"
  import_public_head "$CAPTURE_HEAD" \
    || die "cannot resolve public validation head $CAPTURE_HEAD in the local worktree or the no-mistakes per-run object store"
  public_head=$(git rev-parse --verify "${CAPTURE_HEAD}^{commit}" 2>/dev/null) \
    || die "cannot resolve public validation head $CAPTURE_HEAD after import"
  [ "$local_branch" = "$CAPTURE_BRANCH" ] \
    || die "stale-run branch mismatch: local=$local_branch public=$CAPTURE_BRANCH"
  fm_nm_head_matches_worktree "$PROJECT_ROOT" "$CAPTURE_HEAD" && return 0
  pipeline_owned_head_move "$local_branch" "$local_head" "$public_head" && return 0
  die "stale-head mismatch: local=$local_head public=$public_head"
}

branch_sync_field() {  # <section> <key>; section "" reads a direct branch_sync child
  # Reads one scalar from the nested branch_sync object of the captured axi status.
  local section=$1 key=$2 value
  value=$(printf '%s\n' "$CAPTURE_STATUS" | awk -v section="$section" -v key="$key" '
    /^branch_sync:[[:space:]]*$/ { inside = 1; current = ""; next }
    inside && /^[^[:space:]]/ { exit }
    !inside { next }
    {
      match($0, /^ */)
      indent = RLENGTH
      line = substr($0, indent + 1)
      if (indent == 2 && line ~ /^[A-Za-z_]+:[[:space:]]*$/) {
        current = line
        sub(/:.*/, "", current)
        next
      }
      if (indent == 2) current = ""
      want = (section == "") ? 2 : 4
      if (indent == want && current == section && index(line, key ":") == 1) {
        print substr(line, length(key) + 2)
        exit
      }
    }')
  strip_value "$value"
}

pipeline_owned_head_move() {  # <local-branch> <local-head> <public-head>
  # 0 when the public head moved away from the local branch ONLY because this run's
  # pipeline moved it before push (its rebase step, a pipeline-owned rebase-conflict
  # resolution, or a pipeline fix on top of either). A rebase rewrites history, so
  # the local ref need not be an ancestor of the public head; the binding instead is
  # no-mistakes' own structured branch_sync custody record: the branch is
  # pipeline_owned by this exact run, the local branch is clean and still exactly the
  # head this run was submitted from, and the pipeline's current head is exactly the
  # public head. Any local advance, other run, returned custody, dirty tree, or
  # unrelated head fails this check and stays a stale-head refusal.
  local local_branch=$1 local_head=$2 public_head=$3 current submitted
  [ "$(branch_sync_field '' state)" = pipeline_owned ] || return 1
  [ "$(branch_sync_field pipeline run)" = "$CAPTURE_RUN_ID" ] || return 1
  [ "$(branch_sync_field local branch)" = "$local_branch" ] || return 1
  [ "$(branch_sync_field local clean)" = true ] || return 1
  [ "$(branch_sync_field local head)" = "$local_head" ] || return 1
  submitted=$(branch_sync_field pipeline submitted_head)
  [ -n "$submitted" ] && [ "$submitted" = "$local_head" ] || return 1
  current=$(branch_sync_field pipeline current_head)
  [ -n "$current" ] || return 1
  current=$(git rev-parse --verify --quiet "${current}^{commit}" 2>/dev/null) || return 1
  [ "$current" = "$public_head" ]
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

sorted_csv() {  # <csv>; prints the same IDs sorted, for set comparison
  printf '%s' "$1" | jq -Rr 'split(",") | map(select(length > 0)) | sort | join(",")'
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

review_lock_held_hooks() {
  # Deterministic seams for hermetic concurrency and crash fixtures. They fire
  # only once the kernel advisory lock is already held by this process, so a test
  # can observe acquisition, hold the lock open, or kill the holder without any
  # sleeping or reliance on a naturally reused PID.
  if [ -n "${FM_NM_REVIEW_TEST_ACQUIRED:-}" ]; then
    printf '%s\n' "$$" >> "$FM_NM_REVIEW_TEST_ACQUIRED"
  fi
  if [ "${FM_NM_REVIEW_TEST_CRASH_HOLDING:-}" = 1 ]; then
    kill -KILL "$$"
  fi
  if [ -n "${FM_NM_REVIEW_TEST_HOLD_FIFO:-}" ]; then
    IFS= read -r _held_release < "$FM_NM_REVIEW_TEST_HOLD_FIFO" || true
  fi
}

prepare_guard_file() {
  umask 077
  mkdir -p "$STATE_DIR"
  LOCK_GUARD="$STATE_DIR/.firstmate-review-ledger.guard"
  [ ! -L "$LOCK_GUARD" ] || die "review-ledger kernel guard must not be a symlink"
  if [ ! -e "$LOCK_GUARD" ]; then
    (set -C; : > "$LOCK_GUARD") 2>/dev/null || true
  fi
  [ -f "$LOCK_GUARD" ] && [ ! -L "$LOCK_GUARD" ] \
    || die "review-ledger kernel guard is not a regular private file"
  chmod 600 "$LOCK_GUARD" || die "cannot make review-ledger kernel guard private"
}

acquire_review_lock() {
  # Take the exclusive kernel lock on descriptor 9, an open file description this
  # process owns for the rest of its life. The helper that performs the flock(2)
  # call exits immediately; the lock stays with the shared open file description,
  # so it is held exactly as long as this guard process lives.
  local rc=0
  prepare_guard_file
  if [ "${FM_NM_REVIEW_TEST_NO_LOCKER:-}" = 1 ]; then
    die "kernel-backed review-ledger exclusion is unavailable; refusing to proceed without single-owner exclusion"
  fi
  exec 9<>"$LOCK_GUARD" || die "cannot open the review-ledger kernel guard"
  case "$(uname -s 2>/dev/null || true)" in
    Linux)
      command -v flock >/dev/null 2>&1 \
        || die "flock is required for crash-safe review-ledger exclusion on Linux; refusing to proceed without single-owner exclusion"
      flock -n -E 75 9 || rc=$?
      ;;
    Darwin)
      command -v perl >/dev/null 2>&1 \
        || die "perl is required for crash-safe review-ledger exclusion on macOS; refusing to proceed without single-owner exclusion"
      perl -MFcntl=:flock -e '
        open(my $fh, "+<&=", 9) or exit 70;
        exit 0 if flock($fh, LOCK_EX | LOCK_NB);
        exit($!{EWOULDBLOCK} ? 75 : 71);' || rc=$?
      ;;
    *) die "kernel-backed review-ledger exclusion is unsupported on this operating system; refusing to proceed without single-owner exclusion" ;;
  esac
  case "$rc" in
    0) ;;
    75) die "review ledger has a live owner; retry after the guarded invocation finishes" ;;
    *) die "review-ledger kernel lock failed (status $rc); refusing to proceed without single-owner exclusion" ;;
  esac
}

ledger_content_hash() {
  # Stable content hash of the current ledger, or a sentinel when it does not
  # exist yet, used for optimistic-concurrency commits.
  [ -e "$LEDGER" ] || { printf 'absent'; return 0; }
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$LEDGER" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 < "$LEDGER" | awk '{print $1}'
  else
    cksum < "$LEDGER" | awk '{print $1 "-" $2}'
  fi
}

ledger_mutate() {
  # Commit a ledger mutation with optimistic concurrency so a stale copy can
  # never clobber a concurrent append. The mutation callback reads $LEDGER and
  # writes the next content to $WORK_FILE; we capture the ledger hash at read
  # time and rename only if the on-disk ledger is still unchanged at commit,
  # otherwise we recompute from the now-current ledger. The guarded path is
  # already serialized by the kernel lock, so this only protects the
  # append-preserving invariant against a writer that bypassed the guard; such a
  # writer already has write access to this private state directory.
  local mutation=$1 before attempts=0
  shift
  while :; do
    before=$(ledger_content_hash)
    "$mutation" "$@"
    if [ "$LEDGER_COMMIT_HOOK_FIRED" -eq 0 ] && [ -n "${FM_NM_REVIEW_TEST_LEDGER_COMMIT_FIFO:-}" ]; then
      LEDGER_COMMIT_HOOK_FIRED=1
      : > "$FM_NM_REVIEW_TEST_LEDGER_COMMIT_FIFO.reached" 2>/dev/null || true
      IFS= read -r _ledger_commit_release < "$FM_NM_REVIEW_TEST_LEDGER_COMMIT_FIFO" || true
    fi
    if [ "$(ledger_content_hash)" = "$before" ]; then
      mv "$WORK_FILE" "$LEDGER" || die "cannot commit the disposition ledger"
      WORK_FILE=$(mktemp "$STATE_DIR/.firstmate-review-ledger.work.XXXXXX") \
        || die "cannot allocate an atomic ledger work file"
      return 0
    fi
    attempts=$((attempts + 1))
    [ "$attempts" -lt 128 ] \
      || die "the disposition ledger changed concurrently repeatedly; refusing to overwrite a concurrently updated ledger"
  done
}

prepare_work_files() {
  mkdir -p "$STATE_DIR"
  WORK_FILE=$(mktemp "$STATE_DIR/.firstmate-review-ledger.work.XXXXXX") \
    || die "cannot allocate an atomic ledger work file"
  MODEL_FILE=$(mktemp "$STATE_DIR/.firstmate-review-model.XXXXXX") \
    || die "cannot allocate an atomic review-history work file"
  printf '%s\n' "$CAPTURE_MODEL" > "$MODEL_FILE"
  if [ ! -e "$LEDGER" ]; then
    # Atomic create so a concurrent initializer cannot be clobbered; if another
    # process wins the race the file simply already exists and is validated below.
    (umask 077; set -C; printf '%s\n' '{"version":1,"runs":[]}' > "$LEDGER") 2>/dev/null || true
    [ -e "$LEDGER" ] || die "cannot initialize the disposition ledger"
  fi
  jq -e '.version == 1 and (.runs | type) == "array"' "$LEDGER" >/dev/null 2>&1 \
    || die "ledger $LEDGER is malformed or has an unsupported version"
}

sync_ledger() {
  ledger_mutate _sync_ledger_apply
}

_sync_ledger_apply() {
  local errors
  errors=$(jq -r --slurpfile model "$MODEL_FILE" '
    # Ledgers written before informational filtering preserved rounds WITH no-op
    # findings; compare both sides in actionable form so such a round stays
    # consistent with its no-op-filtered rebuild.
    def actionable: .findings = [(.findings // [])[] | select(.action != "no-op")];
    ($model[0]) as $m
    | (.runs | map(select(.id == $m.run.id))) as $matches
    | if ($matches | length) > 1 then "duplicate run records for \($m.run.id)"
      elif ($matches | length) == 1 and $matches[0].branch != $m.run.branch then
        "stale-run branch mismatch: ledger=\($matches[0].branch) public=\($m.run.branch)"
      elif ($matches | length) == 1 and ($matches[0].rounds | length) > ($m.rounds | length) then
        "public review history lost prior rounds for run \($m.run.id)"
      elif ($matches | length) == 1 and ([range(0; $matches[0].rounds | length) as $i
        | select(($matches[0].rounds[$i].result | actionable) != ($m.rounds[$i].result | actionable))] | length) > 0 then
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
    # A fix disposition exists only after the round authoritatively resolved as
    # that exact fix, so the next round of the history is its re-review: confirm
    # each requested fix against it.
    | .runs[$ri].rounds = [$rounds | to_entries[]
        | .key as $i
        | .value
        | if ($i + 1) < ($rounds | length) then
            ([($rounds[$i + 1].result.findings // [])[] | select(.action != "no-op")]) as $next_findings
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
}

current_round_number() {
  printf '%s' "$CAPTURE_MODEL" | jq '.rounds | length'
}

round_dispositions_count() {  # <round>
  jq -r --arg run "$CAPTURE_RUN_ID" --argjson round "$1" '
    [.runs[] | select(.id == $run) | .rounds[] | select(.round == $round) | .dispositions[]?] | length
  ' "$LEDGER"
}

review_round_resolution() {  # <round>; sets RESOLUTION (see "Authoritative review resolution")
  # Strictly READ-ONLY. Reads the latest review step of this run and all of its
  # rounds, binds round N to round N of the public history by its actionable
  # finding IDs, and classifies how no-mistakes recorded that round's resolution.
  local round=$1 rows model_ids
  RESOLUTION="unknown:cannot read the no-mistakes review record for run $CAPTURE_RUN_ID round $round"
  require_safe_run_id
  if ! rows=$(sqlite3 -readonly -cmd '.timeout 2000' -json "$NM_STATE_DB" "
      SELECT sr.status AS status, rd.round AS round, rd.selection_source AS source,
             rd.selected_finding_ids AS selected, rd.findings_json AS findings
        FROM step_rounds rd JOIN step_results sr ON sr.id = rd.step_result_id
       WHERE sr.id = (SELECT id FROM step_results
                       WHERE run_id = '$CAPTURE_RUN_ID' AND step_name = 'review'
                       ORDER BY rowid DESC LIMIT 1)
       ORDER BY rd.round;" 2>/dev/null); then
    return 0
  fi
  if [ -z "$rows" ] || [ "$rows" = "[]" ]; then
    RESOLUTION="unknown:the no-mistakes state store has no review rounds for run $CAPTURE_RUN_ID"
    return 0
  fi
  model_ids=$(printf '%s' "$CAPTURE_MODEL" | jq -c --argjson round "$round" \
    '[(.rounds[$round - 1].result.findings // [])[].id] | sort') || return 0
  RESOLUTION=$(printf '%s' "$rows" | jq -r --argjson round "$round" --argjson model_ids "$model_ids" '
    def ids: [((. // "{}") | fromjson | .findings // [])[] | select(.action != "no-op") | .id] | sort;
    def gate: . == "awaiting_approval" or . == "fix_review";
    . as $rows
    | ($rows | map(.round) | max) as $latest
    | [$rows[] | select(.round == $round)] as $match
    | if ($match | length) != 1 then
        "unknown:the no-mistakes store has no unique review round \($round) for this run"
      else
        $match[0] as $r
        | ($r.round < $latest) as $later
        | if ($r.findings | ids) != $model_ids then
            "unknown:no-mistakes review round \($round) does not match round \($round) of the public review history"
          elif $r.source == "user" then
            (($r.selected // "null") | fromjson) as $sel
            | if ($sel | type) == "array" and ($sel | length) > 0
              then "fix:" + ($sel | map(tostring) | sort | join(","))
              else "unknown:no-mistakes recorded a fix for round \($round) without its finding IDs" end
          elif $r.source == "auto_fix" then "auto_fix"
          elif $r.source == "user_declined" then
            if $later or $r.status == "completed" then "approve"
            elif $r.status == "skipped" then "skip"
            elif $r.status == "failed" then "abort"
            else "transient" end
          elif $r.source == null then
            if $later then
              "unknown:no-mistakes review round \($round) has a later round but no recorded decision"
            elif ($r.status | gate) then "pending"
            elif $r.status == "running" or $r.status == "fixing" or $r.status == "pending" then "transient"
            else "unknown:no-mistakes review round \($round) closed (\($r.status)) without a recorded human decision" end
          else "unknown:no-mistakes recorded an unrecognized decision source \($r.source) for round \($round)" end
      end
  ') || RESOLUTION="unknown:the no-mistakes review record for run $CAPTURE_RUN_ID round $round is not parseable"
  return 0
}

resolution_matches() {  # <action> <findings-csv>; tests the current RESOLUTION
  case "$1" in
    fix) [ "$RESOLUTION" = "fix:$(sorted_csv "$2")" ] ;;
    approve) [ "$RESOLUTION" = approve ] ;;
    reject) [ "$RESOLUTION" = skip ] ;;
    *) return 1 ;;
  esac
}

refuse_unmatched_resolution() {  # <round> <action>; dies for any non-matching RESOLUTION
  local round=$1 action=$2
  case "$RESOLUTION" in
    pending) die "the $action response for run $CAPTURE_RUN_ID round $round has not landed; retry it through the guarded response path" ;;
    transient) die "no-mistakes accepted a response for run $CAPTURE_RUN_ID round $round that it is still recording; rerun the same command shortly to confirm it" ;;
    unknown:*) die "${RESOLUTION#unknown:}; the response for run $CAPTURE_RUN_ID round $round cannot be verified" ;;
    *) die "run $CAPTURE_RUN_ID round $round was resolved as '$RESOLUTION' outside the guarded $action response; its findings cannot be accounted, so start a fresh validation run" ;;
  esac
}

receipt_file() {  # <round>
  require_safe_run_id
  printf '%s/.firstmate-review-receipt.%s.%s.json' "$STATE_DIR" "$CAPTURE_RUN_ID" "$1"
}

read_receipt() {  # <round>; prints the receipt JSON, or nothing when absent
  local f
  f=$(receipt_file "$1")
  [ -e "$f" ] || return 0
  [ -f "$f" ] && [ ! -L "$f" ] || die "review-ledger response receipt is not a regular private file"
  jq -e 'type == "object" and (.action | type) == "string" and (.phase | type) == "string"' "$f" >/dev/null 2>&1 \
    || die "response receipt for run $CAPTURE_RUN_ID round $1 is malformed"
  cat "$f"
}

write_receipt() {  # <round> <phase> <action> <findings-csv> <attempt> <head> <client-pid> <client-start>
  local round=$1 phase=$2 action=$3 findings=$4 attempt=$5 head=$6 pid=$7 start=$8 f tmp
  f=$(receipt_file "$round")
  [ ! -L "$f" ] || die "review-ledger response receipt must not be a symlink"
  tmp=$(mktemp "$STATE_DIR/.firstmate-review-receipt.XXXXXX") \
    || die "cannot allocate a response-receipt work file"
  jq -cn --arg run "$CAPTURE_RUN_ID" --arg branch "$CAPTURE_BRANCH" \
    --argjson round "$round" --arg phase "$phase" --arg action "$action" \
    --arg findings "$findings" --argjson attempt "$attempt" --arg head "$head" \
    --arg pid "$pid" --arg start "$start" '
    {version: 2, run: $run, branch: $branch, round: $round, action: $action,
     findings: ($findings | split(",") | map(select(length > 0))),
     attempt: $attempt, head: $head, phase: $phase,
     client: (if $pid == "" then null else {pid: ($pid | tonumber), start: $start} end)}' > "$tmp" \
    || { rm -f "$tmp"; die "cannot render the response receipt"; }
  # Same-directory atomic rename: a crash leaves the prior or next complete
  # receipt, never a partial one. Serialized by the kernel lock.
  mv "$tmp" "$f" || { rm -f "$tmp"; die "cannot commit the response receipt"; }
}

process_start() {  # <pid>; prints the process start time, or nothing when no such process
  ps -o lstart= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true
}

client_alive() {  # <pid> <start>; 0 only while that exact process still runs
  local current
  current=$(process_start "$1")
  [ -n "$current" ] && [ "$current" = "$2" ]
}

ensure_uniform_disposition() {  # <round> <kind> <final-state>
  ledger_mutate _ensure_uniform_disposition_apply "$@"
}

_ensure_uniform_disposition_apply() {
  local round=$1 kind=$2 state=$3
  # Idempotent: the round's dispositions are fully determined by its findings, the
  # accepted action, and the round head, so a replay recomputes the same set.
  jq --arg run "$CAPTURE_RUN_ID" --arg branch "$CAPTURE_BRANCH" \
    --arg kind "$kind" --arg state "$state" --argjson round "$round" '
      (.runs | map(.id) | index($run)) as $ri
      | (.runs[$ri].rounds | map(.round) | index($round)) as $rdi
      | .runs[$ri].rounds[$rdi] as $r
      | .runs[$ri].rounds[$rdi].dispositions = [
          $r.result.findings[]
          | {finding_id: .id, finding: ., kind: $kind, state: $state,
             run_id: $run, branch: $branch, head: $r.head}]
    ' "$LEDGER" > "$WORK_FILE" || die "cannot finalize explicit $kind dispositions"
}

init_fix_dispositions() {  # <round>
  ledger_mutate _init_fix_dispositions_apply "$@"
}

_init_fix_dispositions_apply() {
  local round=$1
  # Initialize once as requested; a later sync confirms from public evidence and
  # must not be reset, so leave any existing dispositions untouched.
  jq --arg run "$CAPTURE_RUN_ID" --arg branch "$CAPTURE_BRANCH" --argjson round "$round" '
      (.runs | map(.id) | index($run)) as $ri
      | (.runs[$ri].rounds | map(.round) | index($round)) as $rdi
      | .runs[$ri].rounds[$rdi] as $r
      | if ($r.dispositions | length) == 0 then
          .runs[$ri].rounds[$rdi].dispositions = [
            $r.result.findings[]
            | {finding_id: .id, finding: ., kind: "fix", state: "requested",
               run_id: $run, branch: $branch, head: $r.head}]
        else . end
    ' "$LEDGER" > "$WORK_FILE" || die "cannot record fix disposition requests"
}

finalize_disposition() {  # <round> <kind>; only after the resolution matched the receipt
  case "$2" in
    approve) ensure_uniform_disposition "$1" approve approved_as_is ;;
    reject) ensure_uniform_disposition "$1" reject rejected_or_skipped ;;
    fix) init_fix_dispositions "$1"; sync_ledger ;;
    *) die "internal finalize error for $2" ;;
  esac
}

confirm_fix_round() {  # <round>; refreshes history so a re-review already present confirms the fix
  local round=$1 survived pending
  capture_public_history
  validate_capture_context
  printf '%s\n' "$CAPTURE_MODEL" > "$MODEL_FILE"
  sync_ledger
  survived=$(jq -r --arg run "$CAPTURE_RUN_ID" --argjson round "$round" '
    .runs[] | select(.id == $run) | .rounds[] | select(.round == $round)
    | .dispositions[] | select(.state == "survived_unchanged")
    | "finding \(.finding_id) fix is survived_unchanged, not fixed_and_confirmed"
  ' "$LEDGER") || die "cannot verify completed fixes"
  [ -z "$survived" ] || die "$survived"
  pending=$(jq -r --arg run "$CAPTURE_RUN_ID" --argjson round "$round" '
    [.runs[] | select(.id == $run) | .rounds[] | select(.round == $round)
     | .dispositions[] | select(.state == "requested")] | length
  ' "$LEDGER") || die "cannot verify completed fixes"
  if [ "$pending" -gt 0 ]; then
    printf '%s: the fix response landed; it is confirmed once no-mistakes re-reviews the fix. Confirm readiness with audit-ready.\n' \
      "$SCRIPT_NAME" >&2
  fi
}

reconcile_round() {  # <round>; sets RECONCILE to none, landed, or retry (with RECONCILE_ATTEMPT)
  # The one reconciliation procedure every invocation applies to a receipt before
  # acting. It never invokes a response; it finalizes a landed response from the
  # authoritative resolution and decides whether an unlanded one may be re-sent.
  local round=$1 existing r_phase r_attempt r_head c_pid c_start has_client
  RECONCILE=none
  RECONCILE_ATTEMPT=1
  RECEIPT_ACTION=
  RECEIPT_FINDINGS=
  existing=$(read_receipt "$round")
  [ -n "$existing" ] || return 0
  RECEIPT_ACTION=$(printf '%s' "$existing" | jq -r '.action')
  RECEIPT_FINDINGS=$(printf '%s' "$existing" | jq -r '.findings // [] | join(",")')
  r_phase=$(printf '%s' "$existing" | jq -r '.phase')
  r_attempt=$(printf '%s' "$existing" | jq -r '.attempt // 0')
  r_head=$(printf '%s' "$existing" | jq -r '.head // ""')
  has_client=$(printf '%s' "$existing" | jq -r 'has("client")')
  c_pid=$(printf '%s' "$existing" | jq -r '.client.pid // ""')
  c_start=$(printf '%s' "$existing" | jq -r '.client.start // ""')
  case "$RECEIPT_ACTION" in
    fix|approve|reject) ;;
    *) die "response receipt for run $CAPTURE_RUN_ID round $round has an unrecognized action '$RECEIPT_ACTION'" ;;
  esac
  case "$r_phase" in
    attempting|landed|failed) ;;
    *) die "response receipt for run $CAPTURE_RUN_ID round $round has an unrecognized phase '$r_phase'" ;;
  esac

  review_round_resolution "$round"
  if resolution_matches "$RECEIPT_ACTION" "$RECEIPT_FINDINGS"; then
    if [ "$r_phase" != landed ] || [ "$(printf '%s' "$existing" | jq -r '.version // 1')" != 2 ]; then
      write_receipt "$round" landed "$RECEIPT_ACTION" "$RECEIPT_FINDINGS" "$r_attempt" "$r_head" "$c_pid" "$c_start"
    fi
    if [ "$(round_dispositions_count "$round")" -eq 0 ] || [ "$RECEIPT_ACTION" = fix ]; then
      finalize_disposition "$round" "$RECEIPT_ACTION"
    fi
    RECONCILE=landed
    return 0
  fi
  [ "$RESOLUTION" = pending ] || refuse_unmatched_resolution "$round" "$RECEIPT_ACTION"

  # Proven unlanded so far. Re-sending is safe only when no client that could
  # still deliver this attempt is running.
  if [ -n "$c_pid" ]; then
    if client_alive "$c_pid" "$c_start"; then
      die "a prior response client (pid $c_pid) for run $CAPTURE_RUN_ID round $round is still running and may yet deliver its response; retry after it exits"
    fi
  elif [ "$has_client" != true ] && [ "$r_phase" != failed ]; then
    # A receipt written by an earlier guard version records no client identity,
    # so a client it launched cannot be proven stopped.
    die "an earlier guard's unconfirmed response attempt for run $CAPTURE_RUN_ID round $round has no recorded client identity, so it cannot be proven stopped; start a fresh validation run"
  fi
  RECONCILE=retry
  RECONCILE_ATTEMPT=$((r_attempt + 1))
}

launch_response_client() {  # <round> <kind> <findings-csv> <instructions> <attempt>
  # Launch the response client gated on its own durably recorded identity: it
  # waits, without contacting no-mistakes, until this attempt's receipt names its
  # PID, and exits without responding if this guard dies first or the
  # authorization does not arrive. It runs with the lock descriptor closed.
  local round=$1 kind=$2 selected_csv=$3 instructions=$4 attempt=$5 receipt
  receipt=$(receipt_file "$round")
  command -v ps >/dev/null 2>&1 || die "ps is required to record the response client identity"
  DRIVE_LOG=$(mktemp "$STATE_DIR/.firstmate-review-drive.XXXXXX") \
    || die "cannot allocate a response drive log"
  set -- "$NM" axi respond --step review
  case "$kind" in
    fix)
      set -- "$@" --action fix --findings "$selected_csv"
      [ -z "$instructions" ] || set -- "$@" --instructions "$instructions"
      ;;
    approve) set -- "$@" --action approve ;;
    reject) set -- "$@" --action skip ;;
    *) die "internal response error for $kind" ;;
  esac
  # shellcheck disable=SC2016  # the gate script expands its own positional parameters
  sh -c '
    receipt=$1 parent=$2 attempt=$3 polls=$4
    shift 4
    i=0
    while [ "$i" -lt "$polls" ]; do
      if jq -e --argjson pid "$$" --argjson attempt "$attempt" \
          ".phase == \"attempting\" and .attempt == \$attempt and .client.pid == \$pid" \
          "$receipt" >/dev/null 2>&1; then
        exec "$@"
      fi
      [ "$(ps -o ppid= -p "$$" 2>/dev/null | tr -d " ")" = "$parent" ] || exit 86
      i=$((i + 1))
      sleep 0.05
    done
    exit 86' fm-review-client "$receipt" "$$" "$attempt" 200 "$@" \
    </dev/null >"$DRIVE_LOG" 2>&1 9>&- &
  CLIENT_PID=$!
  CLIENT_ID_PID=$CLIENT_PID
  [ "${FM_NM_REVIEW_TEST_CRASH_BEFORE_IDENTITY:-}" != 1 ] || kill -KILL "$$"
  CLIENT_START=$(process_start "$CLIENT_PID")
  if [ -z "$CLIENT_START" ]; then
    stop_response_client
    die "cannot record the response client identity; no response was sent and the attempt can be safely retried"
  fi
  write_receipt "$round" attempting "$kind" "$selected_csv" "$attempt" "$CAPTURE_HEAD" "$CLIENT_PID" "$CLIENT_START"
}

stop_response_client() {
  # Stop the client and reap it, so it is proven stopped before the final
  # resolution read. A stopped client only stops observing; the daemon's run
  # keeps driving push, PR, and CI.
  local spins=0
  [ -n "$CLIENT_PID" ] || return 0
  if kill -0 "$CLIENT_PID" 2>/dev/null; then
    kill -TERM "$CLIENT_PID" 2>/dev/null || true
    while kill -0 "$CLIENT_PID" 2>/dev/null; do
      spins=$((spins + 1))
      if [ "$spins" -ge 25 ]; then kill -KILL "$CLIENT_PID" 2>/dev/null || true; break; fi
      sleep 0.2
    done
  fi
  wait "$CLIENT_PID" 2>/dev/null || true
  CLIENT_PID=
}

settle_response() {  # <round> <kind> <findings-csv>; leaves the final RESOLUTION
  # Wait for the round's authoritative resolution, bounded by the IPC budget, or
  # a short grace once the client has exited on its own. The client's exit status
  # is recorded for diagnostics only; it never decides whether the response landed.
  local round=$1 kind=$2 selected_csv=$3 polls=0 max grace=0 rc
  max=$((IPC_BUDGET * 5))
  [ "$max" -ge 1 ] || max=1
  CLIENT_RC=
  while :; do
    review_round_resolution "$round"
    resolution_matches "$kind" "$selected_csv" && break
    case "$RESOLUTION" in pending|transient) ;; *) break ;; esac
    if [ -z "$CLIENT_RC" ] && ! kill -0 "$CLIENT_PID" 2>/dev/null; then
      rc=0
      wait "$CLIENT_PID" 2>/dev/null || rc=$?
      CLIENT_RC=$rc
      CLIENT_PID=
    fi
    if [ -n "$CLIENT_RC" ]; then
      grace=$((grace + 1))
      [ "$grace" -lt 10 ] || break
    else
      polls=$((polls + 1))
      [ "$polls" -lt "$max" ] || break
    fi
    sleep 0.2
  done
  stop_response_client
  review_round_resolution "$round"
}

respond() {
  local fix='' approve='' reject='' instructions='' want='' kind='' raw='' selected_csv round head_ok modes=0 attempt r drive_tail=''
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
  store_ready_or_die
  prepare_work_files
  sync_ledger
  round=$(current_round_number)
  head_ok=$(jq -r --arg run "$CAPTURE_RUN_ID" --argjson round "$round" '
    [.runs[] | select(.id == $run) | .rounds[] | select(.round == $round) | select(.head != null)] | length
  ' "$LEDGER") || die "cannot inspect current ledger round"
  [ "$head_ok" = 1 ] || die "current review round has no exact head context"
  selected_csv=$(printf '%s' "$SELECTED_JSON" | jq -r 'join(",")')

  # Every earlier round's receipt must already be authoritatively resolved.
  r=1
  while [ "$r" -lt "$round" ]; do
    reconcile_round "$r"
    [ "$RECONCILE" != retry ] \
      || die "an earlier response for run $CAPTURE_RUN_ID round $r never landed; resolve it before answering round $round"
    r=$((r + 1))
  done

  reconcile_round "$round"
  case "$RECONCILE" in
    landed)
      [ "$RECEIPT_ACTION" = "$kind" ] && [ "$(sorted_csv "$RECEIPT_FINDINGS")" = "$(sorted_csv "$selected_csv")" ] \
        || die "run $CAPTURE_RUN_ID round $round is already resolved by the recorded $RECEIPT_ACTION response (findings=$RECEIPT_FINDINGS); a different response cannot be applied"
      [ "$kind" != fix ] || confirm_fix_round "$round"
      printf 'recorded: run=%s round=%s action=%s findings=%s\n' \
        "$CAPTURE_RUN_ID" "$round" "$kind" "$selected_csv"
      return 0
      ;;
    retry) attempt=$RECONCILE_ATTEMPT ;;
    none)
      [ "$(round_dispositions_count "$round")" -eq 0 ] \
        || die "run $CAPTURE_RUN_ID round $round already has recorded dispositions without a response receipt; refusing a second response"
      # Send only into a review gate the record shows open and unanswered.
      review_round_resolution "$round"
      case "$RESOLUTION" in
        pending) ;;
        transient) die "the review step for run $CAPTURE_RUN_ID round $round is not parked at a response gate; retry once it is" ;;
        unknown:*) die "${RESOLUTION#unknown:}; refusing to respond without a verifiable review record" ;;
        *) die "run $CAPTURE_RUN_ID round $round is already resolved as '$RESOLUTION' outside this guard; refusing a second response" ;;
      esac
      attempt=1
      ;;
  esac

  # Record intent with no client before launching anything, then launch the
  # gated client, which may act only once its identity is recorded.
  write_receipt "$round" attempting "$kind" "$selected_csv" "$attempt" "$CAPTURE_HEAD" "" ""
  [ "${FM_NM_REVIEW_TEST_CRASH_BEFORE_RESPOND:-}" != 1 ] || kill -KILL "$$"
  launch_response_client "$round" "$kind" "$selected_csv" "$instructions" "$attempt"
  if [ "${FM_NM_REVIEW_TEST_CRASH_AFTER_LAUNCH:-}" = 1 ]; then
    CLIENT_PID=
    kill -KILL "$$"
  fi
  settle_response "$round" "$kind" "$selected_csv"

  if resolution_matches "$kind" "$selected_csv"; then
    [ "${FM_NM_REVIEW_TEST_CRASH_AFTER_RESPOND:-}" != 1 ] || kill -KILL "$$"
    write_receipt "$round" landed "$kind" "$selected_csv" "$attempt" "$CAPTURE_HEAD" "$CLIENT_ID_PID" "$CLIENT_START"
    finalize_disposition "$round" "$kind"
    [ "$kind" != fix ] || confirm_fix_round "$round"
    printf 'recorded: run=%s round=%s action=%s findings=%s\n' \
      "$CAPTURE_RUN_ID" "$round" "$kind" "$selected_csv"
    return 0
  fi

  if [ "$RESOLUTION" = pending ]; then
    # Surface the client's own diagnostic before cleanup removes the drive log.
    drive_tail=$(tail -n 20 "$DRIVE_LOG" 2>/dev/null || true)
    if [ -n "$drive_tail" ]; then
      die "the no-mistakes response did not land (client exit ${CLIENT_RC:-stopped}); the attempt is recorded, its client is stopped, and the same command can be safely retried. Client output (last 20 lines):
$drive_tail"
    fi
    die "the no-mistakes response did not land within ${IPC_BUDGET}s (client exit ${CLIENT_RC:-stopped}); the attempt is recorded, its client is stopped, and the same command can be safely retried"
  fi
  refuse_unmatched_resolution "$round" "$kind"
}

reconcile_all_rounds_for_audit() {  # <last-round>
  local last=$1 round=1
  while [ "$round" -le "$last" ]; do
    reconcile_round "$round"
    [ "$RECONCILE" != retry ] \
      || die "the $RECEIPT_ACTION response for run $CAPTURE_RUN_ID round $round has not landed; retry it through the guarded response path before readiness"
    round=$((round + 1))
  done
}

verify_dispositions_against_resolution() {
  # Readiness accepts a disposition only when no-mistakes' authoritative record of
  # that exact round shows the same action, whichever guard version wrote it.
  local rows round kind ids
  rows=$(jq -r --arg run "$CAPTURE_RUN_ID" '
    .runs[] | select(.id == $run) | .rounds[]
    | select((.dispositions | length) > 0)
    | "\(.round) \([.dispositions[].kind] | unique | join("+")) \([(.result.findings // [])[] | select(.action != "no-op") | .id] | sort | join(","))"
  ' "$LEDGER") || die "cannot read the recorded dispositions"
  while read -r round kind ids; do
    [ -n "$round" ] || continue
    case "$kind" in
      fix|approve|reject) ;;
      *) die "round $round has contradictory disposition kinds $kind" ;;
    esac
    review_round_resolution "$round"
    resolution_matches "$kind" "$ids" && continue
    case "$RESOLUTION" in
      unknown:*) die "${RESOLUTION#unknown:}; the recorded $kind disposition for round $round cannot be verified" ;;
    esac
    die "the recorded $kind disposition for round $round contradicts the no-mistakes record '$RESOLUTION' for that round; readiness is refused"
  done <<EOF
$rows
EOF
}

require_public_green_ci() {
  # Independent public CI evidence from the PR itself, bound to the
  # authoritative head. Every absent, unreadable, or non-green fact refuses.
  local head_full view verdict
  [ -n "$(type -P gh 2>/dev/null)" ] || die "gh is required to verify public CI evidence for readiness"
  head_full=$(git rev-parse --verify "${CAPTURE_HEAD}^{commit}" 2>/dev/null) \
    || die "cannot resolve the authoritative head $CAPTURE_HEAD for CI verification"
  view=$(gh pr view "$CAPTURE_PR" --json headRefOid,state,statusCheckRollup 2>/dev/null) \
    || die "cannot read public CI evidence for $CAPTURE_PR; readiness requires verified green checks"
  verdict=$(printf '%s' "$view" | jq -r --arg head "$head_full" '
    def name: .name // .context // "";
    def key: "\(.__typename)|\(.workflowName // "")|\(name)";
    def when: .startedAt // .createdAt // .completedAt // "";
    def green:
      if .__typename == "CheckRun" then
        .status == "COMPLETED"
        and (.conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED")
      elif .__typename == "StatusContext" then .state == "SUCCESS"
      else false end;
    def success:
      (.__typename == "CheckRun" and .conclusion == "SUCCESS")
      or (.__typename == "StatusContext" and .state == "SUCCESS");
    def describe: "\(name) (\(.status // .state // "unknown")/\(.conclusion // "none"))";
    (.statusCheckRollup) as $all
    | if ($all | type) != "array" then "refuse:the PR check rollup is missing or malformed"
      elif .headRefOid != $head then "refuse:the PR head \(.headRefOid // "unknown") is not the authoritative head \($head)"
      elif .state != "OPEN" then "refuse:the PR is \(.state // "in an unknown state"), not open"
      elif ($all | length) == 0 then "refuse:the PR reports zero CI checks; readiness requires at least one green check"
      elif ($all | length) >= 100 then "refuse:the PR reports \($all | length) checks, which may be a truncated rollup"
      elif any($all[]; (.__typename != "CheckRun" and .__typename != "StatusContext") or (name | length) == 0) then
        "refuse:the PR check rollup has an unrecognized or unnamed entry"
      else
        ($all | group_by(key) | map(sort_by(when) | last)) as $latest
        | [$latest[] | select(green | not) | describe] as $bad
        | if ($bad | length) > 0 then "refuse:public CI is not green: \($bad | join(", "))"
          elif any($latest[]; success) | not then "refuse:no PR check reports success"
          else "green:\($latest | length)" end
      end
  ') || die "public CI evidence for $CAPTURE_PR is not parseable"
  case "$verdict" in
    green:*) ;;
    refuse:*) die "${verdict#refuse:}" ;;
    *) die "public CI evidence for $CAPTURE_PR could not be classified" ;;
  esac
}

audit_ready() {
  local errors ci_logs marker
  command -v "$NM" >/dev/null 2>&1 || die "no-mistakes command is unavailable"
  command -v jq >/dev/null 2>&1 || die "jq is required"
  capture_public_history
  validate_capture_context
  store_ready_or_die
  prepare_work_files
  sync_ledger
  reconcile_all_rounds_for_audit "$(current_round_number)"

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
  verify_dispositions_against_resolution

  [ -n "$CAPTURE_PR" ] || die "axi status has no PR URL; readiness is not public"
  case "$CAPTURE_PR" in https://*) ;; *) die "axi status PR is not a full https URL: $CAPTURE_PR" ;; esac
  case "$CAPTURE_OUTCOME" in
    checks-passed) ;;
    failed|cancelled)
      die "authoritative validation run outcome is $CAPTURE_OUTCOME; historical CI evidence cannot authorize readiness"
      ;;
    passed|passed-with-override)
      die "authoritative validation run outcome is $CAPTURE_OUTCOME; the PR is no longer awaiting readiness"
      ;;
    "")
      # Accept both "ci" (pre-v1.60.2 no-mistakes TOON format) and "running"
      # (v1.60.2+ format, where the run status stays "running" during CI monitoring).
      [ "$CAPTURE_STATUS_VALUE" = ci ] || [ "$CAPTURE_STATUS_VALUE" = running ] \
        || die "authoritative validation run is not in the active CI monitor: ${CAPTURE_STATUS_VALUE:-unknown}"
      if ! ci_logs=$(nm_cli axi logs --run "$CAPTURE_RUN_ID" --step ci); then
        die "public CI log is unavailable for run $CAPTURE_RUN_ID"
      fi
      marker=$(printf '%s\n' "$ci_logs" \
        | grep -E 'CI checks passed|treating as all checks passed|no CI checks reported|checks failed|issues detected|CI checks running|base branch advanced.*re-arming CI monitor timeout' \
        | tail -1 || true)
      case "$marker" in
        *"no_ci"*|*"treating as all checks passed"*) die "the run treats a no_ci declaration as passing; readiness requires green public CI checks" ;;
        *"CI checks passed"*) ;;
        "") die "public CI history has no recognized readiness result" ;;
        *) die "latest public CI result is not green: $marker" ;;
      esac
      ;;
    *) die "authoritative validation run has unrecognized outcome: $CAPTURE_OUTCOME" ;;
  esac
  require_public_green_ci

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
NM_REPOS_DIR=${FM_NM_REPOS_DIR:-${HOME:-}/.no-mistakes/repos}
NM_STATE_DB=${FM_NM_STATE_DB:-${HOME:-}/.no-mistakes/state.sqlite}
IPC_BUDGET=${FM_NM_REVIEW_IPC_BUDGET:-60}
case "$IPC_BUDGET" in
  ''|*[!0-9]*) die "FM_NM_REVIEW_IPC_BUDGET must be a whole number of seconds" ;;
esac
[ "$IPC_BUDGET" -ge 1 ] || die "FM_NM_REVIEW_IPC_BUDGET must be at least 1 second"

case "${1:-}" in
  respond)
    acquire_review_lock
    review_lock_held_hooks
    respond "$@"
    ;;
  audit-ready)
    [ "$#" -eq 1 ] || die "audit-ready accepts no arguments"
    acquire_review_lock
    review_lock_held_hooks
    audit_ready
    ;;
  ledger-path) [ "$#" -eq 1 ] || die "ledger-path accepts no arguments"; printf '%s\n' "$LEDGER" ;;
  -h|--help) usage ;;
  "") usage >&2; exit 2 ;;
  *) die "unknown command: $1" ;;
esac
