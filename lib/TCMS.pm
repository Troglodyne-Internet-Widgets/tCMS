package TCMS;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use Date::Format qw{strftime};

use HTTP::Body   ();
use URL::Encode  ();
use Text::Xslate ();
use Plack::MIME  ();
use Mojo::File   ();
use DateTime::Format::HTTP();
use CGI::Cookie ();
use File::Basename();
use IO::Compress::Gzip();
use Time::HiRes qw{gettimeofday tv_interval};
use HTTP::Parser::XS qw{HEADERS_AS_HASHREF};
use List::Util;

#Grab our custom routes
use lib 'lib';
use Trog::Routes::HTML;
use Trog::Routes::JSON;

use Trog::Auth;
use Trog::Utils;
use Trog::Config;
use Trog::Data;
use Trog::Vars;

# Troglodyne philosophy - simple as possible

# Import the routes

my $conf = Trog::Config::get();
my $data = Trog::Data->new($conf);
my %roots = $data->routes();

my %routes = %Trog::Routes::HTML::routes;
@routes{keys(%Trog::Routes::JSON::routes)} = values(%Trog::Routes::JSON::routes);
@routes{keys(%roots)} = values(%roots);

my %aliases = $data->aliases();

# XXX this is built progressively across the forks, leading to inconsistent behavior.
# This should eventually be pre-filled from DB.
my %etags;

#1MB chunks
my $CHUNK_SIZE = 1024000;
my $CHUNK_SEP  = 'tCMSep666YOLO42069';

#Stuff that isn't in upstream finders
my %extra_types = (
    '.docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
);

=head2 app()

Dispatches requests based on %routes built above.

The dispatcher here does *not* do anything with the authn/authz data.  It sets those in the 'user' and 'acls' parameters of the query object passed to routes.

If a path passed is not a defined route (or regex route), but exists as a file under www/, it will be served up immediately.

=cut

