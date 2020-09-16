tCMeS
=====

It's basically tCMS, with elasticsearch as the storage backend

Oh it's also a Perl PSGI app with a flippin' api now too :P

Ideas:
======
Put *all* posts in elasticsearch, just filter by type and have a micro, blog, image (insta), video, podcat and wiki view with static renders

Search bar that isn't SHIT

*domain* picker at top -- manage all your web properties from one place

login and registration (forces email for a domain to allow posting on said domain)
User data *also* stored in ES -- it's their profile page!

Error and Access logs immediately dumped into ES for EZ viewing in grafana

Automatic analytics!

Builtin paywall -- add in LDAP users not on primary domain, give differing privs
Have all content able to assign to paywall packages

One click share to social via oauth
Mailing list blasts for paywall content
