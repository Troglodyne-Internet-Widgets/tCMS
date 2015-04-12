tCMS
====

A PHP flat-file CMS (teodesian.net CMS), geared towards a webmaster who mostly already "knows what he's doing".
As such, it allows for some neat things like posting via flat files,
in case you just wanted to use vim, etc. to blog (as I do).
Still, I've added a lot of frontend convenience stuff, mostly as requests.

Oh, yeah, did I mention it's responsive by default and degrades well on IE (last I checked)?

See http://tcms.troglodyne.net for more information.

Installing this is pretty easy,
either grab an archive from above site and extract it or git clone it into a public html directory.

WARNING: If you don't setup HTTP Server based Authentication, you deserve what you get.
See the manual for more information: http://tcms.troglodyne.net/index.php?nav=1&dir=fileshare/manual

As of the latest version, there should be no upgrade issues,
despite switching to using JSON to store new postings.
The code anticipates and uses the legacy style of accessing old posts in that instance.

TODO/Ideas:
 * Convert blog posts to use JSON, similar to microblog, mostly to enable storing better metadata.
 * Theming importation ability, or a decent upgrading script for more effective cruise control.
 * Test code. I'll probably do this in perl,
   since I'm used to it's test harnesses and Selenium::Remote::Driver for functional automated testing.
 * Support for torrent seedboxes tracking /fileshare to autoprovide magnet links to downloads
 * API conversion for signifigant functionality, mostly as a way to make it easier to extend tCMS.
   - For example, a cron that watches your install for new posts then crossposts to twitter, etc.
   - Distributed tCMS installs with gluster would be fun :D
 * Support for alternative authentication schemes (LDAP, etc.).
   I doubt a manual mapping table from what you've set HTTP auth users to in tCMS is everyone's cup o tea.
 * Add option for using an SQLite database to store posting data, configs, etc.
 * ...And anything here too: http://tcms.troglodyne.net/index.php?nav=5&post=fileshare/manual/Appendix%2001-TODO.post

Really, I don't wanna go too hog wild with features on this,
since I've already accomplished pretty much 100% of what I want tCMS to do for me.
Most of these are 'nice to have' items. I may think about working on some of these more if there's interest.
