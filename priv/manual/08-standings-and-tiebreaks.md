# Standings and tie-breaks

## The Standings page

**Standings** shows the ranking after the rounds played. For a Swiss tournament
the table has the rank, the name, the rating, the points, and one column for
every tie-break of the tournament, in the order in which they are applied.
The page header says *Standings after round N*. Players still level after
every tie-break are ordered by rating and name, or share a place, as the
setting *Players still level share a place* says (see below).

- The **Category** filter above the table shows one category at a time
  ([Categories and norms](13-categories-and-norms.md)).
- The column *Rds* (rounds present) and the extra-points columns appear
  when they are switched on (Players page, *Display*).
- **W-We** and **We** (FIDE's expected score and the difference with the
  actual score, Table 8.1.2) can be shown.
- A Keizer tournament shows the Keizer table (rank, name, rating, value,
  Keizer points) instead of the tie-break table.
- Under a heading *Not final* the page warns when a game is postponed and
  still to be played, or when boards have no result.
- A player who withdrew keeps their row, with the points scored so far, and is
  marked *withdrawn* beside the name (also in the printed standings). In a
  round robin the rule below can take such a player's results out.
- **Print** opens the standings as a document; **Public page** opens the
  published page of a published tournament.

The standings are recalculated from the games every time they are needed, so
they are always in step with the results.

### Standings after an earlier round

The page always shows the standings after the latest paired round. The
printed standings can be made for an earlier round by adding `?round=N` to
the address of the print page ([Printing](09-printing.md)): only the games of
rounds 1 to N count, with the byes of those rounds.

## Points and scoring

A win scores 1, a draw ½ and a loss 0 unless the Scoring page says otherwise
(any values can be set, including the 3-1-0 system, but not before the
first round in FIDE mode: see [Tournament set-up](03-tournament-setup.md)). A
pairing-allocated bye scores as set on the Scoring page; an absence scores
as set there too ([Byes and absences](05-byes-and-absences.md)). Extra points
(administrative bonus points) are added only if the tournament counts them.
The tie-breaks of C.07 always use the game points of the opponents, never the
extra points.

## Tie-breaks

The tie-breaks decide the order of players who have the same number of
points. They are set on Settings, **Tournament**, section *Tiebreaks*. The
program follows FIDE's C.07 (Tie-Break Regulations, 1 March 2026), and the
calculations are done by the same engine that pairs the Swiss rounds.

### Choosing

- **Preset.** A preset fills the list at once: *FIDE Round Robin* (DE, WIN, SB,
  KS), *Disparate Swiss (wide rating range)* (BHC1, BH, SB), *Regular Swiss*
  (BHC1, BH, PS), *Old Swiss (classic)* (PS, BH, SB), or *Custom* for any list of
  your own. A new tournament starts with the default of FIDE for its type:
  individual Swiss BHC1, BH, SB, DE, WIN, PS; individual round robin DE, WIN,
  SB, KS; team events MP, GP, DE, BB, SB.
- **Add a tiebreak…** adds one from the list below; **Move up** and **Move
  down** change the order (the first one applies first); **Remove** takes one
  out. Without a tie-break, tied players share a place.
- The list can be changed until the first round is paired. In FIDE mode it
  is then locked, because the tie-breaks must be announced before the start
  ([FIDE mode](02-fide-mode.md)).

### The available tie-breaks

All the individual tie-breaks of C.07 can be selected. The *Add a tiebreak…*
list is grouped as below; the codes are C.07's own. Where a tie-break is
based on the rating, an unrated player is counted as described under *Rules
the program applies*.

**Results and games**

