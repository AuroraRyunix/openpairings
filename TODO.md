# TODO / Roadmap

Version: **0.11.1** (not 1.0 yet — the maintainer will call that explicitly).
See [`docs/features.md`](docs/features.md) for what's already shipped.

## Known gaps / deferred features

These are real, identified gaps — not yet built, and not accidentally missed:

- **Admin/support role** (`users.role`) — no staff/support role exists yet;
  every user is a plain account owner. Deferred, no target date.
- **FIDE/KBSB "last synced" banner** — smaller than it sounds:
  `PairingsEngine.Fide.Sync` / `PairingsEngine.Kbsb.Sync` are already
  singleton GenServers and `Fide.last_sync/0` already tracks a timestamp;
  only the UI banner showing it is missing.
- **Live "round paired by someone else" notice** — PubSub already refreshes
  every open page silently when a round is paired elsewhere; there's no
  visible toast/banner calling that out to the arbiter who didn't do it.
- **Team tournaments** — explicitly deferred by the maintainer as a "future
  thing." No schema, no UI.
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
- **Round robin's `total_rounds/2` vs. a user-set `rounds_count`** — pairing
  now clamps to whichever is lower (an explicit product decision), but the
  two numbers can still legitimately disagree in the UI if an arbiter sets
  `rounds_count` below what the Berger schedule needs. Not a bug, just worth
  remembering when reading round-count logic.

## FIDE endorsement readiness

Full checklist, current status per item, and the testing-harness plan live
in [`docs/fide-endorsement.md`](docs/fide-endorsement.md) (built from FIDE's
own Annex 4 Verification Check List and Annex 1 endorsement form). Concrete
gaps identified there, extracted here as actionable items:

- ~~Lock `pairing_number` after round 4 is paired~~ (VCL.09) — **shipped**:
  `Tournaments.update_player/2` now rejects changing an already-assigned
  number once 4 rounds are paired; a first assignment (late entry) still
  always works.
- **Asymmetric ½-0 / 0-½ result support** (VCL.13) — needs research first
  (how FIDE expects this encoded in a TRF row pair, since the standard
  win/draw/loss/forfeit codes don't have an obvious slot for it) before any
  implementation.
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
- **TRF06 import** (VCL.11, recommended not mandatory) — low priority unless
  a real TRF06 file needs importing.
- Two smaller "needs verification" items in the doc (UTF-8 response headers
  on the TRF export, no accidental "FIDE"-branded claim about OpenPairings
  itself in the UI) — quick greps, not full features.

## Backlog (no particular order, nothing blocking)

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
  line (`PairingsEngineWeb.Components.PublicTournamentMeta`) when set. Still
  open: the *printed* standings/pairings pages carrying the same info (not
  touched in this pass).
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
