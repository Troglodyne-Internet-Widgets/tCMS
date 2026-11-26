package Trog::Utils;

# ABSTRACT: Small functions that more than one part of tCMS needs

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use UUID;
use Plack::MIME;
use Mojo::File;
use File::LibMagic;
use Ref::Util   qw{is_hashref};
use URI::Escape ();

=head1 Trog::Utils

Odds and ends which are needed in more than one place and belong to no
particular subsystem.

=head1 FUNCTIONS

=head2 coerce_array($param)

Deal with parameters which may or may not be arrays.

Query parameters arrive as a bare scalar when the caller passed one of
something, and as an arrayref when the caller passed several.  Without this
function, every consumer would have to check.

=over 4

=item param - Str|ArrayRef - the value of a query parameter

=back

Returns ArrayRef, $param itself when it is an ArrayRef, or a new ArrayRef that
holds $param.  When $param is false, the ArrayRef is empty, so the result is
always safe to dereference.

    my $tags = Trog::Utils::coerce_array( $query->{tags} );

=cut

sub coerce_array ($param) {
    my $p = $param || [];
    $p = [$param] if $param && ( ref $param ne 'ARRAY' );
    return $p;
}

=head2 strip_and_trunc($s)

Flatten a chunk of post body into something fit for a meta description or
preview blurb: the tags are stripped, and the text is truncated to 280
characters.

=over 4

=item s - Str - the HTML to flatten

=back

Returns Str, the text without tags, at most 280 characters long.  Returns
nothing (undef in scalar context) when $s is false, rather than an empty
string.

    my $meta_desc = Trog::Utils::strip_and_trunc($body) || '';

=cut

sub strip_and_trunc ($s) {
    return unless $s;
    $s =~ s/<[^>]*>//g;
    return substr $s, 0, 280;
}

=head2 path_href($path)

$path, the path of a file under F<www/>, such as C</assets/a b.mp4>, as a URL
path: each segment percent-encoded, and the slashes between them kept.  A file
name may hold a space, a question mark or a hash, and none of those survive in
an href as they are.  Give it the name of the file, not an href, or what is
encoded already is encoded again.

=over 4

=item path - Str - the path of the file under F<www/>

=back

Returns Str, the URL path.

    my $href = Trog::Utils::path_href("/assets/$newname");

=cut

sub path_href ($path) {
    return join( '/', map { local ($_) = $_; URI::Escape::uri_escape($_) } split( m{/}, $path, -1 ) );
}

=head2 uuid()

A fresh UUID.  A thin wrapper around UUID::uuid(), so that callers do not have
to care which of the several UUID modules tCMS uses.

Returns Str, the new UUID.

    my $token = Trog::Utils::uuid();

=cut

sub uuid {
    return UUID::uuid();
}

=head2 uuid_schema()

The JSON schema of what uuid() returns, for a route parameter that must be one.
The pattern ends with \z, because $ also matches before a final newline.

Returns HashRef, a new schema of type C<string> with a C<pattern> that matches
a lowercase UUID.

    my $schema = Trog::Utils::uuid_schema();

=cut

my $HEX  = qr/[[:digit:]a-f]/;
my $HEX4 = qr/(?: $HEX ){4}/;
my $UUID = qr/\A (?: $HEX ){8} - $HEX4 - $HEX4 - $HEX4 - (?: $HEX ){12} \z/;

sub uuid_schema {
    return { type => 'string', pattern => "$UUID" };
}

#Stuff that isn't in upstream finders
my %extra_types = (
    '.docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
);

=head2 mime_type($file)

Figure out the Content-Type of a file.

Tries the extension first, as that is cheap and right nearly all of the time.
It falls back to libmagic, which sniffs the contents of the file, only when
the extension tells nothing.  %extra_types patches in the handful of types
that the upstream finders do not know about.

=over 4

=item file - Str - the path of the file

=back

Returns Str, the MIME type, or undef if even libmagic cannot say.

    my $mime = Trog::Utils::mime_type("www/assets/$newname");

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
