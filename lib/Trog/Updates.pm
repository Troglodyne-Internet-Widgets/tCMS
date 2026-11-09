package Trog::Updates;

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use File::Basename();

use Trog::Jobs();
use Trog::Themes();

=head1 NAME

Trog::Updates - what commit tCMS, tPSGI and the theme run, as /config shows it

=head1 DESCRIPTION

The /config page shows the commit of each checkout that serves the site, and
whether its upstream has a newer one.  An admin can then pull the newer one.
Both happen in the job queue, because each asks the network.  This module is
the part that a request of tCMS runs: it finds the checkouts, queues the jobs,
and reads their results.  Nothing here asks the network.  The tasks, which run
in the worker of the queue, are in L<Trog::Jobs::Updates>, which also says
what an update refuses and what it reloads.

There are up to three checkouts:

=over 4

=item * B<tCMS>, the root of the install.

=item * B<tPSGI>, the directory above it, when that directory holds
F<.tpsgi.ini> and a git checkout.  This is how the tpsgi recipe of
trog-provisioner lays out a guest.

=item * B<the theme>, the directory of the active theme, when it is a git
checkout.

=back

tCMS and tPSGI are fetched from their public repositories on GitHub, by URL, in
C<%upstreams>.

=cut

our %upstreams = (
    tCMS  => 'https://github.com/Troglodyne-Internet-Widgets/tCMS.git',
    tPSGI => 'https://github.com/Troglodyne-Internet-Widgets/tPSGI.git',
);

# The tPSGI checkout, relative to the root of tCMS.
our $tpsgi_dir = '..';

# A check older than this is done again when an admin opens /config.
our $stale_after = 600;

=head1 FUNCTIONS

=head2 reason($error) = STRING

$error, a message that ends in a newline as a die message here does, without
the newline.

=cut

sub reason ($error) {
    chomp( my $said = $error );
    return $said;
}

=head2 checkouts() = LIST

A hashref for each checkout that serves the site: C<name>, C<dir>, and C<url>,
the upstream.  The names are C<tCMS>, C<tPSGI> and C<theme>.  A theme has no
C<url>, because only the network can tell which of its remotes is public, and
C<status> of L<Trog::Jobs::Updates> asks.  It has C<label>, the name of its
directory.  This asks nothing of the network, so a request can call it.

=cut

sub checkouts {
    my @found;
    push @found, { name => 'tCMS', dir => '.', url => $upstreams{tCMS} } if -e '.git';
    push @found, { name => 'tPSGI', dir => $tpsgi_dir, url => $upstreams{tPSGI} } if -e "$tpsgi_dir/.tpsgi.ini" && -e "$tpsgi_dir/.git";

    my $theme = Trog::Themes::get_dir();
    if ( $theme && -e "$theme/.git" ) {
        push @found, { name => 'theme', label => File::Basename::basename($theme), dir => $theme };
    }
    return @found;
}

=head2 checkout($name) = HASHREF

The checkout of C<checkouts> named $name.  Dies if there is none.

=cut

sub checkout ($name) {
    my ($found) = grep { $_->{name} eq ( $name // '' ) } checkouts();
    die "There is no checkout named " . ( $name // '' ) . " to update\n" unless $found;
    return $found;
}

=head2 enqueue_check() = ID

Queues an C<update_check>, unless one is waiting or running.  Returns its id,
or undef when it queued none.

=cut

sub enqueue_check {
    my $minion = Trog::Jobs::minion();
    return if $minion->jobs( { tasks => ['update_check'], states => [qw{inactive active}] } )->total;
    return $minion->enqueue( update_check => [] );
}

=head2 enqueue_update($name) = ID

Queues an C<update> of the checkout named $name.  Dies for a name that
C<checkouts> does not have.

=cut

sub enqueue_update ($name) {
    checkout($name);
    return Trog::Jobs::minion()->enqueue( update => [$name], { notes => { checkout => $name } } );
}

=head2 summary() = HASHREF

What /config shows: C<checked_at> and C<checkouts>, from the newest finished
C<update_check>, and C<pending>, the C<update_check> and C<update> jobs that
wait or run.  It queues a check when the newest is older than
C<$stale_after> seconds, or there is none.  C<last_update> is the newest
C<update> that finished or failed, with C<state>, C<checkout>, and C<error>
when it failed.  Each checkout also has C<short_head> and C<short_upstream>,
the first twelve characters of the commits.

=cut

sub summary {
    my $minion = Trog::Jobs::minion();
    my $last   = $minion->jobs( { tasks => ['update_check'], states => ['finished'] } )->next;
    my $result = $last ? $last->{result} : {};
    enqueue_check() if ( $result->{checked_at} // 0 ) < time - $stale_after;

    my $pending = $minion->jobs( { tasks => [qw{update_check update}], states => [qw{inactive active}] } );
    my @pending;
    while ( my $job = $pending->next ) { push @pending, { task => $job->{task}, state => $job->{state}, checkout => $job->{args}[0] // '' } }

    my $update = $minion->jobs( { tasks => ['update'], states => [qw{finished failed}] } )->next;
    my $error  = $update && $update->{state} eq 'failed' ? $update->{result} : undef;
    $error = $error->{error} if ref $error eq 'HASH';

    my @checkouts;
    foreach my $co ( @{ $result->{checkouts} // [] } ) {
        my %shown = %$co;
        foreach my $commit (qw{head upstream}) {
            $shown{"short_$commit"} = substr( $co->{$commit}, 0, 12 ) if defined $co->{$commit};
        }
        push @checkouts, \%shown;
    }
    return {
        checked_at  => $result->{checked_at},
        checkouts   => \@checkouts,
        pending     => \@pending,
        last_update => $update ? { state => $update->{state}, checkout => $update->{args}[0], error => $error } : undef,
    };
}

1;
