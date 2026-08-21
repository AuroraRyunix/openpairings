# Manual standings (SWAR parity #23)

An arbiter can override the *displayed* rank order on a tournament's
standings - a tiebreak playoff decided over the board, a documented
correction, a courtesy adjustment - without touching a single point or
tiebreak value. `tournament.manual_ranking` (boolean, default `false`) is
the opt-in; `players.manual_rank` (integer, nilable) is the hand-set order -
always a plain positive `1..N` value, or `nil` for a player never placed.
Staleness is tracked separately, on `tournaments.manual_ranking_stale`
(boolean, default `false`) - see below.

## Where it lives

- `PairingsEngine.Standings.apply_manual_ranking/2`,
  `manual_ranking_stale?/1`, `manual_ranking_incomplete?/1`
  (`lib/pairings_engine/standings.ex`) - pure, display-only reordering of
  already-computed entries. Never touches `:points`, `:tiebreaks`, `:total`.
  `manual_ranking_stale?/1` takes the `%Tournament{}` (not entries) and just
  reads `manual_ranking_stale` back.
- `PairingsEngine.Tournaments` "Manual standings override" section
  (`lib/pairings_engine/tournaments.ex`) - `enable_manual_ranking/1`,
  `disable_manual_ranking/1`, `reseed_manual_ranking/1`,
  `move_manual_rank/3`, and the public `invalidate_manual_ranking/1` hook,
  called from `update_pairing_result/2` here and from the bye-write call
  sites in `PairingsEngine.Pairing` (see "Byes" below).
- UI: the Standings page (`standings_live.ex`) - toggle, up/down controls,
  re-seed button, banner. The public standings page
  (`public_standings_live.ex`) - banner only, read-only, same as everywhere
  else it's unauthenticated. Printed standings
  (`print_controller.ex#standings/2`) - a bordered banner box above the
  table. The TRF export (`trf_export.ex`) does **not** surface this feature
  at all (see below) - instead, the page offering the TRF download
  (`PairingsEngineWeb.PairingsLive`, plus a short note on the Settings
  export card) carries a UI warning.

## Explicit override mode, byte-identical when off

`manual_ranking: false` is the existing behaviour, unchanged: every
standings surface just shows `PairingsEngine.Standings.standings/2`'s
computed tiebreak order. `apply_manual_ranking/2` is a literal no-op
(`entries` returned untouched) unless the flag is true, so nothing on this
path changed for a tournament that never turns the feature on.

## Seeding

`enable_manual_ranking/1` sets the flag and immediately seeds every
player's `manual_rank` from the *current* computed standings
(`Standings.standings/1`'s `:rank`) - never an empty or arbitrary list.
`reseed_manual_ranking/1` does the same seeding step on its own, reused both
by `enable_manual_ranking/1` and by the arbiter's explicit "re-seed from
current order" button.

## Staleness - the mechanism, and why

Requirement: once a result (or a bye - see below) is entered or changed, a
previously hand-set order must not be silently discarded *or* silently kept
looking fresh.

The mechanism: a dedicated column, `tournaments.manual_ranking_stale`
(boolean, default `false`, `null: false`). `players.manual_rank` itself is
never touched by invalidation - it stays exactly the plain positive `1..N`
order the arbiter last set. `Tournaments.invalidate_manual_ranking/1`
(public - every point-changing write outside this module's own
`update_pairing_result/2` calls it too, see "Byes" below) sets the flag with
one `UPDATE tournaments SET manual_ranking_stale = true WHERE id = ...`,
gated on `manual_ranking` being on so a tournament that never uses this
feature never pays for the extra write. Setting an already-`true` flag is a
harmless no-op write - invalidating twice in a row (two result changes
before anyone re-seeds) costs a second identical `UPDATE`, not a data change.
`Standings.manual_ranking_stale?/1` just reads the column back off the
`%Tournament{}` already in memory - no extra query on the read path, same
as before.

`invalidate_manual_ranking/1` runs **before**
`broadcast_tournament_change(tournament_id, :results)` inside
`update_pairing_result/2` (and before the equivalent `:rounds` broadcast at
the bye-write call sites in `PairingsEngine.Pairing`), deliberately - every
standings LiveView reacts to that broadcast by immediately re-reading the
DB, and the flag write has no broadcast of its own. Setting it first means
every reload the broadcast triggers already sees `manual_ranking_stale:
true`; setting it after would leave a real race where a subscriber could
render one frame of a still-fresh-looking order before the flag lands, with
nothing left to prompt a second re-render once it does. See
`PairingsEngine.TournamentsTest`'s "invalidate_manual_ranking (via
update_pairing_result/2)" describe block for a test that subscribes,
receives the broadcast, and confirms the flag is already set by then.

