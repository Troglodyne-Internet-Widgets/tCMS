package Trog::Routes::HTML;

use v5.36;
use re '/aa';

no warnings qw{once};

use POSIX qw{strftime};
use Errno qw{ENOENT};
use File::Touch();
use File::Basename qw{basename};
use List::Util();
use List::MoreUtils();
use Ref::Util();
use Capture::Tiny qw{capture};
use HTML::SocialMeta;

use Clone       qw{clone};
use Encode      qw{encode_utf8};
use Digest::MD5 qw{md5_hex};
use Digest::SHA qw{sha256_hex};
use JSON::MaybeXS();
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
use Trog::DataSource;

use CGI::Cookie ();

our $landing_page = 'default.tx';

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
        nocache  => 1,
    },
    '/auth' => {
        method   => 'POST',
        callback => \&Trog::Routes::HTML::login,
        nocache  => 1,
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

    # When we are logged in, we get a diff ver of the page.
    '/secure/password_reset' => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::resetpass,
        auth     => 1,
    },
    '/request_password_reset' => {
        method   => 'POST',
        callback => \&Trog::Routes::HTML::do_resetpass,
        noindex  => 1,
        nocache  => 1,
    },
    '/request_totp_clear' => {
        method   => 'POST',
        callback => \&Trog::Routes::HTML::do_totp_clear,
        noindex  => 1,
        nocache  => 1,
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
    '/admin/sessions' => {
        method   => 'GET',
        auth     => 1,
        callback => \&Trog::Routes::HTML::sessions,
        noindex  => 1,
        nocache  => 1,
    },
    '/guest/screenshot/(.*)/(.*)' => {
        method   => 'GET',
        auth     => 1,
        callback => \&Trog::Routes::HTML::guest_screenshot,

        # 'guest', not 'domain': the router sets $query->{domain} to the
        # request's own host *after* it applies captures, so a capture by that
        # name never survives to the callback.
        captures => [qw{hypervisor guest}],
        noindex  => 1,
        nocache  => 1,
    },
    '/guest/act' => {
        method   => 'POST',
        auth     => 1,
        callback => \&Trog::Routes::HTML::guest_act,
        noindex  => 1,
        nocache  => 1,
    },
    '/guest/reprovision' => {
        method   => 'POST',
        auth     => 1,
        callback => \&Trog::Routes::HTML::guest_reprovision,
        noindex  => 1,
        nocache  => 1,
    },
    '/guest/reprovision/log/(.*)' => {
        method   => 'GET',
        auth     => 1,
        callback => \&Trog::Routes::HTML::guest_reprovision_log,

        # 'guest', not 'domain', for the reason the screenshot route captures it
        # that way -- the router overwrites $query->{domain} with the request's
        # own host after applying captures.
        captures   => [qw{guest}],
        robot_name => '/guest/reprovision/log/',
        noindex    => 1,
        nocache    => 1,
    },
    '/admin/wyzzerdd' => {
        method   => 'GET',
        auth     => 1,
        callback => \&Trog::Routes::HTML::post_wizard,
        noindex  => 1,
        nocache  => 1,
    },
    '/admin/wyzzerdd/save' => {
        method   => 'POST',
        auth     => 1,
        callback => \&Trog::Routes::HTML::post_wizard_save,
        noindex  => 1,
        nocache  => 1,
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
    '/avatar/(.*)' => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::libravatar,
        captures => ['avatar_hash'],
        noindex  => 1,
        nocache  => 1,
    },
    '/favicon.ico' => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::icon,
    },
    '/totp_qr/(.*)' => {
        auth     => 1,
        method   => 'GET',
        callback => \&Trog::Routes::HTML::totp_qr,
    },
    '/styles/rss-style.xsl' => {
        method   => 'GET',
        callback => \&Trog::Routes::HTML::rss_style,
    },
);

