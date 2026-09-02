use strict;
use warnings;

use Test::More;
use Test::MockModule qw{strict};
use Test::Deep;
use Test::Fatal qw{exception};
use JSON::MaybeXS();
use Path::Tiny();
use URI::Escape();
use FindBin;
use feature qw{signatures};
no warnings qw{experimental::signatures};

use lib "$FindBin::Bin/../lib";

require_ok('Trog::DataModule') or BAIL_OUT("Can't find SUT");
require_ok('Trog::Routes::HTML');

# Point the SUT at a temp component dir we control and hand it whatever
# sidecars each subtest wants.  The layout has to mirror the real one -- the
# component dir with a forms/ inside it -- because schema_for() keys its cache
# on the mtime of forms/, and an earlier version of this fixture flattened the
# two and so could not have caught it being keyed on the wrong directory.
my $tempdir  = Path::Tiny->tempdir();
my $formsdir = $tempdir->child('forms');
$formsdir->mkpath();
my %sidecars;

my $thememock = Test::MockModule->new('Trog::Themes');
$thememock->redefine( 'template_dirs', sub { ("$tempdir") } );
$thememock->redefine(
    'themed_file_in_dir',
    sub ( $path, $file, @ ) {
        return -f "$formsdir/$file" ? "$formsdir/$file" : undef;
    }
);

# The logger isn't initialized outside of a running server.
my $logmock = Test::MockModule->new('Trog::DataModule');
$logmock->redefine( 'WARN', sub { note(shift) } );

# The canned editor blocks and their sidecars, which live in the components dir
# itself rather than in forms/ -- preview.json beside preview.tx.
my %components;

my $slurpmock = Test::MockModule->new('File::Slurper');
$slurpmock->redefine(
    'read_text',
    sub {
        my $name = Path::Tiny::path(shift)->basename;
        return exists $sidecars{$name} ? $sidecars{$name} : $components{$name};
    }
);

# -f has to agree with %sidecars, and the dir mtime has to move, or the
# mtime-keyed cache will hand back a stale answer.
my $generation = 0;

sub set_sidecars {
    %sidecars = @_;
    $_->remove foreach $formsdir->children();
    $formsdir->child($_)->spew_utf8('{}') foreach keys %sidecars;
    $generation++;
    utime( time() + $generation, time() + $generation, "$formsdir" );
    return;
}

# The same, one directory up.  forms/ is a child of this one, so only the files
# get cleared out.
sub set_components {
    %components = @_;
    $_->remove foreach grep { !$_->is_dir } $tempdir->children();
    $tempdir->child($_)->spew_utf8('{}') foreach keys %components;
    $generation++;
    utime( time() + $generation, time() + $generation, "$tempdir" );
    return;
}

sub sidecar { return JSON::MaybeXS::encode_json( { type => 'object', @_ } ) }

subtest 'the base schema applies with no sidecar at all' => sub {
    set_sidecars();

    my $schema = Trog::DataModule::schema_for('blog.tx');
    ok( exists $schema->{properties}{title},  "base properties are there" );
    ok( !exists $schema->{properties}{gravy}, "and nothing else is" );
    ok( !exists $schema->{required},          "an empty required list isn't emitted - it isn't legal OpenAPI" );

    is_deeply(
        Trog::DataModule::schema_for(''),
        $schema,
        "a post with no form still gets the base schema"
    );
};

subtest 'a sidecar merges over the base' => sub {
    set_sidecars(
        'recipe.json' => sidecar(
            required   => ['servings'],
            properties => { servings => { type => 'integer' }, vegan => { type => 'boolean' } },
        )
    );

    my $schema = Trog::DataModule::schema_for('recipe.tx');
    ok( exists $schema->{properties}{servings}, "the sidecar's fields are merged in" );
    ok( exists $schema->{properties}{title},    "...without losing the base's" );
    is_deeply( $schema->{required}, ['servings'], "required carries over" );

    ok(
        !exists Trog::DataModule::schema_for('blog.tx')->{properties}{servings},
        "and they don't leak onto another post type"
    );
};

