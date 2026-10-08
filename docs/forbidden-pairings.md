# Forbidden pairings

A **forbidden pairing** is an arbiter-configured rule: two specific players
in a tournament must never be paired against each other - for example two
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
  soft           boolean, default false - a wish rather than a rule (see "Soft rules")
```

No timestamps, no unique index at the database level. The table (and the
`PairingsEngine.Tournaments.ForbiddenPairing` schema over it) predates this
feature's UI - `PairingsEngine.TournamentExport` / `TournamentImport`
already read and write it directly by table name as part of the full JSON
backup (see `docs/import-export.md`), so the schema stays a plain
two-column pair rather than adding a DB-level constraint that would
complicate that round-trip.

A pair is **order-insensitive**: forbidding Alice↔Bob also forbids Bob↔Alice.
This is enforced in `PairingsEngine.Tournaments`, not the database - before
inserting, `add_forbidden_pairing/3` checks both `{a, b}` and `{b, a}`
against the existing rows.

## The context layer (`PairingsEngine.Tournaments`)

| Function | Behaviour |
|---|---|
| `list_forbidden_pairings/1` | Lists a tournament's forbidden pairings, most recently added first, with `:player_a` / `:player_b` preloaded so the UI can render "Name A - Name B" without an extra query per row. |
| `add_forbidden_pairing/3` | Takes `(tournament, player_a_id, player_b_id)`. Returns `{:error, :same_player}` if the two ids are equal, `{:error, :invalid_player}` if either player doesn't belong to `tournament`, `{:error, :already_forbidden}` if the pair (either order) already exists - otherwise inserts the row and broadcasts `:settings` on the tournament's PubSub topic. |
| `remove_forbidden_pairing/2` | Takes `(tournament, id)`. Returns `{:error, :not_found}` if `id` isn't a forbidden-pairing row belonging to `tournament` (so a stale/forged id from another tournament can't reach across); otherwise deletes it and broadcasts `:settings`. |

**Authorization:** managing forbidden pairings is a tournament-configuration
write, exactly like the general Settings form (name, rounds, tiebreaks,
officials, ...) - see `docs/teams.md`. Any authorized user, owner **or**
accepted collaborator, can add/remove forbidden pairings; there is no
separate owner-only check, matching `update_tournament/2`. Access itself is
still gated the normal way: `SettingsLive.mount/3` loads the tournament via
`Tournaments.get_authorized_tournament!/2`, so a stranger never reaches the
LiveView (and therefore never reaches these functions) at all.

## The UI

Settings → Forbidden pairings (`/t/:id/settings/restrictions`) - see
"The page" under Pairing rules below. Until 0.79.0 these lived on the
Options page as two player `<select>`s and the exclusion settings.

## Applying it to pairing

### Swiss - implemented

The TRF carries an extension line for this: `XXP <ids...>` - all player ids
listed on one `XXP` line must never be paired against each other; multiple
`XXP` lines are allowed, one per rule. Both Swiss engines read it (see
`docs/pairing-systems.md`), and both are handed the same file, so nothing
below depends on which one is selected.

`PairingsEngine.Pairing.javafo_input/2` puts one group per forbidden
pairing in the tournament map it hands to `Ainalrami.Trf.serialize/2`,
which writes them as `XXP` lines after the player rows. The ids in a group
are **not** the players' database ids - they're each player's TRF starting
rank (`pairing_number`) for *this pairing run*, the same numbering used for
every other player row in the generated TRF. This translation is
`PairingsEngine.Pairing.forbidden_pairs/3`:

```elixir
def forbidden_pairs(tournament_id, players, rank_by_player_id \\ nil) do
  rank_by_player_id = rank_by_player_id || Map.new(players, &{&1.id, &1.pairing_number})

  tournament_id
  |> Tournaments.list_forbidden_pairings()
  |> Enum.map(fn fp -> {rank_by_player_id[fp.player_a_id], rank_by_player_id[fp.player_b_id]} end)
  |> Enum.reject(fn {a, b} -> is_nil(a) or is_nil(b) end)
  |> Enum.map(fn {a, b} -> [a, b] end)
