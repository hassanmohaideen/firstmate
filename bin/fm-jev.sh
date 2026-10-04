#!/usr/bin/env bash
# fm-jev.sh - optional TypeSafe Jev second opinion for crewmate and scout
# dispatch intake. Advisory-only, fail-open, and data-only.
#
# Firstmate MAY consult this at crewmate or scout intake, AFTER it has formed its
# own dispatch-rule and effort choice, as a calibrated second opinion. Nothing
# applies the output automatically: firstmate keeps choosing the rule and effort
# with judgment, records whether it followed the advice with `record`, and the
# rest of dispatch is unchanged. The operating protocol lives in
# .agents/skills/harness-adapters/SKILL.md ("Optional Jev dispatch second
# opinion"); docs/configuration.md owns the config/typesafe.env schema.
#
# Hard exclusions. This script exposes only the fixed advisory subcommands below
# with code-owned questions; it has no generic question surface, and it must
# never be consulted for, or called from:
#   - merge approval, PR readiness, or review-gate findings;
#   - ask-user finding dispositions;
#   - destructive, irreversible, or security-sensitive determinations;
#   - quota-array profile selection (it ranks rules, never a profile array's
#     candidates; quota-array-dispatch still owns that choice);
#   - watcher, away-mode, supervision, wake-drain, or session-startup paths.
#
# Fail-open contract. A missing key, an unsafe key file, a refused endpoint, a
# network failure, a timeout (FM_JEV_TIMEOUT seconds, default 4, clamped 1-10),
# a non-200 status, a malformed response, or an unexpected answering model all
# print exactly one `JEV_UNAVAILABLE: <reason>` line and exit 0, so dispatch
# proceeds exactly as it would without this script. There are no retries.
#
# Secrecy. The API key comes from the TYPESAFE_API_KEY environment variable when
# set and non-empty, otherwise from the TYPESAFE_API_KEY= line in
# $FM_HOME/config/typesafe.env (or $FM_CONFIG_OVERRIDE/typesafe.env), which must
# be a regular, non-symlinked, single-linked, mode-0600 file. The key is never
# printed, logged, or passed on any argv: it reaches curl as a header on stdin,
# and curl runs with -q so no curlrc can add tracing.
#
# Data egress. dispatch-tier sends the bounded task text plus the `when` text of
# every effective dispatch rule; effort sends only the bounded task text. Never
# feed it captain preferences, learnings, status logs, pane text, or diffs.
#
# Audit log. Every advice call and every recorded decision appends one JSON line
# to the home-private $FM_HOME/state/jev-advice.jsonl (mode 0600, rotated once
# to jev-advice.jsonl.1 past FM_JEV_LOG_MAX_BYTES, default 1048576). Records
# carry the timestamp, task id, outcome, recommendation, confidences, latency,
# token usage, and a sha256 of the task text; they never carry the key or the
# task text itself.
#
# Usage:
#   fm-jev.sh status
#   fm-jev.sh probe
#   fm-jev.sh dispatch-tier --task-file <path|-> [--task-id <id>]
#   fm-jev.sh effort --task-file <path|-> [--task-id <id>]
#   fm-jev.sh record --task-id <id> --tier <label|none> --effort <effort> \
#                    --followed yes|no|partial [--reason <text>]
#   fm-jev.sh report
#
# Subcommands:
#   status         no network; prints key presence and source, the pinned model,
#                  the log path, and the log record count
#   probe          checks key presence and API reachability with an
#                  authenticated GET /v1/models
#   dispatch-tier  ranks the effective dispatch rules from config/crew-dispatch.json
#                  (labels local-N) and defaults/crew-dispatch.json (labels
#                  tracked-N), plus `none` for "no rule fits, use the default";
#                  prints the recommended tier, effort, and confidences as data
#   effort         rates approach ambiguity only and prints the matching
#                  generic-fallback effort (low|medium|high|xhigh, never max)
#   record         appends firstmate's actual choice and whether it followed the
#                  advice, so `report` can compare advice with decisions
#   report         summarizes availability, latency, and agreement or
#                  disagreement between the latest advice and decision per task
#
# Output: key=value lines. The first line of an advice call is either
# `jev=ok ...` or a single `JEV_UNAVAILABLE: <reason>` line.
#
# Exit status: 0 whenever an advisory, status, probe, record, or report line is
# printed (including every unavailable outcome); 2 on a usage error.
#
# Environment:
#   TYPESAFE_API_KEY       key override; never printed
#   FM_JEV_MODEL           model id, default jev-1.13.0 (pinned, never an alias)
#   FM_JEV_TIMEOUT         whole-request bound in seconds (default 4, 1-10)
#   FM_JEV_BASE_URL        API base, default https://api.typesafe.ai; only an
#                          https host or plain http to localhost/127.0.0.1
#                          (tests), each with an optional port and nothing else
#   FM_JEV_MAX_TASK_BYTES  task text bound sent to the API (default 24000)
#   FM_JEV_LOG_MAX_BYTES   log rotation threshold (default 1048576)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-dispatch-config-lib.sh
. "$SCRIPT_DIR/fm-dispatch-config-lib.sh"