subtest 'sidecars cannot redefine core post fields' => sub {
    set_sidecars(
        'evil.json' => sidecar(
            properties => {
                id       => { type => 'object' },
                acls     => { type => 'string' },
                callback => { type => 'string' },
            },
        )
    );

    my $schema = Trog::DataModule::schema_for('evil.tx');
    is( $schema->{properties}{id}{type},       'string',   "id keeps its own type" );
    is( $schema->{properties}{acls}{type},     'array',    "acls stays an array" );
    is( $schema->{properties}{callback}{type}, 'callback', "callback keeps the type that actually checks the sub exists" );
};

subtest 'a malformed sidecar is skipped, not fatal' => sub {
    set_sidecars( 'busted.json' => '{ this is not json' );

    my $schema;
    is( exception { $schema = Trog::DataModule::schema_for('busted.tx') }, undef, "no exception" );
    ok( exists $schema->{properties}{title}, "we fall back to the base schema" );
};

subtest 'the cache follows the forms dir mtime' => sub {
    set_sidecars( 'recipe.json' => sidecar( properties => { servings => { type => 'integer' } } ) );
    ok( exists Trog::DataModule::schema_for('recipe.tx')->{properties}{servings}, "declared" );

    set_sidecars();
    ok(
        !exists Trog::DataModule::schema_for('recipe.tx')->{properties}{servings},
        "removing the sidecar is picked up without a restart"
    );
};

subtest 'validate() filters, coerces and reports' => sub {
    set_sidecars(
        'recipe.json' => sidecar(
            properties => {
                servings => { type => 'integer' },
                vegan    => { type => 'boolean' },
                photo    => { type => 'upload' },
            },
        )
    );

    my $post = {
        form       => 'recipe.tx',
        title      => 'Cookies',
        visibility => 'public',
        servings   => '12',
        vegan      => '1',

        # The router hands us plenty that was never a post field.
        app   => 'junk',
        to    => '/blog',
        gravy => 'yes please',
    };
    is_deeply( [ Trog::DataModule::validate($post) ], [], "a good post has no errors" );
    is( $post->{servings}, 12, "strings coerce to the declared type" );
    isa_ok( $post->{vegan}, 'JSON::PP::Boolean', "checkbox values become real booleans" );
    ok( !exists $post->{app} && !exists $post->{to} && !exists $post->{gravy}, "undescribed keys are filtered out" );

    my ($error) = Trog::DataModule::validate( { form => 'recipe.tx', servings => 'lots' } );
    like( $error, qr/servings/, "a bad value is reported rather than silently dropped" );

    # 'upload' is our own sugar for the string-or-hashref an upload field is,
    # depending on which direction it's travelling.
    is_deeply( [ Trog::DataModule::validate( { form => 'recipe.tx', photo => { filename => 'x' } } ) ], [], "an upload hashref passes" );
    is_deeply( [ Trog::DataModule::validate( { form => 'recipe.tx', photo => '/assets/x.jpg' } ) ],     [], "so does the href it becomes" );
};

subtest 'what gets written is checked, not just what was submitted' => sub {
    set_sidecars();

    # validate() runs on the submitted post.  _process() then builds the shape
    # that is actually stored, and until it was checked too, a post could be
    # made wrong on its way to disk and nobody would ever hear about it.
    my $good = { form => 'blog.tx', title => 'Fine', tags => [qw{blog public}], visibility => 'public' };
    is_deeply( [ Trog::DataModule::validate_built($good) ], [], 'a well built post passes' );

    my $holed  = { form => 'blog.tx', title => 'Holed', tags => [ 'public', undef ], visibility => 'public' };
    my @errors = Trog::DataModule::validate_built($holed);
    ok( scalar(@errors), 'a null in the tags is caught' );
    like( "$errors[0]", qr{/tags/1}, 'and named by where it is' );

    # It checks rather than filters, unlike validate(): _process() adds fields
    # the base schema has never heard of, and throwing those away would discard
    # the work it just did.
    my $built = {
        form         => 'blog.tx',
        title        => 'Built',
        tags         => ['public'],
        visibility   => 'public',
        content_type => 'text/html',
        is_video     => 1,
        attachments  => ['/assets/thing.txt'],
        preview      => '/assets/thumb.png',
    };
    is_deeply( [ Trog::DataModule::validate_built($built) ], [], "the fields _process() invents do not fail it" );
    ok( exists $built->{is_video},    'and are not deleted' );
    ok( exists $built->{attachments}, 'any of them' );
};

