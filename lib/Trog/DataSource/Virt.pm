package Trog::DataSource::Virt;

# ABSTRACT: A datasource that builds posts out of libvirt guests

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use List::Util();
use File::Path();
use Sys::Hostname::FQDN();
use Sys::Virt();

use Trog::Config();
use Trog::DataSource();

use Trog::Log qw{WARN INFO};

=head1 Trog::DataSource::Virt

Builds posts out of libvirt guests rather than out of the datastore.

A post type says it wants this by naming it in its sidecar:

    "x-tcms-datasource": "Trog::DataSource::Virt"

A series of that type then lists the guests of whichever hypervisor posts its
relations pulled in, instead of listing posts somebody wrote.  Nothing here is
ever written to the datastore -- the guests are the source of truth, and the
posts are rebuilt from them on every view.

=head2 EDITABLE

False.  A guest is built from libvirt every time the page is drawn and has
nothing behind it to save, so a post type backed by this wants no editor: a
form posting to /post/save would write a real post into the datastore which
would then sit alongside, and collide with, the synthesized ones.

Returns Bool, always 0.

    my $editable = Trog::DataSource::Virt->EDITABLE;

=cut

sub EDITABLE { return 0 }

=head2 CACHEABLE

False.  A guest's state is the whole point of the page: whether it is running,
how much memory it has, what its console looks like right now.  A static render
of that is a photograph of a machine, and the reader wants the machine.

There is also nothing that could invalidate it.  A guest starting or stopping is
not a post being saved, and libvirt is not going to tell us about it -- so a
cached listing would not merely be stale, it would have no way of ever becoming
right again.

Returns Bool, always 0.

    my $cacheable = Trog::DataSource::Virt->CACHEABLE;

=cut

sub CACHEABLE { return 0 }

=head2 A NOTE ON SAFETY

libvirt forbids virDomainScreenshot on a read-only connection, so the read path
cannot protect itself by connecting read-only -- it holds a connection which is
perfectly capable of destroying a guest.

The discipline is therefore in the code: posts() and screenshot() call nothing
but accessors, and every operation that changes a guest lives in act(), which
is reached only from an explicit admin-gated POST.  Keep it that way.

=cut

# How long a cached screenshot is considered fresh.  These are console
# captures, so they change slowly and are cheap to refetch.
our $screenshot_ttl = 30;

# Under www/assets like every other asset, in its own subtree because these are
# not uploads somebody made -- they are cached datasource output, and anything
# in here can be deleted at any time and will simply be refetched.
#
# Under private/ specifically because a console capture can show a login
# prompt, a hostname, whatever the last command printed.  That is the same
# reasoning _handle_upload uses to put a private post's assets there, and the
# screenshot route serves these to admins itself rather than relying on
# anything about how www/assets is exposed.
our $screenshot_dir = 'www/assets/private/datasource/virt';

# Reconnecting per guest would be absurd -- one ssh handshake per hypervisor
# per process is enough.  Not a state var: a connection that has gone away
# should be retried rather than remembered.
my sub _connect ( $uri, $cache = {} ) {
    return $cache->{$uri} if $cache->{$uri};

    local $@;
    my $conn = eval { Sys::Virt->new( uri => $uri ) };
    if ( !$conn ) {
        my $why = "$@";
        $why =~ s/\n.*//s;
        WARN("Could not connect to hypervisor '$uri': $why");
        return ( undef, $why );
    }

    $cache->{$uri} = $conn;
    return $conn;
}

# libvirt's numeric domain states, in the order the constants define them.
my @states = (
    'no state', qw{running blocked paused},
    'shutting down', 'shut off', 'crashed', 'suspended',
);

# What this machine calls itself.  Not a state var so that a test can pretend
# to be a different host without having to lie to Sys::Hostname.
our $hostname;

my sub hostname {    ## no critic (ProhibitSingleUseLexicalSubs) -- 14 lines, which would overcomplicate is_self()
    return $hostname if defined $hostname;

    local $@;

    # Sys::Hostname croaks rather than returning undef when it cannot tell, and
    # the configured hostname is the next best thing we know about ourselves.
    $hostname =
         eval { Sys::Hostname::FQDN::fqdn() }
      || eval { Trog::Config->get()->param('general.hostname') }
      || '';

    return $hostname;
}

