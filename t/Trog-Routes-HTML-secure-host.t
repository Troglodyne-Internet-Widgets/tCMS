#!/usr/bin/env perl
use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Test::More;
use Test::MockModule qw{strict};

use FindBin::libs;

require_ok('Trog::Routes::HTML') or BAIL_OUT("Can't find SUT");

my @warnings;
my $logmock = Test::MockModule->new('Trog::Routes::HTML');
$logmock->redefine( WARN => sub { push( @warnings, shift ) } );

{

    package FakeConfig;
    sub new   ( $class, %values ) { return bless {%values}, $class }
    sub param ( $self, $key )     { return $self->{$key} }
}

subtest 'secure_host' => sub {
    my $confmock = Test::MockModule->new('Trog::Config');
    my %cases    = (
        ''                              => '',
        'secure.test.test'              => 'secure.test.test',
        'Secure.Test.Test'              => 'secure.test.test',
        'https://secure.test.test'      => '',
        'secure.test.test:8443'         => '',
        'secure.test.test/login'        => '',
        'someone@secure.test.test'      => '',
        'secure.test.test?a'            => '',
        'secure.test.test#a'            => '',
        'secure.test.test secure.other' => '',
    );
    foreach my $setting ( sort keys %cases ) {
        @warnings = ();
        $confmock->redefine( get => sub { return FakeConfig->new( 'general.secure_host' => $setting ) } );
        is( Trog::Routes::HTML::secure_host(), $cases{$setting},                                     "'$setting' gives '$cases{$setting}'" );
        is( scalar(@warnings),                 ( $setting ne '' && $cases{$setting} eq '' ) ? 1 : 0, "and warns only if it ignores a setting" );
    }

    $confmock->redefine( get => sub { return FakeConfig->new() } );
    is( Trog::Routes::HTML::secure_host(), '', 'a configuration without the setting gives nothing' );

    # Config::Simple splits a value at each comma, and a host name has none.
    @warnings = ();
    $confmock->redefine( get => sub { return FakeConfig->new( 'general.secure_host' => [ 'secure.test.test', 'b' ] ) } );
    is( Trog::Routes::HTML::secure_host(), '', 'a value with a comma is not a host name' );
    is( scalar(@warnings),                 1,  'and warns' );
};

subtest 'public_host' => sub {
    my $confmock = Test::MockModule->new('Trog::Config');

    @warnings = ();
    $confmock->redefine( get => sub { return FakeConfig->new( 'general.hostname' => 'Routes.Test.Test' ) } );
    is( Trog::Routes::HTML::public_host(), 'routes.test.test', 'general.hostname, in lower case' );
    is( scalar(@warnings),                 0,                  'with no warning' );

    $confmock->redefine( get => sub { return FakeConfig->new( 'general.hostname' => 'https://routes.test.test' ) } );
    is( Trog::Routes::HTML::public_host(), '', 'is checked as secure_host() checks its setting' );
    like( $warnings[0], qr/general[.]hostname/, 'and the warning names the setting' );
};

done_testing();
