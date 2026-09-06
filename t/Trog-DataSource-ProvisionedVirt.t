#!/usr/bin/env perl

# Reprovisioning destroys a machine and builds it again, so the whole of this
# file is about what has to be true before anything runs.  _spawn is mocked
# throughout: nothing here forks, and nothing here executes a provisioner.

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

    $REPO   = Cwd::abs_path("$FindBin::Bin/..");
    $OLDCWD = Cwd::getcwd();
    $ROOT   = File::Temp::tempdir( 'tcms-provisioned-XXXXXX', TMPDIR => 1, CLEANUP => 1 );

    $ENV{HOME} = $ROOT;
    File::Path::make_path("$ROOT/$_") for qw{config schema logs totp www/assets};

    # A vault, so that the half of this which is about not having to type a
    # passphrase every time has somewhere to keep one.  The key arrives the way
    # a deployment hands one over, and Trog::Vault takes it out of %ENV as it
    # loads -- so this has to be set before the SUT is required, below.
    File::Copy::copy( "$REPO/schema/auth.schema", "$ROOT/schema/auth.schema" ) or die $!;
    require Crypt::Misc;
    require Crypt::PRNG;
    $ENV{TPSGI_VAULT_KEY} = Crypt::Misc::encode_b64( Crypt::PRNG::random_bytes(32) );

    # A stand-in for the checkout, with the one program a reprovision runs.
    # Never executed -- _spawn is mocked -- but it has to be there and
    # executable, because reprovision() checks that before it commits to
    # anything.
    File::Path::make_path("$ROOT/trog-provisioner/bin");
    my $program = "$ROOT/trog-provisioner/bin/provision";
    open( my $fh, '>', $program ) or die $!;
    print {$fh} "#!/bin/sh\nexit 0\n";
    close $fh;
    chmod( 0755, $program );

    # And a stand-in for the installation's own files, which live where the
    # provisioner keeps them rather than anywhere tCMS is told about.
    $ENV{TROG_PROVISIONER_CONFIG} = "$ROOT/etc";
    File::Path::make_path("$ROOT/etc/recipes.d");
    open( my $recipe, '>', "$ROOT/etc/recipes.d/guest.example.com.yaml" ) or die $!;
    print {$recipe} "---\n_global:\n  registrar: secret:x/y/z\n";
    close $recipe;

    chdir($ROOT) or die "could not chdir to the sandbox: $!";
}

END {
    chdir($OLDCWD) if $OLDCWD;
}

sub write_config {
    my (%section) = @_;
    open( my $fh, '>', "$ROOT/config/default.cfg" ) or die $!;
    print {$fh} "[general]\n    data_model=FlatFile\n[provisioner]\n";
    print {$fh} "    $_=$section{$_}\n" foreach sort keys %section;
    close $fh;

    # Trog::Config memoises, which is what a running server wants and a test
    # emphatically does not.
    no warnings qw{once redefine};
    require Config::Simple;
    my $conf = Config::Simple->new("$ROOT/config/default.cfg");
    local $@;
    *Trog::Config::get = sub { return $conf };
    return;
}

require_ok('Trog::DataSource::ProvisionedVirt') or BAIL_OUT("Can't find SUT");

Trog::Auth::useradd( 'admin', 'The Admin', 'hunter2', ['admin'], 'admin@example.com' )
  or BAIL_OUT('could not make a user to test with');

my $log = Test::MockModule->new('Trog::DataSource::ProvisionedVirt');
$log->redefine( WARN => sub { note(shift) } );
$log->redefine( INFO => sub { note(shift) } );

# Nothing in this file forks, and nothing in it runs a provisioner.
our @SPAWNED;
$log->redefine(
    _spawn => sub {
        my ( $domain, $passphrase, $dir, $command, $user ) = @_;
        push( @SPAWNED, { domain => $domain, passphrase => $passphrase, dir => $dir, command => $command, user => $user } );
        return ( 1, 'started' );
    }
);

