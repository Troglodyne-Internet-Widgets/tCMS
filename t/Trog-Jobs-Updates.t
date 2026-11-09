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
our $TOP    = File::Temp::tempdir( 'tcms-jobs-updates-XXXXXX', TMPDIR => 1, CLEANUP => 0 );

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

require_ok('Trog::Jobs::Updates') or BAIL_OUT("Can't find SUT");
require_ok('Trog::Jobs')          or BAIL_OUT("Can't find Trog::Jobs");

# The SUT is loaded at run time, so perl sees its variables named once here.
no warnings 'once';
local %Trog::Updates::upstreams = ( tCMS => $up_tcms, tPSGI => $up_tpsgi );

my $themes = Test::MockModule->new('Trog::Themes');
$themes->redefine( get_dir => sub { return '' } );

subtest 'public_url' => sub {
    is( Trog::Jobs::Updates::public_url('https://github.com/o/r.git'),   'https://github.com/o/r.git', 'an HTTPS URL is kept' );
    is( Trog::Jobs::Updates::public_url('git@github.com:o/r.git'),       'https://github.com/o/r.git', 'a GitHub URL over ssh becomes HTTPS' );
    is( Trog::Jobs::Updates::public_url('ssh://git@github.com/o/r'),     'https://github.com/o/r.git', '...in either form' );
    is( Trog::Jobs::Updates::public_url('gogs@forge.test.test:o/r.git'), undef,                        'any other ssh URL has no public form' );
    is( Trog::Jobs::Updates::public_url('/bogus/repo'),                  undef,                        'nor does a path' );
};

subtest 'theme_url' => sub {
    my $theme = "$TOP/theme";
    sh( $TOP,   qw{clone -q},              $up_tcms, $theme );
    sh( $theme, qw{remote add private},    'gogs@forge.test.test:o/r.git' );
    sh( $theme, qw{remote set-url origin}, 'https://bogus.test.test/o/r.git' );
    is( Trog::Jobs::Updates::theme_url($theme), undef, 'no remote that answers without credentials' );

    my $mock = Test::MockModule->new('Trog::Jobs::Updates');
    $mock->redefine( public_url => sub ($url) { return $url =~ /bogus/ ? $up_tcms : undef } );
    is( Trog::Jobs::Updates::theme_url($theme), $up_tcms, 'the first remote that answers' );
};

subtest 'status' => sub {
    my $tcms = { name => 'tCMS', dir => '.', url => $up_tcms };
    my $s    = Trog::Jobs::Updates::status($tcms);
    is( $s->{state},    'current',                          'the same commit as the upstream' );
    is( $s->{branch},   'master',                           '...on its branch' );
    is( $s->{upstream}, sh( $up_tcms, qw{rev-parse HEAD} ), '...whose commit it names' );
    is( $s->{dirty},    0,                                  '...with no changes' );

    commit( $up_tcms, 'a' => 1 );
    commit( $up_tcms, 'b' => 2 );
    $s = Trog::Jobs::Updates::status($tcms);
    is_deeply( [ @$s{qw{state behind}} ], [ 'behind', 2 ], 'two commits behind' );
    is( $s->{head}, sh( '.', qw{rev-parse HEAD} ), '...and the checkout did not move' );

    Path::Tiny::path('README')->append_utf8("local\n");
    is( Trog::Jobs::Updates::status($tcms)->{dirty}, 1, 'a change to a tracked file is dirty' );
    sh( '.', qw{checkout -q README} );
    Path::Tiny::path('untracked')->spew_utf8('x');
    is( Trog::Jobs::Updates::status($tcms)->{dirty}, 0, 'an untracked file is not' );
    unlink 'untracked';

    my $tpsgi = { name => 'tPSGI', dir => '..', url => $up_tpsgi };
    commit( '..', 'local' => 1 );
    is( Trog::Jobs::Updates::status($tpsgi)->{state}, 'ahead', 'a local commit the upstream lacks' );
    commit( $up_tpsgi, 'remote' => 1 );
    is( Trog::Jobs::Updates::status($tpsgi)->{state}, 'diverged', 'and one each way' );
    sh( '..', qw{reset -q --hard HEAD~1} );

    $s = Trog::Jobs::Updates::status( { %$tcms, url => "$TOP/bogus" } );
    is( $s->{state}, 'unreachable', 'an upstream that git cannot read' );
    like( $s->{error}, qr/\Agit[ ]fetch/, '...says why' );

    is( Trog::Jobs::Updates::status( { %$tcms, url => undef } )->{state}, 'private', 'a checkout with no upstream is not fetched' );

    my $mock = Test::MockModule->new('Trog::Jobs::Updates');
    $mock->redefine( theme_url => sub ($dir) { return } );
    is( Trog::Jobs::Updates::status( { name => 'theme', dir => '.' } )->{state}, 'private', 'nor is a theme with no public remote' );
    $mock->redefine( theme_url => sub ($dir) { return $up_tcms } );
    is( Trog::Jobs::Updates::status( { name => 'theme', dir => '.' } )->{state}, 'behind', 'a theme with one is compared with it' );
};

