use strict;
use warnings;

use Test::More;
use Test::Fatal qw{exception};
use File::Path  ();
use FindBin;

use lib "$FindBin::Bin/../lib";

my ( $ROOT, $OLDCWD );

BEGIN {
    require File::Temp;
    require Cwd;
    $OLDCWD = Cwd::getcwd();
    $ROOT   = File::Temp::tempdir( 'tcms-flatfile-XXXXXX', TMPDIR => 1, CLEANUP => 1 );

    # Text::Xslate and the loggers both compute paths from $HOME or the cwd at
    # load time, and $datastore is relative, so both have to be set before the
    # SUT is loaded.
    $ENV{HOME} = $ROOT;
    File::Path::make_path("$ROOT/data/files");
    File::Path::make_path("$ROOT/schema");

    # Trog::SQLite::TagIndex builds the tag index at load time and wants this
    # path, hardcoded and relative, before the SUT will even compile.
    require File::Copy;
    File::Copy::copy( "$FindBin::Bin/../schema/flatfile.schema", "$ROOT/schema/flatfile.schema" ) or die $!;

    chdir($ROOT) or die "could not chdir to the sandbox: $!";
}

END {
    chdir($OLDCWD) if $OLDCWD;
}

require_ok('Trog::Data::FlatFile') or BAIL_OUT("Can't find SUT");
require_ok('Trog::Log')            or BAIL_OUT("Can't find SUT");

my $model = bless( {}, 'Trog::Data::FlatFile' );

# Collect whatever the SUT says rather than letting it reach the terminal, so
# that "did this warn" is a thing the test can assert on.
my @said;
local $SIG{__WARN__} = sub { push @said, $_[0] };

sub reads {
    my ($id) = @_;
    @said = ();
    my $posts = $model->read( { id => $id, raw => 1 } );
    return ( $posts, join( '', @said ) );
}

open( my $fh, '>', 'data/files/good' ) or die $!;
print {$fh} '[{"id":"good","title":"Good","tags":["public"],"visibility":"public"}]';
close $fh;

subtest 'a post that is there' => sub {
    my ( $posts, $noise ) = reads('good');
    is( scalar(@$posts), 1,      "the post comes back" );
    is( $posts->[0]{id}, 'good', "and it is the one asked for" );
    is( $noise,          '',     "quietly" );
};

subtest 'a post that is not there' => sub {

    # add() asks this before every single insert, to choose between version 0
    # and a bump.  It used to name the file regardless of whether it existed,
    # so every new post reported itself as a failed read.
    my ( $posts, $noise ) = reads('no-such-post');
    is( scalar(@$posts), 0,  "a miss is an empty list" );
    is( $noise,          '', "and says nothing -- a miss is not a failure" );
};

subtest 'a post that cannot be parsed' => sub {
    open( my $bad, '>', 'data/files/corrupt' ) or die $!;
    print {$bad} '[{"id":"corrupt"';
    close $bad;

    my ( $posts, $noise ) = reads('corrupt');
    is( scalar(@$posts), 0, "nothing comes back" );
    like( $noise, qr/corrupt/, "but it says which post, because this one is a real failure" );
};

subtest 'a post that cannot be read' => sub {
  SKIP: {
        skip( "running as root, which can read anything", 2 ) if $> == 0;

        open( my $no, '>', 'data/files/unreadable' ) or die $!;
        print {$no} 'x';
        close $no;
        chmod( 0000, 'data/files/unreadable' ) or die $!;

        my ( $posts, $noise ) = reads('unreadable');
        is( scalar(@$posts), 0, "nothing comes back" );
        like( $noise, qr/unreadable/, "and it says which post" );

        chmod( 0644, 'data/files/unreadable' );
    }
};

subtest 'the log works before log_init()' => sub {

    # Logging is what you reach for when something has already gone wrong, so
    # dying because nobody set it up first turns a diagnostic into an outage.
    no warnings qw{once};
    is( $Trog::Log::log, undef, "no logger is configured in this process" );

    @said = ();
    is( exception { Trog::Log::WARN('a warning') }, undef, "WARN does not die" );
    like( join( '', @said ), qr/\[WARN\].*a warning/, "it lands on stderr instead" );

    @said = ();
    is( exception { Trog::Log::INFO('a note') },    undef, "INFO does not die" );
    is( exception { Trog::Log::DEBUG('a detail') }, undef, "DEBUG does not die" );

    # An uninitialized request id used to be spliced into the line as an
    # uninitialized-value warning.
    unlike( join( '', @said ), qr/uninitialized/, "and no uninitialized value creeps in" );
    like( join( '', @said ), qr/RequestId NONE/, "the request id says it has none" );

    # FATAL is fatal either way, or the caller's error handling disappears.
    like( exception { Trog::Log::FATAL('the roof is on fire') }, qr/the roof is on fire/, "FATAL still dies" );
};

done_testing();
