package TCMS;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use Date::Format qw{strftime};

use Sys::Hostname();
use HTTP::Body   ();
use URL::Encode  ();
use Text::Xslate ();
use Plack::MIME  ();
use Mojo::File   ();
use DateTime::Format::HTTP();
use CGI::Cookie ();
use File::Basename();
use IO::Compress::Gzip();
use Time::HiRes      qw{gettimeofday tv_interval};
use HTTP::Parser::XS qw{HEADERS_AS_HASHREF};
use List::Util;
use UUID::Tiny();
use URI();

#Grab our custom routes
use FindBin::libs;
use Trog::Routes::HTML;
use Trog::Routes::JSON;

use Trog::Log qw{:all};
use Trog::Auth;
use Trog::Utils;
use Trog::Config;
use Trog::Data;
use Trog::Vars;
use Trog::FileHandler;

# Troglodyne philosophy - simple as possible

# Import the routes
my $conf  = Trog::Config::get();
my $data  = Trog::Data->new($conf);
my %roots = $data->routes();

my %routes = %Trog::Routes::HTML::routes;
@routes{ keys(%Trog::Routes::JSON::routes) } = values(%Trog::Routes::JSON::routes);
@routes{ keys(%roots) }                      = values(%roots);

my %aliases = $data->aliases();

# XXX this is built progressively across the forks, leading to inconsistent behavior.
# This should eventually be pre-filled from DB.
my %etags;

=head2 app()

Dispatches requests based on %routes built above.

The dispatcher here does *not* do anything with the authn/authz data.  It sets those in the 'user' and 'acls' parameters of the query object passed to routes.

If a path passed is not a defined route (or regex route), but exists as a file under www/, it will be served up immediately.

=cut

