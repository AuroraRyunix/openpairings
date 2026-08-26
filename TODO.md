# TODO / Roadmap

Version: **0.17.1** (not 1.0 yet - the maintainer will call that explicitly).
See [`docs/features.md`](docs/features.md) for what's already shipped.

> **A whole-codebase sweep ran on 2026-08-26** and its findings are in
> [docs/sweep-2026-08-26.md](docs/sweep-2026-08-26.md) - 78 items for this
> repository, of which 12 were bugs that survived an adversarial refutation
> pass and 15 more were filed as unverified leads. **All 12 confirmed bugs
> and 10 of the 15 leads are now fixed**; that document's Status section
> carries the finding-to-commit table. Five leads are open and are listed
> under "Still open from the 2026-08-26 sweep" below, three of them under a
> disagreement about whether they are bugs at all. Nothing below bug
> severity - 27 drift items, 7 optimizations, 15 additions - has been
> re-audited. This file is the roadmap; that one is the bug list.

## The 2026 Acceptance Cycle (dominates everything below)

FIDE TEC circulated draft **VCL4THP v13** and a revised **TEC Manual** on
2026-08-25, for consultation until **2026-09-07**. When the final versions
publish, TEC announces a new Acceptance Cycle and **existing endorsements
are revoked** - every vendor re-qualifies. Our feedback draft is
[tec-feedback-2026-09.md](docs/tec-feedback-2026-09.md); it is not sent.

The VCL is 226 questions with **accumulating penalty percentages, where
over 100% is a failure**, plus hard stops that end verification on the
spot. What follows is our own read of where we stand. It is a read, not a
verdict - TEC verifies, we do not.

### Hard failures (verification stops)

- **FIDE Mode does not exist.** We have a fide_homologated flag; the VCL
  wants a MODE (Q40-46) with warning Levels 1-5, a Level-4 double warning
  on exit, no re-entry once exited, and a ### TRF comment recording the
  round it was left. Half the other requirements report THROUGH this, so it
  is the spine: build it first, or build everything else twice.
- **Adjourned games are not implemented at all** (Q157-169). The word does
  not appear in the codebase. Needs a result state, "counts as a draw for
  pairing purposes", a Level-3 warning when a non-draw result is entered
  later, and a block on final standings while any remain.
- **Prohibited pairings can be added mid-tournament** (Q196).
  Tournaments.add_forbidden_pairing/3 does not go through
  ensure_unlocked/2. Cheap to fix - but see the feedback draft, where we
  argue this should be a Level-4 warning rather than a prohibition, since
  C.05:5.2 binds the ORGANISER to communicate, not the software to refuse.
- **Past results are editable in any round** (Q189-191). C.04.2:4.3 allows
  only the round immediately preceding the last one played.
- **TRF import does not verify the imported rounds** against the pairing
  rules (Q54). Mostly plumbing, now that a checker exists.

### Accumulating penalties

Over 100% fails, so these add up rather than standing alone:

- Tournaments over 30 days, where a player may hold more than one rating
  (Q210, **40%**; Q212, 35%)
- Unrated players in rating-based tie-breaks (Q208, **32%**)
- Consistency checks only on explicit request (Q140, **25%**)
- Custom Rating Lists (Q117, 18%)
- Chess960 (Q222, 15%) - **deferred by decision, 2026-08-25.** Cheap for
  the penalty it carries (a start-position draw would satisfy the question)
  but deliberately not now. Keep it on the list.
- ~~W/D/L unrated results, games shorter than one move (Q185, 7%)~~ -
  **shipped 0.17.1.** The codes were already read and written; what
  0.17.1 fixed is that they reached the *pairing engine* correctly. The
  score in TRF columns 81-84 came from a hand-written mapping separate
  from the crosstable's, and `W`/`D` were not on it - so an unrated win
  was banked as a loss and the player was bracketed a full point low.

  Two private copies of the same played-code vocabulary were found and
  missed in the 2026-08-26 sweep, though, so this is not finished:
  `TrfImport`'s and `bye_safe_result/2`'s. See
  [docs/sweep-2026-08-26.md](docs/sweep-2026-08-26.md).

### Blocked on FIDE

- **TRF-26.** Required throughout (Q21 PTC input, Q217 report completeness
  at 30%), but the Manual documents Records 162/172/299 as clarifications
  OF a specification rather than as one. Whether it is published is the
  main question in our feedback. We implement TRF16 today.

