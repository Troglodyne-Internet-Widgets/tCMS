tCMS Design
===========

This document describes how tCMS is put together and, more importantly, *why* --
so that you can tell at a glance where your change belongs.

Read the [Readme](Readme.md) first for installation and the feature-by-feature
tour. This is the architecture behind it.

What tCMS is for
================

**Disintermediation from aggregators.**

Publishing something today usually means publishing it on somebody else's
property. The aggregator owns the URL, the audience, the ranking, the terms, and
the right to change any of them without telling you. Your content is the product
being sold, and you are renting access to people who already agreed to hear from
you.

tCMS exists so that the thing you publish lives at *your* domain, in *your*
database, under *your* rules, and so that standing that up is a day's work rather
than a project.

The obstacle has never been "can I host a blog". It is that real sites are not
blogs. A client wants invoices, or a photo gallery with EXIF, or a list of
virtual machines with a start button, or a recipe index with cook times, or a
paywalled newsletter, or all of those on one site. Every CMS handles the first
one, and every CMS makes the second one a plugin project.

So the design goal is narrower and more useful than "a CMS":

> **Make a new content type cheap enough that building the client the thing they
> actually asked for is faster than talking them out of it.**

That is the bet the whole architecture is placed on. If you are a Perl contractor
holding a statement of work, the question you should be able to answer in minutes
is "what does a `Widget` post look like, and where does the Widget page come
from" -- and the answer should be a template, a small JSON file, and nothing
else.

The one idea
============

**Everything is a post.**

Not "everything is a post, plus pages, plus users, plus categories, plus
settings". Everything:

| The thing | Is a post |
|---|---|
| A blog entry | tagged with its series, `form` is `blog.tx` |
| A page | a post whose `local_href` is where you want it |
| A user profile | a post tagged `about`; the user *is* their profile page |
| A category / section | a "series" post, which owns an ACL and names its children's type |
| A virtual machine | a post, built on demand by a datasource, never stored |

A post is a JSON object. It has a handful of fields every post has -- `id`,
`title`, `data`, `tags`, `created`, `version`, `visibility`, `local_href`,
`callback` -- and then whatever else its type says it has.

Two consequences fall out of that, and most of the system is downstream of them.

**The routing table is data, not code.** Every post carries a `local_href` and a
`callback`. At startup, `TCMS::_routes` asks the data model for every post and
builds the routing table out of them, then merges the static routes from
`Trog::Routes::HTML`, `Trog::Routes::JSON` and the active theme over the top.
Publishing a post creates a URL because the URL *is* a field on the post. There
is no separate router config to keep in sync, and no rewrite rules.

