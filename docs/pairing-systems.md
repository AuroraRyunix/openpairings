# Pairing systems

Every tournament has a `pairing_system` — the engine
`PairingsEngine.Pairing.pair_next_round/1` dispatches to when someone
presses "Pair round N". It's independent of `tournaments.type` (the
individual/team + FIDE report classification used for TRF export and
default tiebreaks) — `pairing_system` only decides which pairing engine
actually runs.

## Swiss — FIDE Dutch (JaVaFo) — available

The default, and the only one implemented today. Round pairing runs through
JaVaFo (© Roberto Ricca, the FIDE-endorsed Dutch-system engine): the
tournament and active players are serialized to TRF16, JaVaFo is invoked as
a subprocess, and its output becomes the round's pairings. See
`PairingsEngine.Pairing` for the full lifecycle (TRF build, JaVaFo run,
round/pairing creation, absentee byes).

## Round robin (Berger) — available

Each player meets every other player once (single cycle, `rr_cycles: 1`) or
twice with colours reversed (double cycle, `rr_cycles: 2`). Implemented in
`PairingsEngine.RoundRobin`, which `PairingsEngine.Pairing.pair_next_round/1`
dispatches to.

**The schedule.** FIDE only publishes finished Berger tables (Handbook C.05
Annex 1) rather than a formula, but they follow a well-defined "circle
method" construction that `PairingsEngine.RoundRobin.schedule/3`
reimplements and has been verified against the published N=4 and N=6
tables. Players are numbered 1..N by their frozen `pairing_number`; one
player is fixed and every round it plays whoever `(round × inverse-of-2 mod
m)` computes to (a bijection over rounds, so everyone takes that slot
exactly once per cycle), while the rest pair off symmetrically. Colour
follows a similarly derived rule (see the module doc for the full
derivation and citations). The whole computation is a **pure function** of
`(player count, cycles, round number)` — pairing round K always produces
the same result no matter when it's computed, which is the correctness
property a fixed schedule depends on.

**Odd player counts.** A phantom player numbered N+1 is added to make the
count even (FIDE's own rule: "where there is an odd number of players, the
highest number counts as a bye"). Whichever real player is scheduled
against the phantom that round gets a structural, **zero-point** bye
instead of a real pairing — recorded as a `"requested-zero"` row in the
`byes` table (TRF code `Z`), the same shape Swiss already uses for a
round-specific requested absence, with no corresponding `pairings` row.
Zero was chosen deliberately over `"pairing-allocated"` (a full point):
every player gets exactly one of these byes per cycle, so a full point
would just be an equally-distributed no-op at best and an unfair windfall
at worst if cycles don't complete evenly — zero keeps it neutral. Every
round has exactly one such bye (never zero, never two), since the
phantom's opponent is a bijection over rounds.

**Freezing pairing numbers.** Exactly like Swiss, pairing numbers are
assigned once — highest rating first, name as the tie-break (FIDE
C.04.2.B) — on the first call to `pair_next_round/1` for the tournament,
then frozen forever. Unlike Swiss, round robin never assigns numbers to
anyone afterward: the Berger table is fixed the moment round 1 is paired,
and there's no way to slot a newcomer into an already-computed schedule
without changing every other player's opponents round by round. **Players
who join after that first pairing are simply excluded from the schedule
for the rest of the tournament** — they never receive a `pairing_number`
via this path and never appear in any later round-robin round.

**Absences don't change the schedule.** A player marked absent for a
specific round (or withdrawn/forfeited entirely) still appears in the
schedule every round after the freeze — round robin never pulls someone
out and re-derives pairings around them, because that would ripple through
everyone else's opponents for that round. The arbiter records a forfeit
result for their games instead, the same way any other forfeit is
entered.

## Keizer — available

A Dutch/Belgian club-league style system (as used by PairTwo and similar
SWAR-adjacent software): players sit on a running "Keizer list" rather than
a fixed bracket, each rung worth a points value, and every round they're
paired against others close to them on that list. See
`PairingsEngine.Keizer` for the full algorithm; summarized:

* **The ladder.** With `N` schedulable players and a "top" cutoff value `T`
  (`keizer_top_value` — blank/nil means automatic, `2 × N`, floored at
  `N + 1` so the bottom rung never goes to zero or negative), the player
  ranked `i` (1-based, best first) is worth `T - (i - 1)`. Before round 1
  the ranking is simply rating descending (name ascending as the tiebreak).

* **Scoring**, given the *current* ladder values: a win is worth the
  opponent's value, a draw half of it, a loss nothing. A forfeit win (no
  game played) is worth half the player's own value — same as an unpaired
  (odd-count) bye. A forfeit loss, double forfeit, or a played "0-0" is
  worth nothing. An excused absence (the player's `Absent` flag, or the
  round listed in `absent_rounds`) is worth a third of the player's own
  value. Rounds before a player's `start_round` are worth nothing.

