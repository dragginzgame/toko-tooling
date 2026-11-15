package FailureEvidence;
# Shared companions: scripts/ci/ic-tool-pins.awk
use strict;
use warnings;
use Exporter 'import';
use Archive::Tar::File;
use IO::Uncompress::Gunzip ();
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Temp qw(tempfile);
our @EXPORT_OK = qw(regular_evidence_archive verify_compact_tools verify_hosted_scenario);
my $pin_parser = dirname(abs_path(__FILE__)) . '/ic-tool-pins.awk';

# Read headers without extraction or path normalization. Archive::Tar::File owns
# tar header/checksum decoding; gzip and extension records retain exact bytes.
sub regular_evidence_archive {
    my ($path) = @_;
    my $stream = IO::Uncompress::Gunzip->new($path, Transparent => 0, Strict => 1, MultiStream => 1)
        or die "cannot read evidence archive: $IO::Uncompress::Gunzip::GunzipError\n";
    my $take = sub {
        my ($size) = @_;
        my $bytes = '';
        while (length($bytes) < $size) {
            my $count = $stream->read(my $part, $size - length($bytes));
            defined($count) && $count > 0 or die "truncated or corrupt evidence archive\n";
            $bytes .= $part;
        }
        return $bytes;
    };
    my (%members, %global, %local);
    my ($long_name, $long_link);
    while (1) {
        my $header = $take->(512);
        last if $header eq "\0" x 512;
        my $member = Archive::Tar::File->new(chunk => $header);
        $member && $member->validate or die "invalid tar header checksum\n";
        my $type = $member->type;
        my $extension = $type =~ /\A[xgLK]\z/;
        my %attributes = (%global, %local);
        my $size = !$extension && exists($attributes{size}) ? $attributes{size} : $member->size;
        defined($size) && $size =~ /\A[0-9]+\z/ or die "invalid tar member size\n";
        my $data = $take->($size);
        $take->((512 - $size % 512) % 512);
        if ($type eq 'x' || $type eq 'g') {
            my %records;
            while (length $data) {
                $data =~ /\A([1-9][0-9]*) / or die "invalid PAX record\n";
                my $length = $1;
                $length <= length($data) or die "truncated PAX record\n";
                my $record = substr($data, 0, $length, '');
                $record =~ /\A[1-9][0-9]* ([^=\n]+)=(.*)\n\z/s or die "invalid PAX record\n";
                my ($key,$value)=($1,$2);
                $key !~ /\AGNU\.sparse/ or die "sparse evidence archives are unsupported\n";
                $records{$key}=$value;
            }
            if ($type eq 'g') { @global{keys %records}=values %records; }
            else { @local{keys %records}=values %records; }
            next;
        }
        if ($type eq 'L' || $type eq 'K') {
            $data =~ s/\0.*\z//s;
            if ($type eq 'L') { $long_name=$data; } else { $long_link=$data; }
            next;
        }
        my $name = $attributes{path} // $long_name //
            (length($member->prefix // '') ? $member->prefix . '/' . $member->name : $member->name);
        $name =~ s{/+\z}{};
        $name =~ s{\A\./}{};
        length($name) && $name !~ m{\A/} && $name !~ /\0/ &&
            !grep { $_ eq '' || $_ eq '.' || $_ eq '..' } split m{/}, $name, -1
            or die "ambiguous or unsafe archive member\n";
        !exists($members{$name}) or die "ambiguous or unsafe archive member\n";
        $members{$name}={type=>$type, mode=>$member->mode, bytes=>$data};
        %local=(); undef $long_name; undef $long_link;
    }
    !keys(%local) && !defined($long_name) && !defined($long_link)
        or die "orphan tar extension record\n";
    # Reaching the tar terminator is not proof of gzip integrity. Consume the
    # remaining padding and trailer so CRC/length/truncation errors cannot hide
    # behind otherwise valid required members. Concatenated payloads refuse.
    while (1) {
        my $count = $stream->read(my $padding, 65536);
        defined($count) && $count >= 0 or die "corrupt gzip evidence trailer\n";
        last unless $count;
        $padding !~ /[^\0]/ or die "unexpected payload after tar terminator\n";
    }
    !length($stream->trailingData // '') or die "unexpected bytes after gzip evidence\n";
    $stream->close or die "cannot close evidence archive\n";
    my $read = sub {
        my ($name, $mode) = @_;
        my $member = $members{$name};
        defined($member) && ($member->{type} eq '0' || $member->{type} eq '')
            or die "missing regular evidence file: $name\n";
        !defined($mode) || $member->{mode} == $mode or die "incorrect retained mode: $name\n";
        return $member->{bytes};
    };
    return (\%members, $read);
}

sub pin_records {
    my ($pins) = @_;
    local $/ = "\n";
    my ($file, $path) = tempfile('evidence-pins.XXXXXX', TMPDIR => 1, UNLINK => 1);
    binmode $file;
    print {$file} $pins or die "cannot write pin input: $!\n";
    close $file or die $!;
    open my $parser, '-|', 'awk', '-f', $pin_parser, $path or die $!;
    my @records = <$parser>;
    close $parser or die "compact IC receipt has an invalid pin selection\n";
    return join '', sort @records;
}

sub verify_compact_tools {
    my ($members, $read, $pins, $native_host) = @_;
    ref($pins) eq 'HASH' && keys(%$pins) && !grep { $_ ne 'host' && $_ ne 'ic' } keys %$pins
        or die "expected a nonempty host/IC tool selection\n";
    for my $kind (qw(host ic)) {
        next unless exists $pins->{$kind};
        my $prefix = "tool-evidence/$kind/";
        $read->($prefix . 'caller-pins') eq $pins->{$kind}
            or die "compact evidence uses different caller pins\n";
        length($read->($prefix . 'check.log')) or die "compact evidence lost its fresh check log\n";
        my ($selection) = $read->($prefix . 'selection.txt') =~ m{\A.+/\.tools/($kind-set\.[A-Za-z0-9]+)\n\z}s;
        defined($selection) or die "compact evidence lost its managed selection identity\n";
        my $active = ".tools/$selection";
        !grep { $_ eq $active || index($_, "$active/") == 0 } keys %$members
            or die "verified active tool payload was not compacted\n";
    }
    return unless exists $pins->{ic};
    pin_records($read->('tool-evidence/ic/pins.tsv')) eq pin_records($pins->{ic})
        or die "compact IC receipt uses different caller pins\n";
    my %hosts = ('Linux/X64'=>"linux-x86_64\n", 'macOS/X64'=>"darwin-x86_64\n", 'macOS/ARM64'=>"darwin-arm64\n");
    exists($hosts{$native_host}) && $read->('tool-evidence/ic/host') eq $hosts{$native_host}
        or die "compact IC receipt identifies a different native host\n";
    length($read->('tool-evidence/ic/files.sha256')) or die "compact IC checksum receipt is empty\n";
}

sub verify_hosted_scenario {
    my ($members, $read, $stage, %options) = @_;
    $stage eq 'early' || $stage eq 'late' or die "expected early or late qualification\n";
    my ($parent, $logs) = @options{qw(scenario_parent failure_log_root)};
    for my $prefix ($parent, $logs) {
        defined($prefix) && length($prefix) && $prefix !~ m{\A/} &&
            !grep { $_ eq '' || $_ eq '.' || $_ eq '..' } split m{/}, $prefix, -1
            or die "expected canonical relative evidence prefixes\n";
    }
    my @scenarios = map { s{/status\.txt\z}{}r }
        grep { m{\A\Q$parent\E/hosted-\Q$stage\E\.[A-Za-z0-9]+/status\.txt\z} } keys %$members;
    @scenarios == 1 or die "expected exactly one selected qualification scenario\n";
    my $scenario = $scenarios[0];
    my $status = $stage eq 'early' ? 22 : 2;
    $read->("$scenario/status.txt") eq "stage=$stage\nstatus=$status\nexpected=$status\n"
        or die "controlled failure status was not retained\n";
    for my $name (qw(before.txt after.txt consumer/input.txt)) {
        $read->("$scenario/$name", 0640) eq "controlled $stage input\n"
            or die "scenario input bytes were not preserved\n";
    }
    my $marker = $stage eq 'early' ? 'error: controlled early installer download failure' : 'error: controlled late validation failure';
    index($read->("$scenario/scenario.log"), $marker) >= 0 or die "scenario did not reach the controlled failure\n";
    if ($stage eq 'early') {
        my @candidates = grep { m{\A\Q$scenario\E/tool-store/host-[0-9a-f]{64}/set\.[A-Za-z0-9]+/bin/jq\z} } keys %$members;
        @candidates == 1 && $read->($candidates[0]) eq "controlled rejected download bytes\n"
            or die "rejected installer candidate bytes were not retained\n";
    } else {
        my $raw = $read->("$logs/latest.log");
        (grep { $_ eq $marker } split /\r\n|\n|\r/, $raw) &&
            index($read->("$logs/latest-combined.log"), $raw) >= 0
            or die "raw/combined validation logs were not retained\n";
    }
}
1;
