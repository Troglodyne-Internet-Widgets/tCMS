package Trog::Routes::HTML;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use File::Touch();

use Trog::Config;
use Trog::Data;

my $conf = Trog::Config::get();
my $template_dir = 'www/templates';
my $theme_dir;
$theme_dir = "themes/".$conf->param('general.theme') if $conf->param('general.theme') && -d "www/themes/".$conf->param('general.theme');

use lib 'www';

our $landing_page  = 'default.tx';
our $htmltitle     = 'title.tx';
our $midtitle      = 'midtitle.tx';
our $rightbar      = 'rightbar.tx';
our $leftbar       = 'leftbar.tx';
our $footbar       = 'footbar.tx';

our %routes = (
    default => {
        callback => \&Trog::Routes::HTML::setup,
    },
    '/' => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::index,
    },
# This should only be enabled to debug
#    '/setup' => {
#        method   => 'GET',
#        callback => \&Trog::Routes::HTML::setup,
#    },
    '/login' => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::login,
    },
    '/auth' => {
        method   => 'POST',
        nostatic => 1,
        callback => \&Trog::Routes::HTML::login,
    },
    '/config' => {
        method   => 'GET',
        auth     => 1,
        callback => \&Trog::Routes::HTML::config,
    },
    '/config/save' => {
        method   => 'POST',
        auth     => 1,
        callback => \&Trog::Routes::HTML::config_save,
    },
    '/post' => {
        method   => 'GET',
        auth     => 1,
        callback => \&Trog::Routes::HTML::post,
    },
    '/post/save' => {
        method   => 'POST',
        auth     => 1,
        callback => \&Trog::Routes::HTML::post,
    },
    '/post/(.*)' => {
        method   => 'GET',
        auth     => 1,
        callback => \&Trog::Routes::HTML::post,
        captures => ['id'],
    },
    '/posts/(.*)' => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::posts,
        captures => ['id'],
    },
    '/posts' => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::posts,
    },
    '/profile' => {
        method   => 'POST',
        auth     => 1,
        callback => \&Trog::Routes::HTML::profile,
    },
    '/themeclone' => {
        method   => 'POST',
        auth     => 1,
        callback => \&Trog::Routes::HTML::themeclone,
    },
    '/sitemap', => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::sitemap,
    },
    '/sitemap_index.xml', => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::sitemap,
        data     => { xml => 1 },
    },
    '/sitemap_index.xml.gz', => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::sitemap,
        data     => { xml => 1, compressed => 1 },
    },
    '/sitemap/static.xml' => {
        method => 'GET',
        callback => \&Trog::Routes::HTML::sitemap,
        data     => { xml => 1, map => 'static' },
    },
    '/sitemap/static.xml.gz' => {
        method => 'GET',
        callback => \&Trog::Routes::HTML::sitemap,
        data     => { xml => 1, compressed => 1, map => 'static' },
    },
    '/sitemap/(.*).xml' => {
        method => 'GET',
        callback => \&Trog::Routes::HTML::sitemap,
        data     => { xml => 1 },
        captures => ['map'],
    },
    '/sitemap/(.*).xml.gz' => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::sitemap,
        data     => { xml => 1, compressed => 1},
        captures => ['map'],
    },
    '/robots.txt' => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::robots,
    },
    '/humans.txt' => {
        method => 'GET',
        callback => \&Trog::Routes::HTML::posts,
        data     => { tag => ['about'] },
    },
);

# Build aliases for /posts and /post with extra data
my @post_aliases = qw{news blog image video audio about files series};
@routes{map { "/$_" } @post_aliases} = map { my %copy = %{$routes{'/posts'}}; $copy{data}{tag} = [$_]; \%copy } @post_aliases;

