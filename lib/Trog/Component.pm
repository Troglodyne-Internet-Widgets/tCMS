package Trog::Component;

use v5.36;
use re '/aa';

use Text::Xslate ();

=head1 Trog::Component

Dispatcher for the UI components living under the Trog::Component namespace.

Injected into the template processor as component() by Trog::Renderer::Base, so
templates ask for what they want rather than having a route thread a rendered
string into their data hash:

    <: component('EmojiPicker') :>
    <: component('Gallery', { album => $post.id, cols => 3 }) :>

Deliberately depends on nothing but Text::Xslate.  Trog::Renderer::Base uses
this module, and components use Trog::Renderer, so anything heavier here would
close a compile-time load cycle.  Components are loaded lazily, at call time,
for the same reason.

=head1 Termination Conditions

Dies if the component can't be named, found, loaded or rendered.  There is no
sensible half-rendered page.

Dying is necessary but not sufficient: Xslate catches exceptions thrown out of a
function call, hands them to its warn handler, and carries on with an empty
string where the call was -- so a broken component would otherwise vanish from
the page with nothing but a line on stderr to say so.  The failure is therefore
also recorded in $Trog::Component::error, which Trog::Renderer::Base::render()
localises and checks, turning it into the 500 it deserves.

=head1 FUNCTIONS

=cut

# A component whose template asks for itself would otherwise recurse until the
# stack gives out, which says nothing about which component did it.
our $MAX_DEPTH = 10;
our $depth     = 0;

# The first component failure of the current render.  See above -- dying alone
# does not stop an Xslate render.  Always read through a local() in the caller.
our $error;

=head2 component($name, $args) = STRING

Render the named component, marked raw so that callers need no C<| mark_raw>.

$name is one flat namespace level under Trog::Component -- word characters only.
It becomes a path handed to require(), so this is what stops a template naming
its way out of Trog/Component/.

$args is an optional HASHREF, flattened into the component's render().  Nullary
components simply ignore it.

=cut

sub component ( $name, $args = {} ) {
    my ( $out, $err );
    {
        local $@;
        $out = eval { _component( $name, $args ) };
        $err = $@;
    }
    return $out if defined $out;

    # Record as well as rethrow: the die on its own gets swallowed by Xslate.
    # First failure wins, as the ones after it tend to be consequences of it.
    # The throw uses our own error rather than $error, so a direct caller is
    # told what *it* did even when something earlier left a record behind.
    $err ||= "Component '$name' failed for no stated reason\n";
    $error //= $err;
    die $err;
}

sub _component ( $name, $args ) {
    my $module = _load($name);

    die "Component '$name' recursed more than $MAX_DEPTH deep\n" if $depth >= $MAX_DEPTH;
    local $depth = $depth + 1;

    $args = {} unless ref $args eq 'HASH';

    my $out;
    local $@;
    eval {
        $out = $module->can('render')->(%$args);
        1;
    } or do {
        die "Component '$name' failed to render: $@";
    };

    # Trog::Renderer::render() answers failure with a PSGI triplet from _yeet(),
    # which is meaningless halfway through a template.  Catching it here is what
    # saves every call site from the 'return $it if ref $it eq ARRAY' dance.
    die "Component '$name' returned a " . ref($out) . " rather than a string\n" if ref $out;
    die "Component '$name' rendered nothing\n"                                  if !defined $out;

    return Text::Xslate::mark_raw($out);
}

=head2 render_template($template, $data) = STRING

Render a component template and hand back the body, for the many components
whose whole job is exactly that.

Dies naming the template if the render fails, rather than answering with the
PSGI triplet Trog::Renderer::render() produces on failure.

=cut

sub render_template ( $template, $data = {} ) {

    # Required rather than used, for the same reason components are loaded
    # lazily: Trog::Renderer::Base uses this module, so a compile-time use here
    # would close the cycle.  By the time anyone calls this it is already loaded.
    require Trog::Renderer;

    my $out = Trog::Renderer->render(
        contenttype => 'text/html',
        component   => 1,
        template    => $template,
        data        => $data,
    );

    die "Could not render component template '$template'\n" if ref $out;
    return $out;
}

# Resolved at call time rather than compile time, so that components are free to
# use Trog::Renderer without cycling back through us.  require() memoizes in
# %INC; %loaded only saves us the repeat eval and string munging.
sub _load ($name) {
    state %loaded;

    die "Component name must be given\n"   unless defined $name && length $name;
    die "Invalid component name '$name'\n" unless $name =~ m/^[A-Za-z][A-Za-z0-9_]*$/;

    my $module = "Trog::Component::$name";
    return $module if $loaded{$module};

    local $@;
    eval {
        require "Trog/Component/$name.pm";    ## no critic (RequireBarewordIncludes) -- $name is validated above
        1;
    } or do {
        die "Could not load component '$name': $@";
    };

    die "Component '$name' has no render()\n" unless $module->can('render');

    $loaded{$module} = 1;
    return $module;
}

1;
