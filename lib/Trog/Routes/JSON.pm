package Trog::Routes::JSON;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use Clone qw{clone};
use JSON::MaybeXS();

use Trog::Config();
use Trog::Auth();
use Trog::Routes::HTML();

my $conf = Trog::Config::get();

# TODO de-duplicate this, it's shared in html
my $theme_dir = '';
$theme_dir = "themes/" . $conf->param('general.theme') if $conf->param('general.theme') && -d "www/themes/" . $conf->param('general.theme');

our %routes = (
    '/api/catalog' => {
        method     => 'GET',
        callback   => \&catalog,
        parameters => [],
    },
    '/api/webmanifest' => {
        method     => 'GET',
        callback   => \&webmanifest,
        parameters => [],
    },
    '/api/version' => {
        method     => 'GET',
        callback   => \&version,
        parameters => [],
    },
    '/api/auth_change_request' => {
        method     => 'POST',
        callback   => \&process_auth_change_request,
        parameters => ['token'],
        noindex    => 1,
    },
);

# Clone / redact for catalog
my $cloned = clone( \%routes );
foreach my $r ( keys(%$cloned) ) {
    delete $cloned->{$r}{callback};
}

my $enc = JSON::MaybeXS->new( utf8 => 1 );

# Note to authors, don't forget to update this
sub _version () {
    return '1.0';
}

sub version ($query) {
    state $ret = [ 200, [ 'Content-type' => "application/json", ETag => 'version-' . _version() ], [ _version() ] ];
    return $ret;
}

sub catalog ($query) {
    state $ret = [ 200, [ 'Content-type' => "application/json", ETag => 'catalog-' . _version() ], [ $enc->encode($cloned) ] ];
    return $ret;
}

sub webmanifest ($query) {
    state $headers  = [ 'Content-type' => "application/json", ETag => 'manifest-' . _version() ];
    state %manifest = (
        "icons" => [
            { "src" => "$theme_dir/img/icon/favicon-192.png", "type" => "image/png", "sizes" => "192x192" },
            { "src" => "$theme_dir/img/icon/favicon-512.png", "type" => "image/png", "sizes" => "512x512" },
        ],
    );
    state $content = $enc->encode( \%manifest );

    return [ 200, $headers, [$content] ];
}

sub process_auth_change_request($query) {
    my $token = $query->{token};
    return Trog::Routes::HTML::forbidden($query) if !Trog::Auth::change_request_exists($token);

    my $msg = Trog::Auth::process_change_request($token);
    return Trog::Routes::HTML::forbidden($query) unless $msg;
    return Trog::Renderer->render(
        code => 200,
        message => $msg,
        result  => 'success',
    );
}

1;
