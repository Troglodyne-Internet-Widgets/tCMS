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
use IO::Compress::Deflate();
use Time::HiRes qw{gettimeofday tv_interval};

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
my %etags;

#1MB chunks
my $CHUNK_SIZE = 1024000;

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
    # XXX yes, this allows cache poisoning
    if ($env->{HTTP_IF_NONE_MATCH}) {
        $etags{$env->{REQUEST_URI}} = $env->{HTTP_IF_NONE_MATCH} unless exists $etags{$env->{REQUEST_URI}};
        return [304, [], ['']] if $env->{HTTP_IF_NONE_MATCH} eq $etags{$env->{REQUEST_URI}};
    }

    my $last_fetch = 0;
    if ($env->{HTTP_IF_MODIFIED_SINCE}) {
        $last_fetch = DateTime::Format::HTTP->parse_datetime($env->{HTTP_IF_MODIFIED_SINCE})->epoch();
    }

    my $query = {};
    $query = URL::Encode::url_params_mixed($env->{QUERY_STRING}) if $env->{QUERY_STRING};

    my $path = $env->{PATH_INFO};

    # Translate alias paths into their actual path
    $path = $aliases{$path} if exists $aliases{$path};

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

    #Disallow any paths that are naughty ( starman auto-removes .. up-traversal)
    if (index($path,'/templates') == 0 || $path =~ m/.*\.psgi$/i ) {
        return Trog::Routes::HTML::forbidden($query);
    }

    # If it's just a file, serve it up
    my $alist = $env->{HTTP_ACCEPT_ENCODING} || '';
    $alist =~ s/\s//g;
    my @accept_encodings;
    @accept_encodings = split(/,/, $alist);
    my $deflate = grep { 'deflate' eq $_ } @accept_encodings;

    return _serve("www/$path", $start, $env->{'psgi.streaming'}, $last_fetch, $deflate) if -f "www/$path";

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

    return Trog::Routes::HTML::notfound($query) unless exists $routes{$path};
    return Trog::Routes::HTML::badrequest($query) unless grep { $env->{REQUEST_METHOD} eq $_ } ($routes{$path}{method},'HEAD');

    @{$query}{keys(%{$routes{$path}{'data'}})} = values(%{$routes{$path}{'data'}}) if ref $routes{$path}{'data'} eq 'HASH' && %{$routes{$path}{'data'}};

    #Actually parse the POSTDATA and dump it into the QUERY object if this is a POST
    if ($env->{REQUEST_METHOD} eq 'POST') {

        my $body = HTTP::Body->new( $env->{CONTENT_TYPE}, $env->{CONTENT_LENGTH} );
        while ( read($env->{'psgi.input'}, my $buf, $CHUNK_SIZE) ) {
            $body->add($buf);
        }

        @$query{keys(%{$body->param})}  = values(%{$body->param});
        @$query{keys(%{$body->upload})} = values(%{$body->upload});
    }

    #Set various things we don't want overridden
    $query->{acls} = [$query->{acls}] if ($query->{acls} && ref $query->{acls} ne 'ARRAY');
    $query->{acls} = Trog::Auth::acls4user($active_user) // [] if $active_user;

    $query->{user}         = $active_user;
    $query->{domain}       = $env->{HTTP_X_FORWARDED_HOST} || $env->{HTTP_HOST};
    $query->{route}        = $path;
    #$query->{route}        = $env->{REQUEST_URI};
    #$query->{route}        =~ s/\?\Q$env->{QUERY_STRING}\E//;
    $query->{scheme}       = $env->{'psgi.url_scheme'} // 'http';
    $query->{social_meta}  = 1;
    $query->{primary_post} = {};

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

sub _serve ($path, $start, $streaming=0, $last_fetch=0, $deflate=0) {
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

    my $mt = (stat($path))[9];
    my $sz = (stat(_))[7];
    my @gm = gmtime($mt);
    my $now_string = strftime( "%a, %d %b %Y %H:%M:%S GMT", @gm );
    my $code = $mt > $last_fetch ? 200 : 304;

    #XXX doing metadata=preload on videos doesn't work right?
    #push(@headers, "Content-Length: $sz");
    push(@headers, "Last-Modified" => $now_string);

    if (open(my $fh, '<', $path)) {
        return sub {
            my $responder = shift;
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
        push( @headers, "Content-Encoding" => "deflate" );
        my $dfh;
        IO::Compress::Deflate::deflate( $fh => \$dfh );
        print $IO::Compress::Deflate::DeflateError if $IO::Compress::Deflate::DeflateError;
        push( @headers, "Content-Length" => length($dfh) );

        # Append server-timing headers
        my $tot = tv_interval($start) * 1000;
        push(@headers, 'Server-Timing' => "file;dur=$tot");

        return [ $code, \@headers, [$dfh]];
    }

    return [ 403, [$ct => $Trog::Vars::content_types{plain}], ["STAY OUT YOU RED MENACE"]];
}

1;
