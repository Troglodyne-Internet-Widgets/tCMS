#!/usr/bin/env perl

# bin/migrate.pl carries a FlatFile site's posts into the SQLite model.  The
# thing worth asserting is not that it copies rows, it is that the site answers
# the same questions afterwards -- so this builds a corpus through the FlatFile
# model, migrates, and compares the two models query for query.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use Test::MockModule qw{strict};

our ( $REPO, $ROOT, $OLDCWD );

BEGIN {
    require Cwd;
    require File::Copy;
    require File::Path;
    require File::Temp;

    $REPO   = Cwd::abs_path("$FindBin::Bin/..");
    $OLDCWD = Cwd::getcwd();
    $ROOT   = File::Temp::tempdir( 'tcms-migrate-XXXXXX', TMPDIR => 1, CLEANUP => 1 );

    $ENV{HOME} = $ROOT;
    File::Path::make_path("$ROOT/$_") for qw{config schema data/files logs};
    File::Copy::copy( "$REPO/schema/$_", "$ROOT/schema/$_" ) or die $! for qw{flatfile.schema sqlite.schema};
    File::Copy::copy( "$REPO/config/default.cfg", "$ROOT/config/default.cfg" ) or die $!;

    chdir($ROOT) or die "could not chdir to the sandbox: $!";
}

END {
    chdir($OLDCWD) if $OLDCWD;
}

require_ok('Trog::Data::FlatFile') or BAIL_OUT("Can't find the model to migrate from");
require_ok('Trog::Data::SQLite')   or BAIL_OUT("Can't find the model to migrate to");
require Trog::Config;
require Trog::SQLite::TagIndex;

my $auth = Test::MockModule->new('Trog::Auth');
$auth->redefine( username2display   => sub { return "Display $_[0]" } );
$auth->redefine( username2classname => sub { return "class-$_[0]" } );

my $config = Trog::Config::get();
my $flat   = Trog::Data::FlatFile->new($config);
my $sqlite = Trog::Data::SQLite->new($config);

# The script is the thing under test, so run it the way an operator would.
sub migrate {
    my (@args) = @_;
    my $out = qx{$^X "-I$REPO/lib" "$REPO/bin/migrate.pl" @args 2>&1};
    return ( $?, $out );
}

my $t = 1700000000;

