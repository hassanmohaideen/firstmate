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

opaque_key() {
  local value=$1 digest
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s' "$value" | shasum -a 256 | awk '{print $1}') || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s' "$value" | sha256sum | awk '{print $1}') || return 1
  else
    return 1
  fi
  case "$digest" in *[!0-9a-f]*|'') return 1 ;; esac
  printf '%s\n' "$digest"
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
    dedupe=$(opaque_key "$kind:$key") || {
      echo "fm-discord-notify: SHA-256 is required for durable deduplication" >&2
      exit 1
    }
    wake_key="discord-$kind-$dedupe"
    fm_wake_append_idempotent check "$wake_key" "check: discord-message $key" "$dedupe"
    ;;
  error)
    case "$key" in ''|*[!a-z0-9-]*) usage ;; esac
    [ "${#key}" -le 64 ] || usage
    private_file "$STATE/discord-bot.error" || {
      echo "fm-discord-notify: private diagnostic record is missing or unsafe" >&2
      exit 1
    }
    diagnostic_record=$(cat "$STATE/discord-bot.error") || exit 1
    case "$diagnostic_record" in *[$'\t\r\n']*)
      echo "fm-discord-notify: private diagnostic record is invalid" >&2
      exit 1
      ;;
    esac
    node_bin=${FM_DISCORD_NODE_BIN:-node}
    incident_id=$(printf '%s' "$diagnostic_record" | "$node_bin" -e '
      let input = "";
      process.stdin.setEncoding("utf8");
      process.stdin.on("data", chunk => { input += chunk; });
      process.stdin.on("end", () => {
        try {
          const record = JSON.parse(input);
          if (record.code !== process.argv[1] || !/^[0-9a-f]{64}$/.test(record.incident_id || "")) process.exit(1);
          process.stdout.write(record.incident_id);
        } catch { process.exit(1); }
      });
    ' "$key") || {
      echo "fm-discord-notify: private diagnostic record is invalid" >&2
      exit 1
    }
    dedupe=$(opaque_key "$kind:$incident_id") || {
      echo "fm-discord-notify: SHA-256 is required for durable deduplication" >&2
      exit 1
    }
    wake_key="discord-$kind-$dedupe"
    fm_wake_append_idempotent check "$wake_key" "check: discord-error $key" "$dedupe"
    ;;
  *) usage ;;
esac
