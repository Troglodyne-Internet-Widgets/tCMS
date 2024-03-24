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
use IO::Compress::Gzip();
use Time::HiRes      qw{gettimeofday tv_interval};
use HTTP::Parser::XS qw{HEADERS_AS_HASHREF};
use List::Util;
use URI();
use Ref::Util qw{is_coderef is_hashref is_arrayref};

#Grab our custom routes
use FindBin::libs;
use Trog::Routes::HTML;
use Trog::Routes::JSON;

use Trog::Log qw{:all};
use Trog::Log::DBI;

use Trog::Auth;
use Trog::Utils;
use Trog::Config;
use Trog::Data;
use Trog::Vars;
use Trog::FileHandler;

# Troglodyne philosophy - simple as possible

# Wrap app to return *our* error handler instead of Plack::Util::run_app's
my $cur_query = {};

sub app {
    return eval { _app(@_) } || do {
        my $env = shift;
        $env->{'psgi.errors'}->print($@);

        # Redact the stack trace past line 1, it usually has things which should not be shown
        $cur_query->{message} = $@;
        $cur_query->{message} =~ s/\n.*//g if $cur_query->{message};

        return _error($cur_query);
    };
}

=head2 app()

Dispatches requests based on %routes built above.

The dispatcher here does *not* do anything with the authn/authz data.  It sets those in the 'user' and 'acls' parameters of the query object passed to routes.

If a path passed is not a defined route (or regex route), but exists as a file under www/, it will be served up immediately.

=cut

