package Trog::DataSource::DirIndex;

use v5.36;
use re '/aa';

use Cwd            ();
use Digest::SHA    qw{sha256_hex};
use File::Basename ();
use URI::Escape    ();

use Trog::DataSource ();
use Trog::Utils      ();

use Trog::Log qw{WARN DEBUG};

=head1 Trog::DataSource::DirIndex

Builds posts out of the contents of a directory.

A series says which directory in its C<directory> field, and its children become
one post per entry: a file listing, a download page, a gallery, whatever the post
type's template makes of it.  Nothing is written to the datastore -- the
directory is the source of truth, and the posts are rebuilt from it on every
view.

    "x-tcms-datasource": "Trog::DataSource::DirIndex"

Build the child type in the Post Type Wizard and pick this as its datasource.
The fields each entry carries are listed under posts() below; a template can use
any of them.

=head2 EDITABLE

False.  An entry is built from the filesystem every time the page is drawn and
has nothing behind it to save, so a post type backed by this wants no editor:
a form posting to /post/save would write a real post to sit alongside, and
collide with, the synthesized ones.  Put files in the directory instead.

=cut

use constant EDITABLE => 0;

=head1 WHAT MAY BE INDEXED

Only directories under C<www/>, and never C<www/assets/private>.

That is not arbitrary caution.  Everything under www/ is already served to
anybody who asks, so listing it discloses nothing that a guessed URL would not --
whereas a listing of anywhere else hands out the names of files the webserver
would refuse to serve, and names are frequently the interesting part.

=head2 A NOTE ON www/assets/private

The refusal is a guard rail against an operator mistake, and not the thing that
makes private assets private.

Private uploads live under www/assets/private, and on a correctly provisioned
site nginx is what protects them: it auth_requests the /authenticated route,
which answers 200 for a request carrying a live session and 403 for one that
isn't, and serves the file or refuses it accordingly.  That is the entire reason
that route exists.  So pointing a listing at that directory does not hand the
files out -- a reader who follows one of the links still gets asked to log in.

What it would hand out is the names, which the site owner probably did not mean
to publish either, and which nothing else would stop.  Sharing that directory is
operator error; refusing it here is cheap, and turns a mistake made in a text
field into an error in the log rather than a disclosure nobody notices.  If you
genuinely want to publish a listing of it, put the files somewhere public instead
-- that is what the distinction between the two directories is for.

None of this holds if the site is served without that nginx configuration.  See
the nginxproxy recipe referenced in the Readme; several features besides this one
assume it.

=head2 SYMLINKS

Resolved before the containment check, so entries pointing outside the tree are
left out of the listing rather than shown with a link that will not work.

=cut

our $root    = 'www';
our @refused = ('www/assets/private');

=head1 FUNCTIONS

=head2 posts($series, $query) = @posts

One post per entry in the series' directory.

Each carries, beyond what every post has:

    name        the entry's own name, as on disk
    path        its path relative to www/
    is_dir      whether it is a directory
    size        bytes, 0 for a directory
    size_human  the same, as a human reads it
    mtime       last modification, which is also the post's created
    extension   lowercased, without the dot, empty for a directory
    is_image / is_video / is_audio    from the content type, as a stored post gets

Registers an inotify watch on the directory the first time it is asked, so that
the static render of this page is thrown away when the directory changes.  See
_watch().

=cut

sub posts ( $series, $query ) {
    my $dir = _resolve( $series->{directory} );
    return () unless $dir;

    _watch( $query, $dir->{relative} );

    opendir( my $dh, $dir->{absolute} ) or do {
        WARN("Could not read $dir->{relative}: $!");
        return ();
    };
    my @entries = grep { $_ ne '.' && $_ ne '..' && index( $_, '.' ) != 0 } readdir($dh);
    closedir($dh);

    my @out;
    foreach my $entry ( sort @entries ) {
        my $post = _post_for( $entry, $dir, $series );
        push( @out, $post ) if $post;
    }

    return @out;
}

