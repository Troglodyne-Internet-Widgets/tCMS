package Trog::DataSource::ProvisionedVirt;

use v5.36;
use re '/aa';

use parent qw{Trog::DataSource::Virt};

use Cwd                 ();
use File::Basename      ();
use File::Path          ();
use File::Slurper       ();
use File::Slurper::Temp ();
use POSIX               ();

use Trog::Config     ();
use Trog::DataSource ();
use Trog::DataSource::Virt();

use Trog::Log qw{WARN INFO};

=head1 Trog::DataSource::ProvisionedVirt

Trog::DataSource::Virt, plus the recipe each guest was built from and a button to
build it again.

Everything about listing guests is inherited unchanged -- this is the same
libvirt connection, the same posts, the same search and the same refusal to be
cached.  What it adds is the other half of the story: a guest on a Troglodyne
hypervisor was provisioned from a recipe, and the recipe is on disk next to the
hypervisor rather than anywhere libvirt can tell you about.

Two repositories between them own that lifecycle:

    provisioners        recipes.d/$domain.yaml, and bin/new_config which turns
                        a recipe into a configuration package
    trog-provisioner    bin/provision, which turns that package into a machine

Say where they are in the tCMS configuration and this becomes useful; leave them
out and it degrades to plain Virt, which is what it is.

    [provisioner]
        provisioners     = /home/you/Code/provisioners
        trog_provisioner = /home/you/Code/trog-provisioner

=head1 A NOTE ON SAFETY

Reprovisioning is not a recoverable operation.  It destroys the guest and builds
it again from its recipe, and whatever was on it that the recipe does not
describe does not come back.

The discipline is the same as its parent's, and for the same reasons.  It is
POST only and admin only; it refuses outright for the guest tCMS is itself
running on, whatever the template chose to draw; and nothing it runs goes near a
shell, so a guest name is an argument and can never be a command.

=cut

our $recipe_dir = 'recipes.d';
our $log_dir    = 'logs/reprovision';

# What a reprovision can be, in the order it can be it.
our %states = (
    running     => 'reprovisioning',
    ok          => 'provisioned',
    failed      => 'reprovision failed',
    interrupted => 'reprovision interrupted',
);

=head1 FUNCTIONS

=head2 posts($series, $query) = @posts

The guests Trog::DataSource::Virt would have listed, each carrying what we know
about how it was built:

    recipe                the recipe's YAML, as text, for the page to show
    recipe_path           where that came from
    has_recipe            whether there was one at all
    can_reprovision       whether the button should be drawn
    reprovision_state     running, ok, failed, interrupted, or absent
    reprovision_status    that, in words a person reads
    reprovision_started   when the last run began
    reprovision_finished  when it ended, if it has
    reprovision_exit      what it exited with, if it has
    reprovision_by        who asked for it
    is_reprovisioning     whether one is going on right now
    reprovision_log       the tail of the last run
    reprovision_log_href  where to read all of it

A guest with no recipe is still listed.  Plenty of guests on a hypervisor were
not built by this, and saying nothing about them is better than hiding them.

=cut

sub posts ( $series, $query ) {
    my @guests = Trog::DataSource::Virt::posts( $series, $query );
    my $config = _config();

    return map { _with_recipe( $_, $config ) } @guests;
}

sub _with_recipe ( $post, $config ) {
    return $post if $post->{unreachable};

    my $domain = $post->{domain} // '';
    my $path   = _recipe_path( $config, $domain );

    if ($path) {
        my $recipe = eval { File::Slurper::read_text($path) };
        if ( defined $recipe ) {
            $post->{recipe}      = $recipe;
            $post->{recipe_path} = $path;
            $post->{has_recipe}  = 1;
        }
        else {
            WARN("Could not read the recipe for '$domain' at $path: $@");
        }
    }

    # Both halves have to be there to run the lifecycle, and we will not rebuild
    # the machine we are answering the request from -- see act() in the parent,
    # which refuses to power that one off for the same reason.
    $post->{can_reprovision} =
      ( $post->{has_recipe} && $config->{provisioners} && $config->{trog_provisioner} && !$post->{is_self} ) ? 1 : 0;

    my $status = status($domain);
    if ($status) {
        $post->{reprovision_state}    = $status->{state};
        $post->{reprovision_status}   = $states{ $status->{state} } // $status->{state};
        $post->{reprovision_started}  = $status->{started};
        $post->{reprovision_finished} = $status->{finished};
        $post->{reprovision_exit}     = $status->{exit};
        $post->{reprovision_by}       = $status->{user};
        $post->{is_reprovisioning}    = $status->{state} eq 'running' ? 1 : 0;
    }

    # One at a time.  Two provisions of the same machine at once is not a thing
    # anybody wants to have started by double clicking.
    $post->{can_reprovision} = 0 if $post->{is_reprovisioning};

    $post->{reprovision_log}      = _log_tail($domain);
    $post->{reprovision_log_href} = $post->{reprovision_log} ? "/guest/reprovision/log/$domain" : undef;

    return $post;
}

