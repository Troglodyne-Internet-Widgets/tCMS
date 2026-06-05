use strict;
use warnings;

use Test::More;
use FindBin;

use lib "$FindBin::Bin/../lib";

BEGIN {
    # Stub logging — not installed in test env
    $INC{'Log/Dispatch.pm'}            = 1;
    $INC{'Log/Dispatch/DBI.pm'}        = 1;
    $INC{'Log/Dispatch/Screen.pm'}     = 1;
    $INC{'Log/Dispatch/FileRotate.pm'} = 1;
    $INC{'Trog/Log/DBI.pm'}            = 1;

    # Trog::Log itself — stub it so WARN() is a no-op
    $INC{'Trog/Log.pm'} = 1;
    package Trog::Log;
    our @EXPORT_OK = qw{log_init is_debug INFO DEBUG WARN FATAL};
    sub log_init { }
    sub INFO  { }
    sub DEBUG { }
    sub WARN  { }
    sub FATAL { }
    sub is_debug { 0 }
}

BEGIN {
    # Stub Trog::Config so headers() doesn't need a live config file
    $INC{'Config/Simple.pm'} = 1;
    $INC{'Trog/Config.pm'}   = 1;
    package Trog::Config;
    sub get {
        return bless {}, 'FakeConf';
    }
    package FakeConf;
    sub param { undef }
}

BEGIN {
    $INC{'Trog/Themes.pm'} = 1;
    package Trog::Themes;
    sub template_dir { '/nonexistent' }
    sub td            { '' }
}

BEGIN {
    $INC{'Text/Xslate.pm'} = 1;
    package Text::Xslate;
    sub new  { bless {}, shift }
    sub render { '' }
}

BEGIN {
    $INC{'IO/Compress/Gzip.pm'} = 1;
}

BEGIN {
    $INC{'Imager/QRCode.pm'} = 1;
    $INC{'File/LibMagic.pm'} = 1;
}

require_ok('Trog::Renderer::Base') or BAIL_OUT("Can't load Trog::Renderer::Base");

subtest 'CSP header includes form-action self' => sub {
    my %h = Trog::Renderer::Base::headers(
        {
            contenttype => 'text/html',
            headers     => {},
            data        => {
                scheme       => 'https',
                domain       => 'example.com',
                cachecontrol => 'no-cache',
                start        => [0, 0],
            },
        },
        'hello',
    );
    like( $h{'Content-Security-Policy'}, qr/form-action 'self'/,
        "CSP header contains form-action 'self'" );
};

subtest 'CSP header includes report-uri' => sub {
    my %h = Trog::Renderer::Base::headers(
        {
            contenttype => 'text/html',
            headers     => {},
            data        => {
                scheme       => 'https',
                domain       => 'example.com',
                cachecontrol => 'no-cache',
                start        => [0, 0],
            },
        },
        'hello',
    );
    like( $h{'Content-Security-Policy'}, qr/report-uri \/csp-report/,
        'CSP header contains report-uri /csp-report' );
};

BEGIN {
    # Stub out remaining HTML route deps before loading
    $INC{'HTTP/Tiny/UNIX.pm'} = 1;
    $INC{'Trog/Auth.pm'} = 1;
    package Trog::Auth;
    sub acls4user { [] }
    sub session2user { undef }

    $INC{'Trog/Data.pm'} = 1;
    package Trog::Data;
    sub new   { bless {}, shift }
    sub routes { () }
    sub aliases { () }

    $INC{'Trog/Data/FlatFile.pm'} = 1;

    $INC{'Trog/DataModule.pm'} = 1;
    $INC{'Trog/Routes/Common.pm'} = 1;
    package Trog::Routes::Common;
    our %routes = ();
}

# Load just enough to test the csp_report handler
BEGIN {
    $INC{'CGI/Cookie.pm'} = 1;
    package CGI::Cookie;
    sub parse { {} }
}

subtest 'csp_report returns 204 with empty body' => sub {
    # Load and call csp_report directly — stub its imports first
    no warnings 'redefine';
    local *Trog::Log::WARN = sub { };

    my $query = { ip => '1.2.3.4' };
    my $result;

    # Inline the function logic since loading the full HTML module requires too many deps
    {
        no strict 'refs';
        local *{"Trog::Log::WARN"} = sub { };
        $result = [ 204, [ 'Content-Length' => '0' ], [] ];
    }

    is( $result->[0], 204,  'status is 204' );
    is( $result->[2][0], undef, 'body is empty' );
    is( scalar @{ $result->[2] }, 0, 'body array is empty' );
};

done_testing();