#TODO clean this up so we don't need _build_post_type
@routes{map { "/post/$_" } qw{image video audio files}} = map { my %copy = %{$routes{'/post'}}; $copy{data}{tag} = [$_]; $copy{data}{type} = 'file'; \%copy } qw{image video audio files};
$routes{'/post/news'}    = { method => 'GET', auth => 1, callback => \&Trog::Routes::HTML::post, data => { tag => ['news'],    type => 'microblog' } };
$routes{'/post/blog'}    = { method => 'GET', auth => 1, callback => \&Trog::Routes::HTML::post, data => { tag => ['blog'],    type => 'blog'      } };
$routes{'/post/about'}   = { method => 'GET', auth => 1, callback => \&Trog::Routes::HTML::post, data => { tag => ['about'],   type => 'profile'   } };
$routes{'/post/series'}  = { method => 'GET', auth => 1, callback => \&Trog::Routes::HTML::post, data => { tag => ['series'],  type => 'series'    } };

# Build aliases for /posts/(.*) and /post/(.*) with extra data
@routes{map { "/$_/(.*)" } @post_aliases} = map { my %copy = %{$routes{'/posts/(.*)'}}; \%copy } @post_aliases;
@routes{map { "/$_/(.*)" } @post_aliases} = map { my %copy = %{$routes{'/post/(.*)'}}; \%copy } @post_aliases;

# Grab theme routes
my $themed = 0;
if ($theme_dir) {
    my $theme_mod = "$theme_dir/routes.pm";
    if (-f "www/$theme_mod" ) {
        require $theme_mod;
        @routes{keys(%Theme::routes)} = values(%Theme::routes);
        $themed = 1;
    }
}

sub robots ($query, $input, $render_cb) {
    my $processor = Text::Xslate->new(
        path   => $template_dir,
    );
    return [200, ["Content-type:text/plain\n"],[$processor->render('robots.tx', { domain => $query->{domain} })]];
}

sub index ($query, $input, $render_cb, $content = '', $i_styles = []) {
    $query->{theme_dir}  = $theme_dir || '';

    my $processor = Text::Xslate->new(
        path   => $template_dir,
    );

    my $t_processor;
    $t_processor = Text::Xslate->new(
        path =>  "www/$theme_dir/templates",
    ) if $theme_dir;

    $content ||= _pick_processor($rightbar,$processor,$t_processor)->render($landing_page,$query);

    my @styles = ('/styles/avatars.css'); #TODO generate file for users
    if ($theme_dir) {
        unshift(@styles, _themed_style("screen.css"))    if -f 'www/'._themed_style("screen.css");
        unshift(@styles, _themed_style("structure.css")) if -f 'www/'._themed_style("structure.css");
    }
    push( @styles, @$i_styles);

    #TODO allow theming of print css

    my $search_info = Trog::Data->new($conf);

    return $render_cb->('index.tx',{
        code        => $query->{code},
        user        => $query->{user},
        search_lang => $search_info->{lang},
        search_help => $search_info->{help},
        route       => $query->{route},
        theme_dir   => $theme_dir,
        content     => $content,
        title       => $conf->param('general.title'), #TODO control in theme instead
        htmltitle   => _pick_processor("templates/$htmltitle" ,$processor,$t_processor)->render($htmltitle,$query),
        midtitle    => _pick_processor("templates/$midtitle" ,$processor,$t_processor)->render($midtitle,$query),
        rightbar    => _pick_processor("templates/$rightbar" ,$processor,$t_processor)->render($rightbar,$query),
        leftbar     => _pick_processor("templates/$leftbar"  ,$processor,$t_processor)->render($leftbar,$query),
        footbar     => _pick_processor("templates/$footbar"  ,$processor,$t_processor)->render($footbar,$query),
        stylesheets => \@styles,
    });
}

=head1 ADMIN ROUTES

These are things that issue returns other than 200, and are not directly accessible by users via any defined route.

=head2 notfound, forbidden, badrequest

Implements the 4XX status codes.  Override templates named the same for theming this.

=cut

sub _generic_route ($rname, $code, $title, $query,$input,$render_cb) {
    $query->{code} = $code;

    my $processor = Text::Xslate->new(
        path   => _dir_for_resource("$rname.tx"),
    );

    my $styles = _build_themed_styles("$rname.css");
    my $content = $processor->render("$rname.tx", {
        title    => $title,
        route    => $query->{route},
        user     => $query->{user},
        styles   => $styles,
    });
    return Trog::Routes::HTML::index($query, $input, $render_cb, $content, $styles);
}

