tCMS
=====

A flexible perl CMS which supports multiple data models and content types

Deployment is currently:
* make depend
* make install

Then:
* Set up proxy rule in your webserver
* open tmux or screen
* `starman -p $PORT www/server.psgi`
OR (if you want tCMS as a systemd service for the current user):
* PORT=$PORT make install-service

$PORT being whatever port you want it to sit on.

TODO: Make the makefile not rewrite itself when running make! Reset for now after run.

A Dockerfile and deployment scripts are provided for your convenience in building/running containers based on this:
```
# Build and run the server
./fulldeploy.sh
# Just run the server with latest changes
./dockerdeploy.sh
# Extract configuration & local data, then spin down the server
./docker-exfil.sh
```
The user guide is self-hosted; After you first login, hit the 'Manual' section in the backend.

Rate-Limiting is expected to be handled at the level of the webserver proxying requests to this application.

Migration of tCMS1 sites
=========================

See migrate.pl, and modify the $docroot variable appropriately

Content Types
=============
Content templates are modular.
Add in a template to /templates/forms which describe the content *and* how to edit it.
Our post data storage being JSON allows us the flexibility to have any kind of meta associated with posts, so go hog wild.

Currently supported:
* Microblogs
* Blogs
* Files (Video/Audio/Images/Other)
* About Pages
* Post Series

Planned development:
* Presentations
* Test Plans / Issues (crossover with App::Prove::Elasticsearch)

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
* DUMMY - A JSON blob.  Used for testing mostly, but could be handy for very small sites.
* Flat File - Pretty much the tCMS1 data model; a migration script is forthcoming

Planned Development:
* Elasticsearch - Documents are ideally indexed in a search engine, should be nice and fast too.
* Git - More for the APE crossover

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
