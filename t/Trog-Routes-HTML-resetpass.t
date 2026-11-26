#!/usr/bin/env perl

# Who can reset whose password, and what a link in a reset email may do.

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use FindBin;
use FindBin::libs;

use Test2::V1        qw{diag done_testing is like ok subtest};
use Test::MockModule qw{strict};
use JSON::Validator  ();

our ( $REPO, $ROOT, $OLDCWD );

BEGIN {
    require Cwd;
    require File::Copy;
    require File::Path;
    require File::Temp;

    $REPO   = Cwd::abs_path("$FindBin::Bin/..");
    $OLDCWD = Cwd::getcwd();
    $ROOT   = File::Temp::tempdir( 'tcms-resetpass-XXXXXX', TMPDIR => 1, CLEANUP => 1 );

    # Every path in this app is cwd relative, the auth db included, so the
    # tests stand in an instance root of their own.  A BEGIN, because the route
    # modules read the configuration as they load.
    $ENV{HOME} = $ROOT;
    File::Path::make_path( map { "$ROOT/$_" } qw{config share schema data/files logs totp www/statics www/themes} );
    foreach my $schema (qw{auth.schema flatfile.schema log.schema}) { File::Copy::copy( "$REPO/schema/$schema", "$ROOT/schema/$schema" ) or die $! }
    symlink( "$REPO/www/templates", "$ROOT/www/templates" ) or die "could not link the templates: $!";

    open( my $fh, '>', "$ROOT/share/default.cfg" ) or die $!;
    print {$fh} "[general]\n    data_model=FlatFile\n    hostname=reset.test.test\n";
    close($fh) or die $!;

    open( my $flag, '>', "$ROOT/config/has_users" ) or die $!;
    close($flag)                                    or die $!;

    chdir($ROOT) or die "could not chdir to the sandbox: $!";
}

END {
    chdir($OLDCWD) if $OLDCWD;
}

use Trog::Auth;
use Trog::Routes::HTML;
use Trog::Routes::JSON;

package FakeTPSGI {
    use 5.040;
    sub see_also   ( $, $to )     { return [ 303, [ Location => $to ], [q{}] ] }
    sub forbidden  ( $, $ )       { return [ 403, [], [q{}] ] }
    sub badrequest ( $, $, $why ) { return [ 400, [], [$why] ] }
}

my $tpsgi = bless {}, 'FakeTPSGI';
my $dbh   = Trog::SQLite::dbh( 'schema/auth.schema', 'config/auth.db' );

Trog::Auth::useradd( qw{alice Alice alice-old}, ['public'], 'alice@test.test' );
Trog::Auth::useradd( qw{bob Bob bob-old},       ['public'], 'bob@test.test' );
Trog::Auth::useradd( qw{root Root root-old},    ['admin'],  'root@test.test' );

sub reset_as ( $who, $acls, %input ) {
    return Trog::Routes::HTML::do_resetpass( { user => $who, user_acls => $acls, input => \%input, tpsgi => $tpsgi, scheme => 'https', domain => 'reset.test.test' } );
}

sub request_row ($token) {
    return $dbh->selectrow_hashref( 'SELECT processed, secret FROM change_request WHERE token = ?', undef, $token );
}

