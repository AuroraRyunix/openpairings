# TODO / Roadmap

Version: **0.11.1** (not 1.0 yet — the maintainer will call that explicitly).
See [`docs/features.md`](docs/features.md) for what's already shipped.

## Known gaps / deferred features

These are real, identified gaps — not yet built, and not accidentally missed:

- **Admin/support role** (`users.role`) — no staff/support role exists yet;
  every user is a plain account owner. Deferred, no target date.
- ~~**FIDE/KBSB "last synced" banner**~~ — this claim was already stale:
  the topbar's `.sync-freshness` strip ("FIDE: 3 days ago · KBSB: never
  synced") has been showing this for a while (`Layouts.sync_label/1`,
  `Fide.last_sync/0`/`Kbsb.last_sync/0`). Nothing left to build here.
- ~~**Live "round paired by someone else" notice**~~ — this claim was
  already half-stale: PairingsLive has had a dismissible "updated by
  another arbiter" toast (`remote_notice`) for a while, comparing the
  freshly-reloaded round against what's on screen to tell a real remote
  change from its own broadcast echo. **Now shipped**: the identical
  mechanism on PlayersLive too, the other page where two arbiters actively
  editing at once is a real scenario (registration, ratings) rather than
  just viewing. Standings/Live-round/public pages weren't extended — they're
  read-only "projector" views whose whole point is reflecting changes live,
  where a toast would be noise rather than useful.
- **Team tournaments** — explicitly deferred by the maintainer as a "future
  thing." More scaffolding already exists than this note used to claim:
  `Tournaments.Team` schema, `Player.team_id`/`board_order`, TRF16 team-block
  read/write (`Trf.team_line/1`/`parse_team_line/3`), and "Swiss (teams)"/
  "Round robin (teams)" are already selectable as a tournament format. None
  of it is wired end-to-end though — no team CRUD UI, `Pairing.pair_next_round/1`
  doesn't branch on team type at all (teams pair as plain individuals today),
  no team standings/tiebreaks, and the team TRF block is never actually sent
  to JaVaFo. Still a real, substantial feature gap — just not a from-scratch
  one.
