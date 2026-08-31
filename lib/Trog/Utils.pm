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

=head1 Trog::Utils

Odds and ends which are needed in more than one place and belong to no
particular subsystem.

=head1 FUNCTIONS

=head2 coerce_array(SCALAR|ARRAYREF param) = ARRAYREF

Deal with Params which may or may not be arrays.

Query parameters arrive as a bare scalar when the caller passed one of
something and as an arrayref when they passed several, which means every
consumer would otherwise have to check.  Returns an empty arrayref for anything
false, so the result is always safe to dereference.

=cut

sub coerce_array ($param) {
    my $p = $param || [];
    $p = [$param] if $param && ( ref $param ne 'ARRAY' );
    return $p;
}

=head2 strip_and_trunc(STRING s) = STRING

Flatten a chunk of post body into something fit for a meta description or
preview blurb -- tags stripped, truncated to 280 characters.

Returns undef when handed nothing, rather than an empty string.

=cut

sub strip_and_trunc ($s) {
    return unless $s;
    $s =~ s/<[^>]*>//g;
    return substr $s, 0, 280;
}

=head2 uuid() = STRING

A fresh UUID.  Thin wrapper around UUID::uuid(), so that callers don't have to
care which of the several UUID modules we ended up using.

=cut

sub uuid {
    return UUID::uuid();
}

#Stuff that isn't in upstream finders
my %extra_types = (
    '.docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
);

=head2 mime_type(STRING file) = STRING

Figure out a file's Content-Type.

Tries the extension first, as that's cheap and right nearly all of the time,
and only falls back to libmagic sniffing the file's contents when the extension
tells us nothing.  %extra_types patches in the handful of types the upstream
finders don't know about.

Returns undef if even libmagic can't say.

=cut

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
