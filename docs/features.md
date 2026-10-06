# OpenPairings - features & roadmap

Current version: **0.74.4**. One page: everything the app does today, and where
it is going. Per-feature detail lives in the other [docs pages](README.md).

## Pairing

- **Swiss (FIDE Dutch)** on either of two engines, chosen per tournament and
  driven through TRF files built and validated by the app:
  - **[Ainalrami](https://github.com/AuroraRyunix/Ainalrami)** (default) -
    written for this project in Elixir, implementing C.04.3 as it stands
    from **1 February 2026**, in-process with no JVM. Cross-checked against
    bbpPairings 6.0.0 over 2.5 billion individual pairings with two
    disagreements, both defects in bbpPairings. See
    [`fide-endorsement.md`](fide-endorsement.md).
  - **JaVaFo 2.2** - FIDE's own reference implementation, of the **2017**
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
  - **No pairing-allocated bye for chosen players** ("Bye preferences" switch, Ainalrami
    only) - an organiser's rule, not FIDE's: a player excluded for all or
    certain rounds is treated as one who already had the bye. Warned as a
    departure from the FIDE rules, with "pair anyway" when it leaves no
    legal round, and recorded in the round's explanation, the audit trail
    and the TRF export's notes. See
    [`pairing-systems.md`](pairing-systems.md).
  - **Bye preferences** (its own switch, off by default; Ainalrami only,
    never on a FIDE-rated tournament) -
    per player, for all or certain rounds: "must get" the pairing-allocated
    bye (if a legal pairing allows; otherwise paired normally and said why -
    but a second pairing-allocated bye, which FIDE's rule C2 forbids, is
    refused when saved and when pairing),
    "rather gets it" or "rather not" (decide among the players on the bye
    score, never lifting it to a higher score). Not FIDE rules: warned on
    the player form, and a round they change is recorded in its
    explanation, under the boards, in the audit trail, on the FIDE record
    and in the TRF export's notes. See
    [`pairing-systems.md`](pairing-systems.md), "Bye preferences".
  - Robust against real-world rosters: absent and round-specific-absent
    players anywhere in the field (including mid-ranking gaps that crash a
    naive JaVaFo invocation) are handled via contiguous rank remapping.
- **Round robin (Berger tables)** - single or double cycle, match format
  (immediate colour-reversed rematches), automatic forfeit results for
  absent/forfeited players, odd-field structural byes.
- **Team round robin** - the Berger table over teams, each pairing a match of
  N boards played board against board in board order, the first-named team
  White on the odd boards. Teams page for teams, rosters, board order and
  seeding; reserves move up for an absent player; an unfilled board is a
  forfeit. Match points (2/1/0, configurable) and game points, team standings
  with the team tie-breaks (GP, DE, BH, SB, EMGSB, BB) and their working,
  individual board statistics, a team pairing sheet and team standings print,
  and the TRF16 team section. Not published to OpenResults yet. See
  [`team-tournaments.md`](team-tournaments.md).
- **Team Swiss (FIDE C.04.6, February 2026)** - team against team, paired by
  Ainalrami's team engine with the regulation's defaults (match points
  primary, game points for colours, Type A colour preferences), each pairing
  a match seated like the team round robin's. The pairing-allocated bye
  scores a drawn match; team tie-breaks apply C.07 Article 16 to byes,
  forfeited matches and withdrawn teams. A team Swiss already paired player by
  player before this carries on that way. See
  [`team-tournaments.md`](team-tournaments.md).
- **Team match actions** (both team systems) - forfeit a match to one team by
  decision, and withdraw the decision; a board added by hand joins its teams'
  match when it fits, and is marked as counting for no team when it does not.
- **Team Swiss pairing rationale** - each round stores the team engine's
  account (bye, brackets, upfloaters, [C8]-[C10], colours) and the rationale
  page shows it.
- **Team TRF import rebuilds matches** - the `013` teams and board orders,
  and each round's matches worked out from the boards where they are
  unambiguous; an unclear round is named, not guessed.
- **Initial colour** - drawn by lot at the first Swiss pairing (the FIDE
  rule, C.04.3 5.1 / C.04.6 4.1), stored and shown on the Pairings page, or
  set to White or Black by the arbiter; both engines are told it (JaVaFo as
  `XXC`).
- **Keizer system** - classic ladder values with retroactive recalculation and
  a dedicated Keizer standings table.
- **Forbidden pairings** - arbiter-managed never-pair list, plus rule-based
  club/federation exclusions (all or listed clubs/federations), enforced in
  Swiss (`XXP`) and Keizer.
- **Soft rules** - a forbidden pairing can be a wish ("only if possible")
  instead of a rule, and clubmates can be asked apart for the first N
  rounds; the Ainalrami engine weighs the wish against the pairing criteria,
  strong (before colour and float rules) or weak (a tie-break), gives way
  when nothing else is legal, and the rationale page shows the rung.
- **Blind result entry** - SWAR-style keyboard flow: focus a board's result,
  type `1`/`2`/`3`, focus advances one board with smooth scrolling.
- **Postponed games** - per tournament, off by default (Settings, Scoring:
  "Allow postponed games"; off offers no postponed option anywhere). On, a
  board can be recorded as "postponed by White" or "postponed by Black"
  (`*W`/`*B`, uitgesteld): result unknown, game still to be played, for a
  game moved by agreement or adjourned (VCL4THP Q157-169). The tournament
  goes on: until the game is played it counts as the tournament's setting
  says - one value for the player who postponed, one for the opponent, a
  draw for both by default (FIDE); anything else is a FIDE-mode departure -
  in the standings, the tie-breaks and the pairing of every later round,
  from one place (`PairingsEngine.Results`/`Standings.pairing_records/4`).
  The value is stored on the game when it is postponed, so changing the
  setting later only affects new ones. Open games are listed on the
  Pairings page with a button to their round, and the real result can be
  entered any time, with the date it was played. Pairing with blank boards
  can record them as postponed (a separate, confirmed button); a result
  that is not a draw over a postponed game, and pairing while one from an
  older round is open, both ask first. Standings, prints, the KBSB upload
  ("Voorlopige stand") and the OpenResults snapshot say "not final" while
  one is open, and the tournament stays running. The TRF26 export writes
  `?` (with `X` in `162`), and a `?` imports as a postponed game.
- **Postponed games, for the organiser** - each open game can carry the
  date its players agreed on (optional, never a deadline: nothing becomes
  overdue), with a short history of every change (old → new, when, by
  whom), set in the Pairings page's list of open games. From there, a
  printable notice per player (round, board, opponent, colour, agreed date,
  venue - also on the Print page) and an `.ics` calendar file for the agreed
  date. The standings (page and print) mark each player or team with a game
  still to be played ("1 pending", "1 board pending"); a team match with a
  postponed board reads "2.5 - 1.5, 1 board pending" on the Pairings page
  and the printed team pairings. Pairing the next round names the players
  of every open game and asks to confirm they are paired on a provisional
  score (it never blocks). The Players page carries a card of open games
  linking to their round; the Print page, the Standings page and archiving
  the tournament say how many are still unplayed first. On Settings, Export,
  the postponed-games file says which FIDE rating period each played game
  falls in and to send it before the end of that month. OpenResults gets
  the agreed date (`postponed_date`) to show "Postponed, to be played ...".
- **TRF for sending** - Settings, Export's "Send…" downloads the file for
  the rating officer and marks every result of its rounds as sent, in one
  step: a sent result changes only after a confirmation; a sent round cannot
  be sent again or unpaired, and a hand edit to who played whom in it - or
  to a player's absence in it, on the Players page - needs a warning
  ticked, so no game is sent twice. Two "Send…" clicks at once (a second
  tab, a co-arbiter) cannot both get a file: the database holds one record
  per game sent and refuses the second. A copy left behind by a hand-off,
  and an archived tournament, send nothing.
  What was sent is also kept in a record a restore or a hand-off return
  does not replace: the marks come back afterwards, and a restore that
  would take a sent game away warns first. Each game keeps an identity of
  its own through every restore, backup and hand-off, so a FIDE ID filled
  in or a name corrected later never makes a sent game look unsent (or an
  open one lose its `?`). A round restored to before it was paired and
  paired again with other games can be sent - after a warning that it
  reports the round a second time; paired into the same games, it stays
  sent. A JSON backup carries the record; a tournament imported from a
  backup, TRF or `.swar` file of an event that may already have been
  reported sends nothing until an arbiter confirms, on Settings, Export,
  that this copy is the one that reports.
  "Download a copy" and "All rounds" are copies: the file name ends
  `COPY-NOT-FOR-RATING` (`KOPIE-NIET-VOOR-RATING` in Dutch) and the file
  says so in a `###` comment line. A game still open when its round is sent
  goes out as `?` and stays `?` in every later report; once played it goes
  in the **postponed-games file** in the Postponed games part of Settings,
  Export instead - reported to FIDE as a **separate tournament** with its
  own name (by default the event's name + "postponed games", "uitgestelde
  partijen" in Dutch, editable) and its own FIDE tournament ID, dated from
  the first to the last day its games were played, one file per rating
  period (month) - extra rounds, packed so nobody plays twice in a round,
  only the players of those games; sending that file marks it sent too.
  The date a late game was played is set when it is first played and kept
  through corrections of its result; changing it is a separate, audited
  step. The warnings and the VCL questions they answer are listed in
  `PairingsEngine.PostponedGames`.

- **Next-round preview** - while the last games of a Swiss round are still
  being played (six or fewer open), "Preview next round" on the Pairings
  page pairs the next round for every combination of their results (1-0,
  ½-½, 0-1: up to 729 outcomes) through exactly the code the real pairing
  runs - same options, same board numbering - and saves nothing. Each board
  is then **fixed** (same players, colours and board in every outcome: the
  name cards can go out), **fixed but may shift** (the board range is
  shown), **fixed with colours open**, or **open** (who a player could meet,
  and which open games decide it); the bye is fixed or open. It works in the
  background with a progress bar and an estimate of the time left, updates
  itself when a result is entered, and prints the fixed boards with a list
  by name for the name cards. Above six open games it says how many are
  still open. Individual Swiss on the built-in engine (Ainalrami) only; the
  engine's field is built once and re-ranked per outcome, so six open games
  on 600 players take seconds (see `PairingsEngine.NextRoundPreview`).

## Scoring, standings & tiebreaks

- **FIDE C.07 tiebreaks** (1 Mar 2026 regulations): BH, BHC1, BHC2, MBH, SB,
  DE, WIN/WON, BPG, PS, KS, ARO, AROC1 - including Article 16 unplayed-game
  handling. Per-tournament selection and ordering, FIDE-default preset.
- **Configurable scoring** - per-tournament win/draw/loss points, bye value,
  presence points, and plain-absence value (covers SWAR's "3-2-1" club
  scoring configurations exactly).
- **Late entrants** - adding a player after rounds were paired offers the
  next round as the one they join in ("Joins in round" on the Players page,
  which says what the rounds before it count as). When absences pay points, those rounds count
  as absences - the same value, within the same two limits, using up the
  same allowance, as SWAR does; a setting beside the absence points turns
  it off (off for tournaments already finished or archived when it
  arrived). A FIDE event without absence points scores them as nothing. A
  player whose join round was never set (added before it existed, or an
  accepted registration) has it worked out from their first round with
  anything in it, or the next round to be paired - never saved.
- **Extra points** - Elo-band bonus points with an opt-in toggle for counting
  them in the ranking.
- **Rounds-present column ("Rds")** - an optional standings column counting the
  rounds each player turned up for: games played (any result), a bye given
  because the field was odd, and a win by forfeit. Arranged byes, absences and
  forfeit losses do not count. For club championships that award a prize for
  attending every round. An ordinary column tick ("Rds", in the Players page's
  Display panel, beside Cl/Nr/Rnk/Ga), so it shows on the players grid and the
  standings table and prints with them. Publishing it is opt-in and separate:
  tick "Rounds-present column" under Settings - Results site, the only public
  display tick that starts off. Readers there can then sort by it.
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
- **Categories** - per-tournament categories, each an optional rule combining
  any of five conditions (rating from/below, age from/below, women-only) -
  nested, banded or combined categories all expressible, going beyond SWAR's
  single non-overlapping threshold per category. Age is FIDE's 1-January
  convention, with a live birth-year hint in the editor. Auto-assign fills
  a category from its rule; per-category standings and, for Swiss, native
  per-category pairing follow. An optional prize count per category
  highlights the in-category places that are actually prizes, on the
  standings page and its per-category filter - informational only for now;
  actually allocating a prize (and the "one prize per player" rule a
  player in several categories needs) is a possible follow-up, not built.

## Import & export

- **SWAR import** - full `.swar` files (players, rounds, results, byes,
  scoring configuration, absences), with FIDE-id resolution during import.
- **TRF26 and TRF16** - import (a complete tournament from a `.trf` file, points
  cross-checked and every round of a Swiss checked against the absolute
  pairing rules) and export (full or selected rounds, FIDE-submission grade).
- **JSON backup** - full single-tournament or all-tournaments export and
  re-import.
- **CSV results import** - bulk result entry per round, all-or-nothing.
- **PGN export** - per-round metadata-only PGN.

## Printing

Player list, player cards, pairing lists (optional absentees section), 
standings, Swiss cross table, round-robin players×players cross table,
result cards (8 per A4, alignment test print, stack-cut imposition), and
folded place cards (chevalets) with field toggles, and the next-round
preview's fixed boards with a name-card list - all per-round where it
makes sense, all reachable from the page they belong to. Tournaments can
carry a logo (stored in the database, shown on printed documents).

**Accreditation badges** (`/badges`, signed in) - A6 badges, front and back,
two to an A4 sheet: name, photo, title, federation, FIDE ID, a coloured role
banner, up to 12 numbered rooms, logos and a QR code. An event linked to a
tournament imports its players and officials, and re-imports update in place;
press, VIP and staff badges are added by hand. See [`badges.md`](badges.md).

## Norms & FIDE reports

- **Official FIDE Excel forms** filled in place: IT3 (tournament report),
  FA1/IA1 (arbiter norms), IT4 (player title norms).
- **Festival combining** - multi-tournament (categories-of-one-event) combined
  reports with duplicate-player detection.
- **Public tools page** (`/tools/norms`) - no login: upload `.swar`/`.trf`
  files, get combined norm reports; nothing is stored server-side.
- **FIDE handling, without a switch** - the settings a new tournament gets are
  the ones the FIDE pairing rules describe, so there is nothing to turn on.
  Three settings can take a tournament out of that, and all three change who
  plays whom: a Keizer ladder, pairing each category as its own separate
  tournament, and the immediate two-game Swiss rematch. The pages that host
  them say so and link to the setting; nothing is refused, and the round it
  first happened in is recorded for the FIDE report. Non-standard scoring,
  half-point byes, extra points, tie-break choice and a hand-set standings
  order are all things FIDE's own rules provide for, and none of them raises
  anything - see `PairingsEngine.Compliance` for the reasoning, setting by
  setting.

## Accounts, sharing & transparency

- **Accounts** with magic-link, password, or 02cloud SSO (Keycloak) login;
  every tournament is private to its owner.
- **Collaborators** - invite by e-mail with explicit accept/decline; owners
  keep delete and sharing rights.
- **Publishing to OpenResults** - a tournament is pushed to the public
  results site under an unguessable per-tournament link: pairings, standings
  and a card per player, no login. A QR on the Live page points spectators
  straight at it. Per-tournament switches decide which details a published
  page may show, from the player cards and byes pages down to individual
  columns and tie-breaks, and a hidden one is withheld when the document is
  built rather than sent and hidden at the other end.

  Settings -> OpenResults holds three controls built like the per-round one
  below, so the three read as one family:

  - **On the results site: Off · Link only · Listed** - whether the
    tournament is published at all, and whether it is also on the results
    site's front page. Going down to Off asks first; a copy already on the
    site stays until it is removed under "The address".
  - **Automatically: By hand · Pairings once paired · + results live ·
    + standings when the round is finished** - how far up the per-round
    ladder the app moves each round by itself. The pairings step takes an
    optional "after N minutes"; everything saves as it is chosen. Standings
    go public once the round and every round before it are finished.
  - **Before round 1, spectators see the starting ranking** - off by
    default; once a round is public the players travel with it anyway.

  What reaches the site is decided per round by one **Spectators see:**
  control on the Pairings page (and in the round's right-click menu), with
  four cumulative levels: **Nothing**, **Pairings** (who plays whom),
  **+ Results** (results as they come in) and **+ Standings** (the standings
  after the round too). The automation only ever moves a round up; the
  arbiter can always take a round down here, and it stays where they put it
  (the automation stops at that level for that round). It is the only place
  a round's level is chosen by hand: the Standings page says what spectators
  see of the round its standings are after, or before round 1 what the
  starting-ranking setting is, and links to where each is changed. By hand,
  a newly published round starts at Pairings: the boards travel without
  results, and nothing computed from a result goes with them, so live
  results are a deliberate choice rather than the default. Choosing a level
  writes exactly that level in one step; going down asks first and names
  what disappears, including later rounds whose sheets would give it away.
  Rounds left with a combination the old separate switches allowed keep it
  until a level is chosen, with a short note saying so.

  Upgrading to the automation ladder (2026-09-28) changed nothing anybody
  could see: "Manually" became By hand, "After a delay" the pairings step
  with its delay, "Immediately" the whole ladder (its rounds, results and
  finished standings written down as public, and the lock on the per-round
  control gone), and "On the round's own date" By hand, rounds already paired
  keeping their date. The retired "Standings" and "Round pairings" page
  switches took their step out of the automation where they were off, and
  keep that page hidden until the arbiter shows it again from a note on the
  settings page.

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
- **Account page** (`/users/settings`, see [account.md](account.md)) -
  profile with a display name shown in audit logs, history and sharing
  lists; sign-in and security with the list of signed-in browsers and
  "sign out everywhere else"; language, theme and accent stored on the
  account so they follow you; defaults for new tournaments; a zip of all
  your data; and deleting the account. Changing the address or password,
  ending sessions, downloading and deleting ask for a recent sign-in.
- **Federation features** (Account page, also at `/users/features`) - the Belgium-specific parts of
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
- **Desktop builds** for Windows, macOS and Linux, each with a double-click
  launcher (see [binaries.md](binaries.md)). On Windows the recommended
  download is an MSI with a proper wizard - welcome, licence, just-me or
  everyone - with a one-click `Setup.exe` beside it. Just-me is the default
  and needs no administrator, and uninstalling leaves your tournaments where
  they are.
- **Update notice** - a desktop copy checks GitHub every few hours and says
  when a newer release is out. The arbiter still always picks the moment -
  an update can change the pairing engine's version under a running event -
  but a per-user Windows install can now do the applying itself: "Install
  and restart", confirmed, handled by the native launcher rather than this
  application (see [binaries.md](binaries.md)'s "Updates" section). Every
  other install kind still only ever gets a link to the release page. It
  can be switched off, and the hosted site never checks.
- **Interface language** - a full gettext catalogue with a per-session picker;
  English and Dutch ship today, and the player-facing public pages stay
  English on purpose because an open draws players from many federations.
- CI on GitHub Actions; 3,500+ tests including end-to-end runs against the real
  JaVaFo engine.

## What's next

**The 2026 Acceptance Cycle now sets the order.** FIDE TEC circulated a
draft VCL and TEC Manual on 2026-08-25; when the final versions publish,
existing endorsements are revoked and every vendor re-qualifies. The gap
list, with our own read of which items are hard failures and which are
accumulating penalties, is at the top of [`../TODO.md`](../TODO.md). The
short version: FIDE Mode was one of the two real build items; adjourned
games, the other, are built as postponed games (above) and wait for the
maintainer to verify Q157-169.
TRF-26 was on that list and came off it on 2026-09-07: we read and write it
now. What is still open there is FIDE's side - whether a specification is
published as a specification, rather than as clarifications of one - and
that is a question about their document, not about our support for it.

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

- **Team pages on OpenResults** - additive snapshot fields for teams,
  matches and team standings, so a team event can be published.

Explicitly out of scope (decided, not planned):

- The American/difference-scaling pairing system.

Version 1.0 will be tagged once the current feature set has survived real
tournament use.