subtest '_process no longer builds a post wrong' => sub {

    # The bug: a post saved without a visibility had an undef pushed into its
    # tags, which is a tag no query ever matches -- so the post went invisible
    # to all but an admin, silently, and the bunk tag was written to disk.
    my $post = Trog::DataModule::_process( { form => 'blog.tx', title => 'No Visibility', tags => ['blog'] } );

    is_deeply( [ grep { !defined } @{ $post->{tags} } ], [], 'no undef survives into the tags' );
    is( $post->{visibility}, 'private', 'and the visibility is defaulted where the tag is made' );
    ok( scalar( grep { $_ eq 'private' } @{ $post->{tags} } ), 'so the tag it produces is a real one' );

    # Which is the same thing validate_built() is there to notice.
    is_deeply( [ Trog::DataModule::validate_built($post) ], [], 'and the result passes the check' );

    # An undef among the acls of a private post went the same way.
    my $acled = Trog::DataModule::_process( { form => 'blog.tx', title => 'Acled', tags => ['blog'], visibility => 'private', acls => [ 'members', undef ] } );
    is_deeply( [ grep { !defined } @{ $acled->{tags} } ], [], 'nor from the acls' );
    ok( scalar( grep { $_ eq 'members' } @{ $acled->{tags} } ), 'while the real acl still lands' );
};

subtest 'add() refuses to store a post it built wrong' => sub {
    set_sidecars();

    # Break _process on purpose: the point is that add() no longer takes its
    # word for it.  This is the shape the real bug produced.
    #
    # One mock object for all three, and unmocked by hand at the end.
    # Test::MockModule keeps one per package, so a second new() on the same
    # package hands back the first -- and leaving it to go out of scope left
    # _process broken for every subtest after this one.
    my @written;
    my $mock = Test::MockModule->new('Trog::DataModule');
    $mock->redefine(
        '_process',
        sub ($post) {
            push( @{ $post->{tags} }, undef );
            return $post;
        }
    );
    $mock->redefine( 'write', sub { my ( $self, $data ) = @_; push( @written, @$data ); return 1 } );
    $mock->redefine( 'get',   sub { return () } );

    my $model = bless {}, 'Trog::DataModule';
    my $err   = exception { $model->add( { form => 'blog.tx', title => 'Doomed', tags => ['blog'], visibility => 'public' } ) };

    $mock->unmock_all();

    ok( $err, 'the save fails' );
    is( ref $err, 'ARRAY', 'with the errors the submitter is shown' );
    like( "$err->[0]", qr{/tags/}, 'saying what was wrong' );
    is_deeply( \@written, [], 'and nothing was written' );

    # The mock really is gone, or every subtest after this one is testing it.
    my $sane = Trog::DataModule::_process( { form => 'blog.tx', title => 'Sane', tags => ['blog'], visibility => 'public' } );
    is_deeply( [ grep { !defined } @{ $sane->{tags} } ], [], '_process is itself again afterwards' );
};

subtest 'empty inputs are treated as absent, except for strings' => sub {
    set_sidecars( 'recipe.json' => sidecar( properties => { servings => { type => 'integer' } } ) );

    # An untouched number input submits '', which is not an integer and was
    # never meant to be one.
    my $post = { form => 'recipe.tx', servings => '', title => '' };
    is_deeply( [ Trog::DataModule::validate($post) ], [], "no spurious type error" );
    ok( !exists $post->{servings}, "the blank number is dropped" );
    is( $post->{title}, '', "a blank string field is left exactly as it was before any of this was typed" );
};

