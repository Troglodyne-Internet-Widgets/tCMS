package Trog::Jobs::Updates;

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use File::Temp();
use File::Which();
use IPC::Run();
use JSON::MaybeXS();
use YAML::XS();

use Trog::Updates();

=head1 NAME

Trog::Jobs::Updates - the tasks that check and update the checkouts of the site, in the worker of the queue

=head1 DESCRIPTION

This is the part of the updates of /config that runs in the worker of the job
queue, C<bin/tcms-jobs minion worker>, and never in a request.  Its process is
a child of that worker, in the unit of the worker, and not of the master of
tPSGI.  L<Trog::Updates> finds the checkouts and queues the tasks.

A theme is fetched from the first of its remotes that git can read over HTTPS
with no credentials.  A theme with no such remote is shown, and cannot be
updated here.  No remote of a checkout is used or changed, because a checkout
can have a remote that needs a key, or none.

An update is a fast forward and nothing else.  It refuses a checkout with
changes to tracked files, and a checkout that is not behind.  It also refuses
when the new commits need something that a person must install, because the
service user cannot install it:

=over 4

=item * a system package or archive, in C<x_system_packages> or
C<x_system_sources> of F<metamerge.yml>.  See
L<Dist::Conformance::Check::SystemPackages>.

=item * a perl module that this perl does not have, as C<dzil listdeps
--missing> says for the new commit.

=back

After an update of tCMS, it runs the C<install> and C<prereq-frontend> targets
of F<Installer.mk>, as the provision does.  Then it sends HUP to the master of
tPSGI, whose new workers load the new code, and restarts the job worker last,
so that it loads the new tasks.  After an update of the theme, it sends the HUP.
After an update of tPSGI, it restarts the unit of tPSGI, because the master
runs code of tPSGI that a HUP does not load again.  The restarts use the sudo
grants that the tcms and tpsgi recipes of trog-provisioner make.

=cut

our $proc = '/proc';

# Seconds that one git command may run, and one dzil listdeps.
our $git_timeout  = 120;
our $dzil_timeout = 600;

# Where a fetch puts the upstream commit, so that two jobs do not share FETCH_HEAD.
our $upstream_ref = 'refs/tcms-update/upstream';

our @system_keys = qw{x_system_packages x_system_sources};

=head1 FUNCTIONS

=head2 run_command(\@command, %options) = ($ok, $stdout, $stderr)

Run @command, which no shell reads, and wait for it.  C<dir> is the directory
to run it in, C<env> a hashref of variables to add, and C<timeout> the seconds
that it may run, C<$git_timeout> by default.  $ok is true when it exited 0.

=cut