subtest 'system_packages' => sub {
    my $head = sh( '.', qw{rev-parse HEAD} );
    is( Trog::Jobs::Updates::system_packages( '.', $head ), '{"x_system_packages":{"ffmpeg":{}},"x_system_sources":null}', 'the keys that name packages, as canonical JSON' );
    my $none = commit( $up_tcms, 'metamerge.yml' => "x_other: 1\n" );
    sh( '.', qw{fetch -q}, $up_tcms );
    is( Trog::Jobs::Updates::system_packages( '.', $none ), '{"x_system_packages":null,"x_system_sources":null}', 'a commit that declares none' );
    sh( $up_tcms, qw{reset -q --hard HEAD~1} );
};

subtest 'missing_modules' => sub {
    my $head = sh( '.', qw{rev-parse HEAD} );
    my $mock = Test::MockModule->new('File::Which');
    $mock->redefine( which => sub ($prog) { fail("asked for $prog"); return } );
    is_deeply( [ Trog::Jobs::Updates::missing_modules( '.', $head ) ], [], 'a commit with no dist.ini needs nothing that dzil can tell' );

    my $with = commit( $up_tcms, 'dist.ini' => "name = Spec\n" );
    sh( '.', qw{fetch -q}, $up_tcms );
    $mock->redefine( which => sub ($prog) { return } );
    like( exception { Trog::Jobs::Updates::missing_modules( '.', $with ) }, qr/dzil[ ]is[ ]not[ ]installed/, 'without dzil, nothing can tell' );

    # A dzil that names a module only when it runs in a checkout of the commit.
    my $dzil = Path::Tiny::path("$TOP/dzil");
    $dzil->spew_utf8(qq{#!/bin/sh\n[ "\$*" = 'listdeps --missing' ] && grep -q Spec dist.ini && echo Foo::Bar && echo 'not a module'\n});
    $dzil->chmod('0755');
    $mock->redefine( which => sub ($prog) { return "$dzil" } );
    is_deeply( [ Trog::Jobs::Updates::missing_modules( '.', $with ) ], ['Foo::Bar'], 'what dzil listdeps --missing names, in a worktree of the commit' );
    is( scalar( () = sh( '.', qw{worktree list --porcelain} ) =~ /^worktree[ ]/mg ), 1, '...which it removes' );

    $dzil->spew_utf8("#!/bin/sh\necho broken >&2\nexit 1\n");
    $dzil->chmod('0755');
    like( exception { Trog::Jobs::Updates::missing_modules( '.', $with ) }, qr/(?-x:dzil listdeps failed for the new commits: broken)/, 'a dzil that fails dies with what it said' );
    sh( $up_tcms, qw{reset -q --hard HEAD~1} );
};

subtest 'new_needs' => sub {
    my $from = sh( '.', qw{rev-parse HEAD} );
    my $mock = Test::MockModule->new('Trog::Jobs::Updates');
    $mock->redefine( missing_modules => sub ( $dir, $commit ) { return } );

    my $same = commit( $up_tcms, 'metamerge.yml' => "x_system_packages:\n  ffmpeg: {}\nx_other: 2\n" );
    sh( '.', qw{fetch -q}, $up_tcms );
    is_deeply( [ Trog::Jobs::Updates::new_needs( '.', $from, $same ) ], [], 'another key of metamerge.yml needs nothing' );

    my $more = commit( $up_tcms, 'metamerge.yml' => "x_system_packages:\n  ffmpeg: {}\n  libfoo: {}\n" );
    sh( '.', qw{fetch -q}, $up_tcms );
    like( ( Trog::Jobs::Updates::new_needs( '.', $from, $more ) )[0], qr/system[ ]packages/, 'a new system package needs a person' );

    $mock->redefine( missing_modules => sub ( $dir, $commit ) { return qw{Foo::Bar Baz} } );
    like( ( Trog::Jobs::Updates::new_needs( '.', $from, $same ) )[0], qr/perl[ ]modules[ ].*[ ]Foo::Bar,[ ]Baz/, 'and so do modules this perl lacks' );
    $mock->redefine( missing_modules => sub ( $dir, $commit ) { die "dzil is not installed\n" } );
    is_deeply( [ Trog::Jobs::Updates::new_needs( '.', $from, $same ) ], ['dzil is not installed'], 'and not being able to tell' );
    sh( $up_tcms, qw{reset -q --hard HEAD~2} );
};

subtest 'unit_of' => sub {
    my $proc = "$TOP/proc";
    File::Path::make_path("$proc/42");
    Path::Tiny::path("$proc/42/cgroup")->spew_utf8("0::/system.slice/test.test.service\n");
    local $Trog::Jobs::Updates::proc = $proc;
    is( Trog::Jobs::Updates::unit_of(42), 'test.test.service', 'the unit, from the cgroup' );
    is( Trog::Jobs::Updates::unit_of(43), undef,               'none for a process that is not there' );
};

subtest 'may_restart' => sub {
    my @asked;
    my $mock = Test::MockModule->new('Trog::Jobs::Updates');
    $mock->redefine( run_command => sub ( $command, %options ) { push @asked, $command; return ( 0, '', '' ) } );
    ok( !Trog::Jobs::Updates::may_restart( 'tcms-worker-test.test.service', 1 ), 'no, when sudo -l refuses' );
    is_deeply( \@asked, [ [qw{sudo -n -l /usr/bin/systemctl restart --no-block tcms-worker-test.test.service}] ], '...asked for the command that restart_unit runs' );
};

subtest 'tpsgi_pid' => sub {
    like( exception { Trog::Jobs::Updates::tpsgi_pid() }, qr/a[ ]person[ ]must[ ]restart[ ]tPSGI/, 'no pid file' );
    File::Path::make_path('../run');
    Path::Tiny::path('../run/tpsgi.pid')->spew_utf8("1234\n");
    is( Trog::Jobs::Updates::tpsgi_pid(), 1234, 'the master, from run/tpsgi.pid of tPSGI' );
};

# The tasks run in this process, so that the mocks see them, against a queue in
# data/ of this root.
my $minion = Trog::Jobs::register_tasks( Trog::Jobs::minion() );

my sub run_update ($name) {
    my $id = Trog::Updates::enqueue_update($name);
    $minion->perform_jobs_in_foreground( { tasks => ['update'] } );
    return $minion->job($id)->info;
}

subtest 'check_task' => sub {
    my $id = Trog::Updates::enqueue_check();
    $minion->perform_jobs_in_foreground( { tasks => ['update_check'] } );
    my $result = $minion->job($id)->info->{result};
    ok( $result->{checked_at}, 'the check finishes with when it ran' );
    is_deeply( [ map { "$_->{name} $_->{state}" } @{ $result->{checkouts} } ], [ 'tCMS behind', 'tPSGI behind' ], '...and the state of each checkout' );

    my $mock = Test::MockModule->new('Trog::Jobs::Updates');
    $mock->redefine( status => sub ($co) { die "git rev-parse HEAD: broken\n" } );
    $id = Trog::Updates::enqueue_check();
    $minion->perform_jobs_in_foreground( { tasks => ['update_check'] } );
    is_deeply(
        $minion->job($id)->info->{result}{checkouts}[0],
        { name => 'tCMS', label => 'tCMS', state => 'unreachable', error => 'git rev-parse HEAD: broken' },
        'a checkout that git cannot read is unreachable, with the reason'
    );
};

subtest 'update_task' => sub {
    my ( @hups, @restarts, @installs );
    my $mock = Test::MockModule->new('Trog::Jobs::Updates');
    $mock->redefine( hup_tpsgi       => sub { push @hups, 1;                                                 return } );
    $mock->redefine( restart_unit    => sub ( $unit, $no_block = 0 ) { push @restarts, [ $unit, $no_block ]; return } );
    $mock->redefine( reinstall       => sub { push @installs, 1;                                             return } );
    $mock->redefine( missing_modules => sub ( $dir, $commit ) { return } );
    $mock->redefine( unit_of         => sub ($pid) { return $pid eq 'self' ? 'tcms-worker-test.test.service' : 'test.test.service' } );
    $mock->redefine( tpsgi_pid       => sub { return 1234 } );
    my $may = 1;
    $mock->redefine( may_restart => sub ( $unit, $no_block = 0 ) { return $may } );

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
    $may  = 0;
    commit( $up_tcms, 'e' => 5 );
    $info = run_update('tCMS');
    is( $info->{state}, 'failed', 'an update whose worker sudo will not restart fails' );
    like( $info->{result}{error}, qr/(?-x:so a person must restart it)/, '...and says who must restart it' );
    is_deeply( [ scalar @hups, \@restarts ], [ 1, [] ], '...after the pull and the HUP, which worked' );
    $may = 1;

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

done_testing();
