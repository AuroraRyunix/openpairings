# Printing

OpenPairings renders print documents as plain server-rendered HTML pages
(`PairingsEngineWeb.PrintController`) that call `window.print()` on load.
They are not LiveViews, so they open cleanly in a new browser tab (and
survive that tab being closed without disturbing the app's LiveView
sockets).

## Documents

| Document | Route | Round-scoped? | Notes |
|---|---|---|---|
| Player list | `GET /t/:id/print/players` | No | Full roster: title, name, FIDE/national rating, federation, club. |
| Player cards | `GET /t/:id/print/cards` | No | One card per player with **every** round of the tournament listed (rows 1..`rounds_count`), never limited to a single round — cards are meant to be filled in over the board, round by round, not reprinted per round. |
| Pairing list | `GET /t/:id/print/pairings?round=n` | Yes | Board-by-board pairings for round `n`. `round` defaults to `1` if omitted. 404s with "Round n has not been paired yet" if round `n` has no pairings. |
| Standings | `GET /t/:id/print/standings?round=n` | Yes (optional) | See "Round-scoped standings" below. Omit `round` for the current/overall standings. 404s the same way as the pairing list if round `n` hasn't been paired. |
| Result cards | `GET /t/:id/print/results?round=n` | Yes | One card per board of round `n` (byes skipped). `round` defaults to the **latest paired round** if omitted (unlike the pairing list, which defaults to round 1). 404s the same way as the pairing list if round `n` hasn't been paired. |
| Cross table | `GET /t/:id/print/crosstable` | No (always current) | Full Swiss cross table: one row per player in current standings order, one column per played round. |

## The `round` query parameter

`pairing_list`, `standings` and `result_cards` all accept `?round=n`:

- **Pairing list**: shows exactly round `n`'s board pairings. Straightforward
  — a round either has pairings stored for it or it doesn't. Defaults to
  round `1` if omitted.
- **Standings**: shows standings as they stood right after round `n` — i.e.
  computed using only rounds `1..n` (see below for how). Omitting the param
  (or passing the latest paired round number) shows the same figures as
  today's "current standings."
- **Result cards**: shows exactly round `n`'s boards, one card each. Omitting
  the param uses the **latest paired round** (`PairingsEngine.Standings.rounds_paired/1`),
  not round 1 — result cards are printed once a round is set up, so "give me
  the round that's currently being played" is the useful default here.

All three actions respond `404` with a plain-text body if the requested round
hasn't been paired yet, rather than silently falling back to a different
round. The cross table has no `round` param at all — it always reflects the
current, full-tournament picture (like the overall standings).

## Fixed-table annotation on the pairing list

A player can be given a `fixed_board` number (Players page, "Fixed table"
field — SWAR's "special table"/HandyTable concept). This is **display/print
only**: it never changes real board numbering produced by the pairing
engine. `PrintController.pairing_list/2` just annotates the affected row —
e.g. `5 (table 5)` — when either player on that board has a `fixed_board`
set; if White and Black each have a different fixed board (rare), both
numbers are shown, e.g. `(table 5, 7)`. Boards with no fixed-board player
are unannotated, exactly as before.

## Result cards

`GET /t/:id/print/results?round=n` prints one card per board of round `n`
(pairings with no black player — byes — are skipped, since there's nothing
to record). Each card has:

- Tournament name, round number, board number.
- White and Black: name, rating, pairing number.
- A large "1 – 0 / ½ – ½ / 0 – 1" row, spaced out for an arbiter or the
  players to circle by hand.
- A smaller "other: ............" line underneath for forfeits and other
  results that don't fit the three standard options.
- Signature lines for White and Black.

Layout is A4 portrait, three cards stacked per page with a dashed border
(cut line) around each card and a forced page break after every third card
(`@page { size: A4 portrait }` plus `nth-child(3n)` — see `@result_cards_css`
in the controller). This is a page-specific `<style>` block layered on top of
the shared `@print_css`, not a change to the shared styles.

## Cross table

`GET /t/:id/print/crosstable` prints the standard Swiss cross table: one row
per player, ordered by current standings rank (`PairingsEngine.Standings.standings/1`,
same entries and the same `points`/tiebreak columns the standings print page
uses), then one column per round that has been paired.

Each round cell uses a compact notation — `<opponent's pairing number><colour><result>`:

- `"12w1"` — played as White against pairing number 12, won.
- `"5b½"` — played as Black against pairing number 5, drew.
- `"-w+"` — forfeit win as White (no real game was played, so no opponent
  number is shown — just the colour and the forfeit outcome).
- `"-b-"` — forfeit loss as Black.
- `"bye"` — any kind of bye (pairing-allocated or requested).
- blank — the round hasn't been played by this player yet (not in their game
  history at all — distinct from a `0` result).

