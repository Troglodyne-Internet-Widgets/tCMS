package Trog::Routes::HTML;

use strict;
use warnings;

no warnings qw{experimental once};
use feature qw{signatures state};

use Errno qw{ENOENT};
use File::Touch();
use List::Util();
use List::MoreUtils();
use Capture::Tiny qw{capture};
use HTML::SocialMeta;

use Encode qw{encode_utf8};
use IO::Compress::Gzip;
use Path::Tiny();
use File::Basename qw{dirname};
use URI();
use URI::Escape();

use FindBin::libs;

use Trog::Log qw{:all};
use Trog::Utils;
use Trog::Config;
use Trog::Auth;
use Trog::Data;
use Trog::FileHandler;
use Trog::Themes;
use Trog::Renderer;
use Trog::Email;

use Trog::Component::EmojiPicker;

my $conf = Trog::Config::get();

our $landing_page = 'default.tx';
our $htmltitle    = 'title.tx';
our $midtitle     = 'midtitle.tx';
our $rightbar     = 'rightbar.tx';
our $leftbar      = 'leftbar.tx';
our $topbar       = 'topbar.tx';
our $footbar      = 'footbar.tx';
our $categorybar  = 'categories.tx';

# Note to maintainers: never ever remove backends from this list.
# the auth => 1 is a crucial protection.
our %routes = (
    default => {
        callback => \&Trog::Routes::HTML::setup,
        nomap    => 1,
    },
    '/index' => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::index,
    },

    #Deal with most indexDocument directives interfering with proxied requests to /
    #TODO replace with alias routes
    '/index.html' => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::index,
    },
    '/index.php' => {
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
        noindex  => 1,
    },
    '/logout' => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::logout,
        noindex  => 1,
    },
    '/auth' => {
        method   => 'POST',
        callback => \&Trog::Routes::HTML::login,
        noindex  => 1,
    },
    '/totp' => {
        method   => 'GET',
        auth     => 1,
        callback => \&Trog::Routes::HTML::totp,
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
    '/config/save' => {
        method   => 'POST',
        auth     => 1,
        callback => \&Trog::Routes::HTML::config_save,
    },
    '/themeclone' => {
        method   => 'POST',
        auth     => 1,
        callback => \&Trog::Routes::HTML::themeclone,
    },
    '/profile' => {
        method   => 'POST',
        auth     => 1,
        callback => \&Trog::Routes::HTML::profile,
    },
    '/manual' => {
        method   => 'GET',
        auth     => 1,
        callback => \&Trog::Routes::HTML::manual,
    },
    '/lib/(.*)' => {
        method   => 'GET',
        auth     => 1,
        captures => ['module'],
        callback => \&Trog::Routes::HTML::manual,
    },
    '/password_reset' => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::resetpass,
        noindex  => 1,
    },
    '/request_password_reset' => {
        method   => 'POST',
        callback => \&Trog::Routes::HTML::do_resetpass,
        noindex  => 1,
    },
    '/request_totp_clear' => {
        method   => 'POST',
        callback => \&Trog::Routes::HTML::do_totp_clear,
        noindex  => 1,
    },
    '/processed' => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::processed,
        noindex  => 1,
    },
    '/metrics' => {
        method   => 'GET',
        auth     => 1,
        callback => \&Trog::Routes::HTML::metrics,
    },

    #TODO transform into posts?
    '/sitemap',
    => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::sitemap,
    },
    '/sitemap_index.xml',
    => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::sitemap,
        data     => { xml => 1 },
    },
    '/sitemap_index.xml.gz',
    => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::sitemap,
        data     => { xml => 1, compressed => 1 },
    },
    '/sitemap/static.xml' => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::sitemap,
        data     => { xml => 1, map => 'static' },
    },
    '/sitemap/static.xml.gz' => {
        method   => 'GET',
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
        data     => { xml => 1, compressed => 1 },
        captures => ['map'],
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
    '/favicon.ico' => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::icon,
    },
    '/styles/rss-style.xsl' => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::rss_style,
    },
);

# Grab theme routes
my $themed = 0;
if ($Trog::Themes::theme_dir) {
    my $theme_mod = "$Trog::Themes::theme_dir/routes.pm";
    if ( -f $theme_mod ) {
        use lib '.';
        require $theme_mod;
        @routes{ keys(%Theme::routes) } = values(%Theme::routes);
        $themed = 1;
    }
    else {
        # Use the special "default" theme
        require Theme;
    }
}

=head1 PRIMARY ROUTE

=head2 index

Implements the primary route used by all pages not behind auth.
Most subsequent functions simply pass content to this function.

=cut

sub index ( $query, $content = '', $i_styles = [], $i_scripts = [] ) {
    $query->{theme_dir} = $Trog::Themes::td;

    my $to_render = $query->{template} // $landing_page;
    $content ||= Trog::Renderer->render( template => $to_render, data => $query, component => 1, contenttype => 'text/html' );
    return $content if ref $content eq "ARRAY";

    my @styles;
    unshift( @styles, qw{embed.css} ) if $query->{embed};
    unshift( @styles, qw{screen.css structure.css} );
    push( @styles, @$i_styles );
    my @p_styles = qw{structure.css print.css};
    unshift( @p_styles, qw{embed.css} ) if $query->{embed};

    my @series = _get_series(0);

    my $title = $query->{primary_post}{title} // $query->{title} // $Theme::default_title // 'tCMS';

    # Handle link "unfurling" correctly
    my ( $default_tags, $meta_desc, $meta_tags ) = _build_social_meta( $query, $title );

    #Do embed content
    my $tmpl = $query->{embed} ? 'embed.tx' : 'index.tx';
    $query->{theme_dir} =~ s/^\/www\///;

    # TO support theming we have to do things like this rather than with an include directive in the templates.
    my $htmltitle = Trog::Renderer->render( template => $htmltitle, data => $query, component => 1, contenttype => 'text/html' );
    return $htmltitle if ref $htmltitle eq 'ARRAY';
    my $midtitle = Trog::Renderer->render( template => $midtitle, data => $query, component => 1, contenttype => 'text/html' );
    return $midtitle if ref $midtitle eq 'ARRAY';
    my $rightbar = Trog::Renderer->render( template => $rightbar, data => $query, component => 1, contenttype => 'text/html' );
    return $rightbar if ref $rightbar eq 'ARRAY';
    my $leftbar = Trog::Renderer->render( template => $leftbar, data => $query, component => 1, contenttype => 'text/html' );
    return $leftbar if ref $leftbar eq 'ARRAY';
    my $topbar = Trog::Renderer->render( template => $topbar, data => $query, component => 1, contenttype => 'text/html' );
    return $topbar if ref $topbar eq 'ARRAY';
    my $footbar = Trog::Renderer->render( template => $footbar, data => $query, component => 1, contenttype => 'text/html' );
    return $footbar if ref $footbar eq 'ARRAY';
    my $categorybar = Trog::Renderer->render( template => $categorybar, data => { %$query, categories => \@series }, component => 1, contenttype => 'text/html' );
    return $categorybar if ref $categorybar eq 'ARRAY';

    # Grab the avatar class for the logged in user
    if ( $query->{user} ) {
        $query->{user_class} = Trog::Auth::username2classname( $query->{user} );
    }

    state $data;
    $data //= Trog::Data->new($conf);

    return finish_render(
        $tmpl,
        {
            %$query,
            search_lang  => $data->lang(),
            search_help  => $data->help(),
            theme_dir    => $Trog::Themes::td,
            content      => $content,
            title        => $title,
            htmltitle    => $htmltitle,
            midtitle     => $midtitle,
            rightbar     => $rightbar,
            leftbar      => $leftbar,
            topbar       => $topbar,
            footbar      => $footbar,
            categorybar  => $categorybar,
            categories   => \@series,
            stylesheets  => \@styles,
            print_styles => \@p_styles,
            scripts      => $i_scripts,
            show_madeby  => $Theme::show_madeby ? 1 : 0,
            embed        => $query->{embed}     ? 1 : 0,
            embed_video  => $query->{primary_post}{is_video},
            default_tags => $default_tags,
            meta_desc    => $meta_desc,
            meta_tags    => $meta_tags,
        }
    );
}

