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
use Trog::Auth  ();
use Trog::Vault ();

use Trog::Log qw{WARN INFO};

=head1 Trog::DataSource::ProvisionedVirt

Trog::DataSource::Virt, plus the recipe each guest was built from and a button to
build it again.

Everything about listing guests is inherited unchanged -- this is the same
libvirt connection, the same posts, the same search and the same refusal to be
cached.  What it adds is the other half of the story: a guest on a Troglodyne
hypervisor was provisioned from a recipe, and the recipe is on disk next to the
hypervisor rather than anywhere libvirt can tell you about.

One repository owns that lifecycle.  trog-provisioner's bin/provision generates
a guest's configuration from its recipe and then builds the machine out of it.
The generator used to be a second repository and a second run; the two had to
become one program once which hypervisor a guest lands on became a choice rather
than whichever machine you happened to be sat at.

Say where that checkout is and this becomes useful; leave it out and it degrades
to plain Virt, which is what it is.

    [provisioner]
        trog_provisioner = /home/you/Code/trog-provisioner

The recipes are not in the checkout.  They describe an installation rather than
the software, so trog-provisioner keeps them in /etc/trog-provisioner, or
wherever TROG_PROVISIONER_CONFIG says instead.  We find them by that same rule,
which is one fewer thing to tell tCMS and one fewer thing to disagree about.

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

# What the provisioner's two passwords are called in a user's vault.  One name
# per person rather than one per guest: the passphrase is to their own secrets
# database, and the sudo password is theirs on the hypervisor rather than
# anything to do with a particular guest.
our $secret_name = 'provisioner';
our $sudo_name   = 'provisioner_sudo';

# Where an installation's own files live, which is trog-provisioner's rule
# rather than ours -- see its Trog::Config.
our $provisioner_config = '/etc/trog-provisioner';

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

    # Asked once for the page rather than once per guest, and asked rather than
    # opened: what the form needs to know is which box to draw.
    my $user = $query->{user} // '';
    $config->{can_remember}    = ( $user                   && Trog::Vault::has_key() )                  ? 1 : 0;
    $config->{remembered}      = ( $config->{can_remember} && Trog::Vault::has( $user, $secret_name ) ) ? 1 : 0;
    $config->{sudo_remembered} = ( $config->{can_remember} && Trog::Vault::has( $user, $sudo_name ) )   ? 1 : 0;

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

    # There has to be something to run it with, and we will not rebuild the
    # machine we are answering the request from -- see act() in the parent,
    # which refuses to power that one off for the same reason.
    $post->{can_reprovision} =
      ( $post->{has_recipe} && $config->{trog_provisioner} && !$post->{is_self} ) ? 1 : 0;

    # Which of the things the button has to ask for.
    $post->{passphrase_remembered} = $config->{remembered};
    $post->{sudo_remembered}       = $config->{sudo_remembered};
    $post->{can_remember}          = $config->{can_remember};

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

Where the provisioner is checked out, from the tCMS configuration, and where the
recipes it reads are, from trog-provisioner's own rule for that.

    trog_provisioner    the checkout, or undef
    recipes             the directory the guests' recipes are in

Undef for the checkout means the feature is off rather than broken: a site which
has not configured it gets a plain guest listing, which is what it asked for.

=cut

