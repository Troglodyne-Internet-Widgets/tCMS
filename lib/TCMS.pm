package TCMS;

# ABSTRACT: A CMS for perl, run by tPSGI, in which a post can be content of any type

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Carp  qw{confess};
use Clone qw{clone};

use CGI::Cookie ();
use List::Util  ();
use Sub::Util   ();
use URI();

#Grab our custom routes
use FindBin::libs;

use Trog::Routes::HTML;
use Trog::Routes::JSON;

use Trog::Log qw{:all};
use Trog::Log::DBI;

use Trog::Auth;
use Trog::Config;

# Loaded here rather than where it is used, so that the vault key comes out of
# the environment once, in the parent, before there is a worker to fork -- see
# Trog::Vault.
use Trog::Vault;    ## no critic (ProhibitUnusedImports) -- loaded for what it does at load time, as above
use Trog::Data;
use Trog::Themes;
use Trog::Bundle;

#XXX Return a clone of the routing table ref, because code modifies it later
my sub _routes ( $data = {} ) {
    state %routes;
    return clone( \%routes ) if %routes;

    my $conf = Trog::Config::get();
    $data = Trog::Data->new($conf) unless $data;

    # Routes in general are going to override earlier, more default ones.
    # XXX this is probably bad in the case of the specific content-typed routes, they should be mutex
    my %roots = $data->routes();

    # OpenAPI has no escape for a brace, so such a path would be a template.
    foreach my $href ( grep { m/[{}]/ } keys(%roots) ) {
        WARN("Not routing $href: a path with a brace in it cannot be a route");
        delete $roots{$href};
    }

    # Setup the /secure/... versions for logged in users, except for already secured routes.
    foreach my $route ( keys(%roots) ) {
        if ( index( $route, '/secure/' ) == 0 ) {
            $roots{$route} = { %{ $roots{$route} }, secure => 1 };
            next;
        }
        $roots{"/secure$route"} = { %{ $roots{$route} }, secure => 1 };
    }

    # It is the responsibility of theme authors to setup /secure routes (other than index),
    # with secure or auth on each.
    my %themed = Trog::Themes::routes();

    %routes                                      = %Trog::Routes::HTML::routes;
    @routes{ keys(%Trog::Routes::JSON::routes) } = values(%Trog::Routes::JSON::routes);
    @routes{ keys(%roots) }                      = values(%roots);
    @routes{ keys(%themed) }                     = values(%themed) if %themed;

    # A page of posts gets the scripts of one, unless its route names its own.
    foreach my $path ( keys(%routes) ) {
        my $callback = $routes{$path}{callback} // '';
        my $name     = ref $callback ? Sub::Util::subname($callback) : $callback;
        next if exists $routes{$path}{scripts} || !List::Util::any { $_ eq $name } @Trog::Routes::HTML::post_page_callbacks;
        $routes{$path} = { %Trog::Routes::HTML::post_page_scripts, %{ $routes{$path} } };
    }

    # Add in global routes, here because they *must* know about all other routes
    # Also, nobody should ever override these.
    $routes{'/robots.txt'} = {
        method   => 'GET',
        callback => \&robots,
    };

    # Special 'am I authenticated' route for nginx
    $routes{'/authenticated'} = {
        method   => 'GET',
        nocache  => 1,
        noindex  => 1,
        callback => sub {
            my ($query) = @_;
            return $query->{tpsgi}->ok($query) if $query->{user};
            return $query->{tpsgi}->forbidden($query);
        },
    };

    # Heartbeat route
    $routes{'/status'} = {
        method   => 'GET',
        nocache  => 1,
        noindex  => 1,
        callback => sub {
            my ($query) = @_;
            return $query->{tpsgi}->ok($query);
        },
    };

    # The Various aliases for directory indices
    foreach my $index (qw{ / /index.html /index.htm}) {
        $routes{$index}          = $routes{'/index'}                       unless exists $routes{$index};
        $routes{"/secure$index"} = { %{ $routes{'/index'} }, secure => 1 } unless exists $routes{"/secure$index"};
    }
    $routes{'/secure'} = $routes{'/secure/'} unless exists $routes{'/secure'};

    return clone( \%routes );
}

