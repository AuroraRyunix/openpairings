# Manubrium - the arbiter's phone app

> **2026-10-20: split in two.** What this document calls Manubrium (phases 1
> and 2) is now **Manubrium Lite**: `/m` in the phone's browser, no install.
> The web app manifest and the home-screen meta tags are gone - the service
> worker stays, registered off a `<meta name="manubrium-lite">` tag, so a
> page that is open survives a wifi drop. The **full Manubrium** is a native
> app (Capacitor, its own repo) that runs whole tournaments against one or
> more servers over a versioned API, because a web app on an https origin
> cannot talk to a desktop install's plain-http hall listener. Read
> "installable" and "manifest" below as history.

Manubrium is what `/m` (no-account mobile result entry) becomes: an
installable web app (PWA) on top of the same enrolment, the same session and
the same permission checks. There is no store build. An Apple developer
account does not exist, nothing needs installing from a store, and the phone
talks to the same server whether that is pairings.cloud or any other hosted
copy.

On a hosted server phones reach `/m` the way they reach any page. A desktop
install binds to loopback and has no accounts; since phase 2 a phone reaches
it only through a second listener the arbiter switches on, which answers the
phone pages and nothing else (see "Desktop: phones over the hall network"
below, and `Mobile.ensure_reachable/0`). The PWA itself has nothing
hosted-specific in it; it works wherever `/m` answers.

## Phase 1

### Architecture

```
phone                                        server
-----                                        ------
/m/results (LiveView, as before)  <------->  MobileResultsLive
  |  hook "Manubrium" (assets/js/manubrium)    (round, filters, settle,
  |    - taps on result buttons and the         clear, lock, PubSub)
  |      incident dialog become ENTRIES
  |    - entries live in IndexedDB           POST /m/sync  (JSON, CSRF,
  |    - sent in order, one request per        session-bound to the
  |      batch, when the network allows  ---->  enrolment)
  |                                          Mobile.Sync.submit/2
  |  service worker /m/sw.js, scope /m/        -> permit_round / range /
  |    - caches /m/results (network first)        permit_result / CAS
  |    - caches the public /assets bundles        -> Tournaments.update_pairing_result
  |    - nothing else                           -> Incidents.log_from_phone/4
  |                                            mobile_submissions: one row per
/m/manifest.webmanifest, icons               client id, the answer it got
```

* **Manifest** (removed with the Lite split) `GET /m/manifest.webmanifest`:
  name and short_name "Manubrium", `start_url` `/m/results`, `scope` `/m/`,
  OpenPairings' palette, PNG icons drawn from the nine-squares Manubrium mark
  (`priv/static/images/manubrium/*.png`, drawn by
  `scripts/manubrium_icons.py` after `brand/marks/manubrium.svg` in the
  shared brand folder beside the repos). Linked from the root layout only on `/m`
  pages (the `:manubrium` assign set by the router pipeline).
* **Service worker** `GET /m/sw.js`, served by the same controller from
  `assets/js/manubrium/sw.js` (read at compile time, not bundled) with the release
  version stamped in, so every release is a new worker and old caches are
  dropped. A fixed path, never digested: a worker's URL is its identity.
  Default scope `/m/`. Registered from `app.js` only on pages that carry the
  manifest link.
* **Queue** `assets/js/manubrium/` - `queue.js` (IndexedDB, one object
  store; an in-memory map where IndexedDB is refused), `outbox.js` (sends in
  order, draws the outbox and the header count), `hook.js` (the LiveView
  hook: taps and the incident dialog become entries). The buttons keep their
  `phx-click`, so a page whose JavaScript did not load still saves the
  old way. The outbox also mounts on the code-entry page `/m`, so a
  phone that was sent there (revoked, expired, left) still shows what it had
  waiting and what the server said about it.

### Entries

An entry is made on the phone, never edited after it is sent:

| field | meaning |
|---|---|
| `cid` | client id, `crypto.randomUUID()`; the idempotency key |
| `enrollment` | the enrolment id the page was opened under |
| `kind` | `"result"` or `"incident"` |
| `round`, `pairing`, `board` | where; `board` only for messages |
| `white`, `black` | the player ids the phone saw on the board |
| `result`, `expected` | result: what was tapped, and what the phone believed the board held at that moment |
| `type`, `note`, `at` | incident: type, note (max 280), phone clock time |
| `photo` | incident, optional: base64 JPEG, shrunk on the phone to 1600 px; sent in a request of its own and dropped from the phone once answered |

### Offline and conflict rules

The server is the judge. The phone only ever asks.

1. **Order.** Entries are sent oldest first, in batches of at most 25, one
   batch at a time. A batch that fails on the network is sent again,
   whole; nothing behind it goes first.
2. **Idempotent resend.** Every final answer is stored in
   `mobile_submissions` under `(enrollment_id, client_id)`. A resend of a
   `cid` the server has answered gets the stored answer back and writes
   nothing. Incidents carry the `cid` on their own row too, under a unique
   index, so even two simultaneous sends of the same incident make one row.
