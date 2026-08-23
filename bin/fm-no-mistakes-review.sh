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
# The per-round structured review result comes from one of two shapes, because
# review agents differ in what they echo to the review log:
#   - Structured-log agents (e.g. codex/gpt/pi) emit one JSON review object per
#     round into the review log; the guard reconstructs the round model from the
#     log, exactly as before.
#   - Prose-log agents (e.g. claude) narrate the review in prose and echo NO
#     per-round JSON object to the log. no-mistakes still records the authoritative
#     structured per-round result in its own durable state store, so when the
#     review log carries no structured object the guard sources the identical round
#     model READ-ONLY from that store's review rounds (~/.no-mistakes/state.sqlite,
#     overridable with FM_NM_STATE_DB). This read never writes to that store.
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
# from the worktree or that store the command refuses closed. This removes the
# manual per-round bare-repo fetch the worktree-isolation gap used to require.
# It invokes the underlying whole-step response only after every finding in the
# current review result has one explicit, uniform choice:
#   --fix     -> no-mistakes axi respond --step review --action fix --findings ...
#   --approve -> no-mistakes axi respond --step review --action approve
#   --reject  -> no-mistakes axi respond --step review --action skip
# A partial set, duplicate ID, unknown ID, or mixed choice is refused before the
# underlying response command and before any ledger write.
#
# no-mistakes axi respond sends a fast (~millisecond) response IPC and then
# FOREGROUND-DRIVES the run through push, PR, and GitHub CI with no client-side
# timeout, so the guard must never block on that whole drive while it holds the
# ledger lock. It backgrounds the respond client, waits only until the review gate
# leaves (proof the IPC has landed) or the bounded FM_NM_REVIEW_IPC_BUDGET elapses,
# then stops the client so the ledger lock is released promptly. Stopping the
# client only tears down the run observer; it never cancels the daemon's run
# (cancellation is a separate axi abort path), so the pipeline keeps driving CI in
# the background. A decision (approve/reject) is finalized the moment its gate is
# consumed, since it needs no CI; a fix leaves its durable attempting receipt in
# place (no premature landed-but-unconfirmed state) and is confirmed later by
# audit-ready or a later response through the same attempting->landed reconciliation
# the guard already applies to a crashed drive, from the next authoritative review
# result. If the client returns before the budget, the whole drive finished
# in-band and the response is finalized exactly as before. This narrows only how
# long the ledger lock is held (the fast IPC-landing window, never the CI drive);
# it does not weaken single-owner exclusion, receipt reconciliation, or the
# never-infer-a-decision-from-generic-completion guarantees below.
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
# An approve or reject the pipeline accepted is written straight to its final
# approved_as_is or rejected_or_skipped state in one ledger commit; it is never
# parked in an intermediate "requested" state a crash could strand.
# A selected fix is written requested, then confirmed only from public evidence:
# it becomes fixed_and_confirmed when the public review log contains both a
# completed fix round and the authoritative next structured review result AND the
# exact finding object does not survive unchanged into that result; otherwise it
# stays requested or becomes survived_unchanged and readiness refuses.
#
# Single-owner exclusion is proven solely by the host kernel's nonblocking
# advisory lock (flock on Linux, lockf on macOS/BSD) held for the entire guarded
# invocation. That proof is non-mintable: a contender cannot forge holding the
# lock, and the kernel releases it the instant the owning process exits for any
# reason, so a crashed owner never wedges the ledger. No PID, incarnation token,
# or on-disk owner record is consulted, so no forgeable ownership capability
# exists and PID reuse cannot impersonate a past owner. A concurrent invocation
# that cannot take the lock refuses and retries rather than entering, and if the
# kernel lock primitive is unavailable or unsupported the command refuses with a
# red diagnostic instead of proceeding without exclusion.
# The internal lock-held entry point re-proves that the guard is actively locked
# before touching the ledger by attempting a fresh non-blocking acquire: only the
# lock primitive's documented contention status means the guard is held (proceed),
# a successful acquire means it was free so a direct caller is refused, and any
# other probe error refuses closed rather than assuming an active lock.
# The response boundary is governed by a durable response receipt per run and
# round at:
#   <project-worktree>/.no-mistakes/.firstmate-review-receipt.<run-id>.<round>.json
# The guard writes this exact shape by same-directory atomic rename:
#   {"run":"<run-id>","branch":"<branch>","round":<integer>,
#   "action":"fix"|"approve"|"reject","findings":["<id>",...],
#   "attempt":<integer>,"head":"<commit>",
#   "phase":"attempting"|"landed"|"failed"}
# It records the exact action and findings in phase attempting BEFORE the
# underlying no-mistakes response runs, then records landed or failed after it
# returns, so a crash at any point leaves a reconcilable record rather than a
# silently accepted or permanently stranded finding.
# A fresh invocation reconciles outstanding receipts across every public round
# before acting, from authoritative evidence bound to the exact round and action.
# An in-process landed receipt directly proves the CLI returned zero and may be
# finalized idempotently. An attempting fix may be inferred landed only when a
# later authoritative review result and that round's committed-agent-fix marker
# both exist. Approve/reject are NEVER inferred landed from generic review, CI,
# or outcome completion because those cannot distinguish the recorded action from
# an out-of-band skip. A proven-unstarted or failed attempt may be retried while
# its gate remains open; every indeterminate or possibly in-flight state refuses.
# So a transient failure has a real recovery path (retry), while an unresolved
# finding is never finalized without evidence that this exact action landed.
# At most one invocation runs per attempt: each attempt claims an atomic
# O_CREAT|O_EXCL marker keyed by run, round, and attempt immediately before the
# CLI runs, and a retry uses the next attempt. Two serialized legitimate callers
# never both invoke, because the kernel guard makes the second observe a terminal
# receipt, not a live attempting one. The only residual is a caller that bypasses
# the kernel guard concurrently with a live responder; the per-attempt marker
# still binds each attempt to a single invocation, and any such actor already has
# write access to this private state directory and can rewrite the ledger outright.
# Every ledger write is a same-directory atomic rename, so a crash mid-write
# leaves the ledger at its prior or next complete state, never a partial one.
# Ledger commits also use optimistic concurrency: the content hash captured when
# a mutation reads the ledger is re-checked at the rename, and a changed ledger
# forces a recompute from the current contents instead of overwriting it. So a
# stale copy computed by a caller that bypassed the guard cannot clobber a
# concurrent append. One accepted residual remains at that boundary: the hash
# re-check and the rename are separate steps, leaving a sub-instruction window in
# which two concurrent committers could both see an unchanged ledger and both
# rename, losing one update. It is deliberately left open because a portable,
# crash-safe, truly atomic commit is not available in shell, and the legitimate
# path never reaches it -- it is fully serialized by the kernel guard, and any
# actor that could reach it already has write access to this state directory.
#
# audit-ready refreshes the append-only public review history, then reconciles
# outstanding response receipts across all rounds without invoking a response.
# It fills only a missing finalization for a landed action, requires
# action-specific public evidence for a detached fix, and refuses every unlanded
# or indeterminate attempt. It then refuses
# for missing or rewritten history, stale run/branch/head context, malformed or
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
# Environment:
#   FM_NM_REPOS_DIR                  overrides the no-mistakes per-run object-store
#                                    root used to import an isolated pipeline head
#                                    (default: ~/.no-mistakes/repos).
#   FM_NM_STATE_DB                   overrides the no-mistakes state store read
#                                    READ-ONLY for the structured review rounds when
#                                    the review log carries no per-round JSON object
#                                    (default: ~/.no-mistakes/state.sqlite).
#   FM_NM_REVIEW_IPC_BUDGET          maximum whole seconds to wait under the ledger
#                                    lock for the review gate to leave (the response
#                                    IPC to land) before refusing closed; the long
#                                    push/PR/CI drive is never awaited under the lock
#                                    (default: 60).
# Environment used by hermetic tests only:
#   FM_NM_REVIEW_STATE_DIR           overrides the ledger directory.
#   FM_NM_REVIEW_TEST_ACQUIRED       appends this PID once the kernel lock is held.
#   FM_NM_REVIEW_TEST_HOLD_FIFO      blocks the lock holder on a fixture FIFO.
#   FM_NM_REVIEW_TEST_CRASH_HOLDING  kills the holder just after it takes the lock.
#   FM_NM_REVIEW_TEST_NO_LOCKER      simulates an unavailable kernel lock primitive.
#   FM_NM_REVIEW_TEST_INFLIGHT_FIFO  blocks a responder after it claims the attempt marker.
#   FM_NM_REVIEW_TEST_LEDGER_COMMIT_FIFO  blocks a ledger mutation once before its first commit.
#   FM_NM_REVIEW_TEST_CRASH_BEFORE_RESPOND  kills a responder after it records the
#                                    attempting receipt but before the CLI runs.
#   FM_NM_REVIEW_TEST_CRASH_AFTER_RESPOND   kills a responder after the CLI lands but
#                                    before the receipt is marked landed.
set -eu