### Where we are already strong

Written down so it is not accidentally rebuilt. Q19-23 wants a free CLI
Pairing/Tie-Break Checker AND a Random Tournament Generator, and Ainalrami
has both. Q33's mandatory 50,000-tournament cross-test we exceed by five
orders of magnitude. Q70-88's scoring and PAB configuration landed
2026-08-24. Q180-184's result codes are already exact: 1/2-0, 0-1/2 and 0-0
are supported, forfeits are restricted to the three legal codes, and the
illegal combinations cannot be entered.

## Known gaps / deferred features

These are real, identified gaps - not yet built, and not accidentally missed:

- **Admin/support role** (`users.role`) - no staff/support role exists yet;
  every user is a plain account owner. Deferred, no target date.
- ~~**FIDE/KBSB "last synced" banner**~~ - this claim was already stale:
  the topbar's `.sync-freshness` strip ("FIDE: 3 days ago · KBSB: never
  synced") has been showing this for a while (`Layouts.sync_label/1`,
  `Fide.last_sync/0`/`Kbsb.last_sync/0`). Nothing left to build here.
- ~~**Live "round paired by someone else" notice**~~ - this claim was
  already half-stale: PairingsLive has had a dismissible "updated by
  another arbiter" toast (`remote_notice`) for a while, comparing the
  freshly-reloaded round against what's on screen to tell a real remote
  change from its own broadcast echo. **Now shipped**: the identical
  mechanism on PlayersLive too, the other page where two arbiters actively
  editing at once is a real scenario (registration, ratings) rather than
  just viewing. Standings/Live-round/public pages weren't extended - they're
  read-only "projector" views whose whole point is reflecting changes live,
  where a toast would be noise rather than useful.
- **Team tournaments** - explicitly deferred by the maintainer as a "future
  thing." More scaffolding already exists than this note used to claim:
  `Tournaments.Team` schema, `Player.team_id`/`board_order`, TRF16 team-block
  read/write (`Trf.team_line/1`/`parse_team_line/3`), and "Swiss (teams)"/
  "Round robin (teams)" are already selectable as a tournament format. None
  of it is wired end-to-end though - no team CRUD UI, `Pairing.pair_next_round/1`
  doesn't branch on team type at all (teams pair as plain individuals today),
  no team standings/tiebreaks, and the team TRF block is never actually sent
  to JaVaFo. Still a real, substantial feature gap - just not a from-scratch
  one.
