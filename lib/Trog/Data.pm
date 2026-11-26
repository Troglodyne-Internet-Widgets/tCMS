package Trog::Data;

# ABSTRACT: The factory that makes the data model which the configuration names

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Module::Runtime();
use Path::Tiny();

use Trog::Log qw{:all};

#It's just a factory

=head1 Trog::Data

This is a data model factory.

=head2 new($config)

Make the data model that model() chooses for $config, loading its class.

Memoized: every call after the first returns the first handle, whatever it is passed.

=over 4

=item config - Config::Simple - the configuration, as Trog::Config::get() returns it

=back

Returns Trog::DataModule, the data model, an object of a Trog::Data::* class.

Dies when the class of the data model cannot be loaded.

    my $data = Trog::Data->new( Trog::Config::get() );

=cut

sub new ( $, $config ) {
    state $datamodule;
    return $datamodule if $datamodule;

    my $module = "Trog::Data::" . model($config);
    Module::Runtime::require_module($module);
    $datamodule = $module->new($config);
    return $datamodule;
}

=head2 model($config)

The data model to serve from: general.data_model, except on a site which never
moved its posts across with bin/migrate.pl.

SQLite is the shipped default, so a FlatFile site which never saved a
data_model of its own, or which saved the default back, is configured for a
database that does not exist.  While data/posts.sqlite is missing and data/files
holds posts, this answers FlatFile and warns, so the site keeps serving the
posts it has.  Once the migration has written the database, the configuration
applies as written.  A function, not a method.

=over 4

=item config - Config::Simple - the configuration, as Trog::Config::get() returns it

=back

Returns Str, the name of the data model under Trog::Data, such as C<SQLite>.

    my $module = "Trog::Data::" . Trog::Data::model($config);

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

    my $posts = eval {
        scalar grep { -f } Path::Tiny::path($flatfile_store)->children;    ## no critic (ProhibitFiletest_f) -- counting names, nothing is opened
    } or return $model;

    WARN("general.data_model is SQLite, but $sqlite_db does not exist and $flatfile_store holds $posts post(s).  Serving them from FlatFile.  Run bin/migrate.pl to move them across.");
    return 'FlatFile';
}

1;
