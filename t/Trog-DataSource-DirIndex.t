#!/usr/bin/env perl

# A datasource which turns a directory into posts.  Most of this file is about
# which directories it will agree to look at, because that is the part where
# getting it wrong hands out the names of files somebody meant to keep.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use Test::MockModule qw{strict};
use Test::Fatal      qw{exception};

our ( $REPO, $ROOT, $OLDCWD );

BEGIN {
    require Cwd;
    require File::Copy;
    require File::Path;
    require File::Temp;

    $REPO      = Cwd::abs_path("$FindBin::Bin/..");
    $OLDCWD    = Cwd::getcwd();
    $ROOT      = File::Temp::tempdir( 'tcms-dirindex-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    $ENV{HOME} = $ROOT;

    # The paths are relative to the tCMS root, so we need one.
    File::Path::make_path("$ROOT/$_") for qw{config www/assets/downloads www/assets/private/secrets www/statics outside};

    # Trog::Routes::HTML reads the config at load time, and the last subtest
    # loads it to check the wizard can see this datasource.
    File::Copy::copy( "$REPO/config/default.cfg", "$ROOT/config/default.cfg" ) or die $!;

    chdir($ROOT) or die "could not chdir to the sandbox: $!";
}

END {
    chdir($OLDCWD) if $OLDCWD;
}

require_ok('Trog::DataSource::DirIndex') or BAIL_OUT("Can't find SUT");

my $log = Test::MockModule->new('Trog::DataSource::DirIndex');
$log->redefine( WARN  => sub { note(shift) } );
$log->redefine( DEBUG => sub { note(shift) } );

sub touch {
    my ( $path, $content ) = @_;
    open( my $fh, '>', $path ) or die "$path: $!";
    print {$fh} ( $content // 'x' );
    close $fh;
    return;
}

touch( 'www/assets/downloads/report.pdf',         'pdf' x 100 );
touch( 'www/assets/downloads/photo.jpg',          'jpg' );
touch( 'www/assets/downloads/notes.txt',          'notes' );
touch( 'www/assets/downloads/.hidden',            'nope' );
touch( 'www/assets/private/secrets/salaries.csv', 'nope' );
touch( 'outside/elsewhere.txt',                   'nope' );
mkdir('www/assets/downloads/archive');

my %series = (
    directory  => 'assets/downloads',
    child_form => 'spec_files.tx',
    tags       => [qw{downloads public}],
    visibility => 'public',
    user       => 'bob',
);

sub names {
    my (@posts) = @_;
    return [ sort map { $_->{name} } @posts ];
}

subtest 'it lists a directory' => sub {
    my @posts = Trog::DataSource::DirIndex::posts( \%series, {} );

    is_deeply( names(@posts), [ sort qw{archive notes.txt photo.jpg report.pdf} ], 'every entry becomes a post' );

    my ($pdf) = grep { $_->{name} eq 'report.pdf' } @posts;
    is( $pdf->{title},      'report.pdf',                   'named after the file' );
    is( $pdf->{path},       'assets/downloads/report.pdf',  'carrying its path relative to www' );
    is( $pdf->{local_href}, '/assets/downloads/report.pdf', 'and a link to where it actually is' );
    is( $pdf->{size},       300,                            'with its size' );
    is( $pdf->{size_human}, '300 B',                        'as a human reads it' );
    is( $pdf->{extension},  'pdf',                          'and its extension' );
    is( $pdf->{is_dir},     0,                              'a file is not a directory' );
    is( $pdf->{form},       'spec_files.tx',                'and it says which template renders it' );
    ok( $pdf->{created}, 'created is its mtime, so it has a real date' );

    my ($dir) = grep { $_->{name} eq 'archive' } @posts;
    is( $dir->{is_dir},    1,  'a directory says so' );
    is( $dir->{size},      0,  'and has no size of its own' );
    is( $dir->{extension}, '', 'nor an extension' );

    # A template wants to know what it is looking at.
    my ($jpg) = grep { $_->{name} eq 'photo.jpg' } @posts;
    is( $jpg->{is_image}, 1, 'an image is flagged as one' );
    is( $pdf->{is_image}, 0, 'and a PDF is not' );

    # Inherited from the series, as every datasource's posts are: the reader
    # reached this page by holding the series' acls.
    is_deeply( $pdf->{tags}, [qw{downloads public}], 'the series tags come along' );
    is( $pdf->{visibility}, 'public', 'and its visibility' );
    is( $pdf->{user},       'bob',    'and its owner' );
};

subtest 'ids are stable and opaque' => sub {
    my @first  = Trog::DataSource::DirIndex::posts( \%series, {} );
    my @second = Trog::DataSource::DirIndex::posts( \%series, {} );

    my %one = map { $_->{name} => $_->{id} } @first;
    my %two = map { $_->{name} => $_->{id} } @second;
    is_deeply( \%one, \%two, 'the same entry gets the same id twice' );

    # Pagination hands out page 2 of a list keyed on these, and a filename is
    # not a thing to put in a URL.
    ok( $one{'report.pdf'} =~ m/^dirindex-[0-9a-f]{32}$/, 'and it is opaque rather than the name' );
    isnt( $one{'report.pdf'}, $one{'notes.txt'}, 'different entries get different ids' );
};

subtest 'what it refuses to look at' => sub {

    # Everything under www/ is already served to anybody who asks, so listing it
    # discloses nothing a guessed URL would not.  Everywhere else, the names are
    # the disclosure.
    my %refused = (
        'somewhere else entirely'        => 'outside',
        'an absolute path'               => "$ROOT/outside",
        'a walk upwards'                 => 'assets/../../outside',
        'a sneakier walk'                => 'assets/downloads/../../../outside',
        'the private assets'             => 'assets/private',
        'inside the private assets'      => 'assets/private/secrets',
        'a directory that is not there'  => 'assets/nonesuch',
        'a file rather than a directory' => 'assets/downloads/report.pdf',
        'nothing at all'                 => '',
    );

    foreach my $why ( sort keys %refused ) {
        my @posts = Trog::DataSource::DirIndex::posts( { %series, directory => $refused{$why} }, {} );
        is_deeply( \@posts, [], "refuses $why" );
    }

    my @undef = Trog::DataSource::DirIndex::posts( { %series, directory => undef }, {} );
    is_deeply( \@undef, [], 'and a series which names no directory at all' );
};

subtest 'the www prefix is optional' => sub {
    my @with    = Trog::DataSource::DirIndex::posts( { %series, directory => 'www/assets/downloads' }, {} );
    my @without = Trog::DataSource::DirIndex::posts( { %series, directory => 'assets/downloads' },     {} );
    is_deeply( names(@with), names(@without), 'either way names the same directory' );
    ok( scalar(@with), 'and it is not simply refusing both' );
};

subtest 'dotfiles and escaping symlinks are left out' => sub {
    my @posts = Trog::DataSource::DirIndex::posts( \%series, {} );
    is_deeply( [ grep { $_->{name} =~ m/^\./ } @posts ], [], 'a dotfile is not listed' );

  SKIP: {
        skip( 'no symlinks here', 2 ) unless eval { symlink( "$ROOT/outside/elsewhere.txt", 'www/assets/downloads/escape.txt' ); 1 };

        my @linked = Trog::DataSource::DirIndex::posts( \%series, {} );
        is_deeply( [ grep { $_->{name} eq 'escape.txt' } @linked ], [], 'nor a symlink pointing out of the tree' );

        symlink( "$ROOT/www/assets/downloads/notes.txt", 'www/assets/downloads/inside.txt' );
        my @inside = Trog::DataSource::DirIndex::posts( \%series, {} );
        ok( scalar( grep { $_->{name} eq 'inside.txt' } @inside ), 'while one pointing within it is fine' );

        unlink('www/assets/downloads/escape.txt');
        unlink('www/assets/downloads/inside.txt');
    }
};

subtest 'a filename that needs escaping' => sub {
    touch('www/assets/downloads/a file & thing #1.txt');

    my @posts = Trog::DataSource::DirIndex::posts( \%series, {} );
    my ($odd) = grep { $_->{name} eq 'a file & thing #1.txt' } @posts;
    ok( $odd, 'it is listed under its real name' );

    # A filename may legally hold a space, an ampersand or a hash, and none of
    # those survive being dropped into an href as they are.
    unlike( $odd->{local_href}, qr/[ #]/, 'but its link carries none of them raw' );
    like( $odd->{local_href}, qr/^\/assets\/downloads\//, 'and still points where it should' );

    unlink('www/assets/downloads/a file & thing #1.txt');
};

subtest 'searching a listing' => sub {
    my @posts = Trog::DataSource::DirIndex::posts( \%series, {} );

    is_deeply( names( Trog::DataSource::DirIndex::filter( { like => 'pdf' },       @posts ) ), ['report.pdf'], 'by extension' );
    is_deeply( names( Trog::DataSource::DirIndex::filter( { like => 'note' },      @posts ) ), ['notes.txt'],  'by name' );
    is_deeply( names( Trog::DataSource::DirIndex::filter( { like => 'downloads' }, @posts ) ), names(@posts),  'by path' );
    is_deeply( names( Trog::DataSource::DirIndex::filter( { like => 'nonesuch' },  @posts ) ), [],             'and nothing matches nothing' );
    is_deeply( names( Trog::DataSource::DirIndex::filter( {}, @posts ) ), names(@posts), 'no search filters nothing' );
};

subtest 'the order a directory index belongs in' => sub {
    my @posts   = Trog::DataSource::DirIndex::posts( \%series, {} );
    my @ordered = Trog::DataSource::DirIndex::order( {}, @posts );

    is( $ordered[0]{name}, 'archive', 'directories come first' );
    is_deeply(
        [ map { $_->{name} } @ordered ],
        [qw{archive notes.txt photo.jpg report.pdf}],
        'and then it is by name, which is what every file browser does'
    );

    # Pagination hands out page 2 of this, so it had better not depend on what
    # order readdir felt like today.
    is_deeply(
        [ map { $_->{name} } Trog::DataSource::DirIndex::order( {}, reverse @posts ) ],
        [ map { $_->{name} } @ordered ],
        'whatever order they arrived in'
    );
};

subtest 'it asks to be told when the directory changes' => sub {
    my @watches;

    my $tpsgi = bless {}, 'FakeTPSGI';
    {
        no warnings qw{once};
        *FakeTPSGI::add_watch = sub {
            my ( $self, $path, $callback, %options ) = @_;
            push( @watches, { path => $path, callback => $callback, %options } );
            return 1;
        };
        *FakeTPSGI::invalidate_renders = sub { push( @{ $_[0]{invalidated} }, $_[1] ); return 1 };
    }

    Trog::DataSource::DirIndex::posts( \%series, { tpsgi => $tpsgi } );
    is( scalar(@watches),  1,                      'a watch is registered' );
    is( $watches[0]{path}, 'www/assets/downloads', 'on the directory it is listing' );
    like( $watches[0]{key}, qr/DirIndex/, 'under a key naming what registered it' );

    # posts() runs per request and builds this closure fresh each time, so
    # without an explicit key the default -- the callback's address -- would
    # stack another copy of the same callback on every single view.
    Trog::DataSource::DirIndex::posts( \%series, { tpsgi => $tpsgi } );
    Trog::DataSource::DirIndex::posts( \%series, { tpsgi => $tpsgi } );
    is( scalar( keys %{ { map { $_->{key} => 1 } @watches } } ), 1, 'and it is the same key every time' );

    # The callback uses the tPSGI it is handed, not the one from the request
    # that registered it: watches are shared between workers, and whichever
    # worker notices the change is the one that has to do the invalidating.
    my $other = bless {}, 'FakeTPSGI';
    $watches[0]{callback}->( $other, { path => 'www/assets/downloads/new.txt', events => ['CREATE'] } );
    is_deeply( $other->{invalidated}, ['html'], 'and it invalidates the html renders when it fires' );
    ok( !$tpsgi->{invalidated}, 'through the object it was handed, not the one it closed over' );
};

subtest 'no tPSGI, or one without watches, is not fatal' => sub {
    is( exception { Trog::DataSource::DirIndex::posts( \%series, {} ) }, undef, 'no tpsgi at all is fine' );

    my $old = bless {}, 'OldTPSGI';
    is( exception { Trog::DataSource::DirIndex::posts( \%series, { tpsgi => $old } ) }, undef, 'and neither is one without add_watch' );

    my @posts = Trog::DataSource::DirIndex::posts( \%series, { tpsgi => $old } );
    ok( scalar(@posts), 'the listing still works; it just goes stale' );
};

subtest 'the wizard can find it' => sub {
    require Trog::Routes::HTML;

    my $sources = Trog::Routes::HTML::_get_datasources();
    ok( scalar( grep { $_ eq 'Trog::DataSource::DirIndex' } @$sources ), 'it is offered as a datasource' );

    is( Trog::DataSource::DirIndex->EDITABLE, 0, 'and declares it wants no editor' );
};

done_testing();