# Troglodyne philosophy - simple as possible

=head2 build_routes() = HASH

The OpenAPI 3 document that tPSGI routes by, made from the routing table that
_routes() returns.  Each route becomes the operation of its method, under its
path.  The operation's x-tpsgi-callback is the route's callback, wrapped in what
every tCMS request needs.  C<data> becomes x-tpsgi-data, and C<auth>,
C<secure>, C<nocache>, C<noindex>, C<nomap>, C<robot_name> and C<totp_exempt> become
x-tcms-auth and so on, which the callback finds in C<< $query->{dispatcher} >>.
C<parameters> are OpenAPI parameter objects, and each variable of a template
that they leave out is a required string.  A route with no method is a GET.

If C<general.secure_host> names a host (see secure_host() in
Trog::Routes::HTML), a route with C<secure> or C<auth> answers only on that
host.  The F</secure> copies of the routes of posts and of the index get
C<secure>, and so does the route of a private post, which the data model
marks.  On any other host, a GET or a HEAD of such a route is a redirect to
the same path and query on the secure host, and any other method gets 404, so
that a form body never goes to the public host.  On a host other than the
secure host, tCMS also ignores the login cookie.  On the secure host, a route
with a F</secure> copy is a reader's page, and a GET or a HEAD of it is a
redirect to C<general.hostname>, if that is set and is another host.  Every page
gets C<secure_base>, C<https://> and the secure host, or an empty string, for
its links to the routes that need a login.

The C<default> route is not a path.  The wrapper calls it when there is no
F<config/setup>.

=cut

my @tcms_keys = qw{auth secure nocache noindex nomap robot_name totp_exempt scripts authenticated_scripts};

