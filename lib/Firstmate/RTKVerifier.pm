package Firstmate::RTKVerifier;

use strict;
use warnings;
use Digest::SHA ();
use Exporter qw(import);
use Fcntl qw(:DEFAULT);
use POSIX ();

our @EXPORT_OK = qw(success_message verify_artifact);

sub success_message {
  my ($pin) = @_;
  return "fm-rtk: reviewed $pin artifact bytes verified; execution remains disabled";
}

sub _effective_executable {
  my ($mode, $owner, $group, $euid, $groups) = @_;
  return ($mode & 0111) != 0 if $euid == 0;
  return ($mode & 0100) != 0 if $euid == $owner;
  my %groups = map { $_ => 1 } @$groups;
  return ($mode & 0010) != 0 if $groups{$group};
  return ($mode & 0001) != 0;
}

sub verify_artifact {
  my (%args) = @_;
  my ($real_os, undef, undef, undef, $real_arch) = POSIX::uname();
  my $os = exists $args{observed_os} ? $args{observed_os} : $real_os;
  my $arch = exists $args{observed_arch} ? $args{observed_arch} : $real_arch;
  return 'unsupported-platform'
    unless $os eq $args{expected_os} && $arch eq $args{expected_arch};

  my $euid = exists $args{effective_uid} ? $args{effective_uid} : $>;
  my @groups = exists $args{effective_groups}
    ? @{$args{effective_groups}}
    : split(/\s+/, $));
  my $directory_flags = O_RDONLY | O_NONBLOCK | O_NOFOLLOW;
  $directory_flags |= O_DIRECTORY if defined &O_DIRECTORY;
  my $result = 'invalid-artifact';
  open(my $original_directory, '<', '.') or return $result;

  eval {
    local $SIG{ALRM} = sub { die "inspection timeout\n" };
    alarm($args{timeout} // 5);
    sysopen(my $directory, $args{home}, $directory_flags) or die "home unavailable\n";
    my @directory_stat = stat($directory);
    die "invalid home\n"
      unless @directory_stat && (($directory_stat[2] & 0170000) == 0040000);
    chdir($directory) or die "home unavailable\n";
    my @directories = ($directory);

    for my $part (@{$args{parts}}) {
      sysopen(my $child, $part, $directory_flags) or die "component unavailable\n";
      my @child_stat = stat($child);
      die "invalid component\n"
        unless @child_stat && (($child_stat[2] & 0170000) == 0040000);
      chdir($child) or die "component unavailable\n";
      push @directories, $child;
    }

    sysopen(my $artifact, $args{filename}, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
      or die "artifact unavailable\n";
    my @stat = stat($artifact);
    die "invalid artifact\n"
      unless @stat && (($stat[2] & 0170000) == 0100000);
    my $owner = exists $args{artifact_uid} ? $args{artifact_uid} : $stat[4];
    my $group = exists $args{artifact_gid} ? $args{artifact_gid} : $stat[5];
    unless (_effective_executable(
      $stat[2], $owner, $group, $euid, \@groups
    )) {
      $result = 'not-executable';
      die "not executable\n";
    }

    binmode($artifact);
    my $sha = Digest::SHA->new(256);
    $sha->addfile($artifact);
    unless ($sha->hexdigest eq $args{expected_sha}) {
      $result = 'hash-mismatch';
      die "hash mismatch\n";
    }
    $result = 'verified';
    alarm 0;
    1;
  } or do {
    $result = 'timeout' if $@ eq "inspection timeout\n";
  };
  alarm 0;
  chdir($original_directory) or return 'invalid-artifact';
  return $result;
}

1;
