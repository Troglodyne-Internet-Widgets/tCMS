package Trog::Routes::JSON;

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Clone qw{clone};

use Trog::Utils();
use Trog::Routes::HTML();

use Trog::Log::Metrics();

# Same shape series.json demands of child_form.
my $FORM_TX = qr/\A [[:alnum:]_-]+ [.] tx \z/;

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
        secure     => 1,
        callback   => \&process_auth_change_request,
        parameters => [ { name => 'token', in => 'path', required => true, schema => Trog::Utils::uuid_schema() } ],
        noindex    => 1,
        robot_name => '/api/auth_change_request/*',
    },
    '/api/posts_of_form' => {
        method     => 'GET',
        auth       => 1,
        parameters => [
            { name => 'form', in => 'query', schema => { type => 'string', pattern => "$FORM_TX" } },
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
    state $headers  = { ETag => 'manifest-' . _version() };
    state %manifest = (
        "icons" => [ map { +{ "src" => Trog::Themes::url_path( Trog::Themes::themed("img/icon/favicon-$_.png") ), "type" => "image/png", "sizes" => "${_}x$_" } } qw{32 48 167 180 192 512} ],
    );
    return _render( 200, $headers, %manifest );
}

=head2 process_auth_change_request

Implements GET /api/auth_change_request/{token}, which reset emails linked to
before /auth_change_request/{token} took over.  It changes nothing, and sends the
browser to the page where the user chooses the new password.

=cut

sub process_auth_change_request ($query) {
    return $query->{tpsgi}->see_also("/auth_change_request/$query->{input}{token}");
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
    my @posts = Trog::Routes::HTML::post_helper( { form => $query->{input}{form}, limit => 0 }, [], [ Trog::Routes::HTML::viewer_acls($query) ] );

    return _render(
        200, undef,
        posts => [ map { { id => $_->{id}, title => $_->{title} } } @posts ],
    );
}

sub requests_per ($query) {
    my $in   = $query->{input};
    my $code = Trog::Utils::coerce_array( $in->{code} );
    return _render(
        200, undef,
        %{ Trog::Log::Metrics::requests_per( $in->{period}, $in->{num_periods}, $in->{before}, @$code ) }
    );
}

1;
