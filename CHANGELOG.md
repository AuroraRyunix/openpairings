# Changelog

All notable changes to OpenPairings are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.14.16] — 2026-08-12

### Added

- **Print button on the Players Card popup** (right-click a player on the
  Players page) — opens a new tab with that one player's round-by-round
  history (opponent, colour, result, running score) as a print-ready
  document, same data and table shape as the popup itself. New route:
  `GET /t/:id/print/card/:player_id`.

## [0.14.15] — 2026-08-12

### Added

- **Public standings link (`/p/:slug/standings`) now also shows the
  Category column** whenever the tournament has 1+ categories — it was
  added to the authenticated Standings page and print in 0.14.14, but
  missed the public page, which has no column-preference system at
  all and just needed the column added outright. Same "—" for an
  unassigned player, on both the FIDE-tiebreak table and the Keizer
  ladder.

## [0.14.14] — 2026-08-12

### Added

- **Standings page now shows a Category column whenever the tournament
  has 1+ categories defined** — printed standings already did this
  (Category column plus one sub-table per category); the live
  Standings page never had a Category column at all. Shows
  unconditionally once the tournament has any categories — not gated
  by the Players page's column-visibility tickbox, matching print's
  own always-on behavior. Covers both the FIDE-tiebreak table and the
  Keizer ladder.

## [0.14.13] — 2026-08-12

### Fixed

- **Changing an already-set result didn't show up for another arbiter
  viewing the same round, if they had that board's result dropdown
  focused** — confirmed by hand: the write and the live broadcast both
  worked correctly (the database and every other part of the page
  updated), but that one `<select>`'s displayed value stayed stuck on
  the old result, even after clicking away from it. Root cause is a
  genuine Phoenix LiveView behavior (protecting a focused form control
  from a server-pushed value change, so it doesn't clobber in-progress
  typing) that doesn't fit a discrete-choice dropdown like this one. The
  real result is now also mirrored into a plain `data-result` attribute,
  which always patches through regardless of focus; the result select's
  hook resyncs its value from that on every update, closing the gap
  without disturbing whatever the arbiter is doing.

## [0.14.12] — 2026-08-12

### Removed

- **The "Round N was just updated by another arbiter" notice, entirely**
  — repositioning it as a fixed toast (0.14.11) didn't fix the
  underlying complaint: it still popped up and grabbed attention
  mid-click regardless of where on screen it sat. The round data itself
  keeps refreshing live via the existing broadcast the moment anyone
  enters a result elsewhere — that always worked and still does; only
  the popup announcing it is gone.

## [0.14.11] — 2026-08-12

### Fixed

- **"Round was just updated by another arbiter" notice pushed the whole
  board list down for everyone else viewing the round** — it sat inline
  above the pairings table with a plain margin, so it appearing the
  instant someone else entered a result visibly shifted every board
  underneath it, right as another arbiter might be reading or clicking
  one. It's now a fixed-position toast that overlays instead of pushing
  layout — same idea the existing flash-message toast already uses,
  just anchored top-center. Also gave each board row a stable DOM `id`
  so a remote update always patches rows in place rather than risking
  a full node swap that could drop focus from an open result dropdown.

## [0.14.10] — 2026-08-12

### Added

- **Each player's score coming into the round now shows next to their
  name on the pairing list** — the authenticated Pairings page, the
  public pairings page, the projector/live view, and the printed
  pairing list all show it now, e.g. "Alice (2400, 2.5)" (rating and
  score together where a rating exists, just the score otherwise). This
  is the score BEFORE the round shown, not after — the same figure a
  real printed pairing sheet has always shown, computed fresh per round
  so it's correct even when browsing a past round.

## [0.14.9] — 2026-08-12

### Fixed

- **The public pairings page (`/p/:slug/pairings`) and the projector/live
  view (`/t/:id/live`) never used the same board display logic as the
  authenticated Pairings page** — both just sorted by raw `pairing.board`
  with no relabeling at all, so the moment a tournament had a fixed-table
  ("special") board, a bye, or an absence, they'd silently disagree with
  the arbiter's own Pairings page and with print: a real board 10 showed
  "10" there, "1001" everywhere else, for the exact same game. Both now
  go through the same `PairingDisplay` module as the Pairings page and
  print, so every surface shows identical board numbers and row order.

