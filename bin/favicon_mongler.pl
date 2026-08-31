#!/usr/bin/env perl

use v5.36;
use re '/aa';

use Cwd            ();
use File::Basename ();
use File::Which    ();
use File::Temp     ();
use List::Util     qw{uniq};

use Imager ();

=head1 SYNOPSIS

Render a favicon SVG out to every size and format a browser might ask for.

=head2 USAGE

    bin/favicon_mongler.pl /path/to/favicon.svg

Writes favicon-<size>.png next to the source SVG for each size below, plus a
favicon.ico, which is what browsers guess at when a page doesn't tell them
otherwise.

The PNG sizes are the ones which actually get asked for: 32 and 48 for the tab
and the desktop shortcut, 167 and 180 for iPads and iPhones, and 192 and 512
for the web app manifest.  Everything but the .ico is named in either
components/header.tx or Trog::Routes::JSON::webmanifest, so adding a size here
means adding it there too, and vice versa.

=head2 CAVEATS

Needs inkscape on the PATH to do the rendering, and dies if it isn't there.

Works with either era of inkscape.  1.0 reworked the command line and renamed
the export flag from -e to -o, and 1.x rejects -e outright, so the version is
read off the binary rather than assumed -- see _export_flag().

Overwrites whatever is already at those paths without asking.

Note that inkscape only ever exports PNG -- it has no idea what an .ico is.
Asking it for one, as this script used to, gets you a PNG with the wrong
extension.  The real container is assembled with Imager afterwards.

=cut

# Inkscape 1.0 reworked the command line: the export flag went from -e to -o,
# and 1.x errors out on -e rather than quietly accepting it.  Ask the binary
# which era it belongs to instead of guessing -- this script has already been
# flipped between the two by hand twice (e23b678, then back in 5f0cdca).
sub _export_flag ($bin) {

    # A list-form pipe open, rather than qx// or backticks, so the path to the
    # binary is handed over as an argument and never sees a shell.
    open( my $fh, '-|', $bin, '--version' ) or die "Could not run $bin --version: $!";
    my $version = do { local $/; <$fh> };
    close $fh;

    my ($major) = ( $version // '' ) =~ m/Inkscape\s+(\d+)/;
    die "Could not read a version out of `$bin --version`, got: " . ( $version // '(nothing)' ) unless defined $major;

    return $major >= 1 ? '-o' : '-e';
}

die "Usage:\n    favicon_mongler.pl /path/to/favicon.svg" unless $ARGV[0];
my $icon = Cwd::abs_path( $ARGV[0] );
my $bin  = File::Which::which('inkscape');
die "Please install inkscape" if !$bin;
my $dir = File::Basename::dirname($icon) || die "Can't figure out dir from $icon";

my $export = _export_flag($bin);

# The sizes the site links to directly.
my @png_sizes = qw{32 48 167 180 192 512};

# The sizes that go inside favicon.ico.  16 is not linked anywhere on its own,
# so it only ever exists as a member of the container.
my @ico_sizes = qw{16 32 48};

# Somewhere to put the sizes we need but don't want to leave lying around.
my $scratch = File::Temp->newdir();

# Render each size from the vector source rather than downscaling one big
# raster -- at 16 and 32 pixels the difference is the whole ballgame.
my %rendered;
foreach my $size ( sort { $b <=> $a } uniq( @png_sizes, @ico_sizes ) ) {
    my $keep = grep { $_ == $size } @png_sizes;
    my $out  = $keep ? "$dir/favicon-$size.png" : "$scratch/favicon-$size.png";

    print "*** Generating ${size}x${size} .png now... ***\n";
    my @cmd = ( $bin, '-w', $size, '-h', $size, $icon, $export, $out );

    # There is no maintained Perl SVG rasterizer to bind instead -- Imager has
    # no SVG reader, and Image::LibRSVG was last released in 2006 -- so driving
    # the renderer as a subprocess is the only option here.
    system(@cmd) and die "Failed to run @cmd: " . ( $? == -1 ? $! : 'exit status ' . ( $? >> 8 ) );    ## no critic (logicLAB::ProhibitShellDispatch)
    print "*** Wrote $out ***\n\n";

    $rendered{$size} = $out;
}

# An .ico is a container of several images, and browsers do pick the size they
# want out of it, so give them all three rather than one scaled at display time.
print "*** Generating favicon.ico (@{[ join 'x, ', @ico_sizes ]}x) now... ***\n";
my @members = map {
    my $img = Imager->new;
    $img->read( file => $rendered{$_} ) or die "Could not read $rendered{$_}: " . $img->errstr;
    $img;
} @ico_sizes;

Imager->write_multi( { file => "$dir/favicon.ico", type => 'ico' }, @members )
  or die "Could not write $dir/favicon.ico: " . Imager->errstr;
print "*** Wrote $dir/favicon.ico ***\n";

0;
