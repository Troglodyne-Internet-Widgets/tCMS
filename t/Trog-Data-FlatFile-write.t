#!/usr/bin/env perl
use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Test::More;
use File::Path ();
use FindBin;

use FindBin::libs;

my ( $ROOT, $OLDCWD );

BEGIN {
    require File::Temp;
    require Cwd;
    $OLDCWD = Cwd::getcwd();
    $ROOT   = File::Temp::tempdir( 'tcms-flatfile-XXXXXX', TMPDIR => 1, CLEANUP => 1 );

    # Text::Xslate and the loggers compute paths from $HOME or the cwd at load
    # time, and $datastore is relative, so both are set before the SUT loads.
    $ENV{HOME} = $ROOT;
    File::Path::make_path("$ROOT/data/files");
    File::Path::make_path("$ROOT/schema");

    # Trog::SQLite::TagIndex opens this path, relative, at load time.
    require File::Copy;
    File::Copy::copy( "$FindBin::Bin/../schema/flatfile.schema", "$ROOT/schema/flatfile.schema" ) or die $!;

    chdir($ROOT) or die "could not chdir to the sandbox: $!";
}

END {
    chdir($OLDCWD) if $OLDCWD;
}

require_ok('Trog::Data::FlatFile') or BAIL_OUT("Can't find SUT");

my $model = bless( {}, 'Trog::Data::FlatFile' );

sub post (%over) {
    return {
        tags       => [qw{blog public}],
        visibility => 'public',
        method     => 'GET',
        callback   => 'Trog::Routes::HTML::posts',
        aliases    => [],
        version    => 0,
        %over,
        local_href => "/posts/$over{id}",
    };
}

subtest 'write' => sub {
    $model->write( [ post( id => 'p-old', created => 1000 ) ] );
    $model->write( [ post( id => 'p-new', created => 2000 ) ] );
    is_deeply( [ Trog::SQLite::TagIndex::posts_for_tags('blog') ], [qw{p-new p-old}], 'the index lists the newer post first' );

    $model->write( [ post( id => 'p-old', created => 3000, version => 1, title => 'Edited' ) ] );
    is_deeply( [ Trog::SQLite::TagIndex::posts_for_tags('blog') ], [qw{p-new p-old}], 'and a new version of the older post leaves it where it was' );

    my ($post_time) = Trog::SQLite::TagIndex::dbh()->selectrow_array(q{SELECT DISTINCT created FROM posts WHERE id = 'p-old'});
    is( $post_time, 1000, 'because the index holds the date of its first version, which get() gives back as created' );

    $model->write( [ post( id => 'p-old', created => 4000, version => 2, tags => ['public'] ) ] );
    is_deeply( [ Trog::SQLite::TagIndex::posts_for_tags('blog') ], ['p-new'], 'the index still takes its tags from the newest version' );
};

done_testing();
