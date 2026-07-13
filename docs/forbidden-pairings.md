# Forbidden pairings

A **forbidden pairing** is an arbiter-configured rule: two specific players
in a tournament must never be paired against each other — for example two
players from the same household/club, or any other pairing the organiser
wants ruled out for the whole event. It's unrelated to the "avoid recent
opponents" logic every Swiss-style engine already does on its own; a
forbidden pairing is a permanent, explicit exception the arbiter sets up by
hand and that holds for every round.

## Data model

```
forbidden_pairings
  id
  tournament_id  → tournaments.id, on_delete: :delete_all
  player_a_id    → players.id, on_delete: :delete_all
  player_b_id    → players.id, on_delete: :delete_all
```

No timestamps, no unique index at the database level. The table (and the
`PairingsEngine.Tournaments.ForbiddenPairing` schema over it) predates this
feature's UI — `PairingsEngine.TournamentExport` / `TournamentImport`
already read and write it directly by table name as part of the full JSON
backup (see `docs/import-export.md`), so the schema stays a plain
two-column pair rather than adding a DB-level constraint that would
complicate that round-trip.

A pair is **order-insensitive**: forbidding Alice↔Bob also forbids Bob↔Alice.
This is enforced in `PairingsEngine.Tournaments`, not the database — before
inserting, `add_forbidden_pairing/3` checks both `{a, b}` and `{b, a}`
against the existing rows.

## The context layer (`PairingsEngine.Tournaments`)

| Function | Behaviour |
|---|---|
| `list_forbidden_pairings/1` | Lists a tournament's forbidden pairings, most recently added first, with `:player_a` / `:player_b` preloaded so the UI can render "Name A — Name B" without an extra query per row. |
| `add_forbidden_pairing/3` | Takes `(tournament, player_a_id, player_b_id)`. Returns `{:error, :same_player}` if the two ids are equal, `{:error, :invalid_player}` if either player doesn't belong to `tournament`, `{:error, :already_forbidden}` if the pair (either order) already exists — otherwise inserts the row and broadcasts `:settings` on the tournament's PubSub topic. |
| `remove_forbidden_pairing/2` | Takes `(tournament, id)`. Returns `{:error, :not_found}` if `id` isn't a forbidden-pairing row belonging to `tournament` (so a stale/forged id from another tournament can't reach across); otherwise deletes it and broadcasts `:settings`. |

**Authorization:** managing forbidden pairings is a tournament-configuration
write, exactly like the general Settings form (name, rounds, tiebreaks,
officials, ...) — see `docs/teams.md`. Any authorized user, owner **or**
accepted collaborator, can add/remove forbidden pairings; there is no
separate owner-only check, matching `update_tournament/2`. Access itself is
still gated the normal way: `SettingsLive.mount/3` loads the tournament via
`Tournaments.get_authorized_tournament!/2`, so a stranger never reaches the
LiveView (and therefore never reaches these functions) at all.

## The UI (Settings page)

The Settings page (`/t/:id/settings`) has a "Forbidden pairings" card,
visible to the owner and every collaborator: two alphabetical player
`<select>`s and an "Add" button, followed by the current list as
"Name A — Name B" rows each with a Remove button. Invalid adds (same player
picked twice, or a pair that's already forbidden) show a friendly inline
error instead of a crash or a raw changeset dump.

## Applying it to pairing

### Swiss (JaVaFo) — implemented

JaVaFo (the FIDE-endorsed Dutch-system engine `PairingsEngine.Pairing`
shells out to) supports a TRF extension line for this: `XXP <ids...>` — all
player ids listed on one `XXP` line must never be paired against each
other; multiple `XXP` lines are allowed, one per rule.

`PairingsEngine.Pairing.javafo_input/2` builds one `"XXP a b\r\n"` line per
forbidden pairing, right after the existing `XXR` (total rounds) line. The
ids on the line are **not** the players' database ids — they're each
player's TRF starting rank (`pairing_number`) for *this pairing run*, the
same numbering used for every other player row in the generated TRF. This
translation is `PairingsEngine.Pairing.forbidden_pairs_lines/2`:

```elixir
def forbidden_pairs_lines(tournament_id, players) do
  rank_by_player_id = Map.new(players, &{&1.id, &1.pairing_number})

  tournament_id
  |> Tournaments.list_forbidden_pairings()
  |> Enum.map(fn fp -> {rank_by_player_id[fp.player_a_id], rank_by_player_id[fp.player_b_id]} end)
  |> Enum.reject(fn {a, b} -> is_nil(a) or is_nil(b) end)
  |> Enum.map_join(fn {a, b} -> "XXP #{a} #{b}\r\n" end)
end
```

If either player in a forbidden pair isn't in `players` at all, or hasn't
been assigned a `pairing_number` yet (not active, permanently
absent/forfeited, or simply never paired before), that pair is **skipped
silently** — JaVaFo only needs to hear about players it's actually being
asked to pair this round, and a rank-less id on an `XXP` line would be
meaningless (or could even collide with another player's rank by
coincidence).

### Keizer — respected once implemented

`PairingsEngine.Keizer.pair_next_round/1` is still a stub today (see
`docs/pairing-systems.md`, returns `{:error, :not_implemented}`), but it's
intended to read `Tournaments.list_forbidden_pairings/1` the same way and
exclude forbidden opponents when matching players on the running Keizer
list, once its actual pairing logic lands.

### Round robin (Berger) — ignored by design

`PairingsEngine.RoundRobin` does **not** consult forbidden pairings. A round
robin's schedule (every player meets every other player once, or twice for
`rr_cycles: 2`) is fixed by definition — there's no pairing *decision* left
to influence, and skipping a scheduled round-robin game would leave a hole
in the schedule rather than substituting a different opponent. If an
organiser needs to guarantee two players never meet, round robin isn't the
right pairing system for that field.

## Interaction with the JSON backup

`PairingsEngine.TournamentExport` includes every forbidden pairing under
`"forbidden_pairings": [{"player_a_id": ..., "player_b_id": ...}]` in the
per-tournament envelope, and `PairingsEngine.TournamentImport` re-creates
them against the newly-imported players' ids (remapped through the same
old-id → new-id table used for every other player reference). A row whose
player id doesn't resolve during import (only possible from a hand-edited
file) is skipped individually rather than failing the whole import — see
`docs/import-export.md`.