The opponent identifier is the opponent's **pairing number** (their fixed
starting number, not their current/round-varying standings rank), matching
how FIDE-style cross tables normally cross-reference opponents.

Landscape print CSS (`@page { size: A4 landscape }`) is applied the same way
result cards apply portrait — a page-specific `<style>` block, since the
shared `@print_css` has no orientation hint of its own. On screen the table
just scrolls horizontally if it's wide (`overflow-x: auto`).

## Round-scoped standings: how it's computed

`PairingsEngine.Standings.standings/2` now takes an options keyword list,
with a single supported key: `through_round: n`. When set, the two DB
queries that feed the tiebreak engine — the tournament's `Round`s (with
their `Pairing`s) and its `byes` — are filtered to `number <= n` / `round <=
n` respectively, before any points or tiebreaks are computed. Everything
downstream (points, Buchholz, Sonneborn-Berger, progressive score, etc.)
runs completely unmodified against that trimmed game set.

This is **not** a special-cased or approximated code path: it is the exact
same computation the app already performs for "current standings" whenever
a tournament is mid-way through — `standings/1` has only ever seen the
rounds that exist in the database, never rounds that haven't been paired
yet. Passing `through_round: n` for a past round `n` reproduces, honestly,
whatever the standings page would have shown right after round `n` was
completed. There is no limitation here worth flagging: FIDE tiebreaks that
look at "remaining rounds" (e.g. Article 16.4's dummy-opponent score for a
player's own unplayed round) use the tournament's configured
`rounds_count`, which is a property of the tournament as a whole and is
correct regardless of which round the standings are being viewed as of.

`PrintController.standings/2` calls `Standings.standings(tournament,
through_round: n)` when `?round=n` is present, and `Standings.standings(tournament)`
(all rounds) otherwise — **except** for a Keizer tournament
(`pairing_system == "keizer"`), where it instead calls
`PairingsEngine.Keizer.standings/2` (same `through_round: n` option) and
renders the Keizer ladder table (rank, name, rating, value, Keizer points,
game score) in place of the FIDE points/tiebreak table — see
`docs/pairing-systems.md`. Non-Keizer output is unaffected either way.

`Standings.grid_standings/1` (used by the Players grid, not by printing) is
unaffected and still always reflects the tournament's full history.

## Standings print: categories

If the tournament has no `categories` defined, the standings document is
unchanged (byte-identical to before this feature existed): no Category
column, no extra tables.

If `tournament.categories` is non-empty, `PrintController.standings/2`:

- Adds a **Category** column to the main table (a player with no category
  shows "—").
- Appends one small standings table per category, in the order categories
  are defined on the tournament, each headed `Category: <name>` and filtered
  to players whose `category` matches. **Ordering is not recomputed** — each
  sub-table keeps the same rows in the same relative order as the main
  table, including each player's overall rank number (categories are not
  separately re-ranked). Players with a blank/unset category, or a category
  string that doesn't match any of the tournament's defined categories,
  appear in the main table only.

## Where the print buttons live

| Page | Buttons | Behaviour |
|---|---|---|
| Pairings (`/t/:id/pairings`) | "Print pairings", "Print standings", "Print result cards" | All three open in a new tab, scoped to whichever round is currently selected in the round picker (`?round=<selected round>`). Only shown once that round has been paired. |
| Standings (`/t/:id/standings`) | "Print" | Opens the overall standings document (no `round` param) in a new tab — this page has no round picker, so it always reflects the current/latest state. |
| Players (`/t/:id/players`) | "Print player list", "Print player cards" | Roster-wide, no round scoping — open `/print/players` and `/print/cards` in a new tab. |
| Print hub (`/t/:id/print`) | "Print…" per document | Links pairings and result cards to the latest paired round, standings to the overall figures, and the cross table to the always-current picture (available even with zero rounds paired — it just has no round columns yet). |

All of these are real `<a target="_blank">` links (not JS-driven), so
middle-click / "open in new tab" work as expected.
