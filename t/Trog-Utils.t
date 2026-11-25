#!/usr/bin/env perl

# The odds and ends that more than one part of tCMS needs.

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use FindBin::libs;

use Test2::V1 qw{done_testing is ok subtest};
use Test2::Plugin::NoWarnings;

ok( require Trog::Utils, 'Trog::Utils loads' );

subtest 'path_href' => sub {
    is( Trog::Utils::path_href('/assets/a.mp4'),       '/assets/a.mp4',           'a name with nothing to encode is as it was' );
    is( Trog::Utils::path_href('/assets/u.a b-1.m4v'), '/assets/u.a%20b-1.m4v',   'a space is percent-encoded' );
    is( Trog::Utils::path_href('docs/what? #1.txt'),   'docs/what%3F%20%231.txt', 'a question mark and a hash are encoded, and a relative path stays relative' );
    is( Trog::Utils::path_href('/assets/a%20b.mp4'),   '/assets/a%2520b.mp4',     'a name that holds a literal %20 is that name, so its % is encoded' );
    is( Trog::Utils::path_href('dir/sub/'),            'dir/sub/',                'each slash is kept, the last one too' );
    is( Trog::Utils::path_href(''),                    '',                        'an empty path stays empty' );
};

done_testing();
