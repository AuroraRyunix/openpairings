# Manubrium - the arbiter's phone app

Manubrium is what `/m` (no-account mobile result entry) becomes: an
installable web app (PWA) on top of the same enrolment, the same session and
the same permission checks. There is no store build. An Apple developer
account does not exist, nothing needs installing from a store, and the phone
talks to the same server whether that is pairings.cloud or any other hosted
copy.

Phone enrolment stays hosted-only (`Mobile.ensure_hosted/0`): a desktop
install binds to loopback and has no accounts, so no phone can reach it and
an enrolment token would be the one credential that works from off the box.
Manubrium does not change that. The PWA itself has nothing hosted-specific
in it; it works wherever `/m` answers.

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
(`illegal_move`, `clock`, `device`, `dispute`, `arbiter_call`, `other`),
`note`, `occurred_at` (the phone's clock, if within a day of the server's;
otherwise the time it arrived), the enrolment id and its label at the time,
`source` (`"phone"`), `client_id`. Listed per round at
`/t/:id/incidents` (linked from the Pairings page's More menu, and from a
line under the round when it has any). Kept by snapshot restores like the
audit trail, deleted with the tournament. Not in the export envelope yet
(see phase 2).

### Who can use it

Manubrium needs a hosted server: enrolment stays hosted-only, so a phone
cannot be enrolled against a desktop install (that is unchanged by the
PWA). On an iPhone a home-screen app has its own cookies, separate from
Safari's, so the phone is added to the home screen first and the code typed
in the app; enrolling in Safari and then installing leaves the app without
the enrolment. The code page and the Phone QR dialog say so.

### What `mix test` does not cover

The server half is tested (`test/pairings_engine/mobile_sync_test.exs`,
`test/pairings_engine_web/controllers/mobile_app_controller_test.exs`,
`test/pairings_engine_web/live/manubrium_live_test.exs`): idempotent
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
* the "Leave" confirm when entries are waiting.

## Phase 2 (not built; the seams)

* Incident report: print and PDF per round or tournament, and carried in
  the export/hand-off envelope (the table is shaped for it: round, board,
  players by id, kind, note, times, source).
* Arbiter-side incident editing: add from the desk, amend a note, mark
  resolved, delete one logged by mistake (`source` already says where it
  came from).
* Push notifications for "arbiter call" (needs the Push API and VAPID keys;
  the service worker is the place it would land).
* Clock times entered from the phone (an entry kind beside `result` and
  `incident`; the queue and `/m/sync` take new kinds without change).
* Photos of scoresheets (needs upload storage and a size budget; would go
  through the same queue, as a blob).
* The Alnasl live-board link: a board result from the hall relay shown
  beside the phone's entry.
* Background Sync API to send while the app is closed (Chrome only; today
  sending happens while the app is open).