sub _build_social_meta ( $query, $title ) {
    return ( undef, undef, undef ) unless $query->{social_meta} && $query->{route} && $query->{domain};

    my $default_tags = $Theme::default_tags;
    $default_tags .= ',' . join( ',', @{ $query->{primary_post}->{tags} } ) if $default_tags && $query->{primary_post}->{tags};

    my $primary_data = ref $query->{primary_post}{data} eq 'ARRAY' ? $query->{primary_post}{data}[0] : $query->{primary_post}{data};
    my $meta_desc = $primary_data // $Theme::description // "tCMS Site";
    $meta_desc = Trog::Utils::strip_and_trunc($meta_desc) || '';

    my $meta_tags = '';
    my $card_type = 'summary';
    $card_type = 'featured_image' if $query->{primary_post} && $query->{primary_post}{is_image};
    $card_type = 'player'         if $query->{primary_post} && $query->{primary_post}{is_video};

    my $image = $Theme::default_image ? "https://$query->{domain}/$Trog::Themes::td/$Theme::default_image" : '';
    $image = "https://$query->{domain}/$query->{primary_post}{preview}" if $query->{primary_post} && $query->{primary_post}{preview};
    $image = "https://$query->{domain}/$query->{primary_post}{href}"    if $query->{primary_post} && $query->{primary_post}{is_image};

    my $primary_route = "https://$query->{domain}/$query->{route}";
    $primary_route =~ s/[\/]+/\//g;

    my $display_name = $Theme::display_name || 'Another tCMS Site';

    my $extra_tags = '';

    my %sopts = (
        site        => '',
        image       => '',
        fb_app_id   => '',
        site_name   => $display_name,
        app_name    => $display_name,
        title       => $title,
        description => $meta_desc,
        url         => $primary_route,
    );
    $sopts{site}      = $Theme::twitter_account if $Theme::twitter_account;
    $sopts{image}     = $image                  if $image;
    $sopts{fb_app_id} = $Theme::fb_app_id       if $Theme::fb_app_id;
    if ( $query->{primary_post} && $query->{primary_post}{is_video} ) {

        #$sopts{player} = "$primary_route?embed=1";
        $sopts{player} = "https://$query->{domain}/$query->{primary_post}{href}";

        #XXX don't hardcode this
        $sopts{player_width}  = 1280;
        $sopts{player_height} = 720;
        $extra_tags .= "<meta property='og:video:type' content='$query->{primary_post}{content_type}' />\n";
    }
    my $social = HTML::SocialMeta->new(%sopts);
    $meta_tags = eval { $social->create($card_type) };
    $meta_tags =~ s/content="video"/content="video:other"/mg if $meta_tags;
    $meta_tags .= $extra_tags                                if $extra_tags;

    print STDERR "WARNING: Theme misconfigured, social media tags will not be included\n$@\n" if $Trog::Themes::theme_dir && !$meta_tags;
    return ( $default_tags, $meta_desc, $meta_tags );
}

=head1 ADMIN ROUTES

These are things that issue returns other than 200, and are not directly accessible by users via any defined route.

=head2 notfound, forbidden, badrequest

Implements the 4XX status codes.  Override templates named the same for theming this.

=cut

sub _generic_route ( $rname, $code, $title, $query ) {
    $query->{code} = $code;
    $query->{route} //= $rname;
    $query->{title}    = $title;
    $query->{template} = "$rname.tx";
    return Trog::Routes::HTML::index($query);
}

sub notfound (@args) {
    return _generic_route( 'notfound', 404, "Return to sender, Address unknown", @args );
}

sub forbidden (@args) {
    return _generic_route( 'forbidden', 403, "STAY OUT YOU RED MENACE", @args );
}

sub badrequest (@args) {
    return _generic_route( 'badrequest', 400, "Bad Request", @args );
}

sub toolong (@args) {
    return _generic_route( 'toolong', 419, "URI too long", @args );
}

sub error (@args) {
    return _generic_route( 'error', 500, "Internal Server Error", @args );
}

=head2 redirect, redirect_permanent, see_also

Redirects to the provided page.

=cut

sub redirect ($to) {
    INFO("redirect: $to");
    return [ 302, [ "Location" => $to ], [''] ];
}

sub redirect_permanent ($to) {
    INFO("permanent redirect: $to");
    return [ 301, [ "Location" => $to ], [''] ];
}

sub see_also ($to) {
    INFO("see also: $to");
    return [ 303, [ "Location" => $to ], [''] ];
}

=head1 NORMAL ROUTES

These are expected to either return a 200, or redirect to something which does.

=head2 setup

One time setup page; should only display to the first user to visit the site which we presume to be the administrator.

=cut

sub setup ($query) {
    File::Touch::touch("config/setup");
    Trog::Renderer->render(
        template => 'notconfigured.tx',
        data     => {
            title       => 'tCMS Requires Setup to Continue...',
            stylesheets => _build_themed_styles( ['notconfigured.css'] ),
            %$query,
        },
        contenttype => 'text/html',
        code        => 200,
    );
}

=head2 totp

Enable 2 factor auth via TOTP for the currently authenticated user.
Returns a page with a QR code & TOTP uri for pasting into your authenticator app of choice.