sub run_command ( $command, %options ) {
    my ( $out, $err ) = ( '', '' );
    local %ENV = ( %ENV, %{ $options{env} // {} } );
    my %init = defined $options{dir} ? ( init => sub { chdir $options{dir} or die "chdir $options{dir}: $!\n" } ) : ();
    my $ok   = eval { IPC::Run::run( $command, \undef, \$out, \$err, %init, IPC::Run::timeout( $options{timeout} // $git_timeout ) ) };
    if ( !$ok && $@ ) {
        $err .= $@ =~ /timeout/ ? "$command->[0] ran for too long and was stopped\n" : "$command->[0] did not run: $@";
    }
    return ( $ok && $? == 0 ? 1 : 0, $out, $err );
}

=head2 git($dir, @args) = STRING

Run git in $dir with @args, and return what it printed, without the last
newline.  It never asks for a password, and uses no credential helper.  Dies
with the first line that git printed on stderr, if it fails.

=cut

sub git ( $dir, @args ) {
    my ( $ok, $out, $err ) = run_command( [ qw{git -c credential.helper= -C}, $dir, @args ], env => { GIT_TERMINAL_PROMPT => 0 } );
    die 'git ' . join( ' ', @args ) . ': ' . ( ( grep { $_ ne '' } split /\n/, $err )[0] // 'failed' ) . "\n" unless $ok;
    chomp $out;
    return $out;
}

=head2 public_url($url) = STRING

$url, if git can fetch it over HTTPS.  A GitHub URL over ssh, in either form,
becomes its HTTPS URL.  Undef for any other URL.

=cut

my $github_ssh = qr{\A(?:ssh://)?git\@github[.]com[:/]};

sub public_url ($url) {
    return $url                           if $url =~ m{\Ahttps?://};
    return "https://github.com/$1/$2.git" if $url =~ m{$github_ssh([^/]+)/(.+?)(?:[.]git)?/?\z};
    return;
}

=head2 theme_url($dir) = STRING

The first remote of the git checkout $dir, as C<public_url> gives it, that
answers C<git ls-remote> with no credentials.  Undef when none does.

=cut

sub theme_url ($dir) {
    my @remotes = split /\n/, git( $dir, 'remote' );
    foreach my $remote (@remotes) {
        my $url = public_url( git( $dir, qw{remote get-url}, $remote ) ) // next;
        return $url if eval { git( $dir, 'ls-remote', $url, 'HEAD' ); 1 };
    }
    return;
}

=head2 status($checkout) = HASHREF

Fetches the upstream of $checkout and compares it with the checkout.  The
upstream of a checkout with no C<url> is C<theme_url>.  The
result has C<name>, C<label>, C<head>, the commit of the checkout, C<branch>,
C<dirty>, true when a tracked file has changes, and C<state>:

=over 4

=item * C<current>: the checkout has the upstream commit.

=item * C<behind>: the upstream has newer commits, C<behind> many, and a fast
forward reaches it.

=item * C<ahead>: the checkout has commits that the upstream does not.

=item * C<diverged>: both have commits that the other does not.

=item * C<private>: a theme with no public remote.

=item * C<unreachable>: the fetch failed.  C<error> says why.

=back

All but the last two also have C<upstream>, the upstream commit.

=cut

sub status ($co) {
    my $dir = $co->{dir};
    my %s   = (
        name   => $co->{name},
        label  => $co->{label} // $co->{name},
        head   => git( $dir, qw{rev-parse HEAD} ),
        branch => git( $dir, qw{rev-parse --abbrev-ref HEAD} ),
        dirty  => git( $dir, qw{status --porcelain --untracked-files=no} ) ne '' ? 1 : 0,
    );
    my $url = exists $co->{url} ? $co->{url} : eval { theme_url($dir) };
    return { %s, state => 'private' } unless $url;

    if ( !eval { git( $dir, qw{fetch --quiet --no-tags}, $url, "+HEAD:$upstream_ref" ); 1 } ) {
        return { %s, state => 'unreachable', error => Trog::Updates::reason($@) };
    }
    $s{upstream} = git( $dir, qw{rev-parse}, $upstream_ref );

    my $ancestor = sub ( $old, $new ) {
        return eval { git( $dir, qw{merge-base --is-ancestor}, $old, $new ); 1 }
    };
    if ( $s{head} eq $s{upstream} ) {
        $s{state} = 'current';
    }
    elsif ( $ancestor->( $s{head}, $s{upstream} ) ) {
        $s{state}  = 'behind';
        $s{behind} = git( $dir, qw{rev-list --count}, "$s{head}..$s{upstream}" ) + 0;
    }
    else {
        $s{state} = $ancestor->( $s{upstream}, $s{head} ) ? 'ahead' : 'diverged';
    }
    return \%s;
}

=head2 system_packages($dir, $commit) = STRING

The C<@system_keys> of F<metamerge.yml> at $commit of the checkout $dir, as
canonical JSON, so that two commits compare as strings.  Empty keys when the
commit has no F<metamerge.yml>.

=cut

sub system_packages ( $dir, $commit ) {
    my $yaml = eval { git( $dir, 'show', "$commit:metamerge.yml" ) };
    my $meta = defined $yaml ? YAML::XS::Load("$yaml\n") : {};
    $meta = {} unless ref $meta eq 'HASH';
    return JSON::MaybeXS->new( canonical => 1 )->encode( { map { $_ => $meta->{$_} } @system_keys } );
}

=head2 missing_modules($dir, $commit) = LIST

The modules that C<dzil listdeps --missing> names for $commit of the checkout
$dir, which this perl does not have.  It checks the commit out into a
temporary worktree, and removes it.  An empty list when the commit has no
F<dist.ini>.  Dies when dzil is not installed, or fails, because then nothing
can tell what the commit needs.

=cut

sub missing_modules ( $dir, $commit ) {
    return () unless eval { git( $dir, 'cat-file', '-e', "$commit:dist.ini" ); 1 };
    my $dzil = File::Which::which('dzil') or die "dzil is not installed, so nothing can tell which perl modules the new commits need\n";

    my $tree = File::Temp->newdir( 'tcms-update-XXXXXX', TMPDIR => 1 );
    git( $dir, qw{worktree add --quiet --detach}, "$tree/build", $commit );
    my ( $ok, $out, $err ) = run_command( [ $dzil, qw{listdeps --missing} ], dir => "$tree/build", timeout => $dzil_timeout );

    # The answer of dzil matters more than the cleanup, and git worktree prune
    # drops an entry whose directory File::Temp removes.
    eval { git( $dir, qw{worktree remove --force}, "$tree/build" ); 1 } or eval { git( $dir, qw{worktree prune} ); 1 } or 1;
    die "dzil listdeps failed for the new commits: " . ( ( grep { $_ ne '' } split /\n/, $err )[-1] // 'no reason given' ) . "\n" unless $ok;
    return grep { /\A[\w:]+\z/ } split /\n/, $out;
}

=head2 new_needs($dir, $from, $to) = LIST

A sentence for each thing that $to needs and $from did not, which the service
user cannot install: system packages, and perl modules.  Empty when there is
none.

=cut

sub new_needs ( $dir, $from, $to ) {
    my @needs;
    push @needs, 'The system packages in metamerge.yml change, and a person must install them' if system_packages( $dir, $from ) ne system_packages( $dir, $to );
    my @missing = eval { missing_modules( $dir, $to ) };
    push @needs, Trog::Updates::reason($@)                                                                   if $@;
    push @needs, 'The new commits need perl modules that this perl does not have: ' . join( ', ', @missing ) if @missing;
    return @needs;
}

=head2 unit_of($pid) = STRING

The systemd unit that the process $pid runs in, such as
C<example.test.service>.  Undef outside a unit.

=cut

sub unit_of ($pid) {
    open my $fh, '<', "$proc/$pid/cgroup" or return;
    my ($unit) = map { m{/([^/]+[.]service)$} } <$fh>;
    close $fh or return;
    return $unit;
}

=head2 tpsgi_pid() = INTEGER

The process of the master of tPSGI, from F<run/tpsgi.pid> of the tPSGI
checkout.  Dies when there is none.

=cut

sub tpsgi_pid {
    my $file = "$Trog::Updates::tpsgi_dir/run/tpsgi.pid";
    open my $fh, '<', $file or die "Cannot read $file, so a person must restart tPSGI: $!\n";
    my ($pid) = <$fh> =~ /(\d+)/;
    close $fh or die "Cannot read $file: $!\n";
    die "$file holds no process\n" unless $pid;
    return $pid;
}

=head2 hup_tpsgi()

Sends HUP to the master of tPSGI, so that it replaces its workers, which load
the code of tCMS again.  Dies if it cannot.

=cut

sub hup_tpsgi {
    my $pid = tpsgi_pid();
    kill( 'HUP', $pid ) or die "Could not send HUP to tPSGI, process $pid: $!\n";
    return;
}

=head2 restart_unit($unit, $no_block)

Restarts $unit with C<sudo -n /usr/bin/systemctl restart>, with
C<--no-block> when $no_block is true.  These are the commands that the tcms
and tpsgi recipes grant, as they are written.  Dies with what sudo said if it
fails.

=cut

sub restart_unit ( $unit, $no_block = 0 ) {
    my ( $ok, undef, $err ) = run_command( [ restart_command( $unit, $no_block ) ] );
    die "Could not restart $unit: $err" unless $ok;
    return;
}

=head2 restart_command($unit, $no_block) = LIST

The command of C<restart_unit>, as a list.

=cut

sub restart_command ( $unit, $no_block = 0 ) {
    return ( qw{sudo -n /usr/bin/systemctl restart}, ( $no_block ? '--no-block' : () ), $unit );
}

=head2 may_restart($unit, $no_block) = BOOLEAN

True when sudo lets this user run the command of C<restart_unit>, as
C<sudo -n -l> says.  It restarts nothing.

=cut

sub may_restart ( $unit, $no_block = 0 ) {
    my ( undef, @command ) = restart_command( $unit, $no_block );
    my ($ok) = run_command( [ qw{sudo -n -l}, grep { $_ ne '-n' } @command ] );
    return $ok;
}

=head2 reinstall()

Runs the C<install> and C<prereq-frontend> targets of F<Installer.mk>, as the
provision does, so that a new directory or front-end file of the new commit is
there.  Dies with what make said if it fails.

=cut

sub reinstall {
    my ( $ok, undef, $err ) = run_command( [qw{make -f Installer.mk install prereq-frontend}], timeout => 300 );
    die "make -f Installer.mk failed: $err" unless $ok;
    return;
}

=head2 check_task($job)

The task C<update_check>.  Finishes with C<checked_at> and L<Trog::Updates/checkouts>, the
C<status> of each of L<Trog::Updates/checkouts>.  A checkout that git cannot read is
C<unreachable>, with the reason in C<error>.

=cut

sub check_task ($job) {
    my @found = map {
        my $co = $_;
        eval { status($co) } // { name => $co->{name}, label => $co->{label} // $co->{name}, state => 'unreachable', error => Trog::Updates::reason($@) };
    } Trog::Updates::checkouts();
    return $job->finish( { checked_at => time, checkouts => \@found } );
}

=head2 update_task($job, $name)

The task C<update>.  Fast forwards the checkout named $name to its upstream,
and reloads what runs it, as the L</DESCRIPTION> says.  Fails with the reason
when it refuses.  One update runs at a time.  It queues a check when it is
done, so that /config shows the new state.  The result has C<name>, C<from>,
C<to> and C<reloaded>.

=cut

sub update_task ( $job, $name ) {
    my %result = ( name => $name );
    my ( $ok, $why );
    {
        # Held while the checkout moves, and let go at the end of the block.
        my $guard = $job->minion->guard( 'tcms_update', 3600 ) or return $job->fail("Another update is running\n");    ## no critic (ProhibitUnusedVarsStricter) -- the lock lasts as long as the variable
        $ok = eval {
            my $co = Trog::Updates::checkout($name);
            my $s  = status($co);
            die "$s->{label} is $s->{state}, so there is nothing to fast forward to" . ( $s->{error} ? ": $s->{error}" : '' ) . "\n" unless $s->{state} eq 'behind';
            die "$s->{label} has changes to tracked files, which a pull could lose\n" if $s->{dirty};
            my @needs = new_needs( $co->{dir}, $s->{head}, $s->{upstream} );
            die join( "\n", @needs ) . "\n" if @needs;

            git( $co->{dir}, qw{merge --ff-only --quiet}, $s->{upstream} );
            @result{qw{from to}} = ( $s->{head}, $s->{upstream} );
            1;
        };
        $why = $@;
    }
    Trog::Updates::enqueue_check();
    return $job->fail("$why") unless $ok;

    if ( $name eq 'tPSGI' ) {
        my $unit = unit_of( tpsgi_pid() ) // die "tPSGI does not run in a systemd unit, so a person must restart it\n";
        restart_unit($unit);
        return $job->finish( { %result, reloaded => [$unit] } );
    }

    my @reloaded;
    if ( $name eq 'tCMS' && !eval { reinstall(); 1 } ) {
        return $job->fail( { %result, error => "The pull worked, but $@" } );
    }
    hup_tpsgi();
    push @reloaded, 'tPSGI workers';

    # The restart comes after the finish, where a refusal could not show, so
    # ask sudo first.
    my $own = $name eq 'tCMS' ? unit_of('self') : undef;
    if ( $own && !may_restart( $own, 1 ) ) {
        return $job->fail( { %result, reloaded => \@reloaded, error => "The pull worked and tPSGI reloaded, but sudo does not let this user restart $own, so a person must restart it to load the new tasks" } );
    }
    $job->finish( { %result, reloaded => [ @reloaded, $own // () ] } );
    restart_unit( $own, 1 ) if $own;
    return;
}

1;
