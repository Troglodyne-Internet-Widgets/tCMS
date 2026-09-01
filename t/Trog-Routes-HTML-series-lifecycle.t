#!/usr/bin/env perl

# Stands up a genuinely fresh tCMS in a temp dir, then walks the loop a user
# actually performs: register an admin, invent a post type in the wizard, and
# for each content post type build a topbar series, confirm it lands in the
# nav, add a child post and confirm the child renders on the series page.
#
# Verification goes through Trog::Routes::HTML::index() -- directly, or via
# series() which delegates to it -- and matches on the returned HTML.

use strict;
use warnings;

# FindBin MUST come first.  $FindBin::Bin is derived from $0, which prove hands
# us relatively, and it is computed once.  chdir before this loads and every
# module's `use FindBin::libs` resolves against the sandbox instead of the repo.
use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use Cwd           ();
use Encode        ();
use File::Copy    ();
use File::Find    ();
use File::Path    ();
use File::Temp    ();
use Time::HiRes   ();
use URI::Escape   ();
use JSON::MaybeXS ();
use File::Slurper ();

our ( $REPO, $ROOT, $OLDCWD );
our %REPO_BEFORE;

# Which data model this run exercises.  Every assertion in this file is about
# what the app does, not how it stores anything, so all of them have to hold for
# any of them.
our $MODEL;

# In BEGIN because the sandbox is built in one, before file scope runs.
BEGIN { $MODEL = $ENV{TCMS_TEST_DATA_MODEL} || 'FlatFile' }

# name => (size, mtime) for every file under the repo dirs this test could
# plausibly disturb.  Cheap enough, and it is the only real proof of isolation.
sub _snapshot {
    my ($dir) = @_;
    my %seen;
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                return unless -f $File::Find::name;
                my @st = stat(_);
                $seen{$File::Find::name} = "$st[7]:$st[9]";
            },
        },
        $dir
    );
    return %seen;
}

sub _copy_tree {
    my ( $from, $to ) = @_;
    File::Path::make_path($to);
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                my $rel = substr( $File::Find::name, length($from) );
                return unless length $rel;
                my $dst = "$to$rel";
                if    ( -d $File::Find::name ) { File::Path::make_path($dst) }
                elsif ( -f $File::Find::name ) { File::Copy::copy( $File::Find::name, $dst ) or die "copy $File::Find::name: $!" }
            },
        },
        $from
    );
    return;
}

# Everything the sandbox needs, in one BEGIN.  The Trog:: modules are require()d
# at runtime below, which is unconditionally after every BEGIN -- so no later
# edit can accidentally load them before the chdir.  That matters: TCMS.pm runs
# build_routes() at file scope and FlatFile.pm reads the tag index at file
# scope, both against whatever cwd happens to be current.
BEGIN {
    $REPO   = Cwd::abs_path("$FindBin::Bin/..");
    $OLDCWD = Cwd::getcwd();

    %REPO_BEFORE = map { _snapshot("$REPO/$_") } qw{config data www/templates www/assets logs totp};

    $ROOT = File::Temp::tempdir( 'tcms-lifecycle-XXXXXX', TMPDIR => 1, CLEANUP => 0 );

    # Installer.mk's tree, plus upload-src for the file.tx fixture.
    File::Path::make_path(
        map { "$ROOT/$_" }
          qw{
          config schema data/files logs totp upload-src
          www/assets/private www/statics www/themes www/scripts
          }
    );

    # A real fresh install: get() looks for config/main.cfg, doesn't find one,
    # and falls through to the shipped default.  The data model is the shipped
    # one unless the environment names another, which is how this whole file
    # gets run against each of them -- the point being that a data model is only
    # finished when the app cannot tell which one it is talking to.
    my $stock = File::Slurper::read_text("$REPO/config/default.cfg");
    $stock =~ s/^(\s*data_model=).*$/$1$MODEL/m or die "could not set the data model in default.cfg";
    File::Slurper::write_text( "$ROOT/config/default.cfg", $stock );

    # Hardcoded paths in Auth.pm, TagIndex.pm, the data models and Log.pm -- not negotiable.
    File::Copy::copy( "$REPO/schema/$_", "$ROOT/schema/$_" ) or die $! for qw{auth.schema flatfile.schema sqlite.schema log.schema};

    # COPY, don't symlink: post_wizard_save() writes into Trog::Themes::forms_dir(),
    # and a symlink would land the generated post type in the real repo.
    _copy_tree( "$REPO/www/templates", "$ROOT/www/templates" );

    # posts.tx pulls in the EmojiPicker component for an editor, and EmojiPicker
    # dies outright if this file is missing.  Only category and emoji are read.
    open( my $fh, '>', "$ROOT/www/scripts/list.min.json" ) or die $!;
    print {$fh} '{"emojis":[{"category":"Smileys","emoji":"X"}]}';
    close $fh;

    # Text::Xslate computes its default cache dir from $HOME once, at load time.
    # Without this the sandbox writes compiled templates into the real ~/.xslate_cache.
    $ENV{HOME} = $ROOT;

    chdir($ROOT) or die "could not chdir to sandbox $ROOT: $!";
}

END {
    # Never rmtree the directory you are standing in.
    chdir($OLDCWD) if $OLDCWD;
    if ( $ENV{TCMS_TEST_KEEP} ) {
        diag("TCMS_TEST_KEEP set, sandbox left at $ROOT");
    }
    elsif ( $ROOT && -d $ROOT ) {

        # SQLite handles are file-lexical in Trog::SQLite and unreachable from
        # here; DBI disconnects at global destruction, after these are gone.
        eval { File::Path::remove_tree($ROOT) };
    }
}

diag("sandbox: $ROOT");

require Trog::Log;
Trog::Log::log_init( 'logs/tcms.log', 'info' );    # sets $LOGDIR, hence logs/log.db

require Trog::Config;
require Trog::Themes;
require Trog::Data;
require Trog::Auth;
require Trog::SQLite::TagIndex if $MODEL eq 'FlatFile';
require Trog::Routes::HTML;
require Trog::Routes::JSON;

