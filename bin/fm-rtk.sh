#!/usr/bin/env bash
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

SOURCE_PATH=${BASH_SOURCE[0]}
SOURCE_NAME=${SOURCE_PATH##*/}
case "$SOURCE_PATH" in
  */*) SOURCE_DIR=${SOURCE_PATH%/*} ;;
  *) SOURCE_DIR=. ;;
esac
SCRIPT_DIR=$(CDPATH='' cd -- "$SOURCE_DIR" 2>/dev/null && pwd -P) || exit 70
FM_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 70
RTK_PIN=v0.45.0
RTK_PLATFORM=aarch64-apple-darwin
RTK_BINARY_SHA256=17d00d61a533a442c61f1be49d8a9321225557f64021d5b70fd8eb75ed8fb0be
TEST_SYSTEM_ROOT=
TEST_OS=
TEST_ARCH=
if [ "$SOURCE_NAME" = fm-rtk-test-driver.sh ] && [ -n "${FM_RTK_TEST_SYSTEM_ROOT:-}" ]; then
  case "$FM_RTK_TEST_SYSTEM_ROOT" in
    /*)
      TEST_SYSTEM_ROOT=$FM_RTK_TEST_SYSTEM_ROOT
      TEST_OS=${FM_RTK_TEST_OS:-Darwin}
      TEST_ARCH=${FM_RTK_TEST_ARCH:-arm64}
      ;;
  esac
fi
if [ -n "$TEST_SYSTEM_ROOT" ]; then
  SYS_USR_BIN=$TEST_SYSTEM_ROOT/usr/bin
  [ -z "${FM_RTK_TEST_SHA256:-}" ] || RTK_BINARY_SHA256=$FM_RTK_TEST_SHA256
else
  SYS_USR_BIN=/usr/bin
fi
PERL_TOOL=$SYS_USR_BIN/perl
ENV_TOOL=$SYS_USR_BIN/env

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

if ! trusted_executable "$PERL_TOOL" || ! trusted_executable "$ENV_TOOL"; then
  printf 'fm-rtk: trusted inspection utility unavailable\n' >&2
  exit 69
fi

REQUESTED_HOME=${FM_HOME:-$FM_ROOT}
EFFECTIVE_HOME=$(CDPATH='' cd -- "$REQUESTED_HOME" 2>/dev/null && pwd -P) || {
  printf 'fm-rtk: home unavailable\n' >&2
  exit 69
}
ARTIFACT=$EFFECTIVE_HOME/data/tools/rtk/$RTK_PIN/$RTK_PLATFORM/rtk

"$ENV_TOOL" -i PATH=/usr/bin:/bin "$PERL_TOOL" -MDigest::SHA -MFcntl=:DEFAULT -MPOSIX -e '
  use strict;
  use warnings;
  $SIG{ALRM} = sub { exit 68 };
  alarm 5;
  my ($path, $expected_sha, $test_os, $test_arch) = @ARGV;
  my ($os, $node, $release, $version, $arch) = POSIX::uname();
  $os = $test_os if length $test_os;
  $arch = $test_arch if length $test_arch;
  exit 64 unless $os eq "Darwin" && $arch eq "arm64";
  sysopen(my $fh, $path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW) or exit 65;
  my @st = stat($fh);
  exit 66 unless @st && (($st[2] & 0170000) == 0100000);
  exit 67 unless ($st[2] & 0111);
  binmode($fh);
  my $sha = Digest::SHA->new(256);
  $sha->addfile($fh);
  exit 69 unless $sha->hexdigest eq $expected_sha;
' "$ARTIFACT" "$RTK_BINARY_SHA256" "$TEST_OS" "$TEST_ARCH" 2>/dev/null
INSPECT_RC=$?
case "$INSPECT_RC" in
  0) ;;
  64) printf 'fm-rtk: unsupported platform\n' >&2; exit 69 ;;
  67) printf 'fm-rtk: artifact is not executable\n' >&2; exit 69 ;;
  68) printf 'fm-rtk: artifact inspection timed out\n' >&2; exit 69 ;;
  69) printf 'fm-rtk: artifact hash mismatch\n' >&2; exit 69 ;;
  *) printf 'fm-rtk: invalid artifact\n' >&2; exit 69 ;;
esac

printf 'fm-rtk: reviewed %s artifact bytes verified; execution remains disabled\n' "$RTK_PIN"
