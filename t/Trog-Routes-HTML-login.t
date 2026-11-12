#!/usr/bin/env perl
use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Test::More;

use FindBin::libs;

require_ok('Trog::Routes::HTML') or BAIL_OUT("Can't find SUT");

{

    package FakeTPSGI;
    sub new      ($class)   { return bless {}, $class }
    sub see_also ( $, $to ) { return [ 303, [ Location => $to ], [''] ] }
}

subtest 'login, for a user who is logged in already' => sub {
    foreach my $to ( qw{/posts/p-one /secure/p-two /login}, undef ) {
        my $res = Trog::Routes::HTML::login( { user => 'someone', route => '/login', to => $to, tpsgi => FakeTPSGI->new() } );
        is( $res->[0],                      303,       'is a redirect, with to=' . ( $to // 'nothing' ) );
        is( { @{ $res->[1] } }->{Location}, '/config', 'to the configuration, not back to the page with the login link' );
    }
};

done_testing();
