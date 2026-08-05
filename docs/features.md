# OpenPairings — features & roadmap

Current version: **0.11.1**. One page: everything the app does today, and where
it is going. Per-feature detail lives in the other [docs pages](README.md).

## Pairing

- **Swiss (FIDE Dutch)** via JaVaFo 2.2 — the reference implementation of the
  FIDE Dutch system, driven through TRF16 files built and validated by the app.
  - **Accelerated Swiss (Baku, FIDE C.04.7)** — the app computes each Group-A
    player's virtual points per round and hands JaVaFo the full history via
    fixed-column `XXA` lines.
  - **Per-category pairing** — each category paired by its own independent
    JaVaFo run, merged into one round with continuous board numbers and a
    single pairing sheet.
  - **Match format** — two-game matches: each JaVaFo decision produces two
    back-to-back rounds, the second a colour-reversed mirror (verified safe
    against the real JaVaFo engine before implementation).
  - Robust against real-world rosters: absent and round-specific-absent
    players anywhere in the field (including mid-ranking gaps that crash a
    naive JaVaFo invocation) are handled via contiguous rank remapping.
- **Round robin (Berger tables)** — single or double cycle, match format
  (immediate colour-reversed rematches), automatic forfeit results for
  absent/forfeited players, odd-field structural byes.
- **Keizer system** — classic ladder values with retroactive recalculation and
  a dedicated Keizer standings table.
- **Forbidden pairings** — arbiter-managed never-pair list, plus rule-based
  club/federation exclusions (all or listed clubs/federations), enforced in
  Swiss (`XXP`) and Keizer.
- **Blind result entry** — SWAR-style keyboard flow: focus a board's result,
  type `1`/`2`/`3`, focus advances one board with smooth scrolling.

## Scoring, standings & tiebreaks

- **FIDE C.07 tiebreaks** (1 Mar 2026 regulations): BH, BHC1, BHC2, MBH, SB,
  DE, WIN/WON, BPG, PS, KS, ARO, AROC1 — including Article 16 unplayed-game
  handling. Per-tournament selection and ordering, FIDE-default preset.
- **Configurable scoring** — per-tournament win/draw/loss points, bye value,
  presence points, and plain-absence value (covers SWAR's "3-2-1" club
  scoring configurations exactly).
- **Extra points** — Elo-band bonus points with an opt-in toggle for counting
  them in the ranking.
- **Manual standings order** — an explicit arbiter override with a visible
  banner everywhere and a staleness flag raised the moment any result changes.
  Display-only; never touches points, tiebreaks, or the TRF.
- **Expected score** — FIDE Table 8.1.2 `We` and `W−We` columns.
- **Live standings** — every page auto-refreshes on any change, including a
  dedicated full-screen live view for a projector.

## Players & rating data

- **FIDE rating list** — synced from ratings.fide.com into a local database
  (~1.9M players) with autofill on player entry.
- **KBSB (Belgian) rating list** — CSV import with encoding/delimiter
  auto-detection, national-id autofill.
- **Bulk rating refresh** — one-click re-rating of a whole tournament from the
  local FIDE/KBSB databases, with a dry-run diff preview.
- **SWAR-style player grid** — every column sortable, plain-language tooltips
  on the abbreviated headers, and a per-user Display panel choosing which
  columns show.
- **Categories** — per-tournament age/rating categories with per-category
  standings and, for Swiss, native per-category pairing.

## Import & export

- **SWAR import** — full `.swar` files (players, rounds, results, byes,
  scoring configuration, absences), with FIDE-id resolution during import.
- **TRF16** — import (a complete tournament from a `.trf` file, points
  cross-checked) and export (full or selected rounds, FIDE-submission grade).
- **JSON backup** — full single-tournament or all-tournaments export and
  re-import.
- **CSV results import** — bulk result entry per round, all-or-nothing.
- **PGN export** — per-round metadata-only PGN.

## Printing

Player list, player cards, pairing lists (optional absentees section), 
standings, Swiss cross table, round-robin players×players cross table,
result cards (8 per A4, alignment test print, stack-cut imposition), and
folded place cards (chevalets) with field toggles — all per-round where it
makes sense, all reachable from the page they belong to. Tournaments can
carry a logo (stored in the database, shown on printed documents).

## Norms & FIDE reports

- **Official FIDE Excel forms** filled in place: IT3 (tournament report),
  FA1/IA1 (arbiter norms), IT4 (player title norms).
- **Festival combining** — multi-tournament (categories-of-one-event) combined
  reports with duplicate-player detection.
- **Public tools page** (`/tools/norms`) — no login: upload `.swar`/`.trf`
  files, get combined norm reports; nothing is stored server-side.

## Accounts, sharing & transparency

- **Accounts** with magic-link, password, or 02cloud SSO (Keycloak) login;
  every tournament is private to its owner.
- **Collaborators** — invite by e-mail with explicit accept/decline; owners
  keep delete and sharing rights.
- **Public read-only pages** — unguessable per-tournament links for pairings
  and standings, live-updating, no login. A QR on the Live page links
  straight to public standings for spectators.
- **Mobile no-account result entry** — an arbiter QR/code-enrols a helper's
  phone for results-only access to one tournament (no account, revocable,
  24h expiry); the results screen shows each player's rating and score
  entering the round, a lock toggle to guard against accidental taps, and a
  per-device theme switch.
- **Audit trail** (Advanced menu) — every state-changing action recorded:
  who, when, what, with field-level diffs for settings changes.
- **"Explain a round"** (Advanced menu) — a visual rationale per paired round:
  a score-bracket map showing every pairing as a connector between score
  groups (floaters visibly crossing bands), board-by-board cards with colour
  chips, due-colour verdicts and float badges. Exact explanations for round
  robin and Keizer; honest input/output analysis for Swiss (JaVaFo's internal
  reasoning is not pretended to be known).
- **Recycle bin** — deleted tournaments are soft-deleted and restorable.

## Platform

- Elixir/Phoenix LiveView + SQLite; runs locally with `mix phx.server` and
  deploys unchanged to a server (systemd, SMTP e-mail, production hardening).
- Responsive layout for tablet/phone; desktop stays full-width.
- CI on GitHub Actions; 950+ tests including end-to-end runs against the real
  JaVaFo engine.

## What's next

Near-term, in rough order:

1. **Admin/support role** — a federation-level support account that can see
   and assist with tournaments it doesn't own.
2. **Rating-list freshness banner** — surface the FIDE/KBSB "last synced"
   timestamps in the top bar.
3. **Concurrent-arbiter notice** — pages already live-update when a colleague
   pairs a round; add a visible "round N was just paired by X" banner instead
   of only the silent refresh.
4. **Match-format round labels** — group a match's two rounds visually
   ("Match 3, game 1/2") instead of plain round numbers.

Later / larger:

- **Team tournaments** (team Swiss, team round robin, match cards) — the
  biggest remaining item, deliberately deferred until the individual
  tournament feature set is fully solid.

Explicitly out of scope (decided, not planned):

- The American/difference-scaling pairing system.

Version 1.0 will be tagged once the current feature set has survived real
tournament use.
