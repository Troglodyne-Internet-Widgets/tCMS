package Trog::Routes::JSON;

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Clone qw{clone};

use Trog::Utils();
use Trog::Auth();
use Trog::Routes::HTML();

use Trog::Log::Metrics();

# The parameters of a route are OpenAPI 3 parameter objects, which
# TCMS::build_routes puts in the operation that tPSGI validates a request by.
our %routes = (
    '/api/catalog' => {
        method   => 'GET',
        callback => \&catalog,
    },
    '/api/webmanifest' => {
        method   => 'GET',
        callback => \&webmanifest,
    },
    '/api/version' => {
        method   => 'GET',
        callback => \&version,
    },
    '/api/auth_change_request/{token}' => {
        method     => 'GET',
        callback   => \&process_auth_change_request,
        parameters => [
            {
                name     => 'token',
                in       => 'path',
                required => true,

                # What Trog::Utils::uuid() makes, ended by \z because perl's $ allows a final newline.
                schema => { type => 'string', pattern => '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z' },
            },
        ],
        noindex    => 1,
        robot_name => '/api/auth_change_request/*',
    },
    '/api/posts_of_form' => {
        method     => 'GET',
        auth       => 1,
        parameters => [

            # Same shape series.json demands of child_form.
            { name => 'form', in => 'query', schema => { type => 'string', pattern => '^[A-Za-z0-9_-]+\.tx\z' } },
        ],
        callback => \&posts_of_form,
        noindex  => 1,
    },
    '/api/requests_per' => {
        method     => 'GET',
        auth       => 1,
        parameters => [
            { name => 'period', in => 'query', schema => { type => 'string', enum => [qw{second minute hour day week month year}] } },
            map { { name => $_, in => 'query', schema => { type => 'number' } } } qw{num_periods before code},
        ],
        callback => \&requests_per,
    },
);

# Clone / redact for catalog
my $cloned = clone( \%routes );
foreach my $r ( keys(%$cloned) ) {
    delete $cloned->{$r}{callback};
}

# Note to authors, don't forget to update this
my sub _version () {
    return '1.0';
}

# Special case of a non data-structure JSON return
sub version {
    state $ret = [ 200, [ 'Content-type' => "application/json", ETag => 'version-' . _version() ], [ _version() ] ];
    return $ret;
}

my sub _render ( $code, $headers, %data ) {
    return Trog::Renderer->render(
        code        => $code,
        data        => \%data,
        template    => 'bogus.tx',
        contenttype => 'application/json',
        headers     => $headers,

        # TODO it may be appropriate to cache some of these methods.
        nocache => 1,
    );
}

sub catalog {
    return _render( 200, { ETag => 'catalog-' . _version() }, %$cloned );
}

sub webmanifest {
    state $headers = { ETag => 'manifest-' . _version() };
    my $theme_dir = Trog::Themes::get_dir();
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
    return $query->{tpsgi}->forbidden($query) unless $msg;
    return _render(
        200, undef,
        message => $msg,
        result  => 'success',
    );
}

=head2 posts_of_form

Implements GET /api/posts_of_form.  Requires a login.

The id and title of every post of the named type which the caller is allowed to
see.  This is what fills a relation field's dropdown in the post editor -- see
www/scripts/post_relations.js and the x-tcms-relations tables in the post type
sidecars.

Only id and title: the caller is populating a picker, and a post's body is
nobody's business here.

=cut

sub posts_of_form ($query) {
    my @posts = Trog::Routes::HTML::post_helper( { form => $query->{form}, limit => 0 }, [], [ Trog::Routes::HTML::viewer_acls($query) ] );

    return _render(
        200, undef,
        posts => [ map { { id => $_->{id}, title => $_->{title} } } @posts ],
    );
}

sub requests_per ($query) {
    my $code = Trog::Utils::coerce_array( $query->{code} );
    return _render(
        200, undef,
        %{ Trog::Log::Metrics::requests_per( $query->{period}, $query->{num_periods}, $query->{before}, @$code ) }
    );
}

1;