sub post {
    my (%o) = @_;
    return {
        title      => 'Untitled',
        data       => 'nothing in particular',
        user       => 'bob',
        author     => 'bob',
        visibility => 'public',
        created    => $t++,
        version    => 0,
        form       => 'blog.tx',
        %o,
        tags => [ @{ $o{tags} // ['blog'] }, $o{visibility} // 'public' ],

        # What add() would have filled in.  Without them the flat file model's
        # index build warns about a post it cannot route.
        local_href => $o{local_href} // "/posts/$o{id}",
        callback   => 'Trog::Routes::HTML::posts',
        method     => 'GET',
    };
}

subtest 'nothing to migrate' => sub {
    my ( $rc, $out ) = migrate();
    isnt( $rc, 0, 'an empty datastore is an error rather than a silent success' );
    like( $out, qr/No posts found/, 'and says so' );
    unlike( $out, qr/ at \S+ line \d+/, 'without a stack trace, since it is not a crash' );
};

# A corpus with the awkward bits: several versions of one post, a private one,
# a post whose body is an array, and one carrying a tag nothing else has.
my @corpus = (
    post( id => 'p-one',    title => 'The First',    data => 'quick brown fox',            tags       => [qw{blog topbar}] ),
    post( id => 'p-one',    title => 'The First v2', data => 'quick brown fox, revised',   tags       => [qw{blog topbar}], version => 1 ),
    post( id => 'p-one',    title => 'The First v3', data => 'quick brown fox, again',     tags       => [qw{blog topbar}], version => 2 ),
    post( id => 'p-secret', title => 'Hidden',       data => 'not for you',                visibility => 'private' ),
    post( id => 'p-deck',   title => 'A Deck',       data => [ 'slide one', 'slide two' ], form       => 'presentation.tx' ),
    post( id => 'p-ann',    title => 'By Ann',       data => 'ann wrote this',             user       => 'ann', author => 'ann', tags => [qw{blog rare}] ),
);
$flat->write( [$_] ) foreach @corpus;

# FlatFile memoizes both the tag list and the posts for a given set of tags at
# load time, and writing a post invalidates neither -- production gets away with
# it because a save re-execs the worker.  Anything reading back what it just
# wrote in one process has to do it by hand.
sub reset_flatfile_cache {
    no warnings qw{once};
    @Trog::Data::FlatFile::tags         = Trog::SQLite::TagIndex::tags();
    %Trog::Data::FlatFile::posts_by_tag = ();
    return;
}

reset_flatfile_cache();

subtest 'a dry run writes nothing' => sub {
    my ( $rc, $out ) = migrate('--dry-run');
    is( $rc, 0, 'it succeeds' ) or diag($out);
    like( $out, qr/Would carry over 6 post version\(s\)/, 'and counts every version, not every post' );
    like( $out, qr/Nothing was written/,                  'and says it wrote nothing' );

    is( $sqlite->count(), 0, 'because it wrote nothing' );
};

subtest 'the migration itself' => sub {
    my ( $rc, $out ) = migrate();
    is( $rc, 0, 'it succeeds' ) or diag($out);
    like( $out, qr/Carried over 6 post version\(s\), skipped 0/,                            'carrying over every version' );
    like( $out, qr/data\/files holds 6 post version\(s\); data\/posts\.sqlite now holds 6/, 'and says what actually landed' );

    is( $sqlite->count(), 4, 'four posts' );

    my $present = $sqlite->versions_present();
    is_deeply( [ sort keys %{ $present->{'p-one'} } ], [ 0, 1, 2 ], 'with the whole version history of the one that has one' );
};

subtest 'the two models now answer the same questions' => sub {
    my @queries = (
        [ 'everything an admin sees' => { limit => 0, acls => ['admin'] } ],
        [ 'what a visitor sees'      => { limit => 0, acls => ['public'] } ],
        [ 'by tag'           => { limit => 0, acls => ['admin'], tags   => ['topbar'] } ],
        [ 'by a rare tag'    => { limit => 0, acls => ['admin'], tags   => ['rare'] } ],
        [ 'by author'        => { limit => 0, acls => ['admin'], author => 'ann' } ],
        [ 'by id'            => { limit => 0, id   => 'p-one' } ],
        [ 'an older version' => { limit => 0, id   => 'p-one',   version => 1 } ],
        [ 'by form'          => { limit => 0, acls => ['admin'], form    => 'presentation.tx' } ],
    );

    foreach my $case (@queries) {
        my ( $name, $query ) = @$case;
        my $want = [ sort map { "$_->{id}\@$_->{version}" } $flat->get(%$query) ];
        my $got  = [ sort map { "$_->{id}\@$_->{version}" } $sqlite->get(%$query) ];
        is_deeply( $got, $want, $name ) or diag("flatfile: @$want\nsqlite:   @$got");
    }

    # The rolled up fields have to survive the trip, not just the rows.
    my ($current) = $sqlite->get( limit => 0, id => 'p-one' );
    is( $current->{version},     2,                   'the newest version is the current one' );
    is( $current->{version_max}, 2,                   'version_max came across' );
    is( $current->{title},       'The First v3',      'with the newest content' );
    is( $current->{created},     $corpus[0]{created}, 'created is still the post birthday' );
    is( $current->{modified},    $corpus[2]{created}, 'and modified the last edit' );

    # Search is built during the migration, not left to be rebuilt later.
    my @found = map { $_->{id} } $sqlite->get( limit => 0, acls => ['admin'], like => 'own fox' );
    is_deeply( [ sort @found ], ['p-one'], 'and the search index was built on the way in' );
};

subtest 'running it again' => sub {
    my ( $rc, $out ) = migrate();
    is( $rc, 0, 'succeeds' ) or diag($out);
    like( $out, qr/Carried over 0 post version\(s\), skipped 6/, 'and carries nothing over twice' );
    is( $sqlite->count(), 4, 'leaving the post count alone' );
};

subtest 'picking up what was written in between' => sub {

    # The reason re-running has to work: run once against a live site, once more
    # after a final quiet period.
    $flat->write( [ post( id => 'p-late', title => 'Written Later', data => 'after the first pass' ) ] );
    reset_flatfile_cache();

    my ( $rc, $out ) = migrate();
    is( $rc, 0, 'succeeds' ) or diag($out);
    like( $out, qr/Carried over 1 post version\(s\), skipped 6/, 'carrying over only the new one' );

    my ($late) = $sqlite->get( limit => 0, id => 'p-late' );
    is( $late->{title}, 'Written Later', 'which is there afterwards' );
};

subtest 'the flat files are left alone' => sub {
    opendir( my $dh, 'data/files' ) or die $!;
    my @files = grep { !m/^\.\.?$/ } readdir($dh);
    closedir $dh;

    is( scalar(@files), 5, 'every post still has its file' );
    ok( -f 'data/posts.db', "and the flat file model's own index is untouched" );

    # Which is what makes going back possible.
    my @still = $flat->get( limit => 0, acls => ['admin'] );
    is( scalar(@still), 5, 'and the old model still reads them' );
};

done_testing();