sub _app {

    # Make sure all writes are with the proper permissions, none need know of our love
    umask 0077;

    INFO("TCMS starting up on PID $MASTER_PID, Worker PID $$");
    # Start the server timing clock
    my $start = [gettimeofday];

    # Build the routing table
    state( $conf, $data, %aliases );

    $conf //= Trog::Config::get();
    $data //= Trog::Data->new($conf);
    my %routes = %{ _routes($data) };
    %aliases = $data->aliases() unless %aliases;

    # XXX this is built progressively across the forks, leading to inconsistent behavior.
    # This should eventually be pre-filled from DB.
    my %etags;

    # Setup logging
    log_init();
    my $requestid = Trog::Utils::uuid();
    Trog::Log::uuid($requestid);

    # Actually start processing the request
    my $env = shift;

    # Discard the path used in the log, it's too long and enough 4xx error code = ban
    return _toolong( { method => $env->{REQUEST_METHOD}, fullpath => '...' } ) if length( $env->{REQUEST_URI} ) > 2048;

    # Various stuff important for logging requests
    state $domain = $conf->param('general.hostname') || $env->{HTTP_X_FORWARDED_HOST} || $env->{HTTP_HOST} || eval { Sys::Hostname::hostname() };
    my $path   = $env->{PATH_INFO};
    my $port   = $env->{HTTP_X_FORWARDED_PORT} // $env->{HTTP_PORT};
    my $pport  = defined $port ? ":$port" : "";
    my $scheme = $env->{'psgi.url_scheme'} // 'http';
    my $method = $env->{REQUEST_METHOD};

    # It's important that we log what the user ACTUALLY requested rather than the rewritten path later on.
    my $fullpath = "$scheme://$domain$pport$path";

    # sigdie can now "do the right thing"
    $cur_query = { route => $path, fullpath => $path, method => $method };

    # Set the IP of the request so we can fail2ban
    $Trog::Log::ip = $env->{HTTP_X_FORWARDED_FOR} || $env->{REMOTE_ADDR};

    # Set the referer & ua to go into DB logs, but not logs in general.
    # The referer/ua largely has no importance beyond being a proto bug report for log messages.
    $Trog::Log::DBI::referer = $env->{HTTP_REFERER};
    $Trog::Log::DBI::ua      = $env->{HTTP_UA};

    # Check eTags.  If we don't know about it, just assume it's good and lazily fill the cache
    # XXX yes, this allows cache poisoning...but only for logged in users!
    if ( $env->{HTTP_IF_NONE_MATCH} ) {
        INFO("$env->{REQUEST_METHOD} 304 $fullpath");
        return [ 304, [], [''] ] if $env->{HTTP_IF_NONE_MATCH} eq ( $etags{ $env->{REQUEST_URI} } || '' );
        $etags{ $env->{REQUEST_URI} } = $env->{HTTP_IF_NONE_MATCH} unless exists $etags{ $env->{REQUEST_URI} };
    }

    # TODO: Actually do something with the language passed to the renderer
    my $lang = $env->{HTTP_ACCEPT_LANGUAGE};

    #TODO: Actually do something with the acceptable output formats in the renderer
    my $accept = $env->{HTTP_ACCEPT};

    # Figure out if we want compression or not
    my $alist = $env->{HTTP_ACCEPT_ENCODING} || '';
    $alist =~ s/\s//g;
    my @accept_encodings;
    @accept_encodings = split( /,/, $alist );
    my $deflate = grep { 'gzip' eq $_ } @accept_encodings;

    # NOTE These two parameters are entirely academic, as we don't use ad tracking cookies, but the UTM parameters.
    # UTMs are actually fully sufficient to get you what you want -- e.g. keywords, audience groups, a/b testing, etc.
    # and you need to put up cookie consent banners if you bother using tracking cookies, which are horrific UX.
    #my $no_track = $env->{HTTP_DNT};
    #my $no_sell_info = $env->{HTTP_SEC_GPC};

    # We generally prefer this to be handled at the reverse proxy level.
    #my $prefer_ssl = $env->{HTTP_UPGRADE_INSECURE_REQUESTS};

    my $last_fetch = 0;
    if ( $env->{HTTP_IF_MODIFIED_SINCE} ) {
        $last_fetch = DateTime::Format::HTTP->parse_datetime( $env->{HTTP_IF_MODIFIED_SINCE} )->epoch();
    }

    #XXX Don't use statics anything that has a search query
    # On one hand, I don't want to DOS the disk, but I'd also like some like ?rss...
    # Should probably turn those into aliases.
    my $has_query = !!$env->{QUERY_STRING};

    my $query = {};
    $query = URL::Encode::url_params_mixed( $env->{QUERY_STRING} ) if $env->{QUERY_STRING};

    #Actually parse the POSTDATA and dump it into the QUERY object if this is a POST
    if ( $env->{REQUEST_METHOD} eq 'POST' ) {

        my $body = HTTP::Body->new( $env->{CONTENT_TYPE}, $env->{CONTENT_LENGTH} );
        while ( $env->{'psgi.input'}->read( my $buf, $Trog::Vars::CHUNK_SIZE ) ) {
            $body->add($buf);
        }

        @$query{ keys( %{ $body->param } ) }  = values( %{ $body->param } );
        @$query{ keys( %{ $body->upload } ) } = values( %{ $body->upload } );
    }

    # It's mod_rewrite!
    $path = '/index' if $path eq '/';

    #XXX this is hardcoded in browsers, so just rewrite the path
    $path = '/img/icon/favicon.ico' if $path eq '/favicon.ico';

    # Translate alias paths into their actual path
    $path = $aliases{$path} if exists $aliases{$path};

    # Collapse multiple slashes in the path
    $path =~ s/[\/]+/\//g;

    #Handle regex/capture routes
    if ( !exists $routes{$path} ) {
        my @captures;

        # XXX maybe this should all just go into $query?
        # TODO can optimize by having separate hashes for capture/non-capture routes
        foreach my $pattern ( keys(%routes) ) {
            @captures = $path =~ m/^$pattern$/;
            if (@captures) {
                $path = $pattern;
                foreach my $field ( @{ $routes{$path}{captures} } ) {
                    $routes{$path}{data} //= {};
                    $routes{$path}{data}{$field} = shift @captures;
                }
                last;
            }
        }
    }

    # Set the 'data' in the query that the route specifically overrides, which we are also using for the catpured data
    # This also means you have to validate both of them via parameters if you set that up.
    @{$query}{ keys( %{ $routes{$path}{'data'} } ) } = values( %{ $routes{$path}{'data'} } ) if ref $routes{$path}{'data'} eq 'HASH' && %{ $routes{$path}{'data'} };

    # Ensure any short-circuit routes can log the request, and return the server-timing headers properly
    $query->{method}   = $method;
    $query->{route}    = $path;
    $query->{fullpath} = $fullpath;
    $query->{start}    = $start;

    # Handle HTTP range/streaming requests
    my $range = $env->{HTTP_RANGE} || "bytes=0-" if $env->{HTTP_RANGE} || $env->{HTTP_IF_RANGE};

    my $streaming = $env->{'psgi.streaming'};
    $query->{streaming} = $streaming;

    my @ranges;
    if ($range) {
        $range =~ s/bytes=//g;
        push(
            @ranges,
            map {
                [ split( /-/, $_ ) ];

                #$tuples[1] //= $tuples[0] + $Trog::Vars::CHUNK_SIZE;
                #\@tuples
            } split( /,/, $range )
        );
    }

    # If it's a file, just serve it
    return Trog::FileHandler::serve( $fullpath, "www/$path", $start, $streaming, \@ranges, $last_fetch, $deflate ) if -f "www/$path";

    # Figure out if we have a logged in user, so we can serve them user-specific files
    my $cookies = {};
    if ( $env->{HTTP_COOKIE} ) {
        $cookies = CGI::Cookie->parse( $env->{HTTP_COOKIE} );
    }

    my $active_user = '';
    $Trog::Log::user = 'nobody';
    if ( exists $cookies->{tcmslogin} ) {
        $active_user     = Trog::Auth::session2user( $cookies->{tcmslogin}->value );
        $Trog::Log::user = $active_user if $active_user;
    }

    return Trog::FileHandler::serve( $fullpath, "totp/$path", $start, $streaming, \@ranges, $last_fetch, $deflate ) if -f "totp/$path" && $active_user;

    # Now that we have firmed up the actual routing, let's validate.
    return _forbidden($query) if exists $routes{$path}{auth} && !$active_user;
    return _notfound($query) unless exists $routes{$path} && ref $routes{$path} eq 'HASH' && keys( %{ $routes{$path} } );
    return _badrequest($query) unless grep { $env->{REQUEST_METHOD} eq $_ } ( $routes{$path}{method} || '', 'HEAD' );

    # Disallow any paths that are naughty ( starman auto-removes .. up-traversal)
    if ( index( $path, '/templates' ) == 0 || index( $path, '/statics' ) == 0 || $path =~ m/.*(\.psgi|\.pm)$/i ) {
        return _forbidden($query);
    }

    # Set the urchin parameters if necessary.
    %$Trog::Log::DBI::urchin = map { $_ => delete $query->{$_} } qw{utm_source utm_medium utm_campaign utm_term utm_content};

    # Now that we've parsed the query and know where we want to go, we should murder everything the route does not explicitly want, and validate what it does
    my $parameters = $routes{$path}{parameters};
    if ($parameters) {
        die "invalid route definition for $path: bad parameters" unless is_hashref($parameters);
        my @known_params = keys(%$parameters);
        for my $param (@known_params) {
            die "Invalid route definition for $path: parameter $param must correspond to a validation CODEREF." unless is_coderef( $parameters->{$param} );

            # A missing parameter is not necessarily a problem.
            next unless $query->{$param};

            # But if we have it, and it's bad, nack it, so that scanners get fail2banned.
            DEBUG("Rejected $fullpath for bad query param $param");
            return _badrequest($query) unless $parameters->{$param}->( $query->{$param} );
        }

        # Smack down passing of unnecessary fields
        foreach my $field ( keys(%$query) ) {
            next if List::Util::any { $field eq $_ } @known_params;
            next if List::Util::any { $field eq $_ } qw{start route streaming method fullpath};
            DEBUG("Rejected $fullpath for query param $field");
            return _badrequest($query);
        }
    }

    # Let's open up our default route before we bother thinking about routing any harder
    return $routes{default}{callback}->($query) unless -f "config/setup";

    $query->{user_acls} = [];
    $query->{user_acls} = Trog::Auth::acls4user($active_user) // [] if $active_user;

    # Grab the list of ACLs we want to add to a post, if any.
    $query->{acls} = [ $query->{acls} ] if ( $query->{acls} && ref $query->{acls} ne 'ARRAY' );

    # Filter out passed ACLs which are naughty
    my $is_admin = grep { $_ eq 'admin' } @{ $query->{user_acls} };
    @{ $query->{acls} } = grep { $_ ne 'admin' } @{ $query->{acls} } unless $is_admin;

    # If we have a static render, just use it instead (These will ALWAYS be correct, data saves invalidate this)
    # TODO: make this key on admin INSTEAD of active user when we add non-admin users.
    if ( !$active_user && !$has_query ) {
        return _static( $fullpath, "$path.z", $start, $streaming ) if -f "www/statics/$path.z" && $deflate;
        return _static( $fullpath, $path,     $start, $streaming ) if -f "www/statics/$path";
    }

    $query->{deflate} = $deflate;
    $query->{user}    = $active_user;

    #Set various things we don't want overridden
    $query->{body}         = '';
    $query->{dnt}          = $env->{HTTP_DNT};
    $query->{user}         = $active_user;
    $query->{domain}       = $domain;
    $query->{route}        = $path;
    $query->{scheme}       = $scheme;
    $query->{social_meta}  = 1;
    $query->{primary_post} = {};
    $query->{has_query}    = $has_query;
    $query->{port}         = $port;
    $query->{lang}         = $lang;
    $query->{accept}       = $accept;

    # Redirecting somewhere naughty not allow
    $query->{to} = URI->new( $query->{to} // '' )->path() || $query->{to} if $query->{to};

    DEBUG("DISPATCH $path to $routes{$path}{callback}");

    #XXX there is a trick to now use strict refs, but I don't remember it right at the moment
    {
        no strict 'refs';
        my $output = $routes{$path}{callback}->($query);
        die "$path returned no data!" unless ref $output eq 'ARRAY' && @$output == 3;

        my $pport = defined $query->{port} ? ":$query->{port}" : "";
        INFO("$env->{REQUEST_METHOD} $output->[0] $fullpath");

        # Append server-timing headers if they aren't present
        my $tot = tv_interval($start) * 1000;
        push( @{ $output->[1] }, 'Server-Timing' => "app;dur=$tot" ) unless List::Util::any { $_ eq 'Server-Timing' } @{ $output->[1] };
        return $output;
    }
}

#XXX Return a clone of the routing table ref, because code modifies it later
sub _routes ( $data = {} ) {
    state %routes;
    return clone( \%routes ) if %routes;

    if ( !$data ) {
        my $conf = Trog::Config::get();
        $data = Trog::Data->new($conf);
    }
    my %roots = $data->routes();
    %routes                                      = %Trog::Routes::HTML::routes;
    @routes{ keys(%Trog::Routes::JSON::routes) } = values(%Trog::Routes::JSON::routes);
    @routes{ keys(%roots) }                      = values(%roots);

    # Add in global routes, here because they *must* know about all other routes
    # Also, nobody should ever override these.
    $routes{'/robots.txt'} = {
        method   => 'GET',
        callback => \&robots,
    };

    return clone( \%routes );
}

=head2 robots

Return an appropriate robots.txt

This is a "special" route as it needs to know about all the routes in order to disallow noindex=1 routes.

=cut

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

sub _generic ( $type, $query ) {
    return _static( "$type.z", $query->{start}, $query->{streaming} ) if -f "www/statics/$type.z";
    return _static( $type,     $query->{start}, $query->{streaming} ) if -f "www/statics/$type";
    my %lookup = (
        notfound   => \&Trog::Routes::HTML::notfound,
        forbidden  => \&Trog::Routes::HTML::forbidden,
        badrequest => \&Trog::Routes::HTML::badrequest,
        toolong    => \&Trog::Routes::HTML::toolong,
        error      => \&Trog::Routes::HTML::error,
    );
    return $lookup{$type}->($query);
}

sub _notfound ($query) {
    INFO("$query->{method} 404 $query->{fullpath}");
    return _generic( 'notfound', $query );
}

sub _forbidden ($query) {
    INFO("$query->{method} 403 $query->{fullpath}");
    return _generic( 'forbidden', $query );
}

sub _badrequest ($query) {
    INFO("$query->{method} 400 $query->{fullpath}");
    return _generic( 'badrequest', $query );
}

sub _toolong ($query) {
    INFO("$query->{method} 419 $query->{fullpath}");
    return _generic( 'toolong', {} );
}

sub _error ($query) {
    $query->{method}   //= "UNKNOWN";
    $query->{fullpath} //= $query->{route} // '/?';
    INFO("$query->{method} 500 $query->{fullpath}");
    return _generic( 'error', $query );
}

sub _static ( $fullpath, $path, $start, $streaming, $last_fetch = 0 ) {

    DEBUG("Rendering static for $path");

    # XXX because of psgi I can't just vomit the file directly
    if ( open( my $fh, '<', "www/statics/$path" ) ) {
        my $headers = '';

        # NOTE: this is relying on while advancing the file pointer
        while (<$fh>) {
            last if $_ eq "\n";
            $headers .= $_;
        }
        my ( undef, undef, $status, undef, $headers_parsed ) = HTTP::Parser::XS::parse_http_response( "$headers\n", HEADERS_AS_HASHREF );

        #XXX need to put this into the file itself
        my $mt         = ( stat($fh) )[9];
        my @gm         = gmtime($mt);
        my $now_string = strftime( "%a, %d %b %Y %H:%M:%S GMT", @gm );
        my $code       = $mt > $last_fetch ? $status : 304;
        $headers_parsed->{"Last-Modified"} = $now_string;

        # Append server-timing headers
        my $tot = tv_interval($start) * 1000;
        $headers_parsed->{'Server-Timing'} = "static;dur=$tot";

        #XXX uwsgi just opens the file *again* when we already have a filehandle if it has a path.
        # starman by comparison doesn't violate the principle of least astonishment here.
        # This is probably a performance optimization, but makes the kind of micromanagement I need to do inconvenient.
        # As such, we will just return a stream.
        INFO("GET 200 $fullpath");

        return sub {
            my $responder = shift;

            #push(@headers, 'Content-Length' => $sz);
            my $writer = $responder->( [ $code, [%$headers_parsed] ] );
            while ( $fh->read( my $buf, $Trog::Vars::CHUNK_SIZE ) ) {
                $writer->write($buf);
            }
            close $fh;
            $writer->close;
          }
          if $streaming;

        return [ $code, [%$headers_parsed], $fh ];
    }
    INFO("GET 403 $fullpath");
    return [ 403, [ 'Content-Type' => $Trog::Vars::content_types{text} ], ["STAY OUT YOU RED MENACE"] ];
}

1;
