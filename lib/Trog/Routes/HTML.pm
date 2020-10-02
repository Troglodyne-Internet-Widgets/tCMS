package Trog::Routes::HTML;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

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
    '/posts/(.*)' => {
        method   => 'GET',
        auth     => 1,
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
);

# Build aliases for /post with extra data
my @post_aliases = qw{news blog image video audio about files};
@routes{map { "/$_" } @post_aliases} = map { my %copy = %{$routes{'/posts'}}; $copy{data}{tag} = [$_]; \%copy } @post_aliases;

# Build aliases for /post/(.*) with extra data
@routes{map { "/$_/(.*)" } @post_aliases} = map { my %copy = %{$routes{'/posts/(.*)'}}; \%copy } @post_aliases;


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

# TODO build a sitemap.xml based on the above routing table, and robots.txt

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
            Trog::Auth::useradd($postdata->{username}, $postdata->{password});
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
    my $tags = ['profile'];
    my $posts = _post_helper($query, $tags);
    my $css   = _build_themed_styles('config.css');
    my $js    = _build_themed_scripts('post.js');
    push(@$css, '/styles/avatars.css');

    $query->{failure} //= -1;

    return $render_cb->('config.tx', {
        title         => 'Configure tCMS',
        stylesheets   => $css,
        scripts       => $js,
        themes        => _get_themes(),
        data_models   => _get_data_models(),
        current_theme => $conf->param('general.theme'),
        current_data_model => $conf->param('general.data_model'),
        route       => '/about',
        category    => '/about',
        types       => ['profile'],
        can_edit    => 1,
        posts       => $posts,
        edittype    => 'profile',
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
        $query->{to} = '/config';
        return login($query,$input,$render_cb);
    }

    my $tags  = _coerce_array($query->{tag});
    my $posts = _post_helper($query, $tags);
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
        types       => [qw{microblog blog file}],
        route       => '/posts',
        category    => '/posts',
        page        => int($query->{page} || 1),
        limit       => int($query->{limit} || 1),
        sizes       => [25,50,100],
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
    my $posts = _post_helper($query, $tags);

    return notfound($query,$input,$render_cb) unless @$posts;

    my $fmt = $query->{format} || '';
    return _rss($posts) if $fmt eq 'rss';

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
        category => $themed ? Theme::path_to_tile($query->{route}) : $query->{route},
    });
    return Trog::Routes::HTML::index($query, $input, $render_cb, $content, $styles);
}

sub _post_helper ($query, $tags) {
    my $data = Trog::Data->new($conf);
    return $data->get(
        page  => int($query->{page} || 1),
        limit => int($query->{limit} || 25),
        tags  => $tags,
        like  => $query->{like},
        id    => $query->{id},
    );
}

sub _rss ($posts) {
    return [200, ["Content-type: text/plain\n"], ["TODO"]];
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
