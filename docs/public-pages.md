# The public page

A tournament becomes readable by the public in exactly one way: it is
published to **OpenResults**, the separate read-only site. This app serves no
public pages at all.

That was not always true. Until 2026-08-29 there were two answers - a set of
local `/p/:slug/...` pages served by whatever machine the arbiter was pairing
on, and, since the split, the results site. Two surfaces for one thing, and
the default was the wrong one: a link to the arbiter's laptop, printed on a
wall chart and handed to a hall full of spectators, is precisely what the
split exists to prevent. The local pages were removed rather than
de-emphasised, because a second correct-looking answer is worse than none.

## One switch

`publish_to_openresults` is the whole of it. On, and the tournament has a
public page; off, and it has none anywhere.

It used to sit beside `public_pages_enabled`, which answered the separate
question "may anyone with the link read this *here*". That field was dropped
with the pages, and the migration carried each tournament's intent across: a
tournament whose arbiter had switched local sharing on is now marked to
publish, because they had already said "this is public" and the only thing
that changed is where the public reads it.

It goes through `Tournaments.set_publish_to_openresults/2`, and is
deliberately **not** cast by `Tournament.changeset/2` - an ordinary settings
save must not be able to start sending an event's player names, ratings and
clubs to a remote server by accident.

### What a machine needs before the switch means anything

Two things, and `PairingsEngineWeb.PublicLink.public?/1` requires both:

1. the tournament's switch is on, and
2. this machine has been told where the results site is (Settings ->
   Connections, stored by `PairingsEngine.Publishing.put_endpoint/1`).

The switch alone is a promise about the future - a tournament can be marked
to publish on a laptop that has never been told an address. Offering a link
built from a blank endpoint would produce `/t/slug`, a relative path
resolving against whatever page rendered it, i.e. straight back to this
machine. That is the old bug wearing a new hat, so it is tested for by name.

## Listed, and what is shown

Two more controls, both on Settings -> Results site, both defaulting to
today's behaviour and both travelling in the snapshot.

**`public_listed`** decides whether the tournament appears in the results
site's index. Off leaves it reachable by its address and nowhere else. It is
**not** a security control and the settings page says so in as many words: an
unlisted tournament is still world-readable to anyone holding the address,
and addresses get forwarded. It hides an event from somebody browsing the
site, not from somebody who was sent the link.

**`public_display`** decides which columns the public page may show -
ratings, titles, federations, clubs, categories, tiebreak columns and player
cards. See `PairingsEngine.PublicDisplay` for the keys.

Three rules hold it together:

1. **Absent means shown**, in every direction: a tournament that predates the
   feature, a key one side knows and the other does not, a key added later
   that no published snapshot mentions. The failure directions are not
   symmetric - showing a column an arbiter meant to hide is visible to them
   and fixed in a click, while hiding one they meant to show is invisible
   from their side and surfaces as somebody in the hall asking where the
   ratings went.
2. **Only the negatives are stored.** The column holds what an arbiter turned
   OFF, so a key added later is not silently pinned to today's default on
   every tournament that has ever visited the page.
3. **The snapshot carries a resolved answer** - every key, every value a real
   boolean - not the sparse stored map. A reader should not have to know this
   app's default list to interpret it.

Names, board numbers, results and placings are not togglable. They are the
tournament; an arbiter who does not want them public does not publish.

Hiding a column is a display rule, not an access rule - except for
`player_cards`, which OpenResults enforces in its controller as well as its
markup, because a link is a courtesy and a bookmarked URL is not.

## The slug is an address, not a secret door

`public_slug` is a random 12-byte token rather than the sequential numeric
`id`, and every tournament has had one since long before anything was
published anywhere.

Its job changed on 2026-08-29. It used to be the thing that kept local pages
from being enumerable. Now it is this tournament's address on the results
site - the `:slug` in OpenResults' `/t/:slug` - and being unguessable still
earns its keep, because a published tournament is world-readable and the slug
is all that stands between a scraper and a list of every event on the site.

### Rotating it is a real operation now

