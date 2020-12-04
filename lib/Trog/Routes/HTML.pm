package Trog::Routes::HTML;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use File::Touch();
use List::Util();
use Capture::Tiny qw{capture};

use Trog::Config;
use Trog::Data;

my $conf = Trog::Config::get();
my $template_dir = 'www/templates';
my $theme_dir = '';
$theme_dir = "themes/".$conf->param('general.theme') if $conf->param('general.theme') && -d "www/themes/".$conf->param('general.theme');
my $td = $theme_dir ? "/$theme_dir" : '';

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
    '/logout' => {
        method => 'GET',
        callback => \&Trog::Routes::HTML::logout,
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
        callback => \&Trog::Routes::HTML::post_save,
    },
    '/post/delete' => {
        method   => 'POST',
        auth     => 1,
        callback => \&Trog::Routes::HTML::post_delete,
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
        method   => 'GET',
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
        method    => 'GET',
        callback  => \&Trog::Routes::HTML::robots,
    },
    '/humans.txt' => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::posts,
        data     => { tag => ['about'] },
    },
    '/styles/avatars.css' => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::avatars,
        data     => { tag => ['about'] },
    },
    '/users/(.*)' => {
        method => 'GET',
        callback => \&Trog::Routes::HTML::users,
        captures => ['username'],
    },
    '/manual' => {
        method => 'GET',
        auth   => 1,
        callback => \&Trog::Routes::HTML::manual,
    },
    '/lib/(.*)' => {
        method => 'GET',
        auth   => 1,
        captures => ['module'],
        callback => \&Trog::Routes::HTML::manual,
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
@routes{map { "/post/$_/(.*)" } @post_aliases} = map { my %copy = %{$routes{'/post/(.*)'}}; \%copy } @post_aliases;

# /series/$ID is a bit of a special case, it's actuallly gonna need special processing
$routes{'/series/(.*)'} = { method => 'GET', auth => 1, callback => \&Trog::Routes::HTML::series, captures => ['id'] };

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

=head1 PRIMARY ROUTE

=head2 index

Implements the primary route used by all pages not behind auth.
Most subsequent functions simply pass content to this function.

=cut

sub index ($query,$render_cb, $content = '', $i_styles = []) {
    $query->{theme_dir}  = $td;

    my $processor = Text::Xslate->new(
        path   => $template_dir,
    );

    my $t_processor;
    $t_processor = Text::Xslate->new(
        path =>  "www/$theme_dir/templates",
    ) if $theme_dir;

    $content ||= _pick_processor($rightbar,$processor,$t_processor)->render($landing_page,$query);

    my @styles = ('/styles/avatars.css');
    if ($theme_dir) {
        unshift(@styles, _themed_style("screen.css"))    if -f 'www/'._themed_style("screen.css");
        unshift(@styles, _themed_style("structure.css")) if -f 'www/'._themed_style("structure.css");
    }
    push( @styles, @$i_styles );

    #TODO allow theming of print css

    my $search_info = Trog::Data->new($conf);

    return $render_cb->('index.tx', {
        code        => $query->{code},
        user        => $query->{user},
        search_lang => $search_info->lang(),
        search_help => $search_info->help(),
        route       => $query->{route},
        theme_dir   => $td,
        content     => $content,
        title       => $query->{title} // $Theme::default_title // 'tCMS',
        htmltitle   => _pick_processor("templates/$htmltitle" ,$processor,$t_processor)->render($htmltitle,$query),
        midtitle    => _pick_processor("templates/$midtitle"  ,$processor,$t_processor)->render($midtitle,$query),
        rightbar    => _pick_processor("templates/$rightbar"  ,$processor,$t_processor)->render($rightbar,$query),
        leftbar     => _pick_processor("templates/$leftbar"   ,$processor,$t_processor)->render($leftbar,$query),
        footbar     => _pick_processor("templates/$footbar"   ,$processor,$t_processor)->render($footbar,$query),
        stylesheets => \@styles,
    });
}

=head1 ADMIN ROUTES

These are things that issue returns other than 200, and are not directly accessible by users via any defined route.

=head2 notfound, forbidden, badrequest

Implements the 4XX status codes.  Override templates named the same for theming this.

=cut

sub _generic_route ($rname, $code, $title, $query, $render_cb) {
    $query->{code} = $code;

    my $processor = Text::Xslate->new(
        path   => _dir_for_resource("$rname.tx"),
    );

    $query->{title} = $title;
    my $styles = _build_themed_styles("$rname.css");
    my $content = $processor->render("$rname.tx", {
        title    => $title,
        route    => $query->{route},
        user     => $query->{user},
        styles   => $styles,
    });
    return Trog::Routes::HTML::index($query, $render_cb, $content, $styles);
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

=head2 robots

Return an appropriate robots.txt

=cut

sub robots ($query, $render_cb) {
    my $processor = Text::Xslate->new(
        path   => $template_dir,
    );
    return [200, ["Content-type:text/plain\n"],[$processor->render('robots.tx', { domain => $query->{domain} })]];
}

=head2 setup

One time setup page; should only display to the first user to visit the site which we presume to be the administrator.

=cut

sub setup ($query, $render_cb) {
    File::Touch::touch("$ENV{HOME}/.tcms/setup");
    return $render_cb->('notconfigured.tx', {
        title => 'tCMS Requires Setup to Continue...',
        stylesheets => _build_themed_styles('notconfigured.css'),
    });
}

=head2 login

Sets the user cookie if the provided user exists, or sets up the user as an admin with the provided credentials in the event that no users exist.

=cut

sub login ($query, $render_cb) {

    # Redirect if we actually have a logged in user.
    # Note to future me -- this user value is overwritten explicitly in server.psgi.
    # If that ever changes, you will die
    $query->{to} //= $query->{route};
    $query->{to} = '/config' if $query->{to} eq '/login';
    if ($query->{user}) {
        return $routes{$query->{to}}{callback}->($query,$render_cb);
    }

    #Check and see if we have no users.  If so we will just accept whatever creds are passed.
    my $hasusers = -f "$ENV{HOME}/.tcms/has_users";
    my $btnmsg = $hasusers ? "Log In" : "Register";

    my @headers;
    if ($query->{username} && $query->{password}) {
        if (!$hasusers) {
            # Make the first user
            Trog::Auth::useradd($query->{username}, $query->{password}, ['admin'] );
            File::Touch::touch("$ENV{HOME}/.tcms/has_users");
        }

        $query->{failed} = 1;
        my $cookie = Trog::Auth::mksession($query->{username}, $query->{password});
        if ($cookie) {
            # TODO secure / sameSite cookie to kill csrf, maybe do rememberme with Expires=~0
            my $secure = '';
            $secure = '; Secure' if $query->{scheme} eq 'https';
            @headers = (
                "Set-Cookie: tcmslogin=$cookie; HttpOnly; SameSite=Strict$secure",
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
        theme_dir     => $td,
    }, @headers);
}

=head2 logout

Deletes your users' session and opens the login page.

=cut

sub logout ($query, $render_cb) {
    Trog::Auth::killsession($query->{user}) if $query->{user};
    delete $query->{user};
    $query->{to} = '/config';
    return login($query,$render_cb);
}

=head2 config

Renders the configuration page, or redirects you back to the login page.

=cut

sub config ($query, $render_cb) {
    if (!$query->{user}) {
        return login($query,$render_cb);
    }
    #NOTE: we are relying on this to skip the ACL check with 'admin', this may not be viable in future?
    return forbidden($query, $render_cb) unless grep { $_ eq 'admin' } @{$query->{acls}};

    my $css   = _build_themed_styles('config.css');
    my $js    = _build_themed_scripts('post.js');

    $query->{failure} //= -1;

    return $render_cb->('config.tx', {
        title              => 'Configure tCMS',
        theme_dir          => $td,
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

sub config_save ($query, $render_cb) {
    $conf->param( 'general.theme',      $query->{theme} )      if defined $query->{theme};
    $conf->param( 'general.data_model', $query->{data_model} ) if $query->{data_model};

    $query->{failure} = 1;
    $query->{message} = "Failed to save configuration!";
    if ($conf->write($Trog::Config::home_cfg)) {
        $query->{failure} = 0;
        $query->{message} = "Configuration updated succesfully.";
    }
    #Get the PID of the parent port using lsof, send HUP
    my $parent = getppid;
    kill 'HUP', $parent;

    return config($query, $render_cb);
}

=head2 themeclone

Clone a theme by copying a directory.

=cut

sub themeclone ($query, $render_cb) {
    my ($theme, $newtheme) = ($query->{theme},$query->{newtheme});

    my $themedir = 'www/themes';

    $query->{failure} = 1;
    $query->{message} = "Failed to clone theme '$theme' as '$newtheme'!";
    require File::Copy::Recursive;
    if ($theme && $newtheme && File::Copy::Recursive::dircopy( "$themedir/$theme", "$themedir/$newtheme" )) {
        $query->{failure} = 0;
        $query->{message} = "Successfully cloned theme '$theme' as '$newtheme'.";
    }
    return config($query, $render_cb);
}

=head2 post

Display the route for making new posts.

=cut

sub post ($query, $render_cb) {
    if (!$query->{user}) {
        return login($query, $render_cb);
    }
    $query->{acls} = _coerce_array($query->{acls});
    return forbidden($query, $render_cb) unless grep { $_ eq 'admin' } @{$query->{acls}};

    my $tags  = _coerce_array($query->{tag});
    my @posts = _post_helper($query, $tags, $query->{acls});
    my $css   = _build_themed_styles('post.css');
    my $js    = _build_themed_scripts('post.js');
    push(@$css, '/styles/avatars.css');
    my @acls  = _post_helper({}, ['series'], $query->{acls});

    my $app = 'file';
    if ($query->{route}) {
        $app = 'image' if $query->{route} =~ m/image$/;
        $app = 'video' if $query->{route} =~ m/video$/;
        $app = 'audio' if $query->{route} =~ m/audio$/;
    }

    #Filter displaying acl/visibility tags
    my @visibuddies = qw{public unlisted private};
    foreach my $post (@posts) {
        @{$post->{tags}} = grep { my $tag = $_; !grep { $tag eq $_ } (@visibuddies, map { $_->{aclname} } @acls ) } @{$post->{tags}};
    }

    my $limit = int($query->{limit} || 25);

    return $render_cb->('post.tx', {
        title       => 'New Post',
        theme_dir   => $td,
        to          => $query->{to},
        failure     => $query->{failure} // -1,
        message     => $query->{message},
        post_visibilities => \@visibuddies,
        stylesheets => $css,
        scripts     => $js,
        posts       => \@posts,
        can_edit    => 1,
        route       => $query->{route},
        category    => '/posts',
        limit       => $limit,
        pages       => scalar(@posts) == $limit,
        older       => @posts ? $posts[-1]->{created} : '',
        sizes       => [25,50,100],
        id          => $query->{id},
        acls        => \@acls,
        post        => { tags => $query->{tag} },
        edittype    => $query->{type} || 'microblog',
        app         => $app,
    });
}

=head2 post_save

Saves posts submitted via the /post pages

=cut

sub post_save ($query, $render_cb) {
    my $to = delete $query->{to};

    #Copy this down since it will be deleted later
    my $acls = $query->{acls};
    state $data = Trog::Data->new($conf);
    $query->{tags}  = _coerce_array($query->{tags});
    $query->{failure} = $data->add($query);
    $query->{to} = $to;
    $query->{acls} = $acls;
    $query->{message} = $query->{failure} ? "Failed to add post!" : "Successfully added Post as $query->{id}";
    delete $query->{id};
    return post($query, $render_cb);
}

=head2 profile

Saves / updates new users.

=cut

sub profile ($query, $render_cb) {
    #TODO allow users to do something OTHER than be admins
    if ($query->{password}) {
        Trog::Auth::useradd($query->{username}, $query->{password}, ['admin'] );
    }

    #Make sure it is "self-authored", redact pw
    $query->{user} = delete $query->{username};
    delete $query->{password};

    return post_save($query, $render_cb);
}

=head2 post_delete

deletes posts.

=cut

sub post_delete ($query, $render_cb) {
    state $data = Trog::Data->new($conf);
    $query->{failure} = $data->delete($query);
    $query->{to} = $query->{to};
    $query->{message} = $query->{failure} ? "Failed to delete post $query->{id}!" : "Successfully deleted Post $query->{id}";
    delete $query->{id};
    return post($query, $render_cb);
}

=head2 series

Series specific view, much like the users/ route

=cut

sub series ($query, $render_cb) {
    #Grab the relevant tag (aclname), then pass that to posts
    my @posts = _post_helper($query, [], $query->{acls});
    delete $query->{id};

    $query->{tag} = $posts[0]->{aclname};
    return posts($query,$render_cb);
}

=head2 avatars

Returns the avatars.css.  Limited to 1000 users.

=cut

sub avatars ($query, $render_cb) {
    #XXX if you have more than 1000 editors you should stop
    push(@{$query->{acls}}, 'public');
    my $tags = _coerce_array($query->{tag});
    $query->{limit} = 1000;
    my $processor = Text::Xslate->new(
        path   => $template_dir,
    );
    my @posts = _post_helper($query, $tags, $query->{acls});

    my $content = $processor->render('avatars.tx', {
        users => \@posts,
    });

    return [200,["Content-type: text/css\n"],[$content]];
}

=head2 users

Implements direct user profile view.

=cut

sub users ($query, $render_cb) {
    push(@{$query->{acls}}, 'public');
    my @posts = _post_helper({ limit => 10000 }, ['about'], $query->{acls});
    my @user = grep { $_->{user} eq $query->{username} } @posts;
    $query->{id} = $user[0]->{id};
    $query->{user_obj} = $user[0];
    return posts($query,$render_cb);
}

=head2 posts

Display multi or single posts, supports RSS and pagination.

=cut

sub posts ($query, $render_cb) {
    my $tags = _coerce_array($query->{tag});

    push(@{$query->{acls}}, 'public');
    push(@{$query->{acls}}, 'unlisted') if $query->{id};
    my @posts;

    if ($query->{user_obj}) {
        #Optimize the /users/* route
        @posts = ($query->{user_obj});
    } else {
        @posts = _post_helper($query, $tags, $query->{acls});
    }

    #OK, so if we have a user as the ID we found, go grab the rest of their posts
    if ($query->{id} && @posts && grep { $_ eq 'about'} @{$posts[0]->{tags}} ) {
        my $user = shift(@posts);
        my $id = delete $query->{id};
        $query->{author} = $user->{user};
        @posts = _post_helper($query, [], $query->{acls});
        @posts = grep { $_->{id} ne $id } @posts;
        unshift @posts, $user;
    }

    return notfound($query, $render_cb) unless @posts;

    my $fmt = $query->{format} || '';
    return _rss($query,\@posts) if $fmt eq 'rss';

    my $processor = Text::Xslate->new(
        path   => $template_dir,
    );

    # Themed header/footer for about page -- TODO maybe make this generic so we can have MESSAGE FROM JIMBO WALES everywhere
    my ($header,$footer);
    if ($query->{route} eq '/about' || $query->{route} eq '/humans.txt') {
        my $t_processor;
        $t_processor = Text::Xslate->new(
            path =>  "www/$theme_dir/templates",
        ) if $theme_dir;

        $header = _pick_processor("templates/about_header.tx"  ,$processor,$t_processor)->render('about_header.tx', { theme_dir => $td } );
        $footer = _pick_processor("templates/about_header.tx"  ,$processor,$t_processor)->render('about_footer.tx', { theme_dir => $td } );
    }

    my $styles = _build_themed_styles('posts.css');

    $query->{title} = @$tags && $query->{domain} ? "$query->{domain} : @$tags" : undef;
    $query->{title} = "$query->{domain} : $posts[0]{title}" if $query->{id} && $posts[0]{title} && $query->{domain};
    my $limit = int($query->{limit} || 25);

    my $content = $processor->render('posts.tx', {
        title     => $query->{title},
        posts     => \@posts,
        like      => $query->{like},
        in_series => !!($query->{route} =~ m/\/series\/\d*$/),
        route     => $query->{route},
        limit     => $limit,
        pages     => scalar(@posts) == $limit,
        older     => $posts[-1]->{created},
        sizes     => [25,50,100],
        rss       => !$query->{id} && !$query->{older},
        tiled     => scalar(grep { $_ eq $query->{route} } qw{/files /audio /video /image /series /about}),
        category  => $themed ? Theme::path_to_tile($query->{route}) : $query->{route},
        about_header => $header,
        about_footer => $footer,
    });
    return Trog::Routes::HTML::index($query, $render_cb, $content, $styles);
}

sub _post_helper ($query, $tags, $acls) {
    state $data = Trog::Data->new($conf);
    return $data->get(
        older   => $query->{older},
        page    => int($query->{page} || 1),
        limit   => int($query->{limit} || 25),
        tags    => $tags,
        acls    => $acls,
        like    => $query->{like},
        author  => $query->{author},
        id      => $query->{id},
        version => $query->{version},
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

sub sitemap ($query, $render_cb) {

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
        my $tot = $data->count();
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
        @to_map = _post_helper($query, [], ['public']);
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

                #add video & preview image if applicable
                $data{images} = [{
                    loc => "http://$query->{domain}$url->{href}",
                    caption => $url->{data},
                    title => $url->{title},
                }] if $url->{is_image};

                $data{videos} = [{
                    content_loc   => "http://$query->{domain}$url->{href}",
                    thumbnail_loc => "http://$query->{domain}$url->{preview}",
                    title         => $url->{title},
                    description   => $url->{data},
                }] if $url->{is_video};

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

    $query->{title} = "$query->{domain} : Sitemap";
    my $content = $processor->render('sitemap.tx', {
        title      => "Site Map",
        to_map     => \@to_map,
        is_index   => $is_index,
        route_type => $route_type,
        route      => $query->{route},
    });

    return Trog::Routes::HTML::index($query, $render_cb,$content,$styles);
}

sub _rss ($query,$posts) {
    require XML::RSS;
    my $rss = XML::RSS->new (version => '2.0');
    my $now = DateTime->from_epoch(epoch => time());
    $rss->channel(
        title          => "$query->{domain}",
        link           => "http://$query->{domain}/$query->{route}?format=rss",
        language       => 'en', #TODO localization
        description    => "$query->{domain} : $query->{route}",
        pubDate        => $now,
        lastBuildDate  => $now,
    );

    #TODO configurability
    $rss->image(
        title       => $query->{domain},
        url         => "$td/img/icon/favicon.ico",
        link        => "http://$query->{domain}",
        width       => 88,
        height      => 31,
        description => "$query->{domain} favicon",
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

    require Encode;
    return [200, ["Content-type: application/rss+xml\n"], [Encode::encode_utf8($rss->as_string)]];
}

=head2 manual

Implements the /manual and /lib/* routes.

Basically a thin wrapper around Pod::Html.

=cut

sub manual ($query, $render_cb) {
    require Pod::Html;
    require Capture::Tiny;

    #Fix links from Pod::HTML
    $query->{module} =~ s/\.html$//g if $query->{module};

    my $infile = $query->{module} ? "$query->{module}.pm" : 'tCMS/Manual.pod';
    return notfound($query,$render_cb) unless -f "lib/$infile";
    my $content = capture { Pod::Html::pod2html(qw{--podpath=lib --podroot=.},"--infile=lib/$infile") };
    return $render_cb->('manual.tx', {
        title       => 'tCMS Manual',
        theme_dir   => $td,
        content     => $content,
        stylesheets => _build_themed_styles('post.css'),
    });
}

# Deal with Params which may or may not be arrays
sub _coerce_array ($param) {
    my $p = $param || [];
    $p = [$param] if $param && (ref $param ne 'ARRAY');
    return $p;
}

sub _build_themed_styles ($style) {
    my @styles;
    @styles = ("/styles/$style") if -f "www/styles/$style";
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
