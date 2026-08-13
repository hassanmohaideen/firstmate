#!/usr/bin/env bash
# Effective crew-dispatch configuration selection.
#
# A home-local config/crew-dispatch.json and the repository's optional tracked
# defaults/crew-dispatch.json form one layered intake surface. Callers validate
# both and use their presence for the explicit-harness consultation backstop;
# this helper never matches task intent. The local path prints first so equal-fit
# local rules and the local default retain higher precedence.

fm_dispatch_config_paths() {
  local config_dir=$1 root=$2 tracked local_file
  tracked=${FM_TEST_DISPATCH_DEFAULTS_PATH:-$root/defaults/crew-dispatch.json}
  local_file="$config_dir/crew-dispatch.json"
  [ ! -f "$local_file" ] || printf '%s\n' "$local_file"
  [ "$tracked" = "$local_file" ] || [ ! -f "$tracked" ] || printf '%s\n' "$tracked"
}

fm_dispatch_config_label() {
  local path=$1 config_dir=$2 root=$3
  if [ "$path" = "$config_dir/crew-dispatch.json" ]; then
    printf '%s\n' 'config/crew-dispatch.json'
  elif [ "$path" = "${FM_TEST_DISPATCH_DEFAULTS_PATH:-$root/defaults/crew-dispatch.json}" ]; then
    printf '%s\n' 'defaults/crew-dispatch.json'
  else
    printf '%s\n' "$path"
  fi
}