**Every point-changing write this feature is aware of now invalidates:**

- Every result entry or correction goes through
  `Tournaments.update_pairing_result/2` (the UI's result form, and
  `PairingsEngine.ResultsImport`, both call it - confirmed by grep, nothing
  else writes `pairings.result`), which calls `invalidate_manual_ranking/1`
  directly.
- **Byes** (`requested-half` / `requested-zero` / `absent` /
  `pairing-allocated`, `byes` table, plus a pairing-allocated bye's `bye`
  result baked straight into its `pairings` row) affect standings points
  too, and are written entirely inside `PairingsEngine.Pairing`, never
  through `update_pairing_result/2`. Both write sites call
  `Tournaments.invalidate_manual_ranking/1` directly, before
  `pair_next_round/1`'s own `:rounds` broadcast:
    - `insert_round_absentee_byes/3` - a round-specific absence
      (`requested-zero`), right after its `Repo.insert_all("byes", rows)`.
    - `create_round/4` - a pairing-allocated bye (an odd player out), whose
      `pairings` row is inserted with `result: "bye"` already set (points
      awarded immediately, no separate result-entry step); invalidated
      inside the same transaction, once per round, if any pair in that
      round was a `b == 0` allocation.
  Pairing a round with **no** bye in it (every player gets a real
  opponent) still doesn't invalidate anything - a freshly paired game
  starts with `result: ""`, which `Standings` doesn't count yet, so nothing
  about the computed order actually changes until a result is entered,
  which routes through the hook above.
- `PairingsEngine.SettingsLive` was audited too (Fix 3): it has no direct
  write to `pairings`, `byes`, or player `extra_points`/points-affecting
  fields - its bye-adjacent content is limited to the `bye_value` *setting*
  (how many points a pairing-allocated bye is worth) and a `manual_ranking`
  toggle passthrough, neither of which is itself a point-changing write on
  an existing player/pairing. Nothing to invalidate there.
- Writers outside this task's file ownership - `PairingsEngine.Keizer`,
  `PairingsEngine.RoundRobin`, `PairingsEngine.TrfImport`,
  `PairingsEngine.TournamentImport`, `PairingsEngine.SwarImport` - also
  insert `byes` rows (or otherwise set points) without invalidating. Keizer
  is exempt by design (see below, it never persists a manual order to begin
  with). The others are real, but out of scope for this task's ownership
  boundary; if any of them can run against a tournament that already has
  `manual_ranking` on (bulk imports and Round Robin/Keizer conversions are
  the likely paths), the same `Tournaments.invalidate_manual_ranking/1` call
  belongs at their bye/point-write sites too - noted here rather than
  silently worked around.

**Explicit reorder confirms freshness.** `move_manual_rank/3` - the arbiter
dragging (well, arrow-clicking) a player up or down - renumbers the *entire*
list 1..N from its current display order and clears
`manual_ranking_stale` tournament-wide, not just for the two rows touched.
The reasoning: the arbiter looking at the list and acting on it *is* the
confirmation the stale flag exists to prompt for. It would be strange to
force a full "re-seed from computed order" round-trip (which would discard
any earlier manual choices) just to acknowledge "yes, I've seen this."
`reseed_manual_ranking/1` clears the same flag, for the same reason.

## The banner

Shown on every surface that displays a rank, per the feature's explicit
requirement list:

1. **Standings page** (`standings_live.ex`) - full banner with toggle,
   stale/incomplete messaging, and the re-seed button when needed.
2. **Public standings page** (`/p/:slug/standings`) - same banner text,
   read-only (no controls) - this is the one page a non-logged-in viewer
   sees, so silence here is the most misleading failure mode of all.
