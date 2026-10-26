package Trog::Bundle;

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Digest::SHA              ();
use File::Slurper            ();
use JavaScript::Minifier::XS ();
use List::Util               ();

use Trog::Themes ();

=head1 Trog::Bundle

The scripts that a page names, served as one response.

A route names its scripts in a list, and finish_render() in Trog::Routes::HTML
links the bundle of them at the href that scripts() returns.  The route
C</bundle/{version}/{names}.js> serves that bundle.

=cut

# The names of each bundle that a page links, as its href carries them, to the
# bundle.
my %bundles;

# The file of each name, or undef for a name that is not a script.
my sub files_of (@names) {
    return map {
        my $file = m/\A\w[\w.-]*[.]js\z/ ? Trog::Themes::themed_script($_) =~ s{\A/}{www/}r : undef;
        $file && -f $file ? $file : undef;    ## no critic (ProhibitFiletest_f) -- a name that is not a file is not a script
    } @names;
}

# The names as an href carries them, and what changes when a file does.
my sub identify ( $names, $files ) {
    return (
        join( '+',  map { s/[.]js\z//r } @$names ),
        join( "\0", map { join( ':', $_, ( stat $_ )[ 7, 9 ] ) } @$files ),
    );
}

my sub build ( $key, $signature, @files ) {

    # A newline before the semicolon, because a file can end in a line comment.
    my $body = join(
        "\n;\n",
        map {
            my $js = File::Slurper::read_binary($_);
            m/[.]min[.]js\z/ ? $js : JavaScript::Minifier::XS::minify($js)
        } @files
    );
    my $version = substr( Digest::SHA::sha256_hex($body), 0, 16 );
    return {
        href      => "/bundle/$version/$key.js",
        version   => $version,
        body      => $body,
        signature => $signature,
    };
}

=head2 scripts(@names) = HASHREF or undef

The bundle that a page links, of the scripts that @names names.  Each name is a
file name under F<www/scripts>, such as C<post.js>.  The theme's copy of a
script is used in place of the stock one.  The order is the order of @names, and
a name that is given twice is used once.

Returns undef for an empty list, and dies if a name is not a script.

The hash has these keys:

    href     where the bundle is served, which changes when its body does
    version  a digest of the body, which is in the href
    body     the scripts, each one minified unless its name ends in .min.js

A process builds each bundle once, and builds it again when a file in it
changes.

=cut

sub scripts (@names) {
    @names = List::Util::uniq(@names);
    return undef unless @names;

    my @files   = files_of(@names);
    my @missing = map { $names[$_] } grep { !defined $files[$_] } 0 .. $#names;
    die "There is no script to bundle named @missing\n" if @missing;

    my ( $key, $signature ) = identify( \@names, \@files );
    return $bundles{$key} if $bundles{$key} && $bundles{$key}{signature} eq $signature;
    return $bundles{$key} = build( $key, $signature, @files );
}

=head2 served(@names) = HASHREF or undef

The bundle that the route serves for @names, as scripts() describes it, or undef
if a name is not a script.

It is the bundle that scripts() built, if that one is current.  Otherwise it is
built for this request and not kept, because anyone can put any list in a URL.

=cut

sub served (@names) {
    @names = List::Util::uniq(@names);
    my @files = files_of(@names);
    return undef if !@names || List::Util::any { !defined } @files;

    my ( $key, $signature ) = identify( \@names, \@files );
    my $linked = $bundles{$key};
    return $linked if $linked && $linked->{signature} eq $signature;
    return build( $key, $signature, @files );
}

=head2 save($tpsgi, $bundle)

Have tPSGI save $bundle as a static render after the response, so that the
webserver serves it from then on.  A process saves a given bundle once.

finish_render() calls this for the bundle that a page links, so only the lists
that routes name are saved.  A list that only a URL names is built and served,
but never saved, because anyone can ask for as many of those as they like.

It also has tPSGI watch the directories of the scripts.  When a script changes,
the saved pages and bundles are thrown away: the pages are rendered again and
link the new bundle, and a page that still links an old one is redirected by
the route.  The route also serves a bundle whose static is gone, so a worker
that still counts it as saved is slower, not wrong.

=cut

# The hrefs of the bundles that this process saved.
our %saved;

sub save ( $tpsgi, $bundle ) {
    return 0 if !$tpsgi || $saved{ $bundle->{href} };

    if ( $tpsgi->can('add_watch') ) {
        my $theme = Trog::Themes::get_dir();
        foreach my $dir ( grep { -d } ( 'www/scripts', $theme ? "$theme/scripts" : () ) ) {
            $tpsgi->add_watch(
                $dir,
                sub {
                    my ( $watcher, $change ) = @_;
                    $watcher->invalidate_renders($_) for qw{html js};
                    return 1;
                },
                key => "Trog::Bundle:$dir",
            );
        }
    }

    $tpsgi->add_post_close_callback(
        sub {
            $tpsgi->save_render( $bundle->{href}, 'js', $bundle->{body} );
            $saved{ $bundle->{href} } = 1;
        }
    );
    return 1;
}
