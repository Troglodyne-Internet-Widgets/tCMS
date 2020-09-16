package Trog::Data::DUMMY;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

sub new ($class, $config) {
    return bless($config,__PACKAGE__);
}

# These have to be sorted as requested by the client
sub get ($self, %request) {
    return [{ data => "<hr><h3 class='blogtitles'><a href='/'>Example Post</a></h3>Here, caveman", id => 666 }]
}

sub add ($self, @posts) {
    return 1;
}

sub update($self, @posts) {
    return 1;
}

sub delete($self, @ids) {
    return 1;
}

1;
