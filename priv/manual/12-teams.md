# Team tournaments

A team tournament is one whose format is **Swiss (teams)** or **Round robin
(teams)**: tick **Team tournament** when you create it. Teams play matches; a
match is a set of individual games, board against board. The individual games
are ordinary games everywhere else (results, player cards, the FIDE rating
report), and the team layer is built on them.

Keizer cannot be a team tournament.

## Setting up

1. Create the tournament with *Team tournament* ticked.
2. **Teams** (a tab next to Players, shown for team tournaments only): add each
   team with a name, an optional short name for narrow columns (it labels the
   tie-break working and is not published) and an optional captain. A team can
   be deleted while it is in no round; a team that is in a paired match is
   withdrawn instead.
3. Register the players on the Players page as usual, then put each one on a
   team from the team's card. **The order of a roster is the board order**:
   board 1 first. The arrows move a player to a higher or lower board; *Remove*
   takes them off the team. Players beyond the match size are marked *reserve*.
4. **Boards per match** (on the Teams page; default 4) is fixed when round 1
   is paired.
5. **The order of the teams.** The order of the cards becomes the teams'
   pairing numbers when round 1 is paired. Move teams with the arrows or press
   **Order by rating**. Teams you did not move by hand are ordered by rating when
   round 1 is paired. How a team's rating is worked out is the Options page's
   *Team rating for the order of the teams*: the default (Olympiad rule)
   is the average of the highest-rated players, one for each board; the
   alternatives are the average of the first boards in board order, the
   average of the whole roster, or a rating typed for each team. A team's
   rating can also be typed on its card, which then wins. An unrated player
   counts as the rating set in *Rating of an unrated player* (1400 by default).
6. **Match points** (Settings, Scoring): 2, 1, 0 by default. A league that scores
   3, 1, 0 changes them here. Game points count board results.
7. **Tie-breaks** (Settings, Tournament): a team tournament is offered the team
   tie-breaks. The FIDE default is MP, GP, DE, BB, SB.

![The Teams page with team cards, rosters in board order and the Boards per match setting](screenshots/12-teams-page.png "The Teams page: rosters in board order")

Every action on the Teams page is an ordinary button with a spoken name, and the
result is announced.

### Line-ups

Options, *Line-ups*: **Required** (the default and the FIDE procedure): a team
plays with the players of its roster in board order, a reserve moves up for an
absent player, and a board that a team cannot fill is a forfeit win for the
opponent.

> [!NOTE] Optional: pair teams without players
> Some leagues and school
> events only record match scores. The matches are paired without players, and
> a match can be given as a *Match score* (for example 2½-1½ on four boards)
> that the program writes onto the boards. A match with empty seats is not a
> rated game and is reported to FIDE with a warning on the Export page.

> [!FIDE]
> In FIDE mode the rosters and board orders are fixed after round 1; a new
> player can still be added at the bottom of a team as a reserve.

## Pairing

**Round robin (teams).** *Pair the whole tournament* pairs every round at once from the
Berger table. The team named first has White on board 1 and on every odd board
and Black on the even boards; the colour of a team in the match is the colour
of its board 1.

**Swiss (teams).** The program pairs each round team against team by the rules
of FIDE C.04.6 (February 2026).

> [!FIDE] C.04.6 (February 2026)
> Match points
> are the primary score, game points decide colours, the first colour is drawn
> by lot. The pairing-allocated bye scores a drawn match (match and game points
> are set on the Scoring page).

A team Swiss that was already paired player by player in an earlier version continues
that way.

Each pairing is a **match**. The Pairings page shows a table *Matches - round N*
above the boards: match number, number of boards, the teams, the game-point
score so far, the match points once every board has a result, a link to the match's
line-ups (*Line-ups*) and the **Forfeit by decision** controls.

- *Line-ups*: the page of a match sets who plays on which board; a line-up
  keeps the team's board order; it can be changed only before the first result
  of the match is entered.
- *Forfeit by decision*: *To Team A* / *To Team B* makes every board of the
  match the forfeit result of that team, and *Neither team* records a double
  forfeit (both lose). *Withdraw the decision* gives back the old results. A
  restore point is saved first.
- A board added by hand (two players from the not-playing list) joins its
  teams' match when the table number, the colours and the board orders fit; when it does
  not, it is marked **no team** and counts for no team until you make it a board
  of the match.

A team can be marked **absent as a team** for a round on its card (before the
round is paired); a team that withdraws is shown as *withdrawn, results not
counted* in the standings (round robin, under 50% played, FIDE General
Regulations 6.6).

## Results and standings

Results are entered per board on the Pairings page, as in any tournament
([Results](07-results.md)). The team standings (Standings page) show the
rank, the team, matches played, won-drawn-lost, match points and the team
tie-breaks, each with its working (for each round the opponent and what it was
worth, a forfeit, a bye). The page also shows **board statistics**: per board
number, the players who sat there, with games, points, percentage and performance.

![The team standings with match points, game points and the working of a team tie-break](screenshots/12-team-standings.png "Team standings with tie-break working")

### Team tie-breaks

MP (match points), GP (game points), DE (direct encounter), BB (board points
weighted by board), SB, BH:GP, EMGSB, EGMSB, EGGSB, EDE (extended direct
encounter), TBR (top board results), BBE (bottom board elimination), SSSC.
The unplayed-game handling of C.07 Article 16 applies to byes, forfeited
matches and withdrawn teams in a team Swiss.

## Printing

The Print page lists **team pairings**, **team standings**, **team cross table**,
**match result sheets**, **team rosters** and **board prizes**
([Printing](09-printing.md)). The Standings page has the same as buttons:
*Cross table*, *Match sheets*, *Rosters*, *Board prizes*.

## Reporting and publishing

The TRF26 report carries the teams and their board orders (records 310 and
013, 362, 320 for the bye and 330 for a forfeited match), and a team file can
be imported again, with the matches rebuilt where the boards say it
unambiguously. Team tournaments are published to OpenResults like others
([Publishing](14-publishing.md)).

> [!NOTE]
> Team events have more detailed rules for forfeits, line-ups and withdrawals
> than are listed here. When the program refuses something, its message says why.
