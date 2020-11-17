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
use List::Util;

use parent qw{Trog::DataModule};

our $datastore = 'data/files/';
sub lang { 'Perl Regex in Quotemeta' }
sub help { 'https://perldoc.perl.org/functions/quotemeta.html' }
our @index;

sub read ($self, $query=undef) {
    @index //= $self->_index();
    my @items;
    foreach my $item (@index) {
        my $slurped = File::Slurper::read_text($item);
        my $parsed  = JSON::MaybeXS::decode_json($slurped);
        push(@items,$parsed) unless $self->filter($parsed);
        last if scalar(@items) == $query->{limit};
    }
    return @items;
}

sub _index ($self) {
    return @index if @index;
    confess "Can't find datastore!" unless -d $datastore;
    opendir(my $dh, $datastore) or die;
    @index = grep { -f $_ } readdir $dh;
    closedir $dh;
    return @index;
}

sub write($self,$data) {
    open(my $fh, '>', $datastore) or confess;
    print $fh JSON::MaybeXS::encode_json($data);
    close $fh;
}

sub count ($self) {
    @index //= $self->_index();
    return scalar(@index);
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