sub app {
    # Start the server timing clock
    my $start = [gettimeofday];

    my $env = shift;

    # Check eTags.  If we don't know about it, just assume it's good and lazily fill the cache
    # XXX yes, this allows cache poisoning...but only for logged in users!
    if ($env->{HTTP_IF_NONE_MATCH}) {
        return [304, [], ['']] if $env->{HTTP_IF_NONE_MATCH} eq ($etags{$env->{REQUEST_URI}} || '');
        $etags{$env->{REQUEST_URI}} = $env->{HTTP_IF_NONE_MATCH} unless exists $etags{$env->{REQUEST_URI}};
    }

    my $last_fetch = 0;
    if ($env->{HTTP_IF_MODIFIED_SINCE}) {
        $last_fetch = DateTime::Format::HTTP->parse_datetime($env->{HTTP_IF_MODIFIED_SINCE})->epoch();
    }

    #XXX Don't use statics anything that has a search query
    # On one hand, I don't want to DOS the disk, but I'd also like some like ?rss...
    # Should probably turn those into aliases.
    my $has_query = !!$env->{QUERY_STRING};

    my $query = {};
    $query = URL::Encode::url_params_mixed($env->{QUERY_STRING}) if $env->{QUERY_STRING};

    #Actually parse the POSTDATA and dump it into the QUERY object if this is a POST
    if ($env->{REQUEST_METHOD} eq 'POST') {

        my $body = HTTP::Body->new( $env->{CONTENT_TYPE}, $env->{CONTENT_LENGTH} );
        while ( read($env->{'psgi.input'}, my $buf, $CHUNK_SIZE) ) {
            $body->add($buf);
        }

        @$query{keys(%{$body->param})}  = values(%{$body->param});
        @$query{keys(%{$body->upload})} = values(%{$body->upload});
    }

    # Grab the list of ACLs we want to add to a post, if any.
    $query->{acls} = [$query->{acls}] if ($query->{acls} && ref $query->{acls} ne 'ARRAY');

    my $path = $env->{PATH_INFO};
    $path = '/index' if $path eq '/';

    # Translate alias paths into their actual path
    $path = $aliases{$path} if exists $aliases{$path};

    # Figure out if we want compression or not
    my $alist = $env->{HTTP_ACCEPT_ENCODING} || '';
    $alist =~ s/\s//g;
    my @accept_encodings;
    @accept_encodings = split(/,/, $alist);
    my $deflate = grep { 'gzip' eq $_ } @accept_encodings;

    # Collapse multiple slashes in the path
    $path =~ s/[\/]+/\//g;

    # Let's open up our default route before we bother to see if users even exist
    return $routes{default}{callback}->($query) unless -f "config/setup";

    my $cookies = {};
    if ($env->{HTTP_COOKIE}) {
        $cookies = CGI::Cookie->parse($env->{HTTP_COOKIE});
    }

    my $active_user = '';
    if (exists $cookies->{tcmslogin}) {
         $active_user = Trog::Auth::session2user($cookies->{tcmslogin}->value);
    }
    $query->{user_acls} = [];
    $query->{user_acls} = Trog::Auth::acls4user($active_user) // [] if $active_user;

    # Filter out passed ACLs which are naughty
    my $is_admin = grep { $_ eq 'admin' } @{$query->{user_acls}};
    @{$query->{acls}} = grep { $_ ne 'admin' } @{$query->{acls}} unless $is_admin;

    # Disallow any paths that are naughty ( starman auto-removes .. up-traversal)
    if (index($path,'/templates') == 0 || index($path, '/statics') == 0 || $path =~ m/.*(\.psgi|\.pm)$/i ) {
        return _forbidden($query);
    }

    # If we have a static render, just use it instead (These will ALWAYS be correct, data saves invalidate this)
    # TODO: make this key on admin INSTEAD of active user when we add non-admin users.
    $query->{start} = $start;
    if (!$active_user && !$has_query) {
        return _static("$path.z",$start) if -f "www/statics/$path.z" && $deflate;
        return _static($path,$start) if -f "www/statics/$path";
    }

    # Handle HTTP range/streaming requests
    my $range = $env->{HTTP_RANGE} || "bytes=0-" if $env->{HTTP_RANGE} || $env->{HTTP_IF_RANGE};

    my @ranges;
    if ($range) {
        $range =~ s/bytes=//g;
        push(@ranges, map {
            [split(/-/, $_)];
            #$tuples[1] //= $tuples[0] + $CHUNK_SIZE;
            #\@tuples
        } split(/,/, $range) );
    }

    my $streaming = $env->{'psgi.streaming'};
    $query->{streaming} = $streaming;

    return _serve("www/$path", $start, $streaming, \@ranges, $last_fetch, $deflate) if -f "www/$path";

    #Handle regex/capture routes
    if (!exists $routes{$path}) {
        my @captures;
        foreach my $pattern (keys(%routes)) {
            @captures = $path =~ m/^$pattern$/;
            if (@captures) {
                $path = $pattern;
                foreach my $field (@{$routes{$path}{captures}}) {
                    $routes{$path}{data} //= {};
                    $routes{$path}{data}{$field} = shift @captures;
                }
                last;
            }
        }
    }

    $query->{deflate} = $deflate;
    $query->{user}    = $active_user;

    return _notfound($query) unless exists $routes{$path};
    return _badrequest($query) unless grep { $env->{REQUEST_METHOD} eq $_ } ($routes{$path}{method} || '','HEAD');

    @{$query}{keys(%{$routes{$path}{'data'}})} = values(%{$routes{$path}{'data'}}) if ref $routes{$path}{'data'} eq 'HASH' && %{$routes{$path}{'data'}};

    #Set various things we don't want overridden
    $query->{body}         = '';
    $query->{dnt}          = $env->{HTTP_DNT};
    $query->{user}         = $active_user;
    $query->{domain}       = $env->{HTTP_X_FORWARDED_HOST} || $env->{HTTP_HOST};
    $query->{route}        = $path;
    $query->{scheme}       = $env->{'psgi.url_scheme'} // 'http';
    $query->{social_meta}  = 1;
    $query->{primary_post} = {};
    $query->{has_query}    = $has_query;

    #XXX there is a trick to now use strict refs, but I don't remember it right at the moment
    {
        no strict 'refs';
        my $output = $routes{$path}{callback}->($query);
        # Append server-timing headers
        my $tot = tv_interval($start) * 1000;
        push(@{$output->[1]}, 'Server-Timing' => "app;dur=$tot");
        return $output;
    }
};

sub _generic($type, $query) {
    return _static("$type.z",$query->{start}) if -f "www/statics/$type.z";
    return _static($type, $query->{start}) if -f "www/statics/$type";
    my %lookup = (
        notfound => \&Trog::Routes::HTML::notfound,
        forbidden => \&Trog::Routes::HTML::forbidden,
        badrequest => \&Trog::Routes::HTML::badrequest,
    );
    return $lookup{$type}->($query);
}

sub _notfound ($query) {
    return _generic('notfound', $query);
}

sub _forbidden($query) {
    return _generic('forbidden', $query);
}

sub _badrequest($query) {
    return _generic('badrequest', $query);
}

sub _static($path,$start,$last_fetch=0) {

    # XXX because of psgi I can't just vomit the file directly
    if (open(my $fh, '<', "www/statics/$path")) {
        my $headers = '';
        # NOTE: this is relying on while advancing the file pointer
        while (<$fh>) {
            last if $_ eq "\n";
            $headers .= $_;
        }
        my(undef, undef, $status, undef, $headers_parsed) = HTTP::Parser::XS::parse_http_response("$headers\n", HEADERS_AS_HASHREF);

        #XXX need to put this into the file itself
        my $mt = (stat($fh))[9];
        my @gm = gmtime($mt);
        my $now_string = strftime( "%a, %d %b %Y %H:%M:%S GMT", @gm );
        my $code = $mt > $last_fetch ? $status : 304;
        $headers_parsed->{"Last-Modified"} = $now_string;

        # Append server-timing headers
        my $tot = tv_interval($start) * 1000;
        $headers_parsed->{'Server-Timing'} = "static;dur=$tot";

        return [$code, [%$headers_parsed], $fh];
    }
    return [ 403, ['Content-Type' => $Trog::Vars::content_types{plain}], ["STAY OUT YOU RED MENACE"]];
}