SCRIPT_NAME=${0##*/}
NM=${FM_NO_MISTAKES_BIN:-no-mistakes}
LOCK_GUARD=
LEDGER_COMMIT_HOOK_FIRED=0
WORK_FILE=
MODEL_FILE=
DRIVE_LOG=
RESP_PID=
DRIVE_RESULT=
DRIVE_RC=0
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
  # The kernel advisory lock is released automatically when this process exits,
  # so cleanup only removes this invocation's private temporary work files. It
  # never touches the shared guard file or any ownership artifact, so an exiting
  # or crashing owner can never remove a successor's lock.
  # A backgrounded response client is stopped too, so an interrupted guard never
  # leaves the run observer running; stopping it never cancels the daemon's run.
  if [ -n "$RESP_PID" ]; then
    kill -TERM "$RESP_PID" 2>/dev/null || true
    RESP_PID=
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

capture_review_model_from_state_store() {
  # Prose-log fallback source for the structured per-round review model. no-mistakes
  # records every review round's authoritative structured result (the same JSON
  # object a structured-log agent echoes to the review log) in its own state store,
  # so when the review log carries no per-round object the guard reads the identical
  # round model from that store. The read is strictly READ-ONLY (sqlite3 -readonly):
  # it never writes to, checkpoints, or otherwise mutates no-mistakes' state, and it
  # never contacts the network. It refuses closed when the tool, store, or a
  # completed review record is genuinely absent, so a missing or in-progress review
  # is never mistaken for a clean pass.
  local srid rstatus rounds_json
  command -v sqlite3 >/dev/null 2>&1 \
    || die "review log for run $CAPTURE_RUN_ID carries no structured result and sqlite3 is unavailable to read the authoritative review record"
  [ -f "$NM_STATE_DB" ] \
    || die "review log for run $CAPTURE_RUN_ID carries no structured result and the no-mistakes review record store is absent at $NM_STATE_DB"
  case "$CAPTURE_RUN_ID" in
    ''|*[!A-Za-z0-9._-]*) die "cannot read the review record for run id '$CAPTURE_RUN_ID'" ;;
  esac
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
  case "$rstatus" in
    completed|awaiting_approval) ;;
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

