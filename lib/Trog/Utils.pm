package Trog::Utils;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use UUID;
use HTTP::Tiny::UNIX();
use Plack::MIME;
use Mojo::File;
use File::LibMagic;
use Ref::Util qw{is_hashref};

use Trog::Log qw{WARN};
use Trog::Config();

# Deal with Params which may or may not be arrays
sub coerce_array ($param) {
    my $p = $param || [];
    $p = [$param] if $param && ( ref $param ne 'ARRAY' );
    return $p;
}

sub strip_and_trunc ($s) {
    return unless $s;
    $s =~ s/<[^>]*>//g;
    return substr $s, 0, 280;
}

sub uuid {
    return UUID::uuid();
}

#Stuff that isn't in upstream finders
my %extra_types = (
    '.docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
);

sub mime_type ($file) {

    # Use libmagic and if that doesn't work try guessing based on extension.
    my $mt;
    my $mf  = Mojo::File->new($file);
    my $ext = '.' . $mf->extname();
    $mt = Plack::MIME->mime_type($ext) if $ext;
    $mt ||= $extra_types{$ext} if exists $extra_types{$ext};
    return $mt                 if $mt;

    # If all else fails, time for libmagic
    state $magic = File::LibMagic->new;
    my $maybe_ct = $magic->info_from_filename($file);
    $mt = $maybe_ct->{mime_type} if ( is_hashref($maybe_ct) && $maybe_ct->{mime_type} );

    return $mt;
}

1;