- **American (accelerated pairing) system** — explicitly dropped, not planned
  ("no one cares" — maintainer's own call).
- **SWAR presence points on pairing-allocated byes (`SW321_PreBye`)** —
  modelled now (`tournaments.presence_on_allocated_bye`,
  `Standings.bye_points/2`); if a real club file ever surfaces where this
  models differently than expected, re-verify against it (only synthetic
  fixtures + the one real file with a coincidental match have exercised it).

## Tech debt

- **`tournaments_live.ex` / `norms_live.ex`** carry `.form-grid` (not the
  Settings pages' `.set-*` layout primitives) by design — those two pages
  are outside the Settings nav, so the inconsistency is intentional, not
  unfinished. Worth a second look only if Settings' layout system is ever
  extended app-wide on purpose.
- ~~Round robin's `total_rounds/2` vs. a user-set `rounds_count`~~ —
  **shipped**: this used to disagree in the UI (an arbiter could set
  `rounds_count` to anything, mismatching what the Berger schedule for
  their actual roster needs — real complaint: "I get too many rounds").
  `RoundRobin.pair_next_round/1` now corrects `rounds_count` to the real
  schedule total the moment players are frozen, every call — round-robin's
  length was never a free-standing choice the way it is for Swiss, it's a
  pure function of player count + cycles/match-format. Round-robin also
  now pairs its whole schedule in one action (`RoundRobin.pair_all_rounds/1`,
  confirm-gated on the Pairings page's "Pair the whole tournament" button)
  instead of one round at a time, since a round-robin round's pairings
  never depend on prior results — closing the "I don't see all rounds in
  advance" complaint too, since the whole schedule now exists right after
  that one click.

## FIDE endorsement readiness

Full checklist, current status per item, and the testing-harness plan live
in [`docs/fide-endorsement.md`](docs/fide-endorsement.md) (built from FIDE's
own Annex 4 Verification Check List and Annex 1 endorsement form). Concrete
gaps identified there, extracted here as actionable items:

- ~~Lock `pairing_number` after round 4 is paired~~ (VCL.09) — **shipped**:
  `Tournaments.update_player/2` now rejects changing an already-assigned
  number once 4 rounds are paired; a first assignment (late entry) still
  always works.
- ~~Asymmetric ½-0 / 0-½ result support~~ (VCL.13) — **shipped**: the TRF16
  spec itself has no cross-validation rule between the two sides' codes
  (that was `Trf`'s own invention) — it's just `=` for the ½ side, `0` for
  the 0 side. Wired through the schema, result-entry UI, standings scoring,
  TRF export/import (both directions), Keizer's own scoring, and SWAR
  import (which already had bitfield codes for this, previously dropped as
  unmappable). See `docs/fide-endorsement.md`'s VCL.13 entry for the file
  list.
- ~~Fuzz-testing harness — but not a pairing checker~~ — **shipped**: (1)
  `test/pairings_engine/trf_property_test.exs` — `StreamData` property tests
  on `Trf.serialize/1` against random-but-legal rosters/histories, checked
  against ground truth via `parse/1` round-tripping rather than re-deriving
  `Trf`'s own column positions; (2)
  `test/pairings_engine/cross_program_test.exs` — runs OpenPairings' real
  `Pairing.pair_next_round/1` (JaVaFo) against `bbpPairings` (Bierema Boyz
  Programming, Apache-2.0, vendored in `priv/bbppairings/` — a genuinely
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
  entirely, to rule out an OpenPairings-side bug) — needs FIDE Dutch-system
  rules research to tell whether this is a bbpPairings quirk, a JaVaFo
  quirk, or a genuinely underspecified tie-break FIDE's own rules leave
  open; the harness's exact job is surfacing this, not resolving it.
- ~~TRF06 import~~ (VCL.11, recommended not mandatory) — **shipped**: read
  FIDE's actual archived TRF06 specs (2006 and 2016 versions) rather than
  guessing — column positions are byte-identical to TRF16, so no separate
  importer was needed, just tolerating TRF06's older bye convention (a
  dangling playing code, no F/H/U/Z). Verifying this surfaced and fixed two
  real `Trf` bugs along the way — see `docs/fide-endorsement.md`'s VCL.11
  entry.
- ~~Two smaller "needs verification" items~~ (UTF-8 response headers on the
  TRF export, no accidental "FIDE"-branded claim about OpenPairings itself
  in the UI) — **both verified**: UTF-8 was already correct (confirmed via
  `Plug.Conn`'s own source, locked in with a test); the login page's hero
  copy had one real overclaim ("FIDE-compliant pairings..."), reworded.
- ~~Trailing pairing-allocated byes scored as draws instead of their
  awarded value~~ (VCL.19) — **shipped**: found while auditing
  `standings.ex` against FIDE's C.07 revision effective 1 March 2026
  (Art. 16.2.1/16.3). `Pairing.result == "bye"` (JaVaFo's own
  odd-player-count byes) was marked `voluntary: true` — inconsistent with
  the `byes`-table path, which already excluded `"pairing-allocated"` from
  its own `voluntary` set. A trailing occurrence (the common last-round
  case) made `adjusted_score/3` substitute a draw's worth of points for
  the bye's real value in every opponent's Buchholz/SB. See
  `docs/fide-endorsement.md`'s VCL.19 entry.
- ~~C.07's new Art. 16.5.1 "Cut-1 Exception"~~ (VCL.19) — **shipped**:
  BHC1/BHC2/MBH now cut a contribution from one of the participant's own
  voluntary unplayed rounds (a bye, via `dummy_score/3`) in preference to
  an ordinary game contribution, reusing the existing `voluntary` flag as
  the VUR tag. See `docs/fide-endorsement.md`'s VCL.19 entry.
- ~~SWAR's "absent" bye type unconditionally treated as voluntary~~ —
  **shipped**: new `Tournament.absent_counts_as_vur` setting, off by
  default (an absence always counts at its award value, like a forfeit
  loss — FIDE has no "absent" concept, so this is the strict/safe
  reading); an arbiter can opt in from Settings for the more lenient
  requested-bye-style treatment. See `docs/fide-endorsement.md`'s VCL.19
  entry.

## Backlog (no particular order, nothing blocking)

- ~~"Substitute player" draws its journey arrow on the wrong seat~~ —
  **shipped 2026-08-15, the "bigger redesign" option**: `matchTravellers()`
  in the `.SwapArrows` hook matches purely by NAME across the whole modal,
  not per-row (see its own extensive comments) — `confirm_for/2`'s
  `:swap_pool` branch now adds a second "Not playing list" row (new
  `bench_card/1` component, single-seat, no colour disc) showing the pool
  player on "before" and the seated player on "after". Because those two
  names already appear once each on the real board row's opposite side,
  the UNCHANGED hook now finds a clean match for both and draws two real
  arrows — one in, one out — exactly as asked, with zero changes to
  `matchTravellers()`/`render()` themselves. The previously-misleading
  phantom arrow on the *unaffected* seat (e.g. white, when black was
  substituted) still fires — the hook's own stated philosophy is "everyone
  shown gets an arrow, the ones who stayed put get a short one back to
  their own seat" — but it's no longer the sole, unexplained arrow on
  screen; it now sits alongside two clearly-purposeful in/out arrows, so it
  reads as "white stayed" rather than as a wrong-looking swap. Not
  separately suppressed - consistent with how a real 2-board swap already
  shows a short "stayed" arrow for an unmoved board partner.

- **Chief arbiter (and the other Officials fields) are unfindable without
  the link.** They live on `/t/:id/norms`, moved there from SettingsLive at
  some point (see `norms_live.ex`'s "relocated from SettingsLive" notes).
  Nothing is broken — the "ready to pair" hint on PairingsLive links
  straight to the right page via `setup_field_path/2`, and the field saves
  fine — but an arbiter looking for "chief arbiter" will look under
  **Settings**, not under a page called **Norms**, and there is nothing on
  Settings pointing them onward. Reported by the maintainer, who could not
  find it even while holding the link.

  Cheapest fix is to say where the link goes ("Chief arbiter — on the Norms
  page") and/or leave a pointer in the Settings → Tournament card. The
  fuller fix is moving Officials back to Settings, which is a bigger move
  and would want its own think about what Norms is then for.

- ~~"Players - title-norm judgment" table has no meaningful sort order~~ —
  **shipped**: `players_by_norm_relevance/2` now sorts achieved-norm
  players first, then closest-to-qualifying (fewest failing B.01 checks on
  their nearest-miss title), then no-games players last.
- ~~"Explain a round" score-bracket map misplaces handicap-table players~~ —
  **shipped, real confirmed bug**: SWAR assigns accessible/"handicap table"
  pairings a per-round Table number starting at 1001 (`TABLE_HANDICAP + N`,
  Swar.h) — not a real board number, just like the `TABLE_BYE` sentinel
  already handled. The importer was copying it verbatim into `board`, so a
  handicap-table pairing (confirmed via production tournament 18, round 5,
  Vandekerckhove Ava — `board: 1001` in the actual DB row) sorted to the
  far end of anything ordered by board number, including the rationale
  bracket map, regardless of real score. `SwarImport.finalize_boards/1` now
  renormalizes a handicap-range Table value the same way it already did for
  byes. Only fixes *future* imports — tournament 18's existing round-5 row
  still has the raw 1001 in the DB; a one-off data fix there is separate,
  deliberately not done without asking first (touches live tournament
  data).
- ~~Public standings page needs to be a clean spectator overview~~ —
  **shipped**: `/p/:slug/standings` and `/p/:slug/pairings` now render
  through a new minimal `Layouts.public/1` (brand + theme switch only, no
  tournament tabs/accent picker/sign-in) instead of the full authenticated
  `Layouts.app/1`, and both show a compact arbiter/deputy/tempo/round-dates
  line (`PairingsEngineWeb.Components.PublicTournamentMeta`) when set.
- ~~Printed standings/pairings pages don't carry the arbiter/tempo/
  round-dates line~~ — **shipped**: `PrintController`'s shared
  `tournament_info_html/1` (already used by every print doc — pairings,
  standings, player list/cards, crosstable, place cards, result cards) was
  missing deputy arbiter and the per-round dates list (`round_dates`,
  distinct from the free-text `start_date`/`end_date` it already showed).
  Both added as their own line items, labeled "Deputy arbiter" and "Round
  date(s)" to stay unambiguous next to the existing "Dates: start – end".
- **Audit OpenPairings' logic against SWAR's own C++ source, file by
  file.** Very low priority — this is a "nice to have more confidence,"
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
  `Classement.cpp` (tiebreaks), `Utils.cpp` (shared edge-case logic — this
  is where the round-specific-absence bug lived), and `EnvoiJAVAFO.cpp`
  (SWAR's own TRF builder, directly comparable to
  `Pairing.javafo_input`/`TrfExport` — the class of bug already found
  twice). Both real bugs found so far came from symptom-driven
  investigation (a real tournament comparison surfacing something odd,
  then a targeted SWAR-source dive), not exhaustive pre-auditing — that's
  the higher-leverage pattern to keep leaning on rather than this.
- Remaining SWAR-parity items: hard pairing variants (accelerated pairing
  beyond Baku, more exotic tiebreak orderings) and printing extras beyond
  what's in `docs/printing.md`.
- Extend the automatic B.01 title-norm judgment
  (`PairingsEngine.Norms.TitleNorms`) to the documented-but-unmodelled
  exemptions: national-championship/zonal federation-mix exemptions
  (art. 1.4.3a-e), the double-round-robin titled-opponent halving
  (art. 1.4.3d), and the 7/8-game event concessions (art. 1.4.1.1-1.4.1.3).
  Currently conservative (never claims a norm the numbers don't strictly
  support), which is the safe default but under-counts in those specific
  event types.
- Standalone binaries (`docs/binaries.md`) have no automated smoke test in
  CI beyond "it builds" — nothing currently boots each target and hits `/`.
- ~~Re-uploading a `.swar` file for a tournament already in OpenPairings
  creates a second, duplicate tournament instead of updating the existing
  one~~ — **first step shipped**: `tournaments.swar_guid` is now stored on
  import, and re-uploading a file whose GUID matches a tournament the
  uploader can already reach shows a warning ("This looks like a
  tournament you already have") with the choice to open the existing one,
  import as a new tournament anyway, or cancel — instead of silently
  creating a duplicate. Still open: a full field-level *merge* (rebuild
  rounds/results without clobbering OpenPairings-only edits like
  norm_data, manual ranking, extra points, forbidden pairings) — that's
  real additional work beyond the detect-and-ask step and deliberately not
  scoped yet.

## Process notes for whoever picks this up next

- `mix precommit` (compile --warnings-as-errors, deps.unlock --unused,
  format, test) is the pre-flight check; CI runs the equivalent.
- `mix format --check-formatted` must stay green — the whole repo was
  normalized to pass it in 2026-07-25; don't let it silently regress by
  editing with a tool that reintroduces CRLF (`.gitattributes` pins source
  files to LF, but a misconfigured editor can still fight it locally).
- Never commit `Co-Authored-By`/`Generated with Claude Code` trailers to
  this repo — an explicit, standing maintainer preference.
- `docs/AGENTS.md` and this file were written in a single documentation
  pass (2026-07-25); nothing enforces they get updated when the code moves
  on. Treat any obviously stale claim in either as a bug, not gospel — see
  the note at the top of `docs/AGENTS.md`.