=cut

sub totp ($query) {
    my $active_user = $query->{user};
    my $domain      = $query->{domain};
    $query->{failure} //= -1;
    my ( $uri, $qr, $failure, $message ) = Trog::Auth::totp( $active_user, $domain );

    return Trog::Routes::HTML::index(
        {
            title     => 'Enable TOTP 2-Factor Auth',
            theme_dir => $Trog::Themes::td,
            uri       => $uri,
            qr        => $qr,
            failure   => $failure,
            message   => $message,
            template  => 'totp.tx',
            is_admin  => 1,
            %$query,
        },
        undef,
        [qw{post.css}],
    );
}

=head2 login

Sets the user cookie if the provided user exists, or sets up the user as an admin with the provided credentials in the event that no users exist.

=cut

sub login ($query) {

    # Redirect if we actually have a logged in user.
    # Note to future me -- this user value is overwritten explicitly in server.psgi.
    # If that ever changes, you will die
    $query->{to} //= $query->{route};
    $query->{to} = '/config' if List::Util::any { $query->{to} eq $_ } qw{/login /logout};
    if ( $query->{user} ) {
        DEBUG("Login by $query->{user}, redirecting to $query->{to}");
        return see_also( $query->{to} );
    }

    #Check and see if we have no users.  If so we will just accept whatever creds are passed.
    my $hasusers = -f "config/has_users";
    my $btnmsg   = $hasusers ? "Log In" : "Register";

    my $headers;
    my $has_totp = 0;
    if ( $query->{username} && $query->{password} ) {
        if ( !$hasusers ) {

            # Make the first user
            Trog::Auth::useradd( $query->{username}, $query->{display_name}, $query->{password}, ['admin'], $query->{contact_email} );

            # Add a stub user page and the initial series.
            my $dat = Trog::Data->new($conf);
            _setup_initial_db( $dat, $query->{username}, $query->{display_name}, $query->{contact_email} );

            # Ensure we stop registering new users
            File::Touch::touch("config/has_users");
        }

        $query->{failed} = 1;
        my $cookie = Trog::Auth::mksession( $query->{username}, $query->{password}, $query->{token} );
        if ($cookie) {

            # TODO secure / sameSite cookie to kill csrf, maybe do rememberme with Expires=~0
            my $secure = '';
            $secure  = '; Secure' if $query->{scheme} eq 'https';
            $headers = {
                "Set-Cookie" => "tcmslogin=$cookie; HttpOnly; SameSite=Strict$secure",
            };
            $query->{failed} = 0;
        }
    }

    $query->{failed} //= -1;
    return Trog::Renderer->render(
        template => 'login.tx',
        data     => {
            title       => 'tCMS 2 ~ Login',
            to          => $query->{to},
            failure     => int( $query->{failed} ),
            message     => int( $query->{failed} ) < 1 ? "Login Successful, Redirecting..." : "Login Failed.",
            btnmsg      => $btnmsg,
            stylesheets => _build_themed_styles( [qw{structure.css screen.css login.css}] ),
            theme_dir   => $Trog::Themes::td,
            has_users   => $hasusers,
            %$query,
        },
        headers     => $headers,
        contenttype => 'text/html',
        code        => 200,
    );
}

sub _setup_initial_db ( $dat, $user, $display_name, $contact_email ) {
    $dat->add(
        {
            "aclname"    => "series",
            "acls"       => [],
            "callback"   => "Trog::Routes::HTML::series",
            method       => 'GET',
            "data"       => "Series",
            "href"       => "/series",
            "local_href" => "/series",
            "preview"    => "/img/sys/testpattern.jpg",
            "tags"       => [qw{series topbar}],
            visibility   => 'public',
            "title"      => "Series",
            user         => $user,
            form         => 'series.tx',
            child_form   => 'series.tx',
            aliases      => [],
        },
        {
            "aclname"    => "about",
            "acls"       => [],
            "callback"   => "Trog::Routes::HTML::series",
            method       => 'GET',
            "data"       => "About",
            "href"       => "/about",
            "local_href" => "/about",
            "preview"    => "/img/sys/testpattern.jpg",
            "tags"       => [qw{series topbar public}],
            visibility   => 'public',
            "title"      => "About",
            user         => $user,
            form         => 'series.tx',
            child_form   => 'profile.tx',
            aliases      => [],
        },
        {
            "aclname"      => "config",
            acls           => [],
            "callback"     => "Trog::Routes::HTML::config",
            'method'       => 'GET',
            "content_type" => "text/html",
            "data"         => "Config",
            "href"         => "/config",
            "local_href"   => "/config",
            "preview"      => "/img/sys/testpattern.jpg",
            "tags"         => [qw{admin}],
            visibility     => 'private',
            "title"        => "Configure tCMS",
            user           => $user,
            aliases        => [],
        },
        {
            title         => $display_name,
            data          => 'Default user',
            preview       => '/img/avatar/humm.gif',
            wallpaper     => '/img/sys/testpattern.jpg',
            tags          => ['about'],
            visibility    => 'public',
            acls          => ['admin'],
            local_href    => "/users/$display_name",
            display_name  => $display_name,
            contact_email => $contact_email,
            callback      => "Trog::Routes::HTML::users",
            method        => 'GET',
            user          => $user,
            form          => 'profile.tx',
            aliases       => [],
        },
    );
}

=head2 logout

Deletes your users' session and opens the index.

=cut

sub logout ($query) {
    Trog::Auth::killsession( $query->{user} ) if $query->{user};
    delete $query->{user};
    return Trog::Routes::HTML::index($query);
}

=head2 config

Renders the configuration page, or redirects you back to the login page.

=cut

sub config ( $query = {} ) {
    return see_also('/login')                    unless $query->{user};
    return Trog::Routes::HTML::forbidden($query) unless grep { $_ eq 'admin' } @{ $query->{user_acls} };

    $query->{failure} //= -1;

    #XXX ACHTUNG config::simple has this brain damaged behavior of returning a multiple element array when you access something that does not exist.
    #XXX straight up dying would be preferrable.
    #XXX anyways, this means you can NEVER NEVER NEVER access a param from within a hash directly.  YOU HAVE BEEN WARNED!
    state $theme    = $conf->param('general.theme')              // '';
    state $dm       = $conf->param('general.data_model')         // 'DUMMY';
    state $embeds   = $conf->param('security.allow_embeds_from') // '';
    state $hostname = $conf->param('general.hostname')           // '';

    return Trog::Routes::HTML::index(
        {
            title              => 'Configure tCMS',
            theme_dir          => $Trog::Themes::td,
            stylesheets        => [qw{config.css}],
            scripts            => [qw{post.js}],
            themes             => _get_themes() || [],
            data_models        => _get_data_models(),
            current_theme      => $theme,
            current_data_model => $dm,
            message            => $query->{message},
            failure            => $query->{failure},
            to                 => '/config',
            scheme             => $query->{scheme},
            embeds             => $embeds,
            is_admin           => 1,
            template           => 'config.tx',
            %$query,
            hostname => $hostname,
        },
        undef,
        [qw{config.css}],
    );
}

