use strict;
use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

# Stub modules that are unavailable or have heavy native deps before loading SUT.
# Pattern: define package, mark as loaded in %INC.

BEGIN {
    package HTTP::Tiny::UNIX;
    $INC{'HTTP/Tiny/UNIX.pm'} = 1;
}

BEGIN {
    package Plack::MIME;
    sub mime_type {
        my ( $class, $ext ) = @_;
        my %map = (
            '.html' => 'text/html',
            '.txt'  => 'text/plain',
            '.png'  => 'image/png',
            '.jpg'  => 'image/jpeg',
        );
        return $map{$ext};
    }
    $INC{'Plack/MIME.pm'} = 1;
}

BEGIN {
    package Mojo::File;
    sub new {
        my ( $class, $path ) = @_;
        return bless { path => $path }, $class;
    }
    sub extname {
        my ($self) = @_;
        my $path = $self->{path};
        return '' unless $path =~ /\.([^.\/]+)$/;
        return $1;
    }
    $INC{'Mojo/File.pm'} = 1;
}

BEGIN {
    package File::LibMagic;
    sub new { bless {}, $_[0] }
    sub info_from_filename { return {} }
    $INC{'File/LibMagic.pm'} = 1;
}

BEGIN {
    package Ref::Util;
    use Exporter 'import';
    our @EXPORT_OK = qw{is_hashref};
    sub is_hashref { ref $_[0] eq 'HASH' }
    $INC{'Ref/Util.pm'} = 1;
}

BEGIN {
    package Trog::Log;
    use Exporter 'import';
    our @EXPORT_OK   = qw{log_init is_debug INFO DEBUG WARN FATAL};
    our %EXPORT_TAGS = ( 'all' => \@EXPORT_OK );
    sub log_init {}
    sub is_debug { 0 }
    sub INFO  { }
    sub DEBUG { }
    sub WARN  { }
    sub FATAL { }
    $INC{'Trog/Log.pm'} = 1;
}

BEGIN {
    package Trog::Config;
    sub get { bless {}, 'Trog::Config' }
    $INC{'Trog/Config.pm'} = 1;
}

require_ok('Trog::Utils') or BAIL_OUT("Can't load SUT");

subtest coerce_array => sub {
    is_deeply( Trog::Utils::coerce_array(undef),        [],           'undef returns empty arrayref' );
    is_deeply( Trog::Utils::coerce_array(0),            [],           'false scalar returns empty arrayref' );
    is_deeply( Trog::Utils::coerce_array('foo'),        ['foo'],      'scalar wrapped in arrayref' );
    is_deeply( Trog::Utils::coerce_array( ['a', 'b'] ), ['a', 'b'], 'arrayref passes through unchanged' );
};

subtest strip_and_trunc => sub {
    is( Trog::Utils::strip_and_trunc(undef), undef, 'undef returns undef' );
    is( Trog::Utils::strip_and_trunc(''),    undef, 'empty string returns undef' );
    is( Trog::Utils::strip_and_trunc('<b>hello</b>'),          'hello',       'HTML tags stripped' );
    is( Trog::Utils::strip_and_trunc('<p>foo</p><br/>bar'),    'foobar',      'multiple tags stripped' );
    is( Trog::Utils::strip_and_trunc('plain text'),            'plain text',  'plain text unchanged' );
    is( Trog::Utils::strip_and_trunc('<a href="x">link</a>'), 'link',        'attribute in tag stripped' );

    my $long = 'x' x 300;
    is( length( Trog::Utils::strip_and_trunc($long) ), 280, 'long string truncated to 280 chars' );

    my $exact = 'y' x 280;
    is( Trog::Utils::strip_and_trunc($exact), $exact, 'exactly-280-char string not truncated' );
};

subtest uuid => sub {
    my $id = Trog::Utils::uuid();
    ok( defined $id && length($id) > 0, 'uuid returns a non-empty string' );
};

subtest mime_type => sub {
    is( Trog::Utils::mime_type('file.html'), 'text/html',   'html extension recognized' );
    is( Trog::Utils::mime_type('file.txt'),  'text/plain',  'txt extension recognized' );
    is( Trog::Utils::mime_type('file.png'),  'image/png',   'png extension recognized' );
    is( Trog::Utils::mime_type('file.docx'),
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'docx uses extra_types fallback'
    );
    # For an unknown extension with no libmagic result, returns undef
    is( Trog::Utils::mime_type('file.unknownxyz'), undef, 'unknown extension returns undef when libmagic gives nothing' );
};

done_testing;