end
```

It returns ranks rather than the `XXP` text it used to, because that text
was concatenated onto an already-finished TRF - which put the arbiter's
rules outside the writer, and outside every check the writer makes.

If either player in a forbidden pair isn't in `players` at all, or hasn't
been assigned a `pairing_number` yet (not active, permanently
absent/forfeited, or simply never paired before), that pair is **skipped
silently** - the engine only needs to hear about players it's actually being
asked to pair this round, and a rank-less id on an `XXP` line would be
meaningless (or could even collide with another player's rank by
coincidence).

### Keizer - implemented

`PairingsEngine.Keizer.pair_next_round/1` reads
`Tournaments.list_forbidden_pairings/1` (via its private `read_forbidden/2`)
into a `MapSet` keyed by `pair_key/2` (the pair of player ids, ordered
`{min, max}`) and excludes forbidden opponents when matching players
top-down on the running Keizer list - see `PairingsEngine.Keizer`'s
module doc, "6. Pairing". Club/federation exclusion rules (below) are
unioned into that same `MapSet`, so both kinds of rule are enforced by the
identical matcher.

### Round robin (Berger) - ignored by design

`PairingsEngine.RoundRobin` does **not** consult forbidden pairings or
club/federation exclusion rules. A round robin's schedule (every player
meets every other player once, or twice for `rr_cycles: 2`) is fixed by
definition - there's no pairing *decision* left to influence, and skipping
a scheduled round-robin game would leave a hole in the schedule rather than
substituting a different opponent. If an organiser needs to guarantee two
players never meet, round robin isn't the right pairing system for that
field. The Settings page's exclusion-rules card says as much.

## Pairing rules (`PairingsEngine.Tournaments.PairingRule`, since 0.79.0)

Explicit forbidden pairings name two players. For the common case - "nobody
from the same club", "no compatriots in the last two rounds", "these five
never meet" - naming every pair by hand doesn't scale, so a tournament also
carries any number of **rules**:

```
pairing_rules
  id, tournament_id
  kind           "club" | "federation" | "group"
  soft           boolean - a wish ("if possible") rather than a rule
  names          club/federation only: limited to these (empty = every one)
  player_ids     group only: the players who never meet each other
  window         "all" | "first" | "last" | "range"
  window_rounds  first/last N
  window_from, window_to   range
  from_round     set when added after rounds were paired (as forbidden_pairings.from_round)
```

A rule is never stored as pairs. `PairingsEngine.Exclusions` expands it from
the players as they are when a round is paired - so a late entrant or a
corrected club is covered without anybody touching it - and only for the
rounds it holds in (`Exclusions.applies?/3`; "last N" counts back from the
tournament's number of rounds). Clubs and federations are compared trimmed
and case-insensitively; a blank one is never a group.

* Hard rules reach the engines as pairs (`Exclusions.hard_pairs/4`):
  `Pairing.exclusion_pairs/6` turns them into starting-rank `XXP` groups,
  deduplicated against explicit pairs; Keizer folds them into its forbidden
  set for the round.
* Soft rules reach Ainalrami as whole groups (`Exclusions.soft_groups/4`,
  through `Pairing.soft_pairs/6`) - C.05 5.2's own example is one: "players
  from the same federation shall, if possible, not meet in the last rounds".
  JaVaFo and Keizer have no such option and ignore them.
* The TRF26 report writes each hard rule as one `260` per club, federation
  or group, with its rounds when it does not hold for the whole event; the
  engine dialect writes the `XXP` groups that hold for the next round.

The five tournament columns that held the old club/federation exclusions and
the soft club wish (`club_exclusion`, `club_exclusion_list`, `fed_exclusion`,
`fed_exclusion_list`, `soft_club_rounds`) were turned into rules by the
migration that introduced this table, with exactly their old meaning, and
are no longer read. A JSON backup from before 0.79.0 carries them instead of
a `pairing_rules` block; `TournamentImport` converts them the same way.

### The page

Settings → Forbidden pairings (`PairingsEngineWeb.SettingsRestrictionsLive`):

* **Effect on the next round** - games the hard prohibitions rule out,
  players left with nobody (prohibitions plus games already played), and
  whether the round can be paired at all (`PairingsEngine.RestrictionCheck`,
  Ainalrami's team-pairing perfect-matching oracle asked over the players).
* **Rules** - add, edit in place, remove; each shows its pairs and groups
  ("4 pairs among 2 clubs").
* **Players who must not meet** - a searchable list with club, federation
  and rating; tick any number and keep them apart in one action (two make a
  forbidden pair, three or more a group rule). Pairs can be turned into a
  wish or a rule in place; groups are edited by ticking.
* **How hard to try the wishes** - `soft_position`.

### FIDE mode (VCL4THP Q195/Q196)

C.05 5.2: restrictions are announced before the first round. Having them is
no departure. Adding, changing or removing a pair or a rule once round 1 is
paired - or changing `soft_position` while there are wishes - is: the page
asks TEC's Level-4 double confirmation, and the context records the act in
`tournaments.prohibition_changes` and stamps `fide_compliance_lost_round` in
the same transaction (`Tournaments.record_prohibition_change/2`). TRF26
copies write `### Prohibition @ Round r: ...` lines; the file sent for
rating does not. A rule reaching a late entrant is not an act. Prohibitions
added late before 0.79.0 are not re-judged: only new acts count.

