#!/usr/bin/env perl
use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Test::More;

use FindBin::libs;

require_ok('Trog::Routes::HTML') or BAIL_OUT("Can't find SUT");

my $base = 'https://media.test.test';

my sub post (%over) {
    return {
        form        => 'file.tx',
        href        => '/assets/uuid.movie.mp4',
        preview     => '/assets/uuid.still.jpg',
        wallpaper   => '/assets/uuid.wall.jpg',
        video_href  => '/assets/uuid.video.mp4',
        audio_href  => '/assets/uuid.audio.ogg',
        attachments => [ '/assets/uuid.a.pdf', '/assets/private/uuid.b.pdf' ],
        local_href  => '/posts/uuid',
        %over,
    };
}

subtest 'media_urls' => sub {
    my $post = post();
    Trog::Routes::HTML::media_urls( $post, '' );
    is_deeply( $post, post(), 'with no base, nothing changes' );

    $post = post();
    Trog::Routes::HTML::media_urls( $post, $base );
    foreach my $field (qw{href preview wallpaper video_href audio_href}) {
        is( $post->{$field}, $base . post()->{$field}, "$field is on the media host" );
    }
    is( $post->{attachments}[0], "$base/assets/uuid.a.pdf",    'a public attachment is on the media host' );
    is( $post->{attachments}[1], '/assets/private/uuid.b.pdf', 'a private attachment stays on this host' );
    is( $post->{local_href},     '/posts/uuid',                'a field that is not an asset does not change' );

    $post = post( href => '/assets/private/uuid.movie.mp4', preview => '/assetsfoo/x.jpg', wallpaper => '/img/sys/testpattern.jpg', video_href => 'https://elsewhere.test.test/assets/x.mp4' );
    Trog::Routes::HTML::media_urls( $post, $base );
    is( $post->{href},       '/assets/private/uuid.movie.mp4',           'a private asset stays on this host' );
    is( $post->{preview},    '/assetsfoo/x.jpg',                         'a path that only starts like /assets does not change' );
    is( $post->{wallpaper},  '/img/sys/testpattern.jpg',                 'a path outside /assets does not change' );
    is( $post->{video_href}, 'https://elsewhere.test.test/assets/x.mp4', 'an absolute URL does not change' );

    $post = post( related => post(), many => [ post() ] );
    $post->{itself} = $post;
    Trog::Routes::HTML::media_urls( $post, $base );
    is( $post->{href},             "$base/assets/uuid.movie.mp4", 'the post itself moves once, though it holds itself' );
    is( $post->{related}{href},    "$base/assets/uuid.movie.mp4", 'a related post moves too' );
    is( $post->{many}[0]{preview}, "$base/assets/uuid.still.jpg", 'and so does one reached through a list' );
};

done_testing();
