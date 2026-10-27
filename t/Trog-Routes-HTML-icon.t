#!/usr/bin/env perl
use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Test::More;
use Test::MockModule qw{strict};

use FindBin::libs;

require_ok('Trog::Routes::HTML') or BAIL_OUT("Can't find SUT");

# A tPSGI that records what it was asked to serve.
my @served;
{

    package Fake::TPSGI;
    sub new                { return bless( {}, shift ) }
    sub serve ( $, @args ) { @served = @args; return 'served' }
}

subtest 'icon' => sub {
    my $themes = Test::MockModule->new('Trog::Themes');
    my $query  = { route => '/favicon.ico', tpsgi => Fake::TPSGI->new(), ranges => [] };

    $themes->redefine( get_dir => sub { '' } );
    is( Trog::Routes::HTML::icon($query), 'served', "the icon is served" );
    is_deeply( [ @served[ 0, 1 ] ], [ '/favicon.ico', 'www/img/icon/favicon.ico' ], "with no theme, from the file of the stock icon" );

    my $original = Trog::Themes->can('themed');
    $themes->redefine( themed => sub ($resource) { $resource eq 'img/icon/favicon.ico' ? "www/themes/spec/$resource" : $original->($resource) } );
    Trog::Routes::HTML::icon($query);
    is( $served[1], 'www/themes/spec/img/icon/favicon.ico', "and from the theme's file where the theme has one" );
};

done_testing();