sub _config {
    my $conf = Trog::Config::get();

    # Nothing to configure here: the provisioner reads this env var or that
    # directory, so a recipe we showed from anywhere else would be a recipe it
    # is not going to build from.
    my %config = ( recipes => ( $ENV{TROG_PROVISIONER_CONFIG} // $provisioner_config ) . "/$recipe_dir" );

    my $dir = $conf->param('provisioner.trog_provisioner');
    return \%config unless $dir && !ref $dir;

    # Resolved, and checked to be there.  A path in a config file which does not
    # exist is a typo, and finding that out here beats finding it out halfway
    # through a reprovision.
    my $absolute = Cwd::abs_path($dir);
    if ( !$absolute || !-d $absolute ) {
        WARN("provisioner.trog_provisioner is set to '$dir', which is not a directory here");
        return \%config;
    }

    $config{trog_provisioner} = $absolute;
    return \%config;
}

# A guest name reaches the filesystem here, so it is a hostname or it is nothing.
sub _safe_domain ($domain) {
    return undef unless defined $domain && length($domain) && length($domain) < 254;
    return undef if $domain =~ m/(?:^|\.)\.\.?(?:\.|$)/;

    my ($safe) = $domain =~ m/^([A-Za-z0-9][A-Za-z0-9._-]*)$/;
    return $safe;
}

# An installation's recipes are where they are whether tCMS knows about the
# provisioner or not, but reading them is the feature, so it is off with it.
sub _recipe_path ( $config, $domain ) {
    return undef unless $config->{trog_provisioner};

    my $safe = _safe_domain($domain);
    return undef unless $safe;

    my $path = "$config->{recipes}/$safe.yaml";
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

Run bin/provision for one guest, which generates its configuration from its
recipe and then builds the machine.

    domain      which guest.  Required, and validated as a hostname.
    user        who asked.  For the log, and whose vault to look in.
    passphrase  the KeePass passphrase the recipe's secrets need.
    sudo        their sudo password on the hypervisor, if it wants one.
    totp        a code, instead of those, when they have been stored.
    remember    store what they just typed, so that next time is a code.

Returns immediately.  Provisioning a machine takes minutes and an HTTP worker
does not have minutes, so the work is handed to a detached process and the
caller is told it started rather than told it finished.  What happened is in
logs/reprovision/$domain.log, which is what _log_tail reads back onto the page.

=head3 WHY IT ASKS FOR ANYTHING AT ALL

Two passwords, for two different reasons.

Every recipe inherits secret: values from _base, so the provisioner opens a
KeePass database on its way past and wants the passphrase to it.  The
alternative to asking is keeping the master password for every secret an
operator holds in a file the webserver can read, which is worse than asking.

And almost everything it does on the hypervisor needs root.  Where the login
there has passwordless sudo -- which is how ours are set up, and what we would
recommend -- there is nothing to ask for.  Where it does not, sudo over ssh has
no terminal to ask at, and a run that finds that out dies several minutes in on
a prompt nobody will ever see.  So it is asked for here instead, and left empty
by anybody who does not need it.

Asking every time has its own cost, though: a passphrase somebody has to have to
hand is a passphrase that gets written down, and then it is in a text file
instead of a config file, which is not an improvement.  So it can be stored --
see Trog::Vault, where it is sealed under a key the database does not contain --
and then what this asks for is a TOTP code, which proves the person is here
without their having to be holding anything.

The code is spent either way, so it authorizes this one reprovision rather than
every reprovision inside its window.

However they arrive, they go down the child's stdin as a credentials block --
see Trog::Credentials in trog-provisioner -- and are written nowhere: not the
log, not the process table, not the configuration.

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
    return ( 0, 'provisioner.trog_provisioner is not configured' ) unless $config->{trog_provisioner};

    my $recipe = _recipe_path( $config, $safe );
    return ( 0, "there is no recipe for '$safe' in $config->{recipes}" ) unless $recipe;

    my ( $credentials, $why ) = _credentials(%args);
    return ( 0, $why ) unless $credentials;

    my $unsendable = _sendable($credentials);
    return ( 0, $unsendable ) if $unsendable;

    # One at a time.  Two provisions of one machine racing each other is not
    # something anybody should be able to start by double clicking.
    my $running = status($safe);
    return ( 0, 'a reprovision of this guest is already running' ) if $running && $running->{state} eq 'running';

    # --credentials, because nothing in there reads stdin unless it is told to.
    my @command = ( "$config->{trog_provisioner}/bin/provision", '--credentials', $safe );
    return ( 0, "$command[0] is not there to run" ) unless -x $command[0];    ## no critic (ProhibitFiletest_rwxRWX) -- refusing early beats finding out mid-provision

    INFO( "Reprovision of '$safe' requested by " . ( $args{user} // 'somebody' ) );

    my ( $ok, $failed ) = _spawn( $safe, $credentials, $config->{trog_provisioner}, \@command, $args{user} );
    return ( 0, $failed ) unless $ok;

    return ( 1, "reprovision started; watch $log_dir/$safe.log" );
}

=head2 _credentials(%args) = ($credentials, $why)

What to hand the provisioner, out of whatever the form sent: a hashref of the
names Trog::Credentials knows, or undef and a reason.

A code is only ever exchanged for passwords that are already stored -- it is
proof of presence, not a password, and there is nothing to derive from six
digits.  Typed passwords are used as they are, and stored on the way past if
they asked for that, so the next run is a code.

The two are independent.  A sudo password typed into the form wins over a stored
one, because somebody typing it has a reason to; and a hypervisor with
passwordless sudo simply never has one, in the form or the vault, which is the
ordinary case and not a missing answer.

The reason, when there is one, is what the person reads -- so it has to tell
'that code is stale' apart from 'there is nothing stored to unlock'.

=cut

sub _credentials (%args) {
    my $user = $args{user} // '';

    my %credentials;

    # What they typed, as opposed to what came back out of the vault.  Only the
    # typed ones are worth filing away, and only they can be: a value fetched
    # from the vault is already in it.
    my %typed;
    $typed{sudo} = $args{sudo} if length( $args{sudo} // '' );

    if ( length( $args{totp} // '' ) ) {
        return ( undef, 'a code identifies somebody, and nobody is logged in' ) unless $user;

        # Asked before the code is spent, and the reason is that a code is
        # spent whether or not the thing it authorized worked.  Somebody whose
        # key has gone would otherwise burn a code to be told there is nothing
        # to unlock, then wait thirty seconds to be told it again.  has() opens
        # the row to answer, so this is the same answer get() is about to give.
        return (
            undef,
            "there is no provisioning passphrase this installation can open for $user." . "  Store it again under /secrets, or reprovision with the passphrase itself."
        ) unless Trog::Vault::has( $user, $secret_name );

        my ( $ok, $why ) = Trog::Auth::spend_totp( $user, $args{totp} );
        return ( undef, $why ) unless $ok;

        my $stored = Trog::Vault::get( $user, $secret_name );
        return ( undef, "the stored provisioning passphrase for $user could not be read" ) unless defined $stored && length($stored);
        $credentials{keepass} = $stored;
    }
    else {
        return ( undef, 'a passphrase is required, as the provisioner asks for one' ) unless length( $args{passphrase} // '' );
        $credentials{keepass} = $args{passphrase};
        $typed{keepass}       = $args{passphrase};
    }

    # A typed sudo password beats a stored one -- somebody typing it has a
    # reason to -- and no sudo password at all is the ordinary answer, for a
    # hypervisor whose login has passwordless sudo.
    my $sudo = $typed{sudo} // ( $user ? Trog::Vault::get( $user, $sudo_name ) : undef );
    $credentials{sudo} = $sudo if defined $sudo && length($sudo);

    _remember( $user, \%typed ) if $args{remember} && $user && %typed;

    return ( \%credentials, '' );
}

# One 'name: value' per line is the format, so a value with a newline in it is
# two lines -- and the second one could name a credential nobody asked us to
# send.  Refused rather than escaped or trimmed: no password anybody meant to
# type has a newline in the middle of it, and quietly changing what somebody
# typed into their own password field is worse than saying no.
sub _sendable ($credentials) {
    foreach my $name ( sort keys %$credentials ) {
        next unless $credentials->{$name} =~ m/[\r\n]/;
        return "the $name has a line break in it, which is not something this can send";
    }
    return '';
}

# File away what they typed, so the next run is a code.
#
# Said rather than refused when it does not work: they asked for a reprovision
# and gave us what it needs, and failing to keep a copy is not a reason to not do
# the thing they asked for.
sub _remember ( $user, $credentials ) {
    my %vault_name = ( keepass => $secret_name, sudo => $sudo_name );

    foreach my $name ( sort keys %$credentials ) {
        my ( $ok, $why ) = Trog::Vault::set( $user, $vault_name{$name}, $credentials->{$name} );
        WARN("Could not remember the provisioner's $name for $user: $why") unless $ok;
    }

    return;
}

=head2 _spawn($domain, $credentials, $dir, $command, $user)

Fork the provisioner off where nothing is waiting for it.

Double forked and setsid'd on purpose: a save signals the parent to reload the
routing table, and a provision which died because a worker was recycled halfway
through would leave a half-built machine.  This has to outlive the request, the
worker, and a restart.

It runs through open() with a list, so there is no shell between us and the
program, and the guest name is an argument rather than a thing that could be
read as one.

The passwords go down its stdin as a credentials block, which is
Trog::Credentials' format over there: one C<name: value> per line, and a blank
line to say that is all of them.  A value with a newline in it would be two
lines, and the second could name a credential we were not asked to send, so one
is refused rather than escaped -- there is no password anybody meant to type
that has a newline in the middle of it.

=cut

sub _spawn ( $domain, $credentials, $dir, $command, $user ) {
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

    print {$fh} "\n--- $command->[0] $command->[1] (in $dir)\n";

    # In the checkout, so that anything the provisioner writes relative to where
    # it was run lands there rather than in the middle of the website.
    if ( !chdir($dir) ) {
        print {$fh} "could not chdir to $dir: $!\n";
        POSIX::_exit(1);
    }

    # The child's own stdout and stderr are the log, so whatever the program
    # says lands there without a shell redirect to get wrong.
    open( STDOUT, '>&', $fh ) or POSIX::_exit(1);
    open( STDERR, '>&', $fh ) or POSIX::_exit(1);

    # List form on purpose, and the reason the whole thing is shaped this way: a
    # piped open with a list never involves a shell, so the guest name is an
    # argument and cannot be read as a command.  The single argument form of
    # this would be the bug.
    my $ok = open( my $stdin, '|-', @$command );    ## no critic (ProhibitPipeOpen) -- list form, so no shell
    if ( !$ok ) {
        print {$fh} "could not run $command->[0]: $!\n";
        POSIX::_exit(1);
    }

    # What the provisioner would otherwise have nobody to ask for.  Closed
    # afterwards, so the read on the far side ends rather than waiting on us.
    print {$stdin} "$_: $credentials->{$_}\n" foreach sort keys %$credentials;
    print {$stdin} "\n";
    close($stdin);

    if ($?) {
        my $status = $? >> 8;
        print {$fh} "\n--- $command->[0] exited $status\n";
        _write_status(
            $domain,
            state    => 'failed',
            started  => $started,
            finished => time(),
            exit     => $status,
            failed   => $command->[0],
            user     => ( $user // '' ),
        );
        POSIX::_exit($status);
    }

    print {$fh} "\n=== finished ===\n";
    _write_status( $domain, state => 'ok', started => $started, finished => time(), exit => 0, user => ( $user // '' ) );
    POSIX::_exit(0);
}

1;
