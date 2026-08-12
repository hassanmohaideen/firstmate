#!/bin/bash -p
# shellcheck disable=SC2016 # Perl owns the dollar expressions in its literal program.
exec /usr/bin/env -i \
  PATH=/usr/bin:/bin LC_ALL=C FM_HOME="${FM_HOME-}" \
  /usr/bin/perl -MCwd=abs_path -e '
    my $launcher = abs_path(shift) // exit 70;
    $launcher =~ m{\A(.+)/bin/fm-rtk\.sh\z} or exit 70;
    my $verifier = "$1/lib/Firstmate/rtk-run";
    my @stat = lstat($verifier);
    exit 70 unless @stat && !-l _ && -f _ && -r _;
    exec "/bin/bash", $verifier, @ARGV;
    exit 70;
  ' "$0" "$@"
exit 70
