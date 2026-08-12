#!/usr/bin/env bash
# Configure and operate Firstmate's self-hosted Discord bot transport.
#
# Usage:
#   bin/fm-discord-bot.sh configure   # interactive, secret-safe local config
#   bin/fm-discord-bot.sh start       # install/load a per-home macOS LaunchAgent
#   bin/fm-discord-bot.sh stop        # unload it and remove its LaunchAgent
#   bin/fm-discord-bot.sh check       # validate config and report safe service health
#   bin/fm-discord-bot.sh run         # foreground service (portable/manual)
#   bin/fm-discord-bot.sh worker      # LaunchAgent entry; single-instance wrapper
#
# Configuration is the regular, single-linked mode-0600 file
#   $FM_HOME/config/discord-bot.env
# (or $FM_CONFIG_OVERRIDE/discord-bot.env). It contains exactly the bot token,
# owner user id, allowed guild id, and allowed channel id. The LaunchAgent plist
# contains only code/home paths - never credentials or deployment ids.
#
# macOS start uses one home-derived label, RunAtLoad, KeepAlive, and a bounded
# launchd throttle. The worker also takes a recoverable home-local process lock,
# so manual and service starts cannot create two Discord Gateway sessions.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
case "$FM_HOME" in
  /*) ;;
  *) FM_HOME=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
       echo "fm-discord-bot: FM_HOME cannot be resolved" >&2
       exit 2
     } ;;
esac
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG_FILE="${FM_DISCORD_CONFIG_FILE:-$CONFIG/discord-bot.env}"
NODE_SCRIPT="$SCRIPT_DIR/fm-discord-bot.mjs"
NODE_BIN="${FM_DISCORD_NODE_BIN:-$(command -v node 2>/dev/null || true)}"
LABEL_PREFIX=dev.firstmate.discord

# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-discord-config-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  bin/fm-discord-bot.sh configure
  bin/fm-discord-bot.sh start
  bin/fm-discord-bot.sh stop
  bin/fm-discord-bot.sh check
  bin/fm-discord-bot.sh run
EOF
}

die() {
  echo "fm-discord-bot: $*" >&2
  exit 1
}

require_node() {
  [ -n "$NODE_BIN" ] && [ -x "$NODE_BIN" ] || die "Node.js 22 or newer is required"
  "$NODE_BIN" -e 'if (typeof WebSocket !== "function" || typeof fetch !== "function") process.exit(1)' \
    >/dev/null 2>&1 || die "Node.js with built-in WebSocket and fetch support is required (Node 22 or newer)"
  [ -f "$NODE_SCRIPT" ] && [ ! -L "$NODE_SCRIPT" ] || die "Discord runtime is missing or unsafe: $NODE_SCRIPT"
}

validate_config() {
  require_node
  FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_DISCORD_CONFIG_FILE="${FM_DISCORD_CONFIG_FILE:-$CONFIG_FILE}" \
    "$NODE_BIN" "$NODE_SCRIPT" validate
}

validate_config_file_only() (
  unset FM_DISCORD_BOT_TOKEN FM_DISCORD_OWNER_USER_ID FM_DISCORD_GUILD_ID FM_DISCORD_CHANNEL_ID
  validate_config
)

home_hash() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$FM_HOME" | shasum -a 256 | awk '{print substr($1,1,12)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$FM_HOME" | sha256sum | awk '{print substr($1,1,12)}'
  else
    die "shasum or sha256sum is required to derive the per-home service label"
  fi
}

service_label() {
  printf '%s.%s\n' "$LABEL_PREFIX" "$(home_hash)"
}

launchagent_paths() {
  local label
  label=$(service_label)
  LAUNCH_AGENT_DIR="${HOME:-}/Library/LaunchAgents"
  LAUNCH_AGENT_PLIST="$LAUNCH_AGENT_DIR/$label.plist"
  LAUNCH_AGENT_LOG="$STATE/discord-bot.log"
  LAUNCH_AGENT_LABEL=$label
}

plist_safe() {
  case "$1" in *'&'*|*'<'*|*'>'*|*'"'*|*"'") return 1 ;; esac
}

render_launchagent() {
  launchagent_paths
  plist_safe "$SCRIPT_DIR/fm-discord-bot.sh" \
    && plist_safe "$FM_HOME" \
    && plist_safe "$FM_ROOT" \
    && plist_safe "$STATE" \
    && plist_safe "$CONFIG" \
    && plist_safe "$CONFIG_FILE" \
    && plist_safe "$NODE_BIN" \
    && plist_safe "${HOME:-}" \
    && plist_safe "$LAUNCH_AGENT_LOG" || return 1
  cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LAUNCH_AGENT_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$SCRIPT_DIR/fm-discord-bot.sh</string>
		<string>worker</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>HOME</key>
		<string>${HOME:-}</string>
		<key>FM_HOME</key>
		<string>$FM_HOME</string>
		<key>FM_ROOT_OVERRIDE</key>
		<string>$FM_ROOT</string>
		<key>FM_STATE_OVERRIDE</key>
		<string>$STATE</string>
		<key>FM_CONFIG_OVERRIDE</key>
		<string>$CONFIG</string>
		<key>FM_DISCORD_CONFIG_FILE</key>
		<string>$CONFIG_FILE</string>
		<key>FM_DISCORD_NODE_BIN</key>
		<string>$NODE_BIN</string>
	</dict>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>ProcessType</key>
	<string>Background</string>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>15</integer>
	<key>StandardOutPath</key>
	<string>$LAUNCH_AGENT_LOG</string>
	<key>StandardErrorPath</key>
	<string>$LAUNCH_AGENT_LOG</string>
</dict>
</plist>
XML
}

configure() {
  local token owner guild channel replace tmp
  [ -t 0 ] || die "configure requires an interactive terminal so the bot token is never passed in argv"
  if [ -e "$CONFIG" ] || [ -L "$CONFIG" ]; then
    [ -d "$CONFIG" ] && [ ! -L "$CONFIG" ] || die "config directory is not a genuine directory: $CONFIG"
  else
    (umask 077; mkdir -p "$CONFIG") || die "cannot create $CONFIG"
  fi
  if [ -e "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ]; then
    [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] || die "existing configuration is not a genuine file"
    printf 'Replace the existing self-hosted Discord configuration? [y/N] ' >&2
    IFS= read -r replace || exit 1
    case "$(printf '%s' "$replace" | tr '[:upper:]' '[:lower:]')" in y|yes) ;; *) echo "unchanged"; return 0 ;; esac
  fi
  printf 'Discord bot token (input hidden): ' >&2
  IFS= read -r -s token || exit 1
  printf '\nDiscord owner user ID: ' >&2
  IFS= read -r owner || exit 1
  printf 'Allowed guild ID: ' >&2
  IFS= read -r guild || exit 1
  printf 'Allowed channel ID: ' >&2
  IFS= read -r channel || exit 1
  tmp=$(umask 077; mktemp "$CONFIG/.discord-bot.env.tmp.XXXXXX") || die "cannot create a private config temporary file"
  trap 'rm -f -- "$tmp"' EXIT HUP INT TERM
  {
    printf 'FM_DISCORD_BOT_TOKEN=%s\n' "$token"
    printf 'FM_DISCORD_OWNER_USER_ID=%s\n' "$owner"
    printf 'FM_DISCORD_GUILD_ID=%s\n' "$guild"
    printf 'FM_DISCORD_CHANNEL_ID=%s\n' "$channel"
  } > "$tmp" || die "cannot write the private config temporary file"
  chmod 600 "$tmp" || die "cannot protect the private config temporary file"
  FM_DISCORD_CONFIG_FILE="$tmp" validate_config_file_only >/dev/null || die "configuration was refused; no existing configuration changed"
  mv -f -- "$tmp" "$CONFIG_FILE" || die "cannot publish $CONFIG_FILE"
  trap - EXIT HUP INT TERM
  echo "self-hosted Discord configuration saved privately; run bin/fm-discord-bot.sh start"
}

run_worker() {
  local lock child='' rc=0 terminating=0
  validate_config >/dev/null
  mkdir -p "$STATE" || die "cannot create $STATE"
  fm_discord_persist_config_file "$STATE" "$CONFIG_FILE" \
    || die "cannot persist the selected Discord configuration path safely"
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  lock="$STATE/.discord-bot.lock"
  if ! fm_lock_try_acquire "$lock"; then
    die "another self-hosted Discord bot already owns this home${FM_LOCK_HELD_PID:+ (pid $FM_LOCK_HELD_PID)}"
  fi
  # shellcheck disable=SC2329 # Invoked by the signal traps below.
  terminate_child() {
    terminating=1
    [ -z "$child" ] || kill -TERM "$child" 2>/dev/null || true
  }
  # shellcheck disable=SC2329 # Invoked by the EXIT trap below.
  cleanup_worker() {
    local cleanup_rc=$?
    [ -z "$child" ] || kill -TERM "$child" 2>/dev/null || true
    [ -z "$child" ] || wait "$child" 2>/dev/null || true
    rm -f "$STATE/discord-bot.enabled" "$STATE/discord-bot.ready" 2>/dev/null || true
    fm_lock_release "$lock"
    return "$cleanup_rc"
  }
  trap terminate_child HUP INT TERM
  trap cleanup_worker EXIT
  FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_DISCORD_CONFIG_FILE="$CONFIG_FILE" \
    "$NODE_BIN" "$NODE_SCRIPT" run &
  child=$!
  printf '%s\n' "$child" > "$lock/child-pid" 2>/dev/null || true
  wait "$child" || rc=$?
  if [ "$terminating" -eq 1 ] && kill -0 "$child" 2>/dev/null; then
    wait "$child" || rc=$?
  fi
  child=
  exit "$rc"
}

start_service() {
  local uid domain tmp out i=0
  [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] \
    || die "persistent start requires the private file written by bin/fm-discord-bot.sh configure"
  validate_config_file_only >/dev/null
  [ "$(uname)" = Darwin ] || die "persistent start is currently supported on macOS; use run under your own service manager elsewhere"
  command -v launchctl >/dev/null 2>&1 || die "launchctl is unavailable"
  uid=$(id -u 2>/dev/null || true)
  case "$uid" in ''|*[!0-9]*) die "the account uid is unavailable" ;; esac
  domain="gui/$uid"
  launchctl print "$domain" >/dev/null 2>&1 || die "no Aqua login launchd domain is available for this account"
  launchagent_paths
  mkdir -p "$STATE" "$LAUNCH_AGENT_DIR" || die "cannot create the service state or LaunchAgents directory"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "service state directory is unsafe"
  [ -d "$LAUNCH_AGENT_DIR" ] && [ ! -L "$LAUNCH_AGENT_DIR" ] || die "LaunchAgents directory is unsafe"
  fm_discord_persist_config_file "$STATE" "$CONFIG_FILE" \
    || die "cannot persist the selected Discord configuration path safely"
  tmp="$LAUNCH_AGENT_DIR/.$LAUNCH_AGENT_LABEL.plist.tmp.$$"
  render_launchagent > "$tmp" || {
    rm -f -- "$tmp"
    die "service paths cannot be embedded safely in a LaunchAgent"
  }
  chmod 644 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$LAUNCH_AGENT_PLIST" || {
    rm -f -- "$tmp"
    die "cannot publish $LAUNCH_AGENT_PLIST"
  }
  launchctl bootout "$domain/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 || true
  rm -f "$STATE/discord-bot.enabled" "$STATE/discord-bot.ready" 2>/dev/null || true
  if ! out=$(launchctl bootstrap "$domain" "$LAUNCH_AGENT_PLIST" 2>&1); then
    rm -f -- "$LAUNCH_AGENT_PLIST" 2>/dev/null || true
    die "launchctl bootstrap refused the Discord service: ${out:-no diagnostic}; the inactive LaunchAgent was removed"
  fi
  if ! out=$(launchctl kickstart -k "$domain/$LAUNCH_AGENT_LABEL" 2>&1); then
    launchctl bootout "$domain/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 || true
    rm -f -- "$LAUNCH_AGENT_PLIST" 2>/dev/null || true
    die "launchctl kickstart refused the Discord service: ${out:-no diagnostic}; the LaunchAgent was unloaded and removed"
  fi
  while [ "$i" -lt 50 ]; do
    [ -f "$STATE/discord-bot.ready" ] && {
      echo "self-hosted Discord bot is connected and will restart automatically"
      return 0
    }
    sleep 0.1
    i=$((i + 1))
  done
  launchctl print "$domain/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 \
    || die "the Discord service did not remain loaded; run check for the safe diagnostic"
  echo "self-hosted Discord bot is running and reconnecting; run check for current health"
}

stop_service() {
  local uid domain out i=0
  launchagent_paths
  uid=$(id -u 2>/dev/null || true)
  case "$uid" in ''|*[!0-9]*) die "the account uid is unavailable" ;; esac
  domain="gui/$uid"
  if command -v launchctl >/dev/null 2>&1; then
    if ! out=$(launchctl bootout "$domain/$LAUNCH_AGENT_LABEL" 2>&1); then
      case "$out" in *"Could not find service"*|*"No such process"*) ;; *) die "launchctl could not stop the Discord service: ${out:-no diagnostic}" ;; esac
    fi
  fi
  rm -f -- "$LAUNCH_AGENT_PLIST" || die "cannot remove $LAUNCH_AGENT_PLIST"
  while [ "$i" -lt 50 ] && [ -e "$STATE/.discord-bot.lock" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ ! -e "$STATE/.discord-bot.lock" ] && [ ! -L "$STATE/.discord-bot.lock" ] \
    || die "the Discord service is still stopping; rerun check before starting another instance"
  rm -f "$STATE/discord-bot.enabled" "$STATE/discord-bot.ready" 2>/dev/null || true
  echo "self-hosted Discord bot stopped; its private configuration is unchanged"
}

check_service() {
  local validate_out validate_rc=0 pid='' code='' stopped=1
  validate_out=$(validate_config 2>&1) || validate_rc=$?
  if [ "$validate_rc" -eq 3 ]; then
    echo "self-hosted Discord bot is disabled (no private configuration)"
    return 1
  fi
  if [ "$validate_rc" -ne 0 ]; then
    printf '%s\n' "$validate_out" >&2
    return 1
  fi
  if [ -e "$STATE/.discord-bot.lock" ] || [ -L "$STATE/.discord-bot.lock" ]; then
    pid=$(cat "$STATE/.discord-bot.lock/pid" 2>/dev/null || true)
    case "$pid" in ''|*[!0-9]*) ;; *) kill -0 "$pid" 2>/dev/null && stopped=0 ;; esac
  fi
  if [ "$stopped" -eq 1 ]; then
    echo "self-hosted Discord bot is configured but stopped"
    return 1
  fi
  if [ -f "$STATE/discord-bot.ready" ] && [ ! -L "$STATE/discord-bot.ready" ]; then
    echo "self-hosted Discord bot is connected"
    return 0
  fi
  if [ -f "$STATE/discord-bot.error" ] && [ ! -L "$STATE/discord-bot.error" ]; then
    code=$("$NODE_BIN" -e '
      const fs=require("fs");
      try { const value=JSON.parse(fs.readFileSync(process.argv[1],"utf8")).code; if (/^[a-z0-9-]+$/.test(value)) process.stdout.write(value); } catch {}
    ' "$STATE/discord-bot.error" 2>/dev/null || true)
  fi
  if [ -n "$code" ]; then
    echo "self-hosted Discord bot is reconnecting; diagnostic: $code"
  else
    echo "self-hosted Discord bot is running and waiting for Discord"
  fi
  return 1
}

command=${1:-}
case "$command" in
  configure) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; configure ;;
  start) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; start_service ;;
  stop) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; stop_service ;;
  check) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; check_service ;;
  run) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; run_worker ;;
  worker) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; run_worker ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
