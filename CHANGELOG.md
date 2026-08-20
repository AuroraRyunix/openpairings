# Changelog

All notable changes to OpenPairings are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **The Paid column is editable straight from the players table** — click
  or right-click a player's Paid cell for "Paid" / "Not paid" / "Gratis",
  the same gesture the Pr. column already had for Present/Absent.
  Right-clicking the Paid column *header* applies one of the three to
  every player at once, matching Pr.'s "All Absent" / "All Present". The
  fee status was previously reachable only by opening a player for
  editing, which is several clicks each on a registration desk.

  Paid is not one of the columns shown by default — switch it on from the
  column picker first, as before.

- **Embedded pages default to the light theme.** A frame sits inside
  somebody else's page, which is overwhelmingly light, so following the
  visitor's OS dark-mode setting dropped a dark slab into the middle of a
  white club site. Embedded pages now default to light regardless of the
  OS, and stay light when it flips at sunset. Only the DEFAULT changes --
  picking a theme from the switch still works inside the frame, still
  wins, and still persists.

- **Embedded public pages size themselves, and no longer reload-loop.**
  Two follow-ups to the embedding support below, both found by actually
  putting it on a club site.

  The embedded page now posts its height to the host page whenever the
  content changes, so the iframe can be sized to fit rather than guessing a
  pixel value — a guess leaves the table scrolling in a small box or a slab
  of empty space under a short tournament. `docs/public-pages.md` has the
  snippet to receive it.

  And the embeddable pages now use a websocket that does not require the
  session cookie. A `SameSite=Lax` cookie is deliberately not sent to a
  cross-site iframe, so the normal socket connected with no session,
  LiveView rejected it, and the client retried forever — the page appeared
  to reload constantly on scroll and hover. Fixed with a second,
  cookie-free socket for those two pages, rather than by loosening the
  cookie for the entire app.

- **The public pairing and standings pages can be embedded in another
  site.** They previously sent `frame-ancestors 'none'` like every other
  page, so a club website putting one in an `<iframe>` got a blank frame
  and a console error. Those two now allow it:

  ```html
  <iframe src="https://your-host/p/SLUG/pairings"
          style="width:100%;height:600px;border:0"></iframe>
  ```

  Nothing else does — not the public registration form, the arbiter
  tools, the mobile result entry, or any logged-in page, where being
  frameable is a clickjacking risk rather than a feature. Set
  `PUBLIC_FRAME_ANCESTORS` to a space-separated origin list to allow only
  particular sites, or to `'none'` to switch embedding off entirely. See
  `docs/public-pages.md`.