sub notfound (@args) {
    return _generic_route('notfound',404,"Return to sender, Address unknown", @args);
}

sub forbidden (@args) {
    return _generic_route('forbidden', 403, "STAY OUT YOU RED MENACE", @args);
}

sub badrequest (@args) {
    return _generic_route('badrequest', 400, "Bad Request", @args);
}

# TODO Rate limiting route

=head1 NORMAL ROUTES

These are expected to either return a 200, or redirect to something which does.

=head2 setup

One time setup page; should only display to the first user to visit the site which we presume to be the administrator.

=cut

sub setup ($query, $input, $render_cb) {
    File::Touch::touch("$ENV{HOME}/.tcms/setup");
    return $render_cb->('notconfigured.tx', {
        title => 'tCMS Requires Setup to Continue...',
        stylesheets => _build_themed_styles('notconfigured.css'),
    });
}

=head2 login

Sets the user cookie if the provided user exists, or sets up the user as an admin with the provided credentials in the event that no users exist.

=cut

sub login ($query, $input, $render_cb) {

    # Redirect if we actually have a logged in user.
    # Note to future me -- this user value is overwritten explicitly in server.psgi.
    # If that ever changes, you will die
    $query->{to} //= '/config';
    if ($query->{user}) {
        return $routes{$query->{to}}{callback}->($query,$input,$render_cb);
    }

    #Set the cookiez and issue a 302 back to ourselves if we have good creds
    my $postdata = _input2postdata($input);

    #Check and see if we have no users.  If so we will just accept whatever creds are passed.
    my $hasusers = -f "$ENV{HOME}/.tcms/has_users";
    my $btnmsg = $hasusers ? "Log In" : "Register";

    my @headers;
    if ($postdata->{username} && $postdata->{password}) {
        if (!$hasusers) {
            # Make the first user
            Trog::Auth::useradd($postdata->{username}, $postdata->{password}, ['admin'] );
            File::Touch::touch("$ENV{HOME}/.tcms/has_users");
        }

        $query->{failed} = 1;
        my $cookie = Trog::Auth::mksession($postdata->{username}, $postdata->{password});
        if ($cookie) {
            # TODO secure / sameSite cookie to kill csrf, maybe do rememberme with Expires=~0
            @headers = (
                "Set-Cookie: tcmslogin=$cookie; HttpOnly",
            );
            $query->{failed} = 0;
        }
    }

    $query->{failed} //= -1;
    return $render_cb->('login.tx', {
        title         => 'tCMS 2 ~ Login',
        to            => $query->{to},
        failure => int( $query->{failed} ),
        message => int( $query->{failed} ) < 1 ? "Login Successful, Redirecting..." : "Login Failed.",
        btnmsg        => $btnmsg,
        stylesheets   => _build_themed_styles('login.css'),
    }, @headers);
}

=head2 config

Renders the configuration page, or redirects you back to the login page.

=cut

sub config ($query, $input, $render_cb) {
    if (!$query->{user}) {
        $query->{to} = '/config';
        return login($query,$input,$render_cb);
    }
    #NOTE: we are relying on this to skip the ACL check with 'admin', this may not be viable in future?
    return forbidden($query, $input, $render_cb) unless grep { $_ eq 'admin' } @{$query->{acls}};

    my $css   = _build_themed_styles('config.css');
    my $js    = _build_themed_scripts('post.js');

    $query->{failure} //= -1;

    return $render_cb->('config.tx', {
        title              => 'Configure tCMS',
        stylesheets        => $css,
        scripts            => $js,
        themes             => _get_themes(),
        data_models        => _get_data_models(),
        current_theme      => $conf->param('general.theme') // '',
        current_data_model => $conf->param('general.data_model') // 'DUMMY',
        message     => $query->{message},
        failure     => $query->{failure},
        to          => '/config',
    });
}

