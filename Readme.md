tCMS
=====

A flexible perl CMS which supports multiple data models and content types.
Should be readily portable/hostable between any other system that runs tCMS due to being largely self-contained.

tCMS is built to be run by tPSGI.

Simple deployment is currently:
* make -f Installer.mk depend
* make -f Installer.mk install
* Setup tPSGI (supposing this clone is in a subdir tCMS of the tPSGI clone):

.tpsgi.conf :
```
http_user=www-data
user=INSERT_MY_USERNAME_HERE
domain=INSERT_MY_DOMAIN_NAME_HERE
routers=tCMS/lib/TCMS.pm
indices=
custom_log="/var/log/www/tpsgi.log"
basedir="tCMS"
```

Then:
* open tmux or screen
* `HOME=. bin/tpsgi -p 5001`

You won't want to run like this in production, but this is probably how you want to develop your themes
or hack on tCMS itself.

Production Deployment
====================

See trog-provisioner & related provisioners repository.

In the latter you will be interested particularly in:

- Provisioner::Recipe::tcms
- Provisioner::Recipe::tpsgi
- Provisioner::Recipe::nginxproxy

Many of the advanced features of tCMS won't work quite right without the configurations encoded therein.

Content Types
=============
Content templates are modular.
Add in a template to www/templates/html/components/forms which describe the content *and* how to edit it.
Our post data storage being JSON allows us the flexibility to have any kind of meta associated with posts, so go hog wild.

You describe the type of data provided in a sidecar JSON file alongside the form's template.
There's a wizard you can use to build these!

From there you make Series of the content type you want; tag the series with 'topbar' if you want it to show up in the top links.

Currently supported:
* Microblogs
* Blogs
* Files (Video/Audio/Images/Other)
* About Pages
* Presentations
Virtualization Data:
* Hypervisors
* Guests

Embedding Posts within other Posts
==================================

If you know a Post's ID (see the numbers at the end of it's URI when viewing it's permalink denoted by the chain emoji)
You can embed template logic into your posts like so:

```
<: embed(12345, 'embed') :>
```

The first parameter is the ID number of the post.
The second parameter is the formatting style:

* embed : default, shows the post with a recessed border as an excerpt.
* media : only show media portion of the post, if any.
* inline : show everything about the post, save for the title.

These will be added as classes to the embedded post, so you can theme this appropriately.

Data Models
===========
Posts are normally stored as a file somewhere.

* DUMMY - A JSON blob.  Used for testing mostly, but could be handy for very small sites.
* Flat File - Pretty much the tCMS1 data model, but with an SQLite index bolted on.
* SQLite - The posts themselves in SQLite, blob and all.

Pick one with general.data_model in your config.

The SQLite model stores each version of each post as the same JSON blob the flat
file model would have written, and projects everything worth querying back out of
it as GENERATED ALWAYS ... VIRTUAL columns, which cost no storage and cannot drift
from the post they came from.  Filtering, paging and search are then the
database's job rather than a grep over every post on disk -- on a 20,000 post
site, a search goes from about 2.5 seconds to about 3 milliseconds.  Search is an
FTS5 index built with the trigram tokenizer, so it keeps the case insensitive
substring matching the search box always had.

Adding a queryable field is one ALTER TABLE and one CREATE INDEX in
schema/sqlite.schema.  No migration, because the data itself never moves:

    ALTER TABLE posts ADD COLUMN subhead TEXT
        GENERATED ALWAYS AS (json_extract(post_data, '$.subhead')) VIRTUAL;
    CREATE INDEX posts_subhead ON posts(subhead);

For a post type's own custom fields you don't have to write that yourself: the
Post Type Wizard offers an "Index this field" checkbox per field, off by default,
and saving the type does the above for every field that has it ticked.  Untick it
and the index goes away again on the next save.  It is worth ticking for a field
you actually search or filter on, and not otherwise -- an index costs a little
on every save and some disk.

On a data model with no notion of an index the checkbox simply does nothing, so
the wizard doesn't have to know which model the site is running.

To move an existing flat file site over, run bin/migrate.pl from the tCMS root
and then set data_model=SQLite and restart.  It copies rather than moves, so
data/files is left alone and the way back is to set data_model back.  It is safe
to re-run -- run it once against the live site, then again after a final quiet
period to pick up whatever was written in between.  --dry-run tells you what it
would do.

Data Sources
============
Sometimes you want to consider something else authoritative that isn't a datamodel under our control.

* Virt - Talk to a libvirt HV to list guests.

A post type names one in its sidecar with x-tcms-datasource, and a series of that
type then lists whatever the source builds instead of posts somebody wrote.  The
series is still an ordinary post; only its children are synthesized, and they are
rebuilt on every view rather than stored.

A source has to provide posts($series, $query).  It may also provide:

* filter($query, @posts) - apply the reader's search to the posts it built.
  Those posts have never been near the datastore, so the search the reader typed
  would otherwise be answered against the datastore and then thrown away along
  with the posts it filtered.  Trog::DataSource::filter is the default, and
  searches a post's title and body; implement your own to search the fields your
  posts actually carry, as Virt does for a guest's name, state and hypervisor.
* order($query, @posts) - the order they belong in.  Defaults to newest first,
  then by title, then by id.  Pagination hands out page 2 of an order, so there
  has to be one and it has to be the same one next time somebody asks.
* lang() and help() - what the search box on such a page is searching, and where
  to read about it.  The data model's answer describes the datastore, which is
  not what these pages are serving.
* EDITABLE - whether the wizard should generate an editor for the type.  A source
  building its posts from somewhere else has nothing to edit, and saying nothing
  means no.

Such pages paginate by page number rather than by the created cursor stored posts
use.  A datasource has already built every post by the time the paginator sees
them, so there is nothing to save by paging with a cursor -- and it would not
work anyway for a source that stamps everything with the time it built them, as
libvirt guests are: every cursor on the page is the same instant, so Prev asks
for everything older than now and gets nothing.

See lib/Trog/DataSource.pm for the whole contract.

Components
==========
Sometimes you re-use a template a lot. Sometimes it also needs special handling.
This is when you write a 'component'.  Example:

Trog::Component::EmojiPicker -> renders www/templates/html/components/emojis.tx

A component is a module in the Trog::Component namespace with a render(%args)
method returning a string.  Templates call it by name:

    <: component('EmojiPicker') :>
    <: component('Gallery', { album => $post.id, cols => 3 }) :>

The optional hash is flattened into the component's render(); nullary components
ignore it.  Output comes back marked raw, so no | mark_raw is needed.  Routes
don't have to know a component exists -- the template asks for what it wants.

The page furniture is built this way: Header, Footer, HtmlTitle, MidTitle,
TopBar, LeftBar, RightBar, FootBar and CategoryBar are what index.tx is made of,
and PostHeader/PostFooter are the per-series header and footer posts.tx pulls in.

Ideas to come:
=============

*domain* picker at top -- manage all your web properties from one place

login and registration (forces email for a domain to allow posting on said domain)
User data *also* stored in ES -- it's their profile page!

Error and Access logs immediately dumped into ES for EZ viewing in grafana

Automatic analytics!

Multiple auth models (ldap, oauth etc)

Builtin paywall -- add in LDAP users not on primary domain, give differing privs
Have all content able to assign to paywall packages

One click share to social via oauth
Mailing list blasts for paywall content