# Nor reaches a hypervisor.
my $virt = Test::MockModule->new('Trog::DataSource::Virt');
$virt->redefine( _is_self => sub { return $_[0] eq 'thisserver.example.com' ? 1 : 0 } );

write_config( trog_provisioner => "$ROOT/trog-provisioner" );

sub reprovision {
    @SPAWNED = ();
    return Trog::DataSource::ProvisionedVirt::reprovision( passphrase => 'hunter2', user => 'admin', @_ );
}

require Trog::Auth;
require Trog::Vault;

subtest 'it is Virt, with more' => sub {
    ok( Trog::DataSource::ProvisionedVirt->isa('Trog::DataSource::Virt'), 'it is a Virt' );

    # can() resolves through @ISA, which is how the datasource dispatcher finds
    # the halves this does not override.
    foreach my $inherited (qw{filter lang help}) {
        my $mine   = Trog::DataSource::ProvisionedVirt->can($inherited);
        my $theirs = Trog::DataSource::Virt->can($inherited);
        is( $mine, $theirs, "$inherited is the one Virt already had" );
    }

    # Virt has no order() of its own, so this correctly finds none and the
    # dispatcher falls back to Trog::DataSource::order.
    ok( !Trog::DataSource::ProvisionedVirt->can('order'), 'and the shared default ordering still applies' );

    # posts() is the one thing it does replace.
    isnt(
        Trog::DataSource::ProvisionedVirt->can('posts'),
        Trog::DataSource::Virt->can('posts'),
        'posts() is its own, since that is where the recipe is added'
    );

    is( Trog::DataSource::ProvisionedVirt->EDITABLE,  0, 'still nothing to edit' );
    is( Trog::DataSource::ProvisionedVirt->CACHEABLE, 0, 'and still never cached, since a guest\'s state is live' );
};