sub _range ($fh, $ranges, $sz, %headers) {
    # Set mode
    my $primary_ct = "Content-Type: $headers{'Content-type'}";
    my $is_multipart = scalar(@$ranges) > 1;
    if ( $is_multipart ) {
        $headers{'Content-type'} = "multipart/byteranges; boundary=$CHUNK_SEP";
    }
    my $code = 206;

    my $fc = '';
    # Calculate the content-length up-front.  We have to fix unspecified lengths first, and reject bad requests.
    foreach my $range (@$ranges) {
        $range->[1] //= $sz-1;
        return [416, [%headers], ["Requested range not satisfiable"]] if $range->[0] > $sz || $range->[0] < 0 || $range->[1] < 0 || $range->[0] > $range->[1];
    }
    $headers{'Content-Length'} = List::Util::sum(map { my $arr=$_; $arr->[1]+1, -$arr->[0] } @$ranges);

    #XXX Add the entity header lengths to the value - should hash-ify this to DRY
    if ($is_multipart) {
        foreach my $range (@$ranges) {
            $headers{'Content-Length'} += length("$fc--$CHUNK_SEP\n$primary_ct\nContent-Range: bytes $range->[0]-$range->[1]/$sz\n\n" );
            $fc = "\n";
        }
        $headers{'Content-Length'} += length( "\n--$CHUNK_SEP\--\n" );
        $fc = '';
    }

    return sub {
        my $responder = shift;
        my $writer;

        foreach my $range (@$ranges) {
            $headers{'Content-Range'} = "bytes $range->[0]-$range->[1]/$sz" unless $is_multipart;
            $writer //= $responder->([ $code, [%headers]]);
            $writer->write( "$fc--$CHUNK_SEP\n$primary_ct\nContent-Range: bytes $range->[0]-$range->[1]/$sz\n\n" ) if $is_multipart;
            $fc = "\n";

            my $len = List::Util::min($sz,$range->[1]+1) - $range->[0];

            seek($fh, $range->[0], 0);
            while ($len) {
                read($fh, my $buf, List::Util::min($len,$CHUNK_SIZE) );
                $writer->write($buf);

                # Adjust for amount written
                $len = List::Util::max($len - $CHUNK_SIZE, 0);
            }
        }
        close($fh);
        $writer->write( "\n--$CHUNK_SEP\--\n" ) if $is_multipart;
        $writer->close;
    };
}

sub _serve ($path, $start, $streaming, $ranges, $last_fetch=0, $deflate=0) {
    my $mf = Mojo::File->new($path);
    my $ext = '.'.$mf->extname();
    my $ft;
    if ($ext) {
        $ft = Plack::MIME->mime_type($ext) if $ext;
        $ft ||= $extra_types{$ext} if exists $extra_types{$ext};
    }
    $ft ||= $Trog::Vars::content_types{plain};

    my $ct = 'Content-type';
    my @headers = ($ct => $ft);
    #TODO use static Cache-Control for everything but JS/CSS?
    push(@headers,'Cache-control' => $Trog::Vars::cache_control{revalidate});

    #XXX chrome is just broken as hell when it comes to seeks
    push(@headers,'Accept-Ranges' => 'bytes');

    my $mt = (stat($path))[9];
    my $sz = (stat(_))[7];
    my @gm = gmtime($mt);
    my $now_string = strftime( "%a, %d %b %Y %H:%M:%S GMT", @gm );
    my $code = $mt > $last_fetch ? 200 : 304;

    push(@headers, "Last-Modified" => $now_string);
    push(@headers, 'Vary' => 'Accept-Encoding');

    if (open(my $fh, '<', $path)) {
        return _range($fh, $ranges, $sz, @headers) if @$ranges && $streaming;

        # Transfer-encoding: chunked
        return sub {
            my $responder = shift;
            push(@headers, 'Content-Length' => $sz);
            my $writer = $responder->([ $code, \@headers]);
            while ( read($fh, my $buf, $CHUNK_SIZE) ) {
                $writer->write($buf);
            }
            close $fh;
            $writer->close;
        } if $streaming && $sz > $CHUNK_SIZE;

        #Return data in the event the caller does not support deflate
        if (!$deflate) {
            push( @headers, "Content-Length" => $sz );
            # Append server-timing headers
            my $tot = tv_interval($start) * 1000;
            push(@headers, 'Server-Timing' => "file;dur=$tot");

            return [ $code, \@headers, $fh];
        }

        #Compress everything less than 1MB
        push( @headers, "Content-Encoding" => "gzip" );
        my $dfh;
        IO::Compress::Gzip::gzip( $fh => \$dfh );
        print $IO::Compress::Gzip::GzipError if $IO::Compress::Gzip::GzipError;
        push( @headers, "Content-Length" => length($dfh) );

        # Append server-timing headers
        my $tot = tv_interval($start) * 1000;
        push(@headers, 'Server-Timing' => "file;dur=$tot");

        return [ $code, \@headers, [$dfh]];
    }

    return [ 403, [$ct => $Trog::Vars::content_types{plain}], ["STAY OUT YOU RED MENACE"]];
}

1;
