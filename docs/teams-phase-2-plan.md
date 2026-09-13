# Team Swiss (C.04.6) - phase 2 plan

> **Built 2026-09-13.** What was built is described in
> [`team-tournaments.md`](team-tournaments.md); this plan is kept as the
> design it came from. Where the build departed from it:
>
> - **The initial colour** is not "default White": the maintainer decided it
>   is drawn by lot by default (and settable), for individual Swiss too.
>   JaVaFo turned out not to read `152`, so the engine TRF carries `XXC`.
> - **Old events are told apart by a stored flag**, `team_pairing_mode`, set
>   by a migration and at first pairing, rather than by refusing team pairing
>   when round 1 exists without matches (B1): such an event is simply routed
>   to the individual path, which is what "keep pairing them as before" asks.
> - **The engine had more to fix than A1-A4.** [C4] was below [C5], [C3] was
>   never judged outside the bracket, [C6] and [C7] had no effect, an even
>   scoregroup could never take upfloaters, and [C10] counted per pair.
> - **Questions 5-7** were answered by a research note (Ainalrami's
>   `docs/conformance-c0406-teams.md`, "Research findings"), not the SPP.
>   Q5: [C5]'s profile is judged among legal sets. Q6: a match won by forfeit
>   is one in which no game was played. Q7: [C7] is minimised before 3.5.4's
>   order.
> - **"Floated last round"** reads the pairing (a forfeited match still
>   floated its teams); **a team with no available player** sits the round
>   out and is passed as `:absent`.
> - **Article 16** follows the C.07 text for the forfeit cap (16.4.1) and for
>   trailing forfeit losses, where the individual `Standings` it was to be
>   modelled on differs slightly; see `team-tournaments.md`.
> - **B7, the explanation**, was stored in a follow-up (2026-09-14): see
>   "The round's account" in `team-tournaments.md`. The same pass rebuilt
>   matches on TRF import, attached hand-added boards to matches, and added
>   the match forfeited by decision.

Phase 1 (the team round robin, [`team-tournaments.md`](team-tournaments.md))
is built. This is the plan for phase 2: pairing a **team Swiss** team against
team under FIDE C.04.6, with board-by-board matches exactly as phase 1 builds
them. Written 2026-09-13, when phase 1 was finished and phase 2 not started.

## The starting point is further along than the brief assumed

The brief for this work said to implement C.04.6 in Ainalrami. **A first cut
already exists there**, on Ainalrami's `main` since 2026-08-26 and inside the
version this app pins (v0.26.1, `deps/ainalrami/lib/ainalrami/team_pairing*`):

- `Ainalrami.TeamPairing.pair_round/2` - Article 3.3's procedure: the
  pairing-allocated bye (3.4), upfloater sets (3.5), brackets, colours.
- `TeamPairing.Bracket` - Article 3.6: the first pairing in identifier order
  that minimises `{C8, C9, C10}`, walked lazily with prefix pruning and a
  step budget.
- `TeamPairing.Team` - Articles 1.6 and 1.7: colour difference, Type A and
  Type B preferences, [C2] bye eligibility.
