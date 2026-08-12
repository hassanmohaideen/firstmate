#!/usr/bin/env bash
# fm-rtk.sh - optional, fixed-scope RTK output compaction for task orientation.
#
# This helper is disabled unless the effective home has a regular non-symlink
# config/rtk containing exactly `v0.45.0` plus one newline.
# It never downloads, installs, updates, discovers, or stages RTK.
# The only supported v1 artifact is:
#   data/tools/rtk/v0.45.0/aarch64-apple-darwin/rtk
# on Darwin arm64, with SHA-256:
#   17d00d61a533a442c61f1be49d8a9321225557f64021d5b70fd8eb75ed8fb0be
#
# Usage:
#   fm-rtk.sh git-log
#   fm-rtk.sh git-diff [--cached]
#   fm-rtk.sh git-status
#   fm-rtk.sh search <pattern> [path...]
#   fm-rtk.sh list <directory>
#
# The verbs map to fixed, read-only, human-oriented argv:
#   git-log          -> git log -n 50 --decorate
#   git-diff         -> git diff
#   git-diff --cached -> git diff --cached
#   git-status       -> git status
#   search ...       -> rg <pattern> [path...]
#   list <directory> -> ls <directory>
# No arbitrary command, command string, shell syntax, option passthrough, machine
# mode, RTK proxy, project filter, or mutation escape hatch exists.
# Standalone shell-operator arguments and option-like search/list arguments are
# admission errors and execute neither RTK nor the raw command.
#
# Compact output is supplemental orientation only.
# Callers must rerun the corresponding raw command before using its output for a
# safety, mutation, validation, final-review, cleanliness, landing, or approval
# decision.
#
# Before compact execution, the helper verifies the selected pin, Darwin arm64,
# artifact type, executable bit, SHA-256, and exact `rtk 0.45.0` version output.
# An unavailable or invalid optional RTK setup prints one argument-free warning
# and replaces this helper with the exact raw allowlisted argv once.
# An admission error executes nothing.
# After the verified RTK command starts, the helper returns its observed streams
# and status and never automatically reruns the raw command.
#
# Every RTK preflight and compact execution receives a fresh mode-0700 temporary
# HOME/XDG/data/cache root, a private RTK_DB_PATH, RTK_TELEMETRY_DISABLED=1,
# RTK_TEE=0, RTK_NO_TOML=1, NO_COLOR=1, PAGER=cat, and GIT_PAGER=cat through a
# clean environment.
# Caller values cannot override those settings.
# The temporary root is removed after normal completion and caught termination.
# The helper logs only its fixed semantic verb and non-sensitive fallback reason,
# never arguments, patterns, paths, command history, output, or analytics.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RTK_PIN=v0.45.0
RTK_VERSION_OUTPUT='rtk 0.45.0'
RTK_BINARY_SHA256=17d00d61a533a442c61f1be49d8a9321225557f64021d5b70fd8eb75ed8fb0be
RTK_PLATFORM=aarch64-apple-darwin
RTK_TMP=
RTK_CHILD_PID=
VERB=
RAW_ARGV=()
RTK_ARGV=()

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

admission_error() {
  printf 'fm-rtk: refused %s request: %s\n' "${VERB:-unknown}" "$1" >&2
  exit 64
}

is_shell_operator() {
  case "$1" in
    '|'|'||'|'&'|'&&'|';'|'<'|'>'|'>>'|'<<'|'('|')') return 0 ;;
    *) return 1 ;;
  esac
}

validate_data_arg() {
  case "$1" in
    -*) admission_error 'option-like arguments are not supported' ;;
  esac
  is_shell_operator "$1" && admission_error 'standalone shell operators are not supported'
}

cleanup_tmp() {
  if [ -n "$RTK_TMP" ] && [ -d "$RTK_TMP" ]; then
    rm -rf -- "$RTK_TMP"
  fi
  RTK_TMP=
}