verify_guard_actively_locked() {
  # Non-mintable reentry proof for the internal lock-held entry point. It is
  # legitimate only when an ancestor run_with_kernel_lock already holds the guard
  # lock, so probe with a fresh non-blocking acquire: a failed acquire proves the
  # guard is actively held (proceed), while a successful acquire proves it was
  # free, meaning this process was invoked directly without the kernel lock
  # (refuse). A direct caller cannot forge a held lock, so the credential cannot
  # be minted. The probe keeps the guard file (-k) and never blocks (-t 0 / -n).
  local guard="$STATE_DIR/.firstmate-review-ledger.guard" probe_rc=0
  [ -e "$guard" ] \
    || die "review-ledger internal entry was invoked without the kernel guard; direct reentry is refused"
  [ -f "$guard" ] && [ ! -L "$guard" ] \
    || die "review-ledger kernel guard is not a regular private file"
  # Both probes report the documented contention status 75 when the guard is
  # already held; every other nonzero status is an operational failure (missing
  # or unreadable guard, permission error) and must refuse closed rather than be
  # mistaken for an active lock.
  case "$(uname -s 2>/dev/null || true)" in
    Darwin)
      command -v lockf >/dev/null 2>&1 \
        || die "lockf is required to verify crash-safe review-ledger exclusion on macOS"
      lockf -k -s -t 0 "$guard" true >/dev/null 2>&1 || probe_rc=$?
      ;;
    Linux)
      command -v flock >/dev/null 2>&1 \
        || die "flock is required to verify crash-safe review-ledger exclusion on Linux"
      flock -E 75 -n "$guard" -c true >/dev/null 2>&1 || probe_rc=$?
      ;;
    *) die "kernel-backed review-ledger exclusion is unsupported on this operating system" ;;
  esac
  case "$probe_rc" in
    75) ;;
    0) die "review-ledger internal entry was invoked without holding the kernel guard; direct reentry is refused" ;;
    *) die "review-ledger guard-lock probe failed (status $probe_rc); refusing internal entry rather than assuming an active lock" ;;
  esac
  LOCK_GUARD="$guard"
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

