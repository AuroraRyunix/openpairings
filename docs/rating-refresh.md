# Bulk rating refresh

SWAR parity: "Refresh all ratings" — a single action that re-looks-up every
registered player against the locally-synced FIDE and KBSB rating lists
(see `docs/kbsb-sync.md`) and proposes changes, with a dry-run diff shown
before anything is written.

How the local FIDE copy itself is refreshed — and the two failure modes that
are easy to misread — is at the foot of this file, under
"[The monthly FIDE sync](#the-monthly-fide-sync-pairingsenginefidesync)".

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
- Doesn't touch `federation`, `birth_year`, or anything else the per-player
  Refresh buttons fill in — only `fide_rating`, `title`, and
  `national_rating`, per the SWAR feature this mirrors ("refresh ratings",
  not "re-sync everything"). **`club` is handled separately** — see
  "Bulk club refresh" below.

## Bulk club refresh (`PairingsEngine.ClubRefresh`)

"Update clubs", the button beside "Refresh ratings" on the Players page.
The same gesture — dry run, preview table, Apply — proposing `club` (name)
and `club_number` from the locally-synced KBSB list.

It is a **separate button** rather than more proposals inside the rating
refresh because the two answer different questions ("are these ratings
current?" and "has anyone changed club?"), are wanted at different
moments, and merging them would force an arbiter who only wanted clubs to
accept rating changes too.

### Matching, and why not the KBSB data platform API

`player.national_id` first, then `player.fide_id` — the local KBSB row
carries both, so a player registered from the FIDE database (FIDE id, no
matricule) still resolves.

The obvious alternative was the KBSB data platform's REST API
(`kbsb-api.zerotwo.cloud`). It cannot do this job:

| endpoint | has club? |
|---|---|
| `GET /players_national/:national_id` | yes — `club`, as a club id |
| `GET /players_national/search?q=` | yes, but name search only |
| `GET /players_fide/:fide_id` | **no** — raw FIDE list, no club or membership fields at all |

There is no by-FIDE-id route into the national table, even though the
column is there, so every FIDE-only player would go unmatched. Meanwhile
the local copy already carries `club_name` *and* `club_number` from the
same upstream sync (`docs/kbsb-sync.md`), needs no API key, and works in a
playing hall with no internet — which is where this button gets pressed.
If a by-FIDE-id route is ever added to the platform, it still would not
beat the local copy on any of those three counts.

### It never clears a club

A KBSB row with a blank club is a lapsed or unrecorded membership, not an
instruction to delete what the arbiter typed. So a blank proposes nothing,
exactly as `RatingRefresh` never proposes blanking a title FIDE doesn't
carry. Name and number always move together — half of a renamed or
renumbered club is how a roster ends up self-contradictory.

## The monthly FIDE sync (`PairingsEngine.Fide.Sync`)

Downloads FIDE's combined rating list (~42 MB zip, ~297 MB of text, ~1.9M
rows) and full-replaces `fide_players`. Two things about it are load-bearing
and non-obvious, both discovered the hard way in production.

### The FTS triggers must be suspended for the bulk replace

`fide_players_fts` is kept in step by per-row triggers, and the delete/update
arms find the row with `WHERE fide_id = ?` on a column the FTS5 table declares
**`UNINDEXED`** — so each firing scans the entire index. That's fine for the
ad-hoc single-row writes the triggers exist for, and quadratic for a full
replace, which fires them ~1.9M times and never finishes.

So `import_list/3` captures the trigger definitions from `sqlite_master`, drops
them, does the delete/insert in bulk, rebuilds the index with one set-based
`INSERT ... SELECT`, and puts the triggers back. All inside the surrounding
transaction — SQLite DDL is transactional, so the corrupt-download rollback
guards restore the triggers along with the rows.

> This only ever bit on a **re-**sync. The first sync deletes zero rows, so the
> problem stayed invisible until the second one.

### Symptoms are easy to misread

- **Stuck on "Unpacking…"** does not mean unpacking. `unpack/3` takes about a
  second; `import_list/3` then sets `total_rows` *without* touching `progress`,
  so the label stays on "Unpacking…" through the delete. A stall there is the
  database, not the zip. (The index rebuild now reports
  `Rebuilding the name index…`, so that phase is no longer silent.)
- **Stuck on "Contacting FIDE…"** is usually the host being blocked by
  ratings.fide.com — see `FIDE_LIST_URL` in [`deployment.md`](deployment.md).
- Memory is worth watching regardless: `:zip.extract/2` is called with
  `[:memory]` and materialises the whole ~297 MB list as one binary. On a small
  or shared VPS that alone can push the peak past 1 GB. Streaming it to disk
  instead is the obvious improvement and has not been done yet.

### The list includes unrated players

Roughly 70% of the rows have no standard rating. So a player being absent from
it means "has no FIDE ID", not "isn't rated yet" — worth remembering before
concluding the importer failed to match someone.
