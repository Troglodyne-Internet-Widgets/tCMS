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
use IO::AIO 2;

use parent qw{Trog::DataModule};

our $datastore = 'data/files';
sub lang { 'Perl Regex in Quotemeta' }
sub help { 'https://perldoc.perl.org/functions/quotemeta.html' }

=head1 Trog::Data::FlatFile

This data model has multiple drawbacks, but is "good enough" for most low-content and few editor applications.
You can only post once per second due to it storing each post as a file named after the timestamp.

=cut

our $parser = JSON::MaybeXS->new();

sub read ($self, $query={}) {
    #Optimize direct ID
    my @index;
    if ($query->{id}) {
        @index = ("$datastore/$query->{id}");
    } else {
        @index = $self->_index();
    }
    $query->{limit} //= 25;

    my $done = 0;
    my $grp = aio_group sub {
        $done = 1;
    };
    #TODO up the limit of group appropriately

    my $contents = {};
    my $num_read = 0;
    @index = grep { -f } @index;

    my @items;
    feed $grp sub {
        my $file = shift @index or return;
        add $grp (aio_slurp $file, 0, 0, $contents->{$file}, sub {

            #Don't waste any time if we dont have to
            return if scalar(@items) >= $query->{limit};

            my $parsed  = $parser->decode($contents->{$file});

            #XXX this imposes an inefficiency in itself, get() will filter uselessly again here later
            my @filtered = $self->filter($query,@$parsed);
            push(@items,@filtered) if @filtered;
        });
    };
    while (@index && !$done) {
        IO::AIO::poll_cb();
        last if scalar(@items) == $query->{limit};
    }
    $grp->cancel();
    @items = sort {$b->{created} <=> $a->{created} } @items;
    return \@items;

    foreach my $item (@index) {
        my $slurped = eval { File::Slurper::read_text($item) };
        if (!$slurped) {
            print "Failed to Read $item:\n$@\n";
            next;
        }
        my $parsed  = $parser->decode($slurped);

        #XXX this imposes an inefficiency in itself, get() will filter uselessly again here
        my @filtered = $self->filter($query,@$parsed);

        push(@items,@filtered) if @filtered;
        last if scalar(@items) == $query->{limit};
    }

    return \@items;
}

sub _index ($self) {
    confess "Can't find datastore!" unless -d $datastore;
    opendir(my $dh, $datastore) or confess;
    my @index = grep { -f } map { "$datastore/$_" } readdir $dh;
    closedir $dh;
    return sort { $b cmp $a } @index;
}

sub write($self,$data) {
    foreach my $post (@$data) {
        my $file = "$datastore/$post->{id}";
        my $update = [$post];
        if (-f $file) {
            my $slurped = File::Slurper::read_text($file);
            my $parsed  = $parser->decode($slurped);

            $update = [(@$parsed, $post)];
        }

        open(my $fh, '>', $file) or confess;
        print $fh $parser->encode($update);
        close $fh;
    }
}

sub count ($self) {
    my @index = $self->_index();
    return scalar(@index);
}

sub add ($self,@posts) {
    my $ctime = time();
    @posts = map {
        $_->{id} //= $ctime;
        $_->{created} = $ctime;
        $_
    } @posts;
    return $self->SUPER::add(@posts);
}

sub delete($self, @posts) {
    foreach my $update (@posts) {
        unlink "$datastore/$update->{id}" or confess;
    }
    return 0;
}

1;