**Adding a content type does not require touching Perl.** A post type is a
template that says how to display and edit it, plus a JSON sidecar that says what
fields it has. Both are files in a directory. See [Post types](#post-types).

The request lifecycle
=====================

tCMS is a routing module, not a server. It is run by **tPSGI**, which owns the
socket, the process model, the access log and the static file cache. tPSGI hands
each request to the callback tCMS registered for that route, and hands the
callback a `tpsgi` object for the things only the server can do -- redirect,
forbid, invalidate cached renders, run work after the response is closed.

```
  tPSGI
    │  route lookup against the table TCMS built at startup
    ▼
  TCMS::build_routes' wrapper          ← identity, ACLs, logging context
    │
    ▼
  Trog::Routes::HTML::<callback>       ← e.g. series() → posts() → index()
    │
    ├──▶ Trog::Data->new(config)       ← the data model: get() the posts
    │      └──▶ Trog::DataSource       ← unless this type's posts are built, not stored
    │
    ├──▶ _enrich_post                  ← resolve declared relations, run enrich subs
    │
    ▼
  Trog::Renderer->render(...)          ← picks a renderer by content type
    │      └──▶ Text::Xslate           ← templates, with component() and render_it()
    ▼
  [ code, headers, body ]              ← a PSGI triplet
    │
    └──▶ tpsgi->save_render(...)       ← if this page is cacheable, write a static
```

The wrapper installed by `TCMS::build_routes` is where a request stops being
anonymous bytes and becomes a request by somebody:

1. Initialise logging into tPSGI's log directory.
2. If `config/setup` does not exist, this is a fresh install -- everything goes
   to the setup route.
3. Pull the `tcmslogin` cookie, resolve it to a user, load that user's ACLs into
   `$query->{user_acls}`.
4. Strip an `admin` ACL from anything the *request* asked for unless the user
   actually holds it.
5. Refuse the request if the route requires auth and nobody is logged in.

Everything downstream reads `$query->{user_acls}` and never asks who the user is
again.

The static render cache
-----------------------

`Trog::Renderer::render` hands finished pages back to tPSGI to save as static
files, but only when caching one is safe. It skips when the render is a
component, when the route says `nocache`, when there is no route to key on, when
the request had a query string, **when a user is logged in**, when the status is
not 200, or when running at debug level.

That last-but-two is the important one: a logged-in reader sees `/secure/...`
variants and editing chrome, and caching those would serve one user's view to
another. Anonymous readers get files off disk; editors get live renders. Saving a
post invalidates the cache.

`nocache` is read off both the render options and the page data, so a route's
`nocache` flag -- which `TCMS::build_routes` puts on the query -- reaches it
whether or not the route thought to forward it. That is also how a datasource
which cannot say when its posts go stale keeps its pages out of the cache.

Post types
==========

This is the extension point that matters, so it gets the most detail.

A post type is two files in `www/templates/html/components/forms/`:

    blog.tx      the template: how a post of this type displays, and how it edits
    blog.json    the sidecar: an OpenAPIv3 object schema for its fields

`Trog::DataModule::schema_for` merges the sidecar with the base post schema and
uses the result to validate every save. The base schema is merged **last**, on
purpose: a sidecar can add fields but can never redefine a core one. A sidecar
retyping `callback` as a plain string would defeat the check that the sub it
names actually exists, which is a privilege problem rather than a cosmetic one.

The sidecar carries the wizard's own UI metadata on `x-` extension keys, so there
is one file to keep in sync rather than two:

| Key | Means |
|---|---|
| `x-tcms-label`, `x-tcms-placeholder` | what the editor shows for this field |
| `x-tcms-input` | which widget to render |
| `x-tcms-private` | editors only -- the value is dropped before rendering, so no template mistake can leak it |
| `x-tcms-indexed` | give this field its own indexed column, where the data model can |
| `x-tcms-relation-form` | this field holds another post's UUID |
| `x-tcms-relations` | what to resolve onto the post at render time |
| `x-tcms-datasource` | these posts are built by a module, not stored |
| `x-tcms-post-type` | the type's own name and description |

You do not have to write either file by hand. **The Post Type Wizard**
(`/admin/wyzzerdd`) generates both from a form: name the fields, pick their
types, tick whether each is required, editors-only, or indexed, and write the
display snippet. It writes the template and the sidecar into whichever forms
directory is in use -- the theme's if it has one, the stock one otherwise -- and
the type is live on the next request. No restart: `themed_templates_in_dir`
re-reads the directory every call and Xslate resolves includes lazily.

The generated template is ordinary Kolon, so hand-editing it afterwards is
expected and fine. Regenerating the type overwrites it, which is why the wizard
says so at the top of what it writes.

Series, and how content is organised
------------------------------------

A **series** is a post of type `series.tx` that does two jobs:

- It **owns an ACL**. Its `aclname` is the tag its children carry, so "who may
  read this section" is one field on one post.
- It **names its children's type** via `child_form`. A series of `invoice.tx`
  lists invoices; the same site's series of `blog.tx` lists blog entries.

Tag a series `topbar` and it appears in the site navigation. That is the whole
of "site structure" -- there is no menu editor, because the menu is a query.

Visibility and ACLs
-------------------

`visibility` is one of `public`, `unlisted`, `private`. `Trog::DataModule::_process`
folds it into the post's `tags`, along with the post's ACLs when it is private,
and then deletes the separate `acls` field. **Tags are the whole truth about who
may see a post**, which is why `get()` answers the `acls` filter by looking at
tags and nothing else.

Know this before you touch anything that filters. A change that makes tags and
ACLs diverge is a disclosure bug, not a refactor.

Storage: data models
====================

A data model is where posts live. `Trog::Data` is a factory; the implementation
is chosen by `general.data_model` in the config.

`Trog::DataModule` is the base class and provides the query semantics -- `get()`,
`filter()`, `paginate()`, version rollup, validation, and the derived-field
plumbing in `_process`. A subclass must implement `read`, `write`, `count`,
`tags`, `lang` and `help`, and may override `get` if it can answer a query more
directly than by filtering in Perl.

| Model | What it is | Use it when |
|---|---|---|
| `DUMMY` | one JSON blob | never in production; it is not race-safe. It exists as the smallest possible worked example of the interface |
| `FlatFile` | one file per post, SQLite alongside as a tag index | you want the posts to be greppable files on disk, and the site is small |
| `SQLite` | posts in SQLite, blob and all | anything else |

Posts are **versioned**. A save appends a version rather than overwriting, and
`get()` hands back the newest one, carrying `version_max` plus the original
`created` and `author` from the first version. Asking for a specific `version`
gets that one.

The SQLite model is worth understanding as a pattern, because it is the shape a
new model should copy: it stores the same JSON blob the flat file model would
have written and projects everything worth querying back out of it as
`GENERATED ALWAYS ... VIRTUAL` columns. The blob stays the single source of
truth, the projections cost no storage and cannot drift from it, and adding a
queryable field is an `ALTER TABLE` plus a `CREATE INDEX` with no migration --
because the data never moves. Tag membership needs one row per tag, so triggers
unpack `json_each` into an index table; search is FTS5 with the trigram
tokenizer, which is the one tokenizer that answers the substring queries the
search box has always meant.

Foreign authority: data sources
===============================

Sometimes the authoritative copy of something is not yours and never will be. A
hypervisor knows what guests exist; a payment processor knows what was paid; an
LDAP directory knows who works here. Copying that into the datastore means it is
wrong the moment you copy it.

A **datasource** lets a post type say "my posts are built, not stored". The
series is still an ordinary post; only its children are synthesized, and they are
rebuilt on every view.

    "x-tcms-datasource": "Trog::DataSource::Virt"

The module provides `posts($series, $query)` and may provide `filter`, `order`,
`lang`, `help` and `EDITABLE`. `Trog::DataSource` documents the whole contract
and supplies the defaults.  `Trog::DataSource::DirIndex` is the shortest complete
example: a directory becomes a listing, with a hard constraint on which
directories it will look at and an inotify watch so the cached page is thrown
away when the directory changes.

Two things about the contract are worth knowing before you write one, because
both are places the obvious implementation is wrong:

- **Your posts have never been near the datastore**, so nothing has filtered
  them. The reader's search was answered against the datastore and thrown away
  along with the posts it filtered. `filter()` is how the search reaches your
  posts, and you should implement it if your posts carry anything worth
  searching beyond a title.
- **Nothing else will invalidate your page's static render.** A post being saved
  does not invalidate it, because no post was saved -- the thing you depend on
  changed instead. So you must answer one of two ways. Either you can name what
  you depend on, in which case register a `$tpsgi->add_watch` for it with a
  stable `key`, invalidate through the tPSGI object your callback is *handed*
  rather than the one it closed over, and declare `CACHEABLE`
  (`DirIndex::_watch` is four lines of this). Or you cannot, in which case say
  nothing and your pages are never cached -- which is the default, because a
  page that is merely slow beats one that is wrong with no way of becoming
  right.
- **Your posts probably all share a timestamp**, because you stamped them with
  the time you built them. Stored posts paginate by a `created` cursor, which on
  such a page cannot move -- every cursor is the same instant. Datasource pages
  therefore paginate by page number, which is why `order()` has to be total: page
  2 of a shuffled list is a lottery.

Rendering
=========

`Trog::Renderer->render(%options)` dispatches on content type to a renderer under
`Trog::Renderer::`, all of which subclass `Trog::Renderer::Base`. The known types
are in `Trog::Vars::%content_types`: text, html, json, blob, xml, xsl, css, rss,
email. (`Trog::Renderer::javascript` exists but is not registered in the
dispatcher.)

Base sets up the Xslate instance, resolves templates against the theme's
directory and then the stock one, and injects two functions every template can
call:

- `render_it($string)` -- render a template string that came out of a post, which
  is what lets a post body contain `<: embed(12345, 'embed') :>`.
- `component('Name', {...})` -- render a `Trog::Component`.

Components
----------

A component is a module in `Trog::Component` with a `render(%args)` returning a
string. Templates ask for what they want by name rather than having a route
render it and thread the string through:

    <: component('EmojiPicker') :>
    <: component('Gallery', { album => $post.id, cols => 3 }) :>

The page furniture is built this way -- `Header`, `Footer`, `HtmlTitle`,
`MidTitle`, `TopBar`, `LeftBar`, `RightBar`, `FootBar`, `CategoryBar` are what
`index.tx` is made of. Each module owns the name of the template it renders, so
adding a piece of furniture does not mean editing a route.

One caution if you write one: Xslate catches an exception thrown out of a
template function, warns, and renders on with an empty string where the call was.
A component that merely dies would vanish from the page with a line on stderr to
show for it, so `Trog::Component` also records the failure for `Renderer::Base`
to turn into a 500.

Themes
------

A theme is a directory under `www/themes/` mirroring the structure of `www/`.
Templates resolve against the theme's directory first and the stock one second,
so a theme overrides individual templates without forking the ones next to them.
Stylesheets are the exception and are loaded both, theme last, so a theme can
override a handful of rules without restating the sheet. A theme may ship a
`routes.pm` to add routes of its own.

Composition: relations and enrichment
=====================================

Types need to refer to each other -- an invoice has a payee and a payor, which
are `entities` posts. A type declares that in its sidecar and
`Trog::Routes::HTML::_enrich_post` resolves it at render time:

- an entry naming a `from` field resolves the UUID in that field into the post it
  refers to;
- an entry without one pulls in *every* post of the target type, which is what an
  editor's picker or a "show me all of these" display wants.

Resolution is memoised per request, or a page of twenty-five invoices rescans
every entities post twenty-five times.

When a type needs something computed rather than merely fetched, it gets an
enrich sub -- see `Trog::Enrich::Invoice`, which sums a multi-page invoice's line
items into a total.

Identity, configuration, operations
===================================

**Auth** (`Trog::Auth`) is an SQLite database at `config/auth.db` holding hashed
and salted passwords, ACLs and sessions. A session is the `tcmslogin` cookie.

The webserver participates. `/authenticated` answers 200 for a request carrying a
live session and 403 otherwise, and exists so that nginx can `auth_request`
against it -- which is how private uploads under `www/assets/private` are gated
without tCMS being in the path of the file itself. That protection is real and it
is invisible from inside the application, so code that reasons about what is
reachable should not assume it and should not try to replace it.
TOTP two-factor is supported. The first user to register becomes the
administrator and registration then closes; further users are made by an admin
through the `about` post type -- because a user *is* their profile page.

**Config** (`Trog::Config`) is a thin wrapper over `Config::Simple` reading
`config/main.cfg` and falling back to the shipped `config/default.cfg`. It is
memoised, so a config change signals the workers to restart.

**Logging** (`Trog::Log`) goes to a rotating file, to the screen at error level
and above -- which is what reaches the webserver's log -- and to SQLite via
`Trog::Log::DBI`, which is what `Trog::Log::Metrics` later reads time series out
of. Log lines start with an ISO8601 date because fail2ban parses them; do not
change that. UTM parameters are captured per request, so the analytics are yours
too.

**Deployment** is tPSGI behind nginx. See the Readme for development, and the
`trog-provisioner` recipes (`tcms`, `tpsgi`, `nginxproxy`) for production --
several features want the configuration encoded there.

Where does my change go?
========================

The contractor's cheat-sheet.

| I need... | Do this | Perl required |
|---|---|---|
| A new kind of content | Post Type Wizard, or write `foo.tx` + `foo.json` by hand | none |
| A field on an existing type | edit its sidecar; the editor and validator follow | none |
| That field to be searchable/filterable fast | tick "Index this field" in the wizard | none |
| A field only editors may see | `x-tcms-private` in the sidecar | none |
| One type to refer to another | `x-tcms-relations` in the sidecar | none |
| A new section of the site | make a series post; tag it `topbar` for the nav | none |
| To restrict a section | give the series an ACL; grant it to users | none |
| A different look | a theme directory; override the templates you care about | none |
| A reusable chunk of UI | `Trog::Component::Whatever` with `render(%args)` | a little |
| A page listing a directory of files | a series with a directory + a wizard type using `DirIndex` | none |
| Content from an external system | `Trog::DataSource::Whatever` with `posts($series,$query)` | some |
| To extend one that exists | subclass it; `can()` resolves through `@ISA`, so override only what differs (`ProvisionedVirt` does this to `Virt`) | some |
| A computed field on a type | an enrich sub, as `Trog::Enrich::Invoice` does | some |
| A route that is not a post | add to `%Trog::Routes::HTML::routes`, or a theme's `routes.pm` | some |
| A different place to keep posts | subclass `Trog::DataModule` | most |
| A new output format | a `Trog::Renderer::` subclass, registered in `Trog::Renderer` | most |

Things that will bite you
=========================

Hard-won, and none of them obvious from reading the code that contains them.

- **Tags carry visibility and ACLs.** `_process` folds them in and deletes the
  separate field. Anything that filters on tags is a security boundary.
- **`get(id => ...)` deliberately skips the ACL filter.** `filter()` returns early
  for an `id`, `title` or `aclname` query, because that is how `add()` asks
  whether a post already exists. Do not "fix" it without reading every caller.
- **Validation runs on what was submitted; `_process` then builds what gets
  stored.** Both are checked now (`validate` and `validate_built`), and they
  check different objects. A field that only exists after `_process` will not be
  in the first one.
- **The FlatFile model caches its tag list at load time** and filters each query's
  tags against it *in place*. A tag created later is not merely unindexed, it is
  deleted from the query. Production survives this because a save re-execs the
  workers; anything long-lived doing its own reads has to refresh it by hand.
- **Sidecar schemas are cached on the forms directory's mtime.** Writing a
  sidecar and reading it back in the same process is fine; the resolution is
  sub-second, but the cache is real.
- **A component that fails must be recorded, not merely thrown.** See above.
- **Never `use` `Trog::Renderer` from `Trog::Component`.** `Renderer::Base` uses
  `Trog::Component`; the cycle is why components load lazily.

Testing
=======

`prove -l t/`. The suite is `Test::More` with `Test::MockModule` and
`Test::Fatal`.

The one to know about is `t/Trog-Routes-HTML-series-lifecycle.t`, which stands up
a genuinely fresh tCMS in a temp directory and walks what a user actually does:
register an admin, invent a post type in the wizard, build a series of every
content type, add children, and confirm each renders. It asserts the repository
itself was not touched, which is the only real proof of isolation.

It is parameterised by `TCMS_TEST_DATA_MODEL` and runs against every data model,
because **a data model is only finished when the application cannot tell which
one it is talking to.** If you add a model, that is the test that says whether
you are done.