3. **Three answers per entry.** `saved` (done, or the board already held
   exactly this result), `refused` (final - shown on the phone, per board,
   with the reason, until dismissed) and `retry` (rate limited or the server
   could not answer; the entry stays waiting). Nothing is dropped silently:
   an entry leaves "waiting" only for "sent" or "refused".
4. **Never overwrite.** A result is written only if the board still holds
   what the phone saw when it was tapped (`expected`): compare-and-set. If
   the desk, another phone or a re-pairing changed the board meanwhile, the
   entry is refused with both values in the message. A helper is fill-once
   on top of that (`Mobile.permit_result/4` reads the stored board).
5. **Same seats.** If the arbiter swapped players on the board since the
   phone drew it (`white`/`black` differ), the entry is refused - the
   result was about two people who are no longer there.
6. **Round still current.** A helper's entry for a round that is no longer
   the latest paired round is refused (`permit_round/3`), even if it was
   tapped while it was. A deputy's is judged like any deputy entry.
7. **Board range, archived, handed off, closed FIDE round, postponed-game
   acknowledgements, sent-in-TRF.** Exactly as for a tap while online: the
   same `update_pairing_result/3` gates, refused with the same sentences.
8. **Revoked or expired enrolment.** Every waiting entry comes back
   `refused`, per board, "this phone's access was ended". The outbox stays
   on the phone (also on `/m`) so the helper can read the results out to
   the arbiter.
9. **A different code.** An entry made under enrolment A is never sent
   under enrolment B: a phone that is re-enrolled gets A's leftovers back
   refused, not quietly re-attributed.
10. **The same board twice on the phone.** A second tap on a board whose
    first entry is still waiting (not yet in flight) replaces it. Otherwise
    the new entry's `expected` is the previous entry's result, so the chain
    is judged in order.
11. **Clearing a result** (deputy, two taps) is not queued: it needs a live
    connection. Taking a result away is not something to do on a delay.
    Likewise the lock, the "More" panel and the round switcher are LiveView
    controls and wait for the connection.

### Security model

* Nothing new to log in with. `/m/sync` reads the enrolment from the same
  signed session cookie as `/m/results`, re-checks it is active on every
  request, and needs the CSRF token like any other form post.
* Every result goes through `Mobile.permit_round/3`, `board_in_range?/2`,
  `Mobile.permit_result/4` and `Tournaments.update_pairing_result/3`. Every
  incident through `permit_round/3`, `board_in_range?/2` and the level rule
  below. The pairing must belong to the enrolment's tournament and to the
  round the entry names.
* Rate limits (`PairingsEngine.RateLimit`), keyed by enrolment id:
  `:mobile_sync` (entries per ten minutes; past it, `retry`) and
  `:mobile_incident` (incidents per ten minutes). A hard cap of 300
  incidents per enrolment. A batch carries at most 25 entries and a note
  280 characters.
* The service worker caches exactly two kinds of thing: the `/m/results`
  page (only ever under that key, only when it answered 200 without a
  redirect, deleted when it redirects or the phone leaves) and the public,
  digested `/assets/` bundles that page needs (identical for every
  visitor). It never caches another page, an API answer, or anything that
  is not a GET. Its scope is `/m/`; the rest of the site never runs through
  it.
* Incidents are typed on the phone with a type and a short note. The phone
  never asks for a name: the board says who is involved, and the note's
  hint says not to type names.

### Helper and deputy

| | helper | deputy |
|---|---|---|
| enter results | blank boards, latest round | any board, any paired round |
| correct a result | no | yes (compare-and-set) |
| clear a result | no | yes, online only, two taps |
| log an incident | "arbiter call" only, latest round | every type, any paired round |
| board range | applies | applies |

A helper standing at a board where something goes wrong needs the arbiter
there, not a form; "arbiter call" is that. Recording what happened is the
arbiter's job, so the other types are deputy-only.

### Incidents

Table `incidents`: tournament, round number, board, pairing (nilified if the
round is re-paired), the white and black player ids at the time and their
names as the board showed them (so a re-pairing or snapshot restore, which
recreates players, does not leave the row about nobody), `kind`
(`illegal_move`, `clock`, `device`, `complaint`, `time_added`,
`game_rewound`, `arbiter_call`, `other`; phase 1's `dispute` was renamed
`complaint` by the migration),
`note`, `occurred_at` (the phone's clock, if within a day of the server's;
otherwise the time it arrived), the enrolment id and its label at the time,
`source` (`"phone"`), `client_id`, the account (`user_id`) when the code
belongs to one, and `has_photo`. Listed per round at
`/t/:id/incidents` (linked from the Pairings page's More menu, and from a
line under the round when it has any). Kept by snapshot restores like the
audit trail, deleted with the tournament. Not in the export envelope yet
(see phase 2).

### Who can use it

A hosted server, or since phase 2 a desktop install with "Let phones on this
network connect" switched on. On an iPhone a home-screen app has its own
cookies, separate from Safari's, so a code redeemed in Safari does not come
along. The QR therefore opens a page that asks before it claims anything
(`GET /m/e/:token` shows a button; `POST` claims), and shows the link again
for copying: pasted into the installed app's code box, the link redeems
there. The 8-digit code still works as before.

### What `mix test` does not cover