- **American (accelerated pairing) system** - explicitly dropped, not planned
  ("no one cares" - maintainer's own call).
- **SWAR categories: value1 / value2 are merged on import** - the
  [CATEGORIES] block holds a type integer plus two parallel 17-slot arrays.
  SwarImport.map_categories/1 flattens both into one name list and ignores
  the type, while SwarExport.reverse_categories/1 writes value2 blank and
  the type always 1. Per-player CatIndex only ever indexes value1, so
  either value2 holds boundaries (and import invents phantom categories) or
  it continues the name list (and assignment breaks past the 16th).
  **Unresolvable from what we have**: all three .swar fixtures in the repo
  carry type = 0. One real club file with categories configured settles it.
- **Print output is not translated** - print_controller.ex builds HTML
  directly rather than through HEEx, so the gettext passes never reached
  it. Pairing sheets, standings and place cards print in English whatever
  the interface language is set to.
- **41 i18n fragments left English on purpose** - sentences wrapping around
  an inline value cannot be one gettext/1 call as written, and splitting
  them renders half in each language. Listed with the placeholder shape
  each needs in docs/i18n.md. Do not wrap a fragment to raise the count.
- **SWAR presence points on pairing-allocated byes (`SW321_PreBye`)** -
  modelled now (`tournaments.presence_on_allocated_bye`,
  `Standings.bye_points/2`); if a real club file ever surfaces where this
  models differently than expected, re-verify against it (only synthetic
  fixtures + the one real file with a coincidental match have exercised it).

## Tech debt

- **`tournaments_live.ex` / `norms_live.ex`** carry `.form-grid` (not the
  Settings pages' `.set-*` layout primitives) by design - those two pages
  are outside the Settings nav, so the inconsistency is intentional, not
  unfinished. Worth a second look only if Settings' layout system is ever
  extended app-wide on purpose.
- ~~Round robin's `total_rounds/2` vs. a user-set `rounds_count`~~ -
  **shipped**: this used to disagree in the UI (an arbiter could set
  `rounds_count` to anything, mismatching what the Berger schedule for
  their actual roster needs - real complaint: "I get too many rounds").
  `RoundRobin.pair_next_round/1` now corrects `rounds_count` to the real
  schedule total the moment players are frozen, every call - round-robin's
  length was never a free-standing choice the way it is for Swiss, it's a
  pure function of player count + cycles/match-format. Round-robin also
  now pairs its whole schedule in one action (`RoundRobin.pair_all_rounds/1`,
  confirm-gated on the Pairings page's "Pair the whole tournament" button)
  instead of one round at a time, since a round-robin round's pairings
  never depend on prior results - closing the "I don't see all rounds in
  advance" complaint too, since the whole schedule now exists right after
  that one click.

## Still open from the 2026-08-26 sweep

The bug-severity findings from [docs/sweep-2026-08-26.md](docs/sweep-2026-08-26.md)
that no commit has closed. All were filed as leads, not as confirmed bugs.
Three of them were adjudicated on 2026-08-27 - two confirmed, one refuted -
and that pass turned up a fourth. Full evidence and line references are in
that document's "Three leads, adjudicated 2026-08-27"; this is the index.

- **Keizer's `classify_result` catch-all scores an unscored pairing as a
  played loss** (`lib/pairings_engine/keizer.ex:605`). A paired-but-unscored
  pairing carries `result: ""`, falls to `_ -> :zero`, and `round_stats/2`'s
  `:zero` bucket increments both `played` and `losses`, where
  `Standings.pairing_records/4` returns `[]` for the same state.
  **CONFIRMED as a defect, harm refuted**: `played`/`wins`/`draws`/`losses`
  are dead fields - returned by `Keizer.standings/2` and read by nothing, and
  all four Keizer surfaces render Score only. The one live effect is
  `raw_points` inflated by `points_loss` per unreported game, which is 0.0
  by default. Low priority, but it is two implementations of one rule.
- **`adjusted_score/3` mixes a record count with a round number**
  (`lib/pairings_engine/standings.ex:770`). `missing_tail` subtracts a round
  number from `rounds_played_count/1`, which counts records, so one board
  reporting first can hand every un-reported player's opponents a phantom
  draw on Buchholz/BHC1/BHC2/MBH/SB, and move Koya's 50% threshold a full
  win at the same instant. **CONFIRMED - and the cause and cure both need
  correcting.** `rounds_played_count <= round_horizon` always (one record
  per player per round, both global maxima), so swapping to `round_horizon`
  as this document first proposed pads MORE, not less. The fix is a third
  horizon: the highest round in which no pairing still has `result: ""`,
  threaded into both `adjusted_score/3` and `tiebreak("KS", ...)`. This is
  the one open finding with a wrong number on an arbiter's screen.
- **The public standings page ignores the per-round publish gate**
  (`lib/pairings_engine_web/live/public_standings_live.ex:72`). It calls
  `Standings.standings/2` with no `through_round` and counts every `rounds`
  row, so in manual or timed publish mode it shows a round the public
  pairings page one link away deliberately hides. **REFUTED as a bug** - the
  settings card is headed "Public pairings" and names `/p/<slug>/pairings`
  literally, and the unpublish confirm, `round_published?/2`'s `@doc` and the
  CHANGELOG entry all scope it the same way. Open only as a PRODUCT
  question: should withholding a round withhold its results too?
- **`Ainalrami.Pairing.explain_round/3` drops `:point_system`**, so a
  non-1/½/0 tournament's stored round explanation is computed at the wrong
  scale and can describe a bracket the engine did not use. Fixed upstream by
  `4dd9980` in the Ainalrami repository, but that commit is on
  `feature/team-pairing` and is not an ancestor of `v0.11.1`, which is what
  `mix.exs:159` pins. Closes here when the pin moves.
- **A vacated seat pays the player left on the board a half-value Keizer
  bye** (`lib/pairings_engine/keizer.ex:561`). `score_game/3` treats any
  pairing with `opponent_id == nil` as `:unpaired_bye` worth half the
  player's own ladder value, and `do_vacate_seat/3` writes exactly that
  shape - so vacating a seat pays the REMAINING player until the arbiter
  runs `award_bye_for_vacancy/2`. Found while adjudicating the three above;
  unlike the `classify_result` one, this is a real points effect. The Swiss
  path gives them nothing.
- **`Standings.bye_points_for_row/2` fires one COUNT query per rendered bye
  row** (`lib/pairings_engine/standings.ex:347`), an N+1 inside four render
  loops. `add_bye_records/3` already does the same count in one in-memory
  pass; the display path never learned it.

## FIDE endorsement readiness (pre-2026 cycle)

> Written against FIDE's earlier Annex 4 checklist. Superseded in scope by
> the 2026 Acceptance Cycle section at the top of this file - kept because
> the shipped items below are still shipped, and the reasoning is still the
> record of why they were done that way.

Full checklist, current status per item, and the testing-harness plan live
in [`docs/fide-endorsement.md`](docs/fide-endorsement.md) (built from FIDE's
own Annex 4 Verification Check List and Annex 1 endorsement form). Concrete
gaps identified there, extracted here as actionable items:

- ~~Lock `pairing_number` after round 4 is paired~~ (VCL.09) - **shipped**:
  `Tournaments.update_player/2` now rejects changing an already-assigned
  number once 4 rounds are paired; a first assignment (late entry) still
  always works.
- ~~Asymmetric ½-0 / 0-½ result support~~ (VCL.13) - **shipped**: the TRF16
  spec itself has no cross-validation rule between the two sides' codes
  (that was `Trf`'s own invention) - it's just `=` for the ½ side, `0` for
  the 0 side. Wired through the schema, result-entry UI, standings scoring,
  TRF export/import (both directions), Keizer's own scoring, and SWAR
  import (which already had bitfield codes for this, previously dropped as
  unmappable). See `docs/fide-endorsement.md`'s VCL.13 entry for the file
  list.
- ~~Fuzz-testing harness - but not a pairing checker~~ - **shipped**: (1)
  `test/pairings_engine/trf_property_test.exs` - `StreamData` property tests
  on `Trf.serialize/1` against random-but-legal rosters/histories, checked
  against ground truth via `parse/1` round-tripping rather than re-deriving
  `Trf`'s own column positions; (2)
  `test/pairings_engine/cross_program_test.exs` - runs OpenPairings' real
  `Pairing.pair_next_round/1` (JaVaFo) against `bbpPairings` (Bierema Boyz
  Programming, Apache-2.0, vendored in `priv/bbppairings/` - a genuinely
  independent second Dutch-system implementation, not JaVaFo again) on
  byte-identical TRF16 input, diffing the actual pairing every round across
  `PAIRING_FUZZ_COUNT` (default 8, set much higher for a deliberate
  "throw a pile of random tournaments at it" pass) synthetic tournaments.
  Both tagged `:javafo`/`:bbppairings`, gated in `test_helper.exs` exactly
  like the existing `:swar_fixture` pattern.
  **First real finding, not yet resolved**: a `PAIRING_FUZZ_COUNT=200` run
  found ~6 disagreements (~1.2% of rounds) on small rosters (5-13 players),
  always a same-score-group-splitting choice in an otherwise-legal
  situation (verified against JaVaFo run standalone, bypassing OpenPairings
  entirely, to rule out an OpenPairings-side bug) - needs FIDE Dutch-system
  rules research to tell whether this is a bbpPairings quirk, a JaVaFo
  quirk, or a genuinely underspecified tie-break FIDE's own rules leave
  open; the harness's exact job is surfacing this, not resolving it.
- ~~TRF06 import~~ (VCL.11, recommended not mandatory) - **shipped**: read
  FIDE's actual archived TRF06 specs (2006 and 2016 versions) rather than
  guessing - column positions are byte-identical to TRF16, so no separate
  importer was needed, just tolerating TRF06's older bye convention (a
  dangling playing code, no F/H/U/Z). Verifying this surfaced and fixed two
  real `Trf` bugs along the way - see `docs/fide-endorsement.md`'s VCL.11
  entry.
- ~~Two smaller "needs verification" items~~ (UTF-8 response headers on the
  TRF export, no accidental "FIDE"-branded claim about OpenPairings itself
  in the UI) - **both verified**: UTF-8 was already correct (confirmed via
  `Plug.Conn`'s own source, locked in with a test); the login page's hero
  copy had one real overclaim ("FIDE-compliant pairings..."), reworded.
- ~~Trailing pairing-allocated byes scored as draws instead of their
  awarded value~~ (VCL.19) - **shipped**: found while auditing
  `standings.ex` against FIDE's C.07 revision effective 1 March 2026
  (Art. 16.2.1/16.3). `Pairing.result == "bye"` (JaVaFo's own
  odd-player-count byes) was marked `voluntary: true` - inconsistent with
  the `byes`-table path, which already excluded `"pairing-allocated"` from
  its own `voluntary` set. A trailing occurrence (the common last-round
  case) made `adjusted_score/3` substitute a draw's worth of points for
  the bye's real value in every opponent's Buchholz/SB. See
  `docs/fide-endorsement.md`'s VCL.19 entry.
- ~~C.07's new Art. 16.5.1 "Cut-1 Exception"~~ (VCL.19) - **shipped**:
  BHC1/BHC2/MBH now cut a contribution from one of the participant's own
  voluntary unplayed rounds (a bye, via `dummy_score/3`) in preference to
  an ordinary game contribution, reusing the existing `voluntary` flag as
  the VUR tag. See `docs/fide-endorsement.md`'s VCL.19 entry.
- ~~SWAR's "absent" bye type unconditionally treated as voluntary~~ -
  **shipped**: new `Tournament.absent_counts_as_vur` setting, off by
  default (an absence always counts at its award value, like a forfeit
  loss - FIDE has no "absent" concept, so this is the strict/safe
  reading); an arbiter can opt in from Settings for the more lenient
  requested-bye-style treatment. See `docs/fide-endorsement.md`'s VCL.19
  entry.

## Backlog (no particular order, nothing blocking)

- ~~**History page (`/t/:id/history`) reported as "just a read-only thing"**~~
  - **answered 2026-08-16.** Nothing was broken: the restore buttons only
  render on entries that ARE restore points, and `Snapshots.capture/4` was
  reachable from exactly four handlers, all in `PairingsLive` (pair a round,
  unpair one, pair a whole round-robin schedule, import results by CSV). A
  tournament run by hand - players edited, settings tuned, results typed in
  - therefore had zero snapshots, hence zero buttons, hence a page that
  reads as a list you can only look at. Shipped: a "Save a restore point"
  action on the page itself (`"snapshot.manual"`), plus an honest empty
  state saying there are none yet and why. The moduledoc's stale
  "Read-only" claim is corrected too.

  Deliberately **not** done at the same time: broadening the automatic
  capture triggers. Adding one before, say, every settings save or every
  result entry would change snapshot volume and storage for every existing
  tournament (these are full tournament copies, `@keep_per_tournament 50`
  of them), so it wants its own decision rather than riding along. The
  candidates, if that decision is ever taken: bulk player import, "assign
  categories" / extra-points apply (both rewrite every player in one
  click), and manual-standings re-seed. Single-field edits are not
  candidates - they're already reconstructable from the audit trail's
  before/after diff.

  The second half of the same report - something colliding into the
  "Everything" filter button - was a layout bug, not a filter-state one,
  and is fixed too: the first day heading's opaque rail mask overhung 6px
  upward into the filter row directly above it. See the CHANGELOG entry.

- ~~"Substitute player" draws its journey arrow on the wrong seat~~ -
  **shipped 2026-08-15, the "bigger redesign" option**: `matchTravellers()`
  in the `.SwapArrows` hook matches purely by NAME across the whole modal,
  not per-row (see its own extensive comments) - `confirm_for/2`'s
  `:swap_pool` branch now adds a second "Not playing list" row (new
  `bench_card/1` component, single-seat, no colour disc) showing the pool
  player on "before" and the seated player on "after". Because those two
  names already appear once each on the real board row's opposite side,
  the UNCHANGED hook now finds a clean match for both and draws two real
  arrows - one in, one out - exactly as asked, with zero changes to
  `matchTravellers()`/`render()` themselves. The previously-misleading
  phantom arrow on the *unaffected* seat (e.g. white, when black was
  substituted) still fires - the hook's own stated philosophy is "everyone
  shown gets an arrow, the ones who stayed put get a short one back to
  their own seat" - but it's no longer the sole, unexplained arrow on
  screen; it now sits alongside two clearly-purposeful in/out arrows, so it
  reads as "white stayed" rather than as a wrong-looking swap. Not
  separately suppressed - consistent with how a real 2-board swap already
  shows a short "stayed" arrow for an unmoved board partner.

- ~~**Chief arbiter (and the other Officials fields) are unfindable without
  the link.**~~ **Cheap fix shipped**: Settings > Tournament grew an
  "Officials" card that names the Norms page, links to it, and shows the
  current chief arbiter (or says it is unset and that this does not block
  pairing -- it is a *recommended* field, not a required one). It edits
  nothing; the point is that Settings is no longer silent about a field it
  plainly looks like it should own. The fuller fix below -- moving Officials
  back to Settings -- is untouched and still open, deliberately: it needs a
  decision about what Norms is then for.

  Original report, kept for that decision: they live on `/t/:id/norms`,
  moved there from SettingsLive at some point (see `norms_live.ex`'s
  "relocated from SettingsLive" notes). Nothing is broken - the "ready to pair" hint on PairingsLive links
  straight to the right page via `setup_field_path/2`, and the field saves
  fine - but an arbiter looking for "chief arbiter" will look under
  **Settings**, not under a page called **Norms**, and there is nothing on
  Settings pointing them onward. Reported by the maintainer, who could not
  find it even while holding the link.

  The cheapest fix - a pointer in the Settings → Tournament card - is the
  one that shipped. What is still open is the fuller move.

- ~~"Players - title-norm judgment" table has no meaningful sort order~~ -
  **shipped**: `players_by_norm_relevance/2` now sorts achieved-norm
  players first, then closest-to-qualifying (fewest failing B.01 checks on
  their nearest-miss title), then no-games players last.
- ~~"Explain a round" score-bracket map misplaces handicap-table players~~ -
  **shipped, real confirmed bug**: SWAR assigns accessible/"handicap table"
  pairings a per-round Table number starting at 1001 (`TABLE_HANDICAP + N`,
  Swar.h) - not a real board number, just like the `TABLE_BYE` sentinel
  already handled. The importer was copying it verbatim into `board`, so a
  handicap-table pairing (confirmed via production tournament 18, round 5,
  Vandekerckhove Ava - `board: 1001` in the actual DB row) sorted to the
  far end of anything ordered by board number, including the rationale
  bracket map, regardless of real score. `SwarImport.finalize_boards/1` now
  renormalizes a handicap-range Table value the same way it already did for
  byes. Only fixes *future* imports - tournament 18's existing round-5 row
  still has the raw 1001 in the DB; a one-off data fix there is separate,
  deliberately not done without asking first (touches live tournament
  data).
- ~~Public standings page needs to be a clean spectator overview~~ -
  **shipped**: `/p/:slug/standings` and `/p/:slug/pairings` now render
  through a new minimal `Layouts.public/1` (brand + theme switch only, no
  tournament tabs/accent picker/sign-in) instead of the full authenticated
  `Layouts.app/1`, and both show a compact arbiter/deputy/tempo/round-dates
  line (`PairingsEngineWeb.Components.PublicTournamentMeta`) when set.
- ~~Printed standings/pairings pages don't carry the arbiter/tempo/
  round-dates line~~ - **shipped**: `PrintController`'s shared
  `tournament_info_html/1` (already used by every print doc - pairings,
  standings, player list/cards, crosstable, place cards, result cards) was
  missing deputy arbiter and the per-round dates list (`round_dates`,
  distinct from the free-text `start_date`/`end_date` it already showed).
  Both added as their own line items, labeled "Deputy arbiter" and "Round
  date(s)" to stay unambiguous next to the existing "Dates: start - end".
- **Audit OpenPairings' logic against SWAR's own C++ source, file by
  file.** Very low priority - this is a "nice to have more confidence,"
  not a response to anything currently broken. Scoping notes from
  discussing it: SWAR's source is ~74k lines/135 files total, but almost
  all of that is UI/vendored-library noise; the actually-comparable
  business logic is ~14 files / ~15,600 lines / ~490 functions
  (`Utils.cpp`, `Joueur.cpp`, `Classement.cpp`, `Categories.cpp`,
  `Tournoi.cpp`, the four `Pairing*.cpp` files, `Pairtwo.cpp`,
  `EnvoiJAVAFO.cpp`, `ImportTrfFile.cpp`, `ImportCsv.cpp`,
  `XtraPoints.cpp`). A full function-by-function pass is genuinely
  multiple days of work for uncertain payoff, since most of those
  functions are mundane and will never diverge. If this ever gets picked
  up, prioritize the highest-risk subset instead of going exhaustive:
  `Classement.cpp` (tiebreaks), `Utils.cpp` (shared edge-case logic - this
  is where the round-specific-absence bug lived), and `EnvoiJAVAFO.cpp`
  (SWAR's own TRF builder, directly comparable to
  `Pairing.javafo_input`/`TrfExport` - the class of bug already found
  twice). Both real bugs found so far came from symptom-driven
  investigation (a real tournament comparison surfacing something odd,
  then a targeted SWAR-source dive), not exhaustive pre-auditing - that's
  the higher-leverage pattern to keep leaning on rather than this.
- Remaining SWAR-parity items: hard pairing variants (accelerated pairing
  beyond Baku, more exotic tiebreak orderings) and printing extras beyond
  what's in `docs/printing.md`.
- Extend the automatic B.01 title-norm judgment
  (`PairingsEngine.Norms.TitleNorms`) to the documented-but-unmodelled
  exemptions. Currently conservative (never claims a norm the numbers don't
  strictly support), which is the safe default but under-counts in specific
  event types. What is actually left, after checking each against the
  handbook text rather than against this list:

  - **Federation-mix exemptions (1.4.3 a-d).** Still open, and the one that
    bites in practice: a national championship or zonal is exempt from the
    "two other federations" rule, so a Belgian national championship where
    most opponents are Belgian reports `foreign_federations` and
    `own_federation_share` as failing when the norm is valid. Needs a
    tournament-level event-type field, which is a schema change plus a
    Settings control plus arbiter discipline in filling it in. One clause -
    1.4.3's big-Swiss case (20+ FIDE-rated players from 3+ federations,
    10+ GM/IM/WGM/WIM title-holders per round) - is auto-detectable from
    data already held and needs no new input.
  - **7/8-game concessions (1.4.1.1-1.4.1.3).** Still open. World Team/Club
    and Continental Team/Club Championships, the World Cup, and the
    unplayed-last-round-win case. Same event-type dependency.
  - ~~**Double-round-robin titled-opponent halving.**~~ **Not a gap - this
    entry was wrong**, and acting on it would have introduced a real bug in
    the dangerous direction. The requirement is already satisfied, because
    the two sides count in different units: `counted_games/2` emits one
    entry per GAME, so a DRR opponent is counted twice, while the Annex
    counts distinct people ("Different MO"/"Different TH") and halves the
    requirement to compensate. Halving `high_needed` on top of the per-game
    count would have asked for ONE distinct titled opponent where FIDE asks
    for two. `title_norms_test.exs` now pins both sides of that boundary.
    (The article number in the old text was wrong too - it is 1.4.5's final
    clause, not 1.4.3d.) The companion "DRR needs 6+ players" rule is
    likewise redundant: a 5-player DRR is 8 games, which the 9-game minimum
    already refuses.
- Standalone binaries (`docs/binaries.md`) have no automated smoke test in
  CI beyond "it builds" - nothing currently boots each target and hits `/`.
- ~~Re-uploading a `.swar` file for a tournament already in OpenPairings
  creates a second, duplicate tournament instead of updating the existing
  one~~ - **first step shipped**: `tournaments.swar_guid` is now stored on
  import, and re-uploading a file whose GUID matches a tournament the
  uploader can already reach shows a warning ("This looks like a
  tournament you already have") with the choice to open the existing one,
  import as a new tournament anyway, or cancel - instead of silently
  creating a duplicate. Still open: a full field-level *merge* (rebuild
  rounds/results without clobbering OpenPairings-only edits like
  norm_data, manual ranking, extra points, forbidden pairings) - that's
  real additional work beyond the detect-and-ask step and deliberately not
  scoped yet.

## Process notes for whoever picks this up next

- `mix precommit` (compile --warnings-as-errors, deps.unlock --unused,
  format, test) is the pre-flight check; CI runs the equivalent.
- `mix format --check-formatted` must stay green - the whole repo was
  normalized to pass it in 2026-07-25; don't let it silently regress by
  editing with a tool that reintroduces CRLF (`.gitattributes` pins source
  files to LF, but a misconfigured editor can still fight it locally).
- Never commit `Co-Authored-By`/`Generated with Claude Code` trailers to
  this repo - an explicit, standing maintainer preference.
- `docs/AGENTS.md` and this file were written in a single documentation
  pass (2026-07-25); nothing enforces they get updated when the code moves
  on. Treat any obviously stale claim in either as a bug, not gospel - see
  the note at the top of `docs/AGENTS.md`.
