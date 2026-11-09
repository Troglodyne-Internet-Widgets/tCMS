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
use IPC::Run3();
use Path::Tiny();

use FindBin::libs;

# Every path in tCMS is relative to the root of an install.  The tests build
# the layout of a guest: a tPSGI checkout with the tCMS checkout in it, each a
# clone of an upstream repository in the same directory, which stands in for
# GitHub.
our $OLDCWD = Cwd::getcwd();
our $TOP    = File::Temp::tempdir( 'tcms-updates-XXXXXX', TMPDIR => 1, CLEANUP => 0 );

END {
    chdir($OLDCWD)                if $OLDCWD;
    File::Path::remove_tree($TOP) if $TOP && -d $TOP;
}

local $ENV{GIT_AUTHOR_NAME}     = 'Test';
local $ENV{GIT_AUTHOR_EMAIL}    = 'test@test.test';
local $ENV{GIT_COMMITTER_NAME}  = 'Test';
local $ENV{GIT_COMMITTER_EMAIL} = 'test@test.test';
local $ENV{GIT_CONFIG_GLOBAL}   = '/dev/null';
local $ENV{GIT_CONFIG_NOSYSTEM} = 1;

my sub sh ( $dir, @cmd ) {
    IPC::Run3::run3( [ 'git', '-C', $dir, @cmd ], \undef, \my $out, \my $err );
    die "git @cmd in $dir: $err" if $?;
    chomp $out;
    return $out;
}

my sub commit ( $dir, %files ) {
    Path::Tiny::path("$dir/$_")->spew_utf8( $files{$_} ) foreach keys %files;
    sh( $dir, 'add', '--', keys %files );
    sh( $dir, qw{commit -q -m}, join( ' ', sort keys %files ) );
    return sh( $dir, qw{rev-parse HEAD} );
}

my sub upstream ($name) {
    my $dir = "$TOP/$name";
    File::Path::make_path($dir);
    sh( $dir, qw{init -q -b master} );
    commit( $dir, 'README' => "$name\n", 'metamerge.yml' => "x_system_packages:\n  ffmpeg: {}\n" );
    return $dir;
}

my $up_tpsgi = upstream('up-tpsgi');
my $up_tcms  = upstream('up-tcms');
my $site     = "$TOP/site";
sh( $TOP,  qw{clone -q}, $up_tpsgi, $site );
sh( $site, qw{clone -q}, $up_tcms,  'tCMS' );
Path::Tiny::path("$site/.tpsgi.ini")->spew_utf8("domain = test.test\n");
File::Path::make_path("$site/tCMS/data");
chdir("$site/tCMS") or die $!;

require_ok('Trog::Updates') or BAIL_OUT("Can't find SUT");
require_ok('Trog::Jobs')    or BAIL_OUT("Can't find Trog::Jobs");

# The SUT is loaded at run time, so perl sees its variables named once here.
no warnings 'once';
local %Trog::Updates::upstreams = ( tCMS => $up_tcms, tPSGI => $up_tpsgi );

my $themes = Test::MockModule->new('Trog::Themes');
$themes->redefine( get_dir => sub { return '' } );

subtest 'public_url' => sub {
    is( Trog::Updates::public_url('https://github.com/o/r.git'),   'https://github.com/o/r.git', 'an HTTPS URL is kept' );
    is( Trog::Updates::public_url('git@github.com:o/r.git'),       'https://github.com/o/r.git', 'a GitHub URL over ssh becomes HTTPS' );
    is( Trog::Updates::public_url('ssh://git@github.com/o/r'),     'https://github.com/o/r.git', '...in either form' );
    is( Trog::Updates::public_url('gogs@forge.test.test:o/r.git'), undef,                        'any other ssh URL has no public form' );
    is( Trog::Updates::public_url('/bogus/repo'),                  undef,                        'nor does a path' );
};