KEY_FILE="$CONFIG/typesafe.env"
LOG="$STATE/jev-advice.jsonl"
MODEL="${FM_JEV_MODEL:-jev-1.13.0}"
BASE_URL="${FM_JEV_BASE_URL:-https://api.typesafe.ai}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die_usage() {
  printf 'fm-jev: %s\n' "$*" >&2
  printf 'Run fm-jev.sh --help for usage.\n' >&2
  exit 2
}

positive_int_or() {
  case "${1:-}" in
    ''|*[!0-9]*|0) printf '%s\n' "$2" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

TIMEOUT=$(positive_int_or "${FM_JEV_TIMEOUT:-}" 4)
[ "$TIMEOUT" -le 10 ] || TIMEOUT=10
MAX_TASK_BYTES=$(positive_int_or "${FM_JEV_MAX_TASK_BYTES:-}" 24000)
LOG_MAX_BYTES=$(positive_int_or "${FM_JEV_LOG_MAX_BYTES:-}" 1048576)

TMP=
cleanup() { [ -z "$TMP" ] || rm -rf -- "$TMP"; }
trap cleanup EXIT

make_tmp() {
  [ -n "$TMP" ] && return 0
  TMP=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-jev.XXXXXX") || return 1
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- key loading -------------------------------------------------------------

private_file() {
  local path=$1 mode links
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  mode=$(stat -f %Lp "$path" 2>/dev/null || true)
  case "$mode" in
    ''|*[!0-9]*)
      links=$(stat -c %h "$path" 2>/dev/null) || return 1
      mode=$(stat -c %a "$path" 2>/dev/null) || return 1
      ;;
    *) links=$(stat -f %l "$path" 2>/dev/null) || return 1 ;;
  esac
  [ "$links" = 1 ] && [ "$mode" = 600 ]
}