The server half is tested (`test/pairings_engine/mobile_sync_test.exs`,
`test/pairings_engine_web/controllers/mobile_app_controller_test.exs`,
`test/pairings_engine_web/live/manubrium_live_test.exs`, and for phase 2
`test/pairings_engine/arbiters_test.exs`,
`test/pairings_engine_web/controllers/mobile_connect_controller_test.exs`,
`test/pairings_engine_web/live/manubrium_hall_test.exs` and
`test/pairings_engine_web/phone_lan_test.exs`, which starts the phones'
listener for real and asks it over HTTP): idempotent
resends, every refusal, compare-and-set, revoked and re-enrolled phones,
incident permissions, caps and rate limits, the manifest, the worker's
placeholders, the pages' hooks and data attributes.

The JavaScript never runs in a test. Untested, and to be checked by hand on
real phones before relying on it in a hall:

* the service worker on iOS Safari and Android Chrome: install, offline
  start-up, the cached page after a redirect, the cache dropped on Leave;
* IndexedDB surviving the app being closed (iOS evicts storage of sites not
  opened for a while; the in-memory fallback when it is refused);
* the queue's order and retry under a flapping connection, and the
  "replace an untried entry" race (`add()` against `flush()`: at worst both
  are sent, and the second is refused as a conflict, never written);
* the incident `<dialog>` on older iOS (15.4 added `<dialog>`);
* the "Leave" confirm when entries are waiting;
* phase 2: the camera input and the shrinking canvas (iOS Safari, Android
  Chrome), a photo entry surviving a wifi drop in IndexedDB, the Screen
  Wake Lock (and its re-take after the page was hidden), the one-handed
  layout on small screens, pasting the QR link into an installed iPhone app,
  and a real phone reaching a desktop copy over the hall wifi (firewall
  prompts on Windows and macOS are the arbiter's to accept).

## Phase 2

### Arbiter accounts

A collaborator has a role: `editor` (as before: everything the owner can do
but manage collaborators and delete) or `arbiter` (new). An arbiter gets the
hall and nothing else:

* `Tournaments.collaborator_tournament_ids/1` counts editors only, so every
  desk page (`get_authorized_tournament/2`) and the board link's account
  codes (`BoardLink.account_links_query/1`) stay shut to an arbiter. There
  is no second check to forget: arbiters are simply not in the one query.
* `Tournaments.hall_role/2` - `:owner`, `:editor`, `:arbiter` or nil - is
  the hall's own question. `hall_tournaments/1` lists them.
* An arbiter signs in on their own phone at `/m/connect`
  (`MobileConnectController`, `:require_authenticated_user`): "Use this
  phone" makes a code bound to the account and redeems it there and then;
  "Show a code for another phone" shows it as a QR (for the installed app
  on an iPhone, or a phone that is not signed in). Accepting an arbiter
  invitation lands there.
* A code with a `user_id` is always a deputy, and is valid only while
  `hall_role` says the account still works there (`Mobile.get_active/1`
  and friends filter through `held/1`). Removing the collaborator, or the
  arbiter leaving, revokes their codes outright (`Mobile.revoke_for_user/2`).
* Its results and incidents are audited under the account
  (`Audit.log(tid, enrollment.user_id, ...)`); a no-account code is still
  "System" with the code in the details.
* Nobody mints an account code for somebody else: the desk's Phone QR codes
  are the no-account kind, so an arbiter's name never ends up on a phone
  they never held.
* Board assignment: the desk gives each arbiter a range in the Phone QR
  dialog (`Tournaments.assign_boards/4`, audited as
  `collaborator.boards_assigned`). It changes what "My boards" shows on
  that arbiter's phone, not what they may enter.

The no-account codes for helpers work exactly as before.

### Desktop: phones over the hall network

`PairingsEngineWeb.PhoneLan`, modelled on the board link's listener
(`BoardLan`), with the same promises:

* The desktop's own listener stays on 127.0.0.1. Nothing moves it.
* A *second* Bandit listener, off until the arbiter switches on "Let phones
  on this network connect" in the Phone QR dialog. Default port 4748 (the
  board link has 4747); the endpoint's own port and the board link's are
  refused. Bound to one private address of this PC, chosen from
  `BoardLan.addresses/0`, and only while that address is still the PC's.
* It listens only while at least one phone code is active; revoke or
  outlive the last one and the port closes (checked on every status call
  and a 30-second tick).
* `PhoneLan.Plug` in front of it: local mode or 404; a private caller
  address or 403; then a method-and-path list or 404, decided before any
  parsing or session - `GET|POST /m`, `GET|POST /m/e/:token`, `GET
  /m/leave`, `GET /m/results`, the manifest and worker, `POST /m/sync`, the
  LiveView socket (`/live/websocket`, `/live/longpoll`), and the public
  static files (`/assets/*`, `/fonts/*`, `/images/manubrium/*`, the
  favicon). `GET /` redirects to `/m`. Every desk page, `/m/connect`, the
  API, the admin pages and the incident photos are 404 there; and if one
  were reached anyway, `UserAuth.local_owner_session/2` signs in loopback
  callers only.
* Proxy headers (`X-Forwarded-*`, `Forwarded`, `X-Real-IP`) are dropped:
  nothing stands in front of that port.
