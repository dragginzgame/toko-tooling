#!/usr/bin/env perl
# Shared companions: TOKO-TOOLING.md
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Temp qw(tempfile);
use FindBin;
use Getopt::Long qw(GetOptions);
use JSON::PP qw(decode_json);

my @exclude;
GetOptions('exclude=s@' => \@exclude) && @ARGV == 1
    or die "usage: $0 [--exclude REPO_RELATIVE_DIRECTORY] REPOSITORY\n";
for (@exclude) {
    length && !m{(?:^/|(?:^|/)(?:\.|\.\.)(?:/|$)|//|/$)}
        or die "expected a repository-relative directory: $_\n";
}

sub capture {
    my (@command) = @_;
    open my $pipe, '-|', @command or die "cannot run $command[0]: $!\n";
    local $/;
    my $output = <$pipe>;
    close $pipe or die "@command failed\n";
    return $output;
}

sub manifest {
    my ($path) = @_;
    return decode_json(capture('yq', '-p', 'toml', '-o', 'json', '.', $path));
}

# Read the canonical table directly so the audit follows baseline revisions.
open my $policy, '<', "$FindBin::Bin/../../TOKO-TOOLING.md" or die "open baseline: $!";
my $text = do { local $/; <$policy> };
my ($table) = $text =~ /^### Common Rust lint policy\n(?:(?!^###? ).)*?^```toml\n(.*?)^```$/ms;
defined $table or die "cannot find the common Rust lint table\n";
my ($temp, $path) = tempfile(TMPDIR => 1, UNLINK => 1);
print {$temp} $table or die "write baseline: $!";
close $temp or die "close baseline: $!";
my $minimum = manifest($path)->{workspace}{lints};
ref($minimum) eq 'HASH' && keys %$minimum or die "empty common Rust lint table\n";

my %rank = (allow => 0, warn => 1, deny => 2, forbid => 3);
my $findings = 0;
sub discrepancy {
    my ($file, $lint, $detail) = @_;
    print "$file: $lint: $detail\n";
    ++$findings;
}

sub setting {
    my ($value) = @_;
    return ref($value) eq 'HASH' ? ($value->{level}, $value->{priority} // 0) : ($value, 0);
}

sub audit {
    my ($file, $lints, $prefix) = @_;
    for my $tool (sort keys %$minimum) {
        my $actual = $lints->{$tool} // {};
        for my $name (sort keys %{$minimum->{$tool}}) {
            my ($expected) = setting($minimum->{$tool}{$name});
            my ($level, $priority) = setting($actual->{$name});
            my $lint = "$prefix.$tool.$name";
            my $want = $expected eq 'allow' ? 'allow' : "at least $expected";
            if (!defined $level || !exists $rank{$level} ||
                ($expected eq 'allow' ? $level ne 'allow' : $rank{$level} < $rank{$expected})) {
                discrepancy($file, $lint, "expected $want, found " . ($level // 'missing'));
            }
            # Preserve group precedence while permitting equivalent priority numbering.
            next unless $tool eq 'clippy' && defined $level && $name ne 'all';
            my $group = $name eq 'correctness' ? 'all' : 'correctness';
            my ($group_level, $group_priority) = setting($actual->{$group});
            if (defined $group_level && $priority <= $group_priority) {
                discrepancy($file, $lint, "priority $priority must exceed $group priority $group_priority");
            }
        }
    }
}

my $root = abs_path($ARGV[0]) // die "unknown repository: $ARGV[0]\n";
chdir $root or die "enter $root: $!";
capture('git', 'rev-parse', '--show-prefix') eq "\n" or die "expected a Git repository root\n";
my @files = split /\0/, capture('git', 'ls-files', '--cached', '--others', '--exclude-standard',
    '-z', '--', 'Cargo.toml', ':(glob)**/Cargo.toml');
my %files;
my @inheriting;
my %workspace_tables;
for my $file (sort @files) {
    next if exists $files{$file} || !-e $file;
    next if $file =~ m{(?:^|/)(?:vendor|node_modules|target|generated|third_party|third-party)(?:/|$)};
    next if grep { index($file, "$_/") == 0 } @exclude;
    -f $file && !-l $file && abs_path($file) eq "$root/$file" or die "unexpected manifest path: $file\n";
    my $data = manifest("./$file");
    $files{$file} = $data;
    if (exists $data->{workspace} && (!exists $data->{package} || exists $data->{workspace}{lints})) {
        $workspace_tables{$file} = 1;
    }
    next unless exists $data->{package};
    if ($data->{lints}{workspace}) {
        push @inheriting, $file;
    } else {
        audit($file, $data->{lints}, 'lints');
    }
}

# Cargo resolves package.workspace and workspace discovery without building packages.
local $ENV{RUSTUP_AUTO_INSTALL} = 0;
for my $file (@inheriting) {
    my $owner = capture('cargo', 'locate-project', '--workspace', '--manifest-path', $file, '--message-format', 'plain');
    chomp $owner;
    my $relative = substr($owner, length($root) + 1);
    index($owner, "$root/") == 0 && exists $files{$relative} && exists $files{$relative}{workspace}
        or die "$file: inherited lint owner outside the audited workspaces: $owner\n";
    $workspace_tables{$relative} = 1;
}
for my $file (sort keys %workspace_tables) {
    audit($file, $files{$file}{workspace}{lints} // {}, 'workspace.lints');
}
printf "Cargo manifests audited: %d. Lint discrepancies: %d.\n", scalar(keys %files), $findings;
exit($findings ? 1 : 0);