run_with_kernel_lock() {
  local rc=0
  prepare_guard_file
  if [ "${FM_NM_REVIEW_TEST_NO_LOCKER:-}" = 1 ]; then
    die "kernel-backed review-ledger exclusion is unavailable; refusing to proceed without single-owner exclusion"
  fi
  case "$(uname -s 2>/dev/null || true)" in
    Darwin)
      command -v lockf >/dev/null 2>&1 \
        || die "lockf is required for crash-safe review-ledger exclusion on macOS"
      lockf -k -s -t 0 "$LOCK_GUARD" "$SCRIPT_DIR/$SCRIPT_NAME" __fm_review_lock_held "$@" || rc=$?
      ;;
    Linux)
      command -v flock >/dev/null 2>&1 \
        || die "flock is required for crash-safe review-ledger exclusion on Linux"
      flock -E 75 -n "$LOCK_GUARD" "$SCRIPT_DIR/$SCRIPT_NAME" __fm_review_lock_held "$@" || rc=$?
      ;;
    *) die "kernel-backed review-ledger exclusion is unsupported on this operating system" ;;
  esac
  [ "$rc" -ne 75 ] || die "review ledger has a live owner; retry after the guarded invocation finishes"
  return "$rc"
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
  # otherwise we recompute from the now-current ledger. The legitimate path is
  # already serialized by the kernel guard, so this protects the append-preserving
  # invariant against a caller that reached the ledger by bypassing the guard.
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
    # Accepted residual: the hash re-check and the rename are separate steps, so
    # a check-to-rename window remains where two concurrent committers could both
    # observe an unchanged ledger and both rename, losing one update. This is
    # unreachable on the legitimate path, which is fully serialized by the kernel
    # guard, and is not closed further on purpose: a portable, crash-safe, truly
    # atomic commit is not available in shell (macOS has no in-process kernel lock
    # and there is no atomic compare-and-swap-on-content primitive). The only way
    # to reach the window is to invoke the undocumented internal entry point
    # directly while a legitimate responder is active and win a sub-instruction
    # race, and any actor able to do that already has write access to this state
    # directory and can rewrite or delete the ledger outright, so it adds no
    # practical exposure. See the header note for the full rationale.
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
    | .runs[$ri].rounds = [$rounds | to_entries[]
        | .key as $i
        | .value
        | if .fix_completed_after == true and ($i + 1) < ($rounds | length) then
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

receipt_file() {  # <round>
  case "$CAPTURE_RUN_ID" in
    ''|*[!A-Za-z0-9._-]*) die "cannot record a response receipt for run id '$CAPTURE_RUN_ID'" ;;
  esac
  printf '%s/.firstmate-review-receipt.%s.%s.json' "$STATE_DIR" "$CAPTURE_RUN_ID" "$1"
}

read_receipt() {  # <round>; prints the receipt JSON, or nothing when absent
  local f
  f=$(receipt_file "$1")
  [ -e "$f" ] || return 0
  [ -f "$f" ] && [ ! -L "$f" ] || die "review-ledger response receipt is not a regular private file"
  cat "$f"
}

write_receipt() {  # <round> <phase> <action> <findings-csv> <attempt> <head>
  local round=$1 phase=$2 action=$3 findings=$4 attempt=$5 head=$6 f tmp
  f=$(receipt_file "$round")
  [ ! -L "$f" ] || die "review-ledger response receipt must not be a symlink"
  tmp=$(mktemp "$STATE_DIR/.firstmate-review-receipt.XXXXXX") \
    || die "cannot allocate a response-receipt work file"
  jq -cn --arg run "$CAPTURE_RUN_ID" --arg branch "$CAPTURE_BRANCH" \
    --argjson round "$round" --arg phase "$phase" --arg action "$action" \
    --arg findings "$findings" --argjson attempt "$attempt" --arg head "$head" '
    {run: $run, branch: $branch, round: $round, action: $action,
     findings: ($findings | split(",") | map(select(length > 0))),
     attempt: $attempt, head: $head, phase: $phase}' > "$tmp" \
    || { rm -f "$tmp"; die "cannot render the response receipt"; }
  # Same-directory atomic rename: a crash leaves the prior or next complete
  # receipt, never a partial one. Serialized by the kernel guard, so no CAS.
  mv "$tmp" "$f" || { rm -f "$tmp"; die "cannot commit the response receipt"; }
}

review_step_status() {
  printf '%s\n' "$CAPTURE_STATUS" \
    | sed -n 's/^[[:space:]]*review,\([^,]*\),.*/\1/p' | head -1
}

response_landed_evidence() {  # <round> <kind>; prints landed | unlanded | ambiguous
  # Only a fix has public action-specific evidence: its round's committed-fix
  # marker followed by a later authoritative review result. Generic completion
  # can never prove that this process's approve/reject, rather than a skip, landed.
  local round=$1 kind=$2 fresh_rounds rstatus fix_marker
  capture_public_history
  validate_capture_context
  fresh_rounds=$(printf '%s' "$CAPTURE_MODEL" | jq '.rounds | length')
  rstatus=$(review_step_status)
  if [ "$kind" = fix ]; then
    fix_marker=$(printf '%s' "$CAPTURE_MODEL" | jq -r --argjson round "$round" \
      '.rounds[$round - 1].fix_completed_after // false')
    if [ "$fresh_rounds" -gt "$round" ] && [ "$fix_marker" = true ]; then
      printf landed
      return 0
    fi
  fi
  case "$rstatus" in
    awaiting_approval|fix_review|blocked|parked|awaiting_agent) printf unlanded; return 0 ;;
  esac
  [ "$CAPTURE_STATUS_VALUE" != review ] || { printf unlanded; return 0; }
  printf ambiguous
  return 0
}

attempt_marker_exists() {  # <round> <attempt>
  [ -e "$STATE_DIR/.firstmate-review-inflight.$CAPTURE_RUN_ID.$1.$2" ]
}

