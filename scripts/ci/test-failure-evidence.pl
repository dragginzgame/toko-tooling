#!/usr/bin/env perl
# Shared companions: scripts/ci/FailureEvidence.pm ci/ic-tools.tsv
use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use FailureEvidence qw(regular_evidence_archive verify_compact_tools verify_hosted_scenario);
use Archive::Tar;
use IO::Compress::Gzip qw(gzip $GzipError);
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use File::Temp qw(tempdir);
use File::Path qw(remove_tree);
use Test::More;
my $fixture = tempdir('failure-evidence.XXXXXX', TMPDIR => 1, CLEANUP => 0);
END {
    my $status = $?;
    if (defined $fixture) {
        if ($status == 0 && Test::More->builder->is_passing) { remove_tree($fixture); }
        else { warn "Evidence verifier fixtures retained: $fixture\n"; }
    }
    $? = $status;
}
my $path = "$fixture/evidence.tar.gz";
sub archive {
    my (@entries) = @_;
    my $tar = Archive::Tar->new;
    for my $entry (@entries) {
        my ($name, $bytes, $mode, $type) = @$entry;
        my $member = $tar->add_data($name, defined($type) && $type =~ /\A[125]\z/ ? '' : $bytes,
            {mode=>$mode // 0644, type=>$type // '0', linkname=>'outside'});
        # Construct the literal header; add_data otherwise normalizes aliases.
        $member->name($name);
        $member->prefix('');
    }
    local $Archive::Tar::DO_NOT_USE_PREFIX = 1;
    $tar->write($path, 1) or die $tar->error;
}
sub rejects {
    my ($code, $label) = @_;
    my $ok = eval { $code->(); 1 };
    ok(!$ok && length($@), $label);
}
for my $kind (qw(valid duplicate alias-duplicate absolute parent prefixed-parent dot separator alias symlink hardlink directory mode)) {
    my %names = (absolute=>'/input',parent=>'../input','prefixed-parent'=>'./../input',dot=>'inside/./input',separator=>'inside//input',alias=>'././input');
    my %types = (symlink=>'2',hardlink=>'1',directory=>'5');
    my @entries = ([$names{$kind} // 'input', 'bytes', $kind eq 'mode' ? 0644 : 0640, $types{$kind}]);
    push @entries, ['input','bytes',0640] if $kind eq 'duplicate';
    push @entries, ['./input','bytes',0640] if $kind eq 'alias-duplicate';
    archive(@entries);
    my $verify = sub { my ($members,$read)=regular_evidence_archive($path); return $read->('input',0640); };
    if ($kind eq 'valid') { is($verify->(), 'bytes', 'regular archive bytes and mode'); }
    else { rejects($verify,"archive refuses $kind"); }
}
archive(['./input','bytes',0640]);
my ($members,$read)=regular_evidence_archive($path);
is($read->('input',0640),'bytes','one conventional prefix is normalized');
rejects(sub {$read->('missing')},'missing regular file');
open my $compressed, '<', $path or die $!;
binmode $compressed;
my $valid_gzip = do { local $/; <$compressed> }; close $compressed;
for my $fault (qw(crc length truncated trailing concatenated)) {
    my $bytes = $valid_gzip;
    if ($fault eq 'crc' || $fault eq 'length') {
        my $offset = $fault eq 'crc' ? -8 : -4;
        substr($bytes,$offset,1)=chr(ord(substr($bytes,$offset,1)) ^ 255);
    } elsif ($fault eq 'truncated') { substr($bytes,-5)=''; }
    elsif ($fault eq 'trailing') { $bytes .= 'unadmitted trailing bytes'; }
    else { $bytes .= $valid_gzip; }
    open my $damaged, '>', $path or die $!; binmode $damaged;
    print {$damaged} $bytes; close $damaged;
    rejects(sub { regular_evidence_archive($path) }, "gzip $fault cannot hide behind valid tar members");
}
open my $broken, '>', "$fixture/broken" or die $!;
print {$broken} 'not a gzip archive'; close $broken;
rejects(sub {regular_evidence_archive("$fixture/broken")},'malformed archive');
# A valid first member must not make a damaged later header acceptable.
archive(['first','bytes',0640],['second','more',0640]);
my $raw;
gunzip $path => \$raw or die $GunzipError;
substr($raw,1024,1)='!';
gzip \$raw => $path or die $GzipError;
rejects(sub {regular_evidence_archive($path)},'partial archive rejected after valid first member');
my $empty="\0" x 1024;
gzip \$empty => $path or die $GzipError;
my ($empty_members,$empty_read)=regular_evidence_archive($path);
is(scalar(keys %$empty_members),0,'empty archive indexes without inventing evidence');
rejects(sub {$empty_read->('required')},'empty archive cannot satisfy required reads');
sub pax_record {
    my ($key,$value)=@_;
    my $length=length(" $key=$value\n")+1;
    $length=length("$length $key=$value\n") while length("$length $key=$value\n") != $length;
    return "$length $key=$value\n";
}
for my $name ('retained/input','./retained/input','../escape','././alias','a//b','a/./b','/absolute') {
    archive(['PaxHeader',pax_record('path',$name),0644,'x'],['placeholder','bytes',0640]);
    my $verify=sub { my ($m,$r)=regular_evidence_archive($path); $r->('retained/input',0640) };
    if ($name =~ /retained/) { is($verify->(),'bytes','PAX path overrides placeholder'); }
    else { rejects($verify,"unsafe PAX path $name"); }
}
archive(['GlobalHeader',pax_record('comment','metadata'),0644,'g'],['input','bytes',0640]);
my ($global_members,$global_read)=regular_evidence_archive($path);
is($global_read->('input'),'bytes','global PAX metadata admitted');
archive(['input','first',0640],['PaxHeader',pax_record('path','./input'),0644,'x'],['placeholder','second',0640]);
rejects(sub {regular_evidence_archive($path)},'PAX alias cannot hide duplicate');
archive(['PaxHeader','99 path=truncated',0644,'x'],['input','bytes',0640]);
rejects(sub {regular_evidence_archive($path)},'malformed PAX length');
archive(['PaxHeader',pax_record('GNU.sparse.map','0,5'),0644,'x'],['input','bytes',0640]);
rejects(sub {regular_evidence_archive($path)},'unsupported sparse layout refuses');
archive(['PaxHeader',pax_record('path','input'),0644,'x']);
rejects(sub {regular_evidence_archive($path)},'orphan extension refuses');
mkdir "$fixture/native" or die $!;
open my $native,'>',"$fixture/native/input" or die $!; print {$native} 'native bytes'; close $native;
system('tar','-czf',"$fixture/native.tar.gz",'-C',$fixture,'native') == 0 or die 'native tar failed';
my ($native_members,$native_read)=regular_evidence_archive("$fixture/native.tar.gz");
is($native_read->('native/input'),'native bytes','native archive roundtrip without extraction');

open my $pins_file, '<', "$FindBin::Bin/../../ci/ic-tools.tsv" or die $!;
my $pins = do {local $/; <$pins_file>}; close $pins_file;
my ($first) = grep {length && !/^#/} split /\n/, $pins;
my @fields = split /\t/, $first;
my $other_version=join "\t",$fields[0],'999.0.0',@fields[2,3];
my $other_digest=join "\t",@fields[0..2],($fields[3] eq '1'x64 ? '2'x64 : '1'x64);
my %tool_pins=(host=>"caller host pins\n",ic=>$pins);
my %files;
for my $kind (qw(host ic)) {
    my $prefix="tool-evidence/$kind/";
    $files{$prefix.'caller-pins'}=$tool_pins{$kind};
    $files{$prefix.'check.log'}="fresh check\n";
    $files{$prefix.'selection.txt'}="/consumer/.tools/$kind-set.ABC123\n";
}
$files{'tool-evidence/ic/pins.tsv'}=$pins;
$files{'tool-evidence/ic/host'}="linux-x86_64\n";
$files{'tool-evidence/ic/files.sha256'}="nonempty receipt\n";
my $read_files=sub { exists $files{$_[0]} or die "missing required file\n"; $files{$_[0]} };
verify_compact_tools({},$read_files,\%tool_pins,'Linux/X64');
pass('compact tools admitted');
for my $change (
    ['ic/caller-pins','different'], ['host/caller-pins','different'], ['ic/pins.tsv','malformed'],
    ['ic/pins.tsv', $pins =~ s/\Q$first\E/$other_version/r],
    ['ic/pins.tsv', $pins =~ s/\Q$first\E/$other_digest/r], ['ic/pins.tsv', $pins.$first."\n"],
    ['ic/host',"darwin-arm64\n"], ['host/check.log',''], ['ic/check.log',''], ['ic/files.sha256',''],
    ['host/selection.txt',"/consumer/.tools/host-set.ABC123\n\n"], ['ic/selection.txt','invalid']) {
    my ($name,$value)=@$change; $name="tool-evidence/$name";
    local $files{$name}=$value;
    rejects(sub {verify_compact_tools({},$read_files,\%tool_pins,'Linux/X64')},"corrupt $name");
}
my %all_files=%files;
for my $kinds ([qw(host)], [qw(ic)], [qw(host ic)]) {
    my %selected=map {$_=>$tool_pins{$_}} @$kinds;
    %files=map {$_=>$all_files{$_}} grep { my ($kind)=m{^tool-evidence/([^/]+)/}; exists $selected{$kind} } keys %all_files;
    verify_compact_tools({},$read_files,\%selected,'Linux/X64');
    pass("selection @$kinds");
    for my $name (sort keys %files) {
        my $saved=delete $files{$name};
        rejects(sub {verify_compact_tools({},$read_files,\%selected,'Linux/X64')},"@$kinds missing $name");
        $files{$name}=$saved;
    }
    for my $kind (@$kinds) {
        for my $member (".tools/$kind-set.ABC123", ".tools/$kind-set.ABC123/bin/tool") {
            rejects(sub {verify_compact_tools({$member=>undef},$read_files,\%selected,'Linux/X64')},"payload retained $member");
        }
    }
    if (!exists $selected{ic}) {
        $files{'tool-evidence/ic/caller-pins'}='stale diagnostics';
        verify_compact_tools({'.tools/ic-set.ABC123/bin/tool'=>undef},$read_files,\%selected,'Other/Host');
        pass('unselected IC diagnostics are ignored');
    } else {
        for my $host ('Other/Host','macOS/X64','macOS/ARM64') {
            rejects(sub {verify_compact_tools({},$read_files,\%selected,$host)},"wrong host $host");
        }
    }
}
%files=%all_files;
for my $selected ({},{unknown=>'pins'},{%tool_pins,unknown=>'pins'}) {
    rejects(sub {verify_compact_tools({},$read_files,$selected,'Linux/X64')},'invalid selection');
}
$files{'tool-evidence/ic/pins.tsv'}="# installation receipt\n".join("\n",reverse split /\n/,$pins)."\n";
verify_compact_tools({},$read_files,\%tool_pins,'Linux/X64');
pass('receipt order/comments preserve admitted selection');

for my $stage (qw(early late)) {
    my ($parent,$logs)=('consumer fixtures/[selected]','consumer logs/validation');
    my $scenario="$parent/hosted-$stage.ABC123";
    my $marker=$stage eq 'early' ? "error: controlled early installer download failure\n" : "error: controlled late validation failure\n";
    my $status=$stage eq 'early' ? 22 : 2;
    my %entries=("$scenario/status.txt"=>["stage=$stage\nstatus=$status\nexpected=$status\n",0644],
        "$scenario/scenario.log"=>[$marker,0644]);
    $entries{"$scenario/$_"}=["controlled $stage input\n",0640] for qw(before.txt after.txt consumer/input.txt);
    my $payload;
    if ($stage eq 'early') {
        $payload="$scenario/tool-store/host-".('0'x64).'/set.ABC123/bin/jq';
        $entries{$payload}=["controlled rejected download bytes\n",0644];
    } else {
        $payload="$logs/latest-combined.log";
        $entries{$payload}=["batch\n$marker",0644];
        $entries{"$logs/latest.log"}=[$marker,0644];
    }
    my $verify=sub {
        my ($entries,$selected,$prefixes,$link)=@_;
        $selected //= $stage; $prefixes //= [$parent,$logs];
        archive((map {[$_,@{$entries->{$_}}]} sort keys %$entries), defined($link) ? ([$link,'',0644,'2']) : ());
        my ($m,$r)=regular_evidence_archive($path);
        verify_hosted_scenario($m,$r,$selected,scenario_parent=>$prefixes->[0],failure_log_root=>$prefixes->[1]);
    };
    $verify->(\%entries); pass("$stage evidence");
    $verify->({map {("./$_"=>$entries{$_})} keys %entries}); pass("$stage prefixed evidence");
    for my $invalid ('','other',"early\n","late\n",$stage eq 'early' ? 'late' : 'early') {
        rejects(sub {$verify->(\%entries,$invalid)},"$stage invalid stage [$invalid]");
    }
    for my $index (0,1) {
        for my $invalid ('','/absolute','../outside','inside/./alias','inside//alias','trailing/') {
            my @prefixes=($parent,$logs); $prefixes[$index]=$invalid;
            rejects(sub {$verify->(\%entries,$stage,\@prefixes)},"invalid prefix $index [$invalid]");
        }
    }
    my $other=$scenario =~ s/ABC123/DEF456/r;
    rejects(sub {$verify->({%entries,"$other/status.txt"=>$entries{"$scenario/status.txt"}})},'ambiguous scenario');
    for my $name (sort keys %entries) {
        my %missing=%entries; delete $missing{$name};
        rejects(sub {$verify->(\%missing)},"missing $name");
        rejects(sub {$verify->(\%missing,$stage,[$parent,$logs],$name)},"symlink $name");
    }
    for my $change (["$scenario/after.txt",['changed',0640]],
        ["$scenario/before.txt",["controlled $stage input\n",0644]],
        ["$scenario/status.txt",['status=0',0644]], ["$scenario/scenario.log",['setup outage',0644]],
        [$payload,['damaged retained bytes',0644]]) {
        rejects(sub {$verify->({%entries,$change->[0]=>$change->[1]})},"corrupt $change->[0]");
    }
    if ($stage eq 'early') {
        for my $wrong ("$scenario/consumer/.tools/host-set.ABC123/bin/jq",
            $payload =~ s/0{64}/invalid/r, $payload =~ s/set.ABC123/set.invalid-name/r) {
            my %changed=%entries; delete $changed{$payload}; $changed{$wrong}=$entries{$payload};
            rejects(sub {$verify->(\%changed)},"wrong candidate $wrong");
        }
        my $other=$payload =~ s/set.ABC123/set.DEF456/r;
        rejects(sub {$verify->({%entries,$other=>$entries{$payload}})},'ambiguous rejected candidate');
    } else {
        rejects(sub {$verify->({%entries,"$logs/latest.log"=>["prefix $marker",0644],$payload=>["prefix $marker",0644]})},'raw marker must be a whole line');
    }
}
done_testing;