=head2 status($domain) = HASHREF or undef

What the last reprovision of this guest is doing, or did.

    state     running, ok, failed or interrupted
    pid       the process doing it, while one is
    started   / finished / exit / user

Nothing waits on the process which does the work -- it is deliberately orphaned,
so that it outlives the worker that started it -- which means its exit status is
not reported to anybody.  This file is how it says what happened, and the last
thing the run does is write it.

A run whose status still says 'running' but whose process is gone therefore
crashed, was killed, or took the machine down with it, and reads as interrupted.
That is a guess from the one piece of evidence there is, and it is the honest
one: the alternative is a page that says a provision is in progress forever.

=cut

sub status ($domain) {
    my $safe = _safe_domain($domain);
    return undef unless $safe;

    my $path = "$log_dir/$safe.status";
    return undef unless -f $path;    ## no critic (ProhibitFiletest_f) -- has this ever run

    my $raw = eval { File::Slurper::read_text($path) };
    return undef unless defined $raw;

    my %status;
    foreach my $line ( split( "\n", $raw ) ) {
        my ( $key, $value ) = $line =~ m/^(\w+)=(.*)$/;
        $status{$key} = $value if defined $key;
    }
    return undef unless $status{state};

    # kill 0 rather than trusting the file: the process is orphaned, so nothing
    # else would ever correct a 'running' that stopped being true.  Same uid, so
    # this is a real answer.  A recycled pid could fool it, which would show a
    # finished run as still going rather than the other way about.
    if ( $status{state} eq 'running' ) {
        my $alive = $status{pid} && kill( 0, $status{pid} );
        $status{state} = 'interrupted' unless $alive;
    }

    return \%status;
}

