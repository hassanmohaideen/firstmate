#!/usr/bin/env bash
# Bind longer-running Firstmate work to one self-hosted Discord request and
# deliver exactly one public-safe terminal reply through the original message.
#
# Usage:
#   bin/fm-discord-followup.sh link <task-id> <message-id>
#   bin/fm-discord-followup.sh check <task-id>
#   bin/fm-discord-followup.sh final <task-id> --text-file <path|->
#
# link records discord_request= and discord_request_ts= in the task's existing
# metadata after revalidating the private reply context. check prints the bound
# message id only while that binding remains usable. final posts with the direct
# Discord reply helper and atomically clears only the exact binding it sent.
# This is a narrow terminal-return binding, not another task lifecycle or public
# commitment state machine.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
NODE_BIN="${FM_DISCORD_NODE_BIN:-$(command -v node 2>/dev/null || true)}"

# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  bin/fm-discord-followup.sh link <task-id> <message-id>
  bin/fm-discord-followup.sh check <task-id>
  bin/fm-discord-followup.sh final <task-id> --text-file <path|->
EOF
  exit 2
}

safe_task() {
  case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 64 ]
}

safe_message() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -ge 15 ] && [ "${#1}" -le 22 ]
}

single_link_regular() {
  local path=$1 links
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    links=$(stat -f %l "$path" 2>/dev/null) || return 1
  else
    links=$(stat -c %h "$path" 2>/dev/null) || return 1
  fi
  [ "$links" = 1 ]
}

meta_value() {
  local meta=$1 key=$2 line
  line=$(grep -E "^${key}=" "$meta" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] && printf '%s' "${line#*=}"
}

meta_rewrite_binding() { # <meta> <request-or-empty> [expected-current]
  local meta=$1 request=$2 expected=${3:-} lock tmp current
  lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_acquire_wait "$lock"
  single_link_regular "$meta" || { fm_lock_release "$lock"; return 1; }
  current=$(meta_value "$meta" discord_request)
  if [ -n "$expected" ] && [ "$current" != "$expected" ]; then
    fm_lock_release "$lock"
    return 3
  fi
  if [ -n "$request" ] && [ -n "$current" ] && [ "$current" != "$request" ]; then
    fm_lock_release "$lock"
    return 3
  fi
  tmp=$(mktemp "$STATE/.discord-meta.XXXXXX") || { fm_lock_release "$lock"; return 1; }
  if ! { grep -vE '^discord_request=|^discord_request_ts=' "$meta" || true; } > "$tmp"; then
    rm -f "$tmp"
    fm_lock_release "$lock"
    return 1
  fi
  if [ -n "$request" ]; then
    printf 'discord_request=%s\n' "$request" >> "$tmp" || {
      rm -f "$tmp"; fm_lock_release "$lock"; return 1;
    }
    printf 'discord_request_ts=%s\n' "$(date +%s)" >> "$tmp" || {
      rm -f "$tmp"; fm_lock_release "$lock"; return 1;
    }
  fi
  if ! mv -f -- "$tmp" "$meta"; then
    rm -f "$tmp"
    fm_lock_release "$lock"
    return 1
  fi
  fm_lock_release "$lock"
}

context_check() {
  local message=$1
  [ -n "$NODE_BIN" ] && [ -x "$NODE_BIN" ] || return 1
  FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
    FM_CONFIG_OVERRIDE="$CONFIG" \
    "$NODE_BIN" "$SCRIPT_DIR/fm-discord-bot.mjs" context-check "$message"
}

command=${1:-}
case "$command" in
  link)
    [ "$#" -eq 3 ] || usage
    task=$2
    message=$3
    if ! safe_task "$task" || ! safe_message "$message"; then usage; fi
    meta="$STATE/$task.meta"
    single_link_regular "$meta" || {
      echo "fm-discord-followup: task metadata is missing or unsafe" >&2
      exit 1
    }
    context_check "$message" || {
      echo "fm-discord-followup: Discord reply context is unavailable or outside the configured boundary" >&2
      exit 1
    }
    meta_rewrite_binding "$meta" "$message" || {
      echo "fm-discord-followup: cannot record the Discord terminal reply binding" >&2
      exit 1
    }
    echo "Discord terminal reply linked"
    ;;
  check)
    [ "$#" -eq 2 ] || usage
    task=$2
    safe_task "$task" || usage
    meta="$STATE/$task.meta"
    single_link_regular "$meta" || exit 0
    message=$(meta_value "$meta" discord_request)
    safe_message "$message" || exit 0
    context_check "$message" >/dev/null 2>&1 || exit 0
    printf '%s\n' "$message"
    ;;
  final)
    [ "$#" -eq 4 ] && [ "$3" = --text-file ] || usage
    task=$2
    text_file=$4
    safe_task "$task" || usage
    meta="$STATE/$task.meta"
    single_link_regular "$meta" || {
      echo "fm-discord-followup: task metadata is missing or unsafe" >&2
      exit 1
    }
    message=$(meta_value "$meta" discord_request)
    safe_message "$message" || {
      echo "fm-discord-followup: task has no self-hosted Discord reply binding" >&2
      exit 1
    }
    "$SCRIPT_DIR/fm-discord-reply.sh" "$message" --final --text-file "$text_file" || exit $?
    meta_rewrite_binding "$meta" "" "$message"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ "$rc" -eq 3 ]; then
        echo "fm-discord-followup: reply sent; a newer task binding was preserved" >&2
        exit 0
      fi
      echo "fm-discord-followup: reply sent but the completed binding could not be cleared" >&2
      exit 1
    fi
    echo "Discord terminal reply completed"
    ;;
  *) usage ;;
esac
