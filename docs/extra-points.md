# Extra points (XtPts)

SWAR parity #12: organizers can grant administrative bonus points — SWAR
calls them "XtPts" — on top of a player's game points. The classic use case
is a handicap event, where lower-rated players get a head start.

`players.extra_points` already existed before this feature (populated by
the SWAR importer, editable per player on the Players page) but standings
did **not** count it — an explicit earlier product decision. This feature
adds a per-tournament opt-in toggle plus an Elo-band auto-assign tool, and
does not change that default.

## Opt-in, off by default — and pairing is never affected

- `tournament.count_extra_points` (boolean, default `false`) is the only
  thing that changes standings ranking. Leaving it off means `extra_points`
  can be set on players (by hand, by import, or via the band tool below)
  without any visible effect on standings or ranking.
- **Pairing never counts extra points, regardless of the toggle.** JaVaFo's
  input and the TRF export both feed the pairing engine game points only
  (`PairingsEngine.Pairing` reads results, not `PairingsEngine.Standings`
  output) — this feature only touches `PairingsEngine.Standings` and the two
  LiveViews below. Verified while implementing this: `Pairing`/`Keizer`
  never call `Standings`, so there was nothing to change there.

## Where it lives

- `PairingsEngine.Tournaments.Tournament` (`lib/pairings_engine/tournaments/tournament.ex`) —
  the `count_extra_points` / `extra_points_bands` columns, plus
  `parse_extra_points_bands/1` and `band_extra_points/2` (pure — no DB
  access), and the changeset normalization that keeps a stored
  `extra_points_bands` string always parseable.
- `PairingsEngine.Tournaments.apply_extra_points_bands/1`
  (`lib/pairings_engine/tournaments.ex`) — the write path. Computes every
  player's band-matched bonus and applies it via `bulk_update_players/2`
  (one transaction, one `tournament_changed` broadcast — same pattern as
  `PairingsEngine.RatingRefresh.apply/2`, see `docs/rating-refresh.md`).
- `PairingsEngine.Standings.standings/2` (`lib/pairings_engine/standings.ex`) —
  every entry always carries `points`, `extra_points` and `total` (`points +
  extra_points`); ranking sorts by `total` only when
  `tournament.count_extra_points` is true, by plain `points` otherwise. FIDE
  tiebreaks (Buchholz, Sonneborn-Berger, ...) always use opponents' game
  `points`, never `total`, regardless of the toggle.
- UI: a "Extra points" card on Settings
  (`lib/pairings_engine_web/live/settings_live.ex`) with the toggle, the
  bands text field, and an "Apply bands to players" button. The Standings
  page (`lib/pairings_engine_web/live/standings_live.ex`) shows "XtPts" and
  "Total" columns only while the toggle is on.

## Elo-band auto-assign

`extra_points_bands` is a comma-separated list of `"threshold:bonus"` pairs,
e.g. `"1400:1, 1600:0.5"`. Semantics (`Tournament.band_extra_points/2`):

- A **rated** player (rating > 0) matches every band whose threshold is
  strictly greater than their rating ("rating below `threshold`"). Among the
  matching bands, the **lowest-threshold** one wins — bands aren't additive.
  With `"1400:1, 1600:0.5"`: a 1350-rated player is below both thresholds
  and gets the lower one's bonus, `1.0`; a 1550-rated player is below only
  1600 and gets `0.5`; a 1700-rated player matches nothing and gets `0.0`.
- An **unrated** player (rating `0` — no FIDE or national rating set) never
  satisfies a `rating < threshold` comparison, so they only get a bonus when
  `extra_points_bands` has an explicit `0:bonus` entry — this is a deliberate
  opt-in, not an accidental side effect of "0 is below everything".

The stored string is re-normalized on every save: trimmed, sorted ascending
by threshold, integer bonuses without a decimal point (`1400:1`, not
`1400:1.0`). Malformed input (wrong shape, negative numbers, ...) is
rejected with a changeset error rather than silently dropped.

"Apply bands to players" (`Tournaments.apply_extra_points_bands/1`) computes
each player's `band_extra_points/2` result and **overwrites**
`extra_points` for every player — including setting it back to `0.0` for
anyone who matches no band. Re-running after a rating change (or an edit to
the bands) always reflects the current rule instead of layering on top of a
stale earlier run. It's a manual button, never triggered automatically by
saving the bands themselves or by a rating change — the arbiter always
decides when the roster's extra points should reflect the current bands.
Returns a summary ("Set extra points for N of M players") where N counts
players who matched at least one band (bonus > 0).

## Not implemented (out of scope for this wave)

- No per-round or per-category bands — one flat rule for the whole
  tournament (categories exist on `Tournament.categories` but aren't
  consulted here).
- No preview/dry-run before "Apply bands to players" (unlike
  `docs/rating-refresh.md`'s two-step flow) — it's a single confirm-free
  action, consistent with how Settings' other bulk actions (exclusion
  rules, categories) persist immediately.
- Printed standings (`print_controller.ex`) are not covered by this change —
  they don't yet show XtPts/Total columns even when the toggle is on.