=head2 resetpass

=head2 do_resetpass

=head2 do_totp_clear

Routes for user service of their authentication details.

=cut

sub resetpass ($query) {
    $query->{failure} //= -1;

    return Trog::Routes::HTML::index(
        {
            title       => 'Request Authentication Resets',
            theme_dir   => $Trog::Themes::td,
            stylesheets => [qw{config.css}],
            scripts     => [qw{post.js}],
            message     => $query->{message},
            failure     => $query->{failure},
            scheme      => $query->{scheme},
            template    => 'resetpass.tx',
            %$query,
        },
        undef,
        [qw{config.css}],
    );
}

sub do_resetpass ($query) {
    my $user = $query->{username};

    # User Does not exist
    return Trog::Routes::HTML::forbidden($query) if !Trog::Auth::user_exists($user);

    # User exists, but is not logged in this session
    return Trog::Routes::HTML::forbidden($query) if !$query->{user} && Trog::Auth::user_has_session($user);

    my $token   = Trog::Utils::uuid();
    my $newpass = $query->{password} // Trog::Utils::uuid();
    my $res     = Trog::Auth::add_change_request( type => 'reset_pass', user => $user, secret => $newpass, token => $token );
    die "Could not add auth change request!" unless $res;

    # If the user is logged in, just do the deed, otherwise send them the token in an email
    if ( $query->{user} ) {
        return see_also("/api/auth_change_request/$token");
    }
    Trog::Email::contact(
        $user,
        "root\@$query->{domain}",
        "$query->{domain}: Password reset URL for $user",
        { uri => "$query->{scheme}://$query->{domain}/api/auth_change_request/$token", template => 'password_reset.tx' }
    );
    return see_also("/processed");
}

sub do_totp_clear ($query) {
    my $user = $query->{username};

    # User Does not exist
    return Trog::Routes::HTML::forbidden($query) if !Trog::Auth::user_exists($user);

    # User exists, but is not logged in this session
    return Trog::Routes::HTML::forbidden($query) if !$query->{user} && Trog::Auth::user_has_session($user);

    my $token = Trog::Utils::uuid();
    my $res   = Trog::Auth::add_change_request( type => 'clear_totp', user => $user, token => $token );
    die "Could not add auth change request!" unless $res;

    # If the user is logged in, just do the deed, otherwise send them the token in an email
    if ( $query->{user} ) {
        return see_also("/api/auth_change_request/$token");
    }
    Trog::Email::contact(
        $user,
        "root\@$query->{domain}",
        "$query->{domain}: Password reset URL for $user",
        { uri => "$query->{scheme}://$query->{domain}/api/auth_change_request/$token", template => 'totp_reset.tx' }
    );
    return see_also("/processed");
}

sub _get_series ( $edit = 0 ) {
    state $data;
    $data //= Trog::Data->new($conf);

    my @series = $data->get(
        acls  => [qw{public}],
        tags  => [qw{topbar}],
        limit => 10,
        page  => 1,
    );
    @series = map { $_->{local_href} = "/post$_->{local_href}"; $_ } @series if $edit;
    return @series;
}

sub _get_themes {
    my $dir = 'www/themes';
    opendir( my $dh, $dir ) || do { die "Can't opendir $dir: $!" unless $!{ENOENT} };
    my @tdirs = grep { !/^\./ && -d "$dir/$_" } readdir($dh);
    closedir $dh;
    return \@tdirs;
}

