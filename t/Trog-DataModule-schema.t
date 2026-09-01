use strict;
use warnings;

use Test::More;
use Test::MockModule qw{strict};
use Test::Deep;
use Test::Fatal qw{exception};
use JSON::MaybeXS();
use Path::Tiny();
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

my $slurpmock = Test::MockModule->new('File::Slurper');
$slurpmock->redefine( 'read_text', sub { $sidecars{ Path::Tiny::path(shift)->basename } } );

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

subtest '_kolon_safe defuses template syntax' => sub {
    my $safe = Trog::Routes::HTML::_kolon_safe(qq{<: \$post.id :>\n: include "evil.tx";});
    unlike( $safe, qr/</,      "no angle brackets survive" );
    unlike( $safe, qr/[\r\n]/, "no newlines survive, so ':' can't start a directive" );
    is( Trog::Routes::HTML::_kolon_safe( [] ), '', "a repeated param can't sneak a ref through" );
};

done_testing();