# Everything this is allowed to look at, or nothing.  Returns the absolute path
# and the path relative to the tCMS root, since the first is what we read and
# the second is what we log and watch.
sub _resolve ($directory) {
    return undef unless defined $directory && length $directory;

    # Before abs_path, which would happily resolve one for us.
    if ( $directory =~ m{(?:^|/)\.\.(?:/|$)} ) {
        WARN("Refusing to index '$directory': it walks upwards");
        return undef;
    }

    my $base = Cwd::abs_path($root);
    if ( !$base ) {
        WARN("Refusing to index '$directory': there is no $root here to index under");
        return undef;
    }

    # Relative to the tCMS root, and named with or without the www/ prefix --
    # 'assets/pics' and 'www/assets/pics' are the same directory, and somebody
    # writing it into a form will pick whichever occurs to them.
    my $candidate = $directory;
    $candidate = "$root/$candidate" unless $candidate =~ m{^\Q$root\E(?:/|$)};

    my $absolute = Cwd::abs_path($candidate);
    if ( !$absolute || !-d $absolute ) {
        WARN("Refusing to index '$directory': it is not a directory here");
        return undef;
    }

    if ( !_within( $absolute, $base ) ) {
        WARN("Refusing to index '$directory': it resolves outside $root");
        return undef;
    }

    foreach my $refused (@refused) {
        my $forbidden = Cwd::abs_path($refused);
        next unless $forbidden;
        next unless _within( $absolute, $forbidden );

        WARN("Refusing to index '$directory': $refused holds files the webserver gates, so its names are gated too");
        return undef;
    }

    my $relative = $absolute;
    $relative =~ s{^\Q$base\E/?}{};

    return { absolute => $absolute, relative => length($relative) ? "$root/$relative" : $root };
}

# Path containment, done on the resolved paths rather than on the strings the
# caller handed us: /www-backup is not inside /www, however it reads.
sub _within ( $path, $within ) {
    return 1 if $path eq $within;
    return index( $path, "$within/" ) == 0;
}