subtest 'checkouts' => sub {
    is_deeply( [ map { $_->{name} } Trog::Updates::checkouts() ], [qw{tCMS tPSGI}], 'tCMS, and tPSGI above it' );

    my $theme = 'www/themes/spec';
    File::Path::make_path($theme);
    sh( $theme, qw{init -q} );
    $themes->redefine( get_dir => sub { return $theme } );
    my $mock = Test::MockModule->new('Trog::Updates');
    $mock->redefine( theme_url => sub ($dir) { fail('asked the network for the remote of the theme'); return } );
    my ($found) = grep { $_->{name} eq 'theme' } Trog::Updates::checkouts();
    is_deeply( $found, { name => 'theme', label => 'spec', dir => $theme }, 'the theme, by the name of its directory, with its upstream left to status' );
    $themes->redefine( get_dir => sub { return '' } );
    File::Path::remove_tree('www');

    rename( "$site/.tpsgi.ini", "$site/.tpsgi.ini.off" ) or die $!;
    is_deeply( [ map { $_->{name} } Trog::Updates::checkouts() ], ['tCMS'], 'no tPSGI where the directory above has no .tpsgi.ini' );
    rename( "$site/.tpsgi.ini.off", "$site/.tpsgi.ini" ) or die $!;

    like( exception { Trog::Updates::checkout('bogus') }, qr/no[ ]checkout[ ]named[ ]bogus/, 'a name that is not a checkout dies' );
};

subtest 'theme_url' => sub {
    my $theme = "$TOP/theme";
    sh( $TOP,   qw{clone -q},              $up_tcms, $theme );
    sh( $theme, qw{remote add private},    'gogs@forge.test.test:o/r.git' );
    sh( $theme, qw{remote set-url origin}, 'https://bogus.test.test/o/r.git' );
    is( Trog::Updates::theme_url($theme), undef, 'no remote that answers without credentials' );

    my $mock = Test::MockModule->new('Trog::Updates');
    $mock->redefine( public_url => sub ($url) { return $url =~ /bogus/ ? $up_tcms : undef } );
    is( Trog::Updates::theme_url($theme), $up_tcms, 'the first remote that answers' );
};

subtest 'status' => sub {
    my $tcms = { name => 'tCMS', dir => '.', url => $up_tcms };
    my $s    = Trog::Updates::status($tcms);
    is( $s->{state},    'current',                          'the same commit as the upstream' );
    is( $s->{branch},   'master',                           '...on its branch' );
    is( $s->{upstream}, sh( $up_tcms, qw{rev-parse HEAD} ), '...whose commit it names' );
    is( $s->{dirty},    0,                                  '...with no changes' );

    commit( $up_tcms, 'a' => 1 );
    commit( $up_tcms, 'b' => 2 );
    $s = Trog::Updates::status($tcms);
    is_deeply( [ @$s{qw{state behind}} ], [ 'behind', 2 ], 'two commits behind' );
    is( $s->{head}, sh( '.', qw{rev-parse HEAD} ), '...and the checkout did not move' );

    Path::Tiny::path('README')->append_utf8("local\n");
    is( Trog::Updates::status($tcms)->{dirty}, 1, 'a change to a tracked file is dirty' );
    sh( '.', qw{checkout -q README} );
    Path::Tiny::path('untracked')->spew_utf8('x');
    is( Trog::Updates::status($tcms)->{dirty}, 0, 'an untracked file is not' );
    unlink 'untracked';

    my $tpsgi = { name => 'tPSGI', dir => '..', url => $up_tpsgi };
    commit( '..', 'local' => 1 );
    is( Trog::Updates::status($tpsgi)->{state}, 'ahead', 'a local commit the upstream lacks' );
    commit( $up_tpsgi, 'remote' => 1 );
    is( Trog::Updates::status($tpsgi)->{state}, 'diverged', 'and one each way' );
    sh( '..', qw{reset -q --hard HEAD~1} );

    $s = Trog::Updates::status( { %$tcms, url => "$TOP/bogus" } );
    is( $s->{state}, 'unreachable', 'an upstream that git cannot read' );
    like( $s->{error}, qr/\Agit[ ]fetch/, '...says why' );

    is( Trog::Updates::status( { %$tcms, url => undef } )->{state}, 'private', 'a checkout with no upstream is not fetched' );

    my $mock = Test::MockModule->new('Trog::Updates');
    $mock->redefine( theme_url => sub ($dir) { return } );
    is( Trog::Updates::status( { name => 'theme', dir => '.' } )->{state}, 'private', 'nor is a theme with no public remote' );
    $mock->redefine( theme_url => sub ($dir) { return $up_tcms } );
    is( Trog::Updates::status( { name => 'theme', dir => '.' } )->{state}, 'behind', 'a theme with one is compared with it' );
};