claim_attempt_marker() {  # <round> <attempt>
  # At most one invocation per attempt: an atomic O_CREAT|O_EXCL claim keyed by
  # run, round, and attempt, taken immediately before the CLI runs. A retry uses
  # the next attempt and so a fresh marker, while a second caller of the same
  # attempt -- however it entered -- cannot create the marker twice. Because the
  # claim precedes the invocation, an absent marker for an attempt proves the CLI
  # never ran for it, and a present one proves it may have.
  local round=$1 attempt=$2 marker
  marker="$STATE_DIR/.firstmate-review-inflight.$CAPTURE_RUN_ID.$round.$attempt"
  [ ! -L "$marker" ] || die "review-ledger in-flight marker must not be a symlink"
  if ! (umask 077; set -C; : > "$marker") 2>/dev/null; then
    die "a no-mistakes response for run $CAPTURE_RUN_ID round $round attempt $attempt is already in flight or completed; refusing a duplicate response"
  fi
  if [ -n "${FM_NM_REVIEW_TEST_INFLIGHT_FIFO:-}" ]; then
    IFS= read -r _inflight_release < "$FM_NM_REVIEW_TEST_INFLIGHT_FIFO" || true
  fi
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

finalize_fix_disposition() {  # <round>
  local round=$1 errors
  init_fix_dispositions "$round"
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
}

finalize_from_receipt() {  # <round> <kind>
  local round=$1 kind=$2
  case "$kind" in
    approve) ensure_uniform_disposition "$round" approve approved_as_is ;;
    reject) ensure_uniform_disposition "$round" reject rejected_or_skipped ;;
    fix) finalize_fix_disposition "$round" ;;
    *) die "internal finalize error for $kind" ;;
  esac
}

reconcile_response() {  # <kind> <round> <findings-csv>; sets RESPONSE_DECISION/RESPONSE_ATTEMPT
  local kind=$1 round=$2 selected_csv=$3 existing r_action r_findings r_phase r_attempt ev
  RESPONSE_DECISION=proceed
  RESPONSE_ATTEMPT=1
  existing=$(read_receipt "$round")
  [ -n "$existing" ] || return 0

  r_action=$(printf '%s' "$existing" | jq -r '.action // ""')
  r_findings=$(printf '%s' "$existing" | jq -r '.findings // [] | join(",")')
  r_phase=$(printf '%s' "$existing" | jq -r '.phase // ""')
  r_attempt=$(printf '%s' "$existing" | jq -r '.attempt // 0')
  [ "$r_action" = "$kind" ] && [ "$r_findings" = "$selected_csv" ] \
    || die "a different response ($r_action findings=$r_findings) is already recorded for run $CAPTURE_RUN_ID round $round; refusing to change the decision mid-flight"

  case "$r_phase" in
    landed)
      finalize_from_receipt "$round" "$kind"
      RESPONSE_DECISION=replay
      ;;
    attempting)
      ev=$(response_landed_evidence "$round" "$kind")
      case "$ev" in
        landed)
          write_receipt "$round" landed "$kind" "$selected_csv" "$r_attempt" "$CAPTURE_HEAD"
          finalize_from_receipt "$round" "$kind"
          RESPONSE_DECISION=replay
          ;;
        unlanded)
          # The gate is still open. Retry only when the attempt marker is absent,
          # which proves the CLI never ran for that attempt. If the marker is
          # present the CLI may have started and a detached response could still be
          # in flight, so refuse rather than risk a duplicate side effect.
          if attempt_marker_exists "$round" "$r_attempt"; then
            die "a prior response attempt for run $CAPTURE_RUN_ID round $round claimed the response but never confirmed it; a detached response may still be in flight -- resolve the pipeline state before retrying"
          fi
          RESPONSE_ATTEMPT=$((r_attempt + 1))
          ;;
        *) die "a prior response attempt for run $CAPTURE_RUN_ID round $round is in an indeterminate state and cannot be safely retried or confirmed; resolve the pipeline state and retry" ;;
      esac
      ;;
    failed)
      # A failed receipt is written only after the CLI returned nonzero, so the
      # attempt is proven done and unlanded and can be retried safely.
      ev=$(response_landed_evidence "$round" "$kind")
      case "$ev" in
        unlanded) RESPONSE_ATTEMPT=$((r_attempt + 1)) ;;
        landed) die "the review gate for run $CAPTURE_RUN_ID round $round closed after a failed response attempt; the failed action cannot be confirmed as landed -- resolve the pipeline state and retry" ;;
        *) die "a failed response attempt for run $CAPTURE_RUN_ID round $round is in an indeterminate state; resolve the pipeline state and retry" ;;
      esac
      ;;
    *) die "response receipt for run $CAPTURE_RUN_ID round $round has an unrecognized phase '$r_phase'" ;;
  esac
}

