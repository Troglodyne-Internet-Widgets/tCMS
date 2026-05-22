package TCMS;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use Clone        qw{clone};
use Date::Format qw{strftime};

use Sys::Hostname();
use HTTP::Body   ();
use URL::Encode  ();
use Text::Xslate ();
use DateTime::Format::HTTP();
use CGI::Cookie ();
use File::Basename();
use Time::HiRes      qw{gettimeofday tv_interval};
use List::Util;
use URI();
use Ref::Util qw{is_coderef is_hashref is_arrayref};

#Grab our custom routes
use FindBin;
use lib "$FindBin::Bin/../lib";
use FindBin::libs;

use Trog::Routes::HTML;
use Trog::Routes::JSON;

use Trog::Log qw{:all};
use Trog::Log::DBI;

use Trog::Auth;
use Trog::Config;
use Trog::Data;
use Trog::Themes;

# Troglodyne philosophy - simple as possible

my $cur_query = {};

# Build routes
sub build_routes {
    my $conf   = Trog::Config::get();
    my $data   = Trog::Data->new($conf);
    my %routes = %{ _routes($data) };

    # Transform 'method' / 'callback' to new scheme
    my %routes_adj;
    foreach my $k (keys(%routes)) {
        my $v = $routes{$k};

        # Some routes are just pointers to other routes.
        # In this case they might have already been transformed and need to be skipped.
        if (exists $v->{callbacks}) {
            $routes_adj{$k} = $v;
            next;
        }

        my %cb;
        my $method   = $v->{method};
        my $callback = delete $v->{callback};

        #XXX For now we will discard the tPSGI object.  We might want it later.
        my $cb_wrap = sub {
            my ( $tpsgi, $query ) = @_;

            # Let's open up our default route if needed before we bother thinking any harder
            return $routes{default}{callback}->($query) unless -f "config/setup";

            # Set the urchin parameters if necessary.
            %$Trog::Log::DBI::urchin = map { $_ => delete $query->{$_} } qw{utm_source utm_medium utm_campaign utm_term utm_content};

            # Set the IP of the request so we can fail2ban
            $Trog::Log::ip = $query->{req_address};

            # Set the referer & ua to go into DB logs, but not logs in general.
            # The referer/ua largely has no importance beyond being a proto bug report for log messages.
            $Trog::Log::DBI::referer = $query->{referer};
            $Trog::Log::DBI::ua      = $query->{ua};

            # Figure out if we have a logged in user, so we can serve them user-specific files
            my $cookies = {};
            $cookies = CGI::Cookie->parse( $query->{cookies} ) if $query->{cookies};

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

            # Some routes may just need to do serve()
            $query->{tpsgi} = $tpsgi;

            # Redirecting somewhere naughty not allow
            $query->{to} = URI->new( $query->{to} // '' )->path() || $query->{to} if $query->{to};

            # Now that we have firmed up the actual routing, let's validate.
            return $tpsgi->forbidden($query) if exists $query->{dispatcher}{auth} && !$active_user;

            no strict 'refs';
            $callback->($query);
            use strict;
        };

        #XXX todo support different callbacks per requested content-type
        $cb{'*'} = $cb_wrap if $callback;

        $v->{callbacks} = \%cb;
        $routes_adj{$k} = $v;
    }

    return [%routes_adj];
}

# Override the generic error handler to look spiffy
sub generic_route ( $rname, $code, $title, $query ) {
    $query->{code} = $code;
    $query->{route} //= $rname;
    $query->{title}    = $title;
    $query->{template} = "$rname.tx";
    return Trog::Routes::HTML::index($query);
}

our @routes  = @{ build_routes() };
our %aliases = aliases();

#XXX Return a clone of the routing table ref, because code modifies it later
sub _routes ( $data = {} ) {
    state %routes;
    return clone( \%routes ) if %routes;

    my $conf = Trog::Config::get();
    $data = Trog::Data->new($conf) unless $data;

    # Routes in general are going to override earlier, more default ones.
    # XXX this is probably bad in the case of the specific content-typed routes, they should be mutex
    my %roots = $data->routes();
    my %themed = Trog::Themes::routes();

    %routes                                      = %Trog::Routes::HTML::routes;
    @routes{ keys(%Trog::Routes::JSON::routes) } = values(%Trog::Routes::JSON::routes);
    @routes{ keys(%roots) }                      = values(%roots);
    @routes{ keys(%themed) }                     = values(%themed) if %themed;

    # Add in global routes, here because they *must* know about all other routes
    # Also, nobody should ever override these.
    $routes{'/robots.txt'} = {
        method   => 'GET',
        callback => \&robots,
    };

    # The Various aliases for directory indices
    foreach my $index (qw{ / /index.html /index.htm}) {
        $routes{$index} = $routes{'/index'} unless exists $routes{$index};
    }

    return clone( \%routes );
}

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

    # If there's a 'capture' route, we need to format it correctly.
    state @banned = map { exists $routes->{$_}{robot_name} ? $routes->{$_}{robot_name} : $_ } grep { $routes->{$_}{noindex} } sort keys(%$routes);

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