sub _get_data_models {
    my $dir = 'lib/Trog/Data';
    opendir( my $dh, $dir ) || die "Can't opendir $dir: $!";
    my @dmods = map { s/\.pm$//g; $_ } grep { /\.pm$/ && -f "$dir/$_" } readdir($dh);
    closedir $dh;
    return \@dmods;
}

=head2 config_save

Implements /config/save route.  Saves what little configuration we actually use to ~/.tcms/tcms.conf

=cut

sub config_save ($query) {
    return see_also('/login')                    unless $query->{user};
    return Trog::Routes::HTML::forbidden($query) unless grep { $_ eq 'admin' } @{ $query->{user_acls} };

    $conf->param( 'general.theme',              $query->{theme} )      if defined $query->{theme};
    $conf->param( 'general.data_model',         $query->{data_model} ) if $query->{data_model};
    $conf->param( 'security.allow_embeds_from', $query->{embeds} )     if $query->{embeds};
    $conf->param( 'general.hostname',           $query->{hostname} )   if $query->{hostname};

    $query->{failure} = 1;
    $query->{message} = "Failed to save configuration!";
    if ( $conf->write($Trog::Config::home_cfg) ) {
        $query->{failure} = 0;
        $query->{message} = "Configuration updated succesfully.";
    }

    #Get the PID of the parent port using lsof, send HUP
    Trog::Utils::restart_parent();

    return config($query);
}

=head2 themeclone

Clone a theme by copying a directory.

=cut

sub themeclone ($query) {
    return see_also('/login')                    unless $query->{user};
    return Trog::Routes::HTML::forbidden($query) unless grep { $_ eq 'admin' } @{ $query->{user_acls} };

    my ( $theme, $newtheme ) = ( $query->{theme}, $query->{newtheme} );

    my $themedir = 'www/themes';

    $query->{failure} = 1;
    $query->{message} = "Failed to clone theme '$theme' as '$newtheme'!";
    require File::Copy::Recursive;
    if ( $theme && $newtheme && File::Copy::Recursive::dircopy( "$themedir/$theme", "$themedir/$newtheme" ) ) {
        $query->{failure} = 0;
        $query->{message} = "Successfully cloned theme '$theme' as '$newtheme'.";
    }
    return see_also('/config');
}

=head2 post_save

Saves posts submitted via the /post pages

=cut

sub post_save ($query) {
    return see_also('/login')                    unless $query->{user};
    return Trog::Routes::HTML::forbidden($query) unless grep { $_ eq 'admin' } @{ $query->{user_acls} };

    my $to = delete $query->{to};

    #Copy this down since it will be deleted later
    my $acls = $query->{acls};

    $query->{tags} = Trog::Utils::coerce_array( $query->{tags} );
    # Support data with multiple pages like presentations
    $query->{data} = Trog::Utils::coerce_array( $query->{data} ) if $query->{data_is_array};
    $query->{attachments} = Trog::Utils::coerce_array( $query->{attachments} );

    # Filter bits and bobs
    delete $query->{primary_post};
    delete $query->{social_meta};
    delete $query->{deflate};
    delete $query->{acls};

    # Ensure there are no null tags
    @{ $query->{tags} } = grep { defined $_ } @{ $query->{tags} };

    # Posts will always be GET
    $query->{method} = 'GET';

    state $data;
    $data //= Trog::Data->new($conf);

    $data->add($query) and die "Could not add post";
    return see_also($to);
}

=head2 profile

Saves / updates new users.

=cut

sub profile ($query) {
    return see_also('/login')                    unless $query->{user};
    return Trog::Routes::HTML::forbidden($query) unless grep { $_ eq 'admin' } @{ $query->{user_acls} };

    # Find the user's post and edit it
    state $data;
    $data //= Trog::Data->new($conf);

    my @userposts = $data->get( tags => ['about'], acls => [qw{admin}] );

    # Users are always self-authored, you see

    my $user_obj = List::Util::first { ( $_->{user} || '' ) eq $query->{username} } @userposts;

    if ( $query->{username} ne $user_obj->{user} || $query->{password} || $query->{contact_email} ne $user_obj->{contact_email} || $query->{display_name} ne $user_obj->{display_name} ) {
        my $for_user = Trog::Auth::acls4user( $query->{username} );

        #TODO support non-admin users
        my @acls = @$for_user ? @$for_user : qw{admin};
        Trog::Auth::useradd( $query->{username}, $query->{display_name}, $query->{password}, \@acls, $query->{contact_email} );
    }

    #Make sure it is "self-authored", redact pw
    $query->{user} = delete $query->{username};
    delete $query->{password};

    # Use the display name as the title
    $query->{title} = $query->{display_name};

    my %merged = (
        %$user_obj,
        %$query,
        $query->{display_name} ? ( local_href => "/users/$query->{display_name}" ) : ( local_href => $user_obj->{local_href} ),
    );

    return post_save( \%merged );
}

=head2 post_delete

deletes posts.

=cut

sub post_delete ($query) {
    return see_also('/login')                    unless $query->{user};
    return Trog::Routes::HTML::forbidden($query) unless grep { $_ eq 'admin' } @{ $query->{user_acls} };

    state $data;
    $data //= Trog::Data->new($conf);

    $data->delete($query) and die "Could not delete post";
    return see_also( $query->{to} );
}

=head2 series

Series specific view, much like the users/ route
Displays identified series, not all series.

=cut

sub series ($query) {
    my $is_admin = grep { $_ eq 'admin' } @{ $query->{user_acls} };

    #we are either viewed one of two ways, /post/$id or /$aclname
    my ( undef, $aclname, $id ) = split( /\//, $query->{route} );
    $query->{aclname} = $aclname if !$id;
    $query->{id}      = $id      if $id;

    # Don't show topbar series on the series page.  That said, don't exclude it from direct series view.
    $query->{exclude_tags} = ['topbar'] if !$is_admin && $aclname && $aclname eq 'series';

    #XXX I'd prefer to overload id to actually *be* the aclname...
    # but this way, accomodates things like the flat file time-indexing hack.
    # TODO I should probably have it for all posts, and make *everything* a series.
    # WE can then do threaded comments/posts.
    # That will essentially necessitate it *becoming* the ID for real.

    #Grab the relevant tag (aclname), then pass that to posts
    my @posts = _post_helper( $query, ['series'], $query->{user_acls} );

    delete $query->{id};
    delete $query->{aclname};

    $query->{subhead}      = $posts[0]->{data};
    $query->{title}        = $posts[0]->{title};
    $query->{tag}          = $posts[0]->{aclname};
    $query->{primary_post} = $posts[0];
    $query->{in_series}    = 1;

    return posts($query);
}

=head2 avatars

Returns the avatars.css.

=cut

sub avatars ($query) {
    push( @{ $query->{user_acls} }, 'public' );
    my $tags = Trog::Utils::coerce_array( $query->{tag} );

    my @posts = _post_helper( $query, $tags, $query->{user_acls} );
    if (@posts) {

        # Set the eTag so that we don't get a re-fetch
        $query->{etag} = "$posts[0]{id}-$posts[0]{version}";
    }

    @posts = map { $_->{id} =~ tr/-/_/; $_->{id} = "a_$_->{id}"; $_ } @posts;

    return Trog::Renderer->render(
        template => 'avatars.tx',
        data     => {
            users => \@posts,
            %$query,
        },
        code        => 200,
        contenttype => 'text/css',
    );
}

=head2 users

Implements direct user profile view.

=cut

sub users ($query) {

    # Capture the username
    my ( undef, undef, $display_name ) = split( /\//, $query->{route} );
    $display_name = URI::Escape::uri_unescape($display_name);

    my $username = Trog::Auth::display2username($display_name);
    return notfound($query) unless $username;

    $query->{username} //= $username;
    push( @{ $query->{user_acls} }, 'public' );
    $query->{exclude_tags} = ['about'];

    # Don't show topbar series on the series page.  That said, don't exclude it from direct series view.
    my $is_admin = grep { $_ eq 'admin' } @{ $query->{user_acls} };
    push( @{ $query->{exclude_tags} }, 'topbar' ) if !$is_admin;

    my @posts = _post_helper( { author => $query->{username} }, ['about'], $query->{user_acls} );
    $query->{id}           = $posts[0]->{id};
    $query->{title}        = $posts[0]->{display_name};
    $posts[0]->{title}     = $posts[0]->{display_name};
    $query->{user_obj}     = $posts[0];
    $query->{primary_post} = $posts[0];
    $query->{in_series}    = 1;
    return posts($query);
}

=head2 posts

Display multi or single posts, supports RSS and pagination.

=cut

sub posts ( $query, $direct = 0 ) {

    # Allow rss.xml to tell what posts to loop over
    my $fmt = $query->{format} || '';

    #Process the input URI to capture tag/id
    $query->{route} //= $query->{to};
    my ( undef, undef, $id ) = split( /\//, $query->{route} );

    my $tags = Trog::Utils::coerce_array( $query->{tag} );
    $query->{id} = $id if $id && !$query->{in_series};

    my $is_admin = grep { $_ eq 'admin' } @{ $query->{user_acls} };
    push( @{ $query->{user_acls} }, 'public' );
    push( @{ $query->{user_acls} }, 'unlisted' ) if $query->{id};
    push( @{ $query->{user_acls} }, 'private' )  if $is_admin;
    my @posts;

    # Discover this user's visibility, so we can make them post in this category by default
    my $user_visibility = 'public';

    if ( $query->{user_obj} ) {

        #Optimize the /users/* route
        @posts           = ( $query->{user_obj} );
        $user_visibility = $query->{user_obj}->{visibility};
    }
    else {
        if ( $query->{user} ) {
            my @me = _post_helper( { author => $query->{user} }, ['about'], $query->{user_acls} );
            $user_visibility = $me[0]->{visibility};
        }
        @posts = _post_helper( $query, $tags, $query->{user_acls} );
    }

    if ( $query->{id} ) {
        $query->{primary_post} = $posts[0] if @posts;
    }

    #OK, so if we have a user as the ID we found, go grab the rest of their posts
    if ( $query->{id} && @posts && List::Util::any { $_ eq 'about' } @{ $posts[0]->{tags} } ) {
        my $user = shift(@posts);
        my $id   = delete $query->{id};
        $query->{author} = $user->{user};
        @posts           = _post_helper( $query, $tags, $query->{user_acls} );
        @posts           = grep { $_->{id} ne $id } @posts;
        unshift @posts, $user;
    }

    if ( !$is_admin ) {
        return notfound($query) unless @posts;
    }

    # Set the eTag so that we don't get a re-fetch
    $query->{etag} = "$posts[0]{id}-$posts[0]{version}" if @posts;

    #Correct page headers
    my $ph = $themed ? _themed_title( $query->{route} ) : $query->{route};

    return _rss( $query, $ph, \@posts ) if $fmt eq 'rss';

    #XXX Is used by the sitemap, maybe just fix there?
    my @post_aliases = map { $_->{local_href} } _get_series();

    # Allow themes to put in custom headers/footers on posts
    my ( $header, $footer );
    $header = Trog::Renderer->render(
        template    => 'headers/' . $query->{primary_post}{header},
        data        => { theme_dir => $Trog::Themes::td, %$query },
        component   => 1,
        contenttype => 'text/html',
    ) if $query->{primary_post}{header};
    return $header if ref $header eq 'ARRAY';
    $footer = Trog::Renderer->render(
        template    => 'footers/' . $query->{primary_post}{footer},
        data        => { theme_dir => $Trog::Themes::td, %$query },
        component   => 1,
        contenttype => 'text/html',
    ) if $query->{primary_post}{footer};
    return $header if ref $footer eq 'ARRAY';

    # List the available headers/footers
    my $headers = Trog::Themes::templates_in_dir( "headers", 'text/html', 1 );
    my $footers = Trog::Themes::templates_in_dir( "footers", 'text/html', 1 );

    #XXX used to be post.css, but probably not good anymore?
    my $styles = [];

    # Build page title if it wasn't set by a wrapping sub
    $query->{title} = "$query->{domain} : $query->{title}" if $query->{title} && $query->{domain};
    $query->{title} ||= @$tags && $query->{domain} ? "$query->{domain} : @$tags" : undef;

    #Handle paginator vars
    $query->{limit} ||= 25;
    my $limit       = int( $query->{limit} );
    my $now_year    = ( localtime(time) )[5] + 1900;
    my $oldest_year = $now_year - 20;                  #XXX actually find oldest post year

    # Handle post style.
    if ( $query->{style} ) {
        undef $header;
        undef $footer;
    }

    my $older = !@posts ? 0 : $posts[-1]->{created};
    $query->{failure} //= -1;
    $query->{id}      //= '';
    my $newer = !@posts ? 0 : $posts[0]->{created};

    #XXX messed up data has to be fixed unfortunately
    @$tags = List::Util::uniq @$tags;

    #Filter displaying visibility tags
    my @visibuddies = qw{public unlisted private};
    foreach my $post (@posts) {
        @{ $post->{tags} } = grep {
            my $tag = $_;
            !grep { $tag eq $_ } @visibuddies
        } @{ $post->{tags} };
    }

    #XXX note that we are explicitly relying on the first tag to be the ACL
    my $aclselected = $tags->[0] || '';
    my @acls        = map {
        $_->{selected} = $_->{aclname} eq $aclselected ? 'selected' : '';
        $_
    } _post_helper( {}, ['series'], $query->{user_acls} );

    my $forms = Trog::Themes::templates_in_dir( "forms", 'text/html', 1 );

    my $edittype = $query->{primary_post} ? $query->{primary_post}->{child_form}          : $query->{form};
    my $tiled    = $query->{primary_post} ? !$is_admin && $query->{primary_post}->{tiled} : 0;

    state $data;
    $data //= Trog::Data->new($conf);

    # Grab the rest of the tags to dump into the edit form
    my @tags_all = $data->tags();

    #Filter out the visibilities and special series tags
    @tags_all = grep {
        my $subj = $_;
        scalar( grep { $_ eq $subj } qw{public private unlisted admin series about topbar} ) == 0
    } @tags_all;

    @posts = map {
        my $subject = $_;
        my @et      = grep {
            my $subj = $_;
            grep { $subj eq $_ } @tags_all
        } @{ $subject->{tags} };
        @et = grep { $_ ne $aclselected } @et;
        $_->{extra_tags} = \@et;
        $_
    } @posts;
    my @et = List::MoreUtils::singleton( @$tags, @tags_all );

    $query->{author} = $query->{primary_post}{user} // $posts[0]{user};

    my $picker = Trog::Component::EmojiPicker::render();
    return $picker if ref $picker eq 'ARRAY';

    #XXX the only reason this is needed is due to direct=1
    #XXX is this even used?
    my $content = Trog::Renderer->render(
        template => 'posts.tx',
        data     => {
            acls              => \@acls,
            can_edit          => $is_admin,
            forms             => $forms,
            post              => { tags => $tags, extra_tags => \@et, form => $edittype, visibility => $user_visibility, addpost => 1 },
            post_visibilities => \@visibuddies,
            failure           => $query->{failure},
            to                => $query->{to},
            message           => $query->{failure} ? "Failed to add post!" : "Successfully added Post as $query->{id}",
            direct            => $direct,
            title             => $query->{title},
            author            => $query->{primary_post}{user} // $posts[0]{user},
            style             => $query->{style},
            posts             => \@posts,
            like              => $query->{like},
            in_series         => exists $query->{in_series} || !!( $query->{route} =~ m/^\/series\// ),
            route             => $query->{route},
            limit             => $limit,
            pages             => scalar(@posts) == $limit,
            older             => $older,
            newer             => $newer,
            sizes             => [ 25, 50, 100 ],
            rss               => !$query->{id} && !$query->{older},
            tiled             => $tiled,
            category          => $ph,
            subhead           => $query->{subhead},
            header            => $header,
            footer            => $footer,
            headers           => $headers,
            footers           => $footers,
            years             => [ reverse( $oldest_year .. $now_year ) ],
            months            => [ 0 .. 11 ],
            emoji_picker      => $picker,
            embed             => $query->{embed},
            nochrome          => $query->{nochrome},
        },
        contenttype => 'text/html',
        component   => 1,
    );

    # Something exploded
    return $content if ref $content eq "ARRAY";

    return $content if $direct;
    return Trog::Routes::HTML::index( $query, $content, $styles );
}

sub _themed_title ($path) {
    return $path unless %Theme::paths;
    return $Theme::paths{$path} ? $Theme::paths{$path} : $path;
}

sub _post_helper ( $query, $tags, $acls ) {
    state $data;
    $data //= Trog::Data->new($conf);

    $query->{page}  ||= 1;
    $query->{limit} ||= 25;

    return $data->get(
        older        => $query->{older},
        newer        => $query->{newer},
        page         => int( $query->{page} ),
        limit        => int( $query->{limit} ),
        tags         => $tags,
        exclude_tags => $query->{exclude_tags},
        acls         => $acls,
        aclname      => $query->{aclname},
        like         => $query->{like},
        author       => $query->{author},
        id           => $query->{id},
        version      => $query->{version},
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

sub sitemap ($query) {

    state $data;
    $data //= Trog::Data->new($conf);

    state $etag = "sitemap-" . time();
    my ( @to_map, $is_index, $route_type );
    my $warning = '';
    $query->{map} //= '';
    if ( $query->{map} eq 'static' ) {

        # Return the map of static routes
        $route_type = 'Static Routes';
        @to_map     = grep { !defined $routes{$_}->{captures} && !$routes{$_}->{auth} && !$routes{$_}->{noindex} && !$routes{$_}->{nomap} } keys(%routes);
    }
    elsif ( !$query->{map} ) {

        # Return the index instead
        @to_map = ('static');
        my $tot   = $data->count();
        my $size  = 50000;
        my $pages = int( $tot / $size ) + ( ( $tot % $size ) ? 1 : 0 );

        # Truncate pages at 10k due to standard
        my $clamped = $pages > 49999 ? 49999 : $pages;
        $warning = "More posts than possible to represent in sitemaps & index!  Old posts have been truncated." if $pages > 49999;

        foreach my $page ( $clamped .. 1 ) {
            push( @to_map, "$page" );
        }
        $is_index = 1;
    }
    else {
        $route_type = "Posts: Page $query->{map}";

        # Return the map of the particular range of dynamic posts
        $query->{limit} = 50000;
        $query->{page}  = $query->{map};
        @to_map         = _post_helper( $query, [], ['public'] );
    }

    if ( $query->{xml} ) {
        DEBUG("RENDER SITEMAP XML");
        my $sm;
        my $xml_date = time();
        my $fmt      = "xml";
        $fmt .= ".gz" if $query->{compressed};
        if ( !$query->{map} ) {
            require WWW::SitemapIndex::XML;
            $sm = WWW::SitemapIndex::XML->new();
            foreach my $url (@to_map) {
                $sm->add(
                    loc     => "http://$query->{domain}/sitemap/$url.$fmt",
                    lastmod => $xml_date,
                );
            }
        }
        else {
            require WWW::Sitemap::XML;
            $sm = WWW::Sitemap::XML->new();
            my $changefreq = $query->{map} eq 'static' ? 'monthly' : 'daily';
            foreach my $url (@to_map) {
                my $true_uri = "http://$query->{domain}$url";
                if ( ref $url eq 'HASH' ) {
                    my $is_user_page = grep { $_ eq 'about' } @{ $url->{tags} };
                    $true_uri = "http://$query->{domain}/posts/$url->{id}";
                    $true_uri = "http://$query->{domain}/users/$url->{title}" if $is_user_page;
                }
                my %out = (
                    loc        => $true_uri,
                    lastmod    => $xml_date,
                    mobile     => 1,
                    changefreq => $changefreq,
                    priority   => 1.0,
                );

                if ( ref $url eq 'HASH' ) {

                    #add video & preview image if applicable
                    $out{images} = [
                        {
                            loc     => "http://$query->{domain}$url->{href}",
                            caption => $url->{data},
                            title   => substr( $url->{title}, 0, 100 ),
                        }
                      ]
                      if $url->{is_image};

                    # Truncate descriptions
                    my $desc    = substr( $url->{data}, 0, 2048 ) || '';
                    my $href    = $url->{href}                    || '';
                    my $preview = $url->{preview}                 || '';
                    my $domain  = $query->{domain}                || '';
                    $out{videos} = [
                        {
                            content_loc   => "http://$domain$href",
                            thumbnail_loc => "http://$domain$preview",
                            title         => substr( $url->{title}, 0, 100 ) || '',
                            description   => $desc,
                        }
                      ]
                      if $url->{is_video};
                }

                $sm->add(%out);
            }
        }
        my $xml = $sm->as_xml();
        require IO::String;
        my $buf = IO::String->new();
        my $ct  = 'application/xml';
        $xml->toFH( $buf, 0 );
        seek $buf, 0, 0;

        if ( $query->{compressed} ) {
            require IO::Compress::Gzip;
            my $compressed = IO::String->new();
            IO::Compress::Gzip::gzip( $buf => $compressed );
            $ct  = 'application/gzip';
            $buf = $compressed;
            seek $compressed, 0, 0;
        }

        #XXX This is one of the few exceptions where we don't use finish_render, as it *requires* gzip.
        return [ 200, [ "Content-type" => $ct, 'ETag' => $etag ], $buf ];
    }

    @to_map = sort @to_map unless $is_index;
    my $styles = ['sitemap.css'];

    $query->{title}    = "$query->{domain} : Sitemap";
    $query->{template} = 'sitemap.tx',
      $query->{to_map}     = \@to_map,
      $query->{is_index}   = $is_index,
      $query->{route_type} = $route_type,
      $query->{etag}       = $etag;

    return Trog::Routes::HTML::index( $query, undef, $styles );
}

sub _rss ( $query, $subtitle, $posts ) {

    require XML::RSS;
    my $rss  = XML::RSS->new( version => '2.0', stylesheet => '/styles/rss-style.xsl' );
    my $now  = DateTime->from_epoch( epoch => time() );
    my $port = $query->{port} ? ":$query->{port}" : '';
    $rss->channel(
        title         => "$query->{domain}",
        subtitle      => $subtitle,
        link          => "http://$query->{domain}$port/$query->{route}?format=xml",
        language      => 'en',                                                        #TODO localization
        description   => "$query->{domain} : $query->{route}",
        pubDate       => $now,
        lastBuildDate => $now,
    );

    $rss->image(
        title       => $query->{domain},
        url         => "/favicon.ico",
        link        => "http://$query->{domain}$port",
        width       => 32,
        height      => 32,
        description => "$query->{domain} favicon",
    );

    foreach my $post (@$posts) {
        my $url = "http://$query->{domain}$port$post->{local_href}";
        _post2rss( $rss, $url, $post );
        next unless ref $post->{aliases} eq 'ARRAY';
        foreach my $alias ( @{ $post->{aliases} } ) {
            $url = "http://$query->{domain}$port$alias";
            _post2rss( $rss, $url, $post );
        }
    }

    return Trog::Renderer->render(
        template => 'raw.tx',
        data     => {
            etag   => $query->{etag},
            body   => encode_utf8( $rss->as_string ),
            scheme => $query->{scheme},
        },
        headers => { 'Content-Disposition' => 'inline; filename="rss.xml"' },

        #XXX if you do the "proper" content-type of application/rss+xml, browsers download rather than display.
        contenttype => "text/xml",
        code        => 200,
    );
}

sub _post2rss ( $rss, $url, $post ) {
    $rss->add_item(
        title       => $post->{title},
        permaLink   => $url,
        link        => $url,
        enclosure   => { url => $url, type => "text/html" },
        description => "<![CDATA[$post->{data}]]>",
        pubDate     => DateTime->from_epoch( epoch => $post->{created} ),    #TODO format like Thu, 23 Aug 1999 07:00:00 GMT
        author      => $post->{user},                                        #TODO translate to "email (user)" format
    );
}

=head2 manual

Implements the /manual and /lib/* routes.

Basically a thin wrapper around Pod::Html.

=cut

sub manual ($query) {
    return see_also('/login')                    unless $query->{user};
    return Trog::Routes::HTML::forbidden($query) unless grep { $_ eq 'admin' } @{ $query->{user_acls} };

    require Pod::Html;
    require Capture::Tiny;

    #Fix links from Pod::HTML
    $query->{module} =~ s/\.html$//g if $query->{module};
    $query->{failure} //= -1;

    my $infile = $query->{module} ? "$query->{module}.pm" : 'tCMS/Manual.pod';
    return notfound($query) unless -f "lib/$infile";
    my $content = capture { Pod::Html::pod2html( qw{--podpath=lib --podroot=.}, "--infile=lib/$infile" ) };

    return Trog::Routes::HTML::index(
        {
            title     => 'tCMS Manual',
            theme_dir => $Trog::Themes::td,
            content   => $content,
            template  => 'manual.tx',
            is_admin  => 1,
            %$query,
        },
        undef,
        ['post.css'],
    );
}

sub processed ($query) {
    return Trog::Routes::HTML::index(
        {
            title     => "Your request has been processed",
            theme_dir => $Trog::Themes::td,
        },
        "Your request has been processed.<br /><br />You will recieve subsequent communications about this matter via means you have provided earlier.",
        ['post.css']
    );
}

sub metrics ($query) {
    return see_also('/login')                    unless $query->{user};
    return Trog::Routes::HTML::forbidden($query) unless grep { $_ eq 'admin' } @{ $query->{user_acls} };

    $query->{failure} //= -1;

    return Trog::Routes::HTML::index(
        {
            title     => 'tCMS Metrics',
            theme_dir => $Trog::Themes::td,
            template  => 'metrics.tx',
            is_admin  => 1,
            %$query,
        },
        undef,
        ['post.css'],
        ['chart.js'],
    );
}

# basically a file rewrite rule for themes
sub icon ($query) {
    my $path = $query->{route};
    return Trog::FileHandler::serve( Trog::Themes::themed("img/icon/$path") );
}

# TODO make statics, abstract gzipped outputting & header handling
sub rss_style ($query) {
    $query->{port}       = ":$query->{port}" if $query->{port};
    $query->{title}      = qq{<xsl:value-of select="rss/channel/title"/>};
    $query->{no_doctype} = 1;

    # Due to this being html rather than XML, we can't use an include directive.
    $query->{header} = Trog::Renderer->render( template => 'header.tx', data => $query, contenttype => 'text/html', component => 1 );
    $query->{footer} = Trog::Renderer->render( template => 'footer.tx', data => $query, contenttype => 'text/html', component => 1 );

    return Trog::Renderer->render(
        template    => 'rss-style.tx',
        contenttype => 'text/xsl',
        data        => $query,
        code        => 200,
    );
}

sub _build_themed_styles ($styles) {
    my @styles = map { ( Trog::Themes::themed_style("$_") ) } @{ Trog::Utils::coerce_array($styles) };
    return \@styles;
}

sub _build_themed_scripts ($scripts) {
    my @scripts = map { Trog::Themes::themed_script("$_") } @{ Trog::Utils::coerce_array($scripts) };
    return \@scripts;
}

sub finish_render ( $template, $vars, %headers ) {

    #XXX default vars that need to be pulled from config
    $vars->{lang}        //= 'en-US';
    $vars->{title}       //= 'tCMS';
    $vars->{stylesheets} //= [];
    $vars->{scripts}     //= [];

    # Theme-ize the paths
    $vars->{stylesheets}  = [ @{ _build_themed_styles( $vars->{stylesheets} ) } ];
    $vars->{print_styles} = [ @{ _build_themed_styles( $vars->{print_styles} ) } ];
    $vars->{scripts}      = [ map { s/^www\///; $_ } @{ _build_themed_scripts( $vars->{scripts} ) } ];

    # Add in avatars.css, it's special
    push( @{ $vars->{stylesheets} }, "/styles/avatars.css" );

    # Absolute-ize the paths for scripts & stylesheets
    @{ $vars->{stylesheets} }  = map { CORE::index( $_, '/' ) == 0 ? $_ : "/$_" } @{ $vars->{stylesheets} };
    @{ $vars->{print_styles} } = map { CORE::index( $_, '/' ) == 0 ? $_ : "/$_" } @{ $vars->{print_styles} };
    @{ $vars->{scripts} }      = map { CORE::index( $_, '/' ) == 0 ? $_ : "/$_" } @{ $vars->{scripts} };

    # TODO Smash together the stylesheets and minify

    $vars->{contenttype}  //= $Trog::Vars::content_types{html};
    $vars->{cachecontrol} //= $Trog::Vars::cache_control{revalidate};

    $vars->{code} ||= 200;
    $vars->{theme_dir} =~ s/^\/www\/// if $vars->{theme_dir};
    $vars->{header} = Trog::Renderer->render( template => 'header.tx', data => $vars, contenttype => 'text/html', component => 1 );
    $vars->{footer} = Trog::Renderer->render( template => 'footer.tx', data => $vars, contenttype => 'text/html', component => 1 );

    return Trog::Renderer->render( template => $template, data => $vars, contenttype => 'text/html', code => $vars->{code} );
}

1;