# Grab theme routes
my $themed    = 0;
my $theme_dir = Trog::Themes::get_dir();
if ($theme_dir) {

    my $theme_mod = "$theme_dir/routes.pm";
    if ( -f $theme_mod ) {    ## no critic (ProhibitFiletest_f) -- theme routes, else the default theme
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

=head2 _feedback_redirect($query, $to, $failure, $message)

Redirect to $to, carrying the outcome of a save so the destination page can put
it in the jsalert banner.

We redirect rather than rendering in place so that a save stays a
POST-redirect-GET -- refreshing the page the user lands on must not re-submit
the post.  That means the outcome has to travel in the URL, as there is nowhere
else to put it.

=cut

sub _feedback_redirect ( $query, $to, $failure, $message ) {
    my $cookie = _feedback_cookie( $failure, $message );

    # Appended to what see_also() built rather than replacing it, so this still
    # logs and still redirects the way every other redirect in here does.
    my $response = $query->{tpsgi}->see_also($to);
    push( @{ $response->[1] }, 'Set-Cookie' => $cookie );

    return $response;
}

=head2 _feedback_cookie($failure, $message) = STRING

The Set-Cookie which carries a save's outcome to the page it redirects to.

A cookie because a redirect's own headers are gone by the time the destination
renders, and a cookie is the one header that survives the hop.  It used to be a
query parameter, which meant a save's message was in the URL: a validation error
carrying a Carp::Always stack trace built a URL of several thousand characters,
and tPSGI answered the redirect it had just issued with a 419.  The user was
shown neither the page nor the error.

Trimmed to one line, because the banner puts it in a JS string literal, and
capped at $feedback_max characters, because a cookie has a size limit of its own
and nothing a person needs to read is longer than that.  The whole of it is in
the log either way.

=cut

our $feedback_max = 512;

sub _feedback_cookie ( $failure, $message ) {
    $message //= '';
    $message =~ s/\s*\n+\s*/; /g;
    $message =~ s/;\s*$//;
    $message = substr( $message, 0, $feedback_max - 3 ) . '...' if length($message) > $feedback_max;

    my $value = ( $failure ? 1 : 0 ) . ':' . URI::Escape::uri_escape($message);

    # HttpOnly because the banner is rendered server side and no script has any
    # business reading it; Max-Age because a message nobody collected should not
    # follow them around; Path=/ because the destination is wherever they were.
    return "tcmsfeedback=$value; Path=/; HttpOnly; SameSite=Lax; Max-Age=30";
}

=head2 _absorb_feedback($query)

Turn the parameters _feedback_redirect() put in the URL back into the failure
and message the jsalert banner reads.

Done in index() rather than in each route, so that a save can hand feedback to
any destination that renders a page, whichever route ends up serving it.

=cut

sub _absorb_feedback ($query) {
    my ( $failure, $message ) = _feedback_from_cookie( $query->{cookies} );

    # The query parameters are still read, for a redirect issued by a worker
    # which had not been restarted yet, and for anyone who has one bookmarked.
    if ( !defined $failure ) {
        my ( $saved, $failed ) = ( $query->{saved}, $query->{savefailed} );
        return unless defined $saved || defined $failed;

        $failure = defined $failed ? 1       : 0;
        $message = defined $failed ? $failed : $saved;
    }

    $query->{failure} = $failure;
    $query->{message} = $message || ( $failure ? 'Save failed.' : 'Saved.' );

    # A page showing a banner is not a page to cache: the banner is for the one
    # person who just saved something, and a static of it would be served to
    # everybody.  The query parameter form was accidentally safe here, since a
    # query string skips the render cache on its own; a cookie is not.
    $query->{nocache} = 1;

    # Read once.  Without this the banner reappears on every page until the
    # cookie expires.
    $query->{feedback_seen} = 1;

    # Nothing further to navigate to -- we are already there.  Without this the
    # banner's success branch would bounce us onwards.
    delete $query->{to};
    return;
}

=head2 _feedback_from_cookie($cookies) = ($failure, $message)

Pull a save's outcome back out of the cookie _feedback_redirect set.

Returns nothing when there isn't one, so that the caller can fall back to the
query parameters this replaced.

=cut

sub _feedback_from_cookie ($cookies) {
    return () unless $cookies;

    local $@;
    my $jar = eval { CGI::Cookie->parse($cookies) };
    return () unless ref $jar eq 'HASH' && $jar->{tcmsfeedback};

    my $value = $jar->{tcmsfeedback}->value // '';
    my ( $failure, $message ) = $value =~ m/^([01]):(.*)$/s;
    return () unless defined $failure;

    return ( int($failure), URI::Escape::uri_unescape($message) );
}

=head2 index

Implements the primary route used by all pages not behind auth.
Most subsequent functions simply pass content to this function.

=cut

sub index ( $query, $content = '', $i_styles = [], $i_scripts = [] ) {
    $query->{theme_dir} = Trog::Themes::td();

    _absorb_feedback($query);

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

    # Grab the avatar class for the logged in user
    if ( $query->{user} ) {
        $query->{user_class} = Trog::Auth::username2classname( $query->{user} );
    }

    state $data;
    $data //= Trog::Data->new( Trog::Config::get() );

    my ( $search_lang, $search_help ) = _search_language($query);

    # Consumed, so expire it: otherwise the banner reappears on every page the
    # reader visits until the cookie times out on its own.
    my %headers;
    %headers = ( 'Set-Cookie' => 'tcmsfeedback=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0' ) if $query->{feedback_seen};

    return finish_render(
        $tmpl,
        {
            %$query,
            search_lang  => $search_lang,
            search_help  => $search_help,
            theme_dir    => Trog::Themes::td(),
            content      => $content,
            title        => $title,
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
        },
        %headers,
    );
}

sub _build_social_meta ( $query, $title ) {
    return ( undef, undef, undef ) unless $query->{social_meta} && $query->{route} && $query->{domain};

    my $default_tags = $Theme::default_tags;
    $default_tags .= ',' . join( ',', @{ $query->{primary_post}->{tags} } ) if $default_tags && $query->{primary_post}->{tags};

    my $primary_data = ref $query->{primary_post}{data} eq 'ARRAY' ? $query->{primary_post}{data}[0] : $query->{primary_post}{data};
    my $meta_desc    = $primary_data // $Theme::description // "tCMS Site";
    $meta_desc = Trog::Utils::strip_and_trunc($meta_desc) || '';

    my $meta_tags = '';
    my $card_type = 'summary';
    $card_type = 'featured_image' if $query->{primary_post} && $query->{primary_post}{is_image};
    $card_type = 'player'         if $query->{primary_post} && $query->{primary_post}{is_video};

    my $image = $Theme::default_image ? "https://$query->{domain}/" . Trog::Themes::get_dir() . "/$Theme::default_image" : '';
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

    print STDERR "WARNING: Theme misconfigured, social media tags will not be included\n$@\n" if $theme_dir && !$meta_tags;
    return ( $default_tags, $meta_desc, $meta_tags );
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
    my ( $uri, $qr, $failure, $message, $totp ) = Trog::Auth::totp( $active_user, $domain );

    my $now_tm     = time;
    my $now_string = strftime( "%a %b %e T%H:%M:%SZ %Y", gmtime($now_tm) );
    return Trog::Routes::HTML::index(
        {
            title     => 'Enable TOTP 2-Factor Auth',
            theme_dir => Trog::Themes::td(),
            uri       => $uri,
            qr        => $qr,
            failure   => $failure,
            message   => $message,
            template  => 'totp.tx',
            is_admin  => 1,
            cur_code  => $totp->expected_totp_code($now_tm),
            timestamp => $now_string,
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
        return $query->{tpsgi}->see_also( $query->{to} );
    }

    #Check and see if we have no users.  If so we will just accept whatever creds are passed.
    my $hasusers = -f "config/has_users";               ## no critic (ProhibitFiletest_f) -- a flag file, only ever touched
    my $btnmsg   = $hasusers ? "Log In" : "Register";

    my $headers;
    my $has_totp = 0;
    if ( $query->{username} && $query->{password} ) {
        if ( !$hasusers ) {

            # Make the first user
            Trog::Auth::useradd( $query->{username}, $query->{display_name}, $query->{password}, ['admin'], $query->{contact_email} );

            # Add a stub user page and the initial series.
            my $dat = Trog::Data->new( Trog::Config::get() );
            _setup_initial_db( $dat, $query->{username}, $query->{display_name}, $query->{contact_email} );

            # Ensure we stop registering new users
            File::Touch::touch("config/has_users");
        }

        $query->{failed} = 1;
        my $cookie = Trog::Auth::mksession( $query->{username}, $query->{password}, $query->{token}, $query->{ip} // '' );
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
            theme_dir   => Trog::Themes::td(),
            has_users   => $hasusers,
            %$query,
        },
        headers     => $headers,
        contenttype => 'text/html',
        code        => 200,
        nocache     => $query->{nocache},
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
    Trog::Auth::killsession( $query->{user}, $query->{ip} // '' ) if $query->{user};
    delete $query->{user};
    return Trog::Routes::HTML::index($query);
}

=head2 config

Renders the configuration page, or redirects you back to the login page.

=cut

sub config ( $query = {} ) {
    return $query->{tpsgi}->see_also('/login') unless $query->{user};
    return $query->{tpsgi}->forbidden($query)  unless grep { $_ eq 'admin' } @{ $query->{user_acls} };

    $query->{failure} //= -1;

    #XXX ACHTUNG config::simple has this brain damaged behavior of returning a multiple element array when you access something that does not exist.
    #XXX straight up dying would be preferrable.
    #XXX anyways, this means you can NEVER NEVER NEVER access a param from within a hash directly.  YOU HAVE BEEN WARNED!
    my $conf = Trog::Config::get();
    state $theme    = $conf->param('general.theme')              // '';
    state $dm       = $conf->param('general.data_model')         // 'DUMMY';
    state $embeds   = $conf->param('security.allow_embeds_from') // '';
    state $hostname = $conf->param('general.hostname')           // '';

    return Trog::Routes::HTML::index(
        {
            title              => 'Configure tCMS',
            theme_dir          => Trog::Themes::td(),
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

    my $is_admin = grep { $_ eq 'admin' } @{ $query->{user_acls} };

    return Trog::Routes::HTML::index(
        {
            title       => 'Request Authentication Resets',
            theme_dir   => Trog::Themes::td(),
            stylesheets => [qw{config.css}],
            scripts     => [qw{post.js}],
            message     => $query->{message},
            failure     => $query->{failure},
            scheme      => $query->{scheme},
            template    => 'resetpass.tx',
            is_admin    => $is_admin,
            %$query,
        },
        undef,
        [qw{config.css}],
    );
}

sub do_resetpass ($query) {
    my $user = $query->{username};

    # User Does not exist
    return $query->{tpsgi}->forbidden($query) if !Trog::Auth::user_exists($user);

    # User exists, but is not logged in this session
    return $query->{tpsgi}->forbidden($query) if !$query->{user} && Trog::Auth::user_has_session($user);

    my $token   = Trog::Utils::uuid();
    my $newpass = $query->{password} // Trog::Utils::uuid();
    my $res     = Trog::Auth::add_change_request( type => 'reset_pass', user => $user, secret => $newpass, token => $token );
    die "Could not add auth change request!" unless $res;

    # If the user is logged in, just do the deed, otherwise send them the token in an email
    if ( $query->{user} ) {
        return $query->{tpsgi}->see_also("/api/auth_change_request/$token");
    }
    Trog::Email::contact(
        $user,
        "root\@$query->{domain}",
        "$query->{domain}: Password reset URL for $user",
        { uri => "$query->{scheme}://$query->{domain}/api/auth_change_request/$token", template => 'password_reset.tx' }
    );
    return $query->{tpsgi}->see_also("/processed");
}

sub do_totp_clear ($query) {
    my $user = $query->{username};

    # User Does not exist
    return $query->{tpsgi}->forbidden($query) if !Trog::Auth::user_exists($user);

    # User exists, but is not logged in this session
    return $query->{tpsgi}->forbidden($query) if !$query->{user} && Trog::Auth::user_has_session($user);

    my $token = Trog::Utils::uuid();
    my $res   = Trog::Auth::add_change_request( type => 'clear_totp', user => $user, token => $token );
    die "Could not add auth change request!" unless $res;

    # If the user is logged in, just do the deed, otherwise send them the token in an email
    if ( $query->{user} ) {
        return $query->{tpsgi}->see_also("/api/auth_change_request/$token");
    }
    Trog::Email::contact(
        $user,
        "root\@$query->{domain}",
        "$query->{domain}: Password reset URL for $user",
        { uri => "$query->{scheme}://$query->{domain}/api/auth_change_request/$token", template => 'totp_reset.tx' }
    );
    return $query->{tpsgi}->see_also("/processed");
}

sub _get_series ( $edit = 0 ) {
    state $data;
    $data //= Trog::Data->new( Trog::Config::get() );

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
    foreach my $incdir (@INC) {
        my $dir = "$incdir/Trog/Data";
        next unless -d $dir;
        opendir( my $dh, $dir ) || die "Can't opendir $dir: $!";
        my @dmods = map { s/\.pm$//g; $_ } grep { /\.pm$/ && -f "$dir/$_" } readdir($dh);    ## no critic (ProhibitFiletest_f) -- building a menu of module names
        closedir $dh;
        return \@dmods;
    }
    die "Could not find tCMS data modules!  Is tCMS in \@INC?";
}

=head2 _get_datasources

Every Trog::DataSource::* module on disk.

The wizard offers these as somewhere other than the datastore for a post type
to get its posts from, and post_wizard_save checks a submitted one against this
list -- the name ends up in a sidecar and is later require()d, so it has to be
something we found rather than something we were told.

=cut

sub _get_datasources {
    my %found;
    foreach my $incdir (@INC) {
        my $dir = "$incdir/Trog/DataSource";
        next unless -d $dir;
        opendir( my $dh, $dir ) or next;
        $found{"Trog::DataSource::$_"} = 1 foreach map { s/\.pm$//r } grep { /\.pm$/ && -f "$dir/$_" } readdir($dh);    ## no critic (ProhibitFiletest_f) -- building an allowlist of names
        closedir $dh;
    }
    return [ sort keys(%found) ];
}

=head2 _datasource_editable($module)

Whether a post type backed by $module should be given an editor.

A datasource says so with an EDITABLE constant.  One that does not say is
assumed editable, since that is what a post type is unless it has a reason not
to be.

=cut

sub _datasource_editable ($module) {
    return 1 unless $module;
    return 1 unless Trog::DataSource::load($module);
    return 1 unless $module->can('EDITABLE');
    return $module->EDITABLE ? 1 : 0;
}

=head2 config_save

Implements /config/save route.  Saves what little configuration we actually use to config/main.cfg

=cut

sub config_save ($query) {
    return $query->{tpsgi}->see_also('/login') unless $query->{user};
    return $query->{tpsgi}->forbidden($query)  unless grep { $_ eq 'admin' } @{ $query->{user_acls} };

    my $conf = Trog::Config::get();
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

    #We need to reap the children with outdated configuration.
    $query->{tpsgi}->signal_restart_parent();

    return config($query);
}

=head2 themeclone

Clone a theme by copying a directory.

=cut

sub themeclone ($query) {
    return $query->{tpsgi}->see_also('/login') unless $query->{user};
    return $query->{tpsgi}->forbidden($query)  unless grep { $_ eq 'admin' } @{ $query->{user_acls} };

    my ( $theme, $newtheme ) = ( $query->{theme}, $query->{newtheme} );

    my $themedir = 'www/themes';

    $query->{failure} = 1;
    $query->{message} = "Failed to clone theme '$theme' as '$newtheme'!";
    require File::Copy::Recursive;
    if ( $theme && $newtheme && File::Copy::Recursive::dircopy( "$themedir/$theme", "$themedir/$newtheme" ) ) {
        $query->{failure} = 0;
        $query->{message} = "Successfully cloned theme '$theme' as '$newtheme'.";
    }
    return $query->{tpsgi}->see_also('/config');
}

=head2 post_save

Saves posts submitted via the /post pages

=cut

sub post_save ($qq) {
    return $qq->{tpsgi}->see_also('/login') unless $qq->{user};
    return $qq->{tpsgi}->forbidden($qq)     unless grep { $_ eq 'admin' } @{ $qq->{user_acls} };

    my $query = clone($qq);

    my $to = delete $query->{to};

    #Copy this down since it will be deleted later
    my $acls = $query->{acls};

    $query->{tags} = Trog::Utils::coerce_array( $query->{tags} );

    # Support data with multiple pages like presentations
    $query->{data}        = Trog::Utils::coerce_array( $query->{data} ) if $query->{data_is_array};
    $query->{attachments} = Trog::Utils::coerce_array( $query->{attachments} );

    # Filter bits and bobs XXX this is done deeper in, may require removal
    delete $query->{primary_post};
    delete $query->{social_meta};
    delete $query->{deflate};
    delete $query->{acls};

    # Ensure there are no null tags
    @{ $query->{tags} } = grep { defined $_ } @{ $query->{tags} };

    # Posts will always be GET
    $query->{method} = 'GET';

    state $data;
    $data //= Trog::Data->new( Trog::Config::get() );

    # A post that doesn't match its type's schema is the user's mistake, not a
    # server error, so hand the validation errors back rather than dying.
    local $@;
    eval { $data->add($query); 1 } or do {
        my @errors = Ref::Util::is_arrayref($@) ? @{$@} : ($@);
        my $why    = "Post failed validation:\n" . join( "\n", map { _short_error($_) } @errors );

        # The full detail goes to the log; the user gets it in the banner on
        # the page they came from, rather than a dead-end 400.
        WARN("Rejected post from $qq->{user}: $why");
        return _feedback_redirect( $qq, '/secure' . $to, 1, $why );
    };

    # Instruct tpsgi to invalidate the cached render.
    $qq->{tpsgi}->add_post_close_callback(
        sub {
            # XXX there is not a great way to find what needs to be re-rendered because posts can include other posts.
            # As such we just have to nuke all the .html renders.
            $qq->{tpsgi}->invalidate_renders('html');
        }
    );

    # Force a reload of the routing table
    $qq->{tpsgi}->signal_restart_parent();

    return _feedback_redirect( $qq, '/secure' . $to, 0, "Saved post '$query->{title}'." );
}

=head2 profile

Saves / updates new users.

=cut

sub profile ($query) {
    return $query->{tpsgi}->see_also('/login') unless $query->{user};
    return $query->{tpsgi}->forbidden($query)  unless grep { $_ eq 'admin' } @{ $query->{user_acls} };

    # Find the user's post and edit it
    state $data;
    $data //= Trog::Data->new( Trog::Config::get() );

    my @userposts = $data->get( tags => ['about'], acls => [qw{admin}] );

    # Users are always self-authored, you see

    my $user_obj = List::Util::first { ( $_->{user} || '' ) eq $query->{username} } @userposts;

    my $username = $query->{username};
    my $password = $query->{password};
    my $changed =
         $username ne ( $user_obj->{user} // '' )
      || $password
      || ( $query->{contact_email} // '' ) ne ( $user_obj->{contact_email} // '' )
      || ( $query->{display_name}  // '' ) ne ( $user_obj->{display_name}  // '' );

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

    # Validate before touching the auth database, not after.  useradd() does an
    # INSERT OR REPLACE on the user row, which cascades to the session table and
    # logs the user straight out -- doing that and *then* rejecting the post
    # leaves the credentials disagreeing with the profile post they came from.
    my @errors = Trog::DataModule::validate( clone( \%merged ) );
    if (@errors) {
        my $why = "Post failed validation:\n" . join( "\n", @errors );
        WARN("Rejected profile update from $query->{user}: $why");
        return $query->{tpsgi}->badrequest( $query, $why );
    }

    if ($changed) {
        my $for_user = Trog::Auth::acls4user($username);

        #TODO support non-admin users
        my @acls = @$for_user ? @$for_user : qw{admin};
        Trog::Auth::useradd( $username, $merged{display_name}, $password, \@acls, $merged{contact_email} );
    }

    return post_save( \%merged );
}

=head2 post_delete

deletes posts.

=cut

sub post_delete ($query) {
    return $query->{tpsgi}->see_also('/login') unless $query->{user};
    return $query->{tpsgi}->forbidden($query)  unless grep { $_ eq 'admin' } @{ $query->{user_acls} };

    state $data;
    $data //= Trog::Data->new( Trog::Config::get() );

    $data->delete($query) and die "Could not delete post";
    return $query->{tpsgi}->see_also( $query->{to} );
}

=head2 _enrich_post($post, $query, $cache)

Resolve a post type's declared relations onto the post, and run its enrich sub
if it has one.

A type says what it depends on in its sidecar rather than in code here -- see
Trog::DataModule::relations_for.  An entry naming a 'from' field resolves the
UUID in that field into the post it refers to; one without gets every post of
the target type, which is what an editor picker or a "show me all of these"
display wants.

$cache is a per-request memo of the per-type lookups.  Without it a page of
invoices re-scans every entities post once per invoice.

=cut

sub _enrich_post ( $post, $query, $cache = {} ) {
    return unless Ref::Util::is_hashref($post) && $post->{form};

    my $relations = Trog::DataModule::relations_for( $post->{form} );
    foreach my $as ( keys(%$relations) ) {
        my $relation = $relations->{$as};
        next unless Ref::Util::is_hashref($relation);

        my ($target) = ( $relation->{form} // '' ) =~ m/^([A-Za-z0-9_-]+\.tx)$/;
        next unless $target;

        $cache->{$target} //= [ _post_helper( { form => $target }, [], $query->{user_acls} ) ];

        # No 'from' means the relation is the whole set rather than one of them.
        my $from = $relation->{from};
        if ( !$from ) {
            $post->{$as} = $cache->{$target};
            next;
        }

        my $wanted = $post->{$from};
        $post->{$as} = defined $wanted ? List::Util::first { $_->{id} eq $wanted } @{ $cache->{$target} } : undef;
    }

    _enrich_callback( $post, $query );
    return;
}

# Anything a type needs computed rather than merely fetched.  The sub is named
# in the sidecar, so validate it the same way a post's own callback field is --
# a sidecar naming an arbitrary sub is a privilege question, not a typo.
sub _enrich_callback ( $post, $query ) {
    my $meta = Trog::DataModule::type_meta_for( $post->{form} );
    my $sub  = $meta->{'x-tcms-post-type'}{enrich};
    return unless $sub && !ref $sub;

    my ($modname) = $sub =~ m/^([\w:]+)::\w+$/;
    if ( !$modname ) {
        WARN("Post type '$post->{form}' declares a malformed enrich sub '$sub'");
        return;
    }

    my $modpath = $modname;
    $modpath =~ s{::}{/}g;
    $modpath .= '.pm';

    local $@;
    eval { require $modpath; 1 } or do {
        WARN("Post type '$post->{form}' declares enrich sub '$sub', but $modname will not load: $@");
        return;
    };

    no strict 'refs';
    if ( !defined &{$sub} ) {
        WARN("Post type '$post->{form}' declares enrich sub '$sub', which does not exist");
        return;
    }

    my %extra = &{$sub}( $post, $query );
    use strict;

    @$post{ keys(%extra) } = values(%extra);
    return;
}

=head2 series

Series specific view, much like the users/ route
Displays identified series, not all series.

=cut

sub series ($query) {
    my $is_admin = grep { $_ eq 'admin' } @{ $query->{user_acls} };

    # rip away /secure if present
    $query->{route} =~ s|^/secure||;

    #we are either viewed one of two ways, /post/$id or /$aclname
    my ( undef, $aclname, $id ) = split( '/', $query->{route} );
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
    #
    # Deliberately not $query: this is looking up the one series post named by
    # the route, and handing it the reader's pagination pages *that* lookup.
    # Asking for page two of a single post gets nothing, so a series carrying a
    # ?page= in its URL could not find itself and 404'd on its own page.  Latent
    # until something started emitting page numbers -- see _paginate_offset.
    my @posts = _post_helper( { %$query, page => 1, limit => 1 }, ['series'], $query->{user_acls} );

    # The series post carries its *children's* relations, so that an editor
    # picker rendered on this page has something to populate from -- that is
    # what $primary_post.entities is on an invoice series.  Keyed on child_form
    # rather than form: the series is a series.tx, its children are what
    # declare the dependency.
    if ( $posts[0] ) {
        my $relations = Trog::DataModule::relations_for( $posts[0]{child_form} );
        if (%$relations) {

            # Resolve against a stand-in wearing the child's form, then copy
            # only the relation keys back, so nothing else about the series
            # post gets overwritten.
            my $stand_in = { %{ $posts[0] }, form => $posts[0]{child_form} };

            # posts() widens user_acls to what a viewer can actually see, but
            # that happens after this -- so resolving here against the raw list
            # means a logged out visitor resolves every relation against no
            # acls at all, and finds nothing however public the target is.
            my @acls = ( @{ $query->{user_acls} }, 'public' );
            push( @acls, 'private' ) if $is_admin;

            _enrich_post( $stand_in, { %$query, user_acls => \@acls } );
            @{ $posts[0] }{ keys(%$relations) } = @{$stand_in}{ keys(%$relations) };
        }
    }

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

=head2 libravatar

Implements the libravatar protocol (https://wiki.libravatar.org/running_your_own/).
Accepts GET /avatar/{hash} where {hash} is the MD5 or SHA-256 of the user's
lowercased email address, and redirects to their profile avatar image.
Returns 404 when no matching user is found or the user has no avatar.

=cut

sub libravatar ($query) {
    my $hash = lc( $query->{avatar_hash} // '' );

    my $users = Trog::Auth::users_with_emails();
    my $matched_user;
    for my $u (@$users) {
        next unless $u->{contact_email};
        my $email = lc( $u->{contact_email} );
        if ( $hash eq sha256_hex($email) || $hash eq md5_hex($email) ) {
            $matched_user = $u->{name};
            last;
        }
    }

    return $query->{tpsgi}->notfound($query) unless $matched_user;

    my @posts   = _post_helper( { author => $matched_user }, ['about'], [qw{public admin}] );
    my $preview = @posts ? $posts[0]->{preview} : '';

    return $query->{tpsgi}->notfound($query) unless $preview;

    return $query->{tpsgi}->redirect_permanent("/$preview");
}

=head2 users

Implements direct user profile view.

=cut

sub users ($query) {

    # rip away /secure if present
    $query->{route} =~ s|^/secure||;

    # Capture the username
    my ( undef, undef, $display_name ) = split( '/', $query->{route} );
    $display_name = URI::Escape::uri_unescape($display_name);

    my $username = Trog::Auth::display2username($display_name);
    return $query->{tpsgi}->notfound($query) unless $username;

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

    # Before we build the render data, not after: posts.tx is rendered here and
    # handed to index() as content, so index()'s own absorb would be too late.
    _absorb_feedback($query);

    # Allow rss.xml to tell what posts to loop over
    my $fmt = $query->{format} || '';

    #Process the input URI to capture tag/id
    $query->{route} //= $query->{to};

    # rip away /secure if present
    $query->{route} =~ s|^/secure||;

    my ( undef, undef, $id ) = split( '/', $query->{route} );

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

    # A post type can say its posts come from somewhere other than the
    # datastore -- see Trog::DataSource::Virt, which builds them out of libvirt
    # guests.  The series is still an ordinary post; only its children are
    # synthesized, and they are rebuilt on every view rather than stored.
    @posts = _datasource_posts( $query, \@posts );

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
        return $query->{tpsgi}->notfound($query) unless @posts;
    }

    # Set the eTag so that we don't get a re-fetch
    $query->{etag} = "$posts[0]{id}-$posts[0]{version}" if @posts;

    #Correct page headers
    my $ph = $themed ? _themed_title( $query->{route} ) : $query->{route};

    return _rss( $query, $ph, \@posts ) if $fmt eq 'rss';

    #XXX Is used by the sitemap, maybe just fix there?
    my @post_aliases = map { $_->{local_href} } _get_series();

    # List the available headers/footers
    my $headers = Trog::Themes::themed_templates_in_dir( "headers", 'text/html', 1 );
    my $footers = Trog::Themes::themed_templates_in_dir( "footers", 'text/html', 1 );

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

    # Datasource pages page by offset, everything else by the created cursor.
    # See _paginate_offset() for why they cannot share.
    my ( $paginate_offset, $page_of, $pages_total ) = ( 0, 1, 1 );
    if ( $query->{is_datasource} ) {
        $paginate_offset = 1;
        ( $page_of, $pages_total, @posts ) = _paginate_offset( $query, $limit, @posts );
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

    my $forms = Trog::Themes::themed_templates_in_dir( "forms", 'text/html', 1 );

    my $edittype = $query->{primary_post} ? $query->{primary_post}->{child_form}          : $query->{form};
    my $tiled    = $query->{primary_post} ? !$is_admin && $query->{primary_post}->{tiled} : 0;

    state $data;
    $data //= Trog::Data->new( Trog::Config::get() );

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

    # Resolve each post's declared relations.  One cache for the whole page, so
    # 25 invoices don't mean 25 scans of every entities post.
    my %relation_cache;
    _enrich_post( $_, $query, \%relation_cache ) foreach @posts;

    #XXX the only reason this is needed is due to direct=1
    # Last thing before the data becomes a page: anything a type marks private
    # goes no further for a reader who cannot edit.  Deliberately after the
    # datasource has run -- a datasource may well need a private field, like
    # the connection uri it takes to reach a hypervisor, to produce anything
    # at all.
    if ( !$is_admin ) {
        my %seen;
        _redact_private( $_, \%seen ) foreach ( @posts, $query->{primary_post} );
    }

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
            message           => $query->{message} // ( $query->{failure} ? "Failed to add post!" : "Successfully added Post as $query->{id}" ),
            direct            => $direct,
            title             => $query->{title},
            author            => $query->{primary_post}{user} // $posts[0]{user},
            primary_post      => $query->{primary_post},
            style             => $query->{style},
            posts             => \@posts,
            like              => $query->{like},
            in_series         => exists $query->{in_series} || !!( $query->{route} =~ m/^\/series\// ),
            route             => $query->{route},
            limit             => $limit,
            pages             => $paginate_offset ? $pages_total > 1 : scalar(@posts) == $limit,
            paginate_offset   => $paginate_offset,
            page              => $page_of,
            pages_total       => $pages_total,
            older             => $older,
            newer             => $newer,
            sizes             => [ 25, 50, 100 ],
            rss               => !$query->{id} && !$query->{older},
            tiled             => $tiled,
            category          => $ph,
            subhead           => $query->{subhead},
            headers           => $headers,
            footers           => $footers,
            years             => [ reverse( $oldest_year .. $now_year ) ],
            months            => [ 0 .. 11 ],
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

=head2 _redact_private($post, $seen)

Drop the fields a post type marks private, for a reader who isn't an editor.

Done to the data on its way to the template rather than with a guard inside the
template: a type can be rendered by more than one template, templates get
edited by people who did not write the type, and a value that was never handed
over cannot be printed by mistake.  Recurses, because a post's relations are
posts too and carry their own private fields.

=cut

sub _redact_private ( $post, $seen = {} ) {
    return unless Ref::Util::is_hashref($post);

    # Relations can point back at what pulled them in.
    return if $seen->{$post}++;

    if ( $post->{form} ) {
        delete $post->{$_} foreach @{ Trog::DataModule::private_fields_for( $post->{form} ) };
    }

    foreach my $value ( values(%$post) ) {
        if    ( Ref::Util::is_hashref($value) )  { _redact_private( $value, $seen ) }
        elsif ( Ref::Util::is_arrayref($value) ) { _redact_private( $_,     $seen ) foreach @$value }
    }
    return;
}

=head2 _datasource_posts($query, $posts)

Swap a series' children for whatever its datasource says they are, if its child
type declares one.

Returns the posts unchanged for every ordinary type, which is nearly all of
them -- this is a hook, not a detour every page takes.

=cut

sub _datasource_posts ( $query, $posts ) {
    my $series = $query->{primary_post};
    return @$posts unless Ref::Util::is_hashref($series) && $series->{child_form};

    my $source = Trog::DataSource::for_type( $series->{child_form} );
    return @$posts unless $source;
    return @$posts unless Trog::DataSource::load($source);

    my $builder = $source->can('posts');
    if ( !$builder ) {
        WARN("Datasource '$source' has no posts() to call");
        return @$posts;
    }

    local $@;
    my @synthesized = eval { $builder->( $series, $query ) };
    if ($@) {
        my $err = "$@";
        $err =~ s/\n.*//s;
        WARN("Datasource '$source' failed: $err");
        return @$posts;
    }

    # The search the reader typed was applied to the datastore by get(), and
    # then thrown away with the posts it filtered -- these are built fresh and
    # have never been near it.  Ask the source to apply it, or apply the default
    # on its behalf, so that searching a datasource page searches the page.
    my $filter = $source->can('filter') // \&Trog::DataSource::filter;

    my @filtered = eval { $filter->( $query, @synthesized ) };
    if ($@) {
        my $err = "$@";
        $err =~ s/\n.*//s;
        WARN("Datasource '$source' could not filter its posts: $err");
        @filtered = @synthesized;
    }

    # Pagination hands out page 2 of an order, so settle on one.
    my $order   = $source->can('order') // \&Trog::DataSource::order;
    my @ordered = eval { $order->( $query, @filtered ) };
    if ($@) {
        my $err = "$@";
        $err =~ s/\n.*//s;
        WARN("Datasource '$source' could not order its posts: $err");
        @ordered = @filtered;
    }

    # Which the paginator below reads, since these page by offset rather than by
    # the created cursor stored posts use.
    $query->{is_datasource} = 1;

    # A source which cannot say when its posts go stale must not have its pages
    # saved as statics: nothing else would ever invalidate them, so the cached
    # copy could never become right again.  See Trog::DataSource::cacheable.
    $query->{nocache} = 1 unless Trog::DataSource::cacheable($source);

    return @ordered;
}

=head2 _paginate_offset($query, $limit, @posts) = ($page, $pages_total, @page_of_posts)

The slice of @posts the reader asked for, by page number.

Stored posts page by a cursor: the datastore is asked for the $limit posts older
than a timestamp, and the paginator hands back the oldest one on the page as the
next cursor.  That is the right shape when the alternative is reading the whole
datastore to skip most of it.

It is the wrong shape for a datasource, which has already built every post by
the time we see them -- and it does not work at all for one which stamps them
all with the time it built them, as libvirt guests are.  Every cursor on such a
page is the same instant, so Prev asks for everything older than now and gets
nothing.  Offset costs nothing here and moves.

=cut

sub _paginate_offset ( $query, $limit, @posts ) {
    $limit = 25 if !$limit || $limit < 1;

    my $total       = scalar(@posts);
    my $pages_total = $total ? int( ( $total + $limit - 1 ) / $limit ) : 1;

    # Straight off a query string, so digits only -- the same coercion older and
    # newer get, rather than int() warning its way through a word.  Past the end
    # shows the last page rather than an empty one, which is what a stale
    # bookmark deserves.
    ( my $wanted = $query->{page} // '' ) =~ s/[^0-9]//g;
    my $page = length($wanted) ? int($wanted) : 1;
    $page = 1            if $page < 1;
    $page = $pages_total if $page > $pages_total;

    my $offset = ( $page - 1 ) * $limit;
    my @slice  = $offset < $total ? @posts[ $offset .. List::Util::min( $offset + $limit, $total ) - 1 ] : ();

    return ( $page, $pages_total, @slice );
}

=head2 _search_language($query)

What to tell the reader the search box searches, as (language, help link).

The data model's answer describes what it can do to the datastore, which is the
right answer for nearly every page.  It is the wrong one for a page whose posts
are built by a datasource rather than read out of the datastore, so such a page
gets to say so.

=cut

sub _search_language ($query) {
    state $data;
    $data //= Trog::Data->new( Trog::Config::get() );

    my $series = $query->{primary_post};
    my $source = Ref::Util::is_hashref($series) && $series->{child_form} ? Trog::DataSource::for_type( $series->{child_form} ) : undef;

    return ( $data->lang(), $data->help() ) unless $source && Trog::DataSource::load($source);

    my $lang = $source->can('lang') // \&Trog::DataSource::lang;
    my $help = $source->can('help') // \&Trog::DataSource::help;

    return ( scalar $lang->(), scalar $help->() );
}

sub _post_helper ( $query, $tags, $acls ) {
    state $data;
    $data //= Trog::Data->new( Trog::Config::get() );

    $query->{page}  ||= 1;
    $query->{limit} ||= 25;

    my @d = $data->get(
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
        form         => $query->{form},
    );
    return map {
        my $subj = $_;
        $subj->{local_href} = "/secure$_->{local_href}";
        $subj
    } @d if $query->{user};
    return @d;
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
    $data //= Trog::Data->new( Trog::Config::get() );

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
    return $query->{tpsgi}->see_also('/login') unless $query->{user};
    return $query->{tpsgi}->forbidden($query)  unless grep { $_ eq 'admin' } @{ $query->{user_acls} };

    require Pod::Html;
    require Capture::Tiny;

    #Fix links from Pod::HTML
    $query->{module} =~ s/\.html$//g if $query->{module};
    $query->{failure} //= -1;

    my $infile = $query->{module} ? "$query->{module}.pm" : 'tCMS/Manual.pod';
    my $found  = 0;
    foreach my $libdir (@INC) {
        $found = $libdir if -f "$libdir/$infile";    ## no critic (ProhibitFiletest_f) -- which @INC dir supplies the pod
        last             if $found;
    }
    return $query->{tpsgi}->notfound($query) unless $found;

    my $content = capture { Pod::Html::pod2html( qw{--podpath=lib --podroot=.}, "--infile=$found/$infile" ) };

    return Trog::Routes::HTML::index(
        {
            title     => 'tCMS Manual',
            theme_dir => Trog::Themes::td(),
            content   => $content,
            template  => 'manual.tx',
            is_admin  => 1,
            %$query,
        },
        undef,
        ['post.css'],
    );
}

=head2 processed

Implements /processed.

The "we got it, go check your email" page, shown after a request that finishes
out of band -- password and TOTP resets, chiefly.  Deliberately says nothing
about whether the account existed.

=cut

sub processed ($query) {
    return Trog::Routes::HTML::index(
        {
            title     => "Your request has been processed",
            theme_dir => Trog::Themes::td(),
        },
        "Your request has been processed.<br /><br />You will recieve subsequent communications about this matter via means you have provided earlier.",
        ['post.css']
    );
}

=head2 metrics

Implements /metrics.  Admin only.

Renders the request metrics dashboard.  The page pulls its actual numbers from
/api/requests_per over XHR and draws them with chart.js, so there's nothing to
compute here.

=cut

sub metrics ($query) {
    return $query->{tpsgi}->see_also('/login') unless $query->{user};
    return $query->{tpsgi}->forbidden($query)  unless grep { $_ eq 'admin' } @{ $query->{user_acls} };

    $query->{failure} //= -1;

    return Trog::Routes::HTML::index(
        {
            title     => 'tCMS Metrics',
            theme_dir => Trog::Themes::td(),
            template  => 'metrics.tx',
            is_admin  => 1,
            %$query,
        },
        undef,
        ['post.css'],
        ['chart.js'],
    );
}

=head2 sessions

Implements /sessions.  Admin only.

The session audit log: logins, logouts and failures, most recent first.
Filterable by username and event type via the filter_user and filter_event
parameters, and capped by limit (100 by default).

Timestamps are formatted here rather than in the template, and session ids are
truncated to their first 8 characters -- there's no reason to put a live
session id on a page.

=cut

sub sessions ($query) {
    return $query->{tpsgi}->see_also('/login') unless $query->{user};
    return $query->{tpsgi}->forbidden($query)  unless grep { $_ eq 'admin' } @{ $query->{user_acls} };

    my $limit  = int( $query->{limit} // 100 );
    my $events = Trog::Auth::audit_log(
        limit      => $limit,
        username   => $query->{filter_user}  // '',
        event_type => $query->{filter_event} // '',
    );

    # Format timestamps for display
    @$events = map {
        my $e = {%$_};
        my @t = localtime( $e->{event_time} );
        $e->{event_ts}      = sprintf( '%04d-%02d-%02d %02d:%02d:%02d', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0] );
        $e->{session_short} = $e->{session_id} ? substr( $e->{session_id}, 0, 8 ) . '...' : '';
        $e
    } @$events;

    return Trog::Routes::HTML::index(
        {
            title        => 'tCMS Session Audit Log',
            theme_dir    => Trog::Themes::td(),
            template     => 'sessions.tx',
            is_admin     => 1,
            events       => $events,
            limit        => $limit,
            filter_user  => $query->{filter_user}  // '',
            filter_event => $query->{filter_event} // '',
            %$query,
        },
        undef,
        ['post.css'],
    );
}

# The canned includes the wizard is willing to splice into a generated form.
# Deliberately a whitelist keyed on the checkbox name -- the include name ends
# up interpolated straight into a template file, so it can never come from the
# submitted data.
our %wizard_includes = (
    inc_preview     => 'preview.tx',
    inc_visibility  => 'visibility.tx',
    inc_acls        => 'acls.tx',
    inc_tags        => 'tags.tx',
    inc_aliases     => 'aliases.tx',
    inc_attachments => 'attachments.tx',
);

# Emitted in this order, so generated forms read like the hand-written ones.
our @wizard_include_order = qw{inc_preview inc_visibility inc_acls inc_tags inc_aliases inc_attachments};

# Every checkbox on the wizard, and which of them start out ticked.
# Every post has a title, a visibility and a set of acls, so a type does not
# get to decide whether its editor collects them -- see post_wizard_save.
our @wizard_mandatory = qw{inc_title_input inc_visibility inc_acls};

our @wizard_optional_includes = grep {
    my $include = $_;
    !grep { $include eq $_ } @wizard_mandatory
} @wizard_include_order;

our @wizard_checkboxes         = ( qw{wrapper inc_post_title inc_post_tags}, @wizard_optional_includes, 'overwrite' );
our %wizard_checked_by_default = map { $_ => 1 } qw{wrapper inc_post_title inc_post_tags inc_preview inc_tags inc_aliases};

# Which HTML input the wizard emits, and what that field is in the sidecar's
# OpenAPIv3 schema.  No 'file': _process() in Trog::DataModule only knows how to
# turn the four hardcoded upload fields into hrefs, so a custom file field would
# store an HTTP::Body::OctetStream that nothing ever picks up.  Point folks at
# the attachment uploader instead.
our %wizard_field_types = (
    relation => { type => 'relation' },
    text     => { type => 'string' },
    url      => { type => 'string' },
    date     => { type => 'string' },
    textarea => { type => 'string' },
    number   => { type => 'integer' },
    checkbox => { type => 'boolean' },
);

# Field names which aren't in %schema but would still collide with something.
our @wizard_reserved = qw{app to form data_is_array addpost extra_tags is_image is_video is_audio is_profile content_type version};

=head2 guest_screenshot

Implements GET /guest/screenshot/$hypervisor/$guest.  Admin only.

Served as its own route rather than inlined into the guest listing, so that a
page of guests renders immediately and the browser fetches the console
captures in parallel instead of us taking them one after another.

=cut

sub guest_screenshot ($query) {
    return $query->{tpsgi}->see_also('/login') unless $query->{user};
    return $query->{tpsgi}->forbidden($query)  unless grep { $_ eq 'admin' } @{ $query->{user_acls} };

    my $hypervisor = _guest_hypervisor( $query, $query->{hypervisor} );
    return $query->{tpsgi}->notfound($query) unless $hypervisor;

    require Trog::DataSource::Virt;
    my ( $path, $why ) = Trog::DataSource::Virt::screenshot( $hypervisor, $query->{guest} );
    if ( !$path ) {
        WARN("Could not screenshot '$query->{guest}': $why");
        return $query->{tpsgi}->notfound($query);
    }

    return $query->{tpsgi}->serve(
        $query->{route},  $path, $query->{start}, $query->{streaming},
        $query->{ranges}, $query->{last_fetched}, $query->{deflate},
    );
}

=head2 guest_act

Implements POST /guest/act.  Admin only.

Powering a guest on or off, snapshotting it, or destroying it.  Separate from
everything that merely reads a guest, and the only route which reaches
Trog::DataSource::Virt::act.

=cut

sub guest_act ($query) {
    return $query->{tpsgi}->see_also('/login') unless $query->{user};
    return $query->{tpsgi}->forbidden($query)  unless grep { $_ eq 'admin' } @{ $query->{user_acls} };

    my $to = $query->{to} || '/';

    my $hypervisor = _guest_hypervisor( $query, $query->{hypervisor} );
    return _feedback_redirect( $query, $to, 1, 'No such hypervisor.' ) unless $hypervisor;

    require Trog::DataSource::Virt;

    # Same reason the screenshot route captures 'guest': a form field called
    # 'domain' would be overwritten by the router with the request's host.
    my ( $ok, $message ) = Trog::DataSource::Virt::act(
        $query->{action}, $hypervisor->{conn_uri}, $query->{guest}, $query->{user},
    );

    return _feedback_redirect( $query, $to, $ok ? 0 : 1, "$query->{guest}: $message" );
}

=head2 guest_reprovision

Implements POST /guest/reprovision.  Admin only.

Rebuilding a guest from the recipe it was provisioned with: bin/new_config in
the provisioners repository, and then bin/provision in trog-provisioner.  The
only route which reaches Trog::DataSource::ProvisionedVirt::reprovision.

This is not a recoverable operation, so read that function before changing
anything here.  It refuses for the guest tCMS is itself running on, and the
passphrase new_config asks for arrives with the request and is not stored.

=cut

sub guest_reprovision ($query) {
    return $query->{tpsgi}->see_also('/login') unless $query->{user};
    return $query->{tpsgi}->forbidden($query)  unless grep { $_ eq 'admin' } @{ $query->{user_acls} };

    my $to = $query->{to} || '/';

    require Trog::DataSource::ProvisionedVirt;

    # 'guest' rather than 'domain', for the reason the screenshot route captures
    # it that way: the router overwrites $query->{domain} with the request's own
    # host, so a form field by that name never arrives.
    my ( $ok, $message ) = Trog::DataSource::ProvisionedVirt::reprovision(
        domain     => $query->{guest},
        passphrase => $query->{passphrase},
        user       => $query->{user},
    );

    # Deleted rather than merely unused: this hash is cloned, logged around and
    # handed to renderers, and the passphrase has no business in any of that.
    delete $query->{passphrase};

    return _feedback_redirect( $query, $to, $ok ? 0 : 1, ( $query->{guest} // 'guest' ) . ": $message" );
}

=head2 guest_reprovision_log

Implements GET /guest/reprovision/log/$guest.  Admin only.

The whole log of a guest's last reprovision, which the listing shows only the
tail of.  Nobody is waiting on the process which writes it, so this is the only
account of what happened there is.

Admin only and served rather than linked directly, because it lives in logs/
rather than under www/ -- and because the output of a provisioner is a
reasonable place for a hostname, an IP plan or a package list to turn up.

=cut

sub guest_reprovision_log ($query) {
    return $query->{tpsgi}->see_also('/login') unless $query->{user};
    return $query->{tpsgi}->forbidden($query)  unless grep { $_ eq 'admin' } @{ $query->{user_acls} };

    require Trog::DataSource::ProvisionedVirt;

    my $log = Trog::DataSource::ProvisionedVirt::log_for( $query->{guest} );
    return $query->{tpsgi}->notfound($query) unless defined $log;

    return Trog::Renderer->render(
        template    => 'reprovision_log.tx',
        contenttype => 'text/plain',
        code        => 200,
        data        => { %$query, body => $log },
    );
}

# The hypervisor post a guest route was asked about.  Looked up rather than
# taken from the request: the connection URI is not something a form gets to
# hand us.
sub _guest_hypervisor ( $query, $id ) {
    return undef unless $id;
    my @found = _post_helper( { id => $id }, [], $query->{user_acls} );
    return undef unless @found && ( $found[0]{conn_uri} // '' );
    return $found[0];
}

=head2 post_wizard

Implements /admin/wyzzerdd.  Admin only.

The post type wizard: lists the post types which currently exist and offers a
form for building a new one.  See post_wizard_save() for what happens when that
form comes back.

Re-rendered by post_wizard_save() on both success and failure, so it keeps the
submitted values and checkbox states rather than making the admin retype
everything after a rejected submission.

=cut

sub post_wizard ($query) {
    return $query->{tpsgi}->see_also('/login') unless $query->{user};
    return $query->{tpsgi}->forbidden($query)  unless grep { $_ eq 'admin' } @{ $query->{user_acls} };

    $query->{failure} //= -1;

    # Get the existing post types
    my $forms = Trog::Themes::themed_templates_in_dir( "forms", 'text/html', 1 );

    # Sticky checkboxes.  Nothing is submitted on a fresh GET, so fall back to
    # the defaults rather than rendering everything unticked.
    my %checked = map { $_ => ( $query->{wizard_submitted} ? $query->{$_} : $wizard_checked_by_default{$_} ) ? 'checked' : '' } @wizard_checkboxes;

    return Trog::Routes::HTML::index(
        {
            # Sticky form values first, so a failed submission doesn't lose the
            # admin's work -- but everything the template actually depends on is
            # set *after* this, as the whole of %$query is attacker controlled.
            %$query,
            title             => 'tCMS Post Wizard',
            theme_dir         => Trog::Themes::td(),
            template          => 'post_wizard.tx',
            is_admin          => 1,
            forms             => $forms,
            forms_dir         => Trog::Themes::forms_dir(),
            types             => _wizard_types_json($forms),
            type_names        => [ map { ( $_ =~ s/\.tx$//r ) } @$forms ],
            description       => _wizard_description( $query->{description} ),
            datasources       => _get_datasources(),
            datasource        => _wizard_scalar( $query->{datasource} ),
            checked           => \%checked,
            name              => _wizard_scalar( $query->{name} ),
            title_placeholder => _wizard_scalar( $query->{title_placeholder} ),
            body_form         => _wizard_scalar( $query->{body_form} ),
            display           => _wizard_scalar( $query->{display} ),
            failure           => $query->{failure},
            message           => $query->{message} // '',
            to                => $query->{to}      // '',
        },
        undef,
        ['post.css'],
    );
}

=head2 post_wizard_save

Implements POST /admin/wyzzerdd/save.

Writes a new post type template into whichever forms directory is currently in
use, along with a JSON sidecar naming its custom fields so that
Trog::DataModule::schema_for will merge it over the base post schema, so the
type's own fields survive validation at save time.

=cut

sub post_wizard_save ($query) {
    return $query->{tpsgi}->see_also('/login') unless $query->{user};
    return $query->{tpsgi}->forbidden($query)  unless grep { $_ eq 'admin' } @{ $query->{user_acls} };

    # Anchored capture rather than a substitution, so anything containing a '/'
    # or a '..' simply fails to match instead of being silently scrubbed into
    # something that still escapes the directory.
    my ($name) = _wizard_scalar( $query->{name} ) =~ m/^([A-Za-z0-9_-]+)$/;
    return _wizard_fail( $query, "Post type names may only contain letters, numbers, '-' and '_'." ) unless $name;

    # Whichever forms dir is in use: the theme's if it has one, the stock one
    # otherwise.  Never mkdir it -- silently conjuring a forms/ dir inside a
    # theme is not something an admin asked for by pressing this button.
    my $dir = Trog::Themes::forms_dir();

    # -d only.  A -w here would check mode bits against our uid, which says
    # nothing about read-only mounts, ACLs or immutable flags -- and it is the
    # files, not the directory, that get written.  The eval around the two
    # spew_utf8 calls below reports the real errno when a write actually fails.
    return _wizard_fail( $query, "Forms directory '$dir' does not exist." ) unless -d $dir;

    my $tx_file   = "$dir/$name.tx";
    my $json_file = "$dir/$name.json";

    my $overwriting = -e $tx_file;
    return _wizard_fail( $query, "Post type '$name.tx' already exists.  Tick 'Overwrite' if you meant to replace it." )
      if $overwriting && !$query->{overwrite};

    # Whitelisted against what is actually on disk: this name goes into a
    # sidecar and is require()d later, so a regex is not enough.
    my $datasource = _wizard_scalar( $query->{datasource} );
    if ( $datasource && !grep { $_ eq $datasource } @{ _get_datasources() } ) {
        return _wizard_fail( $query, "'$datasource' is not a datasource I can find." );
    }

    my $fields = _wizard_fields($query);

    # Not up for discussion.  A post with no visibility gets an undef pushed
    # into its tags by _process, which is a tag nothing matches -- so the post
    # is invisible to everyone but an admin, for no reason anybody chose.  A
    # title and a set of acls are equally non-negotiable: every other form has
    # them, and a type whose editor cannot set them produces posts nobody can
    # title or restrict.
    $query->{$_} = 1 foreach @wizard_mandatory;

    my @includes  = grep { $query->{$_} } @wizard_include_order;
    my $body_form = _wizard_scalar( $query->{body_form} ) eq 'form_multi.tx' ? 'form_multi.tx' : 'form_common.tx';

    my $spec = _wizard_sidecar(
        $name, $fields, \@includes, $body_form, $datasource,
        {
            description       => _wizard_description( $query->{description} ),
            display           => _wizard_scalar( $query->{display} ),
            title_placeholder => _wizard_scalar( $query->{title_placeholder} ),
            map { $_ => $query->{$_} ? 1 : 0 } qw{wrapper inc_post_title inc_post_tags},
        }
    );

    local $@;
    eval {
        Path::Tiny::path($tx_file)->spew_utf8( _wizard_template( $query, $fields, \@includes, $body_form, $datasource ) );
        Path::Tiny::path($json_file)->spew_utf8( JSON::MaybeXS->new( pretty => 1, canonical => 1 )->encode($spec) );
        1;
    } or return _wizard_fail( $query, "Failed to write post type '$name': $@" );

    INFO("Post type '$name' written to $tx_file by $query->{user}");

    # Whatever the data model makes of an indexed field, it wants the whole
    # picture rather than this type's share of it -- see _wizard_reindex.
    my $index_error = _wizard_reindex( $name, $fields );
    return _wizard_fail( $query, "Post type '$name' was written, but indexing its fields failed: $index_error" ) if $index_error;

    # Nothing else is needed to publish a new type: themed_templates_in_dir()
    # re-reads
    # the directory every call, and Xslate resolves includes lazily, so both the
    # wizard's own list and the series child_form dropdown pick it up on the
    # next request without a restart.  Overwriting an *existing* type is another
    # matter -- that changes how already-rendered anonymous pages should look.
    if ($overwriting) {
        $query->{tpsgi}->add_post_close_callback(
            sub {
                $query->{tpsgi}->invalidate_renders('html');
            }
        );
    }

    return post_wizard(
        {
            %$query,
            wizard_submitted => 1,
            failure          => 0,
            message          => "Created post type '$name.tx'.",
            to               => '/admin/wyzzerdd',
        }
    );
}

=head2 _short_error($error) = STRING

An error as a person should see it: the first line, without the file and line
number Perl glued onto the end.

add() dies with an arrayref of validation errors precisely so that they arrive
clean, but a failure further down -- a write that could not land, say -- is an
ordinary string die, and Carp::Always decorates those with the entire call
stack.  That whole thing used to go to the user.

The undecorated original is logged; this is only what reaches the banner.

=cut

sub _short_error ( $error = '' ) {
    $error = "$error";
    $error =~ s/\n.*//s;
    $error =~ s/\s+at\s+\S+\s+line\s+\d+\.?\s*$//;
    return $error;
}

=head2 _wizard_reindex($name, $fields)

Bring the data model's idea of which custom fields are queryable into line with
what the post types on disk declare.

Every type's indexed fields, not just the one that was saved: two types can
declare a field of the same name, so reconciling against one of them alone would
have saving that type drop the other's index.

The type being saved is taken from the field list in hand rather than by reading
back the sidecar just written.  schema_for() caches on the mtime of the forms
directory, which has one second of resolution, so a read here can legitimately
land on the generation before this save.

Returns the error if there was one, and nothing if all was well.  A failure to
index is not a failure to create the post type: the type is written by this
point, works, and is only missing an optimisation.

=cut

sub _wizard_reindex ( $name, $fields ) {
    my %indexed = map { $_->{name} => 1 } grep { $_->{indexed} } @$fields;

    my $this_type = "$name.tx";
    foreach my $form ( @{ Trog::Themes::themed_templates_in_dir( 'forms', 'text/html', 1 ) } ) {
        next if $form eq $this_type;
        $indexed{$_} = 1 foreach @{ Trog::DataModule::indexed_fields_for($form) };
    }

    local $@;
    eval {
        my $data = Trog::Data->new( Trog::Config::get() );
        $data->index_fields( sort keys %indexed );
        1;
    } or do {
        my $error = $@;
        WARN("Could not reconcile custom field indexes: $error");
        return $error;
    };

    return;
}

=head2 _wizard_types($forms) = HASHREF

Every post type on disk, in the shape the wizard's form is in.

This is the other direction from _wizard_sidecar: it reads a type back out and
says what the wizard would have had to be told to produce it, so that picking one
from the dropdown can put the form into that state.

Everything but the display template and the canned includes comes out of the
sidecar.  The display comes out of the sidecar too for anything written since it
started being recorded there, and is read back out of the template itself
otherwise -- see _wizard_display_from_template, and note that a hand-written type
will often yield nothing, which is honest: there is no wizard form that produces
it.

The includes always come out of the template, via
Trog::DataModule::includes_for(), since only a generated sidecar ever recorded
them.  That is also what tells the field list apart from the checkboxes: a
preview image is a field of every type which includes preview.tx, so it is that
box being ticked rather than a custom field somebody added.

=cut

sub _wizard_types ($forms) {
    my %types;

    foreach my $form (@$forms) {
        my $schema = Trog::DataModule::schema_for($form);
        my $meta   = Trog::DataModule::type_meta_for($form);
        my $type   = $meta->{'x-tcms-post-type'};
        $type = {} unless Ref::Util::is_hashref($type);

        # What the editor actually splices in, which for a hand-written type is
        # the only account there is -- nothing but a generated sidecar records
        # the list.  Keyed on the template name, which is what %wizard_includes
        # maps a checkbox to.
        my %includes = map { $_ => 1 } @{ Trog::DataModule::includes_for($form) };

        my $display = $type->{display};
        $display = _wizard_display_from_template($form) unless length( $display // '' );

        $types{$form} = {
            name              => ( $form =~ s/\.tx$//r ),
            description       => $type->{description}         // '',
            display           => $display                     // '',
            body_form         => $type->{body_form}           // 'form_common.tx',
            datasource        => $meta->{'x-tcms-datasource'} // '',
            title_placeholder => $type->{title_placeholder}   // '',
            generated         => $type->{generated} ? 1 : 0,

            # The wizard's own checkboxes.  The includes are a list in the
            # sidecar; the other three are recorded individually because nothing
            # else would say whether they were ticked.
            wrapper        => $type->{wrapper}        ? 1 : 0,
            inc_post_title => $type->{inc_post_title} ? 1 : 0,
            inc_post_tags  => $type->{inc_post_tags}  ? 1 : 0,
            ( map { $_ => $includes{ $wizard_includes{$_} } ? 1 : 0 } @wizard_optional_includes ),

            fields => _wizard_fields_of( $schema, $meta, \%includes ),
        };
    }

    return \%types;
}

# The custom fields of a type, as rows the wizard would have submitted.
sub _wizard_fields_of ( $schema, $meta, $includes = {} ) {
    my $properties = $schema->{properties} // {};
    my %required   = map { $_ => 1 } @{ $schema->{required} // [] };
    my $relations  = $meta->{'x-tcms-relations'};
    $relations = {} unless Ref::Util::is_hashref($relations);

    # Whatever the canned blocks this type includes already collect.  These are
    # real fields of the type and really are in its schema, but nobody typed
    # them into the wizard, and offering them back as custom fields is how
    # ticking 'Preview image upload' and listing 'preview' as a text field came
    # to be the same thing said twice.
    my %canned;
    foreach my $include ( keys(%$includes) ) {
        my $collects = Trog::DataModule::include_schema_for($include)->{properties};
        next unless Ref::Util::is_hashref($collects);
        $canned{$_} = 1 foreach keys(%$collects);
    }

    my @fields;
    foreach my $name ( sort keys(%$properties) ) {

        # Only what this type added.  Everything in the base post schema belongs
        # to every post and was never a wizard field, and everything a canned
        # block collects belongs to the block rather than to the type.
        next if exists $Trog::DataModule::post_schema{properties}{$name};
        next if $canned{$name};

        my $property = $properties->{$name};
        next unless Ref::Util::is_hashref($property);

        push(
            @fields,
            {
                name          => $name,
                type          => $property->{'x-tcms-input'}       // 'text',
                label         => $property->{'x-tcms-label'}       // '',
                placeholder   => $property->{'x-tcms-placeholder'} // '',
                required      => $required{$name}              ? 1 : 0,
                private       => $property->{'x-tcms-private'} ? 1 : 0,
                indexed       => $property->{'x-tcms-indexed'} ? 1 : 0,
                relation_form => $property->{'x-tcms-relation-form'} // '',
                relation_mode => 'one',
            }
        );
    }

    # A relation pulling in every post of its target type stores nothing, so it
    # has no property to have been found above -- it exists only as a relations
    # entry with no 'from'.
    foreach my $name ( sort keys(%$relations) ) {
        my $relation = $relations->{$name};
        next unless Ref::Util::is_hashref($relation);
        next if $relation->{from};

        push(
            @fields,
            {
                name          => $name,
                type          => 'relation',
                label         => '',
                placeholder   => '',
                required      => 0,
                private       => 0,
                indexed       => 0,
                relation_form => $relation->{form} // '',
                relation_mode => 'all',
            }
        );
    }

    return \@fields;
}

=head2 _wizard_display_from_template($form)

Recover a generated type's display template from the template itself.

For types written before the wizard started recording it in the sidecar.  Only
attempted for a file carrying the generated marker, and only between the two
lines _wizard_template puts around it, so this either finds exactly what was
submitted or finds nothing.  A hand-written type finds nothing, which is correct:
there is no wizard form that produces one.

=cut

sub _wizard_display_from_template ($form) {
    my $path = Trog::Themes::themed_file_in_dir( 'forms', $form, 'text/html', 1 );
    return '' unless $path;

    my $template = eval { File::Slurper::read_text($path) };
    return '' unless defined $template;

    my @lines = split( "\n", $template );

    # CORE::index because this package has an index() of its own -- the route
    # that renders every page.
    return '' unless @lines && CORE::index( $lines[0], 'Generated by the tCMS Post Type Wizard' ) != -1;

    my ( @display, $inside );
    foreach my $line (@lines) {
        if ( !$inside ) {
            $inside = 1 if $line =~ m/^\s*:\s*if\s*\(\s*!\$post\.addpost\s*\)\s*\{\s*$/;
            next;
        }

        last if $line =~ m/^\s*:\s*\}\s*$/;

        # The includes the wizard emitted, which are checkboxes rather than
        # anything the admin typed into the display box.
        next if $line =~ m/^\s*:\s*include\s+"/;

        push( @display, $line );
    }

    my $display = join( "\n", @display );
    $display =~ s/^\s+|\s+$//g;
    return $display;
}

=head2 _wizard_types_json($forms) = STRING

_wizard_types() as JSON, safe to drop into a script element.

Every '<' is escaped, which is still valid JSON and means the string cannot
close the element it is sitting in -- a display template is full of markup, and
one containing the characters that end a script tag would otherwise end it.

=cut

sub _wizard_types_json ($forms) {
    my $json = eval { JSON::MaybeXS->new( canonical => 1 )->encode( _wizard_types($forms) ) };
    if ( !defined $json ) {
        WARN("Could not describe the existing post types: $@");
        return '{}';
    }

    $json =~ s/</\\u003c/g;
    return $json;
}

=head2 _wizard_description($description)

A post type's description, as it goes into the sidecar.

Free text rather than template source: it is shown to whoever picks the type in
the wizard, and rendered as text, so the only thing to do to it is keep it a
sane length and stop it being something other than a string.

=cut

our $wizard_description_max = 2048;

sub _wizard_description ( $description = '' ) {
    $description = _wizard_scalar($description);
    $description = substr( $description, 0, $wizard_description_max ) if length($description) > $wizard_description_max;
    return $description;
}

# Repeated params arrive as arrayrefs; anywhere we want one string, insist on one string.
sub _wizard_scalar ( $value = '' ) {
    return '' if !defined $value || ref $value;
    return $value;
}

sub _wizard_fail ( $query, $message ) {
    WARN($message);
    return post_wizard(
        {
            %$query,
            wizard_submitted => 1,
            failure          => 1,
            message          => $message,
        }
    );
}

=head2 _kolon_safe

Make a submitted string safe to splice into a generated Kolon template.
Newlines have to go, as a ':' at the start of a line is a Kolon directive, and
the angle brackets have to go so that '<:' can never be reassembled.

=cut

sub _kolon_safe ( $string = '' ) {
    $string = _wizard_scalar($string);
    $string =~ s/[\r\n]+/ /g;
    $string =~ s/&/&amp;/g;
    $string =~ s/</&lt;/g;
    $string =~ s/>/&gt;/g;
    $string =~ s/"/&quot;/g;
    return $string;
}

=head2 _wizard_fields

Zip the parallel param_* arrays submitted by the wizard back into a list of
field definitions.  Every row always submits exactly one of each param, so the
arrays stay aligned even when a row is left blank.

=cut

sub _wizard_fields ($query) {
    my $names   = Trog::Utils::coerce_array( $query->{param_name} );
    my $types   = Trog::Utils::coerce_array( $query->{param_type} );
    my $labels  = Trog::Utils::coerce_array( $query->{param_label} );
    my $phs     = Trog::Utils::coerce_array( $query->{param_placeholder} );
    my $reqs    = Trog::Utils::coerce_array( $query->{param_required} );
    my $rforms  = Trog::Utils::coerce_array( $query->{param_relation_form} );
    my $rmodes  = Trog::Utils::coerce_array( $query->{param_relation_mode} );
    my $private = Trog::Utils::coerce_array( $query->{param_private} );
    my $indexed = Trog::Utils::coerce_array( $query->{param_indexed} );

    my ( @fields, %seen );
    foreach my $index ( 0 .. $#$names ) {
        my ($fname) = lc( _wizard_scalar( $names->[$index] ) ) =~ m/^([a-z][a-z0-9_]{0,31})$/;

        # Blank and bogus rows just get dropped.
        next unless $fname;
        next if $seen{$fname}++;

        # Never let a custom field shadow a core post attribute.
        next if exists $Trog::DataModule::post_schema{properties}{$fname};
        next if grep { $fname eq $_ } @wizard_reserved;

        my $type = _wizard_scalar( $types->[$index] );
        $type = 'text' unless $wizard_field_types{$type};

        # A relation is only a relation if it names a target type that looks
        # like one; anything else falls back to being a plain text field.
        my ($rform) = _wizard_scalar( $rforms->[$index] ) =~ m/^([A-Za-z0-9_-]+\.tx)$/;
        my $rmode = _wizard_scalar( $rmodes->[$index] ) eq 'all' ? 'all' : 'one';
        $type = 'text' if $type eq 'relation' && !$rform;

        push(
            @fields,
            {
                name          => $fname,
                type          => $type,
                label         => _kolon_safe( $labels->[$index] ) || ucfirst($fname),
                placeholder   => _kolon_safe( $phs->[$index] ),
                required      => _wizard_scalar( $reqs->[$index] ) ? 1 : 0,
                relation_form => $rform,
                relation_mode => $rmode,
                private       => _wizard_scalar( $private->[$index] ) ? 1 : 0,
                indexed       => _wizard_scalar( $indexed->[$index] ) ? 1 : 0,
            }
        );
    }
    return \@fields;
}

=head2 _wizard_sidecar

Turn the wizard's field list into the post type's JSON sidecar: an OpenAPIv3
object schema describing what this type ingests, with the wizard's own UI
metadata hung off x- extension keys so there's only one file to keep in sync.

Trog::DataModule::schema_for() merges this over the base post schema.

=cut

sub _wizard_sidecar ( $name, $fields, $includes, $body_form, $datasource = '', $extra = {} ) {
    my %properties;
    my @required;

    my %relations;

    foreach my $field (@$fields) {

        # A relation pulling in every post of its target type isn't a field the
        # post stores at all -- it is purely something injected at render, so
        # it gets a relations entry and no property.
        if ( $field->{type} eq 'relation' && $field->{relation_mode} eq 'all' ) {
            $relations{ $field->{name} } = { form => $field->{relation_form} };
            next;
        }

        my $property = { %{ $wizard_field_types{ $field->{type} } } };
        $property->{'x-tcms-input'}       = $field->{type};
        $property->{'x-tcms-label'}       = $field->{label};
        $property->{'x-tcms-placeholder'} = $field->{placeholder} if length $field->{placeholder};

        # Only written when it is true: a field is public unless it says so,
        # and a sidecar full of x-tcms-private:false reads like the opposite.
        $property->{'x-tcms-private'} = JSON::MaybeXS::true() if $field->{private};

        # Likewise unindexed unless asked for.  The sidecar is the declaration;
        # post_wizard_save() reconciles the data model against it.
        $property->{'x-tcms-indexed'} = JSON::MaybeXS::true() if $field->{indexed};

        if ( $field->{type} eq 'relation' ) {
            $property->{'x-tcms-relation-form'} = $field->{relation_form};

            # The stored field holds a UUID; the resolved post lands beside it.
            $relations{"$field->{name}_post"} = { form => $field->{relation_form}, from => $field->{name} };
        }

        $properties{ $field->{name} } = $property;
        push( @required, $field->{name} ) if $field->{required};
    }

    # Everything the wizard was told, so that picking this type again puts the
    # form back the way it was.  It all lives under x-tcms-post-type, which
    # schema_for() strips before validation -- the validator sees properties and
    # required and nothing else, so none of this can affect whether a post saves.
    my %spec = (
        'x-tcms-post-type' => {
            name        => $name,
            generated   => JSON::MaybeXS::true(),
            generator   => 'Trog::Routes::HTML::post_wizard_save',
            body_form   => $body_form,
            includes    => [ map { $wizard_includes{$_} } @$includes ],
            description => $extra->{description} // '',
            display     => $extra->{display}     // '',

            # The checkboxes which are not includes, and so are not recoverable
            # from the list above.
            wrapper           => $extra->{wrapper}        ? JSON::MaybeXS::true() : JSON::MaybeXS::false(),
            inc_post_title    => $extra->{inc_post_title} ? JSON::MaybeXS::true() : JSON::MaybeXS::false(),
            inc_post_tags     => $extra->{inc_post_tags}  ? JSON::MaybeXS::true() : JSON::MaybeXS::false(),
            title_placeholder => $extra->{title_placeholder} // '',
        },
        type       => 'object',
        properties => \%properties,
    );
    $spec{required}            = \@required  if @required;
    $spec{'x-tcms-relations'}  = \%relations if %relations;
    $spec{'x-tcms-datasource'} = $datasource if $datasource;

    return \%spec;
}

sub _wizard_field_html ($field) {
    my ( $n, $t, $l, $p ) = @$field{qw{name type label placeholder}};
    my $required = $field->{required} ? 'required ' : '';

    if ( $t eq 'relation' ) {

        # 'all' relations aren't stored, so there is nothing to edit.
        return '' if $field->{relation_mode} eq 'all';

        # Left empty on purpose: post_relations.js fills it from
        # /api/posts_of_form, so the picker can't go stale against the
        # generated template.
        return qq|            $l<br /><select ${required}class="cooltext relation-picker" name="$n" data-relation-form="$field->{relation_form}" data-selected="<: \$post.$n :>"></select>\n|;
    }

    return qq|            $l<br /><textarea ${required}class="cooltext" name="$n" placeholder="$p"><: \$post.$n :></textarea>\n|
      if $t eq 'textarea';

    return qq|            <label for="<: \$post.id :>-$n">$l<input id="<: \$post.id :>-$n" class="coolcb" type="checkbox" name="$n" value="1" <: if ( \$post.$n ) { "checked" } :> /></label><br />\n|
      if $t eq 'checkbox';

    return qq|            $l<br /><input ${required}class="cooltext" type="$t" name="$n" placeholder="$p" value="<: \$post.$n :>" />\n|;
}

=head2 _wizard_template

Assemble the actual .tx file, following the shape of the hand-written forms:
a display half guarded by !$post.addpost, and an edit half guarded by $can_edit.

=cut

sub _wizard_template ( $query, $fields, $includes, $body_form, $datasource = '' ) {
    my $placeholder = _kolon_safe( $query->{title_placeholder} ) || 'Iowa Man Destroys Moon';

    # NOT escaped, on purpose.  Letting an admin write template code is the
    # entire point of the wizard, and it is no more privileged than the data
    # field of any post, which already gets run through render_it().  Both
    # sides of this route are behind the admin ACL.
    my $display = _wizard_scalar( $query->{display} );

    my $out = "<!-- Generated by the tCMS Post Type Wizard.  Regenerating this type will overwrite any hand edits. -->\n";

    # A series can ask for its children to be tiled, which is a layout the
    # wrapper has to carry -- see how file.tx and series.tx do it.  Harmless
    # when the series hasn't asked, and it means a generated type gets tiling
    # for free rather than being the one kind of post that ignores the setting.
    $out .= qq|<div class="post <: \$style :> <: \$tiled ? 'tile' : '' :>">\n| if $query->{wrapper};
    $out .= qq|    : if ( !\$post.addpost ) {\n|;
    $out .= qq|        : include "post_title.tx";\n| if $query->{inc_post_title};
    $out .= qq|        : include "post_tags.tx";\n|  if $query->{inc_post_tags};
    $out .= "$display\n"                             if $display;
    $out .= qq|    : }\n|;

    # A datasource can say its posts are built rather than written, in which
    # case an editor would be a form saving something nobody can edit -- and
    # for Trog::DataSource::Virt, one that writes a real post to sit alongside
    # the synthesized ones and collide with them.
    if ( !_datasource_editable($datasource) ) {
        $out .= qq|</div>\n| if $query->{wrapper};
        return $out;
    }

    $out .= qq|\n|;
    $out .= qq|    : if ( \$can_edit ) {\n|;
    $out .= qq|        <div class="postedit">\n|;
    $out .= qq|        : include "edit_head.tx";\n|;
    $out .= qq|        <form class="Submissions" action="/post/save" method="POST" enctype="multipart/form-data">\n|;
    $out .= qq|            Title *<br /><input required class="cooltext" type="text" name="title" placeholder="$placeholder" value="<: \$post.title :>" />\n|
      if $query->{inc_title_input};
    $out .= _wizard_field_html($_) foreach @$fields;

    foreach my $include (@$includes) {
        $out .= qq|            : include "$wizard_includes{$include}";\n|;
    }

    # Always last, and never optional: this is what carries the post body, the
    # app/to/id/form hiddens and the submit button.
    $out .= qq|            : include "$body_form";\n|;
    $out .= qq|        </form>\n|;
    $out .= qq|        : include "edit_foot.tx";\n|;
    $out .= qq|        </div>\n|;
    $out .= qq|    : }\n|;
    $out .= qq|</div>\n| if $query->{wrapper};
    return $out;
}

# basically a file rewrite rule for themes

=head2 icon

Implements the /img/icon/* routes.

Serves a themed icon, falling back to the stock one.  A rewrite rule with extra
steps, essentially, so that themes can replace individual icons.

=cut

sub icon ($query) {
    my $path  = $query->{route};
    my $tpath = Trog::Themes::themed("img/icon/$path");
    return $query->{tpsgi}->serve( $path, $tpath, $query->{start}, $query->{streaming}, $query->{ranges}, $query->{last_fetched}, $query->{deflate} );
}

=head2 totp_qr

Implements the /totp/* routes.

Serves the QR code generated when a user enables TOTP.  These live outside
www/, so they go out through serve() rather than the static file handler --
handing someone else's enrolment QR out to the world would be handing them the
shared secret.

=cut

sub totp_qr ($query) {
    my $fname = basename( $query->{route} );

    # For authenticated content, we have to now do a serve().
    return $query->{tpsgi}->serve(
        "totp/$fname",
        "totp/$fname",
        $query->{start},
        $query->{streaming},
        $query->{ranges},
        $query->{last_fetched},
        $query->{deflate},
    );
}

=head2 rss_style

Implements /styles/rss-style.xsl.

The XSL stylesheet which makes the RSS feed legible in a browser.

rss-style.tx pulls the header and footer in with component(), which works here
where an include directive would not: the output is XSL rather than HTML, so
the two are rendered separately and composed, and the header is asked for
without a doctype.

=cut

sub rss_style ($query) {
    $query->{port}       = ":$query->{port}" if $query->{port};
    $query->{title}      = qq{<xsl:value-of select="rss/channel/title"/>};
    $query->{no_doctype} = 1;

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

=head2 finish_render($template, $vars, %headers)

Render a full page, as opposed to a component.

Fills in the defaults every page needs (lang, title, status code, content type,
cache control), resolves stylesheet and script names through the theme, makes
their paths absolute, and hands the lot to Trog::Renderer.

The page's own template asks for the header and footer with component(), so the
resolved stylesheet and script lists are passed on to Trog::Component::Header
rather than being rendered into a string here.

Just about everything in this module ends up here; index() is the usual way in.

=cut

sub finish_render ( $template, $vars, %headers ) {

    #XXX default vars that need to be pulled from config
    $vars->{lang}         //= 'en-US';
    $vars->{title}        //= 'tCMS';
    $vars->{stylesheets}  //= [];
    $vars->{print_styles} //= [qw{structure.css print.css}];
    $vars->{scripts}      //= [];

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

    # %headers was accepted and then ignored, which nothing noticed because
    # nothing passed any.  index() passes one now, to expire the feedback cookie
    # once its message has been rendered.
    return Trog::Renderer->render(
        template    => $template,
        data        => $vars,
        contenttype => 'text/html',
        code        => $vars->{code},
        ( %headers ? ( headers => \%headers ) : () ),
    );
}

1;