## [0.14.8] — 2026-08-12

### Fixed

- **Marking a player absent (or otherwise changing a bye) renumbered
  every other board in the round** — a real regression from 0.14.6's
  "byes/absences sort below the special boards" change: pulling a bye
  or vacant seat out of the ordinary numbering sequence to move it
  visually to the bottom also shrank that sequence, shifting every
  later board's displayed number. Board numbers are now computed once,
  together, from real board order regardless of bye/vacant/normal
  status — stable no matter what an arbiter does to any other board
  mid-round — while the ROW ORDER (byes/vacant sorted below the
  special boards, unchanged from 0.14.6) stays exactly as intended.

## [0.14.7] — 2026-08-12

### Fixed

- **FIDE lookup silently rewrote an already-filled name when the only
  difference was formatting** (case, punctuation, word order — e.g. an
  arbiter's own "Tom van 't Hoff" against FIDE's "Van 't Hoff, Tom"),
  with no confirmation prompt, even though a genuinely different name
  correctly asked first. The "don't bother asking about a pure
  reformat" shortcut turned out to be the wrong default for identity
  data — real report: a player's hand-typed name got rewritten with no
  warning. Any real change to an already-filled Name/Sex/Birth year
  now always asks first; only a byte-for-byte-already-correct value
  (re-running the lookup for no reason) still applies without a
  prompt, since there's nothing to actually change.

### Changed

- **Pairings table (and matching print documents) now order byes and
  vacant/absent seats below the special (fixed-table) boards** —
  previously a bye or an absence-vacated seat just sat wherever its real
  board number happened to fall among the ordinary boards. Order is now:
  ordinary boards, then byes, then vacant seats, then special boards
  (unchanged). A fixed-table player's own bye still sorts and labels as
  a special board, not as a bye row — the fixed-table label always wins.

## [0.14.5] — 2026-08-12

### Changed

- **Players page Pr. cell menu: clearer wording, and works on a plain
  click too** — a single player's Present/Absent toggle used to say
  "All Absent"/"All Present", easily misread as touching every player;
  it now just says "Absent"/"Present" for one row (the column
  header's genuinely-bulk menu keeps the "All" wording — right-click
  it to set everyone at once). Right-click wasn't discoverable to
  begin with, so a plain left-click on the cell opens the same menu
  now too.

### Verified

- **Fixed-board results and same-round byes don't cross-contaminate** —
  investigated a report that a fixed-board win looked mis-credited
  (it wasn't: a different player's matching score came from their own
  bye that round, entirely independent). Added a regression test
  (`PairingsEngine.StandingsTest`) that enters a result through the
  exact write path the UI/CSV import use and asserts every player's
  score end to end, confirming standings are keyed by player id start
  to finish — `PairingDisplay`'s board relabeling can't affect it.

## [0.14.4] — 2026-08-12

### Added

- **Sex (M/F) column on the Standings page and printed standings** —
  follows the same "sex" tickbox preference as the Players page on the
  live Standings view (shown by default until you touch the Display
  panel); always shown on the printed standings document (main table,
  per-category tables, and the Keizer ladder alike). Shows FIDE's own
  letters, same as the recent Players table fix.

## [0.14.3] — 2026-08-12

### Changed

- **"Norms" moved into the "Advanced" top-bar dropdown**, alongside Audit
  trail and Pairing rationale, instead of sitting as its own tab.
- **Cleaned up the "Advanced"/"Settings" dropdown chevron** — it now sits
  inline with the label (proper vertical alignment instead of a stray
  floating triangle) and flips to point up while the menu is open.

## [0.14.2] — 2026-08-12

### Fixed

- **Sex column showed the raw internal code ("M"/"W") instead of FIDE's
  own letters ("M"/"F")** — both on the Players table and on printed
  player lists. Storage is unchanged (still "m"/"w" internally, matching
  `Trf.trf_sex/1`'s export convention); only the display was wrong.

## [0.14.1] — 2026-08-12

### Changed

- **FIDE lookup now asks before overwriting a Name, Sex, or Birth year
  that's already on file and disagrees with FIDE's own record** —
  previously only a fuzzy name-search match staged its name behind a
  confirmation; an exact FIDE-ID match applied everything, including
  identity fields, immediately. Filling in a currently-blank value still
  applies right away either way (nothing to conflict with), and a name
  that's the same identity just reformatted (case, punctuation, word
  order — e.g. "tijl de moyer" vs FIDE's own "De Moyer, Tijl") still
  applies immediately too, not treated as a real change. Operational
  data (title, rating, federation) keeps applying directly on every
  refresh, since that's the expected, routine outcome of the button —
  FIDE publishes a new list monthly and this is how ratings actually
  get updated. Multiple conflicting fields on the same lookup are shown
  together in one prompt.

## [0.14.0] — 2026-08-12

### Changed

- **Round-robin tournaments now pair their whole Berger schedule in one
  action instead of one round at a time.** A round-robin round's pairings
  never depend on prior results — the whole schedule is fixed the moment
  the player list is frozen — so there was never a reason to require a
  click per round the way Swiss does. "Pair round 1" is now "Pair the
  whole tournament," confirm-gated (it locks in who's playing; anyone
  added afterward isn't in the schedule, and it can't be changed once it
  exists). This also closes "I don't see all rounds in advance" — the
  whole schedule exists and is browsable right after that one click.
- **Round-robin's declared round count now always matches what the Berger
  schedule for the actual roster needs.** It used to be a free-typed
  number on the tournament-creation form (defaulting to a generic "9",
  the same default Swiss uses) with nothing tying it to the real math —
  "I get too many rounds" was a direct symptom of that mismatch, showing
  round tabs the schedule would never actually reach. `rounds_count` is
  now corrected to the real total (a pure function of player count plus
  cycles/match-format) the moment the round-robin pairing pass first
  freezes the player list, not a value the arbiter needs to compute by
  hand.

## [0.13.1] — 2026-08-12

### Fixed

- **The KBSB lookup button could find a player's FIDE ID but never used
  it** — if the player's FIDE ID was blank, "KBSB lookup" would fill it
  in from KBSB's own cross-reference, but the arbiter then had to click
  "FIDE lookup" a second time by hand to actually pull that player's real
  FIDE data (title, rating, federation, birth year). Now the FIDE data
  comes in automatically the moment KBSB supplies the ID that unlocks it.
  If the FIDE ID KBSB found isn't in the local FIDE copy (e.g. not synced
  recently), KBSB's own fields are still applied rather than discarded.