=head2 is_self($name)

Whether a guest by this name is the machine we are running on.

Such a guest is acting as dom0: it is serving the page the guest list appears
on, so powering it off or destroying it takes the site down along with whatever
asked for that.

=over 4

=item name - Str|undef - the name of the guest

=back

Returns Bool, 1 when the name, compared without case, is the fqdn of this
machine, else 0.  When perl cannot find the fqdn, it uses the configured
C<general.hostname>.

    my $refuse = Trog::DataSource::Virt::is_self( $domain->get_name() );

=cut

sub is_self ($name) {
    my $me = lc( hostname() );
    $name = lc( $name // '' );

    return 1 if $name eq $me;
    return 0;
}

my sub unreachable_post ( $hypervisor, $series, $form, $why ) {
    return {
        id               => "unreachable-$hypervisor->{id}",
        title            => $hypervisor->{title} // 'hypervisor',
        form             => $form,
        data             => '',
        state            => "unreachable: $why",
        is_active        => 0,
        unreachable      => 1,
        hypervisor       => $hypervisor->{id},
        hypervisor_title => $hypervisor->{title},
        preview          => '',
        local_href       => '',
        href             => '',
        tags             => $series->{tags}       // [],
        visibility       => $series->{visibility} // 'private',
        created          => time(),
        version          => 0,
        user             => $series->{user},
        method           => 'GET',
    };
}

=head2 posts($series, $query) = @posts

One post per guest, across every hypervisor the series' relations pulled in.

A hypervisor we cannot reach becomes a single post saying so, rather than
vanishing -- a page that silently omits half your infrastructure is worse than
one that tells you the connection is broken.

The relation that holds the hypervisors is named by the series'
C<x-tcms-datasource-relation>, and is C<hypervisors> when it names none.  A
hypervisor without a C<conn_uri> is skipped.  The second argument is the query.
This sub does not read it.

=over 4

=item series - HashRef - the series post, with its relations pulled in

=back

Returns List[HashRef], one post per guest and one per unreachable hypervisor.
The list is empty when the relation is not an ARRAY reference.

    my @guests = Trog::DataSource::Virt::posts( $series, $query );

=cut

sub posts ( $series, $ ) {
    my $hypervisors = $series->{ $series->{'x-tcms-datasource-relation'} // 'hypervisors' };
    return () unless ref $hypervisors eq 'ARRAY';

    my $form = $series->{child_form} // '';
    my %cache;
    my @out;

    foreach my $hypervisor (@$hypervisors) {
        my $uri = $hypervisor->{conn_uri};
        next unless $uri;

        my ( $conn, $why ) = _connect( $uri, \%cache );
        if ( !$conn ) {
            push( @out, unreachable_post( $hypervisor, $series, $form, $why ) );
            next;
        }

        local $@;
        my @domains = eval { $conn->list_all_domains() };
        if ($@) {
            my $err = "$@";
            $err =~ s/\n.*//s;
            push( @out, unreachable_post( $hypervisor, $series, $form, $err ) );
            next;
        }

        push( @out, map { post_for( $_, $hypervisor, $series, $form ) } @domains );
    }

    return @out;
}

=head2 filter($query, @posts) = @posts

Apply the reader's search to the guest list.

A guest post's body is empty -- everything about it is in named fields -- so the
default, which searches a post's title and body, would only ever match the guest
name.  Search what the page actually shows instead: the guest name, its state,
and the hypervisor it is on.  Searching 'shut' for the stopped guests, or a
hypervisor's title for everything on it, is the thing somebody typing in that
box on this page is trying to do.

Everything else about the query means what it does elsewhere, so it is left to
Trog::DataSource::filter.

=over 4

=item query - HashRef|undef - the reader's query; undef means no query

=item posts - List[HashRef] - the guest posts

=back

Returns List[HashRef], the posts that match.

    my @posts = Trog::DataSource::Virt::filter( { like => 'shut' }, @guests );

=cut

sub filter ( $query, @posts ) {
    $query //= {};

    if ( ( $query->{like} // q{} ) ne q{} ) {
        my $like = $query->{like};
        @posts = grep {
            Trog::DataSource::searchable_match(
                $like,
                $_->{title}, $_->{domain}, $_->{state}, $_->{hypervisor_title}, $_->{hypervisor},
            )
        } @posts;
    }

    # Without like, since that one is answered above.
    return Trog::DataSource::filter( { %$query, like => undef }, @posts );
}

=head2 lang() = STRING

What the search box searches on a page of guests.

Returns Str, the name of the query language.

    my $lang = Trog::DataSource::Virt::lang();

=cut

sub lang { return 'Case insensitive substring of a guest name, state or hypervisor' }

=head2 help() = STRING

Where to read about it.

Returns Str, the URL of a page about the query language.

    my $help = Trog::DataSource::Virt::help();

=cut

sub help { return 'https://en.wikipedia.org/wiki/Substring' }

=head2 post_for($domain, $hypervisor, $series, $form) = HASHREF

The post that stands for the guest $domain, a Sys::Virt::Domain, on
$hypervisor, in the listing of $series, rendered with $form.

=over 4

=item domain - Sys::Virt::Domain - the guest

=item hypervisor - HashRef - the hypervisor post, with its C<id> and C<title>

=item series - HashRef - the series post, for its tags, visibility and user

=item form - Str - the form that renders the post

=back

Returns HashRef, the post.  Its C<id> is the UUID of the guest.

    my @posts = map { Trog::DataSource::Virt::post_for( $_, $hypervisor, $series, $form ) } @domains;

=cut

sub post_for ( $domain, $hypervisor, $series, $form ) {
    my $name = $domain->get_name();
    my $info = $domain->get_info();

    return {
        # The guest's own UUID: stable across renders, and what the control
        # routes look it back up by.
        id    => $domain->get_uuid_string(),
        title => $name,
        form  => $form,
        data  => '',

        domain           => $name,
        state            => $states[ $info->{state} ] // 'unknown',
        is_active        => $domain->is_active() ? 1 : 0,
        is_self          => is_self($name),
        memory           => $info->{memory},
        vcpus            => $info->{nrVirtCpu},
        hypervisor       => $hypervisor->{id},
        hypervisor_title => $hypervisor->{title},

        # Fetched by the browser rather than inline, so ten guests don't mean
        # ten screenshots taken serially before the page can render.
        preview => "/guest/screenshot/$hypervisor->{id}/$name",

        # Enough of a post to survive being rendered like one.
        local_href => "/guest/$hypervisor->{id}/$name",
        href       => '',
        tags       => $series->{tags}       // [],
        visibility => $series->{visibility} // 'private',
        created    => time(),
        version    => 0,
        user       => $series->{user},
        method     => 'GET',
    };
}

=head2 screenshot($hypervisor, $guest_name) = ($path, $error)

Path to a reasonably fresh PNG of the guest's console.

Cached on disk, because a page of guests means one of these per guest and they
are only interesting to about the nearest half minute.  libvirt hands back the
mimetype; qemu gives us PNG already, so there is nothing to convert.

Keyed by hypervisor as well as by guest -- guest names are only unique within
one hypervisor, and two of them called 'staging' would otherwise show each
other's console.

=over 4

=item hypervisor - HashRef - the hypervisor post, with its C<id> and C<conn_uri>

=item guest_name - Str - the name of the guest

=back

Returns a list of two.  On success, the path of the PNG and undef.  On failure,
undef and the reason: a bad guest name or hypervisor id, no connection URI, a
hypervisor that does not answer, no such guest, or a file that cannot be
written.

    my ( $path, $why ) = Trog::DataSource::Virt::screenshot( $hypervisor, $in->{guest} );

=cut

sub screenshot ( $hypervisor, $guest_name ) {
    my ($safe) = ( $guest_name // '' ) =~ m/^([\w.-]+)$/;
    return ( undef, 'bad guest name' ) unless $safe;

    my ($host) = ( $hypervisor->{id} // '' ) =~ m/^([\w.-]+)$/;
    return ( undef, 'bad hypervisor id' ) unless $host;

    my $conn_uri = $hypervisor->{conn_uri};
    return ( undef, 'hypervisor has no connection uri' ) unless $conn_uri;

    my $dir  = "$screenshot_dir/$host";
    my $path = "$dir/$safe.png";

    # One stat rather than -f and then a second stat for the mtime.  A missing
    # file gives the empty list, so $mtime is undef and we fall through to a
    # fresh capture.
    my $mtime = ( stat($path) )[9];
    return ( $path, undef ) if $mtime && ( time() - $mtime ) < $screenshot_ttl;

    my ( $conn, $why ) = _connect($conn_uri);
    return ( undef, $why ) unless $conn;

    local $@;
    my $data = eval {
        my ($domain) = grep { local ($_) = $_; $_->get_name() eq $safe } $conn->list_all_domains();
        die "no such guest\n" unless $domain;

        my $stream = $conn->new_stream();
        $domain->screenshot( $stream, 0, 0 );

        my $buffer = '';
        $stream->recv_all( sub { my ( undef, $chunk ) = @_; $buffer .= $chunk; return length($chunk) } );
        $stream->finish();
        $buffer;
    };
    if ( !$data ) {
        my $err = "$@";
        $err =~ s/\n.*//s;
        return ( undef, $err );
    }

    File::Path::make_path($dir);
    open( my $fh, '>', $path ) or return ( undef, "could not cache the screenshot: $!" );
    binmode $fh;
    print {$fh} $data;
    close($fh) or return ( undef, "could not cache the screenshot: $!" );

    return ( $path, undef );
}

=head2 act($action, $conn_uri, $domain_name, $user) = ($ok, $message)

The operations which change a guest.

Deliberately the only sub here that does, and deliberately not reachable from
the render path -- see the safety note at the top.  Everything it does is
logged with the user who asked for it.

It refuses to C<poweroff> or C<destroy> the guest that is this machine; see
is_self().

=over 4

=item action - Str - one of C<poweron>, C<poweroff>, C<snapshot> and C<destroy>

=item conn_uri - Str - the libvirt URI of the hypervisor

=item domain_name - Str - the name of the guest

=item user - Str - the user who asked, for the log

=back

Returns a list of two: a Bool, 1 when the action was done, and a Str, the
message for the user.  On failure the message says why: a bad guest name, the
guest is this server, the hypervisor does not answer, no such guest, an
unknown action, or the error of libvirt.

    my ( $ok, $message ) = Trog::DataSource::Virt::act( $in->{action}, $hypervisor->{conn_uri}, $in->{guest}, $query->{user} );

=cut

sub act ( $action, $conn_uri, $domain_name, $user ) {
    my ($safe) = $domain_name =~ m/^([\w.-]+)$/;
    return ( 0, 'bad guest name' ) unless $safe;

    # The template draws neither of these buttons for this guest; this is what
    # actually stops it happening.  /guest/act is a POST anybody holding the
    # admin acl can craft by hand, and if it went through there would be
    # nothing left running to report the mistake.
    if ( is_self($safe) && List::Util::any { $_ eq ( $action // '' ) } qw{poweroff destroy} ) {
        WARN("Refused guest action '$action' on '$safe': that is this server");
        return ( 0, "'$safe' is this server -- refusing to $action it" );
    }

    my ( $conn, $why ) = _connect($conn_uri);
    return ( 0, "could not reach the hypervisor: $why" ) unless $conn;

    local $@;
    my ($domain) = eval {
        grep { local ($_) = $_; $_->get_name() eq $safe } $conn->list_all_domains();
    };
    return ( 0, "no guest called '$safe' on that hypervisor" ) unless $domain;

    INFO("Guest action '$action' on '$safe' requested by $user");

    my %actions = (
        poweron  => sub { $_[0]->create() },
        poweroff => sub { $_[0]->shutdown() },
        snapshot => sub { $_[0]->create_snapshot() },
        destroy  => sub { $_[0]->destroy() },
    );

    my $doit = $actions{ $action // '' };
    return ( 0, "'$action' is not something we do to a guest" ) unless $doit;

    eval { $doit->($domain); 1 } or do {
        my $err = "$@";
        $err =~ s/\n.*//s;
        WARN("Guest action '$action' on '$safe' failed: $err");
        return ( 0, $err );
    };

    return ( 1, "$action: ok" );
}

1;
