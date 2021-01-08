package tcms;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

use Date::Format qw{strftime};

use HTTP::Body   ();
use URL::Encode  ();
use Text::Xslate ();
use Plack::MIME  ();
use Mojo::File   ();
use DateTime::Format::HTTP();
use Encode qw{encode_utf8};
use CGI::Cookie ();
use File::Basename();
use IO::Compress::Deflate();

#Grab our custom routes
use lib 'lib';
use Trog::Routes::HTML;
use Trog::Routes::JSON;
use Trog::Auth;
use Trog::Utils;

# Troglodyne philosophy - simple as possible

# Import the routes
my %routes = %Trog::Routes::HTML::routes;
@routes{keys(%Trog::Routes::JSON::routes)} = values(%Trog::Routes::JSON::routes);

#1MB chunks
my $CHUNK_SIZE = 1024000;

# Things we will actually produce from routes rather than just serving up files
my $ct = 'Content-type';
my %content_types = (
    plain => "text/plain;",
    html  => "text/html; charset=UTF-8",
    json  => "application/json;",
    blob  => "application/octet-stream;",
);

my $cc = 'Cache-control';
my %cache_control = (
    revalidate => "no-cache, max-age=0",
    nocache    => "no-store",
    static     => "public, max-age=604800, immutable",
);

#Stuff that isn't in upstream finders
my %extra_types = (
    '.docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
);

=head2 $app

Dispatches requests based on %routes built above.

The dispatcher here does *not* do anything with the authn/authz data.  It sets those in the 'user' and 'acls' parameters of the query object passed to routes.

If a path passed is not a defined route (or regex route), but exists as a file under www/, it will be served up immediately.

=cut

our $app = sub {
    my $env = shift;

    #use Data::Dumper;
    #print Dumper($env);

    my $last_fetch = 0;
    if ($env->{HTTP_IF_MODIFIED_SINCE}) {
        $last_fetch = DateTime::Format::HTTP->parse_datetime($env->{HTTP_IF_MODIFIED_SINCE})->epoch();
    }

    my $query = {};
    $query = URL::Encode::url_params_mixed($env->{QUERY_STRING}) if $env->{QUERY_STRING};

    my $path = $env->{PATH_INFO};
    # Collapse multiple slashes in the path
    $path =~ s/[\/]+/\//g;

    # Let's open up our default route before we bother to see if users even exist
    return $routes{default}{callback}->($query,\&_render) unless -f "config/setup";

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
        return Trog::Routes::HTML::forbidden($query, \&_render);
    }

    # If it's just a file, serve it up
    my $alist = $env->{HTTP_ACCEPT_ENCODING} || '';
    $alist =~ s/\s//g;
    my @accept_encodings;
    @accept_encodings = split(/,/, $alist);
    my $deflate = grep { 'deflate' eq $_ } @accept_encodings;

    return _serve("www/$path", $env->{'psgi.streaming'}, $last_fetch, $deflate) if -f "www/$path";

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

    return Trog::Routes::HTML::notfound($query, \&_render) unless exists $routes{$path};
    return Trog::Routes::HTML::badrequest($query, \&_render) unless grep { $env->{REQUEST_METHOD} eq $_ } ($routes{$path}{method},'HEAD');

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
    $query->{acls} = Trog::Auth::acls4user($active_user) // [] if $active_user;

    $query->{user}         = $active_user;
    $query->{domain}       = $env->{HTTP_HOST};
    $query->{route}        = $env->{REQUEST_URI};
    $query->{route}        =~ s/\?\Q$env->{QUERY_STRING}\E//;
    $query->{scheme}       = $env->{'psgi.url_scheme'} // 'http';
    $query->{social_meta}  = 1;
    $query->{primary_post} = {};

    my $output =  $routes{$path}{callback}->($query, \&_render);
    return $output;
};

sub _serve ($path, $streaming=0, $last_fetch=0, $deflate=0) {
    my $mf = Mojo::File->new($path);
    my $ext = '.'.$mf->extname();
    my $ft;
    if ($ext) {
        $ft = Plack::MIME->mime_type($ext) if $ext;
        $ft ||= $extra_types{$ext} if exists $extra_types{$ext};
    }
    $ft ||= $content_types{plain};

    my @headers = ($ct => $ft);
    #TODO use static Cache-Control for everything but JS/CSS?
    push(@headers,$cc => $cache_control{revalidate});

    #TODO Return 304 unchanged for files that haven't changed since the requestor reports they last fetched
    my $mt = (stat($path))[9];
    my $sz = (stat(_))[7];
    my @gm = gmtime($mt);
    my $now_string = strftime( "%a, %d %b %Y %H:%M:%S GMT", @gm );
    my $code = $mt > $last_fetch ? 200 : 304;
    #XXX something broken about the above logic
    $code=200;

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
            return [ $code, \@headers, $fh];
        }

        #Compress everything less than 1MB
        push( @headers, "Content-Encoding" => "deflate" );
        my $dfh;
        IO::Compress::Deflate::deflate( $fh => \$dfh );
        print $IO::Compress::Deflate::DeflateError if $IO::Compress::Deflate::DeflateError;
        push( @headers, "Content-Length" => length($dfh) );
        return [ $code, \@headers, [$dfh]];
    }

    return [ 403, [$ct => $content_types{plain}], ["STAY OUT YOU RED MENACE"]];
}

sub _render ($template, $vars, @headers) {

    my $processor = Text::Xslate->new(
        path   => 'www/templates',
        header => ['header.tx'],
        footer => ['footer.tx'],
        function => {
            iso8601 => sub {
                my $t = shift;
                my $dt  = DateTime->from_epoch( epoch => $t );
                return $dt->iso8601;
            },
            strip_and_trunc => \&Trog::Utils::strip_and_trunc,
        },
    );

    #XXX default vars that need to be pulled from config
    $vars->{dir}       //= 'ltr';
    $vars->{lang}      //= 'en-US';
    $vars->{title}     //= 'tCMS';
    #XXX Need to have minification detection and so forth, use LESS
    $vars->{stylesheets}  //= [];
    #XXX Need to have minification detection, use Typescript
    $vars->{scripts} //= [];

    # Absolute-ize the paths for scripts & stylesheets
    @{$vars->{stylesheets}} = map { index($_, '/') == 0 ? $_ : "/$_" } @{$vars->{stylesheets}};
    @{$vars->{scripts}}     = map { index($_, '/') == 0 ? $_ : "/$_" } @{$vars->{scripts}};

    $vars->{contenttype} //= $content_types{html};
    $vars->{cachecontrol} //= $cache_control{revalidate};

    $vars->{code} ||= 200;

    push(@headers, $ct => $vars->{contenttype});
    push(@headers, $cc => $vars->{cachecontrol}) if $vars->{cachecontrol};

    my $body = $processor->render($template,$vars);
    $body = encode_utf8($body);

    #Return data in the event the caller does not support deflate
    if (!$vars->{deflate}) {
        push( @headers, "Content-Length" => length($body) );
        return [ $vars->{code}, \@headers, [$body]];
    }

    #Compress
    push( @headers, "Content-Encoding" => "deflate" );
    my $dfh;
    IO::Compress::Deflate::deflate( \$body => \$dfh );
    print $IO::Compress::Deflate::DeflateError if $IO::Compress::Deflate::DeflateError;
    push( @headers, "Content-Length" => length($dfh) );
    return [$vars->{code}, \@headers, [$dfh]];
}