| Code | Name | Meaning |
| --- | --- | --- |
| DE | Direct encounter | The result(s) between the tied players. |
| DE/P | Direct encounter, forfeits counted | Direct encounter in which forfeit wins and losses count as games played. |
| WIN | Number of wins | Games won, forfeits included. |
| WON | Number of games won over the board | Without forfeits and byes. |
| BPG | Games played with Black | |
| BWG | Games won with Black | Over the board. |
| REP | Rounds effectively played | Rounds minus half-point byes, zero-point byes and forfeit losses. |
| STD | Standard points | One point per round scoring more than the opponent, half a point for the same. |
| TPN | Tournament pairing number | The lower number ranks higher. |
| TPN/R | Tournament pairing number, reversed | The higher number ranks higher. |
| EXT | External value | A value calculated outside the program: see below. |

**Buchholz**

| Code | Name | Meaning |
| --- | --- | --- |
| BH | Buchholz | Sum of the scores of the opponents. |
| BHC1 | Buchholz Cut-1 | Buchholz without the lowest opponent score. |
| BHC2 | Buchholz Cut-2 | Buchholz without the two lowest. |
| MBH | Median Buchholz | Buchholz without the highest and lowest. |
| BH/M2 | Median Buchholz, Median-2 | Buchholz without the two highest and the two lowest. |
| FB | Fore Buchholz | Buchholz as it stood before the last round: the last round counts as a draw for every opponent. |
| FB/C1, FB/C2 | Fore Buchholz Cut-1, Cut-2 | Fore Buchholz without the lowest one or two. |
| FB/M1, FB/M2 | Fore Median Buchholz, Median-2 | Fore Buchholz without the highest and lowest, or the two highest and two lowest. |
| AOB | Average of opponents' Buchholz | Average Buchholz of the opponents met over the board. |
| AOB/F | Average of opponents' Fore Buchholz | The same with Fore Buchholz. |

**Sonneborn-Berger and Koya**

| Code | Name | Meaning |
| --- | --- | --- |
| SB | Sonneborn-Berger | Scores of the beaten opponents plus half the scores of the drawn. |
| SB/C1, SB/C2 | Sonneborn-Berger Cut-1, Cut-2 | Without the contribution of the lowest one or two opponents. |
| KS | Koya system | Score against opponents who scored 50% or more. |
| KS/L1, KS/L2 | Koya system, limit 50% + ½ or + 1 | The qualifying limit raised by half a point or a point. |
| KS/L-1, KS/L-2 | Koya system, limit 50% - ½ or - 1 | The qualifying limit lowered by half a point or a point. |

**Progressive score**

| Code | Name | Meaning |
| --- | --- | --- |
| PS | Progressive score | Sum of the running score after each round. |
| PS/C1, PS/C2 | Progressive score Cut-1, Cut-2 | Without the running score of the first one or two rounds. |

**Rating-based**

| Code | Name | Meaning |
| --- | --- | --- |
| ARO | Average rating of opponents | |
| AROC1, ARO/C2 | ARO Cut-1, Cut-2 | Without the lowest-rated one or two opponents. |
| ARO/M1, ARO/M2 | ARO Median-1, Median-2 | Without the highest and lowest, or the two highest and two lowest. |
| TPR | Tournament performance rating | From the opponents' ratings and the score. |
| PTP | Perfect tournament performance | The lowest rating at which the score is expected or better. |
| APRO | Average performance rating of opponents | Average TPR of the opponents met over the board. |
| APPO | Average perfect performance of opponents | Average PTP of the opponents met over the board. |
| RTNG | Tournament rating | The player's rating, the higher the better. |
| RTNG/R | Tournament rating, reversed | The lower the better. |

Team events have their own list: MP (match points), GP (game points), EMGSB,
EGMSB, EGGSB, BH:GP, EDE, TBR, BBE, SSSC, BB (see [Teams](12-teams.md)). They
are the last group of the list.

### Rules the program applies

- **Unplayed games (C.07 Article 16).** A player's own unplayed rounds
  contribute a "virtual opponent" to Buchholz-type sums, and an opponent's
  score is adjusted for the games that opponent did not play. The program applies
  this in full, for byes, forfeits and absences. A setting on the
  Scoring page (*Treat a round sat out as a voluntary unplayed round*)
  chooses how absences count.