# Written by the run itself, at the two moments worth recording.  By rename, so
# that a page drawn while the run is writing sees the old status or the new one
# and never half of either -- the reader would ignore a torn file, but ignoring
# it means the page says nothing was ever run.
sub _write_status ( $domain, %fields ) {
    my $path = "$log_dir/$domain.status";
    my $out  = join( '', map { "$_=" . ( $fields{$_} // '' ) . "\n" } sort keys %fields );

    local $@;
    eval {
        # Beside the file it replaces, or the rename is a copy across
        # filesystems and stops being atomic.
        local $File::Slurper::Temp::FILE_TEMP_DIR   = $log_dir;
        local $File::Slurper::Temp::FILE_TEMP_PERMS = oct('644');
        File::Slurper::Temp::write_text( $path, $out );
        1;
    } or WARN("Could not record the reprovision status for '$domain': $@");

    return;
}

=head2 _config() = HASHREF

Where the two repositories are, from the tCMS configuration.

Undef for either means the feature is off rather than broken: a site which has
not configured them gets a plain guest listing, which is what it asked for.

=cut

sub _config {
    my $conf = Trog::Config::get();

    my %config;
    foreach my $key (qw{provisioners trog_provisioner}) {
        my $dir = $conf->param("provisioner.$key");
        next unless $dir && !ref $dir;

        # Resolved, and checked to be there.  A path in a config file which does
        # not exist is a typo, and finding that out here beats finding it out
        # halfway through a reprovision.
        my $absolute = Cwd::abs_path($dir);
        if ( !$absolute || !-d $absolute ) {
            WARN("provisioner.$key is set to '$dir', which is not a directory here");
            next;
        }

        $config{$key} = $absolute;
    }

    return \%config;
}

# A guest name reaches the filesystem here, so it is a hostname or it is nothing.
sub _safe_domain ($domain) {
    return undef unless defined $domain && length($domain) && length($domain) < 254;
    return undef if $domain =~ m/(?:^|\.)\.\.?(?:\.|$)/;

    my ($safe) = $domain =~ m/^([A-Za-z0-9][A-Za-z0-9._-]*)$/;
    return $safe;
}

sub _recipe_path ( $config, $domain ) {
    return undef unless $config->{provisioners};

    my $safe = _safe_domain($domain);
    return undef unless $safe;

    my $path = "$config->{provisioners}/$recipe_dir/$safe.yaml";
    return -f $path ? $path : undef;    ## no critic (ProhibitFiletest_f) -- is there a recipe for this guest
}

=head2 _log_tail($domain) = STRING

The last of whatever the previous reprovision said, or nothing.

The run happens in a detached process which nobody is waiting on, so this file
is the only account of it there is.

=cut

our $log_tail_bytes = 4096;

sub _log_tail ($domain) {
    my $safe = _safe_domain($domain);
    return undef unless $safe;

    my $path = "$log_dir/$safe.log";
    return undef unless -f $path;    ## no critic (ProhibitFiletest_f) -- has this ever run

    my $text = eval { File::Slurper::read_text($path) };
    return undef unless defined $text;

    return length($text) > $log_tail_bytes ? substr( $text, -$log_tail_bytes ) : $text;
}

=head2 log_for($domain) = STRING or undef

The whole reprovision log for a guest, for the route which serves it.

Undef when there has never been a run, or when the name is not a guest name --
this reaches the filesystem, so it is checked here rather than trusted from the
route that called it.

=cut

our $log_max_bytes = 1024 * 1024;

sub log_for ($domain) {
    my $safe = _safe_domain($domain);
    return undef unless $safe;

    my $path = "$log_dir/$safe.log";
    return undef unless -f $path;    ## no critic (ProhibitFiletest_f) -- has this ever run

    my $text = eval { File::Slurper::read_text($path) };
    return undef unless defined $text;

    # A provisioner can be chatty and this goes out in one response.
    return length($text) > $log_max_bytes
      ? "[ truncated: showing the last " . int( $log_max_bytes / 1024 ) . "KB ]\n" . substr( $text, -$log_max_bytes )
      : $text;
}

=head2 reprovision(%args) = ($ok, $message)

Run the full lifecycle for one guest: bin/new_config in provisioners, and then
bin/provision in trog-provisioner.

    domain      which guest.  Required, and validated as a hostname.
    passphrase  the KeePass passphrase new_config asks for on stdin.
    user        who asked, for the log.

Returns immediately.  Provisioning a machine takes minutes and an HTTP worker
does not have minutes, so the work is handed to a detached process and the
caller is told it started rather than told it finished.  What happened is in
logs/reprovision/$domain.log, which is what _log_tail reads back onto the page.

The passphrase is passed down the child's stdin and is never written anywhere:
not to the log, not to the process table, not to the configuration.  new_config
prompts for it because every recipe inherits secret: values from _base, and the
alternative to asking each time is keeping the master password for every secret
the operator holds in a file the webserver can read.

=cut

sub reprovision (%args) {
    my $safe = _safe_domain( $args{domain} );
    return ( 0, 'bad guest name' ) unless $safe;

    # The template does not draw the button for this guest.  This is what
    # actually stops it: /guest/reprovision is a POST anybody holding the admin
    # acl can craft by hand, and there would be nothing left to report to.
    if ( Trog::DataSource::Virt::_is_self($safe) ) {
        WARN("Refused to reprovision '$safe': that is this server");
        return ( 0, "'$safe' is this server -- refusing to reprovision it" );
    }

    my $config = _config();
    return ( 0, 'provisioner.provisioners is not configured' )     unless $config->{provisioners};
    return ( 0, 'provisioner.trog_provisioner is not configured' ) unless $config->{trog_provisioner};

    my $recipe = _recipe_path( $config, $safe );
    return ( 0, "there is no recipe for '$safe' in $recipe_dir" ) unless $recipe;

    return ( 0, 'a passphrase is required, as new_config asks for one' ) unless length( $args{passphrase} // '' );

    # One at a time.  Two provisions of one machine racing each other is not
    # something anybody should be able to start by double clicking.
    my $running = status($safe);
    return ( 0, 'a reprovision of this guest is already running' ) if $running && $running->{state} eq 'running';

    my @lifecycle = (
        [ $config->{provisioners},     "$config->{provisioners}/bin/new_config",    $safe ],
        [ $config->{trog_provisioner}, "$config->{trog_provisioner}/bin/provision", $safe ],
    );

    foreach my $step (@lifecycle) {
        my ( undef, $program ) = @$step;
        return ( 0, "$program is not there to run" ) unless -x $program;    ## no critic (ProhibitFiletest_rwxRWX) -- refusing early beats finding out mid-lifecycle
    }

    INFO( "Reprovision of '$safe' requested by " . ( $args{user} // 'somebody' ) );

    my ( $ok, $why ) = _spawn( $safe, $args{passphrase}, \@lifecycle, $args{user} );
    return ( 0, $why ) unless $ok;

    return ( 1, "reprovision started; watch $log_dir/$safe.log" );
}

=head2 _spawn($domain, $passphrase, $lifecycle, $user)

Fork the lifecycle off where nothing is waiting for it.

Double forked and setsid'd on purpose: a save signals the parent to reload the
routing table, and a provision which died because a worker was recycled halfway
through would leave a half-built machine.  This has to outlive the request, the
worker, and a restart.

Each step runs through open() with a list, so there is no shell between us and
the program, and the guest name is an argument rather than a thing that could be
read as one.

=cut

sub _spawn ( $domain, $passphrase, $lifecycle, $user ) {
    my $log = "$log_dir/$domain.log";

    local $@;
    eval { File::Path::make_path($log_dir); 1 } or return ( 0, "could not make $log_dir: $@" );

    my $pid = fork();
    return ( 0, "could not fork: $!" ) unless defined $pid;
    return ( 1, 'started' ) if $pid;

    # First child: detach, fork again, and let the middle process go so that
    # nothing is left for the worker to reap or be blocked by.
    POSIX::setsid();
    my $grandchild = fork();
    POSIX::_exit(0) if !defined $grandchild || $grandchild;

    # From here on we are nobody's child and nothing reads our exit status, so
    # the log is the only way to say anything.
    open( my $fh, '>>', $log ) or POSIX::_exit(1);
    $fh->autoflush(1);

    my $started = time();
    print {$fh} "\n=== reprovision of $domain by " . ( $user // 'somebody' ) . ' at ' . localtime($started) . " ===\n";

    # $$ is this process, which is the one that will still be here in ten
    # minutes -- the two before it have already gone.  status() checks it is
    # alive, so it has to be the pid of whatever is actually doing the work.
    _write_status( $domain, state => 'running', pid => $$, started => $started, user => ( $user // '' ) );

    foreach my $step (@$lifecycle) {
        my ( $dir, @command ) = @$step;

        print {$fh} "\n--- $command[0] $command[1] (in $dir)\n";

        if ( !chdir($dir) ) {
            print {$fh} "could not chdir to $dir: $!\n";
            POSIX::_exit(1);
        }

        # The child's own stdout and stderr are the log, so whatever the program
        # says lands there without a shell redirect to get wrong.
        open( STDOUT, '>&', $fh ) or POSIX::_exit(1);
        open( STDERR, '>&', $fh ) or POSIX::_exit(1);

        # List form on purpose, and the reason the whole thing is shaped this
        # way: a piped open with a list never involves a shell, so the guest
        # name is an argument and cannot be read as a command.  The single
        # argument form of this would be the bug.
        my $ok = open( my $stdin, '|-', @command );    ## no critic (ProhibitPipeOpen) -- list form, so no shell
        if ( !$ok ) {
            print {$fh} "could not run $command[0]: $!\n";
            POSIX::_exit(1);
        }

        # What new_config prompts for.  The second step ignores it, and giving
        # it a closed stdin instead would make anything that asks hang forever.
        print {$stdin} "$passphrase\n";
        close($stdin);

        if ($?) {
            my $status = $? >> 8;
            print {$fh} "\n--- $command[0] exited $status, stopping here\n";
            _write_status(
                $domain,
                state    => 'failed',
                started  => $started,
                finished => time(),
                exit     => $status,
                failed   => $command[0],
                user     => ( $user // '' ),
            );
            POSIX::_exit($status);
        }
    }

    print {$fh} "\n=== finished ===\n";
    _write_status( $domain, state => 'ok', started => $started, finished => time(), exit => 0, user => ( $user // '' ) );
    POSIX::_exit(0);
}

1;
