#!/usr/bin/env perl
use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Test::More;
use Test::MockModule qw{strict};
use Test::Fatal      qw{exception};
use Cwd();
use File::Path();
use File::Temp();

use FindBin::libs;

# The request side of the updates: it finds the checkouts by what is on disk,
# and reads the results of the jobs.  It asks git nothing, so a directory named
# .git is a checkout here.
our $OLDCWD = Cwd::getcwd();
our $TOP    = File::Temp::tempdir( 'tcms-updates-XXXXXX', TMPDIR => 1, CLEANUP => 0 );

END {
    chdir($OLDCWD)                if $OLDCWD;
    File::Path::remove_tree($TOP) if $TOP && -d $TOP;
}

File::Path::make_path( "$TOP/site/.git", "$TOP/site/tCMS/.git", "$TOP/site/tCMS/data", "$TOP/site/tCMS/www/themes/spec/.git" );
open( my $ini, '>', "$TOP/site/.tpsgi.ini" ) or die $!;
close $ini                                   or die $!;
chdir("$TOP/site/tCMS")                      or die $!;

require_ok('Trog::Updates') or BAIL_OUT("Can't find SUT");

my $themes = Test::MockModule->new('Trog::Themes');
$themes->redefine( get_dir => sub { return '' } );

my $minion = Trog::Jobs::register_tasks( Trog::Jobs::minion() );

subtest 'checkouts' => sub {
    is_deeply( [ map { $_->{name} } Trog::Updates::checkouts() ], [qw{tCMS tPSGI}], 'tCMS, and tPSGI above it' );
    is( ( Trog::Updates::checkouts() )[0]{url}, 'https://github.com/Troglodyne-Internet-Widgets/tCMS.git', 'tCMS comes from its repository on GitHub' );

    $themes->redefine( get_dir => sub { return 'www/themes/spec' } );
    my ($theme) = grep { $_->{name} eq 'theme' } Trog::Updates::checkouts();
    is_deeply( $theme, { name => 'theme', label => 'spec', dir => 'www/themes/spec' }, 'the theme, by the name of its directory, with its upstream left to the job' );
    $themes->redefine( get_dir => sub { return '' } );

    rename( '../.tpsgi.ini', '../.tpsgi.ini.off' ) or die $!;
    is_deeply( [ map { $_->{name} } Trog::Updates::checkouts() ], ['tCMS'], 'no tPSGI where the directory above has no .tpsgi.ini' );
    rename( '../.tpsgi.ini.off', '../.tpsgi.ini' ) or die $!;
};

subtest 'checkout' => sub {
    is( Trog::Updates::checkout('tPSGI')->{dir}, '..', 'a checkout by its name' );
    like( exception { Trog::Updates::checkout('bogus') }, qr/(?-x:no checkout named bogus)/, 'a name that is not a checkout dies' );
};

subtest 'enqueue_check' => sub {
    $minion->reset( { all => 1 } );
    ok( Trog::Updates::enqueue_check(),  'a check is queued' );
    ok( !Trog::Updates::enqueue_check(), '...and not a second while it waits' );
    is( $minion->jobs( { tasks => ['update_check'] } )->total, 1, 'so there is one' );
};

subtest 'enqueue_update' => sub {
    my $id = Trog::Updates::enqueue_update('tCMS');
    is_deeply( $minion->job($id)->info->{args}, ['tCMS'], 'an update of the checkout is queued' );
    like( exception { Trog::Updates::enqueue_update('bogus') }, qr/(?-x:no checkout named bogus)/, 'and none for a name that is not a checkout' );
};

# A job that a worker took, finished or failed with $result, as the tasks of
# Trog::Jobs::Updates leave it.
my sub done ( $task, $how, $result ) {
    my $id     = $minion->enqueue( $task => $task eq 'update' ? ['tCMS'] : [] );
    my $worker = $minion->worker->register;
    my $job    = $worker->dequeue( 0, { id => $id } );
    $job->$how($result);
    $worker->unregister;
    return $id;
}

subtest 'summary' => sub {
    $minion->reset( { all => 1 } );
    my $s = Trog::Updates::summary();
    is( $s->{checked_at}, undef, 'never checked' );
    is_deeply( $s->{pending}, [ { task => 'update_check', state => 'inactive', checkout => '' } ], '...so a check is queued' );
    Trog::Updates::summary();
    is( $minion->jobs( { tasks => ['update_check'] } )->total, 1, '...once' );

    $minion->reset( { all => 1 } );
    done( update_check => finish => { checked_at => time - 3600, checkouts => [] } );
    Trog::Updates::summary();
    is( $minion->jobs( { tasks => ['update_check'], states => ['inactive'] } )->total, 1, 'a check older than $stale_after queues another' );

    $minion->reset( { all => 1 } );
    my $head = 'a' x 40;
    done( update_check => finish => { checked_at => time, checkouts => [ { name => 'tCMS', head => $head, upstream => 'b' x 40, state => 'behind' }, { name => 'theme', head => $head, state => 'private' } ] } );
    $s = Trog::Updates::summary();
    is_deeply( $s->{pending},                                              [],                     'a fresh check queues no other' );
    is_deeply( [ @{ $s->{checkouts}[0] }{qw{short_head short_upstream}} ], [ 'a' x 12, 'b' x 12 ], 'each commit, shortened to show' );
    ok( !exists $s->{checkouts}[1]{short_upstream}, '...and none for an upstream there is not' );

    done( update => fail => { error => 'it broke' } );
    is_deeply( Trog::Updates::summary()->{last_update}, { state => 'failed', checkout => 'tCMS', error => 'it broke' }, 'the last update, and why it failed' );
    done( update => fail => "plain words\n" );
    is( Trog::Updates::summary()->{last_update}{error}, "plain words\n", '...whether the reason is a hash or words' );
};

done_testing();