round_dispositions_count() {  # <round>
  jq -r --arg run "$CAPTURE_RUN_ID" --argjson round "$1" '
    [.runs[] | select(.id == $run) | .rounds[] | select(.round == $round) | .dispositions[]?] | length
  ' "$LEDGER"
}

reconcile_receipts_readonly() {  # <last-round>
  # Fill only missing finalizations and never invoke the CLI. Scanning every round
  # prevents a fix that advanced N to N+1 before crashing from being stranded.
  local last_round=$1 round=1 existing r_action r_findings r_phase r_attempt r_head ev
  while [ "$round" -le "$last_round" ]; do
    existing=$(read_receipt "$round")
    if [ -n "$existing" ]; then
      r_action=$(printf '%s' "$existing" | jq -r '.action // ""')
      r_findings=$(printf '%s' "$existing" | jq -r '.findings // [] | join(",")')
      r_phase=$(printf '%s' "$existing" | jq -r '.phase // ""')
      r_attempt=$(printf '%s' "$existing" | jq -r '.attempt // 0')
      r_head=$(printf '%s' "$existing" | jq -r '.head // ""')
      case "$r_phase" in
        landed)
          [ "$(round_dispositions_count "$round")" -gt 0 ] \
            || finalize_from_receipt "$round" "$r_action"
          ;;
        attempting)
          ev=$(response_landed_evidence "$round" "$r_action")
          case "$ev" in
            landed)
              write_receipt "$round" landed "$r_action" "$r_findings" "$r_attempt" "$r_head"
              [ "$(round_dispositions_count "$round")" -gt 0 ] \
                || finalize_from_receipt "$round" "$r_action"
              ;;
            *) die "an unconfirmed response attempt for run $CAPTURE_RUN_ID round $round is not landed; complete or retry it through the guarded response path before readiness" ;;
          esac
          ;;
        failed)
          die "a failed response attempt for run $CAPTURE_RUN_ID round $round has no confirmed disposition; retry it through the guarded response path before readiness"
          ;;
        *) die "response receipt for run $CAPTURE_RUN_ID round $round has an unrecognized phase '$r_phase'" ;;
      esac
    fi
    round=$((round + 1))
  done
}

review_gate_open_fresh() {
  # 0 (true) while the review step is still awaiting a response (the gate is open);
  # 1 (false) once the gate has left, i.e. the response IPC has landed and the run
  # advanced past the review step. It reads a fresh READ-ONLY axi status into
  # locals and never mutates the CAPTURE_* context the ledger finalize relies on.
  # An unavailable or unreadable status is treated as still-open so the caller
  # keeps waiting (up to its bounded budget) rather than declaring a premature land.
  local st rstatus topstatus
  st=$("$NM" axi status 2>/dev/null) || return 0
  rstatus=$(printf '%s\n' "$st" | sed -n 's/^[[:space:]]*review,\([^,]*\),.*/\1/p' | head -1)
  topstatus=$(printf '%s\n' "$st" | sed -n 's/^[[:space:]]*status:[[:space:]]*\(.*\)/\1/p' | head -1)
  topstatus=$(strip_value "$topstatus")
  case "$rstatus" in
    ''|awaiting_approval|fix_review|blocked|parked|awaiting_agent) return 0 ;;
  esac
  [ "$topstatus" = review ] && return 0
  return 1
}

launch_review_drive() {  # <kind> <selected-csv> <instructions>
  # Background the response client. It lands the fast IPC and then foreground-
  # drives push/PR/CI; we never await that drive under the ledger lock. Its
  # progress output goes to a private log, so it never pollutes the recorded line.
  local kind=$1 selected_csv=$2 instructions=$3
  case "$kind" in
    fix)
      if [ -n "$instructions" ]; then
        "$NM" axi respond --step review --action fix --findings "$selected_csv" --instructions "$instructions" >"$DRIVE_LOG" 2>&1 &
      else
        "$NM" axi respond --step review --action fix --findings "$selected_csv" >"$DRIVE_LOG" 2>&1 &
      fi
      ;;
    approve) "$NM" axi respond --step review --action approve >"$DRIVE_LOG" 2>&1 & ;;
    reject) "$NM" axi respond --step review --action skip >"$DRIVE_LOG" 2>&1 & ;;
    *) die "internal drive error for $kind" ;;
  esac
  RESP_PID=$!
}

stop_review_drive() {
  # Stop the backgrounded client so the ledger lock releases promptly. A killed
  # client only tears down the observer; the daemon's run keeps driving CI.
  [ -n "$RESP_PID" ] || return 0
  if kill -0 "$RESP_PID" 2>/dev/null; then
    kill -TERM "$RESP_PID" 2>/dev/null || true
    local spins=0
    while kill -0 "$RESP_PID" 2>/dev/null; do
      spins=$((spins + 1))
      if [ "$spins" -ge 25 ]; then kill -KILL "$RESP_PID" 2>/dev/null || true; break; fi
      sleep 0.2
    done
  fi
  wait "$RESP_PID" 2>/dev/null || true
  RESP_PID=
}

