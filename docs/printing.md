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

## The `round` query parameter

`pairing_list` and `standings` both accept `?round=n`:

- **Pairing list**: shows exactly round `n`'s board pairings. Straightforward
  — a round either has pairings stored for it or it doesn't.
- **Standings**: shows standings as they stood right after round `n` — i.e.
  computed using only rounds `1..n` (see below for how). Omitting the param
  (or passing the latest paired round number) shows the same figures as
  today's "current standings."

Both actions respond `404` with a plain-text body if the requested round
hasn't been paired yet, rather than silently falling back to a different
round.

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
(all rounds) otherwise.

`Standings.grid_standings/1` (used by the Players grid, not by printing) is
unaffected and still always reflects the tournament's full history.

## Where the print buttons live

| Page | Buttons | Behaviour |
|---|---|---|
| Pairings (`/t/:id/pairings`) | "Print pairings", "Print standings" | Both open in a new tab, scoped to whichever round is currently selected in the round picker (`?round=<selected round>`). Only shown once that round has been paired. |
| Standings (`/t/:id/standings`) | "Print" | Opens the overall standings document (no `round` param) in a new tab — this page has no round picker, so it always reflects the current/latest state. |
| Players (`/t/:id/players`) | "Print player list", "Print player cards" | Roster-wide, no round scoping — open `/print/players` and `/print/cards` in a new tab. |
| Print hub (`/t/:id/print`) | "Print…" per document | Unchanged: still links pairings to the latest paired round and standings to the overall figures. |

All of these are real `<a target="_blank">` links (not JS-driven), so
middle-click / "open in new tab" work as expected.