"Generate a new link" used to be free: the pages 404'd the instant the slug
changed, because they were served from the same database the slug lived in.

They are not any more, and a bare rotation would do the opposite of what the
button promises. The leaked link keeps working - the copy behind it is on
another server and this machine has merely stopped pointing at it - and the
next publish creates a *second* copy at the new address. The tournament ends
up public twice, with the key that could have withdrawn the first one now
naming a slug that holds nothing.

So `PairingsEngine.Publishing.rotate_address/1` does three things in order:

1. **take the old copy down** (the part the arbiter actually asked for),
2. rotate the slug,
3. publish again, minting a fresh key.

If step 1 fails, nothing else happens - a failed revocation must never look
like a successful one. If step 3 fails, the arbiter is told: the old link is
dead, which was the request, and publishing retries by itself.
`Tournaments.rotate_public_slug/1` still exists and still does only the
middle step; it is not the operation a user wants.

## Registration

The entry form is on the results site too, and this is the one flag that lets
strangers write into an arbiter's tournament.

`registration_open` is unusual in that **this app does not enforce it at
all**. It rides along in the published snapshot, and OpenResults reads it.
That has two consequences worth stating plainly:

- It means nothing for an unpublished tournament. The Results site page
  says so rather than letting an arbiter open a form that does not exist.
- Closing it is not instant. `Tournaments.set_registration_open/2` enqueues a
  publish on *both* edges for exactly this reason - closing is the urgent
  direction, since an arbiter shutting entries at the door needs the site to
  stop taking them.

A reader that predates the field must treat its absence as **open**. Every
snapshot published before 2026-08-29 is silent on the question and that
server accepted entries for all of them, so reading silence as "closed" would
have shut every already-published form the moment the change deployed, with
nothing in either app to explain why. The failure directions are not
symmetric: an entry that should not have been taken lands in a queue an
arbiter reads and rejects, while a form that is shut when it should be open
turns a real person away and tells nobody.

## Where the links come from

`PairingsEngineWeb.PublicLink` is the only module that answers "where does
the public read this tournament". Six call sites use it - the projector QR
code and its printed URL, the pairings and standings page headers, the
settings share card, and the entry-form link - and none of them build a URL
themselves.

Links are **absolute**, because they point at another host and half of them
end up on a QR code, in a printed footer, or pasted into an email.

Targets are deliberately **coarse**. A published tournament gets its front
page (`/t/:slug`) and the reader navigates from there; only registration,
which is a distinct destination rather than a view of the same thing, is
addressed directly. Deep-linking into OpenResults' route shape would tie the
two apps together far more tightly than the snapshot contract does, and a
route rename over there would break links already printed on paper here.

`public?/1` and `url/2` are two halves of one thing: gate the element on the
first, then use the second. `url/2` returns `nil` when there is no public
address, and markup that skipped the gate would render an anchor pointing
nowhere.

## Embedding

A club site that wants the pairing list on its own front page embeds it from
**OpenResults**, which sets no framing restriction.

This app now refuses framing everywhere, with no way to ask for an exception.
`CSP.allow_framing/2`, the router's `:embeddable` pipeline, the cookie-free
`/embed/live` socket and the iframe height-reporting JavaScript were all
removed on 2026-08-29 along with the pages they served, and
`PUBLIC_FRAME_ANCESTORS` went with them.

The argument for the old exception was careful and correct as far as it went
- those pages held no session and took no input, so framing them handed the
embedding site nothing. But it was an argument that had to be re-made every
time a route was added, and getting it wrong once would have quietly made
every logged-in arbiter clickjackable. OpenResults needs no such argument: it
has no login, so there is no authority to steal.
`test/pairings_engine_web/csp_framing_test.exs` pins framing off as
unconditional.

## What is deliberately not here

- **No login, and no per-user anything.** Nothing on the results site knows
  who is reading.
- **No writes back into a tournament.** Entries land in a queue the arbiter
  pulls and reviews; nothing a member of the public does can change a
  pairing, a result or a player.
- **No deep links from this app into that one.** See "Where the links come
  from".