* Three things a plain-http phone would otherwise trip over, each changed
  for this listener's requests only (`conn.private.phone_lan`):
  `force_ssl` skips them (`PhoneLan.lan_request?/1` in config/prod.exs'
  `exclude`); the session cookie loses its `Secure` flag on the way out (a
  desktop build compiles `secure_cookies: true`, and a phone keeps no
  Secure cookie from an http page); and the LiveView socket's origin check
  on a desktop copy (`config/runtime.exs`) accepts the endpoint's host plus
  the listener's own `address:port` while it listens
  (`PhoneLan.origin_allowed?/1`).
* `Mobile.create_enrollment/2` refuses on a desktop copy unless the switch
  is on (`ensure_reachable/0`), and the QR's link is
  `http://<address>:<port>/m/e/<token>`.

Like the board link, it is plain http on the hall network: a phone code and
the session cookie cross it unencrypted. That is the trade the board link
already made; the codes are short-lived and revocable.

### The board's result beside the entered one

With live boards (Alnasl through the board link), every board on the phone
shows what the board in the hall saw (`BoardLink.summaries/1` and
`compare/2`): playing, the same result, a result not entered yet, or - in
red - a different one. It is a warning only; nothing is ever entered from
it. The page follows `BoardLink.topic/1` for new reports.

### Incidents: kinds, photos, the audit trail

Kinds as listed above; a helper still logs "arbiter call" only. A deputy's
dialog has a camera input: the phone shrinks the picture to 1600 px JPEG
(quality 0.8) before queuing it, an entry with a photo is sent in a request
of its own, and the photo is removed from the phone once answered. The
server checks it is base64, at most 2 MB decoded (`Incidents.photo_max/0`)
and a JPEG by its first bytes, then keeps it in `incident_photos` (one per
incident, `ON DELETE CASCADE` from both the tournament and the incident; not
in the export envelope). It is served only at
`/t/:id/incidents/:incident_id/photo` (`IncidentPhotoController`), to
whoever may open the desk pages, `nosniff`, `private, no-store`; a 404 for
anyone else, arbiters included. Every incident is also an audit row
(`incident.logged`, in the Pairings filter).

### The hall view

* Playing or finished on every board.
* The round clock: since the round's pairings were published
  (`Round.published_at`, when it is in the past), or failing that since the
  first board report of the round (`BoardLink.first_report_at/2`); the line
  says which. A round with neither has no clock - rounds have no recorded
  start time, and a clock from the moment of pairing would be wrong.
* Search by name or board number (finished boards included in the results).
* "My boards": the range the desk assigned to this arbiter's account, one
  tap. The existing from-to filter is the table-range version for anyone.
* Two entries that disagree: the compare-and-set already refused the second;
  now it is also announced on `Mobile.hall_topic/1` and shown in red on the
  board on every phone in the hall, until dismissed or the board changes.
  The direct (no-JavaScript) tap does the same check via
  `phx-value-expected`.
* Keep the screen on (Screen Wake Lock API; the button is hidden where the
  browser has none) and a one-handed layout (controls along the bottom
  edge, bigger result buttons). Both are the phone's own settings, kept in
  `localStorage`.

### Still not built (the seams)

* Incident report: print and PDF per round or tournament, and carried in
  the export/hand-off envelope.
* Arbiter-side incident editing: add from the desk, amend a note, mark
  resolved, delete one logged by mistake.
* Push notifications for "arbiter call" (Push API, VAPID keys).
* Clock times entered from the phone.
* Background Sync API to send while the app is closed.
* A round start time of its own (the clock then counts from it).

## Full app

