# Pairing systems

Every tournament has a `pairing_system` — the engine
`PairingsEngine.Pairing.pair_next_round/1` dispatches to when someone
presses "Pair round N". It's independent of `tournaments.type` (the
individual/team + FIDE report classification used for TRF export and
default tiebreaks) — `pairing_system` only decides which pairing engine
actually runs.

## Swiss — FIDE Dutch — available

The default. The tournament and its players are serialized to TRF16 and
handed to a Dutch-system engine, whose output becomes the round's pairings.
See `PairingsEngine.Pairing` for the full lifecycle (TRF build, engine run,
round/pairing creation, absentee byes). Optional Baku acceleration
(`tournament.acceleration == "baku"`, FIDE C.04.7) is Swiss-only — see
`docs/acceleration.md`.

*Which* engine runs is a second, independent setting — `pairing_engine`,
below. Round robin and Keizer never reach an engine at all, so that setting
is inert for them.

### The engine: `pairing_engine` (Swiss only)

| Value | Engine | Status |
|---|---|---|
| `"javafo"` *(default)* | JaVaFo (© Roberto Ricca), an external Java program invoked as `java -jar javafo.jar input.trf -p output.txt` | FIDE-endorsed; the only engine permitted for a FIDE-homologated tournament |
| `"openpair"` | [OpenPair](https://github.com/AuroraRyunix/openpair), a from-scratch Dutch engine in pure Elixir, running inside this app's own BEAM | Beta; never for FIDE-rated events |

**Both engines are handed the byte-identical TRF.** `Pairing.javafo_input/4`
builds the file once and the engine choice only decides what turns those
bytes into `[{white_rank, black_rank}]`. Everything downstream —
`create_round/5`, board numbering/freezing, absentee byes, standings — is
shared and cannot tell which engine answered. That is deliberate: it keeps
the two directly comparable on real tournament data (pair a round with one,
delete it, pair it with the other, diff), rather than only on synthetic
input.

**Why JaVaFo stays the default, and why the FIDE restriction is not
negotiable.** OpenPairings answers FIDE's FE1 question *"Internal engine:
YES/NO"* with **NO — thru JaVaFo**, exactly as Vega, Swiss Manager and
TournamentService do; JaVaFo's own endorsement is what then covers pairing
legality for the whole event. Pairing a homologated tournament with any
other engine voids that answer outright. See `docs/fide-endorsement.md`.

**What OpenPair does not do yet.** Its TRF parser reads only the `XXR`
(round count) extension. The `XXP` lines carrying forbidden pairings and
club/federation exclusions (`docs/forbidden-pairings.md`) and the `XXA`
lines carrying Baku acceleration virtual points are invisible to it. An
engine that ignores those still returns a complete, entirely legal-looking
pairing — one that just happens to seat two players who must never meet —
so this is handled by refusing rather than by hoping:

* `pairing_engine: "openpair"` together with `acceleration: "baku"` is
  rejected by `Tournament.changeset/2`, in both directions.
* A round whose TRF would carry any `XXP` line is refused at pairing time
  with a message naming the reason, and nothing is written. Forbidden
  pairings and exclusion rules can be added at any point mid-tournament,
  long after the engine choice has locked, so they cannot be caught in the
  changeset.

**Three guards, all in the data layer** (the Settings UI renders from the
same rules, but the UI has never been the enforcement here):

1. `pairing_engine` is a member of `Tournaments.locked_fields/1` — frozen
   once the first round is paired, like `pairing_system` itself. Two
   independent Dutch implementations will not always choose the same
   pairing, and swapping mid-event hands the new engine a history it did
   not produce.
2. `"openpair"` is refused on a `fide_homologated` tournament, and ticking
   `fide_homologated` on a tournament already running OpenPair is refused
   too — the reverse direction matters just as much.
3. Round robin and Keizer ignore the setting entirely (see below); it is
   read only on the Swiss path.

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

**Cross table print.** `GET /t/:id/print/crosstable` renders the classic
players×players round-robin grid (rows/columns ordered by `pairing_number`,
one cell per opponent, both cycles shown for a double round robin) instead
of the round-by-round Swiss cross table Swiss/Keizer tournaments get — see
`docs/printing.md`.

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

* **Pairing numbers.** Exactly like Swiss (and reusing that same code —
  `PairingsEngine.Pairing.ensure_pairing_numbers/2`), a Keizer tournament
  freezes `pairing_number` over its active players the first time it pairs a
  round — highest rating first, name ascending as the tie-break — and never
  reassigns one once set; a newcomer gets a number the next time a round is
  paired. Nothing about the Keizer ladder itself depends on this number —
  it's purely what the crosstable print and the player grid's "Nr" column
  show. (Before this, Keizer tournaments never assigned pairing numbers at
  all, so those views showed "?" for every Keizer player.)

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

`pairing_system` is locked once the tournament has paired its first round:
switching systems after rounds have already been paired by a different one
would leave a mixed, likely-inconsistent pairing history. The lock lives in
`Tournaments.locked_fields/1` and is enforced inside `update_tournament/2`,
which is what the Settings page's disabled select renders from — one rule,
one place, so the two can't drift.

`pairing_engine` (the Swiss engine — see above) locks on exactly the same
condition and for the same reason one level down: JaVaFo and OpenPair are
two independent implementations of the Dutch system, and a round already on
the board was decided by whichever one was configured at the time.

`rr_cycles` (round robin only) locks separately once the number of paired
rounds reaches what the *current* cycles setting implies a round-robin
schedule needs — roughly `(player_count - 1) * rr_cycles` rounds. Before
that point it stays editable.

`keizer_top_value` has no lock — it can be changed at any time, including
mid-tournament, since it only affects how far down the Keizer list players
are still paired.
