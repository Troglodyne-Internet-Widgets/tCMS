package Trog::Routes::HTML;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

use Trog::Config;
my $conf = Trog::Config::get();
my $template_dir = 'www/templates';
my $theme_dir;
$theme_dir = "themes/$conf->{'general.theme'}" if $conf->{'general.theme'} && -d "www/themes/$conf->{'general.theme'}";

use lib 'www';

# TODO Things which should be themable
our $landing_page = 'default.tx';
our $htmltitle     = 'title.tx';
our $midtitle      = 'midtitle.tx';
our $rightbar     = 'rightbar.tx';
our $leftbar      = 'leftbar.tx';
our $footbar      = 'footbar.tx';

our %routes = (
    '/' => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::index,
    },
    '/setup' => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::setup,
    },
    '/login' => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::login,
    },
    '/auth' => {
        method   => 'POST',
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
        callback => \&Trog::Routes::HTML::config,
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
    '/posts' => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::posts,
    },
    '/files' => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::files
    },
);

# Build aliases for /post with extra data
my @post_aliases = qw{news blog wiki video audio about};
@routes{map { "/$_" } @post_aliases} = map { my %copy = %{$routes{'/posts'}}; $copy{data} = { tag => [$_] }; \%copy } @post_aliases;

# Grab theme routes
if ($theme_dir) {
    my $theme_mod = "$theme_dir/routes.pm";
    if (-f $theme_mod ) {
        require $theme_mod;
        @routes{keys(%Theme::routes)} = values(%Theme::routes);
    }
}

sub index ($query, $input, $render_cb, $content = '', $i_styles = []) {
    $input->{theme_dir}  = $theme_dir || '';

    my $processor = Text::Xslate->new(
        path   => $template_dir,
    );

    my $t_processor;
    $t_processor = Text::Xslate->new(
        path =>  "www/$theme_dir/templates",
    ) if $theme_dir;

    $content ||= _pick_processor($rightbar,$processor,$t_processor)->render($landing_page,$input);

    my @styles = ('/styles/avatars.css'); #TODO generate file for users
    if ($theme_dir) {
        unshift(@styles, _themed_style("screen.css"))    if -f 'www/'._themed_style("screen.css");
        unshift(@styles, _themed_style("structure.css")) if -f 'www/'._themed_style("structure.css");
    }
    push( @styles, @$i_styles);

    #TODO allow theming of print css

    return $render_cb->('index.tx',{
        user        => $query->{user},
        theme_dir   => $theme_dir,
        content     => $content,
        title       => $conf->{'general.title'},
        htmltitle   => _pick_processor("templates/$htmltitle" ,$processor,$t_processor)->render($htmltitle,$input),
        midtitle    => _pick_processor("templates/$midtitle" ,$processor,$t_processor)->render($midtitle,$input),
        rightbar    => _pick_processor("templates/$rightbar" ,$processor,$t_processor)->render($rightbar,$input),
        leftbar     => _pick_processor("templates/$leftbar"  ,$processor,$t_processor)->render($leftbar,$input),
        footbar     => _pick_processor("templates/$footbar"  ,$processor,$t_processor)->render($footbar,$input),
        stylesheets => \@styles,
    });
}

sub setup ($query, $input, $render_cb) {
    return $render_cb->('notconfigured.tx', {
        title => 'tCMS Requires Setup to Continue...',
        stylesheets => _build_themed_styles('notconfigured.css'),
    });
}

sub login ($query, $input, $render_cb) {
    # TODO actually do login processing

    $query->{failed} //= -1;
    return $render_cb->('login.tx', {
        title         => 'tCMS 2 ~ Login',
        to            => $query->{to} || '/config',
        login_failure => int( $query->{failed} ),
        login_message => int( $query->{failed} ) < 1 ? "Login Successful, Redirecting..." : "Login Failed.",
        stylesheets   => _build_themed_styles('login.css'),
    });
}

sub config ($query, $input, $render_cb) {
    return $render_cb->('config.tx', {
        title => 'Configure tCMS',
        stylesheets => _build_themed_styles('config.css'),
    });
}

sub config_save ($query, $input, $render_cb) {
    return config($query, $input, $render_cb);
}

sub post ($query, $input, $render_cb) {
    return $render_cb->('post.tx', {
        title => 'New Post',
        stylesheets => _build_themed_styles('post.css'),
    });
}

sub post_save ($query, $input, $render_cb) {
    return post($query, $input, $render_cb);
}

sub posts ($query, $input, $render_cb) {
    my $tags = _coerce_array($query->{tag});

    require Trog::Data;
    my $data = Trog::Data->new($conf);

    my $processor ||= Text::Xslate->new(
        path   => _dir_for_resource('posts.tx'),
    );

    my $styles = _build_themed_styles('posts.css');

    my $content = $processor->render('posts.tx', {
        title => "Posts tagged @$tags",
        date  => 'TODO',
        posts => $data->get(
            tags  => $tags,
            like => $query->{like},
        ),
    });
    return Trog::Routes::HTML::index($query, $input, $render_cb, $content, $styles);
}

sub files ($query, $input, $render_cb) {
    return $render_cb->('fileman.tx', {
        title => 'tCMS File Browser',
        stylesheets => _build_themed_styles('fileman.css'),
    });
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
    push(@styles, $ts) if $theme_dir && -f $ts;
    return \@styles;
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

1;
