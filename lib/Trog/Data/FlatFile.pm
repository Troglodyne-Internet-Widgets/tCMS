package Trog::Data::FlatFile;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

use Carp qw{confess};
use JSON::MaybeXS;
use File::Slurper;
use File::Copy;
use Mojo::File;

use parent qw{Trog::DataModule};

our $datastore = 'data/files';
sub lang { 'Perl Regex in Quotemeta' }
sub help { 'https://perldoc.perl.org/functions/quotemeta.html' }
our @index;

=head1 Trog::Data::FlatFile

This data model has multiple drawbacks, but is "good enough" for most low-content and few editor applications.
You can only post once per second due to it storing each post as a file named after the timestamp.

=cut

our $parser = JSON::MaybeXS->new();

sub read ($self, $query={}) {
    @index = $self->_index() unless @index;
    my @items;
    foreach my $item (@index) {
        my $slurped = File::Slurper::read_text($item);
        my $parsed  = $parser->decode($slurped);
        push(@items,$parsed) if $self->filter($query,$parsed);
        last if scalar(@items) == $query->{limit};
    }
    return \@items;
}

sub _index ($self) {
    return @index if @index;
    confess "Can't find datastore!" unless -d $datastore;
    opendir(my $dh, $datastore) or confess;
    @index = grep { -f } map { "$datastore/$_" } readdir $dh;
    closedir $dh;
    return sort { $b cmp $a } @index;
}

sub write($self,$data) {
    my $file = "$datastore/$data->{created}";
    open(my $fh, '>', $file) or confess;
    print $fh $parser->encode($data);
    close $fh;
}

sub count ($self) {
    @index = $self->_index() unless @index;
    return scalar(@index);
}

sub delete($self, @posts) {
    foreach my $update (@posts) {
        unlink "$datastore/$update->{created}" or confess;
    }
    return 0;
}

1;
