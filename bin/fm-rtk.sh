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

SOURCE_PATH=${BASH_SOURCE[0]}
case "$SOURCE_PATH" in
  */*) SOURCE_DIR=${SOURCE_PATH%/*} ;;
  *) SOURCE_DIR=. ;;
esac
SCRIPT_DIR=$(CDPATH='' cd -- "$SOURCE_DIR" 2>/dev/null && pwd -P) || exit 70
FM_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 70
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

if ! trusted_executable "$PERL_TOOL" || ! trusted_executable "$ENV_TOOL"; then
  printf 'fm-rtk: trusted inspection utility unavailable\n' >&2
  exit 69
fi

REQUESTED_HOME=${FM_HOME:-$FM_ROOT}
EFFECTIVE_HOME=$(CDPATH='' cd -- "$REQUESTED_HOME" 2>/dev/null && pwd -P) || {
  printf 'fm-rtk: home unavailable\n' >&2
  exit 69
}
"$ENV_TOOL" -i PATH=/usr/bin:/bin "$PERL_TOOL" -MDigest::SHA -MFcntl=:DEFAULT -MPOSIX -e '
  use strict;
  use warnings;
  $SIG{ALRM} = sub { exit 68 };
  alarm 5;
  my ($home, $expected_sha, @parts) = @ARGV;
  my ($os, $node, $release, $version, $arch) = POSIX::uname();
  exit 64 unless $os eq "Darwin" && $arch eq "arm64";

  my $directory_flags = O_RDONLY | O_NONBLOCK | O_NOFOLLOW;
  $directory_flags |= O_DIRECTORY if defined &O_DIRECTORY;
  sysopen(my $directory, $home, $directory_flags) or exit 65;
  my @directory_stat = stat($directory);
  exit 66 unless @directory_stat && (($directory_stat[2] & 0170000) == 0040000);
  chdir($directory) or exit 65;
  for my $part (@parts) {
    sysopen(my $child, $part, $directory_flags) or exit 65;
    my @child_stat = stat($child);
    exit 66 unless @child_stat && (($child_stat[2] & 0170000) == 0040000);
    chdir($child) or exit 65;
    $directory = $child;
  }

  sysopen(my $fh, "rtk", O_RDONLY | O_NONBLOCK | O_NOFOLLOW) or exit 65;
  my @st = stat($fh);
  exit 66 unless @st && (($st[2] & 0170000) == 0100000);
  my $euid = $>;
  my %effective_groups = map { $_ => 1 } split(/\s+/, $));
  my $executable = $euid == 0 ? ($st[2] & 0111)
    : $euid == $st[4] ? ($st[2] & 0100)
    : $effective_groups{$st[5]} ? ($st[2] & 0010)
    : ($st[2] & 0001);
  exit 67 unless $executable;
  binmode($fh);
  my $sha = Digest::SHA->new(256);
  $sha->addfile($fh);
  exit 69 unless $sha->hexdigest eq $expected_sha;
' "$EFFECTIVE_HOME" "$RTK_BINARY_SHA256" \
  data tools rtk "$RTK_PIN" "$RTK_PLATFORM" 2>/dev/null
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
