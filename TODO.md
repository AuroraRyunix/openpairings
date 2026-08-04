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

- **Lock `pairing_number` after round 4 is paired** (VCL.09 — FIDE requires
  this; nothing currently enforces it). Real footgun independent of
  endorsement: an accidental mid-event renumber (player edit, re-import)
  today has no guard at all.
- **Asymmetric ½-0 / 0-½ result support** (VCL.13) — needs research first
  (how FIDE expects this encoded in a TRF row pair, since the standard
  win/draw/loss/forfeit codes don't have an obvious slot for it) before any
  implementation.
- **Fuzz-testing harness — but not a pairing checker.** A plain checker
  (JaVaFo's own `-g`/`-c`, or bbpPairings') only verifies "is this pairing
  legal given this input" — it can't catch a wrong-but-internally-consistent
  input, which is exactly the bug class both real bugs this session were
  (neither would have been flagged by a checker). What's actually worth
  building: (1) property tests asserting OpenPairings' TRF-builder produces
  exactly the hand-computed-correct output for random rosters/histories —
  no external tool needed; (2) cross-program agreement at scale — run
  synthetic tournaments through OpenPairings' real pipeline *and*
  bbpPairings standalone (a genuinely independent second implementation,
  not just JaVaFo again) on identical input, diff the actual pairings.
  Neither needs a "1,000,000-tournament database" — a synthetic generator
  makes any volume cheap (pure CPU), and FIDE's own 1-per-500 error-ratio
  bar is a reasonable target for the cross-program half specifically.
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
- **"Explain a round" (pairing rationale) score-bracket map may misplace
  ~3 players — unconfirmed, "special table" ruled out, needs a live look
  at the real round.** Reported on production tournament "41ste
  Internationaal Open van Geraardsbergen 2026" (id 18), round 5: ~3
  players (incl. Vandekerckhove, Ava) sit further right than their score
  suggests. Traced `PairingRationale.score_groups/1` and
  `pre_round_scores/2` in full — brackets are built purely from
  `Standings.rank_score/2` (the same already-validated value the Standings
  page and TRF export use), with **zero** reference to
  `special_table`/`fixed_board` anywhere in that module, so that's not the
  mechanism. Two remaining possibilities, not yet distinguished: (1) these
  are genuine **floaters** — a pairing crossing bracket lines is the
  feature's whole documented purpose, in which case this isn't a bug, just
  possibly needs a clearer visual cue that a float is what's being shown;
  or (2) a real bug, but in `PairingsEngineWeb.PairingExplainLive`'s
  render/layout code specifically, not the rationale-computation backend
  (which traces back to already-trustworthy code). Needs the actual round
  5 page open (or the real `PairingRationale.for_round/2` output for that
  round) to tell which.
- **Public standings page (`/p/:slug/standings`) needs to be a clean
  spectator overview, not a stripped-down app page.** Right now it renders
  inside `Layouts.app` (see `docs/public-pages.md`) — no tournament tabs,
  but the topbar/theme-switch/accent-picker/sign-in chrome is all still
  there, which makes no sense for someone who just scanned a QR code to
  check standings. Should be its own minimal layout: tournament name,
  standings table, and the metadata a spectator/player actually wants —
  arbiters, tempo/time control, round dates, that kind of thing — none of
  which the page shows today. The printed standings page should carry the
  same information for the same reason (check `docs/printing.md` for what's
  there now). Look at what SWAR's own public/printed layout includes as a
  reference for *what data* to show — not to copy its visual design, just
  to make sure OpenPairings isn't quietly omitting something SWAR
  considers baseline. Keep it simple.
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
