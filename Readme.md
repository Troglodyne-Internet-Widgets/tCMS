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
