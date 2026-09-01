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
    File::Path::make_path("$ROOT/$_") for qw{config logs www/assets};

    # Stand-ins for the two repositories, with the two programs the lifecycle
    # runs.  Never executed -- _spawn is mocked -- but they have to be there and
    # executable, because reprovision() checks that before it commits to
    # anything.
    File::Path::make_path("$ROOT/provisioners/$_") for qw{bin recipes.d};
    File::Path::make_path("$ROOT/trog-provisioner/bin");
    foreach my $program ( "$ROOT/provisioners/bin/new_config", "$ROOT/trog-provisioner/bin/provision" ) {
        open( my $fh, '>', $program ) or die $!;
        print {$fh} "#!/bin/sh\nexit 0\n";
        close $fh;
        chmod( 0755, $program );
    }
    open( my $recipe, '>', "$ROOT/provisioners/recipes.d/guest.example.com.yaml" ) or die $!;
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

my $log = Test::MockModule->new('Trog::DataSource::ProvisionedVirt');
$log->redefine( WARN => sub { note(shift) } );
$log->redefine( INFO => sub { note(shift) } );

# Nothing in this file forks, and nothing in it runs a provisioner.
our @SPAWNED;
$log->redefine(
    _spawn => sub {
        my ( $domain, $passphrase, $lifecycle, $user ) = @_;
        push( @SPAWNED, { domain => $domain, passphrase => $passphrase, lifecycle => $lifecycle, user => $user } );
        return ( 1, 'started' );
    }
);

# Nor reaches a hypervisor.
my $virt = Test::MockModule->new('Trog::DataSource::Virt');
$virt->redefine( _is_self => sub { return $_[0] eq 'thisserver.example.com' ? 1 : 0 } );

write_config(
    provisioners     => "$ROOT/provisioners",
    trog_provisioner => "$ROOT/trog-provisioner",
);

sub reprovision {
    @SPAWNED = ();
    return Trog::DataSource::ProvisionedVirt::reprovision( passphrase => 'hunter2', user => 'admin', @_ );
}

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
    is( $ok, 0, 'a run with no passphrase, which new_config would just hang waiting for' );
    like( $why, qr/passphrase/, 'and says why' );

    # The name reaches the filesystem and an argument list.
    foreach my $bad ( '../../etc/passwd', 'guest;rm -rf /', 'guest example.com', '', 'a' x 300, '.hidden' ) {
        my ( $refused, $message ) = reprovision( domain => $bad );
        is( $refused, 0, "'$bad' is refused" );
        like( $message, qr/bad guest name|no recipe/, '...before anything is run' );
    }

    is_deeply( \@SPAWNED, [], 'and none of that ran a provisioner' );
};

subtest 'the lifecycle it would run' => sub {
    my ( $ok, $why ) = reprovision( domain => 'guest.example.com' );
    is( $ok, 1, 'a guest with a recipe is accepted' ) or diag($why);
    like( $why, qr/started/, 'and reports that it started rather than that it finished' );

    is( scalar(@SPAWNED), 1, 'exactly one run' );
    my $run = $SPAWNED[0];
    is( $run->{domain}, 'guest.example.com', 'for the guest asked about' );
    is( $run->{user},   'admin',             'recording who asked' );

    # new_config in provisioners, then provision in trog-provisioner, each in
    # its own repository.
    is( scalar( @{ $run->{lifecycle} } ), 2, 'two steps' );
    my ( $first, $second ) = @{ $run->{lifecycle} };
    is( $first->[0], "$ROOT/provisioners", 'the first runs in provisioners' );
    like( $first->[1], qr{/bin/new_config$}, 'and is new_config' );
    is( $first->[2],  'guest.example.com',      'passed the guest as an argument' );
    is( $second->[0], "$ROOT/trog-provisioner", 'the second runs in trog-provisioner' );
    like( $second->[1], qr{/bin/provision$}, 'and is provision' );
    is( $second->[2], 'guest.example.com', 'passed the same' );

    # Arguments, not a command line: there is no shell between us and these, so
    # a guest name can never be read as one.
    foreach my $step ( @{ $run->{lifecycle} } ) {
        is( scalar(@$step), 3, 'a directory, a program and one argument -- nothing to be parsed' );
    }
};

subtest 'without the repositories configured it is just Virt' => sub {
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
    write_config( provisioners => "$ROOT/nonesuch", trog_provisioner => "$ROOT/trog-provisioner" );
    ( $ok, $why ) = reprovision( domain => 'guest.example.com' );
    is( $ok, 0, 'a configured path which is not there is refused' );

    write_config(
        provisioners     => "$ROOT/provisioners",
        trog_provisioner => "$ROOT/trog-provisioner",
    );
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
    is( $SPAWNED[0]{passphrase}, 'hunter2', 'the passphrase reaches the lifecycle' );
    ok( !exists $query->{passphrase}, 'and is gone from the query afterwards' );
};

done_testing();