## [0.13.0] — 2026-08-12

A batch of smaller fixes and features from one round of feedback.

### Added

- **"Leave" a shared tournament.** A collaborator could never remove
  themselves from a tournament someone else shared with them — only the
  owner could remove a collaborator. Leaving is now self-service, right
  next to the (still owner-only) Delete button on the tournament list.
- **"Copy" (duplicate) a tournament**, named "Copy of &lt;original&gt;" —
  available to the owner and any collaborator, reusing the same export/
  import round trip Settings > Export/backup already relies on. The copy
  is owned by whoever clicked it; no collaborators carry over.
- **Fixed-table ("special board") pairings are now really renumbered**,
  not just annotated. A player with a Fixed table set (Players page) used
  to just get a "(table N)" note next to their ordinary board number,
  leaving no visible gap. Now the ordinary boards close the gap a pulled-
  out fixed-table board leaves (board 10 -> fixed_board 1001 means
  whoever was board 11 becomes displayed board 10), and fixed-table
  pairings move to the end of the Pairings page and the printed
  board-order pairing list, sorted by their own table number. Two
  fixed-table players paired against each other show as one row. The
  player edit modal now warns (doesn't block — sharing a table is valid
  when paired together) when a Fixed table value is already used by
  someone else.
- **Standings columns follow the Players page's Display panel.** We/W-We,
  tiebreak columns, and XtPts/Total used to always show on Standings;
  now unticking a column on Players hides it here too (shared
  localStorage preference, defaults to "show everything" for anyone
  who's never touched the Display panel).
- A top-level **Changelog page** (`/changelog`), next to Tournaments and
  Tools — it used to be buried at Settings > Changelog, needing a
  specific tournament in context even though the content is entirely
  app-wide.

### Changed

- The top-left nav link reads **"Home"** instead of "Tournaments" once
  you're inside a tournament — same destination, clearer label for
  leaving the tournament context.
- Tournament list: a single-day tournament shows just the one date
  instead of "date -> date"; finished tournaments get their own badge
  colour instead of looking identical to running ones.
- FIDE rating-list downloads (~41 MB, network fetch) are now limited to
  SSO-signed-in accounts. Local self-registration is open to anyone, so
  without this, anyone could sign up and repeatedly trigger the full
  download.

### Fixed

- **FIDE lookup didn't fill in Sex (M/F)** — added, normalized from
  FIDE's raw "M"/"F" to the app's own "m"/"w" convention.
- **The topbar accent-picker/theme-picker (and the Advanced/Settings
  dropdowns) sometimes didn't open on the first click** — an open
  popover's panel could cover the next trigger over. All four now share
  an exclusive `<details>` group, the browser-native fix.
- **The pairing-rationale "Pre-round score brackets" chart ignored the
  theme system** — every colour (band backgrounds, player dots, floater/
  rematch connector lines, the fairness sparkline) was fixed light-theme
  hex, unreadable under every other theme.
- **A tournament's uploaded logo only ever showed on place cards** —
  every other print document (pairing list, standings, player list/
  cards, crosstable, result cards) never rendered it at all.

## [0.12.3] — 2026-08-12

### Fixed

- **The player edit modal's fields weren't live-synced to the server at
  all** — typing a corrected name or FIDE ID only changed the browser's
  copy; the server-side form stayed exactly as it was when the modal
  opened until Save was clicked. Clicking "FIDE lookup" or "KBSB lookup"
  right after typing something new silently searched on the *old* value
  instead (or, if a FIDE ID was already on file from before, used that
  instead of a freshly-typed name — which is also why the name-correction
  confirmation could seem to not fire: it was really taking the exact-ID
  path on stale data, not skipping the check). The whole modal now syncs
  on every field change, matching what Save would actually submit.

## [0.12.2] — 2026-08-12

### Changed

- **FIDE lookup now corrects the player's name, not just the
  ID/rating/federation/birth year.** By FIDE ID (an exact, unambiguous
  match) the name is corrected immediately, same as every other field. By
  name only (a fuzzy best guess), everything else still fills in right
  away, but the name goes behind a "FIDE has this player's name as
  '…' — correct it? Yes/No" prompt instead of silently overwriting
  whatever was typed by hand.

## [0.12.1] — 2026-08-12

### Fixed

- **A player unrated in a tournament's own tempo (Rapid/Blitz) showed as a
  literal 0 Elo instead of falling back to their Standard rating.** FIDE's
  list uses `0`, not a blank field, for "no rating in this list" — the
  fallback logic used `||`, which doesn't treat `0` as absent in Elixir, so
  it never fired. Affects the tempo-aware FIDE lookup added in 0.12.0; also
  fixed the raw Standard/Rapid/Blitz hint on the player dialog, which had
  the identical bug.

## [0.12.0] — 2026-08-11

The version number sat at 0.11.1 for five weeks while the app kept
shipping — this release is everything that landed in that gap, in one
batch rather than the many small ones it should have been. Going
forward this file gets an entry every time the version bumps.

### Added

- **SWAR `.swar` v7 export** — a real, opinionated SWAR file OpenPairings
  can write from any tournament, not just import. Settings → Export /
  backup.
- **Hand-editing a paired round** — right-click any player on the
  Pairings page to swap them with someone else, mark them absent, award
  a bye, or fill an empty seat from the round's "not playing" pool. Two
  people sitting the round out can be paired straight into a new board.
- **Threshold prize categories** — a category can now be "below/above
  this Elo" or "below/above this age" instead of only a hand-picked
  name, with a one-click "Assign categories" button that fills in every
  player at once.
- **Public self-registration** — players can register themselves for a
  tournament without an arbiter account (off by default, rate-limited).
- **Mobile "enrol a phone"** — no-account result entry from a phone at
  the board, for arbiters or helpers without a login.
- **Automatic FIDE title-norm judgment (B.01)** on the Norms page.
- **TRF06 import support**, and VCL.13's asymmetric ½-0 / 0-½ result
  code across the whole pipeline.
- **Standalone single-file binaries** — no separate Elixir/Erlang
  install needed to run OpenPairings.
- **Alphabetical pairing list and printable score sheets.**
- Settings → About page: which pairing engine a tournament is using, and
  a credits line.
- 02cloud SSO (Keycloak) as an optional login method; configurable FIDE
  rating-list source URL.
- Light/dark theming and an accent-colour picker — now with 4 more accent
  colours (Indigo, Cyan, Orange, Fuchsia, 11 total) and 5 more full themes
  (Solarized Dark, Nord, Dracula, Catppuccin Mocha, Gruvbox Dark) alongside
  System/Light/Dark, 8 total. The theme switch is now a popover instead of
  an inline button row, to fit them all.
- **Tempo-aware FIDE ratings** — a player's FIDE lookup/refresh now pulls
  the Standard, Rapid, or Blitz rating matching the tournament's own
  cadence (Settings → Options → Type), falling back to Standard when the
  player has no rating in that specific list yet. The player registration
  dialog shows all three alongside "Elo used" (whichever one the pairing
  engine actually reads). Changing a tournament's Type after players are
  already registered doesn't retroactively re-fetch anyone's rating — a
  save note points arbiters to the Players page refresh instead.

### Changed

- The Players page's right-click "Absent" now has a real bulk mode (the
  Pr. column header) that touches every player at once without
  disturbing anyone's individually-set absent rounds.
