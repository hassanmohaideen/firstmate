#!/usr/bin/env bash
# Publish one self-hosted Discord event through Firstmate's durable wake queue.
#
# Usage:
#   bin/fm-discord-notify.sh message <discord-message-id>
#   bin/fm-discord-notify.sh error <safe-diagnostic-code>
#
# The Discord runtime calls this only after committing the private inbox or
# diagnostic artifact. Raw Discord text and credentials never enter the queue.
# This script adds no watcher or control plane: fm-wake-lib.sh remains the sole
# owner of durable notification ordering, locking, and recovery.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  bin/fm-discord-notify.sh message <discord-message-id>
  bin/fm-discord-notify.sh error <safe-diagnostic-code>
EOF
  exit 2
}

private_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

private_file() {
  local path=$1 links
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(private_mode "$path")" = 600 ] || return 1
  if [ "$(uname)" = Darwin ]; then
    links=$(stat -f %l "$path" 2>/dev/null) || return 1
  else
    links=$(stat -c %h "$path" 2>/dev/null) || return 1
  fi
  [ "$links" = 1 ]
}

[ "$#" -eq 2 ] || usage
kind=$1
key=$2
case "$kind" in
  message)
    case "$key" in ''|*[!0-9]*) usage ;; esac
    [ "${#key}" -ge 15 ] && [ "${#key}" -le 22 ] || usage
    private_file "$STATE/discord-inbox/$key.json" || {
      echo "fm-discord-notify: private inbox record is missing or unsafe" >&2
      exit 1
    }
    private_file "$STATE/discord-context/$key.json" || {
      echo "fm-discord-notify: private reply binding is missing or unsafe" >&2
      exit 1
    }
    fm_wake_append check "discord-message-$key" "check: discord-message $key"
    ;;
  error)
    case "$key" in ''|*[!a-z0-9-]*) usage ;; esac
    [ "${#key}" -le 64 ] || usage
    private_file "$STATE/discord-bot.error" || {
      echo "fm-discord-notify: private diagnostic record is missing or unsafe" >&2
      exit 1
    }
    fm_wake_append check "discord-error-$key" "check: discord-error $key"
    ;;
  *) usage ;;
esac