# A logged-out reset of alice, and the token from the email it sends.
sub emailed_token () {
    my $uri;
    my $email = Test::MockModule->new('Trog::Email');
    $email->redefine( contact => sub ( $to, $from, $subject, $data ) { $uri = $data->{uri}; return 1 } );
    my $res = reset_as( undef, [], username => 'alice', password => 'chosen-by-the-requester' );
    is( $res->[0], 303, 'a logged-out reset is accepted' );
    my $prefix = 'https://reset.test.test/auth_change_request/';
    my $token  = index( $uri // q{}, $prefix ) == 0 ? substr( $uri, length $prefix ) : undef;
    $token = undef if JSON::Validator->new->schema( Trog::Utils::uuid_schema() )->validate( $token // q{} );
    ok( $token, 'and emails a link to the form that sets the password' ) or diag( "the link was: " . ( $uri // 'undef' ) );
    return $token;
}

subtest 'do_resetpass: a logged-in user resets their own password and nobody else\'s' => sub {
    is( reset_as( 'bob', ['public'], username => 'alice', password => 'chosen-by-bob' )->[0], 403, 'bob may not reset alice' );
    ok( Trog::Auth::check_password( 'alice', 'alice-old' ), 'and alice keeps her password' );

    is( reset_as( 'bob', ['public'], username => 'bob', password => 'bob-new' )->[0], 303, 'bob may reset his own' );
    ok( Trog::Auth::check_password( 'bob', 'bob-new' ), 'and it changes' );

    is( reset_as( 'bob', ['public'], username => 'bob' )->[0], 400, 'but not to nothing' );
    ok( Trog::Auth::check_password( 'bob', 'bob-new' ), 'which leaves it as it was' );

    is( reset_as( 'root', ['admin'], username => 'alice', password => 'alice-by-admin' )->[0], 303, 'an admin may reset anybody' );
    ok( Trog::Auth::check_password( 'alice', 'alice-by-admin' ), 'and it changes' );
};

subtest 'do_resetpass: a logged-out request cannot choose the password' => sub {
    my $token = emailed_token();
    ok( !Trog::Auth::check_password( 'alice', 'chosen-by-the-requester' ), 'the password in the request is not set' );
    ok( Trog::Auth::check_password( 'alice',  'alice-by-admin' ),          'and alice keeps her password' );
    is( request_row($token), { processed => 0, secret => undef }, 'the request stores no password' );
};

subtest 'a GET of the link changes nothing' => sub {
    my $token = emailed_token();

    my %rendered;
    my $html = Test::MockModule->new('Trog::Routes::HTML');
    $html->redefine( index => sub ( $query, @ ) { %rendered = %$query; return [ 200, [], [q{}] ] } );

    Trog::Routes::HTML::change_request_form( { input => { token => $token }, tpsgi => $tpsgi } );
    is( [ @rendered{qw{template token}} ], [ 'change_request.tx', $token ], 'the link shows the form, which posts the token' );

    my $form = Trog::Renderer->render( template => 'change_request.tx', data => { token => $token }, component => 1, contenttype => 'text/html' );
    like( $form, qr{<form[^>]+action="/auth_change_request"[^>]+method="POST"}, 'the form renders, and posts' );
    like( $form, qr{name="token"[ ]value="\Q$token\E"},                         'with the token in it' );

    my $old = Trog::Routes::JSON::process_auth_change_request( { input => { token => $token }, tpsgi => $tpsgi } );
    is( $old, [ 303, [ Location => "/auth_change_request/$token" ], [q{}] ], 'the link of an older email is sent to that form' );

    is( request_row($token)->{processed}, 0, 'and the token is still unspent' );
};

subtest 'do_change_request: the form sets the password, once' => sub {
    my $token  = emailed_token();
    my $change = sub ($password) { return Trog::Routes::HTML::do_change_request( { input => { token => $token, password => $password }, tpsgi => $tpsgi } )->[0] };

    is( $change->(q{}),                   403, 'an empty password is refused' );
    is( request_row($token)->{processed}, 0,   'and does not spend the token' );

    is( $change->('from-the-form'), 303, 'a password is set' );
    ok( Trog::Auth::check_password( 'alice', 'from-the-form' ), 'and alice can log in with it' );

    is( $change->('again'), 403, 'the token cannot be used twice' );
    ok( !Trog::Auth::check_password( 'alice', 'again' ), 'so the second password is not set' );

    is( Trog::Routes::HTML::do_change_request( { input => { token => Trog::Utils::uuid(), password => 'guess' }, tpsgi => $tpsgi } )->[0], 403, 'nor is one with a token that was never issued' );
};

subtest 'the routes' => sub {
    no warnings 'once';
    is( $Trog::Routes::HTML::routes{'/auth_change_request/{token}'}{method}, 'GET',  'the link is a GET' );
    is( $Trog::Routes::HTML::routes{'/auth_change_request'}{method},         'POST', 'and the form that it shows is a POST' );
};

done_testing();
