#!/usr/bin/env perl
# Shared companions: scripts/ci/release-timing.pl
use strict;
use warnings;
use FindBin qw($RealBin);
use lib $RealBin;
use ReleaseTiming;
use File::Temp qw(tempdir);
use File::Path qw(make_path remove_tree);
use Cwd qw(abs_path);
use Test::More;
use JSON::PP;
make_path("$RealBin/../../target/tmp");
my $dir=tempdir('release-timing.XXXXXXXX',DIR=>"$RealBin/../../target/tmp",CLEANUP=>0);
$dir=abs_path($dir);
local $ENV{RELEASE_TIMING_JOURNAL}="$dir/timings.jsonl";
local $ENV{RELEASE_TIMING_ATTEMPT}='original-attempt';
local $ENV{RELEASE_GROUP}='engine';
local $ENV{RELEASE_SOURCE}='a' x 40;
my $clock=100;
{
    no warnings 'redefine';
    local *ReleaseTiming::clock_gettime=sub {$clock};
    my $span=ReleaseTiming::begin('setup-prepare','executed','fixture');
    $clock+=2.5;ReleaseTiming::finish($span,0);
    eval {ReleaseTiming::measure('release-validate','executed','fixture',sub {$clock+=3;die "original failure\n"})};
    like($@,qr/original failure/,'original failure survives timing');
    my $interrupted=ReleaseTiming::begin('publication','executed','old-registry-attempt');
    $ENV{RELEASE_TIMING_ATTEMPT}='resumed-attempt';
    $clock+=10;
    my $reused=ReleaseTiming::begin('validation-stage:compile','reused','original-proof-attempt');
    $clock+=0.25;ReleaseTiming::finish($reused,0);
    my $fallback=ReleaseTiming::begin('validation-stage:compile','fallback','new-proof-attempt');
    $clock+=4;ReleaseTiming::finish($fallback,0);
}
my $rows=ReleaseTiming::report($ENV{RELEASE_TIMING_JOURNAL});
is(scalar(@$rows),5,'collector retains every attempt');
is($rows->[0]{elapsed_seconds},2.5,'substituted monotonic duration');
is($rows->[1]{result},'failed','failed phase retained');
is($rows->[1]{elapsed_seconds},3,'failed duration measured');
is($rows->[2]{result},'incomplete','interrupted phase stays incomplete');
ok(!exists($rows->[2]{elapsed_seconds}),'interruption has no invented duration');
is($rows->[3]{attempt},'resumed-attempt','resume identity distinct');
is($rows->[3]{origin},'original-proof-attempt','reuse preserves original proof identity');
is($rows->[3]{mode},'reused','reuse route explicit');
is($rows->[4]{mode},'fallback','fallback route explicit');
my $helper="$RealBin/release-timing.pl";
my $status=system($^X,$helper,'run','upload','executed',$^X,'-e','exit 23');
is($status>>8,23,'command wrapper preserves failure code');
$status=system($^X,$helper,'run','upload','executed',$^X,'-e','kill 9, getppid(); exit 0');
ok(($status & 127)==9,'timing owner interrupted by fixture child');
$rows=ReleaseTiming::report($ENV{RELEASE_TIMING_JOURNAL});
is($rows->[-1]{result},'incomplete','killed owner retains start without success');
my $before=-s $ENV{RELEASE_TIMING_JOURNAL};
open my $out,'-|',$^X,$helper,'report',$ENV{RELEASE_TIMING_JOURNAL} or die $!;
my $text=do {local $/;<$out>};close $out or die $!;
is(scalar(@{decode_json($text)}),7,'CLI collector reads all observations');
is(-s $ENV{RELEASE_TIMING_JOURNAL},$before,'collector does not mutate evidence');
{
    local $/;
    is(scalar(@{ReleaseTiming::report($ENV{RELEASE_TIMING_JOURNAL})}),7,
        'caller slurp mode does not change journal framing');
}
for my $fault (qw(missing-status null-status text-status boolean-status negative-status large-status
                  missing-duration null-duration negative-duration text-duration nan-duration infinite-duration
                  invalid-event invalid-id)) {
    my $start={schema=>1,event=>'started',id=>'corrupt'};
    my $finish={schema=>1,event=>'finished',id=>'corrupt',status=>0,elapsed_seconds=>1};
    delete $finish->{status} if $fault eq 'missing-status';
    $finish->{status}=undef if $fault eq 'null-status';
    $finish->{status}='not a status' if $fault eq 'text-status';
    $finish->{status}=JSON::PP::false if $fault eq 'boolean-status';
    $finish->{status}=-1 if $fault eq 'negative-status';
    $finish->{status}=256 if $fault eq 'large-status';
    delete $finish->{elapsed_seconds} if $fault eq 'missing-duration';
    $finish->{elapsed_seconds}=undef if $fault eq 'null-duration';
    $finish->{elapsed_seconds}=-1 if $fault eq 'negative-duration';
    $finish->{elapsed_seconds}='not a duration' if $fault eq 'text-duration';
    $finish->{elapsed_seconds}='NaN' if $fault eq 'nan-duration';
    $finish->{elapsed_seconds}='1e9999' if $fault eq 'infinite-duration';
    $start=[] if $fault eq 'invalid-event';
    $start->{id}=[] if $fault eq 'invalid-id';
    my $path="$dir/$fault.jsonl";
    my $bytes=encode_json($start)."\n".encode_json($finish)."\n";
    open my $file,'>',$path or die $!; print {$file} $bytes; close $file or die $!;
    eval {ReleaseTiming::report($path)};
    like($@,qr/invalid timing/,$fault.' refuses invented success');
    open $file,'<',$path or die $!;
    is(do {local $/;<$file>},$bytes,$fault.' preserves evidence');
    close $file or die $!;
}
{
    no warnings 'redefine';
    local *ReleaseTiming::finish=sub {die "timing unavailable\n"};
    local $SIG{__WARN__}=sub {};
    eval {ReleaseTiming::measure('failed','executed','fixture',sub {die "original command failure\n"})};
    like($@,qr/^original command failure/,'timing failure cannot replace the original command failure');
}
{
    local $ENV{RELEASE_TIMING_JOURNAL}='';
    is(system($^X,$helper,'run','upload','executed',$^X,'-e','exit 7')>>8,7,'outside batch command semantics unchanged');
}
symlink "$dir/timings.jsonl","$dir/link" or die $!;
{
    local $ENV{RELEASE_TIMING_JOURNAL}="$dir/link";
    eval {ReleaseTiming::begin('bad','executed','')};
    like($@,qr/symlink/,'symlink journal refused');
}
done_testing();
if (Test::More->builder->is_passing) {remove_tree($dir)} else {warn "Timing fixture retained: $dir\n";}
