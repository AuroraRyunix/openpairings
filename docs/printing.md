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
| Result cards | `GET /t/:id/print/results?round=n` | Yes | One card per board of round `n` (byes skipped). `round` defaults to the **latest paired round** if omitted (unlike the pairing list, which defaults to round 1). 404s the same way as the pairing list if round `n` hasn't been paired. Also accepts `?limit=L` (test print) and `?order=stack` (stack-cut imposition) — see "Result cards" below. |
| Cross table | `GET /t/:id/print/crosstable` | No (always current) | Swiss/Keizer: full round-by-round cross table, one row per player in current standings order, one column per played round. Round robin: the classic players×players grid instead — see "Cross table" below. |

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
- Compact inline signature boxes for White and Black, on the same row as the
  player names.

Layout is A4 portrait, eight compact cards (~32mm each) stacked per page with
a dashed border (cut line) around each card and a forced page break after
every eighth card (`@page { size: A4 portrait }` plus `nth-child(8n)` — see
`@result_cards_css` in the controller). This is a page-specific `<style>`
block layered on top of the shared `@print_css`, not a change to the shared
styles.

### `?limit=L` — test print

`GET /t/:id/print/results?round=n&limit=L` renders only the first `L` cards
(in whatever order the request would otherwise use — board order by
default, or the stack-cut order below if `?order=stack` is also given).
This lets an arbiter print a single test page to check printer alignment
before committing to a full stack of result-card pages. `L` must be a
positive integer; anything else (missing, blank, zero, negative,
non-numeric) is treated as "no limit" and the full print is rendered — a
bad `limit` value never errors or 404s. The Pairings page's "Test print (3)"
button links here with `limit=3`.

### `?order=stack` — stack-cut imposition

`GET /t/:id/print/results?round=n&order=stack` reorders the cards for
**stack-cut printing**: print every page, stack the whole printout, then
make 8 straight guillotine cuts (one between each pair of card rows) to
turn the stack into 8 piles — one pile per card *slot* (all the
top-of-page cards form pile 1, all the second-from-top cards form pile 2,
and so on). Collate the piles top-to-bottom, pile 1 first.

With the **default** ordering (no `?order`), pile 1 would end up holding
boards 1, 9, 17, ... (every 8th board) — not useful. With `?order=stack`,
`PrintController.stack_cut_cards/3` instead places board index `s*P + p`
(0-based into the board-ordered list) into slot `s` (0-based, top to
bottom on the page) of page `p` (0-based), where `P` is the total page
count. Collating the piles afterwards then recovers plain board order 1,
2, 3, .... Slots that run out of real cards — always in the *last* pile(s),
since earlier piles fill first — render as blank, borderless placeholder
cards (`.rc-blank`) purely to keep every page's card count fixed at 8 (and
so the cut geometry intact); they carry no content and aren't meant to be
printed on or given to anyone.

Worked example — 20 cards, 8 per page → `P = ceil(20/8) = 3` pages:

```
slot 0: boards  1, 2, 3
slot 1: boards  4, 5, 6
slot 2: boards  7, 8, 9
slot 3: boards 10,11,12
slot 4: boards 13,14,15
slot 5: boards 16,17,18
slot 6: boards 19,20,blank
slot 7: blank,blank,blank
```

(1-based board numbers shown for readability; the code itself works in
0-based indices — see the comment above `stack_cut_cards/3`.) Every pile is
full except the last two, exactly as required for the cut to make sense.

`?order=stack` combines naturally with `?limit`: `limit` is applied first
(trimming the board-ordered list), and the stack-cut imposition then runs
over whatever's left. The Pairings page's "Print result cards (stack-cut
order)" button links here with `order=stack`.

## Cross table

`GET /t/:id/print/crosstable` renders one of two documents, chosen by
`tournament.pairing_system` (`PrintController.crosstable/2` is the
dispatcher; `swiss_crosstable/2` and `round_robin_crosstable/2` are the two
renderers):

### Swiss and Keizer: the round-by-round cross table

One row per player, ordered by current standings rank
(`PairingsEngine.Standings.standings/1`, same entries and the same
`points`/tiebreak columns the standings print page uses — Keizer tournaments
now carry a `pairing_number` too, frozen at their first pairing exactly the
way Swiss does, see `docs/pairing-systems.md`), then one column per round
that has been paired.

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

### Round robin: the classic players×players grid

For a tournament with `pairing_system == "round_robin"`, the cross table is
instead the traditional round-robin grid: both rows and columns are the
tournament's players, in the same order (ascending by their frozen
`pairing_number` — see `docs/pairing-systems.md` for how round robin freezes
that number at its first pairing), and column headers show that same
pairing number.

Cell (row player A, column player B) shows A's result **against B**,
computed from A's own game record (`PairingsEngine.Standings` entry) for
that opponent:

- `"1"` / `"½"` / `"0"` — a played win/draw/loss.
- `"+"` / `"-"` — a forfeit win/loss (no game played).
- blank — no result recorded yet for that pairing.
- For a **double** round robin (`tournament.rr_cycles == 2`), both cycles'
  results are shown space-separated, first cycle first (e.g. `"1 ½"`) —
  this falls out of sorting A's games against B by round number ascending,
  since cycle 1's rounds are always numbered lower than cycle 2's.

The diagonal (a player against themself) is hatched out via a CSS
`repeating-linear-gradient` (`.rr-diag`) rather than left blank, so it reads
unambiguously as "not a cell" on a printed page.

Only players who actually have a `pairing_number` appear as a row/column —
round robin freezes that set once, at the first pairing, and never grows it
(see `docs/pairing-systems.md`), so a player who joined after the freeze has
no schedule to show here. An odd player count's structural bye (against the
phantom player) likewise never appears as a column — there's no real
opponent to cross-reference — but its zero points are still folded into
that row's **Pts** total, since that total comes from
`PairingsEngine.Standings`, which already includes the bye in the player's
overall score.

The two right-hand columns are **Pts** (game points, same figure the Swiss
cross table's Pts column shows) and **Rank** (current standings rank).

### Shared print layout

Landscape print CSS (`@page { size: A4 landscape }`) is applied the same way
result cards apply portrait — a page-specific `<style>` block, since the
shared `@print_css` has no orientation hint of its own. On screen the table
just scrolls horizontally if it's wide (`overflow-x: auto`). Both variants
reuse this same landscape layout.

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
| Pairings (`/t/:id/pairings`) | "Print pairings", "Print standings", "Print result cards", "Test print (3)", "Print result cards (stack-cut order)" | All open in a new tab, scoped to whichever round is currently selected in the round picker (`?round=<selected round>`). Only shown once that round has been paired. The last two are the result cards document with `limit=3` and `order=stack` respectively — see "Result cards" below. |
| Standings (`/t/:id/standings`) | "Print" | Opens the overall standings document (no `round` param) in a new tab — this page has no round picker, so it always reflects the current/latest state. |
| Players (`/t/:id/players`) | "Print player list", "Print player cards" | Roster-wide, no round scoping — open `/print/players` and `/print/cards` in a new tab. |
| Print hub (`/t/:id/print`) | "Print…" per document | Links pairings and result cards to the latest paired round, standings to the overall figures, and the cross table to the always-current picture (available even with zero rounds paired — it just has no round columns yet). |

All of these are real `<a target="_blank">` links (not JS-driven), so
middle-click / "open in new tab" work as expected.
