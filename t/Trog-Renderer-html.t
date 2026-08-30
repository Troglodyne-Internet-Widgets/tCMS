use strict;
use warnings;

use Test::More;
use FindBin;

use lib "$FindBin::Bin/../lib";
use lib '/tmp/perlstub';

use Digest::SHA qw(sha384);
use MIME::Base64 qw(encode_base64);

require_ok('Trog::Renderer::html') or BAIL_OUT("Can't load Trog::Renderer::html");

subtest 'sri_hash — existing file' => sub {
    my $path   = '/styles/screen.css';
    my $result = Trog::Renderer::html::sri_hash($path);

    like( $result, qr/^sha384-[A-Za-z0-9+\/]+=*$/, 'returns sha384- prefixed base64' );

    open( my $fh, '<:raw', "www$path" ) or BAIL_OUT("Cannot open www$path: $!");
    local $/;
    my $content  = <$fh>;
    my $expected = 'sha384-' . encode_base64( sha384($content), '' );
    is( $result, $expected, 'hash value matches independent SHA-384 computation' );
};

subtest 'sri_hash — caching' => sub {
    my $path   = '/styles/screen.css';
    my $first  = Trog::Renderer::html::sri_hash($path);
    my $second = Trog::Renderer::html::sri_hash($path);
    is( $second, $first, 'repeated call returns cached result' );
};

subtest 'sri_hash — non-existent file' => sub {
    my $result = Trog::Renderer::html::sri_hash('/styles/no-such-file.css');
    is( $result, '', 'returns empty string for missing file' );
};

subtest 'sri_hash — non-absolute path' => sub {
    my $result = Trog::Renderer::html::sri_hash('styles/screen.css');
    is( $result, '', 'returns empty string for non-absolute path' );
};

subtest 'sri_hash — undef input' => sub {
    my $result = Trog::Renderer::html::sri_hash(undef);
    is( $result, '', 'returns empty string for undef input' );
};

done_testing();