settle_review_drive() {
  # Wait only until the response IPC has landed (the review gate leaves) or the
  # bounded budget elapses, then stop the drive. Sets DRIVE_RESULT to:
  #   complete - the client returned 0 before the budget (whole drive finished);
  #   failed   - the client returned nonzero fast (IPC rejected), see DRIVE_RC;
  #   landed   - the gate left, proving the IPC landed, with the drive still going;
  #   timeout  - the gate never left within the budget (cannot confirm landing).
  # A client that lands the response and then returns almost immediately (the whole
  # drive was cheap, e.g. CI already green) races the gate-left observation, so once
  # the gate has left we grant a short grace for the client to exit naturally and
  # report complete/failed before concluding it is genuinely still driving CI.
  local waited=0 max_polls cli_rc=0 gate_left=0 grace=0 grace_max=10
  max_polls=$((IPC_BUDGET * 5))
  [ "$max_polls" -ge 1 ] || max_polls=1
  DRIVE_RESULT=
  DRIVE_RC=0
  while :; do
    if ! kill -0 "$RESP_PID" 2>/dev/null; then
      cli_rc=0
      wait "$RESP_PID" || cli_rc=$?
      RESP_PID=
      if [ "$cli_rc" -eq 0 ]; then DRIVE_RESULT=complete; else DRIVE_RESULT=failed; DRIVE_RC=$cli_rc; fi
      return 0
    fi
    if [ "$gate_left" -eq 0 ] && ! review_gate_open_fresh; then
      gate_left=1
    fi
    if [ "$gate_left" -eq 1 ]; then
      grace=$((grace + 1))
      if [ "$grace" -ge "$grace_max" ]; then DRIVE_RESULT=landed; break; fi
    else
      waited=$((waited + 1))
      if [ "$waited" -ge "$max_polls" ]; then DRIVE_RESULT=timeout; break; fi
    fi
    sleep 0.2
  done
  stop_review_drive
  return 0
}

