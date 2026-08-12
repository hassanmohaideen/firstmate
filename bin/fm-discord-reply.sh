#!/usr/bin/env bash
# Send one public-safe reply directly to the Discord conversation bound to an
# accepted self-hosted message.
#
# Usage:
#   bin/fm-discord-reply.sh <message-id> --text-file <path|->
#   bin/fm-discord-reply.sh <message-id> --final --text-file <path|->
#
# Text must come from a file or stdin, never a shell-interpolated argument.
# The Node owner revalidates the private context against the configured
# guild/channel boundary, applies an idempotent per-phase nonce, suppresses all
# outbound mentions, posts directly to Discord, and removes the pending inbox
# record only after Discord accepts the reply. No Relay token, endpoint, or
# quota participates.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
NODE_BIN="${FM_DISCORD_NODE_BIN:-$(command -v node 2>/dev/null || true)}"
NODE_SCRIPT="$SCRIPT_DIR/fm-discord-bot.mjs"
CONFIG_FILE_OVERRIDE=${FM_DISCORD_CONFIG_FILE:-}

# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-discord-config-lib.sh"

usage() {
  echo "Usage: bin/fm-discord-reply.sh <message-id> [--final] --text-file <path|->" >&2
  exit 2
}

[ "$#" -ge 3 ] || usage
message_id=$1
shift
scope=initial
text_file=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --final)
      scope=final
      shift
      ;;
    --text-file)
      [ "$#" -ge 2 ] || usage
      text_file=$2
      shift 2
      ;;
    *) usage ;;
  esac
done
[ -n "$text_file" ] || usage
case "$message_id" in ''|*[!0-9]*) usage ;; esac
[ "${#message_id}" -ge 15 ] && [ "${#message_id}" -le 22 ] || usage
[ -n "$NODE_BIN" ] && [ -x "$NODE_BIN" ] || {
  echo "fm-discord-reply: Node.js 22 or newer is required" >&2
  exit 1
}
fm_discord_resolve_config_file "$STATE" "$CONFIG" "$CONFIG_FILE_OVERRIDE" || {
  echo "fm-discord-reply: Discord configuration path is missing or unsafe" >&2
  exit 1
}
CONFIG_FILE=$FM_DISCORD_RESOLVED_CONFIG_FILE

if [ "$text_file" != - ]; then
  [ -f "$text_file" ] && [ ! -L "$text_file" ] && [ -r "$text_file" ] || {
    echo "fm-discord-reply: reply text path must be a readable regular non-symlink file" >&2
    exit 1
  }
  case "$text_file" in
    "$STATE"/*) ;;
    *)
      echo "fm-discord-reply: reply text file must stay inside this home's private state directory (or use stdin)" >&2
      exit 1
      ;;
  esac
fi

FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
  FM_CONFIG_OVERRIDE="$CONFIG" FM_DISCORD_CONFIG_FILE="$CONFIG_FILE" \
  "$NODE_BIN" "$NODE_SCRIPT" send "$message_id" \
    --nonce-scope "$scope" --text-file "$text_file"
