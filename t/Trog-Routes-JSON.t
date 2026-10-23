#!/usr/bin/env perl
use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Test::More;
use JSON::Validator ();

use FindBin::libs;

require_ok('Trog::Routes::JSON') or BAIL_OUT("Can't find SUT");

subtest 'the change request token is a uuid, and nothing else' => sub {
    no warnings 'once';
    my ($token) = @{ $Trog::Routes::JSON::routes{'/api/auth_change_request/{token}'}{parameters} };
    my $jv = JSON::Validator->new->schema( $token->{schema} );
    my $valid = sub ($value) { return !$jv->validate($value) };

    ok( $valid->('5bed1745-4201-40dd-b5dd-65acc0316604'), 'a uuid is a token' );
    ok( !$valid->(q{}),                                   'nothing is not' );
    ok( !$valid->('x;drop table user'),                   'and neither is text with a hex digit in it' );
    ok( !$valid->("5bed1745-4201\n"),                     'nor a token with something after it' );
    ok( !$valid->("5bed1745-4201-40dd-b5dd-65acc0316604\n"), 'nor a uuid with a newline after it' );
    ok( !$valid->('a|b'),                                 'nor a pipe, which the class used to hold' );
};

done_testing();
