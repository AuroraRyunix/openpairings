# Handing the tie-breaks to Ainalrami: what the comparison found

September 2026. Before OpenPairings computes its standings with Ainalrami's
tie-breaks (`Ainalrami.Tiebreaks`, a fresh C.07-2026 implementation that
FIDE's checker runs), the two were compared with `mix pairings.tiebreak_gate`
on every tournament available:

| source | tournaments | values | differences |
|---|---|---|---|
| the development database | 23 | 12,372 | 0 |
| Ainalrami-generated TRFs, imported through `TrfImport` | 1,000 | 267,468 | 20,045 + 18 orders, all explained below |

The adapter is faithful: for a generated file, Ainalrami's values straight
from the TRF and through OpenPairings' import and
`PairingsEngine.Standings.AinalramiBridge` are identical for every player.
Every difference is therefore OpenPairings' own, and FIDE's TieBreakServer
(the reference, used for validation only) sides with Ainalrami on each.

## 1. Forfeits counted as played games - a bug

`PairingsEngine.Standings` scores a forfeited round, won or lost, as if the
game had been played: the scheduled opponent's (adjusted) score goes into
Buchholz and Sonneborn-Berger, and a forfeit loss is never a voluntary
unplayed round for the Cut-1 exception. C.07 (effective 1 March 2026)
makes it an unplayed round: 16.2.2 and 16.2.4 categorise forfeits, 16.4
scores the round against a dummy whose score is the player's own, and
16.4.1 caps that at the scheduled opponent's adjusted score.

Example (`g10289`, Ainalrami seed 10289): the player on 1.5 points lost
round 1 by forfeit to the leader on 4.0. By C.07 the round contributes 1.5
to Buchholz; OpenPairings counted 4.0. BH 12.5 instead of 10.0.

Effect: in any tournament with a forfeit, Buchholz and Sonneborn-Berger (and
their cuts) can order tied players differently from C.07. 20,045 of the
267,468 values; the gate reproduces OpenPairings' rule exactly for every one
of them. Fixed by the switch.

## 2. Direct encounter only half implemented - a bug

`add_direct_encounter/2` takes each score group, and only when every player
in it has met every other, gives each the sum of their points against the
others; otherwise everyone gets 0. C.07 Article 6 also:

- reapplies the rule to every subset still tied (6.2);
- in a Swiss event where not all have met, ranks first a player who stays
  alone at the top whatever the missing games' results, then the next (6.3);
- averages, rather than sums, the games of two players who met more than
  once (6.1.2);
- applies to the group still tied at the point DE stands in the list, not
  always to the whole score group.

Effect: under "score, then DE", 17 of the 1,000 tournaments ranked a player
above one C.07 ranks higher (18 places). TieBreakServer agrees with
Ainalrami on all 17. Fixed by the switch.

## 3. The 16.4.2 cap part-way through an event - a reading

A bye's dummy is capped at "the points awarded for a draw multiplied by
the number of rounds in the tournament". OpenPairings used the announced
rounds, Ainalrami the rounds played so far. Final standings agree; before
the last round, a player with a pairing-allocated bye can differ by up to
half a point per missing round. Ainalrami's reading is the cap's purpose -
the score of a player who drew every game so far - and TieBreakServer's.
C.07 16.6 lets a competition choose, so Ainalrami keeps both
(`cap_rounds: :played | :announced`); OpenPairings uses the default.

## Reproducing

    mix pairings.tiebreak_gate                              # a database
    mix pairings.tiebreak_gate --trf DIR --limit 1000       # generated files

(in the Ainalrami repository: `mix run tools/tiebreak_corpus.exs DIR N SEED`
writes the files). The gate starts only the database - run it against a copy.
