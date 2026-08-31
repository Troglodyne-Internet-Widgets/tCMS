#!/usr/bin/env perl

use v5.36;
use re '/aa';

use Cwd            ();
use File::Basename ();
use File::Which    ();
use File::Copy     ();

=head1 SYNOPSIS

Render a favicon SVG out to every size and format a browser might ask for.

=head2 USAGE

    bin/favicon_mongler.pl /path/to/favicon.svg

Writes favicon-<size>.<ext> next to the source SVG for each size below, and
copies the 32x32 .ico to favicon.ico, which is what browsers guess at when a
page doesn't tell them otherwise.

The sizes are the ones which actually get asked for: 32 for the tab, 48 for the
desktop shortcut, 167 and 180 for iPads and iPhones, and 192 and 512 for the
web app manifest.

=head2 CAVEATS

Needs inkscape on the PATH to do the rendering, and dies if it isn't there.

Overwrites whatever is already at those paths without asking.

=cut

die "Usage:\n    favicon_mongler.pl /path/to/favicon.svg" unless $ARGV[0];
my $icon = Cwd::abs_path( $ARGV[0] );
my $bin  = File::Which::which('inkscape');
die "Please install inkscape" if !$bin;
my $dir = File::Basename::dirname($icon) || die "Can't figure out dir from $icon";

my %files = (
    32  => 'ico',
    48  => 'png',
    167 => 'png',
    180 => 'png',
    192 => 'png',
    512 => 'png',
);
foreach my $size ( sort { $b <=> $a } keys(%files) ) {
    print "*** Generating ${size}x${size} .$files{$size} now... ***\n";
    my @cmd = ( $bin, '-w', $size, '-h', $size, $icon, '-e', "$dir/favicon-$size.$files{$size}" );

    # There is no maintained Perl SVG rasterizer to bind instead -- Imager has
    # no SVG reader, and Image::LibRSVG was last released in 2006 -- so driving
    # the renderer as a subprocess is the only option here.
    system(@cmd) and die "Failed to run @cmd: " . ( $? == -1 ? $! : 'exit status ' . ( $? >> 8 ) );    ## no critic (logicLAB::ProhibitShellDispatch)
    print "*** Wrote $dir/favicon-$size.$files{$size} ***\n\n";
}

File::Copy::copy( "$dir/favicon-32.ico", "$dir/favicon.ico" );

0;