subtest 'the recipe lands on the guest' => sub {
    $virt->redefine(
        posts => sub {
            return (
                { title => 'guest.example.com',      domain      => 'guest.example.com',      is_self => 0 },
                { title => 'norecipe.example.com',   domain      => 'norecipe.example.com',   is_self => 0 },
                { title => 'thisserver.example.com', domain      => 'thisserver.example.com', is_self => 1 },
                { title => 'a hypervisor',           unreachable => 1,                        state   => 'nope' },
            );
        }
    );

    my @posts = Trog::DataSource::ProvisionedVirt::posts( {}, {} );
    is( scalar(@posts), 4, 'every guest Virt listed is still listed' );

    my ($provisioned) = grep { ( $_->{domain} // '' ) eq 'guest.example.com' } @posts;
    ok( $provisioned->{has_recipe}, 'the one with a recipe says so' );
    like( $provisioned->{recipe},      qr/registrar/,                             'and carries the recipe itself' );
    like( $provisioned->{recipe_path}, qr{recipes\.d/guest\.example\.com\.yaml$}, 'and where it came from' );
    is( $provisioned->{can_reprovision}, 1, 'and may be reprovisioned' );

    my ($bare) = grep { ( $_->{domain} // '' ) eq 'norecipe.example.com' } @posts;
    ok( !$bare->{has_recipe}, 'a guest with no recipe says so' );
    is( $bare->{can_reprovision}, 0, 'and may not be reprovisioned' );
    ok( exists $bare->{title}, 'but is listed all the same, since plenty of guests were not built by this' );

    my ($self) = grep { ( $_->{domain} // '' ) eq 'thisserver.example.com' } @posts;
    is( $self->{can_reprovision}, 0, 'the server drawing the page may never be reprovisioned' );

    my ($dead) = grep { $_->{unreachable} } @posts;
    ok( !$dead->{has_recipe}, 'an unreachable hypervisor is left exactly as it was' );
};

subtest 'what it refuses to reprovision' => sub {
    my ( $ok, $why ) = reprovision( domain => 'thisserver.example.com' );
    is( $ok, 0, 'the server it is running on' );
    like( $why, qr/this server/, 'and says why' );
    is_deeply( \@SPAWNED, [], 'without running anything' );

    ( $ok, $why ) = reprovision( domain => 'norecipe.example.com' );
    is( $ok, 0, 'a guest with no recipe' );
    like( $why, qr/no recipe/, 'and says why' );

    ( $ok, $why ) = reprovision( domain => 'guest.example.com', passphrase => '' );
    is( $ok, 0, 'a run with no passphrase, which the provisioner would just hang waiting for' );
    like( $why, qr/passphrase/, 'and says why' );

    # The name reaches the filesystem and an argument list.
    foreach my $bad ( '../../etc/passwd', 'guest;rm -rf /', 'guest example.com', '', 'a' x 300, '.hidden' ) {
        my ( $refused, $message ) = reprovision( domain => $bad );
        is( $refused, 0, "'$bad' is refused" );
        like( $message, qr/bad guest name|no recipe/, '...before anything is run' );
    }

    is_deeply( \@SPAWNED, [], 'and none of that ran a provisioner' );
};

subtest 'what it would run' => sub {
    my ( $ok, $why ) = reprovision( domain => 'guest.example.com' );
    is( $ok, 1, 'a guest with a recipe is accepted' ) or diag($why);
    like( $why, qr/started/, 'and reports that it started rather than that it finished' );

    is( scalar(@SPAWNED), 1, 'exactly one run' );
    my $run = $SPAWNED[0];
    is( $run->{domain}, 'guest.example.com', 'for the guest asked about' );
    is( $run->{user},   'admin',             'recording who asked' );

    # One program does the whole of it now: bin/provision generates the guest's
    # configuration from its recipe and then builds the machine.
    is( $run->{dir}, "$ROOT/trog-provisioner", 'run from the checkout' );
    like( $run->{command}[0], qr{/bin/provision$}, 'and it is bin/provision' );
    is( $run->{command}[1], 'guest.example.com', 'passed the guest as an argument' );

    # Arguments, not a command line: there is no shell between us and this, so a
    # guest name can never be read as one.
    is( scalar( @{ $run->{command} } ), 2, 'a program and one argument -- nothing to be parsed' );
};

subtest 'a stored passphrase, and a code instead of one' => sub {
    no warnings qw{once};

    # Nothing stored yet, so the form asks for the passphrase and offers to keep
    # it -- there is a vault key in this sandbox, so keeping it is on the table.
    $virt->redefine( posts => sub { return ( { title => 'guest.example.com', domain => 'guest.example.com', is_self => 0 } ) } );
    my ($post) = Trog::DataSource::ProvisionedVirt::posts( {}, { user => 'admin' } );
    is( $post->{passphrase_remembered}, 0, 'with nothing stored the form asks for the passphrase' );
    is( $post->{can_remember},          1, 'and can offer to remember it' );

    # A code is worth nothing when there is nothing stored to unlock: it is
    # proof somebody is here, not a password.
    my ( $ok, $why ) = reprovision( domain => 'guest.example.com', passphrase => undef, totp => '123456' );
    is( $ok, 0, 'a code with nothing stored behind it does not provision' );
    is_deeply( \@SPAWNED, [], 'having run nothing' );

    # Reprovision the old way, and ask for it to be kept.
    ( $ok, $why ) = reprovision( domain => 'guest.example.com', passphrase => 'correct horse', remember => 1 );
    is( $ok,                     1,               'a typed passphrase still provisions' ) or diag($why);
    is( $SPAWNED[0]{passphrase}, 'correct horse', 'and is what reaches the provisioner' );

    ($post) = Trog::DataSource::ProvisionedVirt::posts( {}, { user => 'admin' } );
    is( $post->{passphrase_remembered}, 1, 'after which the form asks for a code instead' );

    # And now the point of all of it: a code, spent, exchanged for what was
    # stored.  Enrol first -- a code is only meaningful for somebody enrolled.
    my ( $uri, $qr, $failure, $message, $totp ) = Trog::Auth::totp( 'admin', 'example.com' );
    ok( $uri, 'the user is enrolled' ) or diag($message);
    my $code = $totp->expected_totp_code( time() );

    ( $ok, $why ) = reprovision( domain => 'guest.example.com', passphrase => undef, totp => $code );
    is( $ok,                     1,               'a code provisions' ) or diag($why);
    is( $SPAWNED[0]{passphrase}, 'correct horse', 'handing the provisioner the passphrase that was stored' );

    # Spent, so it is worth this one reprovision and not every reprovision
    # somebody can click inside the window.
    ( $ok, $why ) = reprovision( domain => 'guest.example.com', passphrase => undef, totp => $code );
    is( $ok, 0, 'and cannot be used again' );
    like( $why, qr/already been used/, 'saying so' );
    is_deeply( \@SPAWNED, [], 'without running a second one' );

    Trog::Vault::forget( 'admin', $Trog::DataSource::ProvisionedVirt::secret_name );
};

subtest 'and when the vault key has gone' => sub {
    no warnings qw{once};

    # The key lives and dies with the machine, so this is the ordinary
    # consequence of rebuilding one rather than a disaster.  What must not
    # happen is the page going on asking for a code it cannot honour.
    Trog::Vault::set( 'admin', $Trog::DataSource::ProvisionedVirt::secret_name, 'correct horse' );
    $virt->redefine( posts => sub { return ( { title => 'guest.example.com', domain => 'guest.example.com', is_self => 0 } ) } );

    my ($post) = Trog::DataSource::ProvisionedVirt::posts( {}, { user => 'admin' } );
    is( $post->{passphrase_remembered}, 1, 'with the key here, the form asks for a code' );

    local $Trog::Vault::master = Crypt::PRNG::random_bytes(32);

    ($post) = Trog::DataSource::ProvisionedVirt::posts( {}, { user => 'admin' } );
    is( $post->{passphrase_remembered}, 0, 'and with it gone, back to asking for the passphrase' );
    is( $post->{can_reprovision},       1, 'the button is still offered, since it still works that way' );

    # Posted at directly, as somebody would from a page drawn a moment before
    # the key went away.
    my ( $uri, $qr, $failure, $message, $totp ) = Trog::Auth::totp( 'admin', 'example.com' );

    # The subtest above spent this window's codes.  Standing here for thirty
    # seconds would say the same thing and cost thirty seconds.
    require Trog::SQLite;
    Trog::SQLite::dbh( 'schema/auth.schema', 'config/auth.db' )->do("DELETE FROM totp_spent WHERE username='admin'");

    my $code = $totp->expected_totp_code( time() );
    my ( $ok, $why ) = reprovision( domain => 'guest.example.com', passphrase => undef, totp => $code );
    is( $ok, 0, 'a code is refused rather than exploding' );
    like( $why, qr/can open/, 'saying the passphrase cannot be opened' );
    like( $why, qr{/secrets}, 'and where to go about it' );
    is_deeply( \@SPAWNED, [], 'having provisioned nothing' );

    # And the refusal came before the code was spent, so the same code is still
    # good for the thing that does work.  Being told to go and re-store a
    # passphrase should not also cost somebody thirty seconds.
    ( $ok, $why ) = Trog::Auth::spend_totp( 'admin', $code );
    is( $ok, 1, 'the code was not spent on being told no' ) or diag($why);

    ( $ok, $why ) = reprovision( domain => 'guest.example.com', passphrase => 'typed it again', remember => 1 );
    is( $ok,                     1,                'and the passphrase still provisions' ) or diag($why);
    is( $SPAWNED[0]{passphrase}, 'typed it again', 'with what was typed' );

    ($post) = Trog::DataSource::ProvisionedVirt::posts( {}, { user => 'admin' } );
    is( $post->{passphrase_remembered}, 1, 'stored again under the key that is here now' );
};

subtest 'without the provisioner configured it is just Virt' => sub {
    write_config();

    my ( $ok, $why ) = reprovision( domain => 'guest.example.com' );
    is( $ok, 0, 'nothing to run' );
    like( $why, qr/not configured/, 'and says so plainly' );
    is_deeply( \@SPAWNED, [], 'having run nothing' );

    $virt->redefine( posts => sub { return ( { title => 'guest.example.com', domain => 'guest.example.com', is_self => 0 } ) } );
    my ($post) = Trog::DataSource::ProvisionedVirt::posts( {}, {} );
    ok( !$post->{has_recipe}, 'the listing still works' );
    is( $post->{can_reprovision}, 0, 'it simply offers no button' );

    # A path that is not there is a typo, and better found here than halfway
    # through a reprovision.
    write_config( trog_provisioner => "$ROOT/nonesuch" );
    ( $ok, $why ) = reprovision( domain => 'guest.example.com' );
    is( $ok, 0, 'a configured path which is not there is refused' );
    like( $why, qr/not configured/, 'the same as never having configured one' );

    write_config( trog_provisioner => "$ROOT/trog-provisioner" );
};

subtest 'the log is read back onto the page' => sub {
    no warnings qw{once};

    File::Path::make_path("$ROOT/logs/reprovision");
    open( my $fh, '>', "$ROOT/logs/reprovision/guest.example.com.log" ) or die $!;
    print {$fh} ( 'x' x 9000 ) . "\n=== finished ===\n";
    close $fh;

    my $tail = Trog::DataSource::ProvisionedVirt::_log_tail('guest.example.com');
    ok( length($tail) <= $Trog::DataSource::ProvisionedVirt::log_tail_bytes, 'only the tail of it' );
    like( $tail, qr/=== finished ===/, 'which is the part that says how it went' );

    is( Trog::DataSource::ProvisionedVirt::_log_tail('norecipe.example.com'), undef, 'nothing when it has never run' );
    is( Trog::DataSource::ProvisionedVirt::_log_tail('../../etc/passwd'),     undef, 'and a name that is not one reads nothing' );
};

subtest 'the state a reprovision leaves behind' => sub {
    no warnings qw{once};
    File::Path::make_path("$ROOT/logs/reprovision");

    my $status = "$ROOT/logs/reprovision/guest.example.com.status";
    my $write  = sub {
        open( my $fh, '>', $status ) or die $!;
        print {$fh} join( '', map { "$_\n" } @_ );
        close $fh;
    };

    # Nothing waits on the process which does the work, so this file is the
    # whole of what it can say for itself.
    $write->( 'state=ok', 'started=100', 'finished=200', 'exit=0', 'user=admin' );
    my $got = Trog::DataSource::ProvisionedVirt::status('guest.example.com');
    is( $got->{state},    'ok',    'a finished run reads back as finished' );
    is( $got->{exit},     '0',     'with what it exited' );
    is( $got->{user},     'admin', 'and who asked for it' );
    is( $got->{finished}, '200',   'and when it stopped' );

    $write->( 'state=failed', 'exit=3', 'failed=/x/bin/provision' );
    is( Trog::DataSource::ProvisionedVirt::status('guest.example.com')->{state}, 'failed', 'a failed one reads back failed' );

    # A live pid means it really is going on.  Ours is alive by definition.
    $write->( 'state=running', "pid=$$", 'started=100', 'user=admin' );
    is( Trog::DataSource::ProvisionedVirt::status('guest.example.com')->{state}, 'running', 'a run whose process is alive is running' );

    # And a dead one means it stopped without saying so, which is the case that
    # would otherwise leave the page claiming a provision forever.
    my $dead = 999999;
    $dead++ while kill( 0, $dead ) && $dead < 4194304;
    $write->( 'state=running', "pid=$dead", 'started=100' );
    is(
        Trog::DataSource::ProvisionedVirt::status('guest.example.com')->{state},
        'interrupted',
        'a run whose process is gone reads as interrupted, not as still going'
    );

    $write->('state=running');
    is( Trog::DataSource::ProvisionedVirt::status('guest.example.com')->{state}, 'interrupted', 'and so does one with no pid at all' );

    # Half a file is not a status.
    $write->('garbage');
    is( Trog::DataSource::ProvisionedVirt::status('guest.example.com'), undef, 'an unparseable status is no status' );

    is( Trog::DataSource::ProvisionedVirt::status('never.example.com'), undef, 'nothing for a guest that has never run' );
    is( Trog::DataSource::ProvisionedVirt::status('../../etc/passwd'),  undef, 'and a name that is not one reads nothing' );

    unlink($status);
};

subtest 'the listing says what is going on' => sub {
    no warnings qw{once};
    File::Path::make_path("$ROOT/logs/reprovision");

    my $status = "$ROOT/logs/reprovision/guest.example.com.status";
    open( my $log, '>', "$ROOT/logs/reprovision/guest.example.com.log" ) or die $!;
    print {$log} "some output\n";
    close $log;

    $virt->redefine( posts => sub { return ( { title => 'guest.example.com', domain => 'guest.example.com', is_self => 0 } ) } );

    open( my $fh, '>', $status ) or die $!;
    print {$fh} "state=running\npid=$$\nstarted=100\nuser=admin\n";
    close $fh;

    my ($post) = Trog::DataSource::ProvisionedVirt::posts( {}, {} );
    is( $post->{reprovision_state},    'running',                                  'the guest says it is reprovisioning' );
    is( $post->{reprovision_status},   'reprovisioning',                           'in words a person reads' );
    is( $post->{is_reprovisioning},    1,                                          'and is flagged as busy' );
    is( $post->{reprovision_by},       'admin',                                    'naming who started it' );
    is( $post->{can_reprovision},      0,                                          'and offers no button while one is going on' );
    is( $post->{reprovision_log_href}, '/guest/reprovision/log/guest.example.com', 'with a link to read the log' );

    # Starting a second one is refused for the same reason.
    my ( $ok, $why ) = reprovision( domain => 'guest.example.com' );
    is( $ok, 0, 'and a second run is refused while the first is going' );
    like( $why, qr/already running/, 'saying so' );
    is_deeply( \@SPAWNED, [], 'having started nothing' );

    open( $fh, '>', $status ) or die $!;
    print {$fh} "state=failed\nexit=3\nstarted=100\nfinished=200\nuser=admin\n";
    close $fh;

    ($post) = Trog::DataSource::ProvisionedVirt::posts( {}, {} );
    is( $post->{reprovision_state},  'failed',             'a failed run says so' );
    is( $post->{reprovision_status}, 'reprovision failed', 'in words' );
    is( $post->{reprovision_exit},   '3',                  'with what it exited' );
    is( $post->{is_reprovisioning},  0,                    'and is not busy' );
    is( $post->{can_reprovision},    1,                    'so it may be tried again' );

    unlink($status);
    ($post) = Trog::DataSource::ProvisionedVirt::posts( {}, {} );
    ok( !$post->{reprovision_state}, 'a guest which has never been reprovisioned says nothing about it' );
    is( $post->{can_reprovision}, 1, 'and may be' );
};

subtest 'reading the log' => sub {
    no warnings qw{once};

    is( Trog::DataSource::ProvisionedVirt::log_for('never.example.com'), undef, 'nothing when there has been no run' );
    is( Trog::DataSource::ProvisionedVirt::log_for('../../etc/passwd'),  undef, 'and a name that is not one reads nothing' );

    open( my $fh, '>', "$ROOT/logs/reprovision/guest.example.com.log" ) or die $!;
    print {$fh} "the whole log\n";
    close $fh;
    like( Trog::DataSource::ProvisionedVirt::log_for('guest.example.com'), qr/the whole log/, 'and the whole of it when there has' );

    # A provisioner can be chatty, and this goes out in one response.
    local $Trog::DataSource::ProvisionedVirt::log_max_bytes = 64;
    open( $fh, '>', "$ROOT/logs/reprovision/guest.example.com.log" ) or die $!;
    print {$fh} ( 'x' x 500 ) . "END\n";
    close $fh;
    my $capped = Trog::DataSource::ProvisionedVirt::log_for('guest.example.com');
    like( $capped, qr/truncated/, 'a huge one is truncated' );
    like( $capped, qr/END/,       'keeping the end, which is where the answer is' );
};

subtest 'the route' => sub {
    no warnings qw{once};
    require Trog::Routes::HTML;

    my $route = $Trog::Routes::HTML::routes{'/guest/reprovision'};
    ok( $route, 'is registered' );
    is( $route->{method}, 'POST', 'POST only, since it is not a thing to do by following a link' );
    is( $route->{auth},   1,      'and requires a login' );
    ok( $route->{nocache}, 'and is never cached' );
    ok( $route->{noindex}, 'nor indexed' );

    my $tpsgi = bless {}, 'FakeTPSGI3';
    {
        no warnings qw{once};
        *FakeTPSGI3::see_also  = sub { return [ 303, [ Location => $_[1] ], [''] ] };
        *FakeTPSGI3::forbidden = sub { return [ 403, [], ['no'] ] };
        *FakeTPSGI3::notfound  = sub { return [ 404, [], ['gone'] ] };
    }

    # Admin only, like every other thing that changes a guest.
    my $res = Trog::Routes::HTML::guest_reprovision( { user => 'bob', user_acls => ['public'], tpsgi => $tpsgi } );
    is( $res->[0], 403, 'a non-admin is refused' );
    is_deeply( \@SPAWNED, [], 'without running anything' );

    $res = Trog::Routes::HTML::guest_reprovision( { user => '', user_acls => [], tpsgi => $tpsgi } );
    is( $res->[0], 303, 'and somebody logged out is sent to log in' );

    # The passphrase must not survive the request: this hash gets cloned, logged
    # around and handed to renderers.
    @SPAWNED = ();
    my $query = { user => 'admin', user_acls => ['admin'], tpsgi => $tpsgi, guest => 'guest.example.com', passphrase => 'hunter2', to => '/vms' };
    Trog::Routes::HTML::guest_reprovision($query);
    is( scalar(@SPAWNED),        1,         'an admin gets their run' );
    is( $SPAWNED[0]{passphrase}, 'hunter2', 'the passphrase reaches the provisioner' );
    ok( !exists $query->{passphrase}, 'and is gone from the query afterwards' );

    # The log route.  It lives in logs/ rather than under www/, and the output
    # of a provisioner is a fine place for a hostname or an IP plan to turn up.
    my $logroute = $Trog::Routes::HTML::routes{'/guest/reprovision/log/(.*)'};
    ok( $logroute, 'the log route is registered' );
    is( $logroute->{method}, 'GET', 'as a GET, since it only reads' );
    is( $logroute->{auth},   1,     'behind a login' );
    is_deeply( $logroute->{captures}, ['guest'], "capturing 'guest', which survives routing" );

    $res = Trog::Routes::HTML::guest_reprovision_log( { user => 'bob', user_acls => ['public'], tpsgi => $tpsgi } );
    is( $res->[0], 403, 'a non-admin cannot read it' );

    $res = Trog::Routes::HTML::guest_reprovision_log( { user => 'admin', user_acls => ['admin'], tpsgi => $tpsgi, guest => 'never.example.com' } );
    is( $res->[0], 404, 'and a guest with no log is a 404 rather than an empty page' );
};

done_testing();
