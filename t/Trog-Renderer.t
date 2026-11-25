#!/usr/bin/env perl
use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Test::More;
use Test::Fatal qw{exception};

use FindBin::libs;

require_ok('Trog::Renderer') or BAIL_OUT("Can't find SUT");

subtest 'a render that fails, and an error page that fails too' => sub {
    my $err = exception {
        Trog::Renderer->render( contenttype => 'text/html', component => 1, template => 'bogus-nothere.tx', data => {} );
    };
    like( $err, qr/Could[ ]not[ ]render[ ]template[ ]'bogus-nothere[.]tx'/, 'dies with the reason, for data that names no method or route' );
};

done_testing();
