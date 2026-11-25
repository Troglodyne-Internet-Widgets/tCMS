#!/usr/bin/env perl
use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Test::More;
use JSON::Validator  ();
use JSON::MaybeXS    ();
use Test::MockModule qw{strict};

use FindBin::libs;

require_ok('Trog::Routes::JSON') or BAIL_OUT("Can't find SUT");

subtest 'the change request token is a uuid, and nothing else' => sub {
    no warnings 'once';
    my ($token) = @{ $Trog::Routes::JSON::routes{'/api/auth_change_request/{token}'}{parameters} };
    my $jv      = JSON::Validator->new->schema( $token->{schema} );
    my $valid   = sub ($value) { return !$jv->validate($value) };

    ok( $valid->('5bed1745-4201-40dd-b5dd-65acc0316604'),    'a uuid is a token' );
    ok( !$valid->(q{}),                                      'nothing is not' );
    ok( !$valid->('x;drop table user'),                      'and neither is text with a hex digit in it' );
    ok( !$valid->("5bed1745-4201\n"),                        'nor a token with something after it' );
    ok( !$valid->("5bed1745-4201-40dd-b5dd-65acc0316604\n"), 'nor a uuid with a newline after it' );
    ok( !$valid->('a|b'),                                    'nor a pipe, which the class used to hold' );
};

subtest 'webmanifest links each icon from the theme or the stock icons' => sub {
    my $themes = Test::MockModule->new('Trog::Themes');
    $themes->redefine( themed => sub ($resource) { $resource eq 'img/icon/favicon-192.png' ? "www/themes/spec/$resource" : "www/$resource" } );

    my $res      = Trog::Routes::JSON::webmanifest();
    my $manifest = JSON::MaybeXS::decode_json( join( '', @{ $res->[2] } ) );
    my %src      = map { $_->{sizes} => $_->{src} } @{ $manifest->{icons} };

    is( $src{'192x192'},     '/themes/spec/img/icon/favicon-192.png', "an icon that the theme has is linked from the theme" );
    is( $src{'48x48'},       '/img/icon/favicon-48.png',              "and one that it has not is linked from the stock icons" );
    is( scalar( keys %src ), 6,                                       "every size is listed" );
};

done_testing();
