package Trog::Data::DUMMY;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

use Carp qw{confess};
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
    if ( !-f $datastore ) {
        open( my $fh, '>', $datastore );
        print $fh '[]';
        close $fh;
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

    # Gorilla cache invalidation
    Path::Tiny::path('www/statics')->remove_tree;

    return 0;
}

sub tags ($self) {
    return ( uniq map { @{ $_->{tags} } } @$posts );
}

1;
