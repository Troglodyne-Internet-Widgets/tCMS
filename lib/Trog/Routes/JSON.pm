package Trog::Routes::JSON;

# ABSTRACT: The routes of tCMS that answer with JSON

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

=head2 version()

Implements GET /api/version.  It reads nothing of the query.

    my $response = Trog::Routes::JSON::version();

Returns ArrayRef, a PSGI response with status 200, whose body is the version
of this API as a string, such as C<1.0>.  Each call returns the same response.

=cut

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

=head2 catalog()

Implements GET /api/catalog.  It reads nothing of the query.

    my $response = Trog::Routes::JSON::catalog();

Returns ArrayRef, a PSGI response with status 200, whose body is the JSON of
C<%routes> of this module without the callbacks.

=cut

sub catalog {
    return _render( 200, { ETag => 'catalog-' . _version() }, %$cloned );
}

=head2 webmanifest()

Implements GET /api/webmanifest.  It reads nothing of the query.

    my $response = Trog::Routes::JSON::webmanifest();

Returns ArrayRef, a PSGI response with status 200, whose body is a web app
manifest in JSON.  It lists the icons of the theme in each size.

=cut

sub webmanifest {
    state $headers  = { ETag => 'manifest-' . _version() };
    state %manifest = (
        "icons" => [ map { +{ "src" => Trog::Themes::url_path( Trog::Themes::themed("img/icon/favicon-$_.png") ), "type" => "image/png", "sizes" => "${_}x$_" } } qw{32 48 167 180 192 512} ],
    );
    return _render( 200, $headers, %manifest );
}

=head2 process_auth_change_request($query)

Implements GET /api/auth_change_request/{token}, which reset emails linked to
before /auth_change_request/{token} took over.  It changes nothing, and sends the
browser to the page where the user chooses the new password.

    my $response = Trog::Routes::JSON::process_auth_change_request($query);

=over 4

=item query - HashRef - the request.  It reads C<tpsgi>, the TPSGI object, and
C<< input->{token} >>, the token of the change request.

=back

Returns ArrayRef, a PSGI response that sends the browser to
/auth_change_request/{token}.

=cut

sub process_auth_change_request ($query) {
    return $query->{tpsgi}->see_also("/auth_change_request/$query->{input}{token}");
}

=head2 posts_of_form($query)

Implements GET /api/posts_of_form.  Requires a login.

    my $response = Trog::Routes::JSON::posts_of_form($query);

=over 4

=item query - HashRef - the request.  It reads C<< input->{form} >>, the
template of the type of post, such as C<blog.tx>.  The ACLs of the viewer come
from C<user_acls>, through Trog::Routes::HTML::viewer_acls().

=back

The id and title of every post of the named type which the caller is allowed to
see.  This is what fills a relation field's dropdown in the post editor -- see
www/scripts/post_relations.js and the x-tcms-relations tables in the post type
sidecars.

Only id and title: the caller is populating a picker, and a post's body is
nobody's business here.

Returns ArrayRef, a PSGI response with status 200, whose body is JSON with the
key C<posts>: an array of objects with the keys C<id> and C<title>.

=cut

sub posts_of_form ($query) {
    my @posts = Trog::Routes::HTML::post_helper( { form => $query->{input}{form}, limit => 0 }, [], [ Trog::Routes::HTML::viewer_acls($query) ] );

    return _render(
        200, undef,
        posts => [ map { { id => $_->{id}, title => $_->{title} } } @posts ],
    );
}

=head2 requests_per($query)

Implements GET /api/requests_per.  Requires a login.  It counts the requests
that tCMS answered in each of a number of periods of time.

    my $response = Trog::Routes::JSON::requests_per($query);

=over 4

=item query - HashRef - the request.  It reads these keys of C<input>:
C<period>, the length of each period, such as C<hour>; C<num_periods>, how many
periods to count; C<before>, the epoch time that the last period ends at, which
is now when it is not given; and C<code>, one HTTP status or an ArrayRef of
them, to count only the requests that ended with them.

=back

Returns ArrayRef, a PSGI response with status 200, whose body is the JSON of
the HashRef that Trog::Log::Metrics::requests_per() returns.

Dies when C<period> is not a known period.  The route takes only the known
periods, so a request through the route does not die.

=cut

sub requests_per ($query) {
    my $in   = $query->{input};
    my $code = Trog::Utils::coerce_array( $in->{code} );
    return _render(
        200, undef,
        %{ Trog::Log::Metrics::requests_per( $in->{period}, $in->{num_periods}, $in->{before}, @$code ) }
    );
}

1;
