package Trog::Data::DUMMY;

# ABSTRACT: A data model in one JSON file, for tests only

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Carp qw{confess};
use Errno();
use Fcntl qw{O_WRONLY O_CREAT O_EXCL};
use JSON::MaybeXS;
use File::Slurper;
use List::Util qw{uniq};
use parent     qw{Trog::DataModule};

=head1 WARNING

Do not use this as a production data model.  It is *not* safe to race conditions, and is only here for testing.

=cut

our $datastore = 'data/DUMMY.json';

=head1 METHODS

=head2 lang()

Returns Str, C<Perl Regex in Quotemeta>, the name of the query language.

    my $language = $data->lang();

=cut

sub lang { return 'Perl Regex in Quotemeta' }

=head2 help()

Returns Str, the URL of the documentation of quotemeta.

    my $help = $data->help();

=cut

sub help { return 'https://perldoc.perl.org/functions/quotemeta.html' }

our $posts;

=head2 read($query)

Every post in data/DUMMY.json, the newest created first.  It ignores $query,
so get() does the filtering.  It creates the file with no posts when it is
missing, and keeps the posts in C<$Trog::Data::DUMMY::posts> for count() and
tags().

=over 4

=item query - HashRef - the request of get(), which it ignores

=back

Returns ArrayRef[HashRef], the posts.

Dies when it cannot create the file, or when the file is not a JSON array.

    my $posts = $data->read( {} );

=cut

sub read {

    # Seed an empty datastore, as one operation rather than a test followed by
    # a create.  O_EXCL means a file that appeared in between is left alone
    # rather than truncated, and unlike the previous unchecked open, a failure
    # that is not EEXIST is reported here instead of surfacing as a confusing
    # 'print on closed filehandle' followed by a die inside read_text.
    if ( sysopen( my $fh, $datastore, O_WRONLY | O_CREAT | O_EXCL ) ) {
        print {$fh} '[]';
        close($fh) or confess "Could not write $datastore: $!";
    }
    elsif ( $! != Errno::EEXIST ) {
        confess "Could not create $datastore: $!";
    }
    my $slurped = File::Slurper::read_text($datastore);
    $posts = JSON::MaybeXS::decode_json($slurped);

    # Sort everything by date DESC
    @$posts = reverse sort { $a->{created} <=> $b->{created} } @$posts;

    return $posts;
}

=head2 count()

The number of posts that read() last loaded.  It calls read() only when
nothing is loaded yet, so a post written since then is not counted.

Returns Int, the number of posts.

Dies when read() dies.

    my $total = $data->count();

=cut

sub count ($self) {
    $posts //= $self->read();
    return scalar(@$posts);
}

=head2 write($data, $overwrite)

Add the posts to data/DUMMY.json, or replace the posts in it with them.

=over 4

=item data - ArrayRef[HashRef] - the posts

=item overwrite - Bool - true to replace every post in the file with $data.  The default is false, which adds them.

=back

Returns 1.

Dies when it cannot write the file, or when read() dies.

    $data->write( \@posts );

=cut

sub write ( $self, $data, $overwrite = 0 ) {
    my $orig = [];
    if ($overwrite) {
        $orig = $data;
    }
    else {
        $orig = $self->read();
        push( @$orig, @$data );
    }
    open( my $fh, '>', $datastore ) or confess;
    print {$fh} JSON::MaybeXS::encode_json($orig);
    close($fh) or confess "Could not write $datastore: $!";
    return 1;
}

=head2 delete(@posts)

Remove every post with the id of one of @posts from the file.

=over 4

=item @posts - HashRef - the posts to delete.  Only the id of each counts.

=back

Returns 0.

Dies when read() or write() dies.

    $data->delete( { id => $id } );

=cut

sub delete ( $self, @posts ) {
    my $example_posts = $self->read();
    foreach my $update (@posts) {
        @$example_posts = grep { $_->{id} ne $update->{id} } @$example_posts;
    }
    $self->write( $example_posts, 1 );

    return 0;
}

=head2 tags()

The tags of the posts that read() last loaded.  The list is empty when
nothing is loaded yet.

Returns a list of Str, the tags, each once.

    my @tags = $data->tags();

=cut

sub tags {
    return ( uniq map { @{ $_->{tags} } } @$posts );
}

1;