subtest 'the custom types actually bite' => sub {
    set_sidecars();

    my ($bad) = Trog::DataModule::validate( { title => 'x', callback => 'Some::Random::Sub' } );
    like( $bad, qr/cannot be loaded/, "a callback naming a module that isn't there is refused" );

    is_deeply(
        [ Trog::DataModule::validate( { title => 'x', callback => 'Trog::Routes::HTML::posts' } ) ],
        [],
        "a real one is fine"
    );
};

subtest 'add() rejects a post that does not validate' => sub {
    set_sidecars( 'recipe.json' => sidecar( required => ['servings'], properties => { servings => { type => 'integer' } } ) );

    my $written;
    {
        no warnings qw{once};
        @TestData::ISA   = ('Trog::DataModule');
        *TestData::get   = sub { return () };
        *TestData::write = sub { $written = $_[1]; return 0 };
    }

    my $why = exception {
        bless( {}, 'TestData' )->add( { form => 'recipe.tx', title => 'Cookies', visibility => 'public' } );
    };
    is( ref $why, 'ARRAY', "it dies with the error list, not a string" );
    like( join( ' ', @$why ), qr/servings/, "which names the offending field" );

    # A string die would come back wearing a Carp::Always stack trace, which is
    # no use at all to whoever just submitted the form.
    unlike( join( ' ', @$why ), qr/DataModule\.pm line/, "and carries no stack trace" );
    ok( !$written, "nothing was written" );

    bless( {}, 'TestData' )->add( { form => 'recipe.tx', title => 'Cookies', visibility => 'public', servings => '4' } );
    is( $written->[0]{servings}, 4, "the good one went through, coerced" );
};

subtest 'a post always ends up with a visibility' => sub {
    set_sidecars();

    my $written;
    {
        no warnings qw{once};
        @VisData::ISA   = ('Trog::DataModule');
        *VisData::get   = sub { return () };
        *VisData::write = sub { $written = $_[1]; return 0 };
    }

    # A post type built without a visibility selector submits none.  _process
    # pushes visibility into the tags, so an undef one puts an undef in there
    # and the post becomes invisible to everyone but an admin.
    bless( {}, 'VisData' )->add( { title => 'No Visibility', tags => ['sometag'] } );

    is( $written->[0]{visibility}, 'private', 'it defaults, rather than staying undef' );
    ok( !( grep { !defined $_ } @{ $written->[0]{tags} } ), 'so no undef finds its way into the tags' );

    bless( {}, 'VisData' )->add( { title => 'Explicit', visibility => 'public', tags => ['sometag'] } );
    is( $written->[0]{visibility}, 'public', 'and an explicit one is left alone' );
};