- Printed player lists follow exactly the columns ticked in the Display
  panel, instead of a fixed five.
- FIDE report generation (IT3/FA1/IA1/IT4): arbiters are no longer
  capped at two, the organizer is a searchable FIDE person instead of
  free text, and arbiter/organizer e-mail became mandatory for a
  download.
- JaVaFo's pairing input for round 2 onward is built in current-
  standings order rather than fixed pairing_number order — this is what
  a real SWAR-vs-OpenPairings pairing mismatch on the same data turned
  out to be.
- The bracket-map pairing-rationale view: unpin no longer stray-scrolls
  the hover panel, plus a head-to-head duo view.
- The "updated by another arbiter" toast (already on Pairings) now also
  shows on the Players page.
- Mobile result entry: forfeit and asymmetric-disciplinary result codes
  (1-0 FF, 0-0 FF, ½-0, etc.) are now reachable from a phone, behind a
  "More…" toggle per board rather than crowding the three main buttons —
  chosen over a long-press gesture, which has no visible affordance and
  behaves inconsistently across mobile browsers.

### Fixed

- **Results entered from a phone weren't being written to the audit
  trail at all** — every other way of entering a result was, mobile was
  simply never wired up. Now logs the same `pairing.result_entered`/
  `_changed`/`_cleared` actions the desktop flow does, attributed to
  "System" (no user account exists for an enrolled phone) with the
  enrollment's own label/id recorded so an arbiter can still tell which
  phone made the change.

