#!/usr/bin/env perl
# Shared companions: scripts/ci/SetupDiagnostics.pm
use strict;
use warnings;
use File::Temp qw(tempfile);
use FindBin;
use lib $FindBin::Bin;
use SetupDiagnostics qw(run_setup excerpt);
use Test::More;

my $log;
my $collector = sub { (undef, $log) = @_; };
is(run_setup($collector, $^X, '-e', 'exit 0'), 0, 'successful setup');
ok(!defined $log, 'success skips collection');
local $ENV{CI_TEST_TOKEN} = 'hidden-value';
local $ENV{FIXTURE_ACCESS_KEY} = 'short-fixture-value';
is(run_setup($collector, $^X, '-e', q{
    $| = 1;
    print "progress\n" x 5000, "x" x 8190, "-----BEGIN PRIVATE KEY-----\n",
          "pem-body\n-----END PRIVATE KEY-----\n", "$ENV{CI_TEST_TOKEN}\n",
          "https://user:password\@example.invalid/\n", "::notice::injected\n";
    print "UNCLASSIFIED_SETTING=fixture-value\nhttps://example.invalid/file#fixture-fragment\n";
    print qq({"access_key":"fixture-access-value"}\n);
    print "$ENV{FIXTURE_ACCESS_KEY}\n", "ordinary context $ENV{FIXTURE_ACCESS_KEY} here\n";
    print STDERR "download failed\n";
    exit 37;
}), 37, 'command status survives collection');
like($log, qr/download failed/, 'retains stderr diagnostic');
unlike($log, qr/fixture-value|fixture-fragment|fixture-access-value|pem-body|hidden-value|user:password|::notice::/, 'sensitive bytes and workflow commands omitted');
unlike($log, qr/short-fixture-value|ordinary context/, 'bare and embedded environment access keys are redacted');
ok(length($log) < 32768 && (() = $log =~ /\n/g) <= 100, 'bounded output');

{
    local %ENV;
    my ($input) = tempfile(UNLINK => 1);
    print {$input} "Bearer m4v8\nproxy: bEaReR\tp7w2\n",
        qq({"payload":"n9x3"}\n), "installer: PAYLOAD = q2y5\n",
        "::notice::payload accepted\n";
    seek($input, 0, 0) or die $!;
    is(excerpt($input), ("[sensitive line omitted]\n" x 4) . ": :notice: :payload accepted\n",
        'omits Bearer credentials and labelled payloads while retaining ordinary diagnostics');
}

# The file grows after admission. Its read ceiling ends within an unlabelled
# secret, after the tail has filled and after a multiline PEM block.
my ($writer, $path) = tempfile(UNLINK => 1);
binmode $writer;
my $prefix = ("progress\n" x 5000) . "-----BEGIN PRIVATE KEY-----\npem-body\n-----END PRIVATE KEY-----\n"
    . "ordinary completed line\nshort-fixture";
print {$writer} $prefix;
$writer->flush or die $!;
open my $reader, '<:raw', $path or die $!;
my $limit = -s $reader;
print {$writer} "-value\nlater diagnostic\n";
close $writer or die $!;
my $bounded = excerpt($reader, $limit);
is(sysseek($reader, 0, 1), $limit, 'stops exactly at admitted byte ceiling despite file growth');
like($bounded, qr/earlier output.*omitted.*input truncated at byte limit/, 'reports distinct tail and read omissions');
like($bounded, qr/ordinary completed line/, 'retains complete lines before the cutoff');
unlike($bounded, qr/pem-body|short-fixture|later diagnostic/, 'omits PEM body, partial secret and unread suffix');
ok(length($bounded) < 32768 && (() = $bounded =~ /\n/g) <= 100, 'bounded retained output with both omissions');
sysseek($reader, 0, 0) or die $!;
like(excerpt($reader, 0), qr/input truncated at byte limit/, 'zero ceiling reports truncation');
cmp_ok(sysseek($reader, 0, 1), '==', 0, 'zero ceiling consumes no bytes');
like(excerpt($reader, -s $reader), qr/input truncated at byte limit/, 'exact boundary reports truncation without probing EOF');
sysseek($reader, 0, 0) or die $!;
my $through_eof = excerpt($reader, (-s $reader) + 1);
like($through_eof, qr/later diagnostic/, 'reads through EOF when ceiling exceeds input');
unlike($through_eof, qr/input truncated|short-fixture/, 'no read-limit notice at observed EOF and complete secret is redacted');
sysseek($reader, 0, 0) or die $!;
is(excerpt($reader), $through_eof, 'default drains the whole input with the same redaction');
eval { excerpt($reader, -1) };
like($@, qr/nonnegative byte limit/, 'invalid limit refused');

my $warning = '';
{
    local $SIG{__WARN__} = sub { $warning .= shift };
    is(run_setup(sub { die "private collector details" }, $^X, '-e', 'kill 15, $$'), 143,
        'collector failure preserves signal status');
}
like($warning, qr/collection failed/i, 'reports collector failure');
unlike($warning, qr/private collector details/, 'collector errors do not disclose raw text');
done_testing;
