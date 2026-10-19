#!/usr/bin/perl
# tailscale/scripts/lib/hujson2json.pl — HuJSON (JSON + // and /* */ comments
# + trailing commas) on stdin -> JSON on stdout. String-aware. Exit 1 on an
# unterminated string or comment. Used by lint.sh (no HuJSON tool is installed).
use strict; use warnings;
local $/; my $s = <STDIN>; $s = '' unless defined $s;

sub scan {   # calls $cb->($char, $index) outside strings; copies strings verbatim
    my ($in, $cb) = @_; my $out = ''; my $n = length $in;
    for (my $i = 0; $i < $n; $i++) {
        my $c = substr($in, $i, 1);
        if ($c eq '"') {
            my $j = $i + 1;
            while ($j < $n) {
                my $d = substr($in, $j, 1);
                if ($d eq '\\') { $j += 2; next }
                last if $d eq '"';
                $j++;
            }
            die "hujson2json: unterminated string\n" if $j >= $n;
            $out .= substr($in, $i, $j - $i + 1); $i = $j; next;
        }
        my ($emit, $skip) = $cb->($c, $i, $in);
        $out .= $emit; $i += $skip;
    }
    return $out;
}

my $t = scan($s, sub {
    my ($c, $i, $in) = @_;
    my $nx = substr($in, $i + 1, 1);
    if ($c eq '/' && $nx eq '/') {
        my $j = index($in, "\n", $i); $j = length($in) if $j < 0;
        return ('', $j - $i - 1);
    }
    if ($c eq '/' && $nx eq '*') {
        my $j = index($in, '*/', $i + 2); die "hujson2json: unterminated comment\n" if $j < 0;
        return (' ', $j + 1 - $i);
    }
    return ($c, 0);
});
my $u = scan($t, sub {
    my ($c, $i, $in) = @_;
    if ($c eq ',') {
        my $rest = substr($in, $i + 1);
        return ('', 0) if $rest =~ /\A\s*[\]}]/;
    }
    return ($c, 0);
});
print $u;
