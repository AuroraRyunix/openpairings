# Bulk rating refresh

SWAR parity: "Refresh all ratings" — a single action that re-looks-up every
registered player against the locally-synced FIDE and KBSB rating lists
(see `docs/kbsb-sync.md`) and proposes changes, with a dry-run diff shown
before anything is written.

## Where it lives

- `PairingsEngine.RatingRefresh` (`lib/pairings_engine/rating_refresh.ex`) —
  the pure-ish context module. `dry_run/1` reads only; `apply/2` writes.
- `PairingsEngine.Tournaments.bulk_update_players/2`
  (`lib/pairings_engine/tournaments.ex`) — applies a list of
  `{%Player{}, attrs}` updates in one `Repo.transaction/1`, firing exactly
  one `tournament_changed` broadcast on success (instead of one per
  player, which the per-player `update_player/2` would do if called in a
  loop).
- UI: "Refresh ratings" button and modal on the Players page
  (`lib/pairings_engine_web/live/players_live.ex`), next to the existing
  add-player affordances.

## Matching rules

For each player in the tournament:

- **`player.fide_id` → `fide_players`** (exact primary-key lookup, no fuzzy
  search): proposes a new `fide_rating` when the FIDE list's
  `standard_rating` differs, and a new `title` **only when the FIDE record
  actually carries one** — a blank FIDE title never proposes clearing a
  title already set locally (the FIDE list simply might not have looked the
  player up under a title-bearing federation, and that's not grounds to
  erase Direct-elect/national titles the tournament director entered by
  hand).
- **`player.national_id` → `kbsb_players`** (exact primary-key lookup):
  proposes a new `national_rating` when it differs.
- A player with neither id set, or whose id has no match in either table,
  contributes **zero** proposals and counts toward the summary's
  `unmatched` figure (distinct from "matched but nothing changed", which
  counts toward neither `changed` nor `unmatched`).
- No-change fields (the looked-up value equals what's already stored) are
  never proposed — the diff table only ever shows things that would
  actually change.

This deliberately mirrors the per-player "Refresh" / "KBSB" buttons already
on the player registration ("edit player") modal — same source tables, same
id-based matching — just run across every player at once and staged as a
dry-run instead of applied immediately.

## Dry-run / apply

`RatingRefresh.dry_run(tournament)` returns:

```elixir
%{
  proposals: [%RatingRefresh{player: %Player{}, field: :fide_rating, old: 1900, new: 2100}, ...],
  checked: 12,    # players in the tournament
  changed: 5,     # players with >= 1 proposal
  unmatched: 3    # players with no fide_id/national_id match at all
}
```

Nothing is written by `dry_run/1`. The Players page shows this as a diff
table (player / field / old → new) plus the summary line, matching the
`.pe-table` conventions used elsewhere on that page (e.g. the Players Card
modal). An empty `proposals` list renders "Everything up to date." instead
of an empty table.

`RatingRefresh.apply(tournament, proposals)` groups proposals by player (a
player can have both a `fide_rating` and a `title` change, or all three
fields, in one pass) and calls `Tournaments.bulk_update_players/2` with one
`{player, attrs}` pair per affected player — so refreshing 50 players who
all changed fires **one** broadcast, not 50, keeping other open tabs
(Standings, Pairings, …) from doing 50 redundant reloads.

## Not implemented (out of scope for this wave)

- No per-field opt-out in the diff table (it's all-or-nothing — Apply
  writes every proposed change, Cancel writes none). A future pass could
  add row-level checkboxes if that turns out to matter in practice.
- No automatic/scheduled refresh — this is a manual action the tournament
  director triggers, same as the existing per-player Refresh buttons.
- Doesn't touch `federation`, `birth_year`, `club`, or anything else the
  per-player Refresh buttons fill in — only `fide_rating`, `title`, and
  `national_rating`, per the SWAR feature this mirrors ("refresh ratings",
  not "re-sync everything").
