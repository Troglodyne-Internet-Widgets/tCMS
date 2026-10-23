#!/usr/bin/env perl

# spawn() for real: it forks, detaches, and runs a provisioner, which here is
# a shell script in a sandbox.  t/Trog-DataSource-ProvisionedVirt.t mocks it,
# so this is the one place where its child is run.

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use FindBin::libs;

use Test::More;
use File::Temp  qw{tempdir};
use File::Path  ();
use Time::HiRes ();

our ( $ROOT, $OLDCWD );

BEGIN {
    require Cwd;
    $OLDCWD    = Cwd::getcwd();
    $ROOT      = tempdir( 'tcms-spawn-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    $ENV{HOME} = $ROOT;
}

require_ok('Trog::DataSource::ProvisionedVirt') or BAIL_OUT("Can't find SUT");

END {
    chdir($OLDCWD) if $OLDCWD;
}

{
    no warnings qw{once};
    $Trog::DataSource::ProvisionedVirt::log_dir = "$ROOT/logs";
}
File::Path::make_path("$ROOT/bin");

my sub provisioner ( $name, $body ) {
    my $program = "$ROOT/bin/$name";
    open( my $fh, '>', $program ) or die "$program: $!";
    print {$fh} "#!/bin/sh\n$body\n";
    close($fh)              or die "$program: $!";
    chmod( 0755, $program ) or die "$program: $!";
    return $program;
}

# What the run says once it has stopped, or undef if it has not stopped within
# ten seconds.
my sub finished ($domain) {
    foreach ( 1 .. 100 ) {
        my $status = Trog::DataSource::ProvisionedVirt::status($domain);
        return $status if $status && $status->{state} ne 'running';
        Time::HiRes::sleep(0.1);
    }
    return;
}

my sub run ( $domain, $program, $credentials ) {
    my ( $ok, $why ) = Trog::DataSource::ProvisionedVirt::spawn( $domain, $credentials, $ROOT, [ $program, $domain ], 'admin' );
    ok( $ok, "a run for $domain starts" ) or diag($why);
    return finished($domain);
}

# Starman, under which tPSGI runs, ignores SIGPIPE, and its children inherit
# that.  So a write to a provisioner that has gone fails rather than kills.
local $SIG{PIPE} = 'IGNORE';

subtest 'a provisioner that reads its credentials and succeeds' => sub {
    my $status = run( 'reads.test.test', provisioner( 'reads', 'cat >/dev/null; exit 0' ), { password => 'hunter2' } );
    is( $status->{state}, 'ok', 'the run is ok' );
    is( $status->{exit},  '0',  'and exited 0' );
};

subtest 'a provisioner that fails' => sub {
    my $status = run( 'fails.test.test', provisioner( 'fails', 'cat >/dev/null; exit 3' ), { password => 'hunter2' } );
    is( $status->{state}, 'failed', 'the run failed' );
    is( $status->{exit},  '3',      'with what the provisioner exited' );
};

# More than a pipe holds, so the write cannot finish before the provisioner
# has gone, whichever of the two is first.
subtest 'a provisioner that never reads its credentials' => sub {
    my $status = run( 'deaf.test.test', provisioner( 'deaf', 'exit 0' ), { password => 'x' x 1_048_576 } );
    is( $status->{state}, 'failed', 'the run failed, although the provisioner exited 0' );
    my $log = Trog::DataSource::ProvisionedVirt::log_for('deaf.test.test') // '';
    like( $log, qr/could[ ]not[ ]write[ ]to[ ]\N*deaf/, 'and the log says that it never got them' );
};

done_testing();