sub build_routes {
    my $conf   = Trog::Config::get();
    my $data   = Trog::Data->new($conf);
    my %routes = %{ _routes($data) };

    my $default_route = $routes{default}{callback};

    my %paths;
    foreach my $k ( sort grep { $_ ne 'default' } keys(%routes) ) {
        my $v = $routes{$k};

        # The bundles that this route's page can link, for a reader and for a
        # reader who is logged in.
        my @scripts = Trog::Bundle::page_scripts( @{ $v->{scripts} // [] } );
        Trog::Bundle::declare( \@scripts, [ Trog::Bundle::page_scripts( @scripts, @{ $v->{authenticated_scripts} // [] } ) ] );

        my $method = lc( $v->{method} // 'GET' );

        # FlatFile and the tag index name the callback rather than hold it.
        my $callback = $v->{callback};
        next                      unless $callback;
        $callback = \&{$callback} unless ref $callback;

        my $secure_only = $v->{secure} || $v->{auth};

        # A reader's page, which the secure host sends to the public host.
        my $readers_page = !$secure_only && exists $routes{"/secure$k"};

        #XXX For now we will discard the tPSGI object.  We might want it later.
        my $cb_wrap = sub {    ## no critic (ProhibitSingleUseLexicalSubs) -- 78 lines, which would overcomplicate build_routes()
            my ( $tpsgi, $query ) = @_;

            confess "Cannot determine directory for logs!" unless $tpsgi->{log_dir};

            # Make sure the tCMS logs live in the same dir as the tpsgi logs.
            log_init( "$tpsgi->{log_dir}/tpsgi.log", $tpsgi->{verbose} ? 'debug' : 'info', $tpsgi->{loggers} );

            # Let's open up our default route if needed before we bother thinking any harder
            return $default_route->($query) unless -f "config/setup";    ## no critic (ProhibitFiletest_f) -- a flag file, only ever touched

            # Set the urchin parameters if necessary.
            %$Trog::Log::DBI::urchin = map { $_ => delete $query->{$_} } qw{utm_source utm_medium utm_campaign utm_term utm_content};

            # Set the IP of the request so we can fail2ban
            $Trog::Log::ip = $query->{ip};

            # Set the referer & ua to go into DB logs, but not logs in general.
            # The referer/ua largely has no importance beyond being a proto bug report for log messages.
            $Trog::Log::DBI::referer = $query->{referer};
            $Trog::Log::DBI::ua      = $query->{ua};

            # On the public host of a site that has a secure host, nobody is
            # logged in, and a page that needs a login is on the secure host.
            my $secure_host = Trog::Routes::HTML::secure_host();
            my $public      = on_public_host( $query, $secure_host );
            return redirect_to_host( $tpsgi, $query, $secure_host ) if $public && $secure_only;

            my $public_host = $secure_host && !$public && $readers_page ? Trog::Routes::HTML::public_host() : '';
            return redirect_to_host( $tpsgi, $query, $public_host ) if $public_host && $public_host ne $secure_host;

            # Figure out if we have a logged in user, so we can serve them user-specific files
            my $cookies = {};
            $cookies = CGI::Cookie->parse( $query->{cookies} ) if $query->{cookies} && !$public;

            my $active_user = '';
            $Trog::Log::user = 'nobody';
            if ( exists $cookies->{tcmslogin} ) {
                $active_user     = Trog::Auth::session2user( $cookies->{tcmslogin}->value );
                $Trog::Log::user = $active_user if $active_user;
            }

            # Make sure TPSGI can log the user
            $tpsgi->{user} = $active_user;

            # Enrich the query with tcms specific foo
            $query->{user_acls} = [];
            $query->{user_acls} = Trog::Auth::acls4user($active_user) // [] if $active_user;

            # Grab the list of ACLs we want to add to a post, if any.
            $query->{acls} = [ $query->{acls} ] if ( $query->{acls} && ref $query->{acls} ne 'ARRAY' );

            # Filter out passed ACLs which are naughty
            my $is_admin = grep { $_ eq 'admin' } @{ $query->{user_acls} };
            @{ $query->{acls} } = grep { $_ ne 'admin' } @{ $query->{acls} } unless $is_admin;

            $query->{user}         = $active_user;
            $query->{body}         = '';
            $query->{social_meta}  = 1;
            $query->{primary_post} = {};
            $query->{secure_base}  = $secure_host ? "https://$secure_host" : '';

            # Every host shares the saved pages, so a page of the secure host alone is never saved.
            $query->{nocache} = $v->{nocache} || ( $secure_host && $secure_only );

            # Some routes may just need to do serve()
            $query->{tpsgi} = $tpsgi;

            # Redirecting somewhere naughty not allow
            $query->{to} = URI->new( $query->{to} // '' )->path() || $query->{to} if $query->{to};

            # Now that we have firmed up the actual routing, let's validate.
            return $tpsgi->forbidden($query) if exists $query->{dispatcher}{'x-tcms-auth'} && !$active_user;

            if ( needs_enrolment( $active_user, $query->{dispatcher} ) ) {
                INFO("$active_user has no TOTP enrolment; sending them to /totp");
                return $tpsgi->see_also('/totp');
            }

            return $callback->($query);
        };

        my @parameters = @{ $v->{parameters} // [] };
        foreach my $variable ( $k =~ m/\{([^{}]+)\}/g ) {
            next if List::Util::any { $_->{in} eq 'path' && $_->{name} eq $variable } @parameters;
            push( @parameters, { name => $variable, in => 'path', required => true, schema => { type => 'string' } } );
        }

        $paths{$k}{$method} = {
            'x-tpsgi-callback' => $cb_wrap,
            ( $v->{data} ? ( 'x-tpsgi-data' => $v->{data} ) : () ),
            ( map { ( "x-tcms-$_" => $v->{$_} ) } grep { exists $v->{$_} } @tcms_keys ),
            ( @parameters ? ( parameters => \@parameters ) : () ),
            responses => { default => { description => 'The page, or an error page' } },
        };
    }

    return (
        openapi => '3.0.3',
        info    => { title => 'tCMS', version => '1' },
        paths   => \%paths,
    );
}

=head2 on_public_host($query, $secure_host) = BOOL

Whether the request came to a host other than $secure_host, which secure_host()
in Trog::Routes::HTML returned.  The port of the host is ignored.  It is false
when $secure_host is empty, because then there is one host for everything.

=cut

sub on_public_host ( $query, $secure_host ) {
    return 0 unless $secure_host;
    return ( lc( $query->{domain} // '' ) =~ s/:\d+\z//r ) ne $secure_host;
}

=head2 redirect_to_host($tpsgi, $query, $host) = PSGI response

The answer to a request that came to the wrong one of the two hosts.  A GET or
a HEAD gets a redirect to the same path and query on $host, over https.  Any
other method gets 404, so that a browser never sends a form body to the host
that should not see it.  The redirect is not permanent, because the settings
can change.

=cut

sub redirect_to_host ( $tpsgi, $query, $host ) {
    return $tpsgi->notfound($query) unless List::Util::any { $_ eq ( $query->{method} // '' ) } qw{GET HEAD};

    my $to = URI->new("https://$host");
    $to->path( $query->{route} );
    $to->query( $query->{query_string} ) if ( $query->{query_string} // '' ) ne '';
    return $tpsgi->redirect("$to");
}

=head2 needs_enrolment($user, $dispatcher) = BOOL

Whether this request should be turned around and sent to /totp.

Two factors or nothing.  A login is what gets you to the enrollment page -- the QR
is the shared secret, so it cannot be handed to whoever asks for it -- which
leaves a window where somebody is logged in and has no second factor yet.  This
is what makes that window one page wide: every route a login can reach, and no
route a logged out visitor can, is refused until they have enrolled.

The enrollment page and the QR on it say so themselves, with totp_exempt, because
the exemption belongs next to the route rather than in a list over here that the
routing table knows nothing about.  $dispatcher is the operation that
build_routes() made, so it holds them as x-tcms-auth and x-tcms-totp_exempt.

=cut

sub needs_enrolment ( $user, $dispatcher ) {
    return 0 unless $user;
    return 0 if !$dispatcher || !$dispatcher->{'x-tcms-auth'} || $dispatcher->{'x-tcms-totp_exempt'};
    return Trog::Auth::has_totp($user) ? 0 : 1;
}

# Override the generic error handler to look spiffy
sub generic_route ( $rname, $code, $title, $query ) {
    $query->{code} = $code;
    $query->{route} //= $rname;
    $query->{title}    = $title;
    $query->{template} = "$rname.tx";
    return Trog::Routes::HTML::index($query);
}

our %openapi = build_routes();
our %aliases = aliases();

sub aliases {
    my $conf = Trog::Config::get();
    my $data = Trog::Data->new($conf);
    return $data->aliases();
}

=head2 robots

Return an appropriate robots.txt

This is a "special" route as it needs to know about all the routes in order to disallow noindex=1 routes.

=cut

# TODO anytime that the routing table changes, we need to invalidate the cache.
sub robots ($query) {
    state $etag = "robots-" . time();
    my $routes = _routes();

    # A template's variables can be anything, which robots.txt spells as *.
    state @banned = map {
        my $robot_name = $routes->{$_}{robot_name} // $_;
        $robot_name =~ s/\{[^{}]*\}/*/g;
        $robot_name
    } grep { $routes->{$_}{noindex} } sort keys(%$routes);

    return Trog::Renderer->render(
        contenttype => 'text/plain',
        template    => 'robots.tx',
        data        => {
            etag   => $etag,
            banned => \@banned,
            %$query,
        },
        code => 200,
    );
}

1;