## Interaction with the JSON backup

`PairingsEngine.TournamentExport` includes every forbidden pairing under
`"forbidden_pairings": [{"player_a_id": ..., "player_b_id": ..., "soft": false}]`
in the per-tournament envelope (a file written before soft rules existed has
no `"soft"` key, and every row in it imports as a rule), and
`PairingsEngine.TournamentImport` re-creates
them against the newly-imported players' ids (remapped through the same
old-id → new-id table used for every other player reference). A row whose
player id doesn't resolve during import (only possible from a hand-edited
file) is skipped individually rather than failing the whole import - see
`docs/import-export.md`.

## Soft rules - "rather not, if possible"

Everything above is a **rule**: a pair the engine may not seat, whatever it
costs, and a round with no legal way round the rules is a round that
cannot be paired. Arbiters often mean something weaker - "keep these two
apart if you can", "no club games in the first two rounds" - and until
0.45.0 the only way to say it was to say the strong thing and hope.

A soft rule is a **wish**. The Ainalrami engine weighs it against the
pairing criteria as one more rung on its ladder, `S soft avoid`, and gives
way when the rules leave no other legal round: three players who all wish
to avoid each other still produce a game and a bye, where the same three
pairs as rules leave no legal round at all. The rationale page names the
rung in the arbiter's words ("pairs the arbiter asked to keep apart if
possible"), and a what-if that seats a soft pair anyway is judged on it.

Three places, all defaulting to "no wishes", under which the engine's
behaviour is byte for byte what it was:

```
forbidden_pairings.soft        a single pair as a wish instead of a rule
pairing_rules.soft             a rule as a wish (clubmates apart in rounds 1..N, ...)
tournaments.soft_position      "strong" | "weak" - how hard to try
```

*Strong* puts the wish above the quality criteria (C6 onwards): the engine
would rather float a player than seat the pair, which is what "club
protection" means in practice. *Weak* puts it below C21: a tie-break and
nothing more. The absolute criteria (C1-C3, the bye rule) sit above either -
a wish never produces a rematch, a third colour in a row, or an illegal bye.

`PairingsEngine.Pairing.soft_pairs/5` turns the settings into starting-rank
groups in the same shape `forbidden_pairs/4` returns, resolved against the
same rank map - a soft row as a pair, each group a soft rule keeps apart in
the round as one group. Unlike the
rules, the wishes cannot travel in the TRF, which has no way to say "if you
can": they are handed to `Ainalrami.Pairing.pair_next_round/2` as its
`soft_pairs` / `soft_position` options, alongside the file. A soft row is
therefore **never** an `XXP` line - `forbidden_pairs/4` and
`exclusion_pairs/4` read hard rows only.

Only Ainalrami reads the wishes. JaVaFo has no such option and Keizer's
matcher no such rung (`read_forbidden/2` skips soft rows), so for them a
soft pair is simply not a rule. The Options page says which is the case for
the tournament in front of the arbiter rather than letting a wish be set
that nothing reads.

**Wishes are not FIDE's.** Even the weak position replaces the Dutch
system's own last word among equally good pairings (the order candidates
are generated in), so a round a wish changed is not the round a FIDE
checker reproduces; Ainalrami lists soft pairs under "Organiser deviations".
When the round has any wishes, `run_ainalrami/5` pairs it a second time
without them (everything else as it was) and, if the boards differ, records
`"soft_pairs_moved": true` on the round's account. The first such round is
stamped as `fide_compliance_lost_round` and gets a
`tournament.fide_compliance_lost` audit row (setting `soft_pairs`, code
`soft_pairing_wish`), exactly as a bye exclusion that moves the bye does
(`Pairing.pairing_deviations/2`). A wish the pairing already honoured
records nothing. The Options page says so beside the wishes.
