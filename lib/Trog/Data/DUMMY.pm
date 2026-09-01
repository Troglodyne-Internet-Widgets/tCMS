package Trog::Data::DUMMY;

use v5.36;
use re '/aa';

use Carp qw{confess};
use Errno();
use Fcntl qw{O_WRONLY O_CREAT O_EXCL};
use JSON::MaybeXS;
use File::Slurper;
use List::Util qw{uniq};
use Path::Tiny();
use parent qw{Trog::DataModule};

=head1 WARNING

Do not use this as a production data model.  It is *not* safe to race conditions, and is only here for testing.

=cut

our $datastore = 'data/DUMMY.json';
sub lang { 'Perl Regex in Quotemeta' }
sub help { 'https://perldoc.perl.org/functions/quotemeta.html' }

our $posts;

sub read ( $self, $query = {} ) {

    # Seed an empty datastore, as one operation rather than a test followed by
    # a create.  O_EXCL means a file that appeared in between is left alone
    # rather than truncated, and unlike the previous unchecked open, a failure
    # that is not EEXIST is reported here instead of surfacing as a confusing
    # 'print on closed filehandle' followed by a die inside read_text.
    if ( sysopen( my $fh, $datastore, O_WRONLY | O_CREAT | O_EXCL ) ) {
        print {$fh} '[]';
        close $fh;
    }
    elsif ( $! != Errno::EEXIST ) {
        confess "Could not create $datastore: $!";
    }
    my $slurped = File::Slurper::read_text($datastore);
    $posts = JSON::MaybeXS::decode_json($slurped);

    # Sort everything by date DESC
    @$posts = sort { $b->{created} <=> $a->{created} } @$posts;

    return $posts;
}

sub count ($self) {
    $posts //= $self->read();
    return scalar(@$posts);
}

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
    print $fh JSON::MaybeXS::encode_json($orig);
    close $fh;
}

sub delete ( $self, @posts ) {
    my $example_posts = $self->read();
    foreach my $update (@posts) {
        @$example_posts = grep { $_->{id} ne $update->{id} } @$example_posts;
    }
    $self->write( $example_posts, 1 );

    return 0;
}

sub tags ($self) {
    return ( uniq map { @{ $_->{tags} } } @$posts );
}

1;