#--------------------------------------------------------------------------
# A stand-in for the tPSGI object the router injects as $query->{tpsgi}.
#--------------------------------------------------------------------------
{

    package Test::TPSGI;

    sub new {
        my ( $class, %args ) = @_;
        return bless {
            callbacks   => 0,
            renders     => {},
            invalidated => [],
            restarts    => 0,
            tpsgi_dir   => Cwd::getcwd(),
            log_dir     => 'logs',
            gid         => $),
            verbose     => 0,
            %args,
        }, $class;
    }

    sub INFO  { 1 }
    sub DEBUG { 1 }
    sub WARN  { 1 }
    sub ERROR { 1 }
    sub CRIT  { 1 }
    sub ALERT { 1 }
    sub EMERG { 1 }
    sub FATAL { 1 }

    sub see_also           { return [ 303, [ 'Location' => $_[1], 'Content-Length' => 0 ], [''] ] }
    sub redirect           { return [ 302, [ 'Location' => $_[1], 'Content-Length' => 0 ], [''] ] }
    sub redirect_permanent { return [ 301, [ 'Location' => $_[1], 'Content-Length' => 0 ], [''] ] }

    sub _reply     { return [ $_[1], [ 'Content-type' => 'text/html' ], [ defined $_[2] ? $_[2] : '' ] ] }
    sub ok         { return $_[0]->_reply( 200, $_[2] ) }
    sub notfound   { return $_[0]->_reply( 404, $_[2] // 'Not Found' ) }
    sub forbidden  { return $_[0]->_reply( 403, $_[2] // 'Forbidden' ) }
    sub badrequest { return $_[0]->_reply( 400, $_[2] // 'Bad Request' ) }
    sub error      { return $_[0]->_reply( 500, $_[2] // 'Error' ) }
    sub serve      { return [ 200, [], [''] ] }

    # These two must be inert.
    #
    # add_post_close_callback is the ONLY path by which Trog::Renderer and
    # post_save reach save_render()/invalidate_renders().  Dropping the callback
    # on the floor is what guarantees this test never writes into www/statics,
    # whatever the renderer's own skip-save logic decides.
    sub add_post_close_callback { $_[0]{callbacks}++; return 1 }

    # The real one is `kill 'HUP', getppid`.  Under prove, that is prove.
    sub signal_restart_parent { $_[0]{restarts}++; return 1 }

    sub invalidate_renders { push @{ $_[0]{invalidated} }, $_[1];              return 1 }
    sub invalidate_render  { push @{ $_[0]{invalidated} }, [ @_[ 1 .. $#_ ] ]; return 1 }
    sub save_render        { $_[0]{renders}{"$_[1]:$_[2]"} = $_[3]; return 1 }
}

our $TPSGI = Test::TPSGI->new();

our $ADMIN_USER    = 'specadmin';
our $ADMIN_DISPLAY = 'Spec Admin';
our $ADMIN_EMAIL   = 'specadmin@example.com';
our $ADMIN_PASS    = 'spec-password';

#--------------------------------------------------------------------------
# Harness
#--------------------------------------------------------------------------

# Always build a fresh query: posts() pushes onto user_acls, and series()
# rewrites route/aclname/tag/in_series/primary_post in place.
sub _query {
    my (%over) = @_;
    my %q = (
        route        => '/',
        method       => 'GET',
        scheme       => 'http',                             # Renderer::Base compares this with no undef guard
        domain       => 'tcms.test',
        start        => [ Time::HiRes::gettimeofday() ],    # tv_interval() dies on anything else
        deflate      => 0,
        streaming    => 0,
        ranges       => [],
        last_fetched => undef,
        has_query    => 0,
        social_meta  => 0,
        acls         => [],
        user_acls    => [],
        body         => undef,
        tpsgi        => $TPSGI,
        %over,
    );
    $q{fullpath} //= $q{route};
    return \%q;
}

sub _anon  { return _query( user => undef,       user_acls => [],        @_ ) }
sub _admin { return _query( user => $ADMIN_USER, user_acls => ['admin'], @_ ) }

# Returns ($code, $body, $error).  Never dies, so one bad post type cannot take
# the rest of the file with it -- which matters because a failed render inside
# index() dies rather than returning a 500 (there is no www/templates/html/500.tx).
sub _render {
    my ( $query, $how ) = @_;
    $how ||= \&Trog::Routes::HTML::index;

    my $res = eval { $how->($query) };
    return ( 0, '', "died: $@" )                                      if !$res;
    return ( 0, '', 'returned a ' . ( ref($res) || 'plain scalar' ) ) if ref $res ne 'ARRAY';

    my ( $code, $headers, $body ) = @$res;
    $body = ref $body eq 'ARRAY' ? join( '', @$body ) : ( $body // '' );
    return ( $code, Encode::decode_utf8($body), '', $headers );
}

# FlatFile snapshots the tag list at load time and then filters each query's
# tags against it IN PLACE -- so a tag created later isn't merely unindexed, it
# is deleted from the query, and the filter silently degrades to "every public
# post".  Production gets away with it because a save HUPs the parent and the
# worker re-execs.  We have to do it by hand.
#
# Nothing to do for a model that asks the database each time, which is the
# point: this helper exists to paper over a cache, and a model without one
# needs no paper.
sub _reindex {
    return unless $MODEL eq 'FlatFile';

    no warnings 'once';
    @Trog::Data::FlatFile::tags         = Trog::SQLite::TagIndex::tags();
    %Trog::Data::FlatFile::posts_by_tag = ();
    return;
}

sub _data { return Trog::Data->new( Trog::Config::get() ) }

# categories.tx renders into <span id="categories">.  Scope to it -- index.tx
# emits other class="topbar" anchors outside that span.
sub _topbar_titles {
    my ($body) = @_;
    my ($span) = $body =~ m{<span id="categories">(.*?)</span>}s;
    return () unless defined $span;
    return $span =~ m{class="topbar">([^<]*)</a>}g;
}

# post_title.tx emits exactly one of these per displayed post.
sub _post_count {
    my $n = () = $_[0] =~ m{<h3 class='blogtitles'>}g;
    return $n;
}

# The rendered page is ~40KB and mostly JavaScript.  Show the content well.
sub _kontent {
    my ($body) = @_;
    my ($k)    = $body =~ m{<div id="kontent" class="kontained">(.*?)<div id="rightbar"}s;
    $k //= $body;
    $k =~ s/<script\b.*?<\/script>//gs;
    return length($k) > 2500 ? substr( $k, 0, 2500 ) . "\n...[truncated]" : $k;
}

# Save through post_save() rather than $data->add(): add() dies with an
# arrayref of validator errors, whereas post_save catches them and hands back a
# 400 with the field-level detail in the body -- which is the single most
# useful thing to see when a fixture is wrong.
sub _save_post {
    my ( $label, %post ) = @_;
    my $to = delete $post{to};

    my $res = eval { Trog::Routes::HTML::post_save( _admin( route => '/post/save', method => 'POST', to => $to, %post ) ) };

    if ( !$res || ref $res ne 'ARRAY' ) {
        fail("$label: saved");
        diag( $@ || 'post_save returned nothing' );
        return undef;
    }

    my ( $code, $headers, $body ) = @$res;
    my %h = @{ $headers || [] };

    # Both outcomes redirect now, so the status alone proves nothing -- the
    # outcome is in the query string post_save hands to the destination.
    if ( $code != 303 || ( $h{Location} // '' ) =~ m/savefailed=/ ) {
        fail("$label: saved");
        diag( "post_save returned $code, Location: " . ( $h{Location} // '(none)' ) );
        diag( join( '', @{ $body || [''] } ) ) if $body && @$body;
        return undef;
    }
    pass("$label: saved");

    _reindex();    # mandatory: see the comment on _reindex

    my $saved = _find_post( $post{title} );
    ok( $saved, "$label: readable back out of the datastore" ) or return undef;
    return $saved;
}

sub _find_post {
    my ($title) = @_;

    # filter() short-circuits on title; the admin acl skips the visibility filter.
    my @posts = _data()->get( title => $title, acls => ['admin'], limit => 0 );
    return $posts[0];
}

#--------------------------------------------------------------------------

subtest 'the sandbox is what we are actually running against' => sub {
    is( Cwd::getcwd(), Cwd::abs_path($ROOT), 'cwd is the sandbox' );
    ok( -d 'data/files',         'datastore dir exists' );
    ok( -f 'config/default.cfg', 'config was seeded' );
    ok( !-f 'config/main.cfg',   'and there is no main.cfg, so we fall through to the default' );

    my $conf = Trog::Config::get();
    is( $conf->param('general.data_model'), $MODEL, 'config resolves inside the sandbox' );

    like( Trog::Themes::forms_dir(), qr/^www\/templates/, 'forms dir is relative, hence sandboxed' );
    ok( -d Cwd::abs_path( Trog::Themes::forms_dir() ), 'and it exists' );
    like( Cwd::abs_path( Trog::Themes::forms_dir() ), qr/^\Q$ROOT\E/, 'and it is under the sandbox, not the repo' );
};

subtest 'registering the first admin bootstraps the install' => sub {
    ok( !-f 'config/has_users', 'no users yet, so login() is in register mode' );

    my ( $code, $body, $err, $headers ) = _render(
        _anon(
            route         => '/login',
            method        => 'POST',
            username      => $ADMIN_USER,
            display_name  => $ADMIN_DISPLAY,
            contact_email => $ADMIN_EMAIL,
            password      => $ADMIN_PASS,
            to            => '/',
        ),
        \&Trog::Routes::HTML::login,
    );
    is( $code, 200, 'login() rendered' ) or diag($err);

    my %h = @{ $headers || [] };
    like( $h{'Set-Cookie'} // '', qr/^tcmslogin=[0-9a-f-]{36};/, 'a session cookie came back' );

    ok( -f 'config/has_users', 'registration is now closed' );
    is_deeply( Trog::Auth::acls4user($ADMIN_USER), ['admin'], 'the new user is an admin' );

    _reindex();

    my @seeded = _data()->get( acls => ['admin'], limit => 0 );
    is( scalar @seeded, 4, 'the four seed posts were written' )
      or diag( 'got: ' . join( ', ', map { "$_->{title} ($_->{form})" } @seeded ) );
};

subtest 'the post wizard invents a new post type' => sub {
    my %wizard = (
        name              => 'spec_widget',
        title_placeholder => 'Widget Name',
        body_form         => 'form_common.tx',
        wrapper           => 1,
        inc_post_title    => 1,
        inc_post_tags     => 1,
        inc_title_input   => 1,
        inc_visibility    => 1,
        inc_tags          => 1,
        inc_aliases       => 1,
        param_name        => ['flavor'],
        param_type        => ['text'],
        param_label       => ['Flavor'],
        param_placeholder => ['Strawberry'],
        param_required    => [0],
        display           => q{<div class="postData responsive-text" id="postData-<: $post.id :>">} . q{<span class="spec-flavor"><: $post.flavor :></span>} . q{<: render_it($post.data) | mark_raw :></div>},
    );

    my ( $code, $body, $err ) = _render(
        _admin( route => '/admin/wyzzerdd/save', method => 'POST', %wizard ),
        \&Trog::Routes::HTML::post_wizard_save,
    );
    is( $code, 200, 'wizard save rendered' ) or diag($err);

    ok( -f 'www/templates/html/components/forms/spec_widget.tx',   'the template was written' );
    ok( -f 'www/templates/html/components/forms/spec_widget.json', 'the schema sidecar was written' );
    like( $body, qr{<li>spec_widget\.tx</li>}, 'and the new type is listed back to us' );

    # This is the assertion that the sandbox is real: a symlinked template tree
    # would have put these in the developer's actual checkout.
    ok( !-e "$REPO/www/templates/html/components/forms/spec_widget.tx", 'nothing was written into the repo' );

    # The relation controls have to be present in every row and always submit,
    # or the parallel param_* arrays de-align server side.
    like( $body, qr/name="param_relation_form"/, 'the relation target select is in the row template' );
    like( $body, qr/name="param_relation_mode"/, 'so is the relation mode select' );
    like( $body, qr/<option value="relation">/,  'and relation is offered as a field type' );

    # A series can ask for its children to be tiled.  A generated type has to
    # carry that on its wrapper like the hand-written forms do, or it is the
    # one kind of post that silently ignores the setting.
    my $generated = Path::Tiny->new('www/templates/html/components/forms/spec_widget.tx')->slurp_utf8;

    # Single quoted: the wrapper is Kolon source, so every sigil in it is
    # literal and must not be interpolated by the test that checks for it.
    my $wrapper = q{<div class="post <: $style :> <: $tiled ? 'tile' : '' :>">};
    ok( index( $generated, $wrapper ) >= 0, 'the generated wrapper carries the tile class when the series asks for it' )
      or diag( "wanted: $wrapper\ngot:    " . ( split( /\n/, $generated ) )[1] );

    # Every post has a title, a visibility and acls.  The wizard used to let a
    # type opt out of collecting them, which is how a hypervisor post ended up
    # stored with no visibility and an undef in its tags.
    foreach my $required ( 'visibility.tx', 'acls.tx' ) {
        like( $generated, qr/\Q: include "$required";\E/, "$required is included whether or not it was asked for" );
    }
    like( $generated, qr/name="title"/, 'and so is the title input' );

    foreach my $gone (qw{inc_title_input inc_visibility inc_acls}) {
        unlike( $body, qr/name="\Q$gone\E"/, "the wizard no longer offers '$gone' as a choice" );
    }

    like( $body, qr/name="param_private"/,   'and it offers per-field privacy' );
    like( $body, qr/name="datasource"/,      'and a datasource to draw the posts from' );
    like( $body, qr/Trog::DataSource::Virt/, 'listing the ones that exist' );
};

subtest 'a datasource-backed type gets no editor' => sub {

    # A datasource whose posts are built rather than written has nothing behind
    # a form to save, so generating one would produce an editor that writes
    # real posts to sit alongside the synthesized ones.
    my ( $code, $body, $err ) = _render(
        _admin(
            route          => '/admin/wyzzerdd/save',
            method         => 'POST',
            name           => 'spec_sourced',
            datasource     => 'Trog::DataSource::Virt',
            body_form      => 'form_common.tx',
            wrapper        => 1,
            inc_post_title => 1,
            display        => q{<div class="s"><: $post.title :></div>},
        ),
        \&Trog::Routes::HTML::post_wizard_save,
    );
    is( $code, 200, 'the type was created' ) or diag($err);

    my $generated = Path::Tiny->new('www/templates/html/components/forms/spec_sourced.tx')->slurp_utf8;
    unlike( $generated, qr{action="/post/save"}, 'no editor was generated' );
    unlike( $generated, qr/\$can_edit/,          'and nothing guards one' );
    like( $generated, qr/class="s"/, 'but the display half is there' );

    my $sidecar = JSON::MaybeXS::decode_json( Path::Tiny->new('www/templates/html/components/forms/spec_sourced.json')->slurp_utf8 );
    is( $sidecar->{'x-tcms-datasource'}, 'Trog::DataSource::Virt', 'and the sidecar records the datasource' );

    # The same type without one keeps its editor.
    _render(
        _admin(
            route          => '/admin/wyzzerdd/save',
            method         => 'POST',
            name           => 'spec_stored',
            body_form      => 'form_common.tx',
            wrapper        => 1,
            inc_post_title => 1,
            display        => q{<div class="s"><: $post.title :></div>},
        ),
        \&Trog::Routes::HTML::post_wizard_save,
    );
    my $stored = Path::Tiny->new('www/templates/html/components/forms/spec_stored.tx')->slurp_utf8;
    like( $stored, qr{action="/post/save"}, 'a type on the datastore still gets one' );

    # The name is require()d later, so it has to be one we found.
    ( $code, $body ) = _render(
        _admin( route => '/admin/wyzzerdd/save', method => 'POST', name => 'spec_bogus', datasource => 'Evil::Module' ),
        \&Trog::Routes::HTML::post_wizard_save,
    );
    like( $body, qr/not a datasource I can find/, 'a datasource we did not find is refused' );
    ok( !-e 'www/templates/html/components/forms/spec_bogus.tx', 'and nothing was written' );
};

subtest 'a field can be declared editors-only' => sub {
    my ( $code, $body, $err ) = _render(
        _admin(
            route               => '/admin/wyzzerdd/save',
            method              => 'POST',
            name                => 'spec_secretive',
            body_form           => 'form_common.tx',
            wrapper             => 1,
            inc_post_title      => 1,
            inc_tags            => 1,
            param_name          => [ 'shown',   'hidden' ],
            param_type          => [ 'text',    'text' ],
            param_label         => [ 'Shown',   'Hidden' ],
            param_placeholder   => [ '',        '' ],
            param_required      => [ 0,         0 ],
            param_private       => [ 0,         1 ],
            param_relation_form => [ 'blog.tx', 'blog.tx' ],
            param_relation_mode => [ 'one',     'one' ],

            # Deliberately unguarded: declaring the field private is supposed
            # to be enough, so an author does not have to remember.
            display => q{<div class="s"><: $post.shown :></div><div class="h"><: $post.hidden :></div>},
        ),
        \&Trog::Routes::HTML::post_wizard_save,
    );
    is( $code, 200, 'the type was created' ) or diag($err);

    my $sidecar = JSON::MaybeXS::decode_json( Path::Tiny->new('www/templates/html/components/forms/spec_secretive.json')->slurp_utf8 );
    ok( $sidecar->{properties}{hidden}{'x-tcms-private'},        'the private field is marked so' );
    ok( !exists $sidecar->{properties}{shown}{'x-tcms-private'}, 'and a public one carries no flag at all' );

    _reindex();

    _make_series( 'spec_secretive', 'specsecretive', 'spec_secretive.tx', 'Spec Secretive Series', no_topbar => 1 ) or return;
    my $child = _save_post(
        'spec_secretive child',
        form       => 'spec_secretive.tx',
        title      => 'Spec Secretive Child',
        shown      => 'public value',
        hidden     => 'private value',
        visibility => 'public',
        tags       => ['specsecretive'],
        to         => '/specsecretive',
    ) or return;

    is( $child->{hidden}, 'private value', 'the value is stored like any other' );

    # An editor sees both.
    my ( $acode, $abody ) = _render( _admin( route => '/specsecretive' ), \&Trog::Routes::HTML::series );
    is( $acode, 200, 'the series renders for an admin' );
    like( $abody, qr{<div class="h">private value</div>}, 'who sees the private field' );

    # A logged out reader sees only the public one, without the template
    # having guarded anything.
    my ( $ncode, $nbody ) = _render( _anon( route => '/specsecretive' ), \&Trog::Routes::HTML::series );
    is( $ncode, 200, 'and for everyone else' );
    like( $nbody, qr{<div class="s">public value</div>}, 'who still sees the public field' );
    unlike( $nbody, qr/private value/, 'but not the private one' );
};

#--------------------------------------------------------------------------
# The matrix.
#
# Per type: build a topbar series whose child_form is that type, check it shows
# up in the nav, add a child post, check the child renders on the series page.
#
# Everything is verified ANONYMOUSLY.  can_edit is then false, so the editor
# half of each form never renders and a title appears exactly once -- which is
# what makes like($body, qr/$title/) mean anything.  It also sidesteps the
# /secure prefixing that both _post_helper and categories.tx apply when a user
# is set.
#--------------------------------------------------------------------------

sub _make_series {
    my ( $label, $aclname, $child_form, $title, %opt ) = @_;

    # _get_series caps the bar at 10 and the seeds already use two, so only the
    # series whose topbar behaviour we actually care about get tagged.
    my @tags = $opt{no_topbar} ? ('series') : ( 'series', 'topbar' );

    my $series = _save_post(
        "$label series",
        form       => 'series.tx',
        title      => $title,
        aclname    => $aclname,                       # required by series.json
        child_form => $child_form,                    # required by series.json
        local_href => "/$aclname",
        href       => "/$aclname",
        data       => "$title subhead",
        callback   => 'Trog::Routes::HTML::series',
        visibility => 'public',
        tags       => \@tags,
        tiled      => 0,
        to         => '/',
    ) or return undef;

    return $series if $opt{no_topbar};

    # The topbar comes from _get_series(), which index() renders through
    # categories.tx.  Check it on / -- the series has no children yet, and
    # posts() 404s on an empty series.
    my ( $code, $body, $err ) = _render( _anon( route => '/' ) );
    is( $code, 200, "$label: / renders" ) or diag($err);

    my @titles = _topbar_titles($body);
    ok( ( grep { $_ eq $title } @titles ), "$label: series is in the topbar" )
      or diag( 'topbar was: ' . join( ', ', @titles ) );

    return $series;
}

sub _series_page {
    my ( $label, $aclname, $series_title, $expected_posts ) = @_;

    my ( $code, $body, $err ) = _render( _anon( route => "/$aclname" ), \&Trog::Routes::HTML::series );
    is( $code, 200, "$label: series page renders" ) or do { diag($err); return '' };

    like( $body, qr{<title>[^<]*\Q$series_title\E}, "$label: series page is the right series" );
    is( _post_count($body), $expected_posts, "$label: exactly $expected_posts post(s) listed" )
      or diag( _kontent($body) );

    return $body;
}

# Entities first: the invoice type resolves payee/payor against existing public
# entities.tx posts, so those have to be in the datastore before we get there.
our ( $PAYEE, $PAYOR );

subtest 'entities' => sub {
    my $title = 'Spec Entities Series';
    _make_series( 'entities', 'specentities', 'entities.tx', $title ) or return;

    $PAYEE = _save_post(
        'entities payee child',
        form            => 'entities.tx',
        title           => 'Spec Payee Entity',
        data            => 'Acme Payments LLC, 1 Road, Metropolis',
        payment_method  => 'ACH',
        payment_details => 'Routing 0000 Account 1111',
        visibility      => 'public',
        tags            => ['specentities'],
        to              => '/specentities',
    ) or return;

    $PAYOR = _save_post(
        'entities payor child',
        form            => 'entities.tx',
        title           => 'Spec Payor Entity',
        data            => 'Wile E Coyote, PO Box 9',
        payment_method  => 'Carrier Pigeon',
        payment_details => 'none',
        visibility      => 'public',
        tags            => ['specentities'],
        to              => '/specentities',
    ) or return;

    my $body = _series_page( 'entities', 'specentities', $title, 2 ) or return;

    like( $body, qr{id="postData-\Q$PAYEE->{id}\E"}, 'payee body rendered' );
    like( $body, qr/Acme Payments LLC/,              'payee data rendered' );
    like( $body, qr/Wile E Coyote/,                  'payor data rendered' );

    # entity_details.tx is included only in the editor half, so these are stored
    # but never displayed.  Pinning that so a template change is noticed.
    unlike( $body, qr/Carrier Pigeon/, 'payment details are not shown to anonymous readers' );
    is( _find_post('Spec Payee Entity')->{payment_method}, 'ACH', 'but payment_method did survive the schema' );
};

subtest 'blog' => sub {
    my $title = 'Spec Blog Series';
    _make_series( 'blog', 'specblog', 'blog.tx', $title ) or return;

    my $child = _save_post(
        'blog child',
        form       => 'blog.tx',
        title      => 'Spec Blog Child',
        data       => 'Spec blog body text.',
        visibility => 'public',
        tags       => ['specblog'],
        to         => '/specblog',
    ) or return;

    my $body = _series_page( 'blog', 'specblog', $title, 1 ) or return;

    like( $body, qr/Spec Blog Child/,                'child title rendered' );
    like( $body, qr{href='/posts/\Q$child->{id}\E'}, 'child permalink rendered' );
    like( $body, qr{id="postData-\Q$child->{id}\E"}, 'child body block rendered' );
    like( $body, qr/Spec blog body text\./,          'child body text rendered' );
    unlike( $body, qr/Spec Payee Entity/, 'no bleed from the entities series' );
};

subtest 'microblog' => sub {
    my $title = 'Spec Microblog Series';
    _make_series( 'microblog', 'specmicroblog', 'microblog.tx', $title ) or return;

    my $child = _save_post(
        'microblog child',
        form       => 'microblog.tx',
        title      => 'Spec Microblog Child',
        href       => 'https://example.com/spec',
        data       => 'Spec microblog body.',
        visibility => 'public',
        tags       => ['specmicroblog'],
        to         => '/specmicroblog',
    ) or return;

    my $body = _series_page( 'microblog', 'specmicroblog', $title, 1 ) or return;

    like( $body, qr{href='https://example\.com/spec' >Spec Microblog Child</a>}, 'title links out to href' );
    like( $body, qr{id="postData-\Q$child->{id}\E"},                             'body block rendered' );
    like( $body, qr/Spec microblog body\./,                                      'body text rendered' );
};

subtest 'file' => sub {
    my $title = 'Spec File Series';
    _make_series( 'file', 'specfile', 'file.tx', $title ) or return;

    # _handle_upload MOVES the file, so it has to be created fresh here.
    my $src = "$ROOT/upload-src/spec-upload.txt";
    open( my $fh, '>', $src ) or die $!;
    print {$fh} "spec upload contents\n";
    close $fh;

    my $child = _save_post(
        'file child',
        form       => 'file.tx',
        title      => 'Spec File Child',
        data       => 'Spec file body.',
        file       => { tempname => $src, filename => 'spec-upload.txt' },
        visibility => 'public',
        tags       => ['specfile'],
        to         => '/specfile',
    ) or return;

    ok( !-e $src,                                     'the upload was moved out of its temp location, not copied' );
    ok( -f "www/assets/$child->{id}.spec-upload.txt", 'and it landed in www/assets' );

    my $body = _series_page( 'file', 'specfile', $title, 1 ) or return;

    like( $body, qr{href='/assets/\Q$child->{id}\E\.spec-upload\.txt'}, 'title links to the asset' );
    like( $body, qr{id="postData-\Q$child->{id}\E"},                    'body block carries a unique id, like every other form' );
    like( $body, qr/Spec file body\./,                                  'body text rendered' );

    # This form used to emit <div class="postData" id="postData" class="responsive-text">
    # -- a duplicated class attribute, and an id shared by every file post on
    # the page.  Neither should come back.
    unlike( $body, qr{<div class="postData" id="postData"}, 'no duplicated class attribute' );

    # text/plain, so none of the media branches fire.
    unlike( $body, qr/<video/, 'no video block for a text file' );
    unlike( $body, qr/<audio/, 'no audio block either' );
};

subtest 'presentation' => sub {
    my $title = 'Spec Presentation Series';
    _make_series( 'presentation', 'specpresentation', 'presentation.tx', $title ) or return;

    my $child = _save_post(
        'presentation child',
        form          => 'presentation.tx',
        title         => 'Spec Presentation Child',
        data          => [ 'Slide one body.', 'Slide two body.' ],
        data_is_array => 1,
        visibility    => 'public',
        tags          => ['specpresentation'],
        to            => '/specpresentation',
    ) or return;

    is_deeply( $child->{data}, [ 'Slide one body.', 'Slide two body.' ], 'the multi-page data round-tripped as an array' );

    my $body = _series_page( 'presentation', 'specpresentation', $title, 1 ) or return;

    # Slides only render under nochrome; the series page just links to the deck.
    like( $body, qr{<a href="/posts/\Q$child->{id}\E\?embed=1&nochrome=1">Click Here to view</a>}, 'deck link rendered' );
    unlike( $body, qr/Slide one body\./, 'slides themselves are not rendered inline' );
};

subtest 'invoice' => sub {
    my $title = 'Spec Invoice Series';
    _make_series( 'invoice', 'specinvoice', 'invoice.tx', $title ) or return;

    my $child = _save_post(
        'invoice child',
        form          => 'invoice.tx',
        title         => 'Spec Invoice Child',
        data          => [ "Widget assembly\nPrice: \$420", "Shipping\nPrice: \$80" ],
        data_is_array => 1,
        payee         => $PAYEE->{id},
        payor         => $PAYOR->{id},
        due_days      => 30,
        visibility    => 'public',
        tags          => ['specinvoice'],
        to            => '/specinvoice',
    ) or return;

    my $body = _series_page( 'invoice', 'specinvoice', $title, 1 ) or return;

    like( $body, qr/Invoice ID# \Q$child->{id}\E/, 'invoice header rendered' );

    # These two only resolve because the entities subtest ran first and left
    # public entities.tx posts behind for the enrich hook to find.
    like( $body, qr/Acme Payments LLC/, 'payee entity resolved' );
    like( $body, qr/Wile E Coyote/,     'payor entity resolved' );
    like( $body, qr/ACH/,               'payee payment method pulled through' );

    like( $body, qr/Widget assembly/, 'line items rendered' );
    like( $body, qr/Total: \$500/,    'total summed from the line item prices' );
};

subtest 'spec_widget (the wizard-built type)' => sub {
    my $title = 'Spec Widget Series';
    _make_series( 'spec_widget', 'specwidget', 'spec_widget.tx', $title ) or return;

    my $child = _save_post(
        'spec_widget child',
        form        => 'spec_widget.tx',
        title       => 'Spec Widget Child',
        data        => 'Spec widget body.',
        flavor      => 'Strawberry',
        bogus_field => 'nope',
        visibility  => 'public',
        tags        => ['specwidget'],
        to          => '/specwidget',
    ) or return;

    is( $child->{flavor}, 'Strawberry', 'the custom field survived validation' );
    ok( !exists $child->{bogus_field}, 'an undeclared field was still stripped' );

    my $body = _series_page( 'spec_widget', 'specwidget', $title, 1 ) or return;

    # The payoff: this can only render if the wizard wrote spec_widget.json,
    # schema_for merged it over the base post schema, and validate() therefore
    # kept 'flavor' instead of deleting it as an unknown key.
    like( $body, qr{<span class="spec-flavor">Strawberry</span>}, 'the custom field rendered on the page' );
    like( $body, qr/Spec widget body\./,                          'and the body came through the generated template' );
};

subtest 'a wizard-built type can depend on another type' => sub {

    # The type we will point at.  The relation is what is under test, so keep
    # the target itself boring.
    my ( $code, $body, $err ) = _render(
        _admin(
            route           => '/admin/wyzzerdd/save',
            method          => 'POST',
            name            => 'spec_target',
            body_form       => 'form_common.tx',
            wrapper         => 1,
            inc_post_title  => 1,
            inc_title_input => 1,
            inc_visibility  => 1,
            inc_tags        => 1,
            display         => q{<div><: render_it($post.data) | mark_raw :></div>},
        ),
        \&Trog::Routes::HTML::post_wizard_save,
    );
    is( $code, 200, 'target type created' ) or diag($err);

    # ...and the type that depends on it: one picked by id, one pulling in the
    # whole set.
    ( $code, $body, $err ) = _render(
        _admin(
            route               => '/admin/wyzzerdd/save',
            method              => 'POST',
            name                => 'spec_relator',
            body_form           => 'form_common.tx',
            wrapper             => 1,
            inc_post_title      => 1,
            inc_title_input     => 1,
            inc_visibility      => 1,
            inc_tags            => 1,
            param_name          => [ 'chosen',         'everything' ],
            param_type          => [ 'relation',       'relation' ],
            param_label         => [ 'Chosen One',     'All Of Them' ],
            param_placeholder   => [ '',               '' ],
            param_required      => [ 0,                0 ],
            param_relation_form => [ 'spec_target.tx', 'spec_target.tx' ],
            param_relation_mode => [ 'one',            'all' ],
            display             => q{<div class="rel"><span class="chosen"><: $post.chosen_post.title :></span>} . q{<: for $post.everything -> $t { :><span class="each"><: $t.title :></span><: } :></div>},
        ),
        \&Trog::Routes::HTML::post_wizard_save,
    );
    is( $code, 200, 'relating type created' ) or diag($err);

    my $sidecar = JSON::MaybeXS::decode_json( Path::Tiny->new('www/templates/html/components/forms/spec_relator.json')->slurp_utf8 );

    # 'one' is a field the post stores; 'all' is not a field at all.
    is( $sidecar->{properties}{chosen}{type},                   'relation',       'the picked relation is a stored property' );
    is( $sidecar->{properties}{chosen}{'x-tcms-relation-form'}, 'spec_target.tx', 'naming its target type' );
    ok( !exists $sidecar->{properties}{everything}, "the 'all' relation stores nothing" );

    is_deeply(
        $sidecar->{'x-tcms-relations'},
        {
            chosen_post => { form => 'spec_target.tx', from => 'chosen' },
            everything  => { form => 'spec_target.tx' },
        },
        'and both are declared for resolution at render'
    );

    # The relation pseudo-type has to become a real one before validation, or
    # every relation field would be stripped as an unknown type.
    is(
        Trog::DataModule::schema_for('spec_relator.tx')->{properties}{chosen}{type},
        'string', "'relation' expands to a real schema type"
    );

    _reindex();

    # Now exercise it end to end.
    _make_series( 'spec_target', 'spectarget', 'spec_target.tx', 'Spec Target Series', no_topbar => 1 ) or return;
    my $target = _save_post(
        'spec_target child',
        form       => 'spec_target.tx',
        title      => 'Spec Target Post',
        data       => 'Spec target body.',
        visibility => 'public',
        tags       => ['spectarget'],
        to         => '/spectarget',
    ) or return;

    _make_series( 'spec_relator', 'specrelator', 'spec_relator.tx', 'Spec Relator Series', no_topbar => 1 ) or return;
    my $relator = _save_post(
        'spec_relator child',
        form       => 'spec_relator.tx',
        title      => 'Spec Relator Post',
        data       => 'Spec relator body.',
        chosen     => $target->{id},
        visibility => 'public',
        tags       => ['specrelator'],
        to         => '/specrelator',
    ) or return;

    is( $relator->{chosen}, $target->{id}, 'the referenced id survived validation' );

    my $page = _series_page( 'spec_relator', 'specrelator', 'Spec Relator Series', 1 ) or return;

    # Both halves of the relation resolved: the one we picked, and the set.
    like( $page, qr{<span class="chosen">Spec Target Post</span>}, 'the picked post resolved into the page' );
    like( $page, qr{<span class="each">Spec Target Post</span>},   'and so did the whole set' );
};

subtest '/api/posts_of_form feeds the relation picker' => sub {
    my $target = _find_post('Spec Target Post');
    ok( $target, 'the target post is there to be listed' ) or return;

    my $res = Trog::Routes::JSON::posts_of_form( _admin( route => '/api/posts_of_form', form => 'spec_target.tx' ) );
    is( ref $res, 'ARRAY', 'a PSGI response came back' ) or return;

    my ( $code, undef, $body ) = @$res;
    is( $code, 200, 'and it is a 200' );

    my $payload = JSON::MaybeXS::decode_json( join( '', @$body ) );
    is_deeply(
        $payload->{posts},
        [ { id => $target->{id}, title => 'Spec Target Post' } ],
        'listing exactly the posts of that type, id and title only'
    );

    # An unknown type is an empty list, not an error -- a type with no posts
    # yet is the normal state of affairs right after you create it.
    $res     = Trog::Routes::JSON::posts_of_form( _admin( route => '/api/posts_of_form', form => 'nosuchtype.tx' ) );
    $payload = JSON::MaybeXS::decode_json( join( '', @{ $res->[2] } ) );
    is_deeply( $payload->{posts}, [], 'an unknown type lists nothing rather than failing' );

    # The route's own declaration is what keeps a malformed form out; check it
    # matches what series.json demands of child_form.
    my $validator = $Trog::Routes::JSON::routes{'/api/posts_of_form'}{parameters}{form};
    ok( $validator->('blog.tx'),                                 'the parameter validator accepts a form name' );
    ok( !$validator->('../../etc/passwd'),                       'and rejects a path' );
    ok( $Trog::Routes::JSON::routes{'/api/posts_of_form'}{auth}, 'the route requires a login' );
};

subtest 'a series resolves its relations for logged out visitors too' => sub {

    # The relations series() resolves land on the primary post, which is what a
    # datasource reads to find its hypervisors -- so assert on that rather than
    # on the rendered children, whose relations posts() resolves later, after
    # it has widened user_acls and thus by a path that was never broken.
    foreach my $case ( [ 'anonymously', _anon( route => '/specrelator' ) ], [ 'as an admin', _admin( route => '/specrelator' ) ] ) {
        my ( $label, $query ) = @$case;

        my ( $code, undef, $err ) = _render( $query, \&Trog::Routes::HTML::series );
        is( $code, 200, "the series renders $label" ) or do { diag($err); next };

        my $resolved = $query->{primary_post}{everything};
        is( ref $resolved, 'ARRAY', "$label, the series' own relation resolved" );
        cmp_ok( scalar @{ $resolved || [] }, '>', 0, "$label, to something rather than nothing" );
    }
};

subtest 'saves report back through the jsalert banner' => sub {

    # A good save redirects to where you came from, carrying the outcome.
    my $res = Trog::Routes::HTML::post_save(
        _admin(
            route      => '/post/save',
            method     => 'POST',
            to         => '/specblog',
            form       => 'blog.tx',
            title      => 'Spec Feedback Child',
            data       => 'Spec feedback body.',
            visibility => 'public',
            tags       => ['specblog'],
        )
    );
    my ( $code, $headers ) = @$res;
    my %h = @{ $headers || [] };
    is( $code, 303, 'a good save redirects' );
    like( $h{Location}, qr{^/secure/specblog\?saved=}, 'to where we came from, flagged as saved' );
    unlike( $h{Location}, qr/\n/, 'and the message is one line, since it lands in a JS string' );

    _reindex();

    # Follow the redirect the way a browser would.
    my ($qs) = $h{Location} =~ m/\?(.*)$/;
    my %params = map { my ( $k, $v ) = split( /=/, $_, 2 ); ( $k => URI::Escape::uri_unescape($v) ) } split( /&/, $qs );

    my ( $rcode, $body, $err ) = _render(
        _admin( route => '/specblog', has_query => 1, %params ),
        \&Trog::Routes::HTML::series,
    );
    is( $rcode, 200, 'the destination renders' ) or diag($err);
    like( $body, qr/var loginFailure = 0;/,                      'the banner is in success mode' );
    like( $body, qr/Saved post &#39;Spec Feedback Child&#39;\./, 'and says what was saved' );

    # Nothing to navigate on to, so the banner must not bounce us anywhere.
    unlike( $body, qr/window\.location=/, 'and does not redirect onwards' );

    # A rejected save comes back the same way, in red.
    $res = Trog::Routes::HTML::post_save(
        _admin(
            route      => '/post/save',
            method     => 'POST',
            to         => '/specblog',
            form       => 'blog.tx',
            title      => 'Spec Rejected Child',
            visibility => 'not-a-visibility',
            tags       => ['specblog'],
        )
    );
    ( $code, $headers ) = @$res;
    %h = @{ $headers || [] };
    is( $code, 303, 'a rejected save redirects too, rather than dead-ending on a 400' );
    like( $h{Location},                              qr{^/secure/specblog\?savefailed=}, 'flagged as failed' );
    like( URI::Escape::uri_unescape( $h{Location} ), qr/Not in enum list/,               'carrying the validator error' );

    ok( !_find_post('Spec Rejected Child'), 'and the bad post was not written' );

    ($qs) = $h{Location} =~ m/\?(.*)$/;
    %params = map { my ( $k, $v ) = split( /=/, $_, 2 ); ( $k => URI::Escape::uri_unescape($v) ) } split( /&/, $qs );

    ( $rcode, $body, $err ) = _render(
        _admin( route => '/specblog', has_query => 1, %params ),
        \&Trog::Routes::HTML::series,
    );
    is( $rcode, 200, 'the destination still renders' ) or diag($err);
    like( $body, qr/var loginFailure = 1;/, 'the banner is in failure mode' );
    like( $body, qr/Not in enum list/,      'and shows why' );
};

subtest 'the topbar did not silently overflow' => sub {
    my ( $code, $body, $err ) = _render( _anon( route => '/' ) );
    is( $code, 200, '/ renders' ) or diag($err);

    my @titles = _topbar_titles($body);

    # 2 seeded series (Series, About) + the 7 we built.  _get_series() caps at
    # 10 (HTML.pm), so an eighth post type would start silently dropping one.
    is( scalar @titles, 9, 'every series we made is in the topbar' )
      or diag( 'topbar was: ' . join( ', ', @titles ) );
    cmp_ok( scalar @titles, '<=', 10, 'and we are not at the _get_series limit' );
};

subtest 'the tpsgi side effects stayed inert' => sub {
    cmp_ok( $TPSGI->{restarts},  '>', 0, 'post_save did try to signal a restart' );
    cmp_ok( $TPSGI->{callbacks}, '>', 0, 'and did queue post-close callbacks' );

    # We never run the queued callbacks, which is what keeps save_render and
    # invalidate_renders from ever firing.
    is_deeply( $TPSGI->{renders},     {}, 'no static renders were written' );
    is_deeply( $TPSGI->{invalidated}, [], 'and nothing was invalidated' );

    my @statics = glob('www/statics/*');
    is_deeply( \@statics, [], 'www/statics is empty' );
};

subtest 'the real repo was not touched' => sub {
    my %after = map { _snapshot("$REPO/$_") } qw{config data www/templates www/assets logs totp};

    my @changed = grep { ( $REPO_BEFORE{$_} // '' ) ne ( $after{$_} // '' ) } keys %after;
    my @removed = grep { !exists $after{$_} } keys %REPO_BEFORE;

    is_deeply( [ sort @changed ], [], 'no repo file was added or modified' );
    is_deeply( [ sort @removed ], [], 'and none were removed' );
    ok( !-e "$REPO/www/templates/html/components/forms/spec_widget.tx", 'the wizard type is not in the repo' );
};

done_testing();
