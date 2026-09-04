# OpenPairings - features & roadmap

Current version: **0.36.3**. One page: everything the app does today, and where
it is going. Per-feature detail lives in the other [docs pages](README.md).

## Pairing

- **Swiss (FIDE Dutch)** on either of two engines, chosen per tournament and
  driven through TRF16 files built and validated by the app:
  - **[Ainalrami](https://github.com/AuroraRyunix/Ainalrami)** (default) -
    written for this project in Elixir, implementing C.04.3 as it stands
    from **1 February 2026**, in-process with no JVM. Cross-checked against
    bbpPairings 6.0.0 over 2.5 billion individual pairings with two
    disagreements, both defects in bbpPairings. See
    [`fide-endorsement.md`](fide-endorsement.md).
  - **JaVaFo 2.2** - FIDE's own reference implementation, of the **2022**
    edition of C.04.3. External, needs a JVM, and is the choice for an
    organiser who wants the endorsed engine rather than the current rules.
  - **Accelerated Swiss (Baku, FIDE C.04.7)** - the app computes each Group-A
    player's virtual points per round and hands the selected engine the full
    history via fixed-column `XXA` lines.
  - **Per-category pairing** - each category paired by its own independent
    engine run, merged into one round with continuous board numbers and a
    single pairing sheet.
  - **Match format** - two-game matches: each pairing decision produces two
    back-to-back rounds, the second a colour-reversed mirror (verified safe
    against the real JaVaFo engine before implementation).
  - Robust against real-world rosters: absent and round-specific-absent
    players anywhere in the field (including mid-ranking gaps that crash a
    naive JaVaFo invocation) are handled via contiguous rank remapping.
- **Round robin (Berger tables)** - single or double cycle, match format
  (immediate colour-reversed rematches), automatic forfeit results for
  absent/forfeited players, odd-field structural byes.
- **Keizer system** - classic ladder values with retroactive recalculation and
  a dedicated Keizer standings table.
- **Forbidden pairings** - arbiter-managed never-pair list, plus rule-based
  club/federation exclusions (all or listed clubs/federations), enforced in
  Swiss (`XXP`) and Keizer.
- **Blind result entry** - SWAR-style keyboard flow: focus a board's result,
  type `1`/`2`/`3`, focus advances one board with smooth scrolling.

## Scoring, standings & tiebreaks

- **FIDE C.07 tiebreaks** (1 Mar 2026 regulations): BH, BHC1, BHC2, MBH, SB,
  DE, WIN/WON, BPG, PS, KS, ARO, AROC1 - including Article 16 unplayed-game
  handling. Per-tournament selection and ordering, FIDE-default preset.
- **Configurable scoring** - per-tournament win/draw/loss points, bye value,
  presence points, and plain-absence value (covers SWAR's "3-2-1" club
  scoring configurations exactly).
- **Extra points** - Elo-band bonus points with an opt-in toggle for counting
  them in the ranking.
- **Manual standings order** - an explicit arbiter override with a visible
  banner everywhere and a staleness flag raised the moment any result changes.
  Display-only; never touches points, tiebreaks, or the TRF.
- **Published tiebreak working** - each published standings row carries, per
  tiebreak, one contribution per round: which opponent it came from, what it
  was worth, and whether a cut modifier discarded it or Article 16 supplied a
  virtual opponent. OpenResults renders it as the answer to "why am I
  fourth", and never recomputes it - a Buchholz sums opponents' ADJUSTED
  scores, so a public page adding up the visible numbers would disagree with
  the arbiter's. Only the tiebreaks that cannot be re-derived from the
  published results are sent.
- **Per-tiebreak publishing** - which tiebreak columns the public page shows,
  one checkbox each, separately from whether the working is published.
  Hiding a column does not stop it deciding the order, so the published page
  says the order used tiebreaks it does not show.
- **Expected score** - FIDE Table 8.1.2 `We` and `W−We` columns.
- **Live standings** - every page auto-refreshes on any change, including a
  dedicated full-screen live view for a projector.

## Players & rating data

- **FIDE rating list** - synced from ratings.fide.com into a local database
  (~1.9M players) with autofill on player entry.
- **KBSB (Belgian) rating list** - CSV import with encoding/delimiter
  auto-detection, national-id autofill.
- **Bulk rating refresh** - one-click re-rating of a whole tournament from the
  local FIDE/KBSB databases, with a dry-run diff preview.
- **SWAR-style player grid** - every column sortable, plain-language tooltips
  on the abbreviated headers, and a per-user Display panel choosing which
  columns show.
- **Categories** - per-tournament age/rating categories with per-category
  standings and, for Swiss, native per-category pairing.

## Import & export

- **SWAR import** - full `.swar` files (players, rounds, results, byes,
  scoring configuration, absences), with FIDE-id resolution during import.
- **TRF16** - import (a complete tournament from a `.trf` file, points
  cross-checked) and export (full or selected rounds, FIDE-submission grade).
- **JSON backup** - full single-tournament or all-tournaments export and
  re-import.
- **CSV results import** - bulk result entry per round, all-or-nothing.
- **PGN export** - per-round metadata-only PGN.

## Printing

Player list, player cards, pairing lists (optional absentees section), 
standings, Swiss cross table, round-robin players×players cross table,
result cards (8 per A4, alignment test print, stack-cut imposition), and
folded place cards (chevalets) with field toggles - all per-round where it
makes sense, all reachable from the page they belong to. Tournaments can
carry a logo (stored in the database, shown on printed documents).

## Norms & FIDE reports

- **Official FIDE Excel forms** filled in place: IT3 (tournament report),
  FA1/IA1 (arbiter norms), IT4 (player title norms).
- **Festival combining** - multi-tournament (categories-of-one-event) combined
  reports with duplicate-player detection.
- **Public tools page** (`/tools/norms`) - no login: upload `.swar`/`.trf`
  files, get combined norm reports; nothing is stored server-side.

## Accounts, sharing & transparency

- **Accounts** with magic-link, password, or 02cloud SSO (Keycloak) login;
  every tournament is private to its owner.
- **Collaborators** - invite by e-mail with explicit accept/decline; owners
  keep delete and sharing rights.
- **Publishing to OpenResults** - a tournament is pushed to the public
  results site under an unguessable per-tournament link: pairings, standings
  and a card per player, no login. A QR on the Live page points spectators
  straight at it. Seventeen per-tournament switches decide what a published
  page may show, from whole pages down to individual columns, and a hidden
  one is withheld when the document is built rather than sent and hidden at
  the other end.

  The read-only pages used to be served by this app itself; they moved to
  OpenResults on 2026-08-29 so a busy public page and a live pairing session
  cannot take each other down.
- **Mobile no-account result entry** - an arbiter QR/code-enrols a helper's
  phone for results-only access to one tournament (no account, revocable,
  24h expiry); the results screen shows each player's rating and score
  entering the round, a lock toggle to guard against accidental taps, and a
  per-device theme switch.
- **Audit trail** (Advanced menu) - every state-changing action recorded:
  who, when, what, with field-level diffs for settings changes.
- **"Explain a round"** (Advanced menu) - a visual rationale per paired round:
  a score-bracket map showing every pairing as a connector between score
  groups (floaters visibly crossing bands), board-by-board cards with colour
  chips, due-colour verdicts and float badges. Exact explanations for round
  robin and Keizer, and for Swiss on Ainalrami, which reports the criteria it
  applied per bracket and per board (which colour preference was denied, whose
  float was repeated). Swiss on JaVaFo stays an honest input/output analysis:
  its internal reasoning is not pretended to be known.
- **Recycle bin** - deleted tournaments are soft-deleted and restorable.
- **Federation features** (`/users/features`) - the Belgium-specific parts of
  the app are five independent per-account switches, all off by default: the
  KBSB rating-list sync, the KBSB player lookup, the bulk club update, SWAR
  import and SWAR export. An arbiter outside Belgium never sees any of them;
  one inside it ticks what they use. Switching a feature off hides buttons
  and nothing else - every tournament already imported keeps its players,
  clubs, scoring settings and standings exactly as they are.

## Platform

- Elixir/Phoenix LiveView + SQLite; runs locally with `mix phx.server` and
  deploys unchanged to a server (systemd, SMTP e-mail, production hardening).
- Responsive layout for tablet/phone; desktop stays full-width.
- **Interface language** - a full gettext catalogue with a per-session picker;
  English ships today, and the player-facing public pages stay English on
  purpose because an open draws players from many federations.
- CI on GitHub Actions; 2,000+ tests including end-to-end runs against the real
  JaVaFo engine.

## What's next

**The 2026 Acceptance Cycle now sets the order.** FIDE TEC circulated a
draft VCL and TEC Manual on 2026-08-25; when the final versions publish,
existing endorsements are revoked and every vendor re-qualifies. The gap
list, with our own read of which items are hard failures and which are
accumulating penalties, is at the top of [`../TODO.md`](../TODO.md). The
short version: FIDE Mode and adjourned games are the two real build items,
and TRF-26 is blocked on FIDE publishing the specification.

Everything below predates that and is still wanted, just not first:


Near-term, in rough order:

1. **Admin/support role** - a federation-level support account that can see
   and assist with tournaments it doesn't own.
2. **Rating-list freshness banner** - surface the FIDE/KBSB "last synced"
   timestamps in the top bar.
3. **Concurrent-arbiter notice** - pages already live-update when a colleague
   pairs a round; add a visible "round N was just paired by X" banner instead
   of only the silent refresh.
4. **Match-format round labels** - group a match's two rounds visually
   ("Match 3, game 1/2") instead of plain round numbers.

Later / larger:

- **Team tournaments** (team Swiss, team round robin, match cards) - the
  biggest remaining item, deliberately deferred until the individual
  tournament feature set is fully solid. The C.04.6 reading is written up
  ahead of any code, and its Article 4.3.1 colour rule is the same TPN
  parity as the individual Article 5.2.5 - which the FIDE Systems of
  Pairings and Programs Commission settled on 2026-08-28, so that half is no
  longer an open question.

Explicitly out of scope (decided, not planned):

- The American/difference-scaling pairing system.

Version 1.0 will be tagged once the current feature set has survived real
tournament use.