# Sets KEY and KEY_SOURCE (env|file), or KEY_PROBLEM on failure. Never prints.
KEY=
KEY_SOURCE=none
KEY_PROBLEM=
load_key() {
  local line value found=0
  KEY=
  KEY_SOURCE=none
  KEY_PROBLEM=
  if [ -n "${TYPESAFE_API_KEY:-}" ]; then
    value=$TYPESAFE_API_KEY
    KEY_SOURCE="env"
  else
    if [ ! -e "$KEY_FILE" ] && [ ! -L "$KEY_FILE" ]; then
      KEY_PROBLEM="no key configured (config/typesafe.env absent and TYPESAFE_API_KEY unset)"
      return 1
    fi
    if ! private_file "$KEY_FILE"; then
      KEY_PROBLEM="config/typesafe.env must be a regular, single-linked, mode-0600 file; key not read"
      return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%$'\r'}
      case "$line" in
        TYPESAFE_API_KEY=*)
          value=${line#TYPESAFE_API_KEY=}
          found=1
          ;;
      esac
    done < "$KEY_FILE"
    if [ "$found" != 1 ]; then
      KEY_PROBLEM="config/typesafe.env has no TYPESAFE_API_KEY= line"
      return 1
    fi
    case "$value" in
      \"*\") value=${value#\"}; value=${value%\"} ;;
      \'*\') value=${value#\'}; value=${value%\'} ;;
    esac
    KEY_SOURCE="file"
  fi
  if [ -z "$value" ]; then
    KEY_PROBLEM="TYPESAFE_API_KEY is empty"
    KEY_SOURCE=none
    return 1
  fi
  if [ "${#value}" -lt 8 ] || [ "${#value}" -gt 512 ] || [[ ! "$value" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; then
    KEY_PROBLEM="TYPESAFE_API_KEY is malformed (value not shown)"
    return 1
  fi
  KEY=$value
}

# The authority must be a bare host with an optional numeric port: no userinfo,
# path, query, or other characters, so `http://localhost:1@remote.example`
# can never send the key in cleartext to a remote host.
base_url_allowed() {
  [[ "$BASE_URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] \
    || [[ "$BASE_URL" =~ ^http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?$ ]]
}

# --- logging -----------------------------------------------------------------

log_append() {
  local record=$1 size
  [ -n "$record" ] || return 0
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  if [ -L "$LOG" ] || { [ -e "$LOG" ] && [ ! -f "$LOG" ]; }; then
    return 0
  fi
  if [ -f "$LOG" ]; then
    size=$(wc -c < "$LOG" 2>/dev/null | tr -d ' ')
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    if [ "$size" -ge "$LOG_MAX_BYTES" ]; then
      mv -f -- "$LOG" "$LOG.1" 2>/dev/null || true
    fi
  fi
  (umask 077; printf '%s\n' "$record" >> "$LOG") 2>/dev/null || return 0
  chmod 600 "$LOG" 2>/dev/null || true
}

TASK_ID=
TASK_SHA=
TASK_BYTES=0

log_unavailable() {
  local mode=$1 reason=$2
  log_append "$(jq -cn --arg ts "$(now_iso)" --arg mode "$mode" --arg id "$TASK_ID" \
    --arg reason "$reason" --arg sha "$TASK_SHA" --argjson bytes "${TASK_BYTES:-0}" \
    '{ts:$ts, kind:"advice", mode:$mode, task_id:$id, outcome:"unavailable", reason:$reason,
      task_sha256:$sha, task_bytes:$bytes}')"
}

unavailable() {
  local mode=$1 reason=$2
  printf 'JEV_UNAVAILABLE: %s\n' "$reason"
  [ "$mode" = probe ] || log_unavailable "$mode" "$reason"
  exit 0
}

# --- HTTP --------------------------------------------------------------------

# http_call <method> <path> <body-file|''> <out-file>; sets HTTP_CODE, LATENCY_MS,
# and CURL_RC. The key travels only as a header read from stdin.
HTTP_CODE=000
LATENCY_MS=0
CURL_RC=0
http_call() {
  local method=$1 path=$2 body=$3 out=$4 meta
  local -a args=(-q -sS --max-time "$TIMEOUT" --connect-timeout "$TIMEOUT"
    --max-filesize 1048576 -o "$out" -w '%{http_code} %{time_total}'
    -H @- -H 'Accept: application/json' -X "$method")
  if [ -n "$body" ]; then
    args+=(-H 'Content-Type: application/json' --data-binary "@$body")
  fi
  meta=$(printf 'Authorization: Bearer %s\n' "$KEY" | curl "${args[@]}" "$BASE_URL$path" 2>/dev/null)
  CURL_RC=$?
  HTTP_CODE=${meta%% *}
  case "$HTTP_CODE" in ''|*[!0-9]*) HTTP_CODE=000 ;; esac
  LATENCY_MS=$(awk -v t="${meta#* }" 'BEGIN { if (t + 0 == t) printf "%d", t * 1000; else print 0 }')
}

http_failure_reason() {
  if [ "$CURL_RC" = 28 ]; then
    printf 'timeout after %ss\n' "$TIMEOUT"
  elif [ "$CURL_RC" != 0 ] && [ "$HTTP_CODE" = 000 ]; then
    printf 'network error (curl exit %s)\n' "$CURL_RC"
  else
    case "$HTTP_CODE" in
      401|403) printf 'HTTP %s (key rejected)\n' "$HTTP_CODE" ;;
      422) printf 'HTTP 422 (request rejected by validation)\n' ;;
      429) printf 'HTTP 429 (rate limited)\n' ;;
      529) printf 'HTTP 529 (overloaded)\n' ;;
      *) printf 'HTTP %s\n' "$HTTP_CODE" ;;
    esac
  fi
}