- `TeamPairing.Colour` - Article 4, including 4.3.1's TPN parity on the
  numbering that skips teams never paired (the SPP's 2026-08-27 ruling).
- `TeamPairing.Matching` - the [C3] completability oracle.
- `test/ainalrami/team_pairing_test.exs` (888 lines) - including the
  small-bracket proof: enumerate every pairing, sort by identifier, filter by
  the criteria, assert the engine returns the head.

So phase 2 is not "write the engine". It is: close the engine's open
questions, add the validation the brief asks for that is not there yet, and
wire it into OpenPairings.

## Why it was not started in this pass

1. The brief's order is phase 1 complete, then phase 2. Phase 1 took the
   pass, with its tests, docs and translations.
2. Ainalrami changes are required first (the absent-team defect below), and
   they belong in an Ainalrami branch with its own version tag before this
   app pins them. This pass ran isolated in an OpenPairings worktree, where
   git operations on another repository were refused, so no Ainalrami branch
   could be made from here.

## Design

### A. Ainalrami (branch `team-swiss`, then a tag)

1. **The absent team's number (open defect in the conformance doc).**
   `pair_round/2` cannot tell "never arrived" from "arrived, not playing
   this round", so a team that has played and then sits a round out loses
   its 4.3.1 parity position. Add a `:roster` (or `:absent`) option listing
   teams that have arrived but are not in this round's field, so
   `Colour` numbers the arrivals the way the individual side does after the
   SPP ruling.
2. **Match-level forfeit.** [C2] bars a team that "won a match by forfeit"
   from the bye. `%Team{won_by_forfeit?: true}` exists; what is missing is
   the host's definition. Proposal: a match counts as won by forfeit when
   every board the opponent should have filled is a forfeit - i.e. the
   opponent did not turn up as a team. That is OpenPairings' to compute
   (see B3) and Ainalrami's to document.
3. **[C7] as a ranking pass**, per the conformance doc's reading decision -
   decide, test both readings, record the choice.
4. **[C5] versus the 3.5.4 example** - keep following the article; add the
   question to the SPP list (see "Open questions").

### B. OpenPairings

1. **Dispatch.** `Pairing.pair_next_round/1`: a tournament where
   `type == "team-swiss"` goes to a new `PairingsEngine.TeamSwiss` before the
   Swiss path. Today that type pairs player by player; the Teams page says
   so. Existing team-Swiss tournaments with individually paired rounds
   cannot be converted mid-event - refuse team pairing when round 1 already
   exists without matches, with a message, and keep pairing them as before.
2. **Team numbers.** Reuse phase 1's freeze (`teams.pairing_number` from the
   Teams page's seeding order). C.04.6 1.1.3 allows late entries to change
   TPNs only per General Handling 2.4/2.5; follow the individual Swiss rule
   (numbers assigned to newcomers after the freeze, never renumbered after
   round 4).
3. **Building `%Ainalrami.TeamPairing.Team{}` per round**, from
   `TeamStandings.matches/2` through the previous round:
   - `match_points` / `game_points` - including the PAB's points (below);
   - `opponents` - team TPNs met;
   - `colours` - the team's board-1 colour in each match **actually
     played** (1.6.1). Team A of a match has White on board 1 (phase 1's
     convention), so this is `:white` for team A and `:black` for team B;
     a bye or a fully forfeited match adds nothing;
   - `had_pab?` - a previous round's bye match;
   - `won_by_forfeit?` - A2 above;
   - `floated_last_round?` - the previous round's opponent had a different
     primary score before that round.
   Options: `score_mode: :match_points`, `type: :a`,
   `round:`/`expected_rounds:` from the tournament, `initial_colour:` from a
   new setting drawn before round 1 (default White, as the individual
   engine).
4. **Writing the round.** Reuse `TeamRoundRobin`'s writer: extract its
   `create_round/4` into a shared `PairingsEngine.TeamRounds` taking
   `[{:pairing, white_tpn, black_tpn} | {:bye, tpn}]`. Ainalrami's pairs are
   already `%{white: tpn, black: tpn}`, so the white team becomes team A
   and phase 1's board-by-board line-ups, forfeits and board numbering apply
   unchanged.
5. **The pairing-allocated bye pays** "as many match points and game points
   as are rewarded for a draw" (1.4). Unlike a round robin's bye it scores:
   `TeamStandings` gives a Swiss bye match `mp = team_match_points_draw` and
   `gp = team_boards x points_draw` (what a match drawn on every board
   pays). Add a `team_bye_*` setting only if a competition asks; the
   FIDE-safe default is the draw.
6. **Team tie-breaks under C.07 Article 16.** A Swiss makes unplayed rounds
   matter. `TeamStandings` needs, for BH/SB/EMGSB: the opponent's adjusted
   score (16.3 - a trailing voluntary unplayed round counts as a draw), and
   the team's own unplayed rounds as a dummy opponent capped per 16.4 - in
   match points AND game points ("for team competitions, points means match
   points and game points"). The individual implementation in
   `Standings.adjusted_score/2` and `dummy_score/3` is the model. Team
   events' voluntary unplayed rounds are rare (a team withdrawing), so the
   PAB (16.2.1) is the common case.
7. **Explanation.** `pair_round/2` returns `brackets`; store them on
   `rounds.explanation` like the individual engine, and show them on the
   rationale page later (not needed for a first release).
8. **Publishing** stays refused, as in phase 1, until OpenResults has team
   pages.

## Test strategy

There is no reference implementation to diff against (not bbpPairings,
JaVaFo, Gacrux or SWAR; Swiss-Manager is closed). The regulation defines the
answer as the head of an enumerable order, so the tests can be the
definition.

**In Ainalrami:**

1. **Brute-force head, as a property test.** StreamData generates small
   fields (4-10 teams) with random histories (scores, opponents, colours,
   byes, floats) that are reachable - built by playing random earlier
   rounds through the engine itself. For each, enumerate every legal round
   pairing, apply 3.4 (bye), 3.5 (upfloaters) and 3.6 by brute force in
   plain code written from the text, and assert `pair_round/2` returns the
   same pairs and bye. This exists for single brackets; extend it to whole
   rounds.
2. **Absolute criteria always hold**, at every size up to ~60 teams:
   no rematch ([C1]), no second bye or bye after a forfeit win ([C2]), every
   team paired except at most one ([C3]), and colours valid.
3. **Colour rules as properties**: 4.3.1 parity on first meetings (with
   absent teams, A1), 4.3.2-4.3.9 order checked on generated pairs with a
   reference implementation of Article 4 written separately from `Colour`.
4. **Hand-worked examples from the text**: 3.5.4's set ordering example
   (already pinned) and 3.6.2's identifier example (`11-24 16-6 10-9 8-4`
   -> `4 6 9 11 8 16 10 24`).
5. **Fuzz for crashes and budget exhaustion** on the fuzz server for large
   fields - the corpus role that survives without an oracle.

**In OpenPairings:**

1. `TeamSwiss` builds the right `%Team{}` structs from stored matches
   (colours from team A/B, bye, forfeit-won match, floats) - unit tests on
   hand-made histories.
2. A 6-team, 5-round event paired end to end with scripted results: every
   round satisfies [C1]-[C3] as seen from the database; the bye team's
   standings row gets draw points.
3. Team tie-breaks under Article 16 with hand-computed examples: a PAB, a
   withdrawn team's trailing rounds, Cut-1 is not in scope unless asked.
4. The existing suite proves individual tournaments unchanged, and phase 1's
   tests prove the round robin unchanged by the shared writer.
5. Mutation-check the bye scoring and the Article 16 adjustment.

## Open questions

For the maintainer:

1. **Initial colour (C.04.6 4.1)** - drawn by lot before round 1. Store it
   per tournament and default to White (like the individual engine), or ask
   the arbiter at the first pairing?
2. **Existing team-Swiss tournaments** paired player by player - leave them
   on the individual path forever (proposed), or offer a conversion?
3. **Type B colour preferences, game points as primary score** - C.04.6
   1.2.1/1.7 make both competition options. Expose them in Settings in
   phase 2, or ship the FIDE defaults only (proposed: defaults only)?
4. **Team pages on OpenResults** - phase 2, or a phase of their own?

For the FIDE SPP (the maintainer sends these; wording ready):

5. "C.04.6 Article 2.3.2 [C5] says to maximise the scores of the upfloaters,
   yet the example under Article 3.5.4 takes two 3-point teams and one
   2.5-point team when three 3-point teams (2, 6, 8) are available. Is the
   example applying a constraint not stated in 2.3.2 (for instance [C6],
   which switches off when the scoregroup empties), or should [C5] take all
   three 3-point teams?"
6. "C.04.6 Article 2.1.2 [C2] bars from the pairing-allocated bye a team
   that 'won a match by forfeit'. Is a match won by forfeit one in which the
   opponent forfeited every board, or one in which the opponent forfeited
   the match as a whole by regulation, regardless of how many boards were
   played?"
7. "C.04.6 Article 3.5.5 asks for the first set of upfloaters that complies
   with [C6] and [C7]. [C7] is a minimisation. Should the sets be ranked by
   their [C7] count before the lexicographic order of 3.5.4 is applied, or
   is the first set in 3.5.4's order that achieves the minimum number
   intended?"
