package Trog::DataSource::Virt;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use File::Path();
use Sys::Virt();

use Trog::Log qw{WARN INFO};

=head1 Trog::DataSource::Virt

Builds posts out of libvirt guests rather than out of the datastore.

A post type says it wants this by naming it in its sidecar:

    "x-tcms-datasource": "Trog::DataSource::Virt"

A series of that type then lists the guests of whichever hypervisor posts its
relations pulled in, instead of listing posts somebody wrote.  Nothing here is
ever written to the datastore -- the guests are the source of truth, and the
posts are rebuilt from them on every view.

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

our $screenshot_dir = 'www/assets/guests';

# Reconnecting per guest would be absurd -- one ssh handshake per hypervisor
# per process is enough.  Not a state var: a connection that has gone away
# should be retried rather than remembered.
sub _connect ( $uri, $cache = {} ) {
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
    'no state',      'running',  'blocked', 'paused',
    'shutting down', 'shut off', 'crashed', 'suspended',
);

sub _state_name ($state) {
    return $states[$state] // 'unknown';
}

=head2 posts($series, $query) = @posts

One post per guest, across every hypervisor the series' relations pulled in.

A hypervisor we cannot reach becomes a single post saying so, rather than
vanishing -- a page that silently omits half your infrastructure is worse than
one that tells you the connection is broken.

=cut

sub posts ( $series, $query ) {
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
            push( @out, _unreachable_post( $hypervisor, $series, $form, $why ) );
            next;
        }

        local $@;
        my @domains = eval { $conn->list_all_domains() };
        if ($@) {
            my $err = "$@";
            $err =~ s/\n.*//s;
            push( @out, _unreachable_post( $hypervisor, $series, $form, $err ) );
            next;
        }

        push( @out, map { _post_for( $_, $hypervisor, $series, $form ) } @domains );
    }

    return @out;
}

sub _post_for ( $domain, $hypervisor, $series, $form ) {
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
        state            => _state_name( $info->{state} ),
        is_active        => $domain->is_active() ? 1 : 0,
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

sub _unreachable_post ( $hypervisor, $series, $form, $why ) {
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

=head2 screenshot($conn_uri, $domain_name) = ($path, $error)

Path to a reasonably fresh PNG of the guest's console.

Cached on disk, because a page of guests means one of these per guest and they
are only interesting to about the nearest half minute.  libvirt hands back the
mimetype; qemu gives us PNG already, so there is nothing to convert.

=cut

sub screenshot ( $conn_uri, $domain_name ) {
    my ($safe) = $domain_name =~ m/^([A-Za-z0-9._-]+)$/;
    return ( undef, 'bad domain name' ) unless $safe;

    my $path = "$screenshot_dir/$safe.png";
    return ( $path, undef ) if -f $path && ( time() - ( stat($path) )[9] ) < $screenshot_ttl;

    my ( $conn, $why ) = _connect($conn_uri);
    return ( undef, $why ) unless $conn;

    local $@;
    my $data = eval {
        my ($domain) = grep { $_->get_name() eq $safe } $conn->list_all_domains();
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

    File::Path::make_path($screenshot_dir);
    open( my $fh, '>', $path ) or return ( undef, "could not cache the screenshot: $!" );
    binmode $fh;
    print {$fh} $data;
    close $fh;

    return ( $path, undef );
}

=head2 act($action, $conn_uri, $domain_name, $user) = ($ok, $message)

The operations which change a guest.

Deliberately the only sub here that does, and deliberately not reachable from
the render path -- see the safety note at the top.  Everything it does is
logged with the user who asked for it.

=cut

sub act ( $action, $conn_uri, $domain_name, $user ) {
    my ($safe) = $domain_name =~ m/^([A-Za-z0-9._-]+)$/;
    return ( 0, 'bad guest name' ) unless $safe;

    my ( $conn, $why ) = _connect($conn_uri);
    return ( 0, "could not reach the hypervisor: $why" ) unless $conn;

    local $@;
    my ($domain) = eval {
        grep { $_->get_name() eq $safe } $conn->list_all_domains();
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