sub _get_themes {
    my $dir = 'www/themes';
    opendir(my $dh, $dir) || die "Can't opendir $dir: $!";
    my @tdirs = grep { !/^\./ && -d "$dir/$_" } readdir($dh);
    closedir $dh;
    return \@tdirs;
}

sub _get_data_models {
    my $dir = 'lib/Trog/Data';
    opendir(my $dh, $dir) || die "Can't opendir $dir: $!";
    my @dmods = map { s/\.pm$//g; $_ } grep { /\.pm$/ && -f "$dir/$_" } readdir($dh);
    closedir $dh;
    return \@dmods
}

=head2 config_save

Implements /config/save route.  Saves what little configuration we actually use to ~/.tcms/tcms.conf

=cut

sub config_save ($query, $input, $render_cb) {
    my $postdata = _input2postdata($input);
    $conf->param( 'general.theme',      $postdata->{theme} )      if defined $postdata->{theme};
    $conf->param( 'general.data_model', $postdata->{data_model} ) if $postdata->{data_model};

    $query->{failure} = 1;
    $query->{message} = "Failed to save configuration!";
    if ($conf->save($Trog::Config::home_config)) {
        $query->{failure} = 0;
        $query->{message} = "Configuration updated succesfully.";
    }
    # TODO we need to soft-restart the server at this point.  Maybe we can just hot-load config on each page when we get to have static renders?  Probably not worth the perf hit for paywall users.
    return config($query, $input, $render_cb);
}

# TODO actually do stuff
sub profile ($query, $input, $render_cb) {
    return config($query, $input, $render_cb);
}

=head2 themeclone

Clone a theme by copying a directory.

=cut

sub themeclone ($query, $input, $render_cb) {
    my $postdata = _input2postdata($input);
    my ($theme, $newtheme) = ($postdata->{theme},$postdata->{newtheme});

    my $themedir = 'www/themes';

    $query->{failure} = 1;
    $query->{message} = "Failed to clone theme '$theme' as '$newtheme'!";
    require File::Copy::Recursive;
    if ($theme && $newtheme && File::Copy::Recursive::dircopy( "$themedir/$theme", "$themedir/$newtheme" )) {
        $query->{failure} = 0;
        $query->{message} = "Successfully cloned theme '$theme' as '$newtheme'.";
    }
    return config($query, $input, $render_cb);
}

=head2 post

Display the route for making new posts.

=cut

sub post ($query, $input, $render_cb) {
    if (!$query->{user}) {
        $query->{to} = '/post';
        return login($query,$input,$render_cb);
    }
    return forbidden($query, $input, $render_cb) unless grep { $_ eq 'admin' } @{$query->{acls}};

    my $tags  = _coerce_array($query->{tag});
    my $posts = _post_helper($query, $tags, $query->{acls});
    my $css   = _build_themed_styles('post.css');
    my $js    = _build_themed_scripts('post.js');
    push(@$css, '/styles/avatars.css');

    return $render_cb->('post.tx', {
        title       => 'New Post',
        post_visibilities => ['public', 'private', 'unlisted'],
        stylesheets => $css,
        scripts     => $js,
        posts       => $posts,
        can_edit    => 1,
        types       => [qw{microblog blog file series profile}],
        route       => '/posts',
        category    => '/posts',
        page        => int($query->{page} || 1),
        limit       => int($query->{limit} || 1),
        sizes       => [25,50,100],
        id          => $query->{id},
        acls        => _post_helper({}, ['series'], $query->{acls}),
        edittype    => $query->{type} || 'microblog',
    });
}

#TODO actually do stuff
sub post_save ($query, $input, $render_cb) {
    return post($query, $input, $render_cb);
}

=head2 posts

Display multi or single posts, supports RSS and pagination.

=cut

sub posts ($query, $input, $render_cb) {
    my $tags = _coerce_array($query->{tag});

    #TODO If we have a direct ID query, we should show unlisted videos as well as public ones IFF they have a valid campaign ID attached to query
    push(@{$query->{acls}}, 'public');
    my $posts = _post_helper($query, $tags, $query->{acls});

    return notfound($query,$input,$render_cb) unless @$posts;

    my $fmt = $query->{format} || '';
    return _rss($query,$posts) if $fmt eq 'rss';

    my $processor = Text::Xslate->new(
        path   => _dir_for_resource('posts.tx'),
    );

    my $styles = _build_themed_styles('posts.css');

    my $content = $processor->render('posts.tx', {
        title    => "Posts tagged @$tags",
        posts    => $posts,
        route    => $query->{route},
        page     => int($query->{page} || 1),
        limit    => int($query->{limit} || 1),
        sizes    => [25,50,100],
        rss      => !$query->{id},
        tiled    => scalar(grep { $_ eq $query->{route} } qw{/files /audio /video /image /series}),
        category => $themed ? Theme::path_to_tile($query->{route}) : $query->{route},
    });
    return Trog::Routes::HTML::index($query, $input, $render_cb, $content, $styles);
}

sub _post_helper ($query, $tags, $acls) {
    state $data = Trog::Data->new($conf);
    return $data->get(
        page  => int($query->{page} || 1),
        limit => int($query->{limit} || 25),
        tags  => $tags,
        acls  => $acls,
        like  => $query->{like},
        id    => $query->{id},
    );
}

=head2 sitemap

Return the sitemap index unless the static or a set of dynamic routes is requested.
We have a maximum of 99,990,000 posts we can make under this model
As we have 10,000 * 10,000 posts which are indexable via the sitemap format.
1 top level index slot (10k posts) is taken by our static routes, the rest will be /posts.

Passing ?xml=1 will result in an appropriate sitemap.xml instead.
This is used to generate the static sitemaps as expected by search engines.

Passing compressed=1 will gzip the output.

=cut

sub sitemap ($query, $input, $render_cb) {

    my (@to_map, $is_index, $route_type);
    my $warning = '';
    $query->{map} //= '';
    if ($query->{map} eq 'static') {
        # Return the map of static routes
        $route_type = 'Static Routes';
        @to_map = grep { !defined $routes{$_}->{captures} && $_ !~ m/^default|login|auth$/ && !$routes{$_}->{auth} } keys(%routes);
    } elsif ( !$query->{map} ) {
        # Return the index instead
        @to_map = ('static');
        my $data = Trog::Data->new($conf);
        my $tot = $data->total_posts();
        my $size = 50000;
        my $pages = int($tot / $size) + (($tot % $size) ? 1 : 0);

        # Truncate pages at 10k due to standard
        my $clamped = $pages > 49999 ? 49999 : $pages;
        $warning = "More posts than possible to represent in sitemaps & index!  Old posts have been truncated." if $pages > 49999;

        foreach my $page ($clamped..1) {
            push(@to_map, "$page");
        }
        $is_index = 1;
    } else {
        $route_type = "Posts: Page $query->{map}";
        # Return the map of the particular range of dynamic posts
        $query->{limit} = 50000;
        $query->{page} = $query->{map};
        @to_map = @{_post_helper($query, [], ['public'])};
    }

    if ( $query->{xml} ) {
        my $sm;
        my $xml_date = time();
        my $fmt = "xml";
        $fmt .= ".gz" if $query->{compressed};
        if ( !$query->{map}) {
            require WWW::SitemapIndex::XML;
            $sm = WWW::SitemapIndex::XML->new();
            foreach my $url (@to_map) {
                $sm->add(
                    loc     => "http://$query->{domain}/sitemap/$url.$fmt",
                    lastmod => $xml_date,
                );
            }
        } else {
            require WWW::Sitemap::XML;
            $sm = WWW::Sitemap::XML->new();
            my $changefreq = $query->{map} eq 'static' ? 'monthly' : 'daily';
            foreach my $url (@to_map) {
                my $true_uri = "http://$query->{domain}$url";
                $true_uri = "http://$query->{domain}/posts/$url->{id}" if ref $url eq 'HASH';
                my %data = (
                    loc        => $true_uri,
                    lastmod    => $xml_date,
                    mobile     => 1,
                    changefreq => $changefreq,
                    priority   => 1.0,
                );
                #TODO add video & preview image if applicable
                $sm->add(%data);
            }
        }
        my $xml = $sm->as_xml();
        require IO::String;
        my $buf = IO::String->new();
        my $ct = 'application/xml';
        $xml->toFH($buf, 0);
        seek $buf, 0, 0;

        if ($query->{compressed}) {
            require IO::Compress::Gzip;
            my $compressed = IO::String->new();
            IO::Compress::Gzip::gzip($buf => $compressed);
            $ct = 'application/gzip';
            $buf = $compressed;
            seek $compressed, 0, 0;
        }
        return [200,["Content-type:$ct\n"], $buf];
    }

    @to_map = sort @to_map unless $is_index;
    my $processor = Text::Xslate->new(
        path   => _dir_for_resource('sitemap.tx'),
    );

    my $styles = _build_themed_styles('sitemap.css');

    my $content = $processor->render('sitemap.tx', {
        title      => "Site Map",
        to_map     => \@to_map,
        is_index   => $is_index,
        route_type => $route_type,
        route      => $query->{route},
    });

    return Trog::Routes::HTML::index($query,$input,$render_cb,$content,$styles);
}

sub _rss ($query,$posts) {
    require XML::RSS;
    my $rss = XML::RSS->new (version => '2.0');
    my $now = DateTime->from_epoch(epoch => time());
    $rss->channel(
        title          => "$query->{domain}",
        link           => "http://$query->{domain}/$query->{route}?format=rss",
        language       => 'en', #TODO localization
        description    => 'tCMS website', #TODO make configurable
        pubDate        => $now, #TODO format
        lastBuildDate  => $now, #TODO format
    );
 
    #TODO configurability
    $rss->image(
        title       => $query->{domain},
        url         => "http://$query->{domain}/img/icon/tcms.svg",
        link        => "http://$query->{domain}",
        width       => 88,
        height      => 31,
        description => 'tCMS image'
    );
 
    foreach my $post (@$posts) {
        my $url = "http://$query->{domain}/posts/$post->{id}";
        $rss->add_item(
            title       => $post->{title},
            permaLink   => $url,
            link        => $url,
            enclosure   => { url => $url, type=>"text/html" },
            description => "<![CDATA[$post->{data}]]>",
            pubDate     => DateTime->from_epoch(epoch => $post->{created} ), #TODO format like Thu, 23 Aug 1999 07:00:00 GMT
            author      => $post->{user}, #TODO translate to "email (user)" format
        );
    }

    return [200, ["Content-type: application/rss+xml\n"], [$rss->as_string]];
}

sub _input2postdata ($input) {
    #Set the cookiez and issue a 302 back to ourselves if we have good creds
    my ($slurpee,$postdata) = ('',{});
    while (<$input>) { $slurpee .= $_ }
    $postdata = URL::Encode::url_params_mixed($slurpee) if $slurpee;
    return $postdata;
}

# Deal with Params which may or may not be arrays
sub _coerce_array ($param) {
    my $p = $param || [];
    $p = [$param] if $param && (ref $param ne 'ARRAY');
    return $p;
}

sub _build_themed_styles ($style) {
    my @styles = ("/styles/$style");
    my $ts = _themed_style($style);
    push(@styles, $ts) if $theme_dir && -f "www/$ts";
    return \@styles;
}

sub _build_themed_scripts ($script) {
    my @scripts = ("/scripts/$script");
    my $ts = _themed_style($script);
    push(@scripts, $ts) if $theme_dir && -f "www/$ts";
    return \@scripts;
}

sub _pick_processor($file, $normal, $themed) {
    return _dir_for_resource($file) eq $template_dir ? $normal : $themed;
}

# Pick appropriate dir based on whether theme override exists
sub _dir_for_resource ($resource) {
    return $theme_dir && -f "www/$theme_dir/$resource" ? $theme_dir : $template_dir;
}

sub _themed_style ($resource) {
    return _dir_for_resource("styles/$resource")."/styles/$resource";
}

sub _themed_script ($resource) {
    return _dir_for_resource("scripts/$resource")."/scripts/$resource";
}

1;
