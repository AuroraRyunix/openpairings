# Manubrium - the arbiter's phone app

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

* **Manifest** `GET /m/manifest.webmanifest` (`MobileAppController`):
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
