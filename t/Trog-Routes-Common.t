use strict;
use warnings;

use Test::More;
use Test::Deep;
use FindBin;

use lib "$FindBin::Bin/../lib";

# Stub Trog::Routes::HTML entirely — we only care that Common dispatches to it
# with the right $query fields.  The full HTML rendering stack is tested elsewhere.
BEGIN {
    $INC{'Trog/Routes/HTML.pm'} = 1;
    package Trog::Routes::HTML;
    our $landing_page = 'default.tx';
    # echo back the query hashref so tests can inspect it
    sub index { return $_[0] }
}

require_ok('Trog::Routes::Common') or BAIL_OUT("Can't load Trog::Routes::Common");

# ── _init_query ──────────────────────────────────────────────────────────────

subtest '_init_query with undef query' => sub {
    my $q = Trog::Routes::Common::_init_query( undef, 404, 'Not Found', '404.tx' );
    is( $q->{code},     404,         'code set' );
    is( $q->{title},    'Not Found', 'title set' );
    is( $q->{template}, '404.tx',   'template set' );
    is_deeply( $q->{primary_post}, {}, 'primary_post initialised to empty hash' );
    is( $q->{social_meta}, 0, 'social_meta off by default' );
    is( $q->{path},     '',  'path defaults to empty string when route absent' );
    ok( ref( $q->{start} ) eq 'ARRAY', 'start set to gettimeofday array' );
};

subtest '_init_query with partial query' => sub {
    my $q = Trog::Routes::Common::_init_query(
        { route => '/foo', user => 'alice', start => [100, 0] },
        403, 'Forbidden', '403.tx'
    );
    is( $q->{code},     403,        'code overwritten' );
    is( $q->{title},    'Forbidden','title overwritten' );
    is( $q->{template}, '403.tx',  'template overwritten' );
    is( $q->{user},     'alice',   'existing fields preserved' );
    is( $q->{path},     '/foo',    'path defaults from route' );
    is_deeply( $q->{start}, [100, 0], 'existing start preserved' );
};

subtest '_init_query does not overwrite existing path' => sub {
    my $q = Trog::Routes::Common::_init_query(
        { route => '/r', path => '/p' }, 404, 'Not Found', '404.tx'
    );
    is( $q->{path}, '/p', 'explicit path wins over route' );
};

# ── error handlers ────────────────────────────────────────────────────────────
# Each handler must call HTML::index with the correct code/title/template.

my %cases = (
    not_found   => { code => 404, title => 'Not Found',               template => '404.tx' },
    forbidden   => { code => 403, title => 'Forbidden',               template => '403.tx' },
    bad_request => { code => 400, title => 'Bad Request',             template => '400.tx' },
    too_long    => { code => 419, title => 'URI Too Long',            template => '419.tx' },
    server_error => { code => 500, title => 'Internal Server Error',  template => '500.tx' },
    unavailable  => { code => 503, title => 'Service Unavailable',    template => '503.tx' },
);

for my $handler ( sort keys %cases ) {
    my $expected = $cases{$handler};
    subtest "$handler — undef query" => sub {
        no strict 'refs';
        my $q = Trog::Routes::Common->can($handler)->( undef );
        is( $q->{code},     $expected->{code},     'correct HTTP status' );
        is( $q->{title},    $expected->{title},    'correct title' );
        is( $q->{template}, $expected->{template}, 'correct template' );
        ok( ref( $q->{start} ) eq 'ARRAY', 'start initialised' );
    };

    subtest "$handler — partial query forwarded" => sub {
        no strict 'refs';
        my $q = Trog::Routes::Common->can($handler)->( { user => 'bob', route => '/x' } );
        is( $q->{code},  $expected->{code}, 'code set' );
        is( $q->{user},  'bob',             'existing user preserved' );
        is( $q->{route}, '/x',             'existing route preserved' );
    };
}

done_testing;