subtest 'system_packages' => sub {
    my $head = sh( '.', qw{rev-parse HEAD} );
    is( Trog::Updates::system_packages( '.', $head ), '{"x_system_packages":{"ffmpeg":{}},"x_system_sources":null}', 'the keys that name packages, as canonical JSON' );
    my $none = commit( $up_tcms, 'metamerge.yml' => "x_other: 1\n" );
    sh( '.', qw{fetch -q}, $up_tcms );
    is( Trog::Updates::system_packages( '.', $none ), '{"x_system_packages":null,"x_system_sources":null}', 'a commit that declares none' );
    sh( $up_tcms, qw{reset -q --hard HEAD~1} );
};

subtest 'missing_modules' => sub {
    my $head = sh( '.', qw{rev-parse HEAD} );
    my $mock = Test::MockModule->new('File::Which');
    $mock->redefine( which => sub ($prog) { fail("asked for $prog"); return } );
    is_deeply( [ Trog::Updates::missing_modules( '.', $head ) ], [], 'a commit with no dist.ini needs nothing that dzil can tell' );

    my $with = commit( $up_tcms, 'dist.ini' => "name = Spec\n" );
    sh( '.', qw{fetch -q}, $up_tcms );
    $mock->redefine( which => sub ($prog) { return } );
    like( exception { Trog::Updates::missing_modules( '.', $with ) }, qr/dzil[ ]is[ ]not[ ]installed/, 'without dzil, nothing can tell' );

    # A dzil that names a module only when it runs in a checkout of the commit.
    my $dzil = Path::Tiny::path("$TOP/dzil");
    $dzil->spew_utf8(qq{#!/bin/sh\n[ "\$*" = 'listdeps --missing' ] && grep -q Spec dist.ini && echo Foo::Bar && echo 'not a module'\n});
    $dzil->chmod('0755');
    $mock->redefine( which => sub ($prog) { return "$dzil" } );
    is_deeply( [ Trog::Updates::missing_modules( '.', $with ) ], ['Foo::Bar'], 'what dzil listdeps --missing names, in a worktree of the commit' );
    is( scalar( () = sh( '.', qw{worktree list --porcelain} ) =~ /^worktree[ ]/mg ), 1, '...which it removes' );

    $dzil->spew_utf8("#!/bin/sh\necho broken >&2\nexit 1\n");
    $dzil->chmod('0755');
    like( exception { Trog::Updates::missing_modules( '.', $with ) }, qr/(?-x:dzil listdeps failed for the new commits: broken)/, 'a dzil that fails dies with what it said' );
    sh( $up_tcms, qw{reset -q --hard HEAD~1} );
};

subtest 'new_needs' => sub {
    my $from = sh( '.', qw{rev-parse HEAD} );
    my $mock = Test::MockModule->new('Trog::Updates');
    $mock->redefine( missing_modules => sub ( $dir, $commit ) { return } );

    my $same = commit( $up_tcms, 'metamerge.yml' => "x_system_packages:\n  ffmpeg: {}\nx_other: 2\n" );
    sh( '.', qw{fetch -q}, $up_tcms );
    is_deeply( [ Trog::Updates::new_needs( '.', $from, $same ) ], [], 'another key of metamerge.yml needs nothing' );

    my $more = commit( $up_tcms, 'metamerge.yml' => "x_system_packages:\n  ffmpeg: {}\n  libfoo: {}\n" );
    sh( '.', qw{fetch -q}, $up_tcms );
    like( ( Trog::Updates::new_needs( '.', $from, $more ) )[0], qr/system[ ]packages/, 'a new system package needs a person' );

    $mock->redefine( missing_modules => sub ( $dir, $commit ) { return qw{Foo::Bar Baz} } );
    like( ( Trog::Updates::new_needs( '.', $from, $same ) )[0], qr/perl[ ]modules[ ].*[ ]Foo::Bar,[ ]Baz/, 'and so do modules this perl lacks' );
    $mock->redefine( missing_modules => sub ( $dir, $commit ) { die "dzil is not installed\n" } );
    is_deeply( [ Trog::Updates::new_needs( '.', $from, $same ) ], ['dzil is not installed'], 'and not being able to tell' );
    sh( $up_tcms, qw{reset -q --hard HEAD~2} );
};

subtest 'unit_of' => sub {
    my $proc = "$TOP/proc";
    File::Path::make_path("$proc/42");
    Path::Tiny::path("$proc/42/cgroup")->spew_utf8("0::/system.slice/test.test.service\n");
    local $Trog::Updates::proc = $proc;
    is( Trog::Updates::unit_of(42), 'test.test.service', 'the unit, from the cgroup' );
    is( Trog::Updates::unit_of(43), undef,               'none for a process that is not there' );
};

subtest 'tpsgi_pid' => sub {
    like( exception { Trog::Updates::tpsgi_pid() }, qr/a[ ]person[ ]must[ ]restart[ ]tPSGI/, 'no pid file' );
    File::Path::make_path('../run');
    Path::Tiny::path('../run/tpsgi.pid')->spew_utf8("1234\n");
    is( Trog::Updates::tpsgi_pid(), 1234, 'the master, from run/tpsgi.pid of tPSGI' );
};

# The tasks run in this process, so that the mocks see them, against a queue in
# data/ of this root.
my $minion = Trog::Jobs::register_tasks( Trog::Jobs::minion() );

my sub run_update ($name) {
    my $id = Trog::Updates::enqueue_update($name);
    $minion->perform_jobs_in_foreground( { tasks => ['update'] } );
    return $minion->job($id)->info;
}

subtest 'update_task' => sub {
    my ( @hups, @restarts, @installs );
    my $mock = Test::MockModule->new('Trog::Updates');
    $mock->redefine( hup_tpsgi       => sub { push @hups, 1;                                                 return } );
    $mock->redefine( restart_unit    => sub ( $unit, $no_block = 0 ) { push @restarts, [ $unit, $no_block ]; return } );
    $mock->redefine( reinstall       => sub { push @installs, 1;                                             return } );
    $mock->redefine( missing_modules => sub ( $dir, $commit ) { return } );
    $mock->redefine( unit_of         => sub ($pid) { return $pid eq 'self' ? 'tcms-worker-test.test.service' : 'test.test.service' } );
    $mock->redefine( tpsgi_pid       => sub { return 1234 } );

    # Where the subtests above left the upstream.
    sh( '.', qw{fetch -q}, $up_tcms, 'master' );
    sh( '.', qw{reset -q --hard FETCH_HEAD} );

    my $info = run_update('tCMS');
    is( $info->{state}, 'failed', 'a checkout that is current is not updated' );
    like( $info->{result}, qr/tCMS[ ]is[ ]current/, '...and the job says so' );

    my $from = sh( '.', qw{rev-parse HEAD} );
    my $to   = commit( $up_tcms, 'c' => 3 );
    Path::Tiny::path('README')->append_utf8("local\n");
    like( run_update('tCMS')->{result}, qr/changes[ ]to[ ]tracked[ ]files/, 'a checkout with changes is not updated' );
    is( sh( '.', qw{rev-parse HEAD} ), $from, '...and does not move' );
    sh( '.', qw{checkout -q README} );

    commit( $up_tcms, 'metamerge.yml' => "x_system_packages:\n  libfoo: {}\n" );
    like( run_update('tCMS')->{result}, qr/system[ ]packages/, 'nor one whose new commits need a system package' );
    is( sh( '.', qw{rev-parse HEAD} ), $from, '...which stays where it was' );
    sh( $up_tcms, qw{reset -q --hard}, $to );

    $minion->reset( { all => 1 } );
    $info = run_update('tCMS');
    is( $info->{state},                'finished', 'a checkout that is behind and clean is updated' ) or diag explain $info->{result};
    is( sh( '.', qw{rev-parse HEAD} ), $to,        '...to the upstream commit' );
    is_deeply( [ @{ $info->{result} }{qw{from to}} ], [ $from, $to ], '...which the result names' );
    is( scalar @installs, 1, 'the installer ran' );
    is( scalar @hups,     1, 'tPSGI got a HUP' );
    is_deeply( \@restarts, [ [ 'tcms-worker-test.test.service', 1 ] ], 'and the worker restarts, without waiting' );
    is( $minion->jobs( { tasks => ['update_check'], states => ['inactive'] } )->total, 1, 'a check is queued, to show the new state' );

    @hups = @restarts = ();
    my $tp = commit( $up_tpsgi, 'd' => 4 );
    $info = run_update('tPSGI');
    is( $info->{state},                 'finished', 'tPSGI updates' ) or diag explain $info->{result};
    is( sh( '..', qw{rev-parse HEAD} ), $tp,        '...to its upstream' );
    is_deeply( [ \@hups, \@restarts ], [ [], [ [ 'test.test.service', 0 ] ] ], '...and its unit restarts, with no HUP' );

    {
        my $guard = $minion->guard( 'tcms_update', 60 );    ## no critic (ProhibitUnusedVarsStricter) -- the lock lasts as long as the variable
        like( run_update('tPSGI')->{result}, qr/Another[ ]update[ ]is[ ]running/, 'one update at a time' );
    }
};

subtest 'summary' => sub {
    $minion->reset( { all => 1 } );
    my $s = Trog::Updates::summary();
    is( $s->{checked_at}, undef, 'never checked' );
    is_deeply( $s->{pending}, [ { task => 'update_check', state => 'inactive', checkout => '' } ], '...so a check is queued' );
    Trog::Updates::summary();
    is( $minion->jobs( { tasks => ['update_check'] } )->total, 1, '...once' );

    $minion->perform_jobs_in_foreground( { tasks => ['update_check'] } );
    $s = Trog::Updates::summary();
    ok( $s->{checked_at}, 'the check ran' );
    is_deeply( [ map { "$_->{name} $_->{state}" } @{ $s->{checkouts} } ], [ 'tCMS current', 'tPSGI current' ], '...and found both current' );
    is( length $s->{checkouts}[0]{short_head}, 12, '...with short commits to show' );
    is_deeply( $s->{pending}, [], 'and a fresh check queues no other' );

    # Only a job that runs can fail, so take it as a worker does.
    Trog::Updates::enqueue_update('tCMS');
    my $worker = $minion->worker->register;
    $worker->dequeue( 0, { tasks => ['update'] } )->fail( { error => 'it broke' } );
    $worker->unregister;
    is_deeply( Trog::Updates::summary()->{last_update}, { state => 'failed', checkout => 'tCMS', error => 'it broke' }, 'the last update, and why it failed' );
};

done_testing();
