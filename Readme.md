tCMS
=====

A flexible perl CMS which supports multiple data models and content types.
Should be readily portable/hostable between any other system that runs tCMS due to being largely self-contained.

tCMS is built fully around ubuntu hosts at the moment.

Deployment is currently:
* make -f Installer.mk depend
* make -f Installer.mk install

Then:
* open tmux or screen
* `sudo ./tcms`
OR (if you want tCMS as a systemd service for production/preproduction contexts):
* `make -f Installer.mk all`

This sets up nginx, reverse proxy and SSL certs for you.
It also sets up the mailserver and DNS for you via pdns.

It is strongly suggested that you chmod everything but the run/ directory to be 0700, particularly in a shared environment.

## Administration/Development

Administrating the server should in general be done via the system user we setup which will be the domain setup with `tcms-hostname` with dots replaced with dashes.
Slap in the authorized public key to .ssh/authorized\_keys, as this is the system user's homedir.
From there you'll need to `sudo chsh -s /bin/bash $system_user_name` to allow logging in remotely.
In production you should probably leave things nologin, and instead sudo into the user for shells from an administrator account.

The user guide is self-hosted; After you first login, hit the 'Manual' section in the backend.

Rate-Limiting is expected to be handled at the level of the webserver proxying requests to this application.
See ufw/setup-rules as an example of the easy way to setup rules/limiting for all the services you need to run tCMS.

Containerization
====================

A Dockerfile and deployment scripts are provided for your convenience in building/running containers based on this:
```
# Build and run the server
./fulldeploy.sh
# Just run the server with latest changes
./dockerdeploy.sh
# Extract configuration & local data, then spin down the server
./docker-exfil.sh
```
There is also podman container code; see images/README.md

Deployment via Terraform
========================

See provisioner_configs.

Migration of tCMS1 sites
=========================

See migrate.pl, and modify the $docroot variable appropriately

Content Types
=============
Content templates are modular.
Add in a template to www/templates/html/components/forms which describe the content *and* how to edit it.
Our post data storage being JSON allows us the flexibility to have any kind of meta associated with posts, so go hog wild.

Currently supported:
* Microblogs
* Blogs
* Files (Video/Audio/Images/Other)
* About Pages
* Post Series
* Presentations

Planned development:
* LaTeX
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