subtest 'a save message never becomes a URL' => sub {

    # The whole shape of the bug: a write that failed deep in File::Slurper,
    # decorated by Carp::Always with the entire call stack, went into the
    # redirect URL as a query parameter.  The result was several thousand
    # characters, and tPSGI answered its own redirect with a 419 -- so the user
    # saw neither the page they saved from nor the error.
    my $realistic = "Couldn't rename data/dnZHxmlXE5 to data/files/: Not a directory at /opt/perl5/lib/File/Slurper/Temp.pm line 56.\n" . "\tFile::Slurper::Temp::write_text(\"data/files/\", \"[{...}]\") called at /opt/perl5/lib/File/Slurper/Temp.pm line 63\n" . ( "\tTrog::Routes::HTML::post_save(HASH(0x5e798a626570)) called at lib/TCMS.pm line 130\n" x 40 );

    my $short = Trog::Routes::HTML::_short_error($realistic);
    unlike( $short, qr/\n/,       'the trace is gone' );
    unlike( $short, qr/line \d+/, 'and so is the file and line Perl glued on' );
    like( $short, qr/^Couldn't rename data/, 'leaving what actually went wrong' );

    my $cookie = Trog::Routes::HTML::_feedback_cookie( 1, $realistic );
    ok( length($cookie) < 2048, 'even the whole untrimmed thing fits in a cookie' )
      or diag( 'cookie was ' . length($cookie) . ' bytes' );
    like( $cookie, qr/^tcmsfeedback=1:/, 'flagged as a failure' );
    like( $cookie, qr/HttpOnly/,         'and not readable by script, since nothing needs to' );
    like( $cookie, qr/Max-Age=\d+/,      'and does not outlive the message it carries' );

    # One line, because the banner puts it in a JS string literal.
    my ($value) = $cookie =~ m/^tcmsfeedback=1:([^;]*)/;
    unlike( URI::Escape::uri_unescape($value), qr/\n/, 'the message is one line' );

    # Round trips.
    my ( $failure, $message ) = Trog::Routes::HTML::_feedback_from_cookie($cookie);
    is( $failure, 1, 'the outcome comes back out' );
    like( $message, qr/^Couldn't rename/, 'and so does the message' );

    ( $failure, $message ) = Trog::Routes::HTML::_feedback_from_cookie( Trog::Routes::HTML::_feedback_cookie( 0, "Saved post 'Thing'." ) );
    is( $failure, 0,                     'a success comes back as one' );
    is( $message, "Saved post 'Thing'.", 'with its message intact' );

    # And nothing at all when there is no cookie to read.
    is_deeply( [ Trog::Routes::HTML::_feedback_from_cookie('') ],                 [], 'no cookies, no feedback' );
    is_deeply( [ Trog::Routes::HTML::_feedback_from_cookie('other=thing') ],      [], 'nor other cookies' );
    is_deeply( [ Trog::Routes::HTML::_feedback_from_cookie('tcmsfeedback=xyz') ], [], 'nor one that is malformed' );
};

subtest '_wizard_fields zips the parallel arrays' => sub {

    # The middle row was left blank.  Dropping it must not shift the type of
    # the row after it -- this is the whole reason param_required is a select.
    my $fields = Trog::Routes::HTML::_wizard_fields(
        {
            param_name        => [ 'Servings', '',     'cook_time', 'id',   'servings' ],
            param_type        => [ 'number',   'text', 'textarea',  'text', 'text' ],
            param_label       => [ 'Servings', '',     'Cook Time', 'ID',   'Dupe' ],
            param_placeholder => [ '4',        '',     '45 min',    '',     '' ],
            param_required    => [ 1,          0,      0,           0,      0 ],
        }
    );

    is( scalar @$fields,        2,           "blank, core-shadowing and duplicate rows are dropped" );
    is( $fields->[0]{name},     'servings',  "names are lowercased" );
    is( $fields->[0]{required}, 1,           "required survives" );
    is( $fields->[1]{name},     'cook_time', "the row after the blank one is still present" );
    is( $fields->[1]{type},     'textarea',  "...with its own type, not the blank row's" );
};

subtest '_wizard_sidecar emits a usable OpenAPIv3 schema' => sub {
    my $spec = Trog::Routes::HTML::_wizard_sidecar(
        'recipe',
        [
            { name => 'servings', type => 'number',   label => 'Servings', placeholder => '4', required => 1 },
            { name => 'vegan',    type => 'checkbox', label => 'Vegan?',   placeholder => '',  required => 0 },
        ],
        ['inc_tags'],
        'form_common.tx',
    );

    is( $spec->{type},                       'object',  "it's an object schema" );
    is( $spec->{properties}{servings}{type}, 'integer', "a number input is an integer" );
    is( $spec->{properties}{vegan}{type},    'boolean', "a checkbox is a boolean" );
    is_deeply( $spec->{required}, ['servings'], "only the required rows are required" );

    # UI metadata rides along on x- keys so there's only one file to keep in sync.
    is( $spec->{properties}{servings}{'x-tcms-label'},       'Servings', "labels are kept" );
    is( $spec->{properties}{servings}{'x-tcms-placeholder'}, '4',        "so are placeholders" );
    ok( !exists $spec->{properties}{vegan}{'x-tcms-placeholder'}, "but an empty placeholder isn't written out" );
    is_deeply( $spec->{'x-tcms-post-type'}{includes}, ['tags.tx'], "the includes are recorded for regeneration" );
};

subtest 'a type records what the wizard was told, where the validator cannot see it' => sub {
    my $fields = [
        {
            name     => 'cook_time', type => 'text', label => 'Cook Time', placeholder => '45 minutes',
            required => 1, private => 0, indexed => 1, relation_form => '', relation_mode => 'one',
        },
        {
            name     => 'everything', type => 'relation', label => '', placeholder => '',
            required => 0, private => 0, indexed => 0, relation_form => 'blog.tx', relation_mode => 'all',
        },
    ];

    my $spec = Trog::Routes::HTML::_wizard_sidecar(
        'recipe', $fields, ['inc_tags'], 'form_common.tx', '',
        {
            description       => 'A recipe, with its cook time.',
            display           => '<div class="r"><: $post.cook_time :></div>',
            title_placeholder => 'Bread',
            wrapper           => 1,
            inc_post_title    => 1,
            inc_post_tags     => 0,
        }
    );

    my $type = $spec->{'x-tcms-post-type'};
    is( $type->{description},       'A recipe, with its cook time.',              'the description is recorded' );
    is( $type->{display},           '<div class="r"><: $post.cook_time :></div>', 'and the display template' );
    is( $type->{title_placeholder}, 'Bread',                                      'and the title placeholder' );
    ok( $type->{wrapper},        'and the checkboxes which are not includes' );
    ok( $type->{inc_post_title}, 'all of them' );
    ok( !$type->{inc_post_tags}, 'including the ones that were clear' );

    # The point of putting it there: schema_for() keeps properties and required
    # and nothing else, so none of this can affect whether a post validates.
    set_sidecars( 'recipe.json' => JSON::MaybeXS::encode_json($spec) );
    my $schema = Trog::DataModule::schema_for('recipe.tx');
    ok( !exists $schema->{'x-tcms-post-type'},   'and the validator never sees any of it' );
    ok( exists $schema->{properties}{cook_time}, 'while the fields it does care about are there' );

    is_deeply( [ Trog::DataModule::validate( { form => 'recipe.tx', title => 'x', cook_time => '45 minutes' } ) ], [], 'so a post of the type still saves' );
};

subtest 'a type reads back as the form that made it' => sub {
    my $spec = Trog::Routes::HTML::_wizard_sidecar(
        'recipe',
        [
            {
                name     => 'cook_time', type => 'number', label => 'Cook Time', placeholder => '45',
                required => 1, private => 0, indexed => 1, relation_form => '', relation_mode => 'one',
            },
            {
                name     => 'secret_note', type => 'textarea', label => 'Note', placeholder => '',
                required => 0, private => 1, indexed => 0, relation_form => '', relation_mode => 'one',
            },
            {
                name     => 'picked', type => 'relation', label => 'Picked', placeholder => '',
                required => 0, private => 0, indexed => 0, relation_form => 'blog.tx', relation_mode => 'one',
            },
            {
                name     => 'everything', type => 'relation', label => '', placeholder => '',
                required => 0, private => 0, indexed => 0, relation_form => 'entities.tx', relation_mode => 'all',
            },
        ],
        [qw{inc_preview inc_tags}],
        'form_multi.tx',
        'Trog::DataSource::Virt',
        {
            description       => 'What it is for.',
            display           => '<div>x</div>',
            title_placeholder => 'Bread',
            wrapper           => 1,
            inc_post_title    => 0,
            inc_post_tags     => 1,
        }
    );
    set_sidecars( 'recipe.json' => JSON::MaybeXS::encode_json($spec) );

    my $types = Trog::Routes::HTML::_wizard_types( ['recipe.tx'] );
    my $back  = $types->{'recipe.tx'};

    is( $back->{name},              'recipe',                 'the name comes back without the extension' );
    is( $back->{description},       'What it is for.',        'the description comes back' );
    is( $back->{display},           '<div>x</div>',           'and the display' );
    is( $back->{body_form},         'form_multi.tx',          'and which body form' );
    is( $back->{datasource},        'Trog::DataSource::Virt', 'and the datasource' );
    is( $back->{title_placeholder}, 'Bread',                  'and the placeholder' );
    is( $back->{wrapper},           1,                        'the ticked boxes come back ticked' );
    is( $back->{inc_post_title},    0,                        'the clear ones clear' );
    is( $back->{inc_post_tags},     1,                        'individually' );
    is( $back->{inc_preview},       1,                        'and the includes are recovered from the list' );
    is( $back->{inc_tags},          1,                        'all of them' );
    is( $back->{inc_aliases},       0,                        'and only them' );

    my %by_name = map { $_->{name} => $_ } @{ $back->{fields} };
    is( scalar( keys %by_name ), 4, 'every custom field comes back' );

    is( $by_name{cook_time}{type},       'number',    'with the input it was given' );
    is( $by_name{cook_time}{label},      'Cook Time', 'its label' );
    is( $by_name{cook_time}{required},   1,           'whether it was required' );
    is( $by_name{cook_time}{indexed},    1,           'and whether it was indexed' );
    is( $by_name{secret_note}{private},  1,           'a private field says so' );
    is( $by_name{picked}{type},          'relation',  'a relation says so' );
    is( $by_name{picked}{relation_form}, 'blog.tx',   'naming its target' );
    is( $by_name{picked}{relation_mode}, 'one',       'and that it picks one' );

    # This one stores nothing, so it has no property to be found by -- it exists
    # only as a relations entry, and would be lost without looking there.
    is( $by_name{everything}{relation_mode}, 'all',         'a pick-everything relation comes back too' );
    is( $by_name{everything}{relation_form}, 'entities.tx', 'naming its target' );

    # And nothing from the base post schema, which was never a wizard field.
    ok( !exists $by_name{title},      'the base schema fields are not offered as custom ones' );
    ok( !exists $by_name{visibility}, 'any of them' );
};

subtest 'the types are handed to the page as JSON it cannot break out of' => sub {
    no warnings qw{once};

    my $spec = Trog::Routes::HTML::_wizard_sidecar(
        'nasty', [], [], 'form_common.tx', '',
        { description => 'ends a script </script><script>alert(1)</script>', display => '<div>markup</div>' }
    );
    set_sidecars( 'nasty.json' => JSON::MaybeXS::encode_json($spec) );

    my $json = Trog::Routes::HTML::_wizard_types_json( ['nasty.tx'] );
    unlike( $json, qr/</, 'no bare < survives, so the script element cannot be closed early' );

    my $back = JSON::MaybeXS::decode_json($json);
    like( $back->{'nasty.tx'}{description}, qr{</script>}, 'while the text itself is intact once parsed' );
    is( $back->{'nasty.tx'}{display}, '<div>markup</div>', 'and so is the display template' );

    # A description is free text, but it still goes in a file.
    my $long = Trog::Routes::HTML::_wizard_description( 'x' x 9000 );
    ok( length($long) <= $Trog::Routes::HTML::wizard_description_max, 'a very long description is capped' );
    is( Trog::Routes::HTML::_wizard_description(),                    '', 'and no description at all is empty rather than undef' );
    is( Trog::Routes::HTML::_wizard_description( [ 'an', 'array' ] ), '', 'as is one that is not a string' );
};

subtest 'a canned block declares what it collects, and the types including it get it' => sub {
    set_components(
        'preview.json' => sidecar(
            properties => {
                preview      => { type => 'string', 'x-tcms-label' => 'Preview Image' },
                preview_file => { type => 'upload', 'x-tcms-label' => 'Preview Image', 'x-tcms-input' => 'file' },
            }
        )
    );

    # What the wizard writes for a type with 'Preview image upload' ticked: the
    # block spliced into the template, and a sidecar naming only the field
    # somebody actually typed into the form.
    my $spec = Trog::Routes::HTML::_wizard_sidecar(
        'recipe',
        [
            {
                name     => 'cook_time', type => 'number', label => 'Cook Time', placeholder => '45',
                required => 0, private => 0, indexed => 0, relation_form => '', relation_mode => 'one',
            },
        ],
        [qw{inc_preview inc_visibility inc_acls}],
        'form_common.tx',
        '',
        { description => 'What it is for.', display => '', title_placeholder => '' },
    );

    set_sidecars(
        'recipe.json' => JSON::MaybeXS::encode_json($spec),
        'recipe.tx'   => qq|            : include "preview.tx";\n            : include "form_common.tx";\n|,
    );

    is_deeply(
        Trog::DataModule::includes_for('recipe.tx'),
        [qw{preview.tx form_common.tx}],
        "the blocks a type splices in are read out of the template it renders"
    );

    my $schema = Trog::DataModule::schema_for('recipe.tx');
    ok( exists $schema->{properties}{preview_file}, "a block's fields land in the schema of every type that includes it" );
    ok( exists $schema->{properties}{cook_time},    "alongside the ones the type declares itself" );

    # The whole point: validate() drops every field the schema doesn't describe,
    # so until the block said what it collects, a generated type threw away the
    # preview image its own editor had just uploaded.
    my $post = {
        form         => 'recipe.tx',
        title        => 'Bread',
        preview_file => { tempname => '/tmp/nope', filename => 'loaf.jpg' },
    };
    is_deeply( [ Trog::DataModule::validate($post) ], [], "a post carrying one still validates" );
    ok( exists $post->{preview_file}, "and keeps it rather than having it filtered away" );

    # A block never gets to overrule the type that borrows it, nor the base
    # schema -- see the merge order in schema_for().
    set_components( 'preview.json' => sidecar( properties => { preview => { type => 'integer' }, title => { type => 'integer' } } ) );
    $schema = Trog::DataModule::schema_for('recipe.tx');
    is( $schema->{properties}{title}{type}, 'string', "and it cannot redefine a base post field" );
};

subtest 'the wizard tells a canned field apart from one somebody typed in' => sub {
    set_components(
        'preview.json' => sidecar(
            properties => {
                preview      => { type => 'string' },
                preview_file => { type => 'upload' },
            }
        )
    );

    # A hand-written type: it declares the block's fields itself, the way every
    # stock form does, and records nothing about which blocks it includes.
    set_sidecars(
        'blog.json' => sidecar(
            properties => {
                preview      => { type => 'string' },
                preview_file => { type => 'upload' },
                video_href   => { type => 'string', 'x-tcms-input' => 'url', 'x-tcms-label' => 'Video' },
            }
        ),
        'blog.tx' => qq|        : include "preview.tx";\n        : include "form_common.tx";\n|,

        # And one which declares a field of the same name without including the
        # block -- a datasource fills this one in, so it really is the type's.
        'guests.json' => sidecar( properties => { preview => { type => 'string', 'x-tcms-label' => 'Console capture' } } ),
        'guests.tx'   => qq|        : include "post_title.tx";\n|,
    );

    my $types = Trog::Routes::HTML::_wizard_types( [ 'blog.tx', 'guests.tx' ] );

    is( $types->{'blog.tx'}{inc_preview}, 1, "the box for a block the template includes comes back ticked" );
    is_deeply(
        [ map { $_->{name} } @{ $types->{'blog.tx'}{fields} } ],
        ['video_href'],
        "and what that block collects is not offered back as a custom field"
    );

    is( $types->{'guests.tx'}{inc_preview}, 0, "a type which does not include the block has the box clear" );
    is_deeply(
        [ map { $_->{name} } @{ $types->{'guests.tx'}{fields} } ],
        ['preview'],
        "and keeps the field of that name, which is its own rather than the block's"
    );
};

subtest '_kolon_safe defuses template syntax' => sub {
    my $safe = Trog::Routes::HTML::_kolon_safe(qq{<: \$post.id :>\n: include "evil.tx";});
    unlike( $safe, qr/</,      "no angle brackets survive" );
    unlike( $safe, qr/[\r\n]/, "no newlines survive, so ':' can't start a directive" );
    is( Trog::Routes::HTML::_kolon_safe( [] ), '', "a repeated param can't sneak a ref through" );
};

done_testing();
