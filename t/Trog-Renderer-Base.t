#!/usr/bin/env perl
use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Test::More;
use Test::Fatal qw{exception};

use FindBin::libs;

require_ok('Trog::Renderer::Base') or BAIL_OUT("Can't find SUT");

subtest 'render' => sub {
    my %options = ( template => 'manual.tx', contenttype => 'text/html', component => 1 );

    like(
        exception { Trog::Renderer::Base::render( %options, data => {} ) },
        qr/disallowed[ ]key[ ]'content'/,
        'a variable that the template reads and data lacks is fatal, and named'
    );
    my $out;
    is( exception { $out = Trog::Renderer::Base::render( %options, data => { content => undef } ) }, undef, 'but one that data has as undef is not' );
    like( $out, qr{<div[ ]id="backoffice">\s*</div>}, 'and renders as nothing' );

    my %data = ( content => 'x' );
    Trog::Renderer::Base::render( %options, data => \%data );
    $data{later} = 1;
    is( $data{later}, 1, "and the caller's data is not left locked" );
};

done_testing();
