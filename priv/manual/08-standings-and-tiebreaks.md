# Standings and tie-breaks

## The Standings page

**Standings** shows the ranking after the rounds played. For a Swiss tournament
the table has the rank, the name, the rating, the points, and one column for
every tie-break of the tournament, in the order in which they are applied.
The page header says *Standings after round N*. Players who tie on points and
on every tie-break share the same place.

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

| Code | Name | Meaning |
| --- | --- | --- |
| BH | Buchholz | Sum of the scores of the opponents. |
| BHC1 | Buchholz Cut-1 | Buchholz without the lowest opponent score. |
| BHC2 | Buchholz Cut-2 | Buchholz without the two lowest. |
| MBH | Median Buchholz | Buchholz without the highest and lowest. |
| SB | Sonneborn-Berger | Scores of the beaten opponents plus half the scores of the drawn. |
| DE | Direct encounter | The result(s) between the tied players. |
| WIN | Number of wins | Games won, forfeits included. |
| WON | Number of games won over the board | Without forfeits and byes. |
| BPG | Games played with Black | |
| PS | Progressive score | Sum of the running score after each round. |
| KS | Koya system | Score against opponents who scored 50% or more. |
| ARO | Average rating of opponents | |
| AROC1 | ARO Cut-1 | Without the lowest-rated opponent. |

Team events have their own list: MP (match points), GP (game points), EMGSB,
EGMSB, EGGSB, BH:GP, EDE, TBR, BBE, SSSC, BB (see [Teams](12-teams.md)).

### Rules the program applies

- **Unplayed games (C.07 Article 16).** A player's own unplayed rounds
  contribute a "virtual opponent" to Buchholz-type sums, and an opponent's
  score is adjusted for the games that opponent did not play. The program applies
  this in full, for byes, forfeits and absences. A setting on the
  Scoring page (*Treat a round sat out as a voluntary unplayed round*)
  chooses how absences count.
- **Rating-based tie-breaks and unrated players.** ARO and AROC1 are dropped when
  an unrated player is in the field, unless the tournament regulations say how
  unrated players are handled: then enter the rating an unrated player counts
  as in *Rating of an unrated player in the tie-breaks* (Settings, Tournament)
  and nothing is dropped. State the rule before the first round. The page says
  which tie-break was dropped and why.
- **Players still level after every tie-break.** *Players still level share a
  place* (Settings, Tournament): off, the remaining ties are ordered by rating
  and then by name and numbered one after the other (record a drawing of lots
  with the manual order below); on, they all show the same place, such as 2=,
  and the next place is skipped.
- **Round robin.** Buchholz and the tie-breaks built on it are not used in a
  round robin (C.07 Article 8); the page says so.

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

## Prize places

If categories have a **prize count** (Categories page), the places inside a
category that receive a prize are marked in the standings of that category.
This is informational: the program does not allocate prizes.
