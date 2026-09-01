package Trog::Data::FlatFile;

use v5.36;
use re '/aa';

use Carp           qw{confess};
use Fcntl          qw{LOCK_EX};
use File::Basename ();
use File::Path     ();
use JSON::MaybeXS;
use File::Slurper;
use File::Slurper::Temp();
use File::Copy;
use Path::Tiny();
use Capture::Tiny qw{capture_merged};

use lib 'lib';
use Trog::Log qw{:all};
use Trog::SQLite::TagIndex;

use parent qw{Trog::DataModule};

our $datastore = 'data/files';
sub lang { 'Perl Regex in Quotemeta' }
sub help { 'https://perldoc.perl.org/functions/quotemeta.html' }

=head1 Trog::Data::FlatFile

This data model has multiple drawbacks, but is "good enough" for most low-content and few editor applications.
You can only post once per second due to it storing each post as a file named after the timestamp.

=cut

our $parser = JSON::MaybeXS->new( utf8 => 1 );

# Initialize the list of posts by tag for all known tags.
# This is because the list won't ever change between HUPs
our @tags = Trog::SQLite::TagIndex::tags();
our %posts_by_tag;

sub read ( $self, $query = {} ) {
    $query->{limit} //= 25;

    #Optimize direct ID
    my @index;
    if ( $query->{id} ) {

        # Only when it's actually there.  A miss here is the ordinary answer to
        # "is there a post with this id", which is what add() asks before every
        # single insert to decide between version 0 and a bump -- naming the
        # file regardless meant every new post reported itself as a failed read.
        # The other branch gets its paths from _index(), which greps -f, so this
        # is the only way a path that isn't there can reach the loop below.
        my $path = "$datastore/$query->{id}";
        @index = ($path) if -f $path;    ## no critic (ProhibitFiletest_f) -- a missing post is a miss, not an error
    }
    else {
        # Remove tags which we don't care about and sort to keep memoized memory usage down
        @{ $query->{tags} } = sort grep {
            my $t = $_;
            grep { $t eq $_ } @tags
        } @{ $query->{tags} };
        my $tagkey = join( '&', @{ $query->{tags} } );

        # Check against memoizer
        $posts_by_tag{$tagkey} //= [];
        @index = @{ $posts_by_tag{$tagkey} } if @{ $posts_by_tag{$tagkey} };

        if ( !@index && -f 'data/posts.db' ) {    ## no critic (ProhibitFiletest_f) -- use the tag index, else fall back to _index()
            @index = map { "$datastore/$_" } Trog::SQLite::TagIndex::posts_for_tags( @{ $query->{tags} } );
            $posts_by_tag{$tagkey} = \@index;
        }
        @index = $self->_index() unless @index;
    }

    my @items;
    foreach my $item (@index) {

        # Checked with defined() rather than truthiness so that an empty file
        # falls through to the JSON parser, which will say what is actually
        # wrong with it rather than blaming the read.
        my $slurped = eval { File::Slurper::read_text($item) };
        if ( !defined $slurped ) {
            WARN("Could not read post '$item': $@");
            next;
        }
        my $parsed;
        capture_merged {
            $parsed = eval { $parser->decode($slurped) }
        };
        if ( !$parsed ) {

            # Try and read it in binary in case it was encoded incorrectly the first time
            $slurped = eval { File::Slurper::read_binary($item) };
            $parsed  = eval { $parser->decode($slurped) };
            if ( !$parsed ) {
                WARN("Could not decode post '$item': $@");
                next;
            }
        }

        #XXX this imposes an inefficiency in itself, get() will filter uselessly again here
        my @filtered = $query->{raw} ? @$parsed : $self->filter( $query, @$parsed );

        push( @items, @filtered ) if @filtered;
        next                      if $query->{limit} == 0;    # 0 = unlimited

        # Enough for the page that was asked for, not one page's worth.  get()
        # paginates *after* this, so stopping at limit meant it had nothing left
        # to slice for page two and every page but the first came back empty --
        # offset pagination simply did not work on this model.
        #
        # >= rather than ==, because a file holds every version of its post and
        # one of them can push @items past the mark in a single step, which the
        # equality test would then never match.
        my $needed = $query->{limit} * ( $query->{page} || 1 );
        last if scalar(@items) >= $needed;
    }

    return \@items;
}

sub _index ($self) {
    confess "Can't find datastore in $datastore !" unless -d $datastore;
    opendir( my $dh, $datastore ) or confess;
    my @index = grep { -f } map { "$datastore/$_" } readdir $dh;    ## no critic (ProhibitFiletest_f) -- listing names, nothing is opened
    closedir $dh;
    return sort { $b cmp $a } @index;
}

sub routes ($self) {
    return Trog::SQLite::TagIndex::routes();
}

sub aliases ($self) {
    return Trog::SQLite::TagIndex::aliases();
}

sub write ( $self, $data ) {

    # The lock and the scratch file both live beside the datastore rather than
    # in it: _index() scans $datastore with readdir, and would otherwise hand
    # either of them to the JSON parser as though it were a post.
    my $spool = File::Basename::dirname($datastore);

    foreach my $post (@$data) {
        my $file = "$datastore/$post->{id}";

        File::Path::make_path($datastore);

        # Two separate races here, needing two separate answers.
        #
        # The lock is what stops a lost update.  Without it two workers saving
        # the same post both read the existing N revisions and each write back
        # N+1, so one save vanishes: at three workers by 25 saves, about 30 of
        # 75 revisions survived.  With it, all 75.  It has to be taken on a
        # path that never gets renamed, hence a lockfile rather than the post.
        open( my $lock, '>>', "$spool/.write.lock" ) or confess "Could not open $spool/.write.lock: $!";
        flock( $lock, LOCK_EX )                      or confess "Could not lock $spool/.write.lock: $!";

        my $slurped = eval { File::Slurper::read_binary($file) };
        my $update  = length( $slurped // '' ) ? [ ( @{ $parser->decode($slurped) }, $post ) ] : [$post];

        # The rename is what stops a torn read.  Every reader here takes no
        # lock, so writing in place lets one catch a half-written file: a few
        # hundred unparseable reads per hundred thousand, against none once the
        # write lands by rename.  PERMS because File::Temp would otherwise
        # create a new post 0600, where a plain open honoured the umask.
        local $File::Slurper::Temp::FILE_TEMP_DIR   = $spool;
        local $File::Slurper::Temp::FILE_TEMP_PERMS = oct('666') & ~umask;
        File::Slurper::Temp::write_binary( $file, $parser->encode($update) );

        close $lock;

        Trog::SQLite::TagIndex::add_post( $post, $self );
    }
}

sub count ($self) {
    my @index = $self->_index();
    return scalar(@index);
}

sub delete ( $self, @posts ) {
    foreach my $update (@posts) {
        unlink "$datastore/$update->{id}" or confess;
        Trog::SQLite::TagIndex::remove_post($update);
    }

    return 0;
}

sub tags ($self) {
    return Trog::SQLite::TagIndex::tags();
}

1;
