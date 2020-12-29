tCMS
=====

A flexible perl CMS which supports multiple data models and content types

Deployment is currently:
* make depend
* make install
* Set up proxy rule in your webserver
* open tmux or screen
* `starman -p $PORT www/server.psgi`

A Dockerfile and deployment scripts are provided for your convenience in building/running containers based on this:
```
# Build and run the server
./docker-deploy.sh
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
* Microblogs
* Blogs
* Video
* Audio
* Files
* About Pages

Planned development:
* Presentations
* Test Plans / Issues (crossover with App::Prove::Elasticsearch)

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