- **Rating-based tie-breaks and unrated players.** The rating-based
  tie-breaks (ARO and its cuts and medians, TPR, PTP, APRO, APPO, RTNG) are
  dropped when an unrated player is in the field, unless the tournament
  regulations say how an unrated player is counted. Say it in Settings,
  Tournament, *How an unrated player is counted in the tie-breaks*, before the
  first round:
  - *Fixed rating*: every unrated player counts as the rating typed in
    *Rating of an unrated player in the tie-breaks*; while that is empty,
    the rating-based tie-breaks are dropped.
  - *Lowest rating in the field*: every unrated player counts as the lowest
    rating of the tournament.
  - *Average rating of the rated players*: every unrated player counts as
    that average.

  The page says which tie-break was dropped and why. The number worked out is
  the one written to the tie-break line of the TRF, so a checker computes the
  same values.
- **Players still level after every tie-break.** *Players still level share
  a place* (Settings, Tournament): off (the default), the remaining ties are
  ordered by rating and then by name and numbered one after the other; on,
  they all show the same place, such as 2=, and the next place is skipped.
  A drawing of lots (below) can settle such ties instead.
- **Round robin.** Buchholz and the tie-breaks built on it (the Buchholz
  group above) are not used in a round robin (C.07 Article 8); the page says
  so.
- **Round robin, a player who withdrew early (C.05 6.6).** A player of an
  individual round robin who withdrew or was expelled having completed fewer
  than half of their games (over the board; forfeits and postponed games not
  yet played do not count) is taken out of the standings: their results stay
  in the cross table and count for rating, but not for anybody's score or
  tie-breaks. The player is shown after the others, with *-* for the place and
  the note *withdrawn, not counted*. At exactly half or more the results
  stay and count. The TRF report always keeps every game.

A tie-break that cannot be calculated for a tournament is not shown as a column
of zeros: it is dropped, with a note.

### The working of a tie-break

For team events the *Working* line under each value lists the contribution of
each round (the opponent, what it was worth, a forfeit, a bye). For individual
standings the same information is published to the results site (see
[Publishing](14-publishing.md)), where a reader can ask why they stand where
they do.

## Manual ranking (a hand-set order)

An arbiter may need to set an order by hand, for instance after a play-off
that was decided over the board. On the Standings page, **Enable manual
ranking** turns the tournament's order into a list that you can change:

- the order is first set from the current standings;
- each row has controls to move it up or down (*Reorder*);
- **Re-seed from current order** starts again from the computed standings;
- **Disable manual ranking** goes back to the computed order.

While it is on, a banner says *Manual ranking is ON* on every page, the print
and the public page that shows a rank. When a result or a bye changes after the
order was set, the banner says that the order may be out of date. Manual
ranking changes only the displayed order: it never touches the points, the
tie-breaks or the TRF report, so a rating officer replaying the file sees the
computed standings.

## Drawing of lots

When players are still level after every tie-break, **Draw lots for ties** on
the Standings page puts the players of each tied place in a random order and
records the result as the manual ranking above. The button is shown only while
somebody is level; it asks for confirmation first. Drawing again gives the
same order: the order depends on the players and on a number drawn once, the
first time lots are drawn, and kept with the tournament, so a draw cannot be
repeated until it pleases. Players who join a tie later, or ties that appear
because a result changed, are ordered by the same number. The draw is written
to the audit trail. It is not offered for Keizer or team tournaments.

## External tie-break values

A tournament that uses a tie-break the program does not calculate can add the
code **EXT** (*External value*) to its tie-break list. The Standings page
then shows a column in which you type, for each player, the value calculated
outside the program (a number, comma or point as decimal separator; empty
clears it). A higher value ranks higher. EXT is not a C.07 tie-break and is
not written to the TRF. The values can be typed until the tournament is
archived.

## Prize places

If categories have a **prize count** (Categories page), the places inside a
category that receive a prize are marked in the standings of that category.
This is informational: the program does not allocate prizes.
