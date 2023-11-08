package Trog::FileHandler;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

use POSIX qw{strftime};
use Mojo::File;
use Plack::MIME;
use IO::Compress::Gzip;
use Time::HiRes qw{tv_interval};

use Trog::Log qw{:all};
use Trog::Vars;

#TODO consider integrating libfile
#Stuff that isn't in upstream finders
my %extra_types = (
    '.docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
);

=head2 serve

Serve a file, with options to stream and cache the output.

=cut

sub serve ( $fullpath, $path, $start, $streaming, $ranges, $last_fetch = 0, $deflate = 0 ) {
    my $mf  = Mojo::File->new($path);
    my $ext = '.' . $mf->extname();
    my $ft;
    if ($ext) {
        $ft = Plack::MIME->mime_type($ext) if $ext;
        $ft ||= $extra_types{$ext}         if exists $extra_types{$ext};
    }
    $ft ||= $Trog::Vars::content_types{text};

    my $ct      = 'Content-type';
    my @headers = ( $ct => $ft );

    #TODO use static Cache-Control for everything but JS/CSS?
    push( @headers, 'Cache-control' => $Trog::Vars::cache_control{revalidate} );

    push( @headers, 'Accept-Ranges' => 'bytes' );

    my $mt         = ( stat($path) )[9];
    my $sz         = ( stat(_) )[7];
    my @gm         = gmtime($mt);
    my $now_string = strftime( "%a, %d %b %Y %H:%M:%S GMT", @gm );
    my $code       = $mt > $last_fetch ? 200 : 304;

    push( @headers, "Last-Modified" => $now_string );
    push( @headers, 'Vary'          => 'Accept-Encoding' );

    if ( open( my $fh, '<', $path ) ) {
        return _range( $fh, $ranges, $sz, @headers ) if @$ranges && $streaming;

        # Transfer-encoding: chunked
        return sub {
            my $responder = shift;
            push( @headers, 'Content-Length' => $sz );
            my $writer = $responder->( [ $code, \@headers ] );
            while ( $fh->read( my $buf, $Trog::Vars::CHUNK_SIZE ) ) {
                $writer->write($buf);
            }
            close $fh;
            $writer->close;
          }
          if $streaming && $sz > $Trog::Vars::CHUNK_SIZE;

        #Return data in the event the caller does not support deflate
        if ( !$deflate ) {
            push( @headers, "Content-Length" => $sz );

            # Append server-timing headers
            my $tot = tv_interval($start) * 1000;
            push( @headers, 'Server-Timing' => "file;dur=$tot" );

            return [ $code, \@headers, $fh ];
        }

        #Compress everything less than 1MB
        push( @headers, "Content-Encoding" => "gzip" );
        my $dfh;
        IO::Compress::Gzip::gzip( $fh => \$dfh );
        print $IO::Compress::Gzip::GzipError if $IO::Compress::Gzip::GzipError;
        push( @headers, "Content-Length" => length($dfh) );

        INFO("GET 200 $fullpath");

        # Append server-timing headers
        my $tot = tv_interval($start) * 1000;
        push( @headers, 'Server-Timing' => "file;dur=$tot" );

        return [ $code, \@headers, [$dfh] ];
    }

    INFO("GET 403 $fullpath");
    return [ 403, [ $ct => $Trog::Vars::content_types{text} ], ["STAY OUT YOU RED MENACE"] ];
}

sub _range ( $fh, $ranges, $sz, %headers ) {

    # Set mode
    my $primary_ct   = "Content-Type: $headers{'Content-type'}";
    my $is_multipart = scalar(@$ranges) > 1;
    if ($is_multipart) {
        $headers{'Content-type'} = "multipart/byteranges; boundary=$Trog::Vars::CHUNK_SEP";
    }
    my $code = 206;

    my $fc = '';

    # Calculate the content-length up-front.  We have to fix unspecified lengths first, and reject bad requests.
    foreach my $range (@$ranges) {
        $range->[1] //= $sz - 1;
        return [ 416, [%headers], ["Requested range not satisfiable"] ] if $range->[0] > $sz || $range->[0] < 0 || $range->[1] < 0 || $range->[0] > $range->[1];
    }
    $headers{'Content-Length'} = List::Util::sum( map { my $arr = $_; $arr->[1] + 1, -$arr->[0] } @$ranges );

    #XXX Add the entity header lengths to the value - should hash-ify this to DRY
    if ($is_multipart) {
        foreach my $range (@$ranges) {
            $headers{'Content-Length'} += length("$fc--$Trog::Vars::CHUNK_SEP\n$primary_ct\nContent-Range: bytes $range->[0]-$range->[1]/$sz\n\n");
            $fc = "\n";
        }
        $headers{'Content-Length'} += length("\n--$Trog::Vars::CHUNK_SEP\--\n");
        $fc = '';
    }

    return sub {
        my $responder = shift;
        my $writer;

        foreach my $range (@$ranges) {
            $headers{'Content-Range'} = "bytes $range->[0]-$range->[1]/$sz" unless $is_multipart;
            $writer //= $responder->( [ $code, [%headers] ] );
            $writer->write("$fc--$Trog::Vars::CHUNK_SEP\n$primary_ct\nContent-Range: bytes $range->[0]-$range->[1]/$sz\n\n") if $is_multipart;
            $fc = "\n";

            my $len = List::Util::min( $sz, $range->[1] + 1 ) - $range->[0];

            $fh->seek( $range->[0], 0 );
            while ($len) {
                $fh->read( my $buf, List::Util::min( $len, $Trog::Vars::CHUNK_SIZE ) );
                $writer->write($buf);

                # Adjust for amount written
                $len = List::Util::max( $len - $Trog::Vars::CHUNK_SIZE, 0 );
            }
        }
        $fh->close();
        $writer->write("\n--$Trog::Vars::CHUNK_SEP\--\n") if $is_multipart;
        $writer->close;
    };
}

1;
