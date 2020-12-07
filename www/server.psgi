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

#Grab our custom routes
use lib 'lib';
use Trog::Routes::HTML;
use Trog::Routes::JSON;
use Trog::Auth;

# Troglodyne philosophy - simple as possible

# Import the routes
my %routes = %Trog::Routes::HTML::routes;
@routes{keys(%Trog::Routes::JSON::routes)} = values(%Trog::Routes::JSON::routes);

# Things we will actually produce from routes rather than just serving up files
my $ct = 'Content-type';
my %content_types = (
    plain => "$ct:text/plain;",
    html  => "$ct:text/html; charset=UTF-8",
    json  => "$ct:application/json;",
    blob  => "$ct:application/octet-stream;",
);

my $cc = 'Cache-control';
my %cache_control = (
    revalidate => "$cc: no-cache, max-age=0;",
    nocache    => "$cc: no-store;",
    static     => "$cc: public, max-age=604800, immutable",
);

=head2 $app

Dispatches requests based on %routes built above.

The dispatcher here does *not* do anything with the authn/authz data.  It sets those in the 'user' and 'acls' parameters of the query object passed to routes.

If a path passed is not a defined route (or regex route), but exists as a file under www/, it will be served up immediately.

=cut

my $app = sub {
    my $env = shift;

    my $last_fetch = 0;
    if ($env->{HTTP_IF_MODIFIED_SINCE}) {
        $last_fetch = DateTime::Format::HTTP->parse_datetime($env->{HTTP_IF_MODIFIED_SINCE})->epoch();
    }

    my $query = {};
    $query = URL::Encode::url_params_mixed($env->{QUERY_STRING}) if $env->{QUERY_STRING};
    my $path = $env->{PATH_INFO};

    # Let's open up our default route before we bother to see if users even exist
    return $routes{default}{callback}->($query,\&_render) unless -f "$ENV{HOME}/.tcms/setup";

    my $cookies = {};
    if ($env->{HTTP_COOKIE}) {
        $cookies = CGI::Cookie->parse($env->{HTTP_COOKIE});
    }

    my ($active_user,$user_id) = ('','');
    if (exists $cookies->{tcmslogin}) {
         ($active_user,$user_id) = Trog::Auth::session2user($cookies->{tcmslogin}->value);
    }

    #Disallow any paths that are naughty ( starman auto-removes .. up-traversal)
    if (index($path,'/templates') == 0 || $path =~ m/.*\.psgi$/i ) {
        return Trog::Routes::HTML::forbidden($query, \&_render);
    }

    # If it's just a file, serve it up
    return _serve("www/$path", $env->{'psgi.streaming'}, $last_fetch) if -f "www/$path";

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

    $query->{user}   = $active_user;
    return Trog::Routes::HTML::notfound($query, \&_render) unless exists $routes{$path};
    return Trog::Routes::HTML::badrequest($query, \&_render) unless $routes{$path}{method} eq $env->{REQUEST_METHOD};

    @{$query}{keys(%{$routes{$path}{'data'}})} = values(%{$routes{$path}{'data'}}) if ref $routes{$path}{'data'} eq 'HASH' && %{$routes{$path}{'data'}};

    #Actually parse the POSTDATA and dump it into the QUERY object if this is a POST
    if ($env->{REQUEST_METHOD} eq 'POST') {

        my $body = HTTP::Body->new( $env->{CONTENT_TYPE}, $env->{CONTENT_LENGTH} );
        my $len = $env->{CONTENT_LENGTH};
        while ( $len ) {
            read($env->{'psgi.input'}, my $buf, ($len < 8192) ? 8192 : $len );
            $len -= length($buf);
            $body->add($buf);
        }

        @$query{keys(%{$body->param})}  = values(%{$body->param});
        @$query{keys(%{$body->upload})} = values(%{$body->upload});
    }

    #Set various things we don't want overridden
    $query->{acls} = Trog::Auth::acls4user($user_id) // [] if $user_id;

    $query->{user}   = $active_user;
    $query->{domain} = $env->{HTTP_HOST};
    $query->{route}  = $env->{REQUEST_URI};
    $query->{scheme} = $env->{'psgi.url_scheme'} // 'http';

    my $output =  $routes{$path}{callback}->($query, \&_render);
    return $output;
};

sub _serve ($path, $streaming=0, $last_fetch=0) {
    my $mf = Mojo::File->new($path);
    my $ext = '.'.$mf->extname();
    my $ft;
    $ft = Plack::MIME->mime_type($ext) if $ext;
    $ft = "$ct:$ft;" if $ft;
    $ft ||= $content_types{plain};

    my @headers = ($ft);

    #TODO use static Cache-Control for everything but JS/CSS?
    push(@headers,$cache_control{revalidate});

    #TODO Return 304 unchanged for files that haven't changed since the requestor reports they last fetched
    my $mt = (stat($path))[9];
    my @gm = gmtime($mt);
    my $now_string = strftime( "%a, %d %b %Y %H:%M:%S GMT", @gm );
    my $code = $mt > $last_fetch ? 200 : 304;
    #XXX something broken about the above logic
    $code=200;

    push(@headers, "Last-Modified: $now_string\n");

    my $h = join("\n",@headers);
    if (open(my $fh, '<', $path)) {
        return sub {
            my $responder = shift;
            my $writer = $responder->([ $code, [$h]]);
            while ( read($fh, my $buf, 102400) ) {
                $writer->write($buf);
            }
            close $fh;
            $writer->close;
        } if $streaming;

        return [ $code, [$h], $fh];
    }
    return [ 403, [$content_types{plain}], ["STAY OUT YOU RED MENACE"]];
}

sub _render ($template, $vars, @headers) {

    my $processor = Text::Xslate->new(
        path   => 'www/templates',
        header => ['header.tx'],
        footer => ['footer.tx'],
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

    push(@headers, $vars->{contenttype});
    push(@headers, $vars->{cachecontrol}) if $vars->{cachecontrol};
    my $h = join("\n",@headers);

    my $body = $processor->render($template,$vars);
    return [$vars->{code}, [$h], [encode_utf8($body)]];
}