sub app {

    # Start the server timing clock
    my $start = [gettimeofday];

    my $env = shift;

    return _toolong() if length( $env->{REQUEST_URI} ) > 2048;

    # Check eTags.  If we don't know about it, just assume it's good and lazily fill the cache
    # XXX yes, this allows cache poisoning...but only for logged in users!
    if ( $env->{HTTP_IF_NONE_MATCH} ) {
        return [ 304, [], [''] ] if $env->{HTTP_IF_NONE_MATCH} eq ( $etags{ $env->{REQUEST_URI} } || '' );
        $etags{ $env->{REQUEST_URI} } = $env->{HTTP_IF_NONE_MATCH} unless exists $etags{ $env->{REQUEST_URI} };
    }

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

    # Grab the list of ACLs we want to add to a post, if any.
    $query->{acls} = [ $query->{acls} ] if ( $query->{acls} && ref $query->{acls} ne 'ARRAY' );

    my $path = $env->{PATH_INFO};
    $path = '/index' if $path eq '/';
    #XXX this is hardcoded in browsers, so just rewrite the path
    $path = '/img/icon/favicon.ico' if $path eq '/favicon.ico';

    # Translate alias paths into their actual path
    $path = $aliases{$path} if exists $aliases{$path};

    # Figure out if we want compression or not
    my $alist = $env->{HTTP_ACCEPT_ENCODING} || '';
    $alist =~ s/\s//g;
    my @accept_encodings;
    @accept_encodings = split( /,/, $alist );
    my $deflate = grep { 'gzip' eq $_ } @accept_encodings;

    # Collapse multiple slashes in the path
    $path =~ s/[\/]+/\//g;

    # Let's open up our default route before we bother to see if users even exist
    return $routes{default}{callback}->($query) unless -f "config/setup";

    my $cookies = {};
    if ( $env->{HTTP_COOKIE} ) {
        $cookies = CGI::Cookie->parse( $env->{HTTP_COOKIE} );
    }

    # Set the IP of the request so we can fail2ban
    $Trog::Log::ip = $env->{HTTP_X_FORWARDED_FOR} || $env->{REMOTE_ADDR};

    my $active_user = '';
    $Trog::Log::user = 'nobody';
    if ( exists $cookies->{tcmslogin} ) {
        $active_user = Trog::Auth::session2user( $cookies->{tcmslogin}->value );
        $Trog::Log::user = $active_user if $active_user;
    }
    $query->{user_acls} = [];
    $query->{user_acls} = Trog::Auth::acls4user($active_user) // [] if $active_user;

    # Log the request.  UUID::Tiny can explode sometimes.
    my $requestid = eval { UUID::Tiny::create_uuid_as_string( UUID::Tiny::UUID_V1, UUID::Tiny::UUID_NS_DNS ) } // "00000000-0000-0000-0000-000000000000";
    Trog::Log::uuid($requestid);
    INFO("$env->{REQUEST_METHOD} $path");

    # Filter out passed ACLs which are naughty
    my $is_admin = grep { $_ eq 'admin' } @{ $query->{user_acls} };
    @{ $query->{acls} } = grep { $_ ne 'admin' } @{ $query->{acls} } unless $is_admin;

    # Disallow any paths that are naughty ( starman auto-removes .. up-traversal)
    if ( index( $path, '/templates' ) == 0 || index( $path, '/statics' ) == 0 || $path =~ m/.*(\.psgi|\.pm)$/i ) {
        return _forbidden($query);
    }

    my $streaming = $env->{'psgi.streaming'};
    $query->{streaming} = $streaming;

    # If we have a static render, just use it instead (These will ALWAYS be correct, data saves invalidate this)
    # TODO: make this key on admin INSTEAD of active user when we add non-admin users.
    $query->{start} = $start;
    if ( !$active_user && !$has_query ) {
        return _static( "$path.z", $start, $streaming ) if -f "www/statics/$path.z" && $deflate;
        return _static( $path,     $start, $streaming ) if -f "www/statics/$path";
    }

    # Handle HTTP range/streaming requests
    my $range = $env->{HTTP_RANGE} || "bytes=0-" if $env->{HTTP_RANGE} || $env->{HTTP_IF_RANGE};

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

    return Trog::FileHandler::serve( "www/$path",  $start, $streaming, \@ranges, $last_fetch, $deflate ) if -f "www/$path";
    return Trog::FileHandler::serve( "totp/$path", $start, $streaming, \@ranges, $last_fetch, $deflate ) if -f "totp/$path" && $active_user;

    #Handle regex/capture routes
    if ( !exists $routes{$path} ) {
        my @captures;
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

    $query->{deflate} = $deflate;
    $query->{user}    = $active_user;

    return _forbidden($query) if $routes{$path}{auth} && !$active_user;
    return _notfound($query)   unless exists $routes{$path};
    return _badrequest($query) unless grep { $env->{REQUEST_METHOD} eq $_ } ( $routes{$path}{method} || '', 'HEAD' );

    @{$query}{ keys( %{ $routes{$path}{'data'} } ) } = values( %{ $routes{$path}{'data'} } ) if ref $routes{$path}{'data'} eq 'HASH' && %{ $routes{$path}{'data'} };

    #Set various things we don't want overridden
    $query->{body}         = '';
    $query->{dnt}          = $env->{HTTP_DNT};
    $query->{user}         = $active_user;
    $query->{domain}       = eval { Sys::Hostname::hostname() } // $env->{HTTP_X_FORWARDED_HOST} || $env->{HTTP_HOST};
    $query->{route}        = $path;
    $query->{scheme}       = $env->{'psgi.url_scheme'} // 'http';
    $query->{social_meta}  = 1;
    $query->{primary_post} = {};
    $query->{has_query}    = $has_query;
    $query->{port}         = $env->{HTTP_X_FORWARDED_PORT} // $env->{HTTP_PORT};
    # Redirecting somewhere naughty not allow
    $query->{to}           = URI->new($query->{to} // '')->path() || $query->{to} if $query->{to};

    #XXX there is a trick to now use strict refs, but I don't remember it right at the moment
    {
        no strict 'refs';
        my $output = $routes{$path}{callback}->($query);

        # Append server-timing headers
        my $tot = tv_interval($start) * 1000;
        push( @{ $output->[1] }, 'Server-Timing' => "app;dur=$tot" );
        return $output;
    }
}

sub _generic ( $type, $query ) {
    return _static( "$type.z", $query->{start}, $query->{streaming} ) if -f "www/statics/$type.z";
    return _static( $type,     $query->{start}, $query->{streaming} ) if -f "www/statics/$type";
    my %lookup = (
        notfound   => \&Trog::Routes::HTML::notfound,
        forbidden  => \&Trog::Routes::HTML::forbidden,
        badrequest => \&Trog::Routes::HTML::badrequest,
        toolong    => \&Trog::Routes::HTML::toolong,
    );
    return $lookup{$type}->($query);
}

sub _notfound ($query) {
    return _generic( 'notfound', $query );
}

sub _forbidden ($query) {
    return _generic( 'forbidden', $query );
}

sub _badrequest ($query) {
    return _generic( 'badrequest', $query );
}

sub _toolong() {
    return _generic( 'toolong', {} );
}

sub _static ( $path, $start, $streaming, $last_fetch = 0 ) {

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
    return [ 403, [ 'Content-Type' => $Trog::Vars::content_types{plain} ], ["STAY OUT YOU RED MENACE"] ];
}

1;