Manubrium (as opposed to Manubrium Lite, the `/m` pages above) is a native
phone app, built with Capacitor from its own repository
([teapot-chess/Manubrium](https://github.com/teapot-chess/Manubrium),
Apache-2.0, kept apart from this one). It runs a tournament from a phone against one or
more OpenPairings servers at once: the round as its home screen, results
entered offline, Lite phones' results confirmed or rejected, incidents with
a photo, and, for the organiser and editors, a new tournament, pairing,
hand edits, publishing, standings, players (from the rating lists too),
check-in, requested byes, the mid-event settings and the hall boxes' codes.

### Architecture

```
phone (Capacitor app)                      server
---------------------                      ------
server list (one token per server)
  |  native HTTP (CapacitorHttp):          /api/manubrium/v1   (JSON, Bearer)
  |  no browser, no cookie, no CORS          ManubriumApi.Auth  token -> device -> scope
  |                                          TournamentController / PlayerController
round screen  ---- GET round ------------>   ManubriumApi.Json  (read-only presenters)
result taps   ---- POST sync (queued) --->   Mobile.Sync.submit  (the hall's queue)
pair/publish  ---- POST/PUT (online) ---->   PairingsEngineWeb.DeskActions
hand edits    ---- POST edits (online) -->     (also called by PairingsLive / PlayersLive)
players, settings - POST/PATCH (online) ->
Lite results  ---- POST confirm/reject -->   Mobile.PhoneResults (reads the audit trail)
photos        ---- POST photo (online) -->   Incidents.attach_photo/4
```

Nothing in the API decides a rule. Every write is a function the desk or
the hall pages already call:

| What | Function | Shared with |
|---|---|---|
| results, incidents | `Mobile.Sync.submit/2` under the device's phone code | Manubrium Lite's queue |
| clearing a result | `Manubrium.clear_result/4` (the deputy clear) | Lite's clear |
| pairing the next round | `DeskActions.pair_next_round/3` | the Pairings page |
| unpairing the latest round | `DeskActions.delete_round/3` | the Pairings page |
| a round's public level | `DeskActions.set_publish_level/4` | the Pairings page |
| a new tournament | `DeskActions.create_tournament/2` (the account's defaults, the derived type, seeded round dates, `Quotas`) | the "New tournament" form |
| player search, adding from a list | `PlayerLookup.search/3`, `fide_values/4`, `bel_values/2`, then `DeskActions.create_player/3` | the Players page's add form |
| late entry, player edits, check-in, requested byes | `DeskActions.create_player/3`, `update_player/5` | the Players page |
| hall boxes' codes | `BoardLink.list_links/1`, `create_link/3`, `revoke_link/3`, `BoardLinkAddress.connect_code/2` | the Boards settings page |
| hand edits | `DeskActions.hand_edit/5`, `finish_hand_edits/4` | the Pairings page's swap, absent, bye, fill, pool and delete, and its "Finish hand edits" |
| mid-event settings | `DeskActions.update_settings/3` (`Tournaments.update_tournament/2`, locks included) | the Settings pages |
| a Lite phone's result | `Mobile.PhoneResults.confirm/5`, `reject/5` | the hall's clear, for the rejection |
| an incident's photo afterwards | `Incidents.attach_photo/4` (`check_photo/1`) | Lite's photo in the queue |

Where the desk would open a dialog and ask - the pairing-number question,
the FIDE departure guard, bye exclusions, a round of hand edits in
progress, a round robin's whole schedule, a team event - the API refuses
with `409` and a sentence saying to do it at the desk. It never answers the
question on the arbiter's behalf. The confirmations a phone can sensibly
give are asked instead: postponed-game warnings before pairing
(`next_round.warnings`, sent back as `acknowledged`), the player-edit
confirmations, and the hand-edit dialog's questions (all three as
`409 needs_acknowledgement` with `confirm` ids).

### Hand edits

`POST /rounds/:n/edits` takes one edit, the Pairings page's own:

| `kind` | Fields | What |
|---|---|---|
| `swap` | `a`, `b` (player ids) | two seated players trade seats (the same board: a colour swap); one seated and one from the pool: a substitution |
| `vacate` | `player`, `bye_type?` | a seated player is not playing; `bye_type` (`requested-half`, `requested-zero`, `full-point`) only where the tournament asks the type, else `absent` |
| `bye` | `pairing` | the player left alone on a board gets the pairing-allocated bye |
| `fill` | `pairing`, `player` | a pool player takes the empty seat |
| `pool_pair` | `a`, `b`, `board?` | two pool players on a new board |
| `pool_bye` | `player` | a pool player gets the pairing-allocated bye on a new board |
| `delete` | `pairing` | an empty last board is removed |

The first edit of a round opens its manual pairing alteration from the
boards as they were (Q65), as the page does. The questions the desk's
confirmation dialog asks come back as `409 needs_acknowledgement` with
`confirm` ids, the edit's `summary` and the pairing-rule `warnings` as
sentences: `frozen_round` (not the latest round), `sent_round_changed`
(already sent for rating), `pairing_rules` (the boards break Q66/Q67),
`second_half_bye` (Q174). The app shows them and sends the same edit with
`acknowledged`. `POST /rounds/:n/edits/finish` is "Finish hand edits": a
vacant seat or no boards is `409`; boards the pairing checker would not pair
need `mpa_pibe` acknowledged (the `409` carries the checker's verdict as
`checker: {checked, line, missing, added, warnings}`), and the line is
recorded as the round's MPA PIBE. Team events stay at the desk
(`409 desk_only`): their boards count for matches.

### A Lite phone's result

The desk has one notion of a phone's result, and it is the audit row
`Mobile.log_result/6` writes (`via: "mobile"`, the code's label). There is
no column for it and the API adds none. `Mobile.PhoneResults.by_pairing/2`
reads the round's result rows: a board whose last write came from a phone
code that is not a connected Manubrium app's (the app's rows carry
`device_id`: those are the arbiter's own taps), and still holds that result,
is `phone: {by, state: "unconfirmed", at}` in the round. Confirming writes
`pairing.result_confirmed` and nothing else (`state: "confirmed"`);
rejecting clears the board as the hall's clear does and writes
`pairing.result_rejected`. Both take `expected` and answer `409 conflict`
with `current` when the board changed meanwhile. A result the desk changes
afterwards is no longer a phone's.

### Settings

`GET /tournaments/:id` gives the desk's roles `settings.editable` (the
fields of `DeskActions.phone_settings_fields/0` not locked now:
`Tournaments.locked_fields/1`), `configured_tiebreaks` and
`tiebreak_options` (`Tiebreaks.selectable/1`). The phone's fields are
`rounds_count tiebreaks time_control chief_arbiter deputy_arbiter venue city
bye_value ask_bye_type shared_places`: what an arbiter changes mid-event,
nothing structural. `PATCH /settings` ignores any other field and writes
through `Tournaments.update_tournament/2`, so FIDE mode's locks answer
`422 locked_in_fide_mode` exactly as the Settings page would. Tie-breaks
must come from the tournament's own catalogue, each once. Audited as
`tournament.settings_updated` with `via: "mobile"`.

### A new tournament

`GET /tournament-options` is what the "New tournament" screen offers:
`systems` (`Tournament.pairing_systems/0`, the form's own list, with its
labels), `player_sources` (`fide` always; `bel` only when the account has the
Belgian player lookup on AND this installation has a member list:
`PlayerLookup.bel_available?/1`) and `defaults` (the form's starting values
with the account's own defaults over them: `system`, `rounds_count`,
`time_control`, `city`, `venue`, `federation`, `rated`).

`POST /tournaments` takes `{tournament: {name, start_date, end_date, city,
venue, system, rounds_count, time_control, federation, rated}}` and creates
through `DeskActions.create_tournament/2`, the function the web form calls,
with the phone's account as owner. The app's names map onto the form's:
`system` is `pairing_system`, `time_control` is `rate_of_play` (the field
every report reads; the old free-text `time_control` column is left alone),
`rated` is `fide_homologated`. Start and end dates are not stored as such
(the tournament derives them from its round dates): every round is dated to
`start_date` as the form does, and a different `end_date` dates the last
round. Dates are `YYYY-MM-DD`; an end before the start is `422 bad_date`.
Always an individual event: team events are made at the desk. The hosted
edition's limit answers `409 tournament_quota`. The answer is `201
{tournament}`, a line of `GET /tournaments`.

### Players from the lists, and check-in

`GET /tournaments/:id/player-search?q=&source=fide|bel` is the Players page's
add-form search (`PlayerLookup.search/3`): at least three characters
(`422 query_too_short`), at most 25 results, `source=bel` only where
`bel` is offered (`422 unknown_source`). Each result is
`{source, fide_id, national_id, name, federation, title, sex, birth_year,
fide_rating, national_rating, club, already_in}`, the values picking it
would fill in: the main rating list's rating (`RatingLists.main_values/2`),
and with the Belgian lookup on, a FIDE hit's member details. `already_in` is
a player with that FIDE id or national id in the tournament.

`POST /players` with `{player: {from: {source: "fide", fide_id}}}` or
`{from: {source: "bel", national_id}}` (and `start_round` beside `from` if
wanted) adds the player exactly as that pick and Save would. One already in
the tournament is `422 duplicate_player`; an id the list does not have is
`404 not_in_list`.

There is no separate check-in field. The desk marks a player who has not
turned up with the Players page's "Pr." column, which is `absent` (the whole
event: not paired at all). The player JSON has `present` (its opposite), and
`PATCH /players/:pid` takes `{player: {present: true|false}}`.

### Requested byes

The player JSON carries `byes: [{round, kind}]`: the rounds in
`absent_rounds`, each with its typed bye (`ByeTypes`, the `byes` table) or
`absent` where there is none. `GET /tournaments/:id` carries
`bye_kinds: [{id, label, points}]`: where the tournament asks the bye type
(`ByeTypes.applies?/1`: `ask_bye_type`, an individual Swiss) the dialog's
three, `requested-half`, `requested-zero`, `full-point`; otherwise only
`absent`, worth what the tournament pays an absence (`points` is before any
limit).

`PUT /players/:pid/byes` takes `{byes: [{round, kind}], acknowledged?}` and
replaces what the player asked for the rounds not yet paired; the paired
rounds' absences stay as they are. It writes `absent_rounds` and
`bye_types` through `DeskActions.update_player/5`, as the player dialog
does, so its confirmations come back the same way (`409
needs_acknowledgement`: `second_half_bye`, `sent_round_changed`). A paired
round is `422 round_paired`; a kind the tournament does not offer is `422
unknown_bye_kind`; a round outside the tournament or named twice is `400`.
The organiser and editors only, as on the Players page.

### Sharing

`GET /tournaments/:id` carries `openresults_url`: the results site's page
(`PublicLink.url/1`, what every desk page links to), or null when the
tournament is not on the results site. The app writes its own share text.

### Hall boxes (Alnasl)

A board never enters a result (`PairingsEngine.BoardLink`). What a box
reported for a game is in the round, beside the result: each board has
`board_report`, null or `{status, result, mismatch, moves_count,
updated_at}` (`BoardLink.summaries/1`). `mismatch` is
`BoardLink.compare/2`'s red case: a board result that differs from the
entered one, a forfeit compared by who got the point. `status` is the
box's `waiting`, `live` or `finished`; `moves_count` counts full moves,
not plies.

`GET /tournaments/:id/board-links` lists the codes that reach the tournament,
its own and its group's: `{links: [{id, kind, label, hint, reach, created_at,
last_seen_at}]}`, `kind` `tournament` or `group`, `reach` `lan` (a desktop
copy's code for a box on its network) or `server`, `label` what the box
called itself or else the code's last four characters (`hint`). Account
codes are the account's business and are not listed. `POST` makes a code
for this tournament (`{where: "lan"}` asks for a network code on a desktop
copy, as the Boards page does; `409 lan_unusable` when the listener cannot
take one) and answers `201 {link, code}`, `code` the full connect code the
box scans or types (`<address>/api/boards/v1#oplt_...`), shown this once.
Eight at most (`409 too_many_codes`). `DELETE /board-links/:lid` withdraws
one (`204`; `404 link_not_found`). The organiser and editors only.

### Incident photos

A photo taken while logging travels inside the incident's sync entry
(`photo`, base64), as Lite's does. One taken afterwards is
`POST /incidents/:iid/photo` (`{photo: base64}`). Both go through
`Incidents.check_photo/1` - a JPEG by its first bytes, never by what the
sender called it, at most `Incidents.photo_max/0` (2 MB) - and are kept in
the incident's photo row in the tournament's own database, one per incident
(`409 photo_exists`; `413 photo_too_large`; `415 not_a_photo`). `GET
/incidents/:iid/photo` sends it back as `image/jpeg` with `nosniff` and
`private, no-store`, to the organiser and editors only - the people the
desk's incidents page shows it to. An arbiter's phone can send a photo; it
cannot read one back.

### Token model

1. A signed-in account makes a **connect code** on the account page
   (Account, Manubrium app, "Connect a phone"): a 256-bit one-time secret,
   ten minutes, shown as a QR code of
   `manubrium://connect?server=<base url>&secret=<secret>`. Only its SHA-256
   is stored (`manubrium_connect_codes`).
2. The app trades it once (`POST /connect`) for a **device token**
   (`mnb_` + 256 bits), bound to the account and to that phone. Only its hash
   and last four characters are stored (`manubrium_devices`). The trade is a
   single conditional `UPDATE`, so two phones scanning one QR cannot both win.
3. Every request carries `Authorization: Bearer <token>`. No session, no
   cookie, no CSRF token.
4. The account page lists the devices and signs any of them out; the app can
   sign itself out (`DELETE /me`). Signing out is final, and revokes the
   device's phone codes with it.

A device has its account's rights and no more: `Tournaments.hall_role/2` and
`Tournaments.get_authorized_tournament/2` are asked on every request, so an
arbiter taken off a tournament loses it on the phone at once. Results are
entered under a claimed, account-bound deputy phone code per device and
tournament (`Manubrium.enrollment_for/2`, `mobile_enrollments.device_id`), so
the audit trail names the account, and the desk's list of phones shows
"Manubrium: <phone name>".

Rate limits (`PairingsEngine.RateLimit`): `:manubrium_connect` (codes per
account, 20 an hour), `:manubrium_redeem` (refused trades per address, 10 per
ten minutes), `:manubrium_auth` (refused tokens per address, 30 per ten
minutes), `:manubrium_api` (requests per device, 600 a minute).

### Roles

| Role | `can` | Routes |
|---|---|---|
| owner, editor | `results incidents pair publish players standings settings` | all |
| arbiter | `results incidents` | the list, a tournament, a round, sync, clear, confirm and reject a Lite phone's result |

Anything else answers `403 arbiter_role` for an arbiter and
`404 tournament_not_found` for an account with no role on the tournament
(the same answer as for a tournament that does not exist).

### Desktop

A desktop copy has no accounts: the local owner is signed in on loopback.
That owner opens the account page on the PC and makes the code like anyone
else, but the code carries the phones' network listener's address
(`PhoneLan.status().base_url`), not the loopback one. That listener
(`PairingsEngineWeb.PhoneLan`) serves `/api/manubrium/v1/*` beside the Lite
pages, and is open while the switch "Let phones on this network connect" is
on and a phone code, an unused connect code or a connected device exists.
With the switch off the account page refuses to make a code and says why.
The API's results path also needs the switch (`Mobile.create_enrollment/2`
refuses `:local_mode` without it; the API answers `409 phones_off`).