- **Round 2+ pairing input had no tie-break for players equal on both
  score and rating** — JaVaFo's Dutch-system engine falls back to input
  order when a bracket has more than one structurally-equal pairing, and
  that fallback order was effectively arbitrary (unordered map
  enumeration), not a real rule. Found via the same real SWAR-vs-
  OpenPairings comparison above; fixed by adding `pairing_number` (FIDE
  Art. 1.14's starting-rank fallback) as the third sort key.
- **`SW321_PreBye` presence points** on pairing-allocated byes were not
  modeled at all — a real scoring gap for clubs running SWAR's 3-2-1
  point scale.
- **FIDE C.07's Cut-1 Exception** (Art. 16.5.1) was missing, and a
  trailing pairing-allocated bye was scored as a draw instead of a bye.
- **Article 16.4** unplayed-round tiebreak scoring (Buchholz / BHC1 /
  Sonneborn-Berger) was wrong for a specific unplayed-round shape.
- **SWAR `AbsValue` mapping** was backwards — a checked "pay ½ point for
  absence" box imported as 0 points, not 0.5.
- SWAR handicap-table boards were misplacing pairings in board order.
- The registration form's FIDE-id dropdown could silently fail to
  appear at all.

### Security

- Content-Security-Policy with a per-response nonce.
- Rate-limiting keyed on the real client IP; throttled magic-link sends
  and registration-form submissions.
- Mobile enrollment codes moved to a CSPRNG, 8 digits over one global
  space instead of per-tournament.
- Closed an `/invites` link enumeration issue; tournament owners can now
  disable or rotate a public link.
- Bumped `bandit` for a HIGH-severity WebSocket DoS advisory.

---

Versions before 0.11.1 are not itemized here — see the git history.