# shellcheck disable=SC2329 # Invoked indirectly by the HUP/INT/TERM traps below.
forward_signal() {
  local signal=$1 code=$2
  trap - HUP INT TERM
  if [ -n "$RTK_CHILD_PID" ]; then
    kill -s "$signal" "$RTK_CHILD_PID" 2>/dev/null || true
    wait "$RTK_CHILD_PID" 2>/dev/null || true
    RTK_CHILD_PID=
  fi
  cleanup_tmp
  kill -s "$signal" "$$" 2>/dev/null || exit "$code"
}

raw_fallback() {
  local reason=$1
  cleanup_tmp
  trap - EXIT HUP INT TERM
  printf 'fm-rtk: optional compaction unavailable (%s); running raw %s\n' "$reason" "$VERB" >&2
  exec "${RAW_ARGV[@]}"
}

sha256_file() {
  local file=$1 output
  if command -v shasum >/dev/null 2>&1; then
    output=$(shasum -a 256 "$file" 2>/dev/null) || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    output=$(sha256sum "$file" 2>/dev/null) || return 1
  else
    return 1
  fi
  printf '%s\n' "${output%%[[:space:]]*}"
}

resolve_home() {
  local requested=${FM_HOME:-$FM_ROOT}
  case "$requested" in
    /*)
      [ -d "$requested" ] || return 1
      (CDPATH='' cd -- "$requested" 2>/dev/null && pwd -P)
      ;;
    *)
      (CDPATH='' cd -- "$requested" 2>/dev/null && pwd -P)
      ;;
  esac
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

[ "$#" -gt 0 ] || admission_error 'a semantic verb is required'
VERB=$1
shift
case "$VERB" in
  git-log)
    [ "$#" -eq 0 ] || admission_error 'git-log accepts no arguments'
    RAW_ARGV=(git log -n 50 --decorate)
    RTK_ARGV=(git log -n 50 --decorate)
    ;;
  git-diff)
    case "$#:${1:-}" in
      0:) RAW_ARGV=(git diff); RTK_ARGV=(git diff) ;;
      1:--cached) RAW_ARGV=(git diff --cached); RTK_ARGV=(git diff --cached) ;;
      *) admission_error 'git-diff accepts only an optional --cached' ;;
    esac
    ;;
  git-status)
    [ "$#" -eq 0 ] || admission_error 'git-status accepts no arguments'
    RAW_ARGV=(git status)
    RTK_ARGV=(git status)
    ;;
  search)
    [ "$#" -ge 1 ] || admission_error 'search requires a pattern'
    for arg in "$@"; do
      validate_data_arg "$arg"
    done
    RAW_ARGV=(rg "$@")
    RTK_ARGV=(rg "$@")
    ;;
  list)
    [ "$#" -eq 1 ] || admission_error 'list requires exactly one directory'
    validate_data_arg "$1"
    [ -d "$1" ] || admission_error 'list target must be a directory'
    RAW_ARGV=(ls "$1")
    RTK_ARGV=(ls "$1")
    ;;
  *)
    admission_error 'unknown semantic verb'
    ;;
esac

EFFECTIVE_HOME=$(resolve_home) || raw_fallback 'home unavailable'
CONFIG_FILE="$EFFECTIVE_HOME/config/rtk"
if [ -L "$CONFIG_FILE" ]; then
  raw_fallback 'invalid config'
fi
if [ ! -e "$CONFIG_FILE" ]; then
  raw_fallback 'disabled'
fi
if [ ! -f "$CONFIG_FILE" ]; then
  raw_fallback 'invalid config'
fi
CONFIG_BYTES=$(LC_ALL=C wc -c < "$CONFIG_FILE" 2>/dev/null | tr -d '[:space:]') || raw_fallback 'unreadable config'
SELECTED_PIN=
IFS= read -r SELECTED_PIN < "$CONFIG_FILE" || true
if [ "$CONFIG_BYTES" != 8 ] || [ "$SELECTED_PIN" != "$RTK_PIN" ]; then
  raw_fallback 'invalid pin'
fi

OS_NAME=$(uname -s 2>/dev/null) || raw_fallback 'platform check failed'
ARCH_NAME=$(uname -m 2>/dev/null) || raw_fallback 'platform check failed'
if [ "$OS_NAME" != Darwin ] || [ "$ARCH_NAME" != arm64 ]; then
  raw_fallback 'unsupported platform'
fi

ARTIFACT="$EFFECTIVE_HOME/data/tools/rtk/$RTK_PIN/$RTK_PLATFORM/rtk"
if [ -L "$ARTIFACT" ]; then
  raw_fallback 'invalid artifact type'
fi
if [ ! -f "$ARTIFACT" ]; then
  raw_fallback 'missing artifact'
fi
if [ ! -x "$ARTIFACT" ]; then
  raw_fallback 'artifact is not executable'
fi
ACTUAL_SHA=$(sha256_file "$ARTIFACT") || raw_fallback 'artifact hash unavailable'
if [ "$ACTUAL_SHA" != "$RTK_BINARY_SHA256" ]; then
  raw_fallback 'artifact hash mismatch'
fi

old_umask=$(umask)
umask 077
RTK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-rtk.XXXXXX") || {
  umask "$old_umask"
  raw_fallback 'temporary isolation unavailable'
}
trap cleanup_tmp EXIT
trap 'forward_signal HUP 129' HUP
trap 'forward_signal INT 130' INT
trap 'forward_signal TERM 143' TERM
umask "$old_umask"
chmod 700 "$RTK_TMP" 2>/dev/null || raw_fallback 'temporary isolation unavailable'
mkdir -p "$RTK_TMP/home" "$RTK_TMP/config" "$RTK_TMP/data" "$RTK_TMP/cache" "$RTK_TMP/tmp" \
  || raw_fallback 'temporary isolation unavailable'

ISOLATED_ENV=(
  "HOME=$RTK_TMP/home"
  "XDG_CONFIG_HOME=$RTK_TMP/config"
  "XDG_DATA_HOME=$RTK_TMP/data"
  "XDG_CACHE_HOME=$RTK_TMP/cache"
  "TMPDIR=$RTK_TMP/tmp"
  "RTK_DB_PATH=$RTK_TMP/data/history.db"
  'RTK_TELEMETRY_DISABLED=1'
  'RTK_TEE=0'
  'RTK_NO_TOML=1'
  'NO_COLOR=1'
  'PAGER=cat'
  'GIT_PAGER=cat'
  "PATH=${PATH:-/usr/bin:/bin}"
)

VERSION_STDOUT="$RTK_TMP/version.stdout"
VERSION_STDERR="$RTK_TMP/version.stderr"
env -i "${ISOLATED_ENV[@]}" "$ARTIFACT" --version > "$VERSION_STDOUT" 2> "$VERSION_STDERR"
VERSION_RC=$?
if [ "$VERSION_RC" -ne 0 ]; then
  raw_fallback 'artifact startup failed'
fi
VERSION_BYTES=$(LC_ALL=C wc -c < "$VERSION_STDOUT" 2>/dev/null | tr -d '[:space:]') \
  || raw_fallback 'version check failed'
VERSION_LINE=
IFS= read -r VERSION_LINE < "$VERSION_STDOUT" || true
if [ "$VERSION_BYTES" != 11 ] || [ "$VERSION_LINE" != "$RTK_VERSION_OUTPUT" ] || [ -s "$VERSION_STDERR" ]; then
  raw_fallback 'artifact version mismatch'
fi

printf 'fm-rtk: using RTK %s for supplemental %s orientation\n' "$RTK_PIN" "$VERB" >&2
env -i "${ISOLATED_ENV[@]}" "$ARTIFACT" "${RTK_ARGV[@]}" &
RTK_CHILD_PID=$!
wait "$RTK_CHILD_PID"
RTK_RC=$?
RTK_CHILD_PID=
trap - HUP INT TERM
exit "$RTK_RC"
