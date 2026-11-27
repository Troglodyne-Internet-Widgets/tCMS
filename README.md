# NAME

TCMS - A CMS for perl, run by tPSGI, in which a post can be content of any type

# VERSION

version 0.01

## build\_routes()

The OpenAPI 3 document that tPSGI routes by, made from the routing table that
\_routes() returns.  Each route becomes the operation of its method, under its
path.  The operation's x-tpsgi-callback is the route's callback, wrapped in what
every tCMS request needs.  `data` becomes x-tpsgi-data, and `auth`,
`secure`, `nocache`, `noindex`, `nomap`, `robot_name` and `totp_exempt` become
x-tcms-auth and so on, which the callback finds in `$query->{dispatcher}`.
`parameters` are OpenAPI parameter objects, and each variable of a template
that they leave out is a required string.  A route with no method is a GET.
Every route links the scripts of @Theme::scripts before its own `scripts`.

If `general.secure_host` names a host (see secure\_host() in
Trog::Routes::HTML), a route with `secure` or `auth` answers only on that
host.  The `/secure` copies of the routes of posts and of the index get
`secure`, and so does the route of a private post, which the data model
marks.  On any other host, a GET or a HEAD of such a route is a redirect to
the same path and query on the secure host, and any other method gets 404, so
that a form body never goes to the public host.  On a host other than the
secure host, tCMS also ignores the login cookie.  On the secure host, a route
with a `/secure` copy is a reader's page, and a GET or a HEAD of it is a
redirect to `general.hostname`, if that is set and is another host.  Every page
gets `secure_base`, `https://` and the secure host, or an empty string, for
its links to the routes that need a login.

A route that does not declare its parameters takes the query or the form that
%Trog::Routes::HTML::inputs names for its callback, less what its `data` fixes and
its path holds.  Every GET also takes the parameters of a campaign, utm\_source
and the rest.  The wrapper gives the callback the input of the request in
`$query->{input}`, and sets `to` beside it, as a path on this site.

The `default` route is not a path.  The wrapper calls it when there is no
`config/setup`.

Returns the document as a list of key and value pairs, `openapi`, `info`
and `paths`, to assign to a hash.

```
our %openapi = TCMS::build_routes();
```

## on\_public\_host($query, $secure\_host)

Whether the request came to a host other than $secure\_host, which secure\_host()
in Trog::Routes::HTML returned.  The port of the host is ignored.  It is false
when $secure\_host is empty, because then there is one host for everything.

- query - HashRef - the query of the request, of which it reads `domain`
- secure\_host - Str - the secure host, or an empty string

Returns Bool, 1 when the request came to another host, else 0.

```
return redirect_to_host( $tpsgi, $query, $secure ) if on_public_host( $query, $secure );
```

## redirect\_to\_host($tpsgi, $query, $host)

The answer to a request that came to the wrong one of the two hosts.  A GET or
a HEAD gets a redirect to the same path and query on $host, over https.  Any
other method gets 404, so that a browser never sends a form body to the host
that should not see it.  The redirect is not permanent, because the settings
can change.

- tpsgi - TPSGI - the server, which makes the response
- query - HashRef - the query of the request, of which it reads `method`, `route` and `query_string`
- host - Str - the host to send the request to

Returns ArrayRef, the PSGI response: the redirect, or the 404.

```
return redirect_to_host( $tpsgi, $query, $secure ) if on_public_host( $query, $secure );
```

## needs\_enrolment($user, $dispatcher)

Whether this request should be turned around and sent to /totp.

Two factors or nothing.  A login is what gets you to the enrollment page -- the QR
is the shared secret, so it cannot be handed to whoever asks for it -- which
leaves a window where somebody is logged in and has no second factor yet.  This
is what makes that window one page wide: every route a login can reach, and no
route a logged out visitor can, is refused until they have enrolled.

The enrollment page and the QR on it say so themselves, with totp\_exempt, because
the exemption belongs next to the route rather than in a list over here that the
routing table knows nothing about.  $dispatcher is the operation that
build\_routes() made, so it holds them as x-tcms-auth and x-tcms-totp\_exempt.

- user - Str - the user who is logged in, or an empty string
- dispatcher - HashRef - the operation of the route

Returns Bool, 1 when the user must enrol first, else 0.

```perl
my $enrol = TCMS::needs_enrolment( $user, $query->{dispatcher} );
```

## generic\_route($rname, $code, $title, $query)

The page of an error, which tPSGI asks the router for in place of its own plain
one.  It renders the template of the code, such as `404.tx`, through
Trog::Routes::HTML::index(), with the path that the request asked for.

- rname - Str - the route of the error, such as `/404`
- code - Int - the HTTP status
- title - Str - the title of the page, which tPSGI gives as the name of the error
- query - HashRef - the query of the request, which it changes

Returns ArrayRef, the PSGI response of the page.

```
return TCMS::generic_route( '/404', 404, 'Not Found', $query );
```

## aliases()

The aliases of the posts, from the data model that the configuration names,
which tPSGI reads from `%TCMS::aliases`.

Returns the aliases as a list of key and value pairs, from each alias to the
path that it stands for.

```
our %aliases = TCMS::aliases();
```

## robots($query)

Return an appropriate robots.txt

This is a "special" route as it needs to know about all the routes in order to disallow noindex=1 routes.

Returns ArrayRef, the PSGI response of the text.

```perl
my $response = TCMS::robots($query);
```

# BUGS

Please report any bugs or feature requests on the bugtracker website
[https://github.com/Troglodyne-Internet-Widgets/tCMS/issues](https://github.com/Troglodyne-Internet-Widgets/tCMS/issues)

When submitting a bug or request, please include a test-file or a
patch to an existing test-file that illustrates the bug or desired
feature.

# AUTHORS

Current Maintainers:

- George S. Baugh <george@troglodyne.net>

# CONTRIBUTORS

- Andy Baugh <andy@troglodyne.net>
- Evan Carroll <me@evancarroll.com>
- George Baugh <gbaugh@hailstrike.com>
- George S. Baugh <doge@dux.troglodyne.net>
- George S. Baugh <doge@teodesian.net>
- Nicolas R <nicolas@atoomic.org>
- teo greenwood <teo@teodesian.net>
- troglodyne-bot <morpheus@troglodyne.net>
- troglodyne-bot <troglodyne-bot@users.noreply.github.com>
- troglodyne-robot <trogbot@troglodyne.net>
- Troglodyne <root@troglodyne.net>

# COPYRIGHT AND LICENSE

Copyright (c) 2020 Troglodyne LLC

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
LICENSE, and [https://www.gnu.org/licenses/gpl-3.0.html](https://www.gnu.org/licenses/gpl-3.0.html).
