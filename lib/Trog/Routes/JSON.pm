package Trog::Routes::JSON;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use Clone qw{clone};
use JSON::MaybeXS();

use Scalar::Util();

use Trog::Utils();
use Trog::Config();
use Trog::Auth();
use Trog::Routes::HTML();

use Trog::Log::Metrics();

my $conf = Trog::Config::get();

# TODO de-duplicate this, it's shared in html
my $theme_dir = '';
$theme_dir = "themes/" . $conf->param('general.theme') if $conf->param('general.theme') && -d "www/themes/" . $conf->param('general.theme');

our %routes = (
    '/api/catalog' => {
        method     => 'GET',
        callback   => \&catalog,
        parameters => {},
    },
    '/api/webmanifest' => {
        method     => 'GET',
        callback   => \&webmanifest,
        parameters => {},
    },
    '/api/version' => {
        method     => 'GET',
        callback   => \&version,
        parameters => {},
    },
    '/api/auth_change_request/(.*)' => {
        method     => 'GET',
        callback   => \&process_auth_change_request,
        captures   => ['token'],
        parameters => {
            token => sub { my $tok = shift; $tok =~ m/[a-f|0-9|-]+/; },
        },
        noindex    => 1,
        robot_name => '/api/auth_change_request/*',
    },
    '/api/requests_per' => {
        method => 'GET',
        auth   => 1,
        parameters => {
            period      => sub { grep { my $valid=$_; List::Util::any { $_ eq $valid } @_ } qw{second minute hour day week month year} },
            num_periods => \&Scalar::Util::looks_like_number,
            before      => \&Scalar::Util::looks_like_number,
            code        => \&Scalar::Util::looks_like_number,
        },
        callback => \&requests_per,
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

# Special case of a non data-structure JSON return
sub version ($query) {
    state $ret = [ 200, [ 'Content-type' => "application/json", ETag => 'version-' . _version() ], [ _version() ] ];
    return $ret;
}

sub catalog ($query) {
    return _render( 200, { ETag => 'catalog-' . _version() }, %$cloned );
}

sub webmanifest ($query) {
    state $headers = { ETag => 'manifest-' . _version() };
    state %manifest = (
        "icons" => [
            { "src" => "$theme_dir/img/icon/favicon-32.png",  "type" => "image/png", "sizes" => "32x32" },
            { "src" => "$theme_dir/img/icon/favicon-48.png",  "type" => "image/png", "sizes" => "48x48" },
            { "src" => "$theme_dir/img/icon/favicon-167.png", "type" => "image/png", "sizes" => "167x167" },
            { "src" => "$theme_dir/img/icon/favicon-180.png", "type" => "image/png", "sizes" => "180x180" },
            { "src" => "$theme_dir/img/icon/favicon-192.png", "type" => "image/png", "sizes" => "192x192" },
            { "src" => "$theme_dir/img/icon/favicon-512.png", "type" => "image/png", "sizes" => "512x512" },
        ],
    );
    return _render( 200, $headers, %manifest );
}

sub process_auth_change_request ($query) {
    my $token = $query->{token};

    my $msg = Trog::Auth::process_change_request($token);
    return Trog::Routes::HTML::forbidden($query) unless $msg;
    return _render(
        200, undef,
        message => $msg,
        result  => 'success',
    );
}

sub requests_per($query) {
    my $code = Trog::Utils::coerce_array($query->{code});
    return _render(
        200, undef, 
        %{Trog::Log::Metrics::requests_per($query->{period}, $query->{num_periods}, $query->{before}, @$code )}
    );
}

sub _render ( $code, $headers, %data ) {
    return Trog::Renderer->render(
        code        => 200,
        data        => \%data,
        template    => 'bogus.tx',
        contenttype => 'application/json',
        headers     => $headers,
    );
}

1;