# --- subcommands ---------------------------------------------------------------

log_record_count() {
  local n=0
  [ -f "$LOG" ] && n=$(wc -l < "$LOG" | tr -d ' ')
  printf '%s\n' "$n"
}

cmd_status() {
  [ "$#" -eq 0 ] || die_usage "status takes no arguments"
  if load_key; then
    printf 'jev=configured key=present key_source=%s model=%s\n' "$KEY_SOURCE" "$MODEL"
  else
    printf 'jev=disabled key=absent reason="%s" model=%s\n' "$KEY_PROBLEM" "$MODEL"
  fi
  printf 'log=%s records=%s\n' "$LOG" "$(log_record_count)"
  printf 'advisory=data-only fail_open=yes network=none\n'
}

require_tools() {
  local tool
  for tool in curl jq; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'JEV_UNAVAILABLE: %s is not installed\n' "$tool"; exit 0; }
  done
}

cmd_probe() {
  [ "$#" -eq 0 ] || die_usage "probe takes no arguments"
  require_tools
  load_key || unavailable probe "$KEY_PROBLEM"
  base_url_allowed || unavailable probe "refusing non-https API base URL"
  make_tmp || unavailable probe "cannot create a private temporary directory"
  http_call GET /v1/models '' "$TMP/models.json"
  if [ "$HTTP_CODE" != 200 ]; then
    unavailable probe "$(http_failure_reason)"
  fi
  local models
  models=$(jq -r '[(.data // .models // . | if type == "array" then .[] else empty end)
      | if type == "object" then (.id // .name // empty) else . end
      | select(type == "string")] | join(",")' "$TMP/models.json" 2>/dev/null) \
    || unavailable probe "malformed /v1/models response"
  printf 'jev=reachable http=200 latency_ms=%s key=present key_source=%s model=%s listed_models=%s\n' \
    "$LATENCY_MS" "$KEY_SOURCE" "$MODEL" "${models:-none}"
}

TASK_FILE=
parse_advice_args() {
  local mode=$1
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task-file) [ "$#" -ge 2 ] || die_usage "--task-file needs a value"; TASK_FILE=$2; shift 2 ;;
      --task-id) [ "$#" -ge 2 ] || die_usage "--task-id needs a value"; TASK_ID=$2; shift 2 ;;
      *) die_usage "unknown $mode argument: $1" ;;
    esac
  done
  [ -n "$TASK_FILE" ] || die_usage "$mode requires --task-file <path|->"
  valid_task_id "$TASK_ID" || die_usage "--task-id must match [A-Za-z0-9._-]{1,128}"
}

valid_task_id() {
  [ -z "$1" ] || [[ "$1" =~ ^[A-Za-z0-9._-]{1,128}$ ]]
}

