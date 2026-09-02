package Trog::Config;

use v5.36;
use re '/aa';

use FindBin::libs;

use Config::Simple;

=head1 Trog::Config

A thin wrapper around Config::Simple which reads the configuration from the appropriate place.

=head2 Trog::Config::get() = Config::Simple

Returns a configuration object that will be used by server.psgi, the data model and Routing modules.
Memoized, so you will need to HUP the children on config changes.

Reads $home_cfg, falling back to $default when the instance has never saved a
configuration of its own.  Both are full paths relative to the tCMS root, so
that writers can use them too -- an earlier version had the 'config/' prefix
hardcoded here and nowhere else, which meant everything that *wrote* the
configuration put it somewhere get() would never look.

=cut

# Where an instance's own configuration lives, once it has saved one.
our $home_cfg = "config/main.cfg";

# Shipped defaults.  Tracked in git -- never write to this.
our $default = "config/default.cfg";

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

=head2 Trog::Config::schema( STRING file = $default ) = ARRAYREF

The shape of the configuration, as described by the file we ship.

config/default.cfg is the only place which says what settings exist at all, so
it is also what the /config editor is built out of -- add a key there and it
becomes editable, leave one out and it isn't.  Sections and keys come back in
file order:

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
than asking the object we already have.

Keys appearing before any section header are skipped -- Config::Simple has no
name for them, so neither do we.

=cut

sub schema ( $file = $default ) {
    open( my $fh, '<', $file ) or die "Could not read $file: $!";

    my ( @sections, $section, @comments );
    while ( my $line = readline($fh) ) {
        chomp $line;
        $line =~ s/^\s+//;
        $line =~ s/\s+$//;
        next unless length $line;

        if ( $line =~ m/^\[(.+)\]$/ ) {
            $section = { section => $1, fields => [] };
            push( @sections, $section );
            @comments = ();
            next;
        }

        if ( $line =~ m/^[#;]\s?(.*)$/ ) {
            push( @comments, $1 );
            next;
        }

        my ( $key, $value ) = $line =~ m/^([^=]+?)\s*=\s*(.*)$/;
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
    close($fh);

    return \@sections;
}

1;