sub _post_for ( $name, $dir, $series ) {
    my $absolute = "$dir->{absolute}/$name";

    # Resolved, so a symlink pointing out of the tree is left out rather than
    # listed with a link the webserver will not honour.
    my $real = Cwd::abs_path($absolute);
    if ( !$real || !_within( $real, Cwd::abs_path($root) ) ) {
        DEBUG("Skipping $name: it points outside $root");
        return undef;
    }

    my @stat = stat($absolute);
    return undef unless @stat;

    my $is_dir = -d _    ? 1 : 0;
    my $size   = $is_dir ? 0 : $stat[7];
    my $mtime  = $stat[9];

    # Relative to www/, which is also its URL.
    my $path = "$dir->{relative}/$name";
    $path =~ s{^\Q$root\E/?}{};

    my ($extension) = $is_dir ? ('') : ( lc( $name =~ m/\.([^.]+)$/ ? $1 : '' ) );

    my $content_type = $is_dir ? 'inode/directory' : ( Trog::Utils::mime_type($absolute) // 'application/octet-stream' );

    # Escaped per segment: a filename may legally hold a space, a question mark
    # or a hash, and none of those survive being dropped into an href as they
    # are.  Per segment rather than wholesale, or the separators go too.
    my $href = '/' . join( '/', map { URI::Escape::uri_escape($_) } split( '/', $path ) );

    my $post = {

        # Stable across renders, because pagination and page anchors need it to
        # be, and opaque because a filename is not a thing to put in a URL.
        id => 'dirindex-' . substr( sha256_hex($path), 0, 32 ),

        title => $name,
        name  => $name,
        path  => $path,
        data  => '',

        # Which template renders it.  posts.tx dispatches on this, so without it
        # the entries come out through the default form rather than the type the
        # series named, and the page looks empty.
        form => $series->{child_form},

        is_dir     => $is_dir,
        size       => $size,
        size_human => _human_size($size),
        mtime      => $mtime,
        extension  => $extension,

        content_type => $content_type,
        is_image     => ( $content_type =~ m{^image/} ? 1 : 0 ),
        is_video     => ( $content_type =~ m{^video/} ? 1 : 0 ),
        is_audio     => ( $content_type =~ m{^audio/} ? 1 : 0 ),

        # Where the thing actually is.  The title links to the file and so does
        # the permalink, because for a listing they are the same thing.
        local_href => $href,
        href       => $href,

        # Enough of a post to survive being rendered like one.  The tags and
        # visibility come from the series, as they do for every datasource:
        # the reader reached this page by holding the series' acls.
        tags       => $series->{tags}       // [],
        visibility => $series->{visibility} // 'private',
        created    => $mtime,
        version    => 0,
        user       => $series->{user},
        method     => 'GET',
    };

    return $post;
}

sub _human_size ($bytes) {
    return '' unless defined $bytes;
    return "$bytes B" if $bytes < 1024;

    my @units = qw{KB MB GB TB PB};
    my $size  = $bytes / 1024;
    foreach my $unit (@units) {
        return sprintf( '%.1f %s', $size, $unit ) if $size < 1024 || $unit eq $units[-1];
        $size /= 1024;
    }
    return "$bytes B";
}

=head2 filter($query, @posts) = @posts

Apply the reader's search to the listing.

A listing's posts have no body, so the default -- which searches a post's title
and body -- would only ever match the name.  Search the path and the extension
as well, so that 'pdf' finds the PDFs and a subdirectory's name finds what is
under it.

=cut

sub filter ( $query, @posts ) {
    $query //= {};

    if ( length( $query->{like} // '' ) ) {
        my $like = $query->{like};
        @posts = grep { Trog::DataSource::searchable_match( $like, $_->{name}, $_->{path}, $_->{extension} ) } @posts;
    }

    return Trog::DataSource::filter( { %$query, like => undef }, @posts );
}

=head2 order($query, @posts) = @posts

Directories first, then by name.

Not the default newest-first: this is a directory index, and the convention a
reader expects from one is the convention every file browser has -- which also
means page two holds what page one alphabetically ran out of, rather than
whatever happened to be touched least recently.

=cut

sub order ( $query, @posts ) {
    return sort { ( $b->{is_dir} // 0 ) <=> ( $a->{is_dir} // 0 ) || lc( $a->{name} // '' ) cmp lc( $b->{name} // '' ) || ( $a->{name} // '' ) cmp ( $b->{name} // '' ) } @posts;
}

=head2 lang() = STRING

What the search box searches on a directory listing.

=head2 help() = STRING

Where to read about it.

=cut

sub lang { 'Case insensitive substring of a file name, path or extension' }
sub help { 'https://en.wikipedia.org/wiki/Substring' }

=head2 _watch($query, $directory)

Ask tPSGI to tell us when the directory changes, and throw the static renders
away when it does.

These pages are cached exactly like any other: the render goes through
Trog::Renderer, which hands anonymous, unparameterised, successful renders to
tPSGI to save.  That is the whole point -- a directory listing is cheap to build
but there is no reason to build it per request -- but a cached listing of a
directory that has since changed is simply wrong, and nothing else would ever
invalidate it.  A post being saved does not invalidate this page, because no post
was saved: somebody dropped a file in a directory.

Registered under an explicit key rather than the callback's address.  posts()
runs per request and this closure is built fresh each time, so the default key
would stack a new copy of the same callback on every single view.

The callback uses the tPSGI object it is handed rather than the one from the
request that registered it: watches are shared between workers, so whichever
worker notices the change is the one that must do the invalidating.

=cut

sub _watch ( $query, $directory ) {
    my $tpsgi = $query->{tpsgi};
    return 0 unless $tpsgi;

    # tCMS runs under whatever tPSGI is installed, and watches arrived in it
    # later than the rest of this.  Without them the listing is still correct,
    # it just goes stale until something else invalidates the renders.
    return 0 unless $tpsgi->can('add_watch');

    $tpsgi->add_watch(
        $directory,
        sub {
            my ( $watcher, $change ) = @_;
            $watcher->invalidate_renders('html');
            return 1;
        },
        key => "Trog::DataSource::DirIndex:$directory",
    );

    return 1;
}

1;
