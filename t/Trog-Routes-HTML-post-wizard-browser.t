#!/usr/bin/env perl

# Drives the post type wizard in a real browser, against a running tCMS.
#
# The "Start from" dropdown is two halves which nothing below the browser can
# check actually meet: post_wizard() writes every type that exists into the page
# as JSON, and fillFromType() in post_wizard.js applies the one you picked to the
# form.  A unit test can prove the JSON is right and still tell you nothing about
# what an admin sees, and what an admin sees is where every bug in this feature
# has lived so far.
#
# What is asserted is the state of the form after picking a type: which canned
# boxes are ticked, which body form is selected, and which rows turn up under
# Custom Fields.  The expectations below are the stock post types, read off the
# templates in www/templates/html/components/forms -- so a theme which overrides
# one of them will make this fail, which is why it is opt-in.
#
# Needs a running server and an admin to log in as, and skips without them:
#
#   TCMS_TEST_URL=http://localhost:5000 \
#   TCMS_TEST_USER=someadmin TCMS_TEST_PASS=hunter2 \
#     prove -Ilib t/Trog-Routes-HTML-post-wizard-browser.t
#
# playwright_server needs its node deps (uuid, playwright, express) somewhere
# node resolves them from -- its own directory, /usr/local/lib/node_modules, or
# NODE_PATH.  A global install under nvm is not one of those places.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;

my $URL  = $ENV{TCMS_TEST_URL} || 'http://localhost:5000';
my $USER = $ENV{TCMS_TEST_USER};
my $PASS = $ENV{TCMS_TEST_PASS};
my $TYPE = $ENV{TCMS_TEST_BROWSER} || 'firefox';

plan skip_all => 'set TCMS_TEST_USER and TCMS_TEST_PASS to run the browser tests' unless $USER && $PASS;

# Playwright checks its node deps in a BEGIN, so this is a require rather than a
# use: a kit that cannot start the server should skip rather than fail to
# compile.
eval { require Playwright; 1 } or plan skip_all => "Playwright will not load: $@";

# Every stock post type, as the wizard ought to read it back.  'boxes' is every
# checkbox the wizard offers; 'fields' is what should be left under Custom
# Fields once the canned blocks have been accounted for.
my %EXPECT = (
    'blog.tx' => {
        body   => 'form_common.tx',
        fields => [],
        boxes  => { wrapper => 1, inc_post_title => 1, inc_post_tags => 1, inc_preview => 1, inc_tags => 1, inc_aliases => 1, inc_attachments => 0 },
    },

    # The multi-page one: reopening it used to hand back form_common.tx, so
    # saving it again silently turned a slide deck into a single page.
    'presentation.tx' => {
        body   => 'form_multi.tx',
        fields => ['video_href'],
        boxes  => { wrapper => 1, inc_post_title => 1, inc_post_tags => 1, inc_preview => 1, inc_tags => 1, inc_aliases => 1, inc_attachments => 1 },
    },

    # No wrapper -- it opens with its own markup so it can tile -- and its avatar
    # upload is its own rather than preview.tx, so preview really is a field of
    # this type and should still be offered as one.
    'profile.tx' => {
        body   => 'form_common.tx',
        fields => [qw{contact_email display_name preview preview_file user_acls username wallpaper wallpaper_file}],
        boxes  => { wrapper => 0, inc_post_title => 1, inc_post_tags => 0, inc_preview => 0, inc_tags => 0, inc_aliases => 1, inc_attachments => 0 },
    },

    # A datasource type: built rather than written, so it has no editor at all,
    # and the preview it declares is a console capture of its own.
    'guests.tx' => {
        body   => 'form_common.tx',
        fields => [qw{preview hypervisors}],
        boxes  => { wrapper => 1, inc_post_title => 0, inc_post_tags => 0, inc_preview => 0, inc_tags => 0, inc_aliases => 0, inc_attachments => 0 },
    },
);

my @BOXES = qw{wrapper inc_post_title inc_post_tags inc_preview inc_tags inc_aliases inc_attachments};

# Locators throughout rather than select(): a select() hands back a handle to
# the element as it was at that moment, and the login page settles after
# 'networkidle' often enough that filling one raced with the DOM it came from.
# A locator resolves when it is acted on instead.
my $handle  = Playwright->new();
my $browser = $handle->launch( headless => 1, type => $TYPE );
my $page    = $browser->newPage();

END {
    eval { $page->close() }    if $page;
    eval { $browser->close() } if $browser;
    eval { $handle->quit() }   if $handle;
}

sub field_names {
    return $page->evaluate('return Array.from(document.querySelectorAll("#wizard-params input[name=param_name]")).map(function (i) { return i.value; });');
}

subtest 'an admin can reach the wizard' => sub {

    # Posted rather than typed into the login page.  The session lands in the
    # page's own cookie jar either way, and this keeps the test off a page it is
    # not about: on a successful login jsalert.tx schedules a window.location to
    # $to half a second after DOMContentLoaded, so the login form navigates out
    # from under anything still filling it in.
    my $res = $page->request->fetch(
        "$URL/auth",
        {
            method => 'POST',
            form   => { app => 'login', to => '', username => $USER, password => $PASS },
        }
    );
    is( $res->status(), 200, "logged in at $URL" ) or BAIL_OUT("no tCMS answering at $URL, or those credentials are wrong");

    $res = $page->goto( "$URL/admin/wyzzerdd", { waitUntil => 'networkidle' } );
    is( $res->status(), 200, 'the wizard renders' );

    is( $page->locator('#wizard-existing')->count(), 1, "the 'Start from' dropdown is there" )
      or BAIL_OUT("not logged in as an admin -- check TCMS_TEST_USER");
};

foreach my $form ( sort keys(%EXPECT) ) {
    subtest "picking $form fills the form in the way that type was built" => sub {
        my $expect = $EXPECT{$form};

        # Back to blank between types, so nothing here can pass on what the
        # previous type left in the form rather than on what this one says.
        $page->locator('#wizard-existing')->selectOption( { value => '' } );
        is_deeply( field_names(), [''], 'a blank pick leaves one empty custom field row' );

        $page->locator('#wizard-existing')->selectOption( { value => $form } );

        foreach my $box (@BOXES) {
            my $want = $expect->{boxes}{$box};
            my $got  = $page->locator(qq{#postTypeWizard [name="$box"]})->isChecked() ? 1 : 0;
            is( $got, $want, "$box is " . ( $want ? 'ticked' : 'clear' ) );
        }

        is( $page->locator('#postTypeWizard [name="body_form"]')->inputValue(), $expect->{body}, 'the body form is the one the type carries' );

        # Only the named rows are asserted: fillFromType() always leaves an
        # empty one behind to type the next field into, and a type with no
        # custom fields at all gets that row and nothing else.
        is_deeply(
            [ sort grep { length } @{ field_names() } ],
            [ sort @{ $expect->{fields} } ],
            'and only the fields somebody typed in are offered as custom ones'
        );

        # Saving under the same name is the point of picking one, and the save
        # is refused outright without this.
        ok( $page->locator('#postTypeWizard [name="overwrite"]')->isChecked(), 'overwrite is ticked for you' );
    };
}

done_testing();