respond() {
  local fix='' approve='' reject='' instructions='' want='' kind='' raw='' selected_csv round head_ok modes=0
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
  prepare_work_files
  sync_ledger
  round=$(current_round_number)
  head_ok=$(jq -r --arg run "$CAPTURE_RUN_ID" --argjson round "$round" '
    [.runs[] | select(.id == $run) | .rounds[] | select(.round == $round) | select(.head != null)] | length
  ' "$LEDGER") || die "cannot inspect current ledger round"
  [ "$head_ok" = 1 ] || die "current review round has no exact head context"
  selected_csv=$(printf '%s' "$SELECTED_JSON" | jq -r 'join(",")')

  # Resolve every older outstanding receipt before accepting a new round, then
  # reconcile this round for replay or a safe next attempt.
  [ "$round" -le 1 ] || reconcile_receipts_readonly "$((round - 1))"
  reconcile_response "$kind" "$round" "$selected_csv"
  if [ "$RESPONSE_DECISION" = replay ]; then
    printf 'recorded: run=%s round=%s action=%s findings=%s\n' \
      "$CAPTURE_RUN_ID" "$round" "$kind" "$selected_csv"
    return 0
  fi

  # Record intent BEFORE the side effect so a crash is reconcilable, then claim
  # this attempt's exclusive marker immediately before invoking the CLI.
  write_receipt "$round" attempting "$kind" "$selected_csv" "$RESPONSE_ATTEMPT" "$CAPTURE_HEAD"
  [ "${FM_NM_REVIEW_TEST_CRASH_BEFORE_RESPOND:-}" != 1 ] || kill -KILL "$$"
  claim_attempt_marker "$round" "$RESPONSE_ATTEMPT"

  # Land the response without ever awaiting the long push/PR/CI drive under the
  # ledger lock: background the client, wait only until the gate leaves or the
  # bounded budget elapses, then stop it (see settle_review_drive).
  DRIVE_LOG=$(mktemp "$STATE_DIR/.firstmate-review-drive.XXXXXX") \
    || die "cannot allocate a response drive log"
  launch_review_drive "$kind" "$selected_csv" "$instructions"
  settle_review_drive

  case "$DRIVE_RESULT" in
    failed)
      write_receipt "$round" failed "$kind" "$selected_csv" "$RESPONSE_ATTEMPT" "$CAPTURE_HEAD"
      die "underlying no-mistakes response failed with exit $DRIVE_RC; the attempt is recorded as unlanded and can be safely retried"
      ;;
    complete)
      # The client returned before the budget, so the whole drive finished in-band
      # (e.g. CI was already green). Finalize exactly as the pre-bounded path did.
      [ "${FM_NM_REVIEW_TEST_CRASH_AFTER_RESPOND:-}" != 1 ] || kill -KILL "$$"
      write_receipt "$round" landed "$kind" "$selected_csv" "$RESPONSE_ATTEMPT" "$CAPTURE_HEAD"
      finalize_from_receipt "$round" "$kind"
      printf 'recorded: run=%s round=%s action=%s findings=%s\n' \
        "$CAPTURE_RUN_ID" "$round" "$kind" "$selected_csv"
      ;;
    landed)
      # The review gate left, proving THIS invocation's IPC landed, while the CI
      # drive is still going in the background.
      case "$kind" in
        approve|reject)
          # A decision finalizes the moment its gate is consumed; it needs no CI.
          # The gate left immediately after THIS invocation sent this exact action
          # under the exclusive ledger lock and attempt marker, and a rejected IPC
          # returns fast (nonzero) rather than leaving the gate, so gate-left is
          # specific proof this action -- not an out-of-band skip -- landed. Record
          # the landed receipt and finalize now.
          write_receipt "$round" landed "$kind" "$selected_csv" "$RESPONSE_ATTEMPT" "$CAPTURE_HEAD"
          finalize_from_receipt "$round" "$kind"
          printf 'recorded: run=%s round=%s action=%s findings=%s\n' \
            "$CAPTURE_RUN_ID" "$round" "$kind" "$selected_csv"
          ;;
        fix)
          # A fix cannot be confirmed until the next authoritative review result
          # shows the finding did not survive, which the daemon produces later in
          # the background drive. Rather than record a premature landed receipt
          # whose dispositions are still unconfirmed, leave the durable attempting
          # receipt (and its attempt marker) exactly as written before launch: the
          # same attempting->landed reconciliation the guard already applies to a
          # crashed drive confirms it from that public evidence, run by audit-ready
          # or a later response. This preserves the invariant that a landed fix
          # receipt always has confirmed dispositions, so no landed-but-unconfirmed
          # intermediate state is ever created.
          printf 'recorded: run=%s round=%s action=%s findings=%s\n' \
            "$CAPTURE_RUN_ID" "$round" "$kind" "$selected_csv"
          printf '%s: the fix response landed; the pipeline is driving CI in the background. Confirm readiness with audit-ready.\n' \
            "$SCRIPT_NAME" >&2
          ;;
      esac
      ;;
    timeout)
      # The gate never left within the budget, so the IPC landing is unconfirmed.
      # Leave the attempting receipt and its attempt marker in place so a later
      # response or audit-ready reconciles from authoritative evidence rather than
      # recording an unproven landing.
      die "the no-mistakes response was sent but the review gate did not leave within ${IPC_BUDGET}s; a detached response may still be in flight -- resolve the pipeline state and retry"
      ;;
    *) die "internal drive-settle error: ${DRIVE_RESULT:-unknown}" ;;
  esac
}

audit_ready() {
  local errors ci_logs marker
  command -v "$NM" >/dev/null 2>&1 || die "no-mistakes command is unavailable"
  command -v jq >/dev/null 2>&1 || die "jq is required"
  capture_public_history
  validate_capture_context
  prepare_work_files
  sync_ledger
  reconcile_receipts_readonly "$(current_round_number)"

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
NM_REPOS_DIR=${FM_NM_REPOS_DIR:-${HOME:-}/.no-mistakes/repos}
NM_STATE_DB=${FM_NM_STATE_DB:-${HOME:-}/.no-mistakes/state.sqlite}
IPC_BUDGET=${FM_NM_REVIEW_IPC_BUDGET:-60}
case "$IPC_BUDGET" in
  ''|*[!0-9]*) die "FM_NM_REVIEW_IPC_BUDGET must be a whole number of seconds" ;;
esac
[ "$IPC_BUDGET" -ge 1 ] || die "FM_NM_REVIEW_IPC_BUDGET must be at least 1 second"

case "${1:-}" in
  respond|audit-ready)
    guarded_command=$1
    shift
    run_with_kernel_lock "$guarded_command" "$@"
    ;;
  __fm_review_lock_held)
    shift
    verify_guard_actively_locked
    review_lock_held_hooks
    case "${1:-}" in
      respond) respond "$@" ;;
      audit-ready) [ "$#" -eq 1 ] || die "audit-ready accepts no arguments"; audit_ready ;;
      *) die "invalid guarded review-ledger command" ;;
    esac
    ;;
  ledger-path) [ "$#" -eq 1 ] || die "ledger-path accepts no arguments"; printf '%s\n' "$LEDGER" ;;
  -h|--help) usage ;;
  "") usage >&2; exit 2 ;;
  *) die "unknown command: $1" ;;
esac
