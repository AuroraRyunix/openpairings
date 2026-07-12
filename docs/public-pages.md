# Public (no login) tournament pages

Every tournament has two read-only pages that don't require an account:

- `/p/:slug/pairings` — the tournament name, the latest paired round number,
  and that round's pairing list (board, white, black, result).
- `/p/:slug/standings` — the tournament name and the current standings
  table, with the same tiebreak columns as the authenticated Standings page.

Both are meant to be shared with players, spectators, or a tournament hall
screen — anyone with the link can open them, no log-in required.

## The link is a token, not the tournament id

`:slug` is `tournaments.public_slug`, a random URL-safe token
(`:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false)`, 12
characters) — **not** the tournament's numeric `id`. Tournament ids are
small sequential integers, so a public URL built from the id would let
anyone page through `/t/1`, `/t/2`, `/t/3`... and view every tournament in
the system. The random token makes that infeasible: only someone who was
given the link (or found it on the tournament's own pages) can open it.

Every tournament always has a `public_slug` — it's filled in automatically
by `PairingsEngine.Tournaments.Tournament.changeset/2` the first time a
tournament is created, whichever path creates it (the "New tournament" UI
form, the SWAR importer, or the JSON tournament importer all go through
this same changeset). Existing tournaments were backfilled with a slug by
the `AddPublicSlugToTournaments` migration. The slug never changes once
set — sharing a link doesn't risk it rotating out from under someone.

`PairingsEngine.Tournaments.get_tournament_by_public_slug/1` is the lookup
used by both pages. Unlike every other tournament lookup in that module, it
does **no** scope/ownership check — that's the point, it's the one
intentionally public entry point. An unknown slug 404s (`Ecto.NoResultsError`).

## Where to find the links

On the authenticated **Pairings** page, next to "Open live view":
**"Public pairings link"**. On the authenticated **Standings** page, next
to **Print**: **"Public standings link"**. Both open in a new tab and carry
a "No login needed — share this link" tooltip.

## Live updates

Both pages subscribe to the tournament's PubSub topic
(`PairingsEngine.Tournaments.tournament_topic/1`) the same way every other
tournament view does, and reload when a `{:tournament_changed, id, hint}`
message arrives — entering a result on the authenticated Pairings page (or
anywhere else) updates an open public page within a heartbeat, no refresh
needed.

If the tournament is deleted while someone has a public page open, the page
switches to a "This tournament is no longer available" message instead of
crashing or redirecting (there's nowhere authenticated to redirect a
logged-out visitor to).

## What's deliberately not here

- No editing of any kind — results, pairing, settings, everything stays
  behind login.
- No navigation to other tournaments or to the authenticated app — the
  public pages render inside `Layouts.app` with no `tournament` assign, so
  none of the app's tournament tabs (Players, Pairings, Settings, ...)
  appear.
- No way to enumerate tournaments from a public link — the slug reveals
  nothing about the tournament's id or any other tournament's slug.
