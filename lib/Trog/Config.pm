package Trog::Config;

# ABSTRACT: Read the configuration of a tCMS instance, and the shape of it

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use FindBin::libs;

use Config::Simple;
use File::Slurper();
use Ref::Util ();
use URI       ();

use Trog::Log qw{WARN};

=head1 Trog::Config

A thin wrapper around Config::Simple which reads the configuration from the appropriate place.

=head2 Trog::Config::get()

The configuration object that server.psgi, the data model and the routing
modules use.  It is memoized, so you need to HUP the children when the
configuration changes.

Reads $home_cfg, falling back to $default when the instance has never saved a
configuration of its own.  Both are full paths relative to the tCMS root, so
that writers can use them too.  An earlier version had the 'config/' prefix
hardcoded here and nowhere else, which meant that everything that I<wrote> the
configuration put it somewhere that get() would never look.

Returns Config::Simple, the configuration, the same object on each call.

Dies when neither file exists, or when Config::Simple cannot read the first
one that exists.

    my $conf = Trog::Config::get();

=cut

# Where an instance's own configuration lives, once it has saved one.
our $home_cfg = "config/main.cfg";

# Shipped defaults.  Tracked in git -- never write to this.
our $default = "share/default.cfg";

sub get {
    state $cf;
    return $cf if $cf;
    foreach my $cfg2try ( $home_cfg, $default ) {
        next unless -f $cfg2try;    ## no critic (ProhibitFiletest_f) -- the instance config, else the shipped default
        $cf = Config::Simple->new($cfg2try);
        last;
    }
    die "Could not find config file!" unless $cf;
    return $cf;
}

=head2 Trog::Config::media_base() = STRING

The base URL from C<general.media_base> in the configuration, with no slash at
the end.  It is empty if the setting is empty.  It is also empty, with a
warning, if the setting is not an absolute C<http> or C<https> URL with a host
and no query or fragment.

Returns Str, the base URL, or an empty string.

    my $base = Trog::Config::media_base();    # https://media.test.test

=cut

sub media_base {
    my $base = get()->param('general.media_base');

    # Config::Simple splits a value at each comma.
    $base = join( ',', @$base ) if Ref::Util::is_arrayref($base);
    $base //= '';
    return '' if $base eq '';

    my $uri = URI->new( $base =~ s{/+$}{}r );
    return "$uri" if ( $uri->scheme // '' ) =~ m/^https?$/ && $uri->host && !defined $uri->query && !defined $uri->fragment;

    WARN("general.media_base is not an http or https URL, so the assets stay on this host: $base");
    return '';
}

=head2 Trog::Config::schema($file)

The shape of the configuration, as described by the file that tCMS ships.

share/default.cfg is the only place which says what settings exist at all, so
it is also what the /config editor is built out of.  Add a key there and it
becomes editable.  Leave one out and it is not.

=over 4

=item file - Str - the path of the configuration file to read.  The default
is $default, F<share/default.cfg>.

=back

Returns ArrayRef[HashRef], one HashRef per section.  Sections and keys come
back in file order:

    [
        {
            section => 'general',
            fields  => [
                {
                    key     => 'data_model',
                    name    => 'general.data_model',
                    default => 'SQLite',
                    comment => 'FlatFile or SQLite. ...',
                },
            ],
        },
    ]

Comment lines accumulate until a key claims them, so a comment block is the
help text for whatever setting follows it.  Config::Simple throws both comments
and ordering away when it reads a file, which is why this reads it again rather
than asking the object that get() returns.

Keys that appear before any section header are skipped.  Config::Simple has
no name for them, so neither does this.

Dies when the file cannot be read.

    foreach my $section ( @{ Trog::Config::schema() } ) {
        say $_->{name} for @{ $section->{fields} };
    }

=cut

sub schema ( $file = $default ) {
    my ( @sections, $section, @comments );
    foreach my $line ( File::Slurper::read_lines($file) ) {
        $line =~ s/^\s+//;
        $line =~ s/\s+$//;
        next unless $line;

        if ( $line =~ m/^\[(\N+)\]$/ ) {
            $section = { section => $1, fields => [] };
            push( @sections, $section );
            @comments = ();
            next;
        }

        if ( $line =~ m/^[#;]\s?(\N*)$/ ) {
            push( @comments, $1 );
            next;
        }

        my ( $key, $value ) = $line =~ m/^([^=]+?)\s*=\s*(\N*)$/;
        next unless defined $key;
        next unless $section;

        push(
            @{ $section->{fields} },
            {
                key     => $key,
                name    => "$section->{section}.$key",
                default => $value,
                comment => join( ' ', @comments ),
            }
        );
        @comments = ();
    }

    return \@sections;
}

1;
