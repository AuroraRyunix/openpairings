# OpenPairings documentation

OpenPairings is a chess tournament manager (Elixir/Phoenix + LiveView + SQLite):
Swiss pairing via JaVaFo, round robin (Berger), the Keizer system,
FIDE tiebreaks (C.07), TRF16 export/import, FIDE + KBSB rating lists,
SWAR import, per-tournament sharing, and FIDE norm/report forms.

**Start here: [Features & roadmap](features.md)** — a one-page overview of
everything the app does and what is planned next.

## Project documentation

- [Architecture](architecture.md) — system design, data flow, module
  boundaries.
- [Setup guide](setup-guide.md) — environment setup, prerequisites, dev
  workflow.
- [Deployment](deployment.md) — how the live instance is actually run.
- [AGENTS.md](AGENTS.md) — deep technical context for AI coding agents
  (invariants, non-obvious patterns, gotchas) — read this before making a
  change to the pairing engine, norms/`.xlsx` filling, or standings.
- [Standalone binaries](binaries.md) — Burrito single-file executables.
- [FIDE endorsement readiness](fide-endorsement.md) — the Verification Check
  List mapped against OpenPairings' JaVaFo-wrapper architecture, current gaps,
  and the RTG/FPC fuzz-testing harness plan.

## Feature guides

- [Pairing systems](pairing-systems.md) — Swiss (FIDE Dutch via JaVaFo),
  round robin (Berger tables, single/double), and the Keizer system (ladder
  values, retroactive recalculation, Keizer-point standings); the per-tournament
  selector locks after the first pairing.
- [Forbidden pairings](forbidden-pairings.md) — pairs of players that must
  never meet: managed in Settings, enforced in Swiss (JaVaFo `XXP`) and Keizer;
  round robin ignores them by design. Includes club/federation exclusion rules
  (never pair clubmates / same-federation players, for all or only listed
  clubs/federations).
- [SWAR import](swar-import.md) — .swar parsing, national vs FIDE id mapping,
  FIDE-database matching for players without a FIDE id (with a resolve step
  during import), full birth dates, federation normalization to FIDE codes,
  and SWAR's "3-2-1" configurable scoring (a `TOURNOI_TYPE == 3` file carries
  its own win/draw/loss/bye point values, stored ×8).
- [Acceleration](acceleration.md) — Baku accelerated Swiss (FIDE C.04.5): we
  compute each Group-A player's virtual points per round ourselves and hand
  JaVaFo the full history via fixed-column `XXA` lines, because JaVaFo does
  not derive acceleration from a flag on its own.
- [Manual standings](manual-standings.md) — the arbiter's hand-set standings
  order: an explicit, per-tournament override mode with a banner on every
  surface that shows a rank, and a staleness flag raised the moment a result
  or bye changes. Display-only — never affects points, tiebreaks, or the TRF.
- [Printing](printing.md) — print documents (player list, cards, pairings,
  standings, per-round result cards, place cards/chevalets, cross table —
  Swiss-style plus a players×players grid for round robin), the `?round=N`
  query param, per-page/per-round print buttons, the result-card `?limit=N`
  test print and `?order=stack` stack-cutting imposition, and the
  per-tournament logo (uploaded in Settings, stored as a DB blob).
- [TRF import](trf-import.md) — one-step `.trf` upload creating a complete new
  tournament (players, rounds, results, byes, officials, round dates); points
  are recomputed and cross-checked against the file's own points column.
- [KBSB rating list](kbsb-sync.md) — Belgian national ratings via file-upload
  import (no stable public bulk download exists) on the Rating lists page,
  with national-id / FIDE-id autofill in the player form.
- [Arbiter tools](tools.md) — public no-login `/tools/norms` page: upload
  SWAR/TRF files, download IT3/FA1/IA1 forms; festival combining with a
  master tournament; sessions live 60 minutes in memory only, nothing stored.
