package Trog::Data;

use v5.36;
use re '/aa';

use Trog::Log qw{:all};

#It's just a factory

=head1 Trog::Data

This is a data model factory.

=head2 Trog::Data->new(Trog::Config) = $handle

Returns a new Trog::Data::* class appropriate to what is configured in the Trog::Config object passed.

Memoized: every call after the first returns the first handle, whatever it is passed.

=cut

sub new ( $class, $config ) {
    state $datamodule;
    return $datamodule if $datamodule;

    my $module = "Trog::Data::" . model($config);
    my $req    = $module;
    $req =~ s/::/\//g;
    require "$req.pm";
    $datamodule = $module->new($config);
    return $datamodule;
}

=head2 model(Trog::Config) = STRING

The data model to serve from: general.data_model, except on a site which never
moved its posts across with bin/migrate.pl.

SQLite is the shipped default, so a FlatFile site which never saved a
data_model of its own, or which saved the default back, is configured for a
database that does not exist.  While data/posts.sqlite is missing and data/files
holds posts, this answers FlatFile and warns, so the site keeps serving the
posts it has.  Once the migration has written the database, the configuration
applies as written.

=cut

# FlatFile's datastore, named here because loading that model creates its tag
# index, and this has to look before choosing.  Trog::Data::FlatFile has its own.
our $flatfile_store = 'data/files';

sub model ($config) {
    my $model = $config->param('general.data_model');
    return $model unless $model eq 'SQLite';

    # Which that model only creates on first use.
    require Trog::Data::SQLite;
    no warnings 'once';
    my $sqlite_db = $Trog::Data::SQLite::dbname;
    return $model if -e $sqlite_db;

    opendir( my $dh, $flatfile_store ) or return $model;
    my $posts = grep { -f "$flatfile_store/$_" } readdir $dh;    ## no critic (ProhibitFiletest_f) -- counting names, nothing is opened
    closedir $dh;
    return $model unless $posts;

    WARN("general.data_model is SQLite, but $sqlite_db does not exist and $flatfile_store holds $posts post(s).  Serving them from FlatFile.  Run bin/migrate.pl to move them across.");
    return 'FlatFile';
}

1;