### API

All under `/api/manubrium/v1`, JSON, errors as
`{"error": code, "message": sentence}`.

| Method and path | Who | Body | Answer |
|---|---|---|---|
| `POST /connect` | anyone with a code | `{secret, name?, platform?}` | `201 {token, device, user, server}`; `401 invalid_code`, `429` |
| `GET /me` | device | | `{device, user, server}` |
| `DELETE /me` | device | | `204`, token withdrawn |
| `GET /tournament-options` | device | | `{systems: [{id, label}], player_sources: [{id, label}], defaults}` |
| `GET /tournaments` | device | | `{tournaments: [{id, name, role, status, rounds_count, paired_rounds, ...}]}` |
| `POST /tournaments` | device | `{tournament: {name, start_date, end_date, city, venue, system, rounds_count, time_control, federation, rated}}` | `201 {tournament}`; `422 invalid`, `422 bad_date`, `409 tournament_quota` |
| `GET /tournaments/:id` | hall | | `{tournament: {can, rounds: [{number, publish_level, missing_results}], next_round: {number, blocker, warnings}, settings, bye_kinds, openresults_url, ...}}` |
| `GET /tournaments/:id/rounds/:n` | hall | | `{round: {number, latest, publish_level, boards: [{id, board, label, white, black, bye, vacant, empty, result, clearable, phone, board_report}], byes, pool: [{player, type, absent}], hand_edits: {open, pibe}, results}}` |
| `POST /tournaments/:id/sync` | hall | `{entries: [...]}` (at most 25) | `{results: [{cid, status, reason, message}]}` |
| `POST /tournaments/:id/rounds/:n/boards/:pairing/clear` | hall | `{expected}` | `{status: "cleared"}`; `409 conflict` with `current` |
| `POST /tournaments/:id/rounds/:n/boards/:pairing/confirm` | hall | `{expected}` | `{status: "confirmed"}`; `409 not_from_phone`, `409 conflict` |
| `POST /tournaments/:id/rounds/:n/boards/:pairing/reject` | hall | `{expected}` | `{status: "rejected"}`, board cleared; as above |
| `POST /tournaments/:id/rounds/:n/edits` | desk | `{edit: {kind, ...}, acknowledged}` | `{round}`; `409 needs_acknowledgement` with `confirm`, `summary`, `warnings`; `422` for an edit that does not fit |
| `POST /tournaments/:id/rounds/:n/edits/finish` | desk | `{acknowledged}` | `{pibe, round}`; `409 needs_acknowledgement` with `checker`, `409 vacant_seat`, `409 no_hand_edits` |
| `PATCH /tournaments/:id/settings` | desk | `{settings: {field: value}}` | `{settings}`; `422` for a locked field or an unknown tie-break |
| `POST /tournaments/:id/incidents/:iid/photo` | desk | `{photo: base64 JPEG}` | `201 {incident}`; `409`, `413`, `415` |
| `GET /tournaments/:id/incidents/:iid/photo` | desk | | the JPEG; `404` |
| `POST /tournaments/:id/rounds` | desk | `{acknowledged: [warning ids]}` | `201 {round}`; `409` for every desk question |
| `DELETE /tournaments/:id/rounds/:n` | desk | | `204`; `422` unless it is the latest |
| `PUT /tournaments/:id/rounds/:n/publish` | desk | `{level: 0..3}` | `{round, publish_level}` |
| `GET /tournaments/:id/standings` | desk | | `{standings: {tiebreaks: [{code, name}], tiebreaks_through, rounds_paired, rows: [{rank, player, points, tiebreaks}]}}` - points count every result entered, tie-breaks only rounds 1..`tiebreaks_through` (the complete ones), as on the Standings page |
| `GET /tournaments/:id/incidents` | desk | `?round=n` | `{incidents: [...]}` (no photos) |
| `GET /tournaments/:id/players` | desk | | `{players: [{..., present, absent_rounds, byes: [{round, kind}]}]}` |
| `GET /tournaments/:id/player-search` | desk | `?q=&source=fide\|bel` | `{results: [...]}`; `422 query_too_short`, `422 unknown_source` |
| `POST /tournaments/:id/players` | desk | `{player: {name, title, sex, fide_id, ratings, federation, club, birth_year, start_round}}` or `{player: {from: {source, fide_id \| national_id}, start_round?}}` | `201 {player}`; `422 duplicate_fide_id`, `422 duplicate_player`, `404 not_in_list` |
| `PATCH /tournaments/:id/players/:pid` | desk | `{player: {basic fields, withdrawn, present, absent, absent_rounds: [n], bye_types}, acknowledged}` | `{player}`; `409 needs_acknowledgement` |
| `PUT /tournaments/:id/players/:pid/byes` | desk | `{byes: [{round, kind}], acknowledged}` | `{player}`; `422 round_paired`, `422 unknown_bye_kind`, `409 needs_acknowledgement` |
| `GET /tournaments/:id/board-links` | desk | | `{links: [{id, kind, label, hint, reach, created_at, last_seen_at}]}` |
| `POST /tournaments/:id/board-links` | desk | `{where?: "lan"}` | `201 {link, code}`; `409 too_many_codes`, `409 lan_unusable` |
| `DELETE /tournaments/:id/board-links/:lid` | desk | | `204`; `404 link_not_found` |

A sync entry is Lite's entry without the `enrollment` field (the server
fills in the device's own): `{cid, kind: "result", round, pairing, board,
white, black, result, expected}` or `{cid, kind: "incident", round, pairing,
board, type, note, at?, photo?}`. The `cid` makes a resend harmless. An entry
without a `pairing` is refused as `no_board`: every incident belongs to a
board. The app's sentences are worded for an account that is itself the
arbiter (`MobileAppController.wire/2`, `:account`): a refusal never tells the
organiser to check with the arbiter.

For the app's web bundle on a developer's screen, `config/dev.exs` lists the
Vite dev server's origins (`:manubrium_dev_origins`) and
`PairingsEngineWeb.Plugs.ManubriumDevCors` answers their preflights. No
other config sets it; the installed app needs no CORS at all.

### Not built yet

- Hand edits of team events, and the desk's own questions before pairing
  (above), stay at the desk.
- Results Lite refuses for the desk (a decisive postponed game, a correction
  after the next round is paired, a round already sent to FIDE) are refused
  in the app too, with the same sentence. Acknowledging them from a phone is
  a later decision.
