package Trog::Data::DUMMY;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

use Carp qw{confess};
use JSON::MaybeXS;
use File::Slurper;
use File::Copy;
use Mojo::File;
use List::Util;

use parent qw{Trog::DataModule};

=head1 WARNING

Do not use this as a production data model.  It is *not* safe to race conditions, and is only here for testing.

=cut

our $datastore = 'data/DUMMY.json';
sub lang { 'Perl Regex in Quotemeta' }
sub help { 'https://perldoc.perl.org/functions/quotemeta.html' }

sub read ($self, $count=0) {
    confess "Can't find datastore!" unless -f $datastore;
    my $slurped = File::Slurper::read_text($datastore);
    return JSON::MaybeXS::decode_json($slurped);
}

sub write($self,$data) {
    open(my $fh, '>', $datastore) or confess;
    print $fh JSON::MaybeXS::encode_json($data);
    close $fh;
}

sub delete($self, @posts) {
    my $example_posts = $self->read();
    foreach my $update (@posts) {
        @$example_posts = grep { $_->{id} ne $update->{id} } @$example_posts;
    }
    $self->write($example_posts);
    return 0;
}

1;
