#!/usr/bin/env perl

# TOTP is not optional here.  These tests are about the window between "logged
# in" and "enrolled", which exists because a login is what gets you the QR --
# and about the fact that there is no longer any way to turn 2fa back off.

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
    $ROOT   = File::Temp::tempdir( 'tcms-totp-XXXXXX', TMPDIR => 1, CLEANUP => 1 );

    # Every path in this app is cwd relative, the auth db included, so the tests
    # stand in an instance root of their own rather than in the checkout.  This
    # is a BEGIN because TCMS.pm builds its routing table at file scope, against
    # whatever cwd is current when it loads.
    #
    # Text::Xslate works out its cache directory from HOME once, at load time.
    $ENV{HOME} = $ROOT;
    File::Path::make_path( map { "$ROOT/$_" } qw{config schema data/files logs totp www/statics www/themes} );

    # Hardcoded paths in Auth.pm, TagIndex.pm, the data models and Log.pm.
    File::Copy::copy( "$REPO/schema/$_", "$ROOT/schema/$_" ) or die $! for qw{auth.schema flatfile.schema log.schema};

    open( my $fh, '>', "$ROOT/config/default.cfg" ) or die $!;
    print {$fh} "[general]\n    data_model=FlatFile\n    hostname=totp.example.com\n";
    close $fh;

    # Otherwise login() reads the instance as a fresh install and registers
    # whoever knocks first as the admin, which is a different test.
    open( $fh, '>', "$ROOT/config/has_users" ) or die $!;
    close $fh;

    chdir($ROOT) or die "could not chdir to the sandbox: $!";
}

END {
    chdir($OLDCWD) if $OLDCWD;
}

require_ok('Trog::Auth') or BAIL_OUT("Can't find SUT");
require_ok('TCMS')       or BAIL_OUT("Can't load the dispatcher");
require_ok('Trog::Routes::HTML');

Trog::Auth::useradd( 'bob', 'Bob Bobson', 'hunter2', ['admin'], 'bob@example.com' )
  or BAIL_OUT('could not make a user to test with');

subtest 'a user starts out unenrolled' => sub {
    is( Trog::Auth::has_totp('bob'),           0, 'a fresh user has no second factor' );
    is( Trog::Auth::has_totp('nobody-at-all'), 0, 'nor does somebody who does not exist' );

    # Which is the only reason logging in without a token works at all: it is
    # how you get to the page that gives you one.
    ok( Trog::Auth::mksession( 'bob', 'hunter2', '', '127.0.0.1' ), 'and can still log in, with no token' );
};

subtest 'and cannot go anywhere but /totp until they enrol' => sub {
    my %page = ( auth => 1 );
    my %public;
    my %enrol = ( auth => 1, totp_exempt => 1 );

    is( TCMS::needs_enrolment( 'bob', \%page ),   1, 'a page behind a login is refused' );
    is( TCMS::needs_enrolment( 'bob', \%enrol ),  0, 'the enrolment page is not, or there would be nowhere to go' );
    is( TCMS::needs_enrolment( 'bob', \%public ), 0, 'and a public page is nobody\'s business' );

    # Nothing to enrol, and nothing to protect.
    is( TCMS::needs_enrolment( '', \%page ), 0, 'a logged out visitor is left alone' );

    my ( $uri, $qr, $failure, $message ) = Trog::Auth::totp( 'bob', 'totp.example.com' );
    ok( $uri, 'enrolling gives them a URI' ) or diag($message);
    is( Trog::Auth::has_totp('bob'), 1, 'and they are enrolled' );

    is( TCMS::needs_enrolment( 'bob', \%page ), 0, 'after which every page opens up' );
};

subtest 'the enrolment does not change' => sub {

    # A user who lost their authenticator scans the same code into the next one,
    # which is what makes having no way to turn 2fa off a supportable position.
    my ( $uri, $qr, $failure ) = Trog::Auth::totp( 'bob', 'totp.example.com' );
    my ( $again, $qr2 ) = Trog::Auth::totp( 'bob', 'totp.example.com' );
    is( $again,   $uri, 'asking again gives back the enrolment they already have' );
    is( $qr2,     $qr,  'and the same QR' );
    is( $failure, -1,   'reported as nothing new having been generated' );
};

subtest 'and there is no way to turn it off' => sub {
    ok( !Trog::Auth->can('clear_totp'),                             'Trog::Auth cannot clear a secret' );
    ok( !Trog::Routes::HTML->can('do_totp_clear'),                  'nor is there a route handler to ask it to' );
    ok( !exists $Trog::Routes::HTML::routes{'/request_totp_clear'}, 'nor a route' );

    # The two the gate lets through, which is the whole of the exemption.
    ok( $Trog::Routes::HTML::routes{'/totp'}{totp_exempt},         'the enrolment page says it is exempt' );
    ok( $Trog::Routes::HTML::routes{'/totp_qr/(.*)'}{totp_exempt}, 'and so does the QR on it' );
    my @exempt = grep { $Trog::Routes::HTML::routes{$_}{totp_exempt} } keys(%Trog::Routes::HTML::routes);
    is( scalar(@exempt), 2, 'and nothing else is' );
};

subtest 'a login without an enrolment is sent to enrol' => sub {
    my $tpsgi = bless {}, 'FakeTPSGI';
    {
        no warnings qw{once};
        *FakeTPSGI::see_also = sub { return [ 303, [ Location => $_[1] ], [''] ] };
    }

    # login() renders rather than redirects on success -- the redirect is the
    # 'to' the page then sends the browser to -- so that is what to look at.
    my $rendered;
    my $renderer = Test::MockModule->new('Trog::Renderer');
    $renderer->redefine( render => sub { my ( $class, %args ) = @_; $rendered = $args{data}; return [ 200, [], [''] ] } );

    my $auth = Test::MockModule->new('Trog::Auth');
    $auth->redefine( mksession => sub { return 'a-session' } );
    $auth->redefine( has_totp  => sub { return 0 } );

    Trog::Routes::HTML::login( { username => 'bob', password => 'hunter2', to => '/config', tpsgi => $tpsgi, scheme => 'http', route => '/auth' } );
    is( $rendered->{to}, '/totp', 'a login with nothing enrolled goes to enrol, not where it was headed' );

    $auth->redefine( has_totp => sub { return 1 } );
    Trog::Routes::HTML::login( { username => 'bob', password => 'hunter2', to => '/config', tpsgi => $tpsgi, scheme => 'http', route => '/auth' } );
    is( $rendered->{to}, '/config', 'and one with a second factor goes where it was headed' );
};

done_testing();
