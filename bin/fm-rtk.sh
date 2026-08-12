#!/bin/bash -p
if [ "${_FM_RTK_CLEAN_ENV:-}" != 'firstmate-rtk-verifier-v1' ]; then
  exec /usr/bin/env -i \
    _FM_RTK_CLEAN_ENV=firstmate-rtk-verifier-v1 \
    PATH=/usr/bin:/bin LC_ALL=C \
    FM_HOME="${FM_HOME:-}" \
    /bin/bash -p "$0" "$@"
  exit 70
fi
unset _FM_RTK_CLEAN_ENV BASH_ENV ENV CDPATH GLOBIGNORE
PATH=/usr/bin:/bin
LC_ALL=C
export PATH LC_ALL

# fm-rtk.sh - inspect the reviewed RTK pilot artifact without executing it.
#
# This command only verifies the manually staged scout candidate and never runs
# RTK or a project command.
#
# Usage:
#   fm-rtk.sh verify
#
# The only reviewed candidate is the regular, non-symlink, executable file at:
#   $FM_HOME/data/tools/rtk/v0.45.0/aarch64-apple-darwin/rtk
# on Darwin arm64, with SHA-256:
#   17d00d61a533a442c61f1be49d8a9321225557f64021d5b70fd8eb75ed8fb0be
# The command does not install, stage, activate, download, update, or execute it.
set -u

SOURCE_PATH=$(/usr/bin/perl -MCwd=abs_path -e 'print abs_path($ARGV[0])' -- "${BASH_SOURCE[0]}") || exit 70
case "$SOURCE_PATH" in
  */*) SOURCE_DIR=${SOURCE_PATH%/*} ;;
  *) exit 70 ;;
esac
SCRIPT_DIR=$(CDPATH='' cd -- "$SOURCE_DIR" 2>/dev/null && pwd -P) || exit 70
FM_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 70
VERIFIER_LIB=$FM_ROOT/lib/Firstmate/RTKVerifier.pm
RTK_PIN=v0.45.0
RTK_PLATFORM=aarch64-apple-darwin
RTK_BINARY_SHA256=17d00d61a533a442c61f1be49d8a9321225557f64021d5b70fd8eb75ed8fb0be
PERL_TOOL=/usr/bin/perl
ENV_TOOL=/usr/bin/env

trusted_executable() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ -x "$1" ]
}

usage() {
  printf '%s\n' \
    'fm-rtk.sh - inspect the reviewed RTK pilot artifact without executing it.' \
    '' \
    'Usage:' \
    '  fm-rtk.sh verify'
}

case "${1:-}" in
  -h|--help)
    [ "$#" -eq 1 ] || { printf 'fm-rtk: help accepts no arguments\n' >&2; exit 64; }
    usage
    exit 0
    ;;
  verify)
    [ "$#" -eq 1 ] || { printf 'fm-rtk: verify accepts no arguments\n' >&2; exit 64; }
    ;;
  '') printf 'fm-rtk: verify is required\n' >&2; exit 64 ;;
  *) printf 'fm-rtk: unknown inspection request\n' >&2; exit 64 ;;
esac

if ! trusted_executable "$PERL_TOOL" || ! trusted_executable "$ENV_TOOL" ||
  [ ! -f "$VERIFIER_LIB" ] || [ -L "$VERIFIER_LIB" ] || [ ! -r "$VERIFIER_LIB" ]; then
  printf 'fm-rtk: trusted inspection utility unavailable\n' >&2
  exit 69
fi

REQUESTED_HOME=${FM_HOME:-$FM_ROOT}
EFFECTIVE_HOME=$(CDPATH='' cd -- "$REQUESTED_HOME" 2>/dev/null && pwd -P) || {
  printf 'fm-rtk: home unavailable\n' >&2
  exit 69
}
INSPECT_RESULT=$("$ENV_TOOL" -i PATH=/usr/bin:/bin \
  "$PERL_TOOL" -I "$FM_ROOT/lib" \
  -MFirstmate::RTKVerifier=success_message,verify_artifact -e '
    my ($home, $sha, $pin, @parts) = @ARGV;
    my $result = verify_artifact(
      home => $home,
      expected_sha => $sha,
      expected_os => "Darwin",
      expected_arch => "arm64",
      parts => \@parts,
      filename => "rtk",
    );
    print $result eq "verified" ? success_message($pin) : $result;
  ' "$EFFECTIVE_HOME" "$RTK_BINARY_SHA256" "$RTK_PIN" \
  data tools rtk "$RTK_PIN" "$RTK_PLATFORM" 2>/dev/null) || INSPECT_RESULT=invalid-artifact
case "$INSPECT_RESULT" in
  "fm-rtk: reviewed $RTK_PIN artifact bytes verified; execution remains disabled")
    printf '%s\n' "$INSPECT_RESULT"
    ;;
  unsupported-platform) printf 'fm-rtk: unsupported platform\n' >&2; exit 69 ;;
  not-executable) printf 'fm-rtk: artifact is not executable\n' >&2; exit 69 ;;
  timeout) printf 'fm-rtk: artifact inspection timed out\n' >&2; exit 69 ;;
  hash-mismatch) printf 'fm-rtk: artifact hash mismatch\n' >&2; exit 69 ;;
  *) printf 'fm-rtk: invalid artifact\n' >&2; exit 69 ;;
esac