* **Retroactive recalculation** is the signature Keizer feature: nothing
  Keizer-specific is ever stored in the database — only results, byes and
  absences are — so the whole ladder is recomputed from scratch every time
  it's needed. Ranking and scoring are mutually dependent, so this is a
  fixed point: assign values from the current order, score every round
  played so far with those values, re-rank by total Keizer points (ties:
  rating descending, then name), reassign values, rescore — repeat until
  the order stops changing or 20 iterations, whichever comes first (a
  20-iteration cap guards against a pathological oscillation; whichever
  order the last iteration produced is used). Because every round is
  rescored with the *current* values on every pass, an opponent you beat
  early on who later climbs the list keeps increasing what that early win
  is worth — nothing is ever "locked in".

* **Pairing** the next round takes that recalculated order, drops anyone
  not eligible this round (same eligibility Swiss pairing uses — an
  absence, permanent or round-specific, scores the excused-absence
  fraction above instead of being paired), then walks top-down pairing
  each unpaired player with the nearest unpaired player below them they
  haven't already played, backtracking when that leads to a dead end
  further down the list. A `forbidden_pairings` pair (see
  `docs/forbidden-pairings.md`) is never paired; if a repeat is truly
  unavoidable, the pair repeated longest ago is preferred over failing
  outright. An odd count gives the bye to the lowest-ranked player it can
  — if that specific player's bye would leave the rest impossible to pair,
  the next-lowest-ranked candidate is tried instead.

* **Colours.** The player with fewer games as White so far gets White;
  tied, the lower-ranked player (further down the list) gets White. Colour
  is never a reason to reject a pairing.

* **Standings** for a Keizer tournament show the Keizer ladder (rank, name,
  rating, current value, Keizer points, and the same games under ordinary
  FIDE-style scoring for comparison) instead of the FIDE tiebreak table —
  FIDE tiebreaks (Buchholz, Sonneborn-Berger, etc.) don't apply to a Keizer
  ladder. See `PairingsEngine.Keizer.standings/2` (accepts `through_round:
  n`, same idea as `PairingsEngine.Standings.standings/2`), and every
  standings-shaped view — `StandingsLive`, `PublicStandingsLive`,
  `LiveRoundLive` (the `/t/:id/live` projector page) and the standings print
  document (`PairingsEngineWeb.PrintController.standings/2`, including its
  per-category tables) — which all render this table instead of the usual
  one whenever `pairing_system == "keizer"`.

Implemented in `PairingsEngine.Keizer.pair_next_round/1`, dispatched to the
same way as every other pairing system (see above).

## Changing the pairing system mid-tournament

`pairing_system` is locked (both in the UI — the select is disabled — and
server-side in `SettingsLive`) once the tournament has paired its first
round: switching engines after rounds have already been paired by a
different system would leave a mixed, likely-inconsistent pairing history.

`rr_cycles` (round robin only) locks separately once the number of paired
rounds reaches what the *current* cycles setting implies a round-robin
schedule needs — roughly `(player_count - 1) * rr_cycles` rounds. Before
that point it stays editable.

`keizer_top_value` has no lock — it can be changed at any time, including
mid-tournament, since it only affects how far down the Keizer list players
are still paired.