- **A second Swiss pairing engine: Ainalrami, opt-in and beta** — the
  "multi-engine" item the login page has been advertising as coming soon.
  Settings → Options gains a "Swiss engine" control alongside the pairing
  system: **JaVaFo** stays the default and is unchanged, and
  [Ainalrami](https://github.com/AuroraRyunix/Ainalrami) — a from-scratch
  Dutch-system engine in pure Elixir, pinned as a `github:` dependency at
  an exact commit — is available as an alternative for club and non-rated
  events. It runs inside this app's own BEAM: no JVM, no jar, nothing to
  install alongside a release or a Burrito binary, which also means its
  tests are the first Swiss pairing tests in this suite that run on a bare
  checkout instead of being `@tag :javafo`-excluded.

  Both engines are handed the **byte-identical TRF**
  `Pairing.javafo_input/4` already built — the engine choice only decides
  what turns those bytes into pairs, and everything downstream
  (`create_round/5`, board freezing, absentee byes, standings) is shared and
  cannot tell which one answered. That keeps the two directly comparable on
  real tournament data rather than only on synthetic input, which is the
  whole point of having a second implementation.

  Three guards, all in the data layer rather than the UI, because "the UI
  hides the control" has never been enforcement here:
  - **Never on a FIDE-homologated tournament.** OpenPairings' entire FIDE
    story is FE1's *"Internal engine: NO — thru JaVaFo"*, exactly as Vega,
    Swiss Manager and TournamentService answer it, and JaVaFo's own
    endorsement is what then covers pairing legality. The changeset refuses
    Ainalrami on a homologated tournament **and** refuses ticking
    "FIDE-homologated" on a tournament already running Ainalrami — the
    reverse direction matters just as much, and checking only the changed
    field would have let it through.
  - **Locked after round 1**, via `Tournaments.locked_fields/1` (so
    `update_tournament/2` refuses it, not just the disabled select), same
    rule and same reason as `pairing_system` one level up: two independent
    Dutch implementations won't always agree, and swapping mid-event hands
    the new engine a history it didn't produce.
  - **Refuses rather than silently ignores anything it can't do.** Ainalrami
    reads every TRF extension this app emits — `XXR` (rounds), `XXP`
    (forbidden pairings and club/federation exclusions) and `XXA` (Baku
    acceleration) — so forbidden pairings and accelerated events work on
    either engine. That's new: Ainalrami's parser used to discard everything
    but `XXR`, which for this input is the worst way to fail, because an
    engine that ignores an `XXP` line still returns a complete, perfectly
    legal-looking round that just happens to seat two players who must never
    meet, and nothing downstream can tell. Integrating it here is what
    surfaced that; both extensions were implemented upstream rather than
    worked around, and the round is still refused outright — nothing
    written, reason named — if the generated TRF ever carries an extension
    the engine doesn't know. The check reads the generated file rather than
    the tournament's settings, so a future extension is caught by default
    instead of being quietly ignored.

    A late catch on that last point, found by a source sweep before any of
    this shipped: the integration parsed the `XXP` lines and then dropped
    them. `Ainalrami.Pairing.pair_next_round/2` takes forbidden pairs as an
    OPTION rather than reading them off the parsed file, and the call passed
    only the round count — so every explicit forbidden pairing and every
    club/federation exclusion was silently ignored, which is precisely the
    failure the guard above exists to prevent. The test that was supposed to
    cover it could not fail: it asserted that ranks 1 and 2 were not paired
    in round 1 of a six-player field, where the Dutch system pairs top half
    against bottom half and those two could never have met anyway. Both are
    fixed, and the replacement is four players — where the forbidden pair IS
    the natural pairing — with a control test pinning that.

  Round robin and Keizer are completely unaffected — they compute their own
  pairings and never consult the setting. See `docs/pairing-systems.md`.

- **"Save a restore point" on the History page** — restore points could only
  ever be created as a side effect of something else. `Snapshots.capture/4`
  was called from exactly four handlers, all of them in PairingsLive: pairing
  a round, unpairing one, pairing a whole round-robin schedule, and importing
  results from a CSV. Run a tournament the way small clubs actually do —
  register players by hand, tune the settings, type results in one board at a
  time, never touch an import — and the app took *no* snapshots at all. The
  History page then had nothing to offer a "Go back to here" button on, so
  the restore machinery that has been shipped for a while (branch tree,
  "Switch to this branch", the type-to-confirm modal) was invisible and the
  whole page read as a list you could only look at. That was the actual
  complaint behind "History is just a read-only thing".

  So: a button that takes one on demand, with an optional short label
  ("End of day 1", "before the appeal") that becomes the point's caption on
  the timeline. It goes through the same `Snapshots.capture/4` as the
  automatic ones — same payload, same retention, same branch tree, same
  restore path — under its own `snapshot.manual` action code so hand-saved
  points show a "saved by hand" badge and read apart from the ones the app
  took to protect an irreversible action. It's a write like any other:
  refused on an archived tournament, and logged to the audit trail.

  The empty state is honest now too. A tournament with no restore points
  yet says so, explains that hand-editing doesn't take one, and points at
  the button — instead of silently rendering a timeline with no actions on
  it, which is what made this look broken rather than merely unused.

  The automatic triggers are deliberately unchanged: these are full
  tournament copies, so adding more of them shifts storage behaviour for
  every existing tournament and deserves its own decision (candidates noted
  in `TODO.md`).

- **"Assign categories" now shows a dry-run preview before it writes
  anything** — clicking the button used to reassign every player's category
  instantly, no warning. It now computes the same rule decisions
  (`Tournaments.preview_auto_assign_categories/1`, the single source of
  truth the real write path now reuses too, so preview and apply can never
  drift apart) and shows a Player/From/To diff in a confirm modal, filtered
  to only the players who'd actually move. Cancel discards it with zero
  side effects; confirming re-checks current DB state rather than trusting
  the staged preview verbatim, so a concurrent edit mid-modal can't write
  stale decisions. A no-op roster (nothing would change) says so plainly
  instead of opening an empty diff.
- **"Substitute player" now shows both halves of the move, with real in/out
  arrows** — previously the confirm modal only showed the board seat
  changing, with no visual for where the outgoing player went or the
  incoming player came from. A new "Not playing list" row appears alongside
  the board row (the outgoing seated player arriving there, the incoming
  pool player leaving it), and the existing `.SwapArrows` journey-arrow
  mechanism — which matches identical names appearing once on the "before"
  side and once anywhere on the "after" side, across the whole modal, not
  just within one row — draws the two arrows automatically from that shape
  alone. No changes needed to the arrow-drawing code itself. This also
  fixes a real bug the old single-row layout had: the *unchanged* seat (say,
  White, when Black was the one substituted) still showed the same name on
  both its own before/after sides, so the old name-matcher drew a spurious
  arrow between White's two seats instead of showing anything for the
  actual substitution — misleading, since it looked like White had somehow
  moved. That seat still gets its own short "stayed put" arrow today (the
  same thing an unmoved partner in a two-board swap already got), but it's
  no longer the only, unexplained arrow on screen.

- **Hide a fully-vacated board, or delete the round's actual last one** — two
  ways to clean up a pairing row that's left over from marking both players
  on it absent, without ever risking the 0.14.6 board-renumbering bug class
  again. "Hide" (right-click the empty board, or from the new "Hidden
  boards" panel) is a display-only, fully reversible toggle — it's skipped
  by PairingsLive, LiveRoundLive, PublicPairingsLive and print docs, but the
  row, its frozen `display_board`, audit history and TRF/export data are
  completely untouched, and never interacts with `PairingDisplay`'s freeze
  mechanism at all. "Delete" is a real, permanent removal, but is only ever
  offered — and only ever accepted server-side — on the round's own current
  highest real board number, since deleting the trailing row is the one
  deletion that can never require renumbering anything after it. It goes
  through the same confirm-modal pattern as every other hand-edit gesture on
  this page.

### Changed

- **The login/registration hero no longer lists "multi-engine" as coming
  soon** — it ships (above), so the Swiss line now names both engines and
  the coming-soon row is down to TRF26 alone.
- **Result cards redesigned** — each player's name, rating/starting-№, and
  signature line used to be crammed onto one small row alongside a "Sign
  ___" blank; the name is now on its own, larger row, with the signature on
  a separate row below it instead of competing for space on the same line.
  The result row (1-0 / ½-½ / 0-1) is now genuinely centred — the trailing
  "other: ...." option previously used `margin-left: auto` to push itself
  right, which dragged the three main results left of true centre as a side
  effect.
- **Removed the "Print player cards" button** from the Players page — kept
  causing confusion with "Print place cards" right next to it and wasn't
  something arbiters actually used; the print route itself is untouched.
- **The swap-confirm modal (swap/vacate/fill/substitute/pair) is wider**
  (720px instead of 560px, the same `.pe-modal-wide` variant the categories
  preview above already uses) so names have more room before truncating.
- **Removed the "⇄ Board N" chip** from a cross-board swap's changed seat —
  confusing, and redundant with the journey arrows the modal already draws
  to show where a moved player came from. Also removed its now-fully-dead
  plumbing (`related_board`, threaded through three functions purely to
  feed this one chip) and the `flex-wrap` machinery that existed only to
  give it its own line.

### Changed

- **The History page is the restore-point tree now, not a merged event feed**
  — it used to interleave audit rows and restore points as peers, which broke
  down in three ways once it was actually used. Saving a point by hand wrote
  both a snapshot and an audit row, so it showed up twice. Audit rows carry no
  branch information, so after switching to a branch a result change still
  rendered at the top of the trunk, which is not where the tournament was. And
  the page carried filters for "players", "settings" and so on — questions
  about changes, which is the Audit trail's subject, not this page's.

  So the points are the timeline, and everything that changed between two of
  them is folded under the earlier one, collapsed until you open it. A branch
  can be collapsed to a single line. The kind filters are gone; the Audit
  trail keeps the full searchable log, and this page links to it. Day headings
  went too — one collapsed branch can stand in for points spanning several
  days, which headings couldn't survive — so each point carries its own date.

  The save box got a real label and an example instead of the placeholder
  "What is this point?", which read as a search field. And having exactly one
  restore point no longer looks broken: it is the point the tournament is
  already on, so it offers no "go back", and the page now says why instead of
  showing a save button and nothing else.

### Fixed

- **Settings now says where the chief arbiter lives** — the Officials
  fields sit on the Norms page, because that is what builds the IT3/FA1/IA1
  forms from them, but an arbiter looking for "chief arbiter" looks under
  **Settings**, and Settings said nothing at all. Reported by someone who
  could not find the field while holding a direct link to it. Settings →
  Tournament grew an "Officials" card that links to Norms and shows the
  current chief arbiter, or says it is not set and that this does not block
  pairing (it is a recommended field, not a required one). It edits
  nothing — moving the fields back is a separate question about what the
  Norms page is then for.

- **The accelerated TRF this app exports was malformed, and only JaVaFo
  would read it** — `XXA` lines carry Baku acceleration's virtual points,
  and the writer padded each player's starting rank to five columns instead
  of four. That put a single-digit rank in column 9 and left columns 5–8
  blank, shifting every value on the line one place right of where the
  format puts it. JaVaFo accepts the malformed form, which is exactly why
  this survived: JaVaFo has been the only thing that ever read these files.
  Any stricter reader rejects the line outright, so an accelerated
  tournament exported for a rating officer, an archive, or a second engine
  was silently unusable. Confirmed against the real bbpPairings binary,
  which reads the rank from columns 5–8 and each value four wide on a
  five-column stride, and proven by generating one accelerated TRF that
  differs only in this layout: the old form is refused as an invalid line,
  the new one parses — and JaVaFo pairs both identically, so no existing
  pairing changes.

- **The bracket map's variable dead space, under the graph** — on
  "Pre-round score brackets" there was sometimes a sizeable empty gap
  between the graph and the minimap strip below it, and sometimes none.
  Reported as intermittent; it was entirely deterministic. The canvas's
  inline `min-height` permanently reserved the room a *hover* popover needs
  below the lowest dot that opens downward, and because the above/below flip
  deliberately tests against the much taller *pinned* popover's room, on
  every round past the first essentially every dot opens downward — so the
  reservation cleared the graph's own floor by about 110px on most rounds
  and by nothing on the few whose bracket happened to be tall enough. Which
  round you looked at decided whether you saw a gap.

  Now both reservations are deferred, the same way the pinned one already
  was: the canvas rests at exactly the graph's height and grows via
  `:has()` only while a wrap is actually hovered, focused or pinned
  (`--pe-hover-min` / `--pe-pinned-min`). The popover can cover what sits
  under the chart while it's open, which is the deliberate trade — a
  tooltip overlapping its surroundings for as long as you hover is better
  than a permanent empty band under every chart. Nothing about the flip
  itself changed, so a pinned popover still always opens onto the side it
  reserved room on, and neither popover is clipped by the strip's
  `overflow-y: hidden`.

- **Something covering the corner of the "Everything" button on the History
  page** — the timeline's day headings paint an opaque 10px-wide mask over
  the rail so the date sits in a clean gap, and that mask deliberately
  overhangs 6px above the label to cover the rail's own inset. Above the
  *first* heading there is no rail to cover — the rail lives inside the
  `<ul>` below it — so the overhang only reached up into the filter row,
  which sits directly above with no margin between them, and landed exactly
  on the bottom-left corner of the first filter button. The first day group
  is now marked server-side (`.tl-first-day`) and drops the upward overhang;
  later headings, which genuinely do have rail above them, are unchanged.
  The marker has to come from the server because each heading is the first
  child of its own day group, so `.tl-day:first-child` matches every one of
  them rather than the first.

- **Three real "vacated seat" crashes in the "Explain this round" page and
  its underlying analysis, found and fixed over one afternoon as each one
  surfaced the next.** `Tournaments.vacate_seat/3` can empty EITHER colour's
  seat (not just the one a bye already leaves empty), which turned out to
  be a state nothing downstream actually expected:
  1. `PairingRationale.board_context/7`'s rematch check assumed White is
     always present whenever the board isn't a formal bye — crashed with
     `key :id not found in: nil` reading `white.id` when only Black
     remained seated.
  2. A bye's own recipient can be vacated too (a bye pairing already has
     Black's seat empty; vacating White leaves nobody at all, but `is_bye`
     — which only checks Black's seat — still reports the board as a bye).
     `annotate_bye/3` then crashed reading the vanished recipient's name.
     Fixed alongside a real, quieter second bug in the same function: an
     empty "ghost" bye board sorting before a real one would have silently
     reported the empty ghost as the round's allocated bye instead of the
     actual recipient.
  3. Once the analysis itself stopped crashing, `PairingExplainLive`'s own
     rendering turned out to make the identical assumption in three
     separate places — the score-bracket graph, the "Board by board" card
     list, and the "Pairing numbers" table — each reading a player's name
     unconditionally with no guard for a missing seat. Boards missing a
     side are now excluded from the score-bracket graph entirely (there's
     no player to plot), and the other two now show a plain "Seat vacant"
     note instead of crashing.
- **The round-dates setup checklist could stay stuck on "missing" forever**
  even after every date was filled in — `round_dates` was only padded or
  truncated to match `rounds_count` on the Dates settings page's own save,
  not wherever else `rounds_count` can change (e.g. round-robin silently
  correcting it to match the real Berger schedule on freeze). Moved into
  the shared tournament changeset so it happens on every save, from any
  page.
- **The "Delay (minutes)" field showed even when "Publish each round" was
  set to "Immediately"** — it now only appears for "After a delay", live,
  as the dropdown changes.
- **A print doc could show a stale fixed-board note after a round was
  already paired and frozen** — `fixed_board_note/1` (score sheets, result
  cards) read `Player.fixed_board` live, bypassing the freeze mechanism
  that already exists for exactly this (see the 0.14.6-class fix below) and
  contradicting its own module doc's claim to be the *only* such reader. A
  mid-round edit to a player's fixed board could make a reprinted document
  disagree with the already-frozen main pairing sheet for the same board.
  Now reads the pairing's own frozen data instead.
- **The swap-confirm modal's before/after cards could end up different
  heights**, making the connecting journey arrows look crooked — caused by
  a long name wrapping onto a second line in one card but not its partner.
  Names no longer wrap (truncate with an ellipsis instead, full name still
  available on hover); cards now size to their own content instead of a
  forced equal split, so a short name's card isn't stretched to match a
  long one.
  - A related, more specific wrap bug survived that first fix: the W/B
    colour badge could end up alone on its own line, above the name, on
    any "Swap colours" confirm with two ordinary-length names — not just a
    pathological long one. Root cause: with `flex-wrap: wrap` on the seat
    row, the browser decides which line an item lands on using its
    *un-shrunk* preferred size, not its post-ellipsis size — so a name
    "too wide" to fit next to the badge got bumped to a new line before
    the shrinking/ellipsis logic ever got a chance to run.
  - "Pair these two" (pool-pair) could show a large, visibly empty gap
    between its two cards — a CSS Grid trap: the arrow column's `auto`
    track sizing doesn't mean "size to content" the way it does for a
    `width` property, it means "absorb the grid's leftover space" when
    nothing else claims it, and two narrow cards left a lot of it. Changed
    to `max-content`, which never grows past the arrow glyph itself.

### Fixed

- **An archived tournament's Pairings page let you enter/change results** —
  the underlying write was always correctly refused
  (`Tournaments.ensure_writable/1`, in place since archiving shipped), but
  the result `<select>` had no `disabled` state tied to `archived_at`, and a
  refused write showed no error at all. Worse: because a refused write
  leaves every assign byte-identical to before, LiveView sends no patch for
  that board's `<select>` — so the browser's own "user just picked this"
  native state was left uncorrected, visually looking like the change had
  taken even though nothing was written. Fixed by disabling the select
  outright while archived, surfacing a clear "This tournament is archived"
  error on any write that's still refused, and forcing a patch on refusal
  (a small nonce threaded into the element) so the existing
  data-result-resync hook actually runs and snaps the value back. The
  right-click board-editing menu (swap/mark absent/award bye/fill seat/pool
  pair) now also refuses to open at all on an archived round, and CSV
  results import is hidden.
- **Two more instances of the "crashes instead of showing an error" bug
  class found while fixing the above**: the Players page had its own
  broken local `error_text/1` (same shape as an earlier-fixed crash in
  Settings) that raised trying to read `.errors` off the bare atom
  `:archived` instead of a real changeset — editing, deleting, or bulk
  actioning a player on an archived tournament crashed the LiveView. CSV
  results import had the identical bug one level down, in
  `ResultsImport.write_all/2`. Both fixed; audited and fixed the same
  "write refused but the LiveView shows nothing" gap (no crash, just
  silence) across the Pairings, Players, Categories, Standings, and
  Tournament/Options settings pages too, so every one of them now shows a
  clear error instead of quietly no-oping.
- **A production migration wrote `display_special` (the fixed-board freeze
  from the fix below) as the literal text `"true"`/`"false"` instead of the
  integer `0`/`1`** — `Repo.update_all` against the raw `"pairings"` table
  name has no `:boolean` type info to encode through, so SQLite stored the
  Elixir atoms' literal text. Every page that loaded a pairing then crashed
  with `cannot load "false" as type :boolean`, a full outage confirmed and
  fixed live in production (data repaired, migration source corrected so a
  fresh deploy can't repeat it).
- **Only a tournament's owner could archive it — a co-arbiter it was shared
  with could not**, even though sharing otherwise grants "exactly like you"
  access. `archive_tournament`/`unarchive_tournament` now go through the
  same owner-or-accepted-collaborator check every other shared action uses;
  an archived shared tournament also now shows up in a collaborator's own
  Archived panel (marked "shared"), not just the owner's — previously it
  would have simply vanished from their dashboard the moment anyone
  archived it. Delete stays owner-only, same as the main list.
- **Giving a player a fixed (accessible) board after their round was already
  paired silently renumbered every board after theirs** — `PairingDisplay`
  read `Player.fixed_board` live on every render, so an arbiter editing a
  player's fixed board mid-round (e.g. on the Players page) retroactively
  moved that player's pairing to the special/end-of-list group and closed the
  gap in the ordinary sequence, shifting every board number after it, while
  people were already seated. The special/ordinary classification and board
  label are now computed exactly once, at the moment a round is (re-)paired —
  ordinary pairing, round-robin, Keizer, or an import/restore — and frozen
  onto the pairing (`display_board`/`display_special`). Editing a player's
  fixed board no longer has any effect on an already-paired round; it only
  takes effect the next time that round is paired (a fresh round, or an
  explicit unpair-and-re-pair). The narrower survivor of the 0.14.6
  board-renumbering bug class.
- **The top bar overflowed the page horizontally at laptop widths** (roughly
  769-1280px, i.e. most laptops with the window not maximised) — the auth
  cluster (FIDE/KBSB sync status, email, Settings, Log out, version) never
  shrank, so it pushed the whole page wider than the viewport. There were no
  responsive rules at all between the 1280px desktop layout and the 768px
  tablet one. Two new breakpoints now drop the sync strip, then the email and
  version, before anything is forced to wrap.
- **The "Advanced" and "Settings" top-bar dropdowns, and the accent/theme
  pickers, were always laid out and hit-testable, not just when opened** —
  `.topbar-menu-panel`/`.accent-picker-panel`/`.theme-picker-panel` each set
  `display: flex` (or `grid`) unconditionally, relying entirely on
  `<details>`'s own native collapse to hide the closed panel. In Chromium
  that collapse uses `content-visibility: hidden`, which still reports the
  panel's full-size box for layout purposes while correctly skipping
  paint/hit-testing — so a closed dropdown was invisible and non-interactive,
  but its ~180px-wide box still counted toward the page's scrollable width.
  This was most of what was actually causing the top-bar overflow above (a
  closed multi-item "Settings" panel poking out past the viewport with no
  visible cause). All three panels are now `display: none` unless their
  `<details>` is `[open]`, which is also simply correct regardless of any one
  engine's collapse behaviour.
- **Norms was missing from the "Advanced" sub-nav strip** — the top-bar
  dropdown menu listed four pages (Norms, History, Audit trail, Pairing
  rationale) but the strip rendered on each of those pages only showed three
  boxes, because `NormsLive` never rendered the shared sub-nav at all. It
  does now, and the sub-nav component covers all four consistently.
- **Settings that decide the shape of already-paired rounds were locked only
  in the Settings LiveViews, not in the data layer** — `pairing_system`,
  `rr_cycles`, `rr_match_format`, `swiss_match_format`, `pair_by_category`
  and the "Pt ABSENT" trio (`abs_value`/`abs_jusque`/`abs_nbfois`) were
  disabled inputs plus a strip of the submitted params in
  `SettingsOptionsLive`/`SettingsScoringLive` — enforced nowhere else.
  Confirmed exploitable: calling `Tournaments.update_tournament/2` directly
  with `pairing_system: "keizer"` on a tournament with a paired Swiss round
  silently succeeded, reinterpreting every round already on the board under
  different pairing/scoring rules. `Tournaments.locked_fields/1` is now the
  single source of truth — `update_tournament/2` itself refuses a change to
  any locked field once round 1 is paired, and both Settings pages render
  their disabled state from the same function, so the two cannot drift apart
  again. This is the same shape of bug the archive guard (`ensure_writable/1`)
  exists to prevent, just for a different property — "the UI hides the
  button" is not enforcement.

### Added

- **Archive a tournament** — a new frozen read-only state, separate from the
  Recycle bin. An archived tournament stays *fully readable*: its own pages,
  public link, prints and exports all keep working exactly as before. It just
  refuses every change until you unarchive it. Unlike the bin, nothing
  archived is ever purged automatically — it's "done with this, keep it
  forever", not "on its way out".

  Archived tournaments leave the main list and get their own **Archived**
  panel on the Tournaments page, with an amber `archived` badge, and every
  page inside one carries a persistent read-only banner.

  The read-only part is enforced in the context layer
  (`Tournaments.ensure_writable/1`, called by all ~30 write paths plus the
  pairing engines), not by hiding buttons — a stale open tab, a queued
  LiveView event or a direct script call are all refused too. `archived_at`
  is a dedicated column rather than a `status` value (status is derived and
  would be recomputed away) and is deliberately not cast by the ordinary
  changeset, so no settings save can archive or silently unarchive anything.

### Fixed

- **`SettingsSupport.error_text/1` crashed the LiveView on any non-changeset
  error.** It called `changeset.errors` unconditionally, so a bare reason atom
  parsed as a remote call (`:archived.errors/0`) and took the whole page down.
  Found by the archive tests — a settings save on an archived tournament hit
  it immediately. Now handles changesets, atoms and strings.

## [0.14.31] — 2026-08-13

### Changed

- **Public pages are now off by default** for a new tournament, instead of
  on — player names, ratings and clubs no longer become reachable by
  anyone who finds the link until an arbiter deliberately turns it on
  (Settings → Tournament → Public pages), same "opt-in per event"
  reasoning self-registration already used.
- **Scoring moved to its own Settings tab** — points per win/draw/loss,
  the pairing-allocated bye value, and SWAR's "Pt ABSENT" genuine-absence
  rule used to live at the bottom of the Options page; they're on
  Settings → Scoring now, since "how many points" is a different concern
  from "how the tournament is paired" (Options).
- **Categories on/off moved onto the Categories page itself** — it used
  to be a checkbox buried in the Options form (labeled "Enable the
  Categories tab", even though the tab was already always shown). It's
  now a plain Turn on/Turn off button right on the Categories page,
  taking effect immediately — no more Save-then-navigate-over round
  trip. "Pair each category independently" moved there too, next to the
  switch it depends on, marked **(beta)**, and turning categories off
  now also turns this off in the same write (previously conflicted with
  the changeset's own validation if attempted directly).
- **Clearer genuine-absence field labels**, on the new Scoring page:
  "Points for a genuine absence (SWAR's 'Pt ABSENT')" → "Points awarded
  for a genuine absence", with a fuller explanation of what "genuine
  absence" actually means (a plain no-show, distinct from a requested
  bye or a forfeit) above the fields. "...pays through round
  (inclusive)" → "Last round this still applies to"; "...for up to this
  many absences (cumulative)" → "Cap: only a player's first N genuine
  absences pay" — both with longer, more concrete hints.
- **A prominent warning now accompanies "Treat a genuine absence as a
  voluntary unplayed round for tiebreaks"** — this option changes FIDE
  tiebreak results (Buchholz/Sonneborn-Berger), not just scoring, and
  FIDE's own C.07 has no such concept at all. The warning appears the
  instant the checkbox is ticked, before the page is even saved.

### Fixed

- **The Save-settings button on the Tournament and Options pages sat
  crammed against whatever card came right after it** (Tiebreaks → Save
  → Public pages / Share-Team, and Options → Save → Forbidden pairings)
  — a bare `.actions` row only ever had margin above it, none below, so
  it visually ran into the next section. Now has proper spacing on both.

## [0.14.30] — 2026-08-13

### Added

- **Public pairings can now be published on a delay instead of the
  instant they're paired** — a new "Publish each round" setting
  (Settings → Options → Public pairings) picks between four modes:
  *Immediately* (the old, still-default behavior), *Manually* (a round
  stays hidden from `/p/:slug/pairings` until you publish it by hand),
  *After a delay* (a fixed number of minutes after pairing), and *On
  the round's own date* (midnight UTC of that round's date on the
  Dates page). Whichever mode is active, the Pairings page also gets a
  standalone **Publish now / Unpublish** button and a public/not-public
  badge for the round you're viewing — a manual override that works
  regardless of mode, so an arbiter can always release a round early or
  pull it back, even under a timed or scheduled setting. Rounds can be
  published out of order (round 3 public while round 2 still isn't);
  the public page always shows exactly the round it was asked for, or
  a placeholder if that one isn't out yet.

## [0.14.29] — 2026-08-13

### Changed

- **Start/end date are no longer entered separately from round dates** —
  they used to be their own fields on the Tournament settings page,
  independent of the per-round dates on the Dates page (two places that
  could say different things about what's really one piece of
  information). They're derived now: the earliest and latest non-blank
  entry in `round_dates`, recomputed on every save regardless of which
  settings page triggered it. The Dates page shows the derived result
  live as a read-only preview, updating as you type before you even
  save. The "New tournament" form keeps its one "Date from" field (it
  only ever seeded every round to the same date); "Date to" is gone —
  it would have been silently ignored under the new model.
- **A tournament's setup no longer independently requires a start
  date** — requiring `round_dates` already covers it now that start
  date is derived from that list, not a second, separate requirement to
  satisfy.

## [0.14.28] — 2026-08-13

### Fixed

- **The swap confirm modal's card pairs still ended up visibly uneven
  with real (longer) names**, even after 0.14.27's top-alignment fix —
  the "⇄ Board N" chip sat on the same line as the name, so it ate into
  the name's own available width on only the "after" card (the one side
  that ever gets a chip), making the exact same name wrap harder there
  than its own "before" counterpart managed without a chip competing
  for room. The chip now forces onto its own line below the name, so
  both sides of a pair get identical width to wrap into. Verified
  against the exact case that surfaced it (`Burssens, Ruben (1502)`, a
  name long enough to wrap under a chip but not without one): the name
  itself no longer wraps at all now, on either side.

## [0.14.27] — 2026-08-13

### Fixed

- **The swap confirm modal's two board-diff cards could end up visibly
  misaligned** when a long name wrapped to two lines in one card but not
  its mirror (e.g. on the White row of one card, the Black row of the
  other) — centering each card vertically meant the taller one grew
  upward as well as downward, so its own White row landed at a
  different height than the other card's White row despite White not
  having changed. Both cards now align to the same top edge instead.

### Changed

- **Every player shown in a swap now gets a journey arrow, not only the
  ones who moved** — a two-board player swap shows 4 people (the 2 who
  traded boards plus whoever they left behind on each board); all 4 now
  get one, in their own colour: the 2 travellers get a real crossing
  journey, the 2 who stayed put get a short arrow back to their own
  seat, so nobody shown reads as forgotten next to the two who visibly
  moved. A same-board colour swap still shows exactly 2 (there's nobody
  else on that one board to draw) — unchanged. Verified live: 4 paths,
  4 dots, one per player's own colour; the two stationary players' paths
  measure as flat, near-zero-length arrows back to themselves.

## [0.14.26] — 2026-08-13

### Security

- **`phoenix_live_view` 1.2.7 → 1.2.9**, clearing a LOW-severity open
  redirect (EEF-CVE-2026-64941 / GHSA-36m4-rm57-3prf) in LiveView's own
  internal `validate_local_url!/2` check — an ASCII tab/LF/CR in a URL
  could pass that check as "local" while a real browser strips those
  characters and follows the link elsewhere. Pulled `phoenix` along with
  it (1.8.9 → 1.8.11, phoenix_live_view's own dependency floor) — both
  already inside this project's existing `mix.exs` version constraints,
  so only `mix.lock` changed.

  Not obviously reachable from this app's own code today — the one
  place that stores a redirect target (`user_return_to`) uses the
  current request's own path, not an attacker-supplied parameter — but
  the vulnerable check sits inside every `redirect`/`push_navigate`/
  `push_patch` LiveView does internally, so worth clearing regardless.

## [0.14.25] — 2026-08-13

### Added

- **Every player shown in the swap confirm modal gets their own colour**
  — not just the two who moved. A two-board swap shows up to four
  people (the two travellers plus whoever stayed put on each board);
  each now has a distinct colour (from a fixed 6-colour palette,
  independent of the tournament's own accent) applied to their name
  everywhere it appears, so identity is legible at a glance instead of
  only "changed vs. unchanged". Each traveller's journey arrow, dot,
  arrowhead and "⇄ Board N" chip now match their own colour too — read
  straight off the seat elements the arrows hook already found, so
  there's no separate colour list to keep in sync between Elixir and
  JS. A same-board colour swap gets two colours; a non-swap confirm
  (mark absent, award bye, fill a seat, pool-pair) gets none, same as
  before.

## [0.14.24] — 2026-08-13

### Fixed

- **Swap journey arrows: the two curves crossed below the middle rather
  than at it**, which read as a mistake rather than a swap. Each curve
  was built with one shared control x ("a lane per arrow"), which is not
  symmetric; with `+k` out of the start and `−k` into the end, both
  curves pass through the exact centre of the channel at their own
  half-way point and meet there.
- **The arrowhead was still turning as it landed.** Each curve now ends
  (and starts) with a short straight run, so the head sits on a level
  segment.

## [0.14.23] — 2026-08-13

### Added

- **The swap confirm modal now draws each moving player's journey** — a
  curved arrow from where they sit now to where they land, with a dot at
  the start and an arrowhead at the finish. Two boards trading players
  gives two curves crossing in the middle, which is the swap itself; a
  same-board colour swap crosses inside the one row. The curves route
  through the centre column (the static "→" steps aside and widens into
  a channel) so they never cross the opaque board cards.

  Which seats get joined is worked out by matching a name that changed
  seats on *both* sides, so mark-absent, award-bye, fill-seat, pool-pair
  and substitute-from-pool draw nothing at all — nobody travels between
  two shown boards there — with no extra server-side state to keep in
  sync. Purely additive: with no JS, or if measurement fails, the plain
  "→" layout and the "⇄ Board N" chips stand exactly as before. Honours
  `prefers-reduced-motion` (no draw-in animation), and redraws on
  window resize and on re-render.

## [0.14.22] — 2026-08-13

### Fixed

- **The new W/B swap-modal badges (0.14.21) were inverted on a dark
  theme** — White rendered as a dark box, Black as a light one. The fix
  used `var(--surface)`/`var(--text)` for an "inverted pair," not
  noticing those tokens themselves flip between light and dark themes.
  Now fixed literal colours (the same cream/charcoal pair the brand
  mark's own chess pieces use), so White is always the light box and
  Black always the dark one, independent of theme.

## [0.14.21] — 2026-08-13

### Changed

- **The swap confirm modal's board-seat colour indicator is no longer a
  fixed-red dot** — replaced with theme-aware W/B letter badges (White:
  bordered, page-surface background; Black: inverted, same pair either
  way), so it no longer reads as an alarm colour in the one place —
  mid-swap — nothing is actually wrong. A genuine two-board swap's
  changed seat also gets a small "⇄ Board N" chip pointing at the other
  board involved, so the two independent before/after cards no longer
  need to be mentally cross-referenced by hand.

## [0.14.20] — 2026-08-13

### Added

- **PGN export can include board numbers** — right-click "Export PGN" on
  the Pairings page (same `.PrintMenu` pattern as "Print pairings"/"Print
  result cards") for three more variants: this round with board numbers,
  every round, and every round with board numbers. `?board=1` adds a
  `[Board "N"]` tag to every game, using the same DISPLAY board number
  every other view shows (fixed-table boards relabeled/moved), not the
  raw stored board.
- **Editing a past (non-latest) round's pairings now asks you to confirm
  it's not a mistake** — swap, mark absent, pool-pair, fill a seat, award
  a bye: any pairing-altering action staged on a round that isn't the
  tournament's current latest paired round now shows a clear warning in
  the confirm modal ("You're changing round N, not the current round"),
  with the primary button disabled until an explicit "I understand, apply
  anyway" checkbox is ticked — both client-side and re-checked
  server-side. Entering/editing a result is unaffected; this only gates
  changes to who's paired with whom.

### Fixed

- **Public pairings round-picker/table sat flush against each other with
  no gap.**

## [0.14.19] — 2026-08-13

### Fixed

- **SWAR export produced a file real SWAR misreads for a player with
  many rounds absent and no per-round "byes" row** (globally
  `absent: true`, never explicitly marked absent round-by-round). A
  round with neither a `Pairing` nor a `byes` row used to be silently
  omitted from that player's `[RONDE]` array — internally consistent for
  our own reader, but not a shape real, hand-run SWAR tournaments ever
  produce, and real SWAR was confirmed (against an actual production
  export) to desync on it: "???" opponent names and phantom results on
  *later* rounds for exactly that player, once their block ran out. Every
  round from the player's `start_round` onward now gets an explicit
  zero-point "absent" record instead of being skipped — a round before
  `start_round` (not registered yet) is still correctly omitted. No
  change to OpenPairings' own scoring/standings; only what gets written
  into the exported `.swar` file.

## [0.14.18] — 2026-08-13

### Added

- **Public pairings page now shows round history, not just the latest
  round** — `/p/:slug/pairings` gained the same round-picker the
  authenticated Pairings page has (`?round=N`, bookmarkable/shareable),
  so anyone with the public link can look back at earlier rounds instead
  of only ever seeing whatever round is currently being paired. The
  public standings and pairings pages now cross-link to each other.

## [0.14.17] — 2026-08-12

### Fixed

- **"Pair with another player who isn't playing…" confirm dialog got
  silently closed by an unrelated remote broadcast** — an arbiter mid-way
  through that gesture, with someone ELSE entering a totally unrelated
  result elsewhere in the round, got bounced out of it as if they'd hit
  Escape themselves. A remote broadcast now leaves any in-progress
  menu/swap/confirm gesture alone (the round data underneath it still
  refreshes fully either way); only the arbiter's own completed action
  clears it. Hardened `Tournaments.pair_from_pool/4` to re-check the
  target board number is still free right before writing, since the
  confirm dialog can now sit open across a remote update.
- **The Players page's own "Player data was just updated by another
  arbiter" popup, removed** — same call as the Pairings page's identical
  notice (0.14.12): it kept surprising people mid-click regardless of
  where it sat. Player data still refreshes live underneath; only the
  popup announcing it is gone.
- **Assigning categories skipped unrated players for an `elo_below`
  threshold bracket** (e.g. "U1800") — an unrated player's rating is
  effectively 0, which genuinely is under any positive ceiling; the
  `rating > 0` guard had it backwards. `elo_above` keeps requiring a real
  rating, unchanged — an unrated player has no proven rating to be above
  anything.

### Added

- **Tiebreak values on the Players Card** (right-click a player) — a
  compact strip of the tournament's own configured tiebreaks and this
  player's value for each, same as the Standings page shows per column.
  Also added to the card's print version.

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
