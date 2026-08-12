#!/usr/bin/env bash

fm_discord_private_file() {
  local path=$1 links mode
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

fm_discord_config_path_valid() {
  local path=$1
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$path" in *[$'\n\r\t']*) return 1 ;; esac
  [ "${#path}" -le 4096 ] && fm_discord_private_file "$path"
}

fm_discord_resolve_config_file() {
  local state=$1 config=$2 explicit=${3:-} record path lines size
  record="$state/discord-bot.config-path"
  if [ -n "$explicit" ]; then
    path=$explicit
  elif [ -e "$record" ] || [ -L "$record" ]; then
    fm_discord_private_file "$record" || return 1
    size=$(wc -c < "$record" 2>/dev/null | tr -d ' ') || return 1
    lines=$(wc -l < "$record" 2>/dev/null | tr -d ' ') || return 1
    case "$size" in ''|*[!0-9]*) return 1 ;; esac
    case "$lines" in ''|*[!0-9]*) return 1 ;; esac
    [ "$size" -gt 0 ] && [ "$size" -le 4097 ] && [ "$lines" -eq 1 ] || return 1
    IFS= read -r path < "$record" || return 1
  else
    path="$config/discord-bot.env"
  fi
  fm_discord_config_path_valid "$path" || return 1
  FM_DISCORD_RESOLVED_CONFIG_FILE=$path
}

fm_discord_persist_config_file() {
  local state=$1 path=$2 record tmp
  record="$state/discord-bot.config-path"
  fm_discord_config_path_valid "$path" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  if [ -e "$record" ] || [ -L "$record" ]; then
    fm_discord_private_file "$record" || return 1
  fi
  tmp=$(umask 077; mktemp "$state/.discord-bot.config-path.XXXXXX") || return 1
  if ! printf '%s\n' "$path" > "$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$record"; then
    rm -f -- "$tmp"
    return 1
  fi
  fm_discord_private_file "$record"
}