3. **Printed standings** (`/t/:id/print/standings`) - a bordered box above
   the table. Only shown for the *current* standings print (no `?round=`
   param); a round-scoped historical print ("standings as they stood right
   after round n") never applies today's hand-set order to a past round's
   numbers - that would be conflating two different kinds of "as of when"
   and isn't what the arbiter is asking for when they print round 4's
   snapshot.
4. **TRF export** - no banner in the file itself (see below) - instead a
   short warning on the page offering the download, listed there.

**Deliberately out of scope:** the crosstable print
(`/t/:id/print/crosstable`) also has a `Rank` column but isn't in the
feature's explicit surface list and wasn't touched - it still shows the
computed tiebreak order regardless of `manual_ranking`. Mixing a
round-by-round game grid with an arbitrarily hand-set row order is its own
design question or a good follow-up, not assumed here.

## TRF export: why the rank *field* isn't touched, and nothing is added either

`PairingsEngine.Pairing.trf_player_rows/2` sets the FIDE TRF16 "Starting
rank" (columns 5-8) *and* "Rank" (columns 86-89) fields to the same value:
`player.pairing_number`. Every game row's opponent cross-reference is baked
against that same `pairing_number`-based value (`Trf.serialize/1` validates
that every opponent reference resolves and reciprocates). Overwriting just
the `:rank` key with a standings-derived rank in `trf_export.ex` - without
also rewriting every other player's games' `opponent_rank` - would desync
the file's internal cross-references and fail its own validation on every
export. So it isn't touched: `TrfExport.export/2` returns the built TRF
completely unchanged, regardless of `tournament.manual_ranking`.

An earlier version of this feature prepended a one-line notice to the file
using record code `990` (outside FIDE's official `001`-`132` table) when
manual ranking was on. That was removed. Three reasons, in order of
weight:

1. **There's nothing to disclose.** The TRF rank column is
   `pairing_number`-based and manual ranking never touches it - established
   above. A notice about an override that doesn't apply to this file is
   just noise.
2. **"Our own parser ignores it" isn't evidence it's safe.** The only
   argument offered for `990` being spec-legal was that
   `PairingsEngine.Trf.parse/1` drops unknown codes - that says nothing
   about how FIDE's own tooling or JaVaFo would react to an unrecognized
   3-digit code in a submission file. TRF16 is the file an arbiter submits
   to FIDE for rating; "probably harmless because our own code ignores it"
   is not the same as "spec-legal."
3. It was also emitted *before* the mandatory `012` header line, and its
   text referenced an internal repo path (`docs/manual-standings.md`)
   inside a federation submission - both signs it was never meant to ship
   in a file leaving this app.

The caveat now lives where it actually matters: on the page offering the
TRF download. `PairingsEngineWeb.PairingsLive` (the "Pairings" page, where
the "Export TRF" button and the rounds-filtered export form both live)
shows a short factual note - "the TRF export's rank column reflects the
computed/starting-rank order, not the arbiter's hand-set display order" -
whenever `tournament.manual_ranking` is on. The Settings page's export card
carries a shorter version of the same caveat where it already points to the
Pairings page for the TRF16 file.

## Keizer: not offered, on purpose

Keizer standings (`PairingsEngine.Keizer.standings/1`) are recomputed from
scratch on every render and stored nowhere - there's no persisted "current
rank" to seed from or compare against, and the whole notion of "stale since
last seed" doesn't map onto a ladder that's *always* freshly recomputed.
Rather than force `manual_rank`/staleness semantics onto a system that
doesn't have the same shape, manual ranking is simply not offered for
Keizer tournaments:

- `StandingsLive` and `PublicStandingsLive` only ever call
  `Standings.apply_manual_ranking/2` on the non-Keizer branch - the banner,
  toggle and reorder controls never render when `pairing_system == "keizer"`,
  regardless of what `tournament.manual_ranking` happens to be set to.
- `PrintController#standings/2` does the same - the Keizer ladder table is
  unaffected either way.
- `tournament.manual_ranking` itself is a plain tournament-wide boolean, so
  nothing stops it being `true` on a Keizer tournament (e.g. switched on
  under Swiss, then the pairing system changed) - it's just inert there, by
  construction, not by an extra guard that could drift out of sync.