- [Norms & FIDE forms](norms.md) — generating IT3 (per tournament) and FA1 / IA1
  (arbiter norms) / IT4 (player title norms) by filling the official FIDE Excel
  templates in place; the Officials data captured in Settings; combined
  "festival" reports across several tournaments (categories of one event).
- [Import / export](import-export.md) — user-facing TRF export with round
  selection (`?rounds=1-5,7`), and full-fidelity JSON backup/restore of a single
  tournament or all of them (imports become new tournaments owned by you).
- [Results import (CSV)](results-import.md) — bulk-enter a round's results from
  a "board;result" CSV on the Pairings page; all-or-nothing with per-line
  errors, boards not mentioned keep their result.
- [PGN export](pgn-export.md) — metadata-only PGN (Seven Tag Roster, no moves)
  per round or for the whole tournament, from the Pairings page or
  `/t/:id/export/pgn?round=N`.
- [Extra points](extra-points.md) — administrative bonus points (SWAR XtPts):
  Elo-band auto-assign in Settings and a strictly opt-in, per-tournament
  toggle to count them in standings ranking; pairing is never affected.
- [Rating refresh](rating-refresh.md) — bulk re-lookup of every player against
  the locally-synced FIDE and KBSB lists with a dry-run diff preview before
  anything is written; the Standings and Players pages also show FIDE expected
  score (We) and W−We columns.
- [Team sharing](teams.md) — invite people to a tournament by email; they accept
  via a magic link before getting access, then can edit/pair/enter results.
  Owner-only: delete and collaborator management. Data model:
  `tournament_collaborators` (status pending/accepted).
- [Public pages](public-pages.md) — share `/p/<token>/pairings` and
  `/p/<token>/standings`: no login needed, read-only, live-updating, and the
  token is unguessable so tournaments can't be enumerated.
- [Mobile no-account result entry](mobile-results.md) — QR/code-enrol a
  helper's phone from the Live page for results-only access to one
  tournament: session persistence, the confirm-before-clear and lock-toggle
  protections, and the per-device theme toggle.
- [Mobile / responsive](mobile.md) — how the layout adapts at phone/tablet
  widths (breakpoints, scrollable tables, wrapping nav) while desktop stays
  full-width and unchanged.
- [Email / SMTP](email.md) — local mailbox preview in dev (`/dev/mailbox`), Gmail
  SMTP configuration via `.env` for production, credential management.

## Cross-cutting behavior

- **Live refresh** — every tournament LiveView subscribes to
  `"tournament:#{id}"` over Phoenix PubSub; any write (result, player, settings,
  sharing) pushes to all open pages instantly, no polling. Open the projector
  view at `/t/:id/live`.
- **Result codes** — `1-0`, `½-½`, `0-1`, plus forfeits `1-0FF` / `0-1FF` /
  `0-0FF` (double forfeit, unplayed) and a played `0-0` (both lose). Forfeits are
  Art. 16 unplayed for tiebreaks; played `0-0` counts as played. `Trf.serialize`
  raises `Trf.ValidationError` on illegal result combinations.

## Where things live

- `lib/pairings_engine/` — domain: `pairing.ex` (JaVaFo), `standings.ex` (C.07
  tiebreaks, supports `through_round:`), `trf.ex` (TRF16 + result validation),
  `trf_export.ex` / `tournament_export.ex` / `tournament_import.ex` (exports),
  `fide/sync.ex` (rating-list sync), `kbsb/` (Belgian rating-list import),
  `swar_import.ex` (.swar importer), `trf_import.ex` (TRF importer),
  `norms/` (Excel form fill engine + form mappers), `player_card.ex`,
  `tournaments/collaborator.ex` (sharing).
- `lib/pairings_engine_web/live/` — LiveView pages (one per top-bar tab), all
  subscribing to `"tournament:#{id}"` PubSub for instant live refresh.
- `priv/norm_templates/` — the official FIDE `.xlsx` templates.