# Reads the bounded task text into $TMP/task.txt and sets TASK_SHA/TASK_BYTES.
read_task() {
  local mode=$1
  if [ "$TASK_FILE" = - ]; then
    head -c "$MAX_TASK_BYTES" > "$TMP/task.txt" || unavailable "$mode" "cannot read task text from stdin"
  else
    [ -f "$TASK_FILE" ] && [ -r "$TASK_FILE" ] || unavailable "$mode" "task file is not a readable regular file"
    head -c "$MAX_TASK_BYTES" < "$TASK_FILE" > "$TMP/task.txt" || unavailable "$mode" "cannot read task file"
  fi
  TASK_BYTES=$(wc -c < "$TMP/task.txt" | tr -d ' ')
  if ! grep -q '[^[:space:]]' "$TMP/task.txt"; then
    unavailable "$mode" "task text is empty"
  fi
  TASK_SHA=$( { shasum -a 256 2>/dev/null || sha256sum; } < "$TMP/task.txt" | awk '{print $1}')
}

# Writes the effective rules as a JSON array to $TMP/rules.json:
# [{label, when, effort, profiles}] with local rules first, and the effective
# top-level default as {effort, profiles} (or null) to $TMP/default.json.
collect_rules() {
  local path label prefix
  printf '[]' > "$TMP/rules.json"
  printf 'null' > "$TMP/default.json"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    label=$(fm_dispatch_config_label "$path" "$CONFIG" "$FM_ROOT")
    case "$label" in
      config/crew-dispatch.json) prefix=local ;;
      defaults/crew-dispatch.json) prefix=tracked ;;
      *) prefix=other ;;
    esac
    jq -c --arg prefix "$prefix" --slurpfile acc "$TMP/rules.json" '
      $acc[0] + [(.rules // []) | to_entries[]
        | select((.value.when | type) == "string" and (.value.when | length) > 0)
        | {label: "\($prefix)-\(.key + 1)", when: .value.when,
           effort: (if (.value.use | type) == "object" then (.value.use.effort // null) else null end),
           profiles: (if (.value.use | type) == "array" then "array" else "single" end)}]
    ' "$path" > "$TMP/rules.next" 2>/dev/null || return 1
    mv -f "$TMP/rules.next" "$TMP/rules.json"
    jq -c --slurpfile acc "$TMP/default.json" '
      if $acc[0] != null or (has("default") | not) then $acc[0]
      else {effort: (if (.default | type) == "object" then (.default.effort // null) else null end),
            profiles: (if (.default | type) == "array" then "array" else "single" end)} end
    ' "$path" > "$TMP/default.next" 2>/dev/null || return 1
    mv -f "$TMP/default.next" "$TMP/default.json"
  done < <(fm_dispatch_config_paths "$CONFIG" "$FM_ROOT")
}

# shellcheck disable=SC2016 # Backticks are TypeSafe field references, not shell.
AMBIGUITY_QUESTION='{
  "type": "score",
  "instructions": "How unresolved or ambiguous is the approach for the software task in `task`? Rate the uncertainty of how to do it, not its size.",
  "criteria": [
    "Mechanical or well-understood work with an explicit, bounded path",
    "Bounded work whose approach is settled but which needs real engineering depth",
    "Significant complexity, uncertainty, or blast radius; the approach is mostly but not fully settled",
    "Genuinely ambiguous investigation or design whose answer could change what gets built"
  ]
}'

build_request() {
  local mode=$1
  if [ "$mode" = dispatch-tier ]; then
    jq -n --rawfile task "$TMP/task.txt" --slurpfile rules "$TMP/rules.json" \
      --arg model "$MODEL" --argjson amb "$AMBIGUITY_QUESTION" '
      ($rules[0]) as $r
      | {model: $model, state: {task: $task},
         questions: ({
           tier: {type: "choice",
             instructions: "Which dispatch rule condition best describes the software task in `task`? Choose none only when no condition fits.",
             criteria: ([$r[] | {(.label): .when}] | add
               + {none: "No listed condition fits this task; use the default profile."})},
           ambiguity: $amb}
           + ([$r[] | {("fits:" + .label): {type: "noul",
               instructions: {condition: .when,
                 question: "Does the software task in `task` meet the dispatch condition in `condition`?"}}}] | add))}'
  else
    jq -n --rawfile task "$TMP/task.txt" --arg model "$MODEL" --argjson amb "$AMBIGUITY_QUESTION" \
      '{model: $model, state: {task: $task}, questions: {ambiguity: $amb}}'
  fi
}

# Validates the response and prints the derived summary JSON, or fails.
summarize_response() {
  local mode=$1
  jq -ce --arg model "$MODEL" --arg mode "$mode" --slurpfile rules "$TMP/rules.json" \
    --slurpfile default "$TMP/default.json" '
    def num: type == "number";
    def effort_for($score): ["low", "medium", "high", "xhigh"][
      ([([($score + 0.5) | floor, 0] | max), 3] | min)];
    select(type == "object" and .model == $model and (.answers | type) == "object")
    | .answers.ambiguity as $a
    | select($a.type == "score" and ($a.score | num) and ($a.confidence | num))
    | effort_for($a.score) as $ambiguity_effort
    | {model: .model, input_tokens: (.usage.input_tokens // null),
       ambiguity_score: $a.score, ambiguity_confidence: $a.confidence,
       ambiguity_effort: $ambiguity_effort}
    + (if $mode != "dispatch-tier" then {} else
        .answers as $ans
        | $ans.tier as $t
        | select($t.type == "choice" and ($t.choice | type) == "string"
                 and ($t.probabilities | type) == "object" and ($t.confidence | num))
        | ($rules[0]) as $r
        | select($t.choice == "none" or any($r[]; .label == $t.choice))
        | (if $t.choice == "none" then $default[0]
           else [$r[] | select(.label == $t.choice)][0] end) as $chosen
        | {recommended_tier: $t.choice, tier_confidence: $t.confidence,
           tier_profiles: ($chosen.profiles // "default"),
           rules: [$r[] | {label, choice_p: ($t.probabilities[.label] // 0),
                     fits_p: ($ans["fits:" + .label].noul // null), when}],
           none_p: ($t.probabilities.none // 0)}
        | . + (if ($chosen.effort // null) != null
               then {recommended_effort: $chosen.effort, effort_source: "rule"}
               else {recommended_effort: $ambiguity_effort, effort_source: "ambiguity"} end)
      end)' "$TMP/response.json" 2>/dev/null
}

cmd_advice() {
  local mode=$1
  shift
  parse_advice_args "$mode" "$@"
  require_tools
  make_tmp || unavailable "$mode" "cannot create a private temporary directory"
  read_task "$mode"
  load_key || unavailable "$mode" "$KEY_PROBLEM"
  base_url_allowed || unavailable "$mode" "refusing non-https API base URL"
  if [ "$mode" = dispatch-tier ]; then
    collect_rules || unavailable "$mode" "dispatch config unreadable (run bootstrap for the CREW_DISPATCH diagnostic)"
    [ "$(jq 'length' "$TMP/rules.json")" -gt 0 ] || unavailable "$mode" "no dispatch rules to rank"
  else
    printf '[]' > "$TMP/rules.json"
    printf 'null' > "$TMP/default.json"
  fi
  build_request "$mode" > "$TMP/request.json" || unavailable "$mode" "cannot build the request"
  http_call POST /v1/systemone "$TMP/request.json" "$TMP/response.json"
  [ "$HTTP_CODE" = 200 ] || unavailable "$mode" "$(http_failure_reason)"
  local summary
  summary=$(summarize_response "$mode") || unavailable "$mode" "malformed or unexpected response"
  [ -n "$summary" ] || unavailable "$mode" "malformed or unexpected response"

  printf '%s' "$summary" | jq -r --arg mode "$mode" --arg id "${TASK_ID:-none}" --arg lat "$LATENCY_MS" '
    def f: if type == "number" then (. * 100 | round / 100 | tostring) else "n/a" end;
    "jev=ok mode=\($mode) task_id=\($id) model=\(.model) latency_ms=\($lat) input_tokens=\(.input_tokens // "n/a")",
    (if $mode == "dispatch-tier" then
      "recommended_tier=\(.recommended_tier) tier_confidence=\(.tier_confidence | f) recommended_effort=\(.recommended_effort) effort_source=\(.effort_source) profiles=\(.tier_profiles)",
      (.rules[] | "tier \(.label) choice_p=\(.choice_p | f) fits_p=\(.fits_p | f) when=\"\(.when | gsub("[\r\n\t\"]"; " ") | .[0:90])\""),
      "tier none choice_p=\(.none_p | f)"
    else empty end),
    "ambiguity score=\(.ambiguity_score | f) confidence=\(.ambiguity_confidence | f) fallback_effort=\(.ambiguity_effort)",
    "advisory=data-only: firstmate decides; record the actual choice with fm-jev.sh record"'

  log_append "$(printf '%s' "$summary" | jq -c --arg ts "$(now_iso)" --arg mode "$mode" \
    --arg id "$TASK_ID" --argjson lat "$LATENCY_MS" --arg sha "$TASK_SHA" --argjson bytes "$TASK_BYTES" '
    {ts: $ts, kind: "advice", mode: $mode, task_id: $id, outcome: "ok", model,
     recommended_tier: (.recommended_tier // null), tier_confidence: (.tier_confidence // null),
     recommended_effort: (.recommended_effort // .ambiguity_effort),
     effort_source: (.effort_source // "ambiguity"),
     ambiguity_score, ambiguity_confidence,
     tier_probabilities: (if .rules then ([.rules[] | {(.label): .choice_p}] | add) + {none: .none_p} else null end),
     latency_ms: $lat, input_tokens, task_sha256: $sha, task_bytes: $bytes}')"
}

cmd_record() {
  local tier='' effort='' followed='' reason=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task-id) [ "$#" -ge 2 ] || die_usage "--task-id needs a value"; TASK_ID=$2; shift 2 ;;
      --tier) [ "$#" -ge 2 ] || die_usage "--tier needs a value"; tier=$2; shift 2 ;;
      --effort) [ "$#" -ge 2 ] || die_usage "--effort needs a value"; effort=$2; shift 2 ;;
      --followed) [ "$#" -ge 2 ] || die_usage "--followed needs a value"; followed=$2; shift 2 ;;
      --reason) [ "$#" -ge 2 ] || die_usage "--reason needs a value"; reason=$2; shift 2 ;;
      *) die_usage "unknown record argument: $1" ;;
    esac
  done
  if [ -z "$TASK_ID" ] || ! valid_task_id "$TASK_ID"; then
    die_usage "record requires --task-id matching [A-Za-z0-9._-]{1,128}"
  fi
  [[ "$tier" =~ ^(none|[a-z]+-[0-9]+)$ ]] || die_usage "--tier must be a rule label such as local-2 or tracked-6, or none"
  case "$effort" in low|medium|high|xhigh|max|none) ;; *) die_usage "--effort must be low|medium|high|xhigh|max|none" ;; esac
  case "$followed" in yes|no|partial) ;; *) die_usage "--followed must be yes|no|partial" ;; esac
  reason=$(printf '%s' "$reason" | tr '\r\n\t' '   ' | cut -c1-200)
  log_append "$(jq -cn --arg ts "$(now_iso)" --arg id "$TASK_ID" --arg tier "$tier" \
    --arg effort "$effort" --arg followed "$followed" --arg reason "$reason" \
    '{ts: $ts, kind: "decision", task_id: $id, chosen_tier: $tier, chosen_effort: $effort,
      followed: $followed, reason: $reason}')"
  printf 'recorded task_id=%s chosen_tier=%s chosen_effort=%s followed=%s\n' "$TASK_ID" "$tier" "$effort" "$followed"
}

cmd_report() {
  [ "$#" -eq 0 ] || die_usage "report takes no arguments"
  local -a files=()
  [ -f "$LOG.1" ] && files+=("$LOG.1")
  [ -f "$LOG" ] && files+=("$LOG")
  if [ "${#files[@]}" -eq 0 ]; then
    printf 'jev_report advice_calls=0 decisions=0 log=%s\n' "$LOG"
    return 0
  fi
  cat "${files[@]}" | jq -R 'fromjson? // empty' | jq -rs '
    def f: if type == "number" then (. * 100 | round / 100 | tostring) else "n/a" end;
    def median: sort | if length == 0 then null else .[(length / 2) | floor] end;
    [.[] | select(.kind == "advice")] as $adv
    | [$adv[] | select(.outcome == "ok")] as $ok
    | [.[] | select(.kind == "decision")] as $dec
    | ($ok | map(select(.mode == "dispatch-tier" and .task_id != "")) | group_by(.task_id) | map(last)) as $tiers
    | ($dec | group_by(.task_id) | map(last) | map({(.task_id): .}) | add // {}) as $dmap
    | [$tiers[] | . as $a | $dmap[$a.task_id] as $d | select($d != null)
        | {task_id, rec: .recommended_tier, conf: .tier_confidence, rec_effort: .recommended_effort,
           chosen: $d.chosen_tier, chosen_effort: $d.chosen_effort, followed: $d.followed,
           tier_agree: (.recommended_tier == $d.chosen_tier),
           effort_agree: (.recommended_effort == $d.chosen_effort)}] as $pairs
    | def rate($xs): if ($xs | length) == 0 then "n/a" else "\([$xs[] | select(.tier_agree)] | length)/\($xs | length)" end;
    "jev_report advice_calls=\($adv | length) ok=\($ok | length) unavailable=\(($adv | length) - ($ok | length)) decisions=\($dec | length) median_latency_ms=\([$ok[].latency_ms | select(type == "number")] | median // "n/a")",
    "comparisons=\($pairs | length) tier_agree=\([$pairs[] | select(.tier_agree)] | length) tier_disagree=\([$pairs[] | select(.tier_agree | not)] | length) effort_agree=\([$pairs[] | select(.effort_agree)] | length) effort_disagree=\([$pairs[] | select(.effort_agree | not)] | length)",
    "followed yes=\([$pairs[] | select(.followed == "yes")] | length) partial=\([$pairs[] | select(.followed == "partial")] | length) no=\([$pairs[] | select(.followed == "no")] | length)",
    "tier_agreement high_confidence(>=0.7)=\(rate([$pairs[] | select((.conf // 0) >= 0.7)])) low_confidence(<0.7)=\(rate([$pairs[] | select((.conf // 0) < 0.7)]))",
    "advice_without_decision=\([$tiers[] | select($dmap[.task_id] == null)] | length)",
    ([$adv[] | select(.outcome == "unavailable") | .reason] | group_by(.) | .[] | "unavailable_reason count=\(length) reason=\"\(.[0])\""),
    ($pairs[] | select((.tier_agree and .effort_agree) | not)
      | "disagreement task_id=\(.task_id) jev=\(.rec)/\(.rec_effort)@\(.conf | f) chosen=\(.chosen)/\(.chosen_effort) followed=\(.followed)")'
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  status) shift; cmd_status "$@" ;;
  probe) shift; cmd_probe "$@" ;;
  dispatch-tier) shift; cmd_advice dispatch-tier "$@" ;;
  effort) shift; cmd_advice effort "$@" ;;
  record) shift; cmd_record "$@" ;;
  report) shift; cmd_report "$@" ;;
  '') usage >&2; exit 2 ;;
  *) die_usage "unknown subcommand: $1 (only status, probe, dispatch-tier, effort, record, report exist)" ;;
esac
