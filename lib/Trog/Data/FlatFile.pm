package Trog::Data::FlatFile;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

use Carp qw{confess};
use JSON::MaybeXS;
use File::Slurper;
use File::Copy;
use Path::Tiny();
use Capture::Tiny qw{capture_merged};

use lib 'lib';
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
        @index = ("$datastore/$query->{id}");
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

        if ( !@index && -f 'data/posts.db' ) {
            @index = map { "$datastore/$_" } Trog::SQLite::TagIndex::posts_for_tags( @{ $query->{tags} } );
            $posts_by_tag{$tagkey} = \@index;
        }
        @index = $self->_index() unless @index;
    }

    my @items;
    foreach my $item (@index) {
        next unless -f $item;
        my $slurped = eval { File::Slurper::read_text($item) };
        if ( !$slurped ) {
            print "Failed to Read $item:\n$@\n";
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
                print "JSON Decode error on $item:\n$@\n";
                next;
            }
        }

        #XXX this imposes an inefficiency in itself, get() will filter uselessly again here
        my @filtered = $query->{raw} ? @$parsed : $self->filter( $query, @$parsed );

        push( @items, @filtered ) if @filtered;
        next                      if $query->{limit} == 0;                # 0 = unlimited
        last                      if scalar(@items) == $query->{limit};
    }

    return \@items;
}

sub _index ($self) {
    confess "Can't find datastore in $datastore !" unless -d $datastore;
    opendir( my $dh, $datastore ) or confess;
    my @index = grep { -f } map { "$datastore/$_" } readdir $dh;
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
    foreach my $post (@$data) {
        my $file   = "$datastore/$post->{id}";
        my $update = [$post];
        if ( -f $file ) {
            my $slurped = File::Slurper::read_binary($file);
            my $parsed  = $parser->decode($slurped);

            $update = [ ( @$parsed, $post ) ];
        }

        mkdir $datastore;
        open( my $fh, '>', $file ) or confess "Could not open $file";
        print $fh $parser->encode($update);
        close $fh;

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

    # Gorilla cache invalidation
    Path::Tiny::path('www/statics')->remove_tree;

    return 0;
}

sub tags ($self) {
    return Trog::SQLite::TagIndex::tags();
}

1;
