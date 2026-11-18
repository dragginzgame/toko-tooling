#!/usr/bin/env perl
# Shared companions: scripts/ci/SetupDiagnostics.pm
use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use SetupDiagnostics qw(run_setup);
use Test::More;

my $log;
my $collector = sub { (undef, $log) = @_; };
is(run_setup($collector, $^X, '-e', 'exit 0'), 0, 'successful setup');
ok(!defined $log, 'success skips collection');
local $ENV{CI_TEST_TOKEN} = 'hidden-value';
is(run_setup($collector, $^X, '-e', q{
    $| = 1;
    print "progress\n" x 5000, "x" x 8190, "-----BEGIN PRIVATE KEY-----\n",
          "pem-body\n-----END PRIVATE KEY-----\n", "$ENV{CI_TEST_TOKEN}\n",
          "https://user:password\@example.invalid/\n", "::notice::injected\n";
    print STDERR "download failed\n";
    exit 37;
}), 37, 'command status survives collection');
like($log, qr/download failed/, 'retains stderr diagnostic');
unlike($log, qr/pem-body|hidden-value|user:password|::notice::/, 'sensitive bytes and workflow commands omitted');
ok(length($log) < 32768 && (() = $log =~ /\n/g) <= 100, 'bounded output');
my $warning = '';
{
    local $SIG{__WARN__} = sub { $warning .= shift };
    is(run_setup(sub { die "private collector details" }, $^X, '-e', 'kill 15, $$'), 143,
        'collector failure preserves signal status');
}
like($warning, qr/collection failed/i, 'reports collector failure');
unlike($warning, qr/private collector details/, 'collector errors do not disclose raw text');
done_testing;
