#!/usr/bin/perl

use strict;
use warnings;

use Cwd            ();
use File::Basename ();
use File::Which    ();

die "Usage:\n    favicon_mongler.pl /path/to/favicon.svg" unless $ARGV[0];
my $icon = Cwd::abs_path($ARGV[0]);
my $bin = File::Which::which('inkscape');
die "Please install inkscape" if !$bin;
my $dir  = File::Basename::dirname($icon) || die "Can't figure out dir from $icon";

my %files = (
    180 => 'png',
    192 => 'png',
    512 => 'png',
);
foreach my $size ( sort { $b <=> $a } keys(%files) ) {
    print "*** Generating ${size}x${size} .$files{$size} now... ***\n";
    my @cmd = ( $bin, '-w', $size, '-h', $size, $icon, '-o', "$dir/favicon-$size.$files{$size}" );
    system(@cmd) && die "Failed to run @cmd: $!";
    print "*** Wrote $dir/favicon-$size.$files{$size} ***\n\n";
}

0;
