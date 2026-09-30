# Pairing systems

Every tournament has a `pairing_system` - the engine
`PairingsEngine.Pairing.pair_next_round/1` dispatches to when someone
presses "Pair round N". It's independent of `tournaments.type` (the
individual/team + FIDE report classification used for TRF export and
default tiebreaks) - `pairing_system` only decides which pairing engine
actually runs.

## Swiss - FIDE Dutch - available

The default. The tournament and its players are serialized to TRF16 and
handed to a Dutch-system engine, whose output becomes the round's pairings.
See `PairingsEngine.Pairing` for the full lifecycle (TRF build, engine run,
round/pairing creation, absentee byes). Optional Baku acceleration
(`tournament.acceleration == "baku"`, FIDE C.04.7) is Swiss-only - see
`docs/acceleration.md`.

Players' extra points can feed the pairing too, as virtual points on the
same `XXA` channel (`docs/extra-points.md`): always in acceleration mode
(SWAR's XtraPoints - the stronger players start a score group up), and in
handicap mode while the handicap is counted (the score groups are then the
standings' own totals). Each round records the virtual points it was paired
with (`rounds.virtual_points`), because the engine needs the full per-round
history to judge floats, and the row order handed to the engine
(`order_for_pairing/3`) sorts by points plus this round's extra points.
Baku and extra points in the pairing are mutually exclusive.

*Which* engine runs is a second, independent setting - `pairing_engine`,
below. Round robin and Keizer never reach an engine at all, so that setting
is inert for them.

### The engine: `pairing_engine` (Swiss only)

| Value | Engine | Status |
|---|---|---|
| `"ainalrami"` *(default)* | [Ainalrami](https://github.com/AuroraRyunix/Ainalrami), a from-scratch Dutch engine in pure Elixir, running inside this app's own BEAM | Implements C.04.3 effective 1 February 2026; permitted on a FIDE-homologated tournament, with the paperwork caveat below |
| `"javafo"` | JaVaFo (© Roberto Ricca), an external Java program invoked as `java -jar javafo.jar input.trf -p output.txt` | FIDE-endorsed; implements the 2017 edition of C.04.3 |

**Both engines are handed the byte-identical TRF.** `Pairing.javafo_input/4`
builds the file once and the engine choice only decides what turns those
bytes into `[{white_rank, black_rank}]`. Everything downstream -
`create_round/5`, board numbering/freezing, absentee byes, standings - is
shared and cannot tell which engine answered. That is deliberate: it keeps
the two directly comparable on real tournament data (pair a round with one,
delete it, pair it with the other, diff), rather than only on synthetic
input.

**Why Ainalrami is the default, and what that costs on the FIDE side.** The
default flipped on 2026-08-25. JaVaFo 2.2 implements C.04.3 as it stood
until 31 January 2026 and has not been updated for the edition effective
1 February 2026, so leaving it as the default meant handing arbiters
superseded pairings without their having asked for them. A program with no
engine of its own answers FIDE's FE1 question *"Internal engine: YES/NO"*
with **NO - thru JaVaFo**, exactly as Vega, Swiss Manager and
TournamentService do, and JaVaFo's own endorsement is what then covers
pairing legality for the whole event. That
answer no longer describes what this app normally does. The cost is
paperwork rather than pairing quality: a rated event paired by Ainalrami was
not paired by the engine such an answer names. Which engine a homologated
tournament uses is the arbiter's decision, and the Settings page says so
there instead of blocking the choice. See `docs/fide-endorsement.md`.

**TRF extensions.** Ainalrami reads all three this app emits: `XXR` (round
count), `XXP` (forbidden pairings and club/federation exclusions -
`docs/forbidden-pairings.md`) and `XXA` (virtual points: Baku acceleration,
or players' extra points - `docs/extra-points.md`).
All three are written by `Ainalrami.Trf.serialize/2` itself, from the
tournament map the app hands it - the app used to concatenate them onto the
finished text, which put the lines carrying the arbiter's rules outside the
writer and outside its checks.

It did not always. Until ainalrami `451c749` its parser discarded every
extension but `XXR`, which is the worst possible failure mode for this
particular kind of input: an engine that ignores an `XXP` line still returns
a complete, entirely legal-looking round that just happens to seat two
players who must never meet, and nothing downstream can tell. Measured on
ainalrami's own fuzz corpus at a 20% forbidden rate, **27.72% of rounds
seated an excluded pair** - and that was its entire disagreement with
bbpPairings on that axis. Both extensions were implemented upstream rather
than worked around here, and re-verified against bbpPairings over 1.79M
rounds carrying them.

The guard that caught it stays, in its general form: `Pairing` scans the TRF
it actually generated and refuses to pair, writing nothing, if it finds any
line whose code is neither TRF16's own nor on the list of extensions this
integration carries through to the engine. It looks at every non-TRF16
code, not only the `XX` ones, because the writer emits the numeric and
`BB*` extension spellings too - `152`, the initial colour drawn by lot, is
the one it can write that the engine will not act on, and is the reason the
guard is still doing work now that one module both writes and reads the
file. That check is against the
generated file rather than against the tournament's settings, so the next
extension this pipeline learns to emit is refused by default instead of
being silently ignored by whichever engine happens to be selected. It cannot
live in the changeset: forbidden pairings and exclusion rules live in their
own table and can be added at any point mid-tournament, long after the
engine choice has locked.

**Two guards, both in the data layer** (the Settings UI renders from the
same rules, but the UI has never been the enforcement here):

1. `pairing_engine` is a member of `Tournaments.locked_fields/1` - frozen
   once the first round is paired, like `pairing_system` itself. Two
   independent Dutch implementations will not always choose the same
   pairing, and swapping mid-event hands the new engine a history it did
   not produce.
2. Round robin and Keizer ignore the setting entirely (see below); it is
   read only on the Swiss path.

There used to be a third: `"ainalrami"` was refused on a `fide_homologated`
tournament, and ticking `fide_homologated` on a tournament already running
Ainalrami was refused too. That block was removed on 2026-08-21 -
`Tournament.validate_pairing_engine/1` now passes the changeset through
unchanged, and the comment above it records why: refusing outright asserted
a quality judgement the measurements do not support. The Settings page warns
on a homologated tournament instead.

### Bye exclusions - "no pairing-allocated bye" (not a FIDE rule)

An organiser's rule, offered because Belgian club and youth events ask for
it: a player who travelled far, a junior whose parents drive an hour, must
not be the one sent home with the pairing-allocated bye. It is **not part
of the FIDE rules** - C.04.3 gives the bye to whoever its criteria select -
so a round it changes differs from what a FIDE-endorsed program pairs, and
a FIDE checker replaying the TRF will not reproduce it.

**Where it is.** Behind the BEL pack's `bel_bye_exclusions` switch
(Features page, `PairingsEngine.Features`): with it on, a player's details
have "Exclude from the pairing-allocated bye"; ticked, "All rounds" or
"Certain rounds", the rounds typed exactly like the absences above it
(same grammar, same parser - `Player.parse_absent_rounds_input/1` - stored
canonically in `players.no_bye_rounds`; blank means every round). Like
every pack switch it gates the control only: a player who already has an
exclusion keeps the control, and the exclusion keeps pairing, with the
switch off. The players list marks such a player "no bye".

- **Swiss, Ainalrami only.** Round robin, Keizer and team Swiss have no
  pairing-allocated bye to withhold and do not show it. With JaVaFo
  selected the form says it is not available and why, in one line; JaVaFo
  is never handed it.
- **Always warned.** Every time it is ticked the form says it is not a FIDE
  rule and what that costs; on a FIDE-homologated tournament it adds the
  stronger warning that the tournament's FIDE record will say so.

**What the engine does with it.** `Pairing.with_bye_exclusions/4` turns the
round's pairing pool into engine ranks and hands them to Ainalrami as
`:bye_exclusions` (Ainalrami v0.33.0 and later). Each is treated exactly as
C.04.3 [C2] treats a player who already had a pairing-allocated bye:
ineligible for the bye, and for nothing else. An exclusion that does not
bite - the player was never going to get the bye - pairs the round exactly
as no exclusion does, byte for byte, and records nothing. Ainalrami's own
validation of the option is in its README ("Organiser deviations").

**When no legal round keeps the bye away from every excluded player.** The
engine says so as data (`{:error, {:bye_exclusions, %{excluded:, override:}}}`),
and the Pairings page names the excluded players and offers one button,
"Pair anyway, ignoring the exclusion for X" - X being the player who takes
the bye when the round is paired with no exclusion at all, whose exclusion
is therefore the one whose lifting is certain to work. It re-pairs with
that player's exclusion lifted for this round only (`pair_next_round/2`'s
`bye_exclusion_override:`); the setting itself is untouched, and the audit
trail records `pairing.bye_exclusion_overridden`.

**What is recorded.** The round's stored explanation carries the exclusions
it was paired under, who was passed over for the bye because of one ("X was
passed over for the bye: organiser exclusion", in the order they would have
had it - worked out in the pairing click by the engine's own chain, see
"The engine's account, after the click" below), and a lifted exclusion. A re-explained
round reads its exclusions back from that record, not from today's player
settings. When an exclusion actually moved the bye, the audit trail records
`pairing.bye_passed_over`, and the tournament's FIDE record
(`fide_compliance_lost_round`, the same column a non-FIDE setting stamps)
names that round the first time it happens, with a
`tournament.fide_compliance_lost` row (setting `no_bye`). The Export page's
TRF section lists those rounds: the TRF has no way to carry the exclusion,
so a checker replaying the file pairs them as FIDE's rules would.

**Carried by** JSON backups, snapshots, hand-offs and Duplicate (all one
export/import path, `TournamentExport`'s player fields). Not by SWAR, which
has no such field.

### Bye preferences - "must get", "rather gets", "rather not" (not a FIDE rule)

Three more settings per player beside the exclusion, which is the fourth
("must not get it"). Like it, they are an organiser's wish, **not part of
the FIDE rules**: a round they change differs from what a FIDE-endorsed
program pairs, and a FIDE checker replaying the TRF will not reproduce it.

| setting | what it does | what it never does |
|---|---|---|
| **Must get it** (`want_hard`) | whenever the round has a pairing-allocated bye, this player gets it - even on a higher score - as long as the rest can still be paired under the absolute criteria | break C1/C3, a forbidden pairing, or C2 - see "A second pairing-allocated bye" below |
| **Rather gets it** (`want_soft`) | among the players on the score that gets the bye, this one gets it | lift the bye to a higher score, or leave the round unpairable |
| **Rather not** (`avoid_soft`) | another player on the score that gets the bye takes it, if any can | the same |
| **Must not get it** | the bye exclusion above, unchanged | - |

**Where the soft ones sit in the criteria.** Exactly where a "Rather not,
if possible" pair wish sits in its strong position: directly below the
ladder's top rung - the absolute criteria, completing the round, and the
bye's own rules (C2; the bye to the lowest score that still lets the rest
be paired) - and above every quality criterion, C6 to C21 (C9, the bye
holder's unplayed games, included) and the final ordering rule. So they
decide *who on the bye score* gets it, and the brackets are paired as well
as the criteria allow around that choice. The tournament's "weak" position
for pair wishes does not apply to them: below C21 there is practically
never a choice of bye holder left to make.

**Where it is.** Behind its own switch, "Bye preferences", in the account's
features under "Pairing options" - off by default, and in no federation's
pack (`Features.general/0`); the bye exclusion stays in the BEL pack. With
it on, a player's details have, under the exclusion, "Pairing-allocated
bye preference", then "All rounds" or "Certain rounds" typed like the
absences (`players.bye_preference`, `players.bye_preference_rounds`). Like
every switch it owns the entrance only: a player who already has a
preference keeps the control, and the preference keeps pairing, with the
switch off. Every time one is chosen
the form says it is not a FIDE rule and what the chosen one does; the
players list tags such a player "bye: must", "bye: rather" or "bye: rather
not". Swiss with Ainalrami only; with JaVaFo a stored one gets a one-line
"not applied", and round robin, Keizer and team Swiss do not show it.

**Never on a FIDE-rated tournament.** With "FIDE-homologated" ticked the
form does not offer them. If the tournament becomes FIDE-rated while
players have one, nothing is deleted: the pairing ignores them, the player
form shows the stored one as ignored, the players list greys its tag, and
the Pairings page names the players whose preferences are being ignored.
Untick it and they apply again. (The exclusion is unchanged by this: it
keeps working on a FIDE-homologated tournament, with its stronger warning,
as it always did.)

**A second pairing-allocated bye.** FIDE's rule C2 gives nobody a second
pairing-allocated bye (nor one after a forfeit win or a full-point bye),
and "must get it" never overrides that - nor is it silently skipped.
Setting "must get it" for rounds after the one where the player already had
the bye is refused when the player is saved, naming that round. A stored
one that became impossible - typically "must get it, all rounds" once it
has given the player the bye - makes the Pairings page refuse to pair the
round it would apply to: nothing is paired, and the page names the player,
the round of their earlier bye and rule C2, and asks for the preference to
be changed first (Ainalrami's `RefusedError`). "Rather gets it" for such a
player is only reported, and the round paired.

**Conflicts.** Wanting the bye in a round where the player is excluded
from it is refused when the player is saved, naming the rounds. In the
engine (`Ainalrami.ByePreference`, which a TRF-driven or CLI caller can
also reach): for one player, an exclusion beats any want, "must get"
beats "rather not", "rather gets" and "rather not" cancel out; across
players, "must get" goes first - with two of them the FIDE criteria choose
between them - then "rather gets", then "rather not". On an even field
there is no bye to give, and a player not in the round is skipped - both
reported, not silently dropped.

**"Why not me".** On the explanation page's "why the bye went to X", a
player a bye preference kept from the bye reads "not allowed a bye - bye
preference, not a FIDE rule", never "organiser exclusion", which stays the
bye exclusion's.

**What the engine does.** `Pairing.with_bye_exclusions/4` also collects the
round's preferences (`bye_preference_ranks/4`) and Ainalrami resolves them
into bye exclusions (Ainalrami's `bye_preferences:` option): a want pairs
the round with every other active player kept from the bye, and a soft one
keeps that round only if its bye holder is on the score the round without
preferences gives the bye to. The explanation and the "why him and not me"
answers are then worked out under those exclusions, so they judge the round
by the rules it was paired by.

**What is recorded.** The round's explanation carries a `"bye_preference"`
record: whether the preferences changed the round, who got the bye, who
would have had it by the FIDE rules alone, the extra players they kept from
the bye (so a re-explained round is judged the same way), and what
happened to each preference. When a "must get it" could not be honoured,
the Pairings page says so under the boards ("... no legal pairing gives it
to them: the round was paired as without the preference"), as it does for
every preference that was not applied and why; the round explanation says
the same, and the audit trail records `pairing.bye_preference`. A round the
preferences changed is stamped on the tournament's FIDE record like an
exclusion's (`tournament.fide_compliance_lost`, setting `bye_preference`),
and the Export page's TRF section lists it. A preference that changed
nothing records no deviation.

**Carried by** JSON backups, snapshots, hand-offs and Duplicate. Not by
SWAR.

### The engine's account, after the click

Ainalrami's account of a round - the brackets it built
(`Ainalrami.Pairing.explain_round/3`) and, for every float and the bye, what
each other candidate would have cost (`Ainalrami.Alternatives`, one forced
re-pairing per candidate, capped at twelve) - is shown on the round's
explanation page. It used to be worked out inside the "Pair round" click,
before the round was saved. On a large field that was most of the click:
450 players, round 2, on the two-core server took 253 s, 235 of them the
alternatives. It is now worked out after the round is saved, by
`PairingsEngine.ExplanationJobs`.

**What stays in the click, and why.** Everything that decides or records the
round:

- the pairing itself, and the round, its boards and byes, in one transaction;
- the two organiser-deviation checks, each a second pairing run that only
  happens when its setting is in play: whether the "only if possible" wishes
  moved a board (`soft_pairs_moved?/4`), and who a bye exclusion passed over
  (`bye_passed_over/4`, the same chain the engine's `explain_round/3` runs).
  The round's `fide_compliance_lost_round` stamp and the
  `tournament.fide_compliance_lost` / `pairing.bye_passed_over` audit rows
  are written from these the moment the round is saved, so they cannot wait.
  Moving them to the background was considered and rejected: the stamp
  would be right in the end, but the Pairings page and the audit rows read
  it in between, and a tournament would briefly claim compliance it had
  lost;
- the bye-exclusion refusal and its "Pair anyway" override (a refusal is the
  pairing failing, so there is nothing to explain yet);
- the `pairing.round_paired` audit entry.

**The pending record.** The round is saved with
`explanation: %{"status" => "pending", "job" => fingerprint, "sections" => [...]}`,
each section holding its category, the players it paired (`"field"`) and the
deviation facts above - but no brackets, which is what makes
`PairingsEngine.RoundExplanation` read it as "no account yet". So
`pairing_deviations/2`, `RoundExplanation.bye_exclusion_rounds/1` and the
audit rows read the same record before and after the job.

**The job.** One supervised task per round
(`PairingsEngine.ExplanationTaskSupervisor`, registered by round id in
`PairingsEngine.ExplanationJobRegistry`), at low scheduler priority so pages
keep answering on two cores, working from the very field the engine just
paired. Its result is written only if the round still holds the pending
record with that fingerprint (one guarded `UPDATE`): a round unpaired,
re-paired or restored meanwhile no longer does, and a late result is
dropped. The fingerprint has a random part because SQLite reuses the
highest row id after a delete - a re-paired round can have the old one's
id. Unpairing also stops the job. When the account is stored (or the job
fails) `{:tournament_changed, id, :explanation}` goes out on the
tournament's topic; the Pairings page updates its note from the one column,
the explanation page reloads its account.

**Failure and restart.** A job that raises, exits or runs past 30 minutes
marks the record `"failed"`: the page says so and offers "Try again", which
works the account out from the round's history. A job lost with the node
leaves the record `"pending"` with nobody on it; the explanation page
notices (`Pairing.ensure_explanation/2`) and starts it again - from the
round's history (`Pairing.recompute_explanation/2`: the field rebuilt as it
stood before the round, section by section from each section's `"field"`,
the boards as played) - and while it waits it looks again every fifteen
seconds, so it never shows "working" with nothing working. A rebuilt account
is marked `"origin": "recomputed"`, like a Recompute.

**Rounds paired before this.** Their records have no `"status"`; they read,
recompute and deepen exactly as before. `Pairing.reexplain_status/2` says
`:pending` or `:failed` for a round whose job owns it, and Recompute and
"Work it out now" leave such a round alone.

### The alternatives, when opened (since 2026-09-28)

Most arbiters never open "why did HE float and not me". So the job above
now works out the cheap part only - `explain_round/3` with
`bye_passed_over: false`, the brackets and their criteria - and each
alternative is worked out when somebody opens that question on the
explanation page. 451 players at `+S 2:2`
(`test/bench/pairing_click_bench_test.exs`): the explanation is ready
0.24-0.42 s after the click returns, rounds 1-5; an opened question takes
about 0.3-0.4 s to rebuild its field plus about 2.3 s per candidate (one
full re-pairing each) - 4.6 s for a float with two candidates, 9.6 s for a
bye with four. Past the cap of twelve candidates the answer says so at once
and offers "Work it out now" for that one question.

**The record (version 4).** `"alternatives" => "on_demand"`, no
`"float_alternatives"` and no `"bye"` answers; each section keeps the pairs
the engine made (`"pairs"`, player ids, board order) and `"bye_holder"`,
and the finished record keeps the pending one's `"job"` fingerprint (the
job's guarded write now also asks for `"status"` pending or failed, so a
finished account is never written over). The questions are named by their
place in the record - `"bye/<section>"`,
`"float/<section>/<bracket>/<player id>"` - and checked against it
(`RoundExplanation.parse_question/2`), never trusted from the page.

**One question.** `Pairing.open_alternative/4` rebuilds that section's field
as it stood before the round (the same rebuild as a restart's recompute),
takes the pairs from the record rather than the boards - a board changed by
hand since is not what the account describes, and the page already says so
- and asks the engine that one question: `Ainalrami.Alternatives.bye_alternatives/3`
for the bye, and for a float `Ainalrami.Alternatives.float_alternative/5`
(through `Explainer.float_question/5`), the engine's own one-floater entry
of `float_alternatives/3` - Ainalrami holds the two equal over generated
rounds, and `test/pairings_engine/alternatives_on_demand_test.exs` checks
them side by side on this app's own field once more. It runs as an `ExplanationJobs.run_alternative/5` job: supervised,
low priority, registered by `{:alternative, round id, question}` so a second
click or a second viewer joins it, the same timeout. The answer goes into
`round_alternatives` (round, job fingerprint, question, JSON), only while
the round still holds that finished account; a table of its own because
every write to `rounds` changes the standings cache key, and opening a
question changes no standing. Rows go with their round; a re-paired round
has another fingerprint, so an old answer is never read as its own.
Unpairing stops the round's question jobs too.

**The page.** Each question is a button (`aria-expanded`, `aria-controls`)
over a panel announced politely: "Working it out…" while the job runs, the
verdicts once stored, or "This could not be worked out" with "Try again".
News goes out on `ExplanationJobs.alternatives_topic/1`, not the tournament's
topic (a dozen pages reload on anything said there), as
`{:round_alternative, round id, fingerprint, question, :running | :ready | :failed}`,
so every open copy of the page follows. A page with something running looks
again every fifteen seconds: a question nobody is working on any more, and
with no answer, shows as failed rather than a spinner forever. The
compliance checks are not alternatives and stay in the click, as above.

Records of version 3 and earlier keep their alternatives inline and show
exactly as before; Recompute and the whole-round "Work it out now" still
write version 3.

**Tests** run the same work inline, before `pair_next_round/2` returns
(`config :pairings_engine, :explanation_jobs, :inline`), so every existing
assertion on a round's account still holds;
`test/pairings_engine/explanation_jobs_test.exs` and
`explanation_pending_live_test.exs` run it in the background against a
stand-in explainer (`PairingsEngine.Test.SlowExplainer`) they hold up or
break. `test/bench/pairing_click_bench_test.exs` (`--include bench`) times
the click on generated 301- and 451-player events.

## Round robin (Berger) - available

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
`(player count, cycles, round number)` - pairing round K always produces
the same result no matter when it's computed, which is the correctness
property a fixed schedule depends on.

**Odd player counts.** A phantom player numbered N+1 is added to make the
count even (FIDE's own rule: "where there is an odd number of players, the
highest number counts as a bye"). Whichever real player is scheduled
against the phantom that round gets a structural, **zero-point** bye
instead of a real pairing - recorded as a `"requested-zero"` row in the
`byes` table (TRF code `Z`), the same shape Swiss already uses for a
round-specific requested absence, with no corresponding `pairings` row.
Zero was chosen deliberately over `"pairing-allocated"` (a full point):
every player gets exactly one of these byes per cycle, so a full point
would just be an equally-distributed no-op at best and an unfair windfall
at worst if cycles don't complete evenly - zero keeps it neutral. Every
round has exactly one such bye (never zero, never two), since the
phantom's opponent is a bijection over rounds.

**Freezing pairing numbers.** Exactly like Swiss, pairing numbers are
assigned once - highest rating first, name as the tie-break (FIDE
C.04.2.B) - on the first call to `pair_next_round/1` for the tournament,
then frozen forever. Unlike Swiss, round robin never assigns numbers to
anyone afterward: the Berger table is fixed the moment round 1 is paired,
and there's no way to slot a newcomer into an already-computed schedule
without changing every other player's opponents round by round. **Players
who join after that first pairing are simply excluded from the schedule
for the rest of the tournament** - they never receive a `pairing_number`
via this path and never appear in any later round-robin round.

**SWAR's own table, exactly.** SWAR's `GenerationBerger` (`PairingRobin.cpp`,
SWAR v6.65) produces the same table as `schedule/3`, colours included -
checked for every field size from 2 to 30 against a literal port of it - and
SWAR's "double rounds" (`ROBIN_DBL`) and "aller-retour" (`ROBIN_AR`) are
match format and the double cycle here. SWAR numbers each table by the
players' `Rank`, and a SWAR import makes that order the pairing numbers
(`SwarImport.prepare_players/1`), so a round robin continued here from a
SWAR file pairs the rounds SWAR would have: for every single-table round
robin among the SWAR files at hand (ten files, 114 rounds), the table built
from the imported pairing numbers is, round for round, the one SWAR paired
into the file. Such a round robin also keeps SWAR's free round - a bye
board worth the full point SWAR forces on it (docs/swar-import.md) - rather
than this app's zero-point one, so its rounds all score the same way.

**One table per category.** With categories on and "Pair each category
independently" set, every category gets its own Berger table, numbered by
pairing number within the category, all paired into one round with the
boards running on from category to category (`RoundRobin.schedule_groups/2`)
- SWAR's round robin with separate categories, where each group of a club
event is its own round robin. The tournament lasts as long as its largest
table; a category of one player gets no table. Board numbers are this
app's, lowest number first, not SWAR's table order.

**Absences don't change the schedule.** A player marked absent for a
specific round (or withdrawn/forfeited entirely) still appears in the
schedule every round after the freeze - round robin never pulls someone
out and re-derives pairings around them, because that would ripple through
everyone else's opponents for that round. The arbiter records a forfeit
result for their games instead, the same way any other forfeit is
entered.

**Cross table print.** `GET /t/:id/print/crosstable` renders the classic
players×players round-robin grid (rows/columns ordered by `pairing_number`,
one cell per opponent, both cycles shown for a double round robin) instead
of the round-by-round Swiss cross table Swiss/Keizer tournaments get - see
`docs/printing.md`.

## Keizer - available

A Dutch/Belgian club-league style system (as used by PairTwo and similar
SWAR-adjacent software): players sit on a running "Keizer list" rather than
a fixed bracket, each rung worth a points value, and every round they're
paired against others close to them on that list. See
`PairingsEngine.Keizer` for the full algorithm; summarized:

* **The ladder.** With `N` schedulable players and a "top" cutoff value `T`
  (`keizer_top_value` - blank/nil means automatic, `2 × N`, floored at
  `N + 1` so the bottom rung never goes to zero or negative), the player
  ranked `i` (1-based, best first) is worth `T - (i - 1)`. Before round 1
  the ranking is simply rating descending (name ascending as the tiebreak).

* **Scoring**, given the *current* ladder values: a win is worth the
  opponent's value, a draw half of it, a loss nothing. A forfeit win (no
  game played) is worth half the player's own value - same as an unpaired
  (odd-count) bye. A forfeit loss, double forfeit, or a played "0-0" is
  worth nothing. An excused absence (the player's `Absent` flag, or the
  round listed in `absent_rounds`) is worth a third of the player's own
  value. Rounds before a player's `start_round` are worth nothing - also
  when the Swiss setting "Rounds before a late entrant joins count as
  absences" is on: the ladder pays an excused absence a third of the
  player's own value, never the absence points that setting uses.

* **Retroactive recalculation** is the signature Keizer feature: nothing
  Keizer-specific is ever stored in the database - only results, byes and
  absences are - so the whole ladder is recomputed from scratch every time
  it's needed. Ranking and scoring are mutually dependent, so this is a
  fixed point: assign values from the current order, score every round
  played so far with those values, re-rank by total Keizer points (ties:
  rating descending, then name), reassign values, rescore - repeat until
  the order stops changing or 20 iterations, whichever comes first (a
  20-iteration cap guards against a pathological oscillation; whichever
  order the last iteration produced is used). Because every round is
  rescored with the *current* values on every pass, an opponent you beat
  early on who later climbs the list keeps increasing what that early win
  is worth - nothing is ever "locked in".

* **Pairing numbers.** Exactly like Swiss (and reusing that same code -
  `PairingsEngine.Pairing.ensure_pairing_numbers/2`), a Keizer tournament
  freezes `pairing_number` over its active players the first time it pairs a
  round - highest rating first, name ascending as the tie-break - and never
  reassigns one once set; a newcomer gets a number the next time a round is
  paired. Nothing about the Keizer ladder itself depends on this number -
  it's purely what the crosstable print and the player grid's "Nr" column
  show. (Before this, Keizer tournaments never assigned pairing numbers at
  all, so those views showed "?" for every Keizer player.)

* **Pairing** the next round takes that recalculated order, drops anyone
  not eligible this round (same eligibility Swiss pairing uses - an
  absence, permanent or round-specific, scores the excused-absence
  fraction above instead of being paired), then walks top-down pairing
  each unpaired player with the nearest unpaired player below them they
  haven't already played, backtracking when that leads to a dead end
  further down the list. A `forbidden_pairings` pair (see
  `docs/forbidden-pairings.md`) is never paired; if a repeat is truly
  unavoidable, the pair repeated longest ago is preferred over failing
  outright. An odd count gives the bye to the lowest-ranked player it can
  - if that specific player's bye would leave the rest impossible to pair,
  the next-lowest-ranked candidate is tried instead.

* **Colours.** The player with fewer games as White so far gets White;
  tied, the lower-ranked player (further down the list) gets White. Colour
  is never a reason to reject a pairing.

* **Standings** for a Keizer tournament show the Keizer ladder (rank, name,
  rating, current value, Keizer points, and the same games under ordinary
  FIDE-style scoring for comparison) instead of the FIDE tiebreak table -
  FIDE tiebreaks (Buchholz, Sonneborn-Berger, etc.) don't apply to a Keizer
  ladder. See `PairingsEngine.Keizer.standings/2` (accepts `through_round:
  n`, same idea as `PairingsEngine.Standings.standings/2`), and every
  standings-shaped view - `StandingsLive`, `PublicStandingsLive`,
  `LiveRoundLive` (the `/t/:id/live` projector page) and the standings print
  document (`PairingsEngineWeb.PrintController.standings/2`, including its
  per-category tables) - which all render this table instead of the usual
  one whenever `pairing_system == "keizer"`.

Implemented in `PairingsEngine.Keizer.pair_next_round/1`, dispatched to the
same way as every other pairing system (see above).

## Changing the pairing system mid-tournament

`pairing_system` is locked once the tournament has paired its first round:
switching systems after rounds have already been paired by a different one
would leave a mixed, likely-inconsistent pairing history. The lock lives in
`Tournaments.locked_fields/1` and is enforced inside `update_tournament/2`,
which is what the Settings page's disabled select renders from - one rule,
one place, so the two can't drift.

`pairing_engine` (the Swiss engine - see above) locks on exactly the same
condition and for the same reason one level down: JaVaFo and Ainalrami are
two independent implementations of the Dutch system, and a round already on
the board was decided by whichever one was configured at the time.

`rr_cycles` (round robin only) locks separately once the number of paired
rounds reaches what the *current* cycles setting implies a round-robin
schedule needs - roughly `(player_count - 1) * rr_cycles` rounds. Before
that point it stays editable.

`keizer_top_value` has no lock - it can be changed at any time, including
mid-tournament, since it only affects how far down the Keizer list players
are still paired.
