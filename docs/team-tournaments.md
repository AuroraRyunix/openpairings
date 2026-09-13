# Team tournaments

A team tournament is one whose type is **Round robin (teams)** or **Swiss
(teams)**: tick *Team tournament* when creating it. Teams play matches; a
match is a set of individual games, board against board. The individual games
are ordinary games everywhere else in the app - result entry, player cards,
the FIDE rating report - and the team layer is built on top of them.

What exists today (phase 1):

| | Team round robin | Team Swiss |
|---|---|---|
| Teams page (teams, rosters, board order, seeding) | yes | yes |
| Paired team against team | yes (Berger tables) | **no** - still paired player by player |
| Match points, game points, team standings | yes | no |
| Team tie-breaks, board statistics | yes | no |
| TRF team section (`013`) | yes | yes |
| Team pairing sheet and team standings print | yes | no |
| Published to OpenResults | **no** (see below) | **no** |

Team Swiss (FIDE C.04.6) is phase 2; see
[`teams-phase-2-plan.md`](teams-phase-2-plan.md).

## Where the FIDE rules came from

Checked against local copies of the FIDE Handbook texts in the maintainer's
Downloads folder, not memory, unless the row says otherwise.

| Rule | Source |
|---|---|
| Team colour in a match is the board-1 player's colour (C.04.6 Art. 1.6.1) | local PDF, *C.04.6 Swiss Team Pairing System (effective 1 February 2026)* |
| TPN assignment left to the competition or the Chief Arbiter (C.04.6 Art. 1.1.2) | same |
| Match points the default primary score (C.04.6 Art. 1.2.2) | same |
| Match points and game points (C.07 Art. 11.1) | local PDF, *C.07 Play-Off and Tie-Break Regulations (effective 1 March 2026)* |
| Individual tie-breaks apply to teams on the primary score (C.07 Art. 13) | same |
| EMMSB / EMGSB (C.07 Art. 13.2.1 / 13.2.2) | same |
| Board Count (C.07 Art. 12.1) | same |
| Direct encounter, averaging repeated meetings (C.07 Art. 6, 6.1.2) | same |
| Art. 16 unplayed-rounds management is for Swiss events only (Art. 15.3, 16) | same |
| **Colours alternate down the boards, the first team taking the odd boards** | **memory** - the convention of FIDE team competitions such as the Olympiad regulations; no local copy was read |
| **"Olympiad Sonneborn-Berger" is opponent MP x game points scored** | **memory**; only used to describe EMGSB, whose definition is from the local C.07 |
| Berger tables (C.05 Annex 1) | no local copy; the schedule reuses `PairingsEngine.RoundRobin`, which is pinned by tests to the published N=4 and N=6 tables |

## Setting up

1. Create the tournament with *Round robin* and *Team tournament* ticked.
2. **Teams** (a tab next to Players, shown only for team tournaments): add each
   team - a name, an optional short name for narrow columns, an optional
   captain.
3. Register the players on the Players page as usual, then put each one on a
   team from its card on the Teams page. The order of a roster is the board
   order: board 1 first. The arrow buttons move a player up or down a board;
   *Remove* takes them off the team. Players past the match size are marked
   *reserve*.
4. **Boards per match** is on the same page (default 4). It locks when round 1
   is paired.
5. **Order of the teams**: the order of the team cards becomes the teams'
   pairing numbers when round 1 is paired. Move teams with the arrows, or
   *Order by rating* (the mean rating of each team's first *boards-per-match*
   players, a missing board counting 0). C.04.6 Art. 1.1.2 leaves this to the
   competition's rules or the Chief Arbiter, so nothing is applied on its own.
6. **Match points** (Settings - Scoring): 2 / 1 / 0 by default, FIDE's team
   scoring. A league that scores 3 / 1 / 0 changes them here.
7. Tie-breaks (Settings - Tournament): a team tournament is offered the team
   tie-breaks. FIDE's default for team events is `MP GP DE BB SB`.

Every action on the Teams page is a plain button, so it works from the
keyboard, each one has a spoken name ("Move Anna to a higher board"), and the
result is announced through a status line.

## Pairing a team round robin

*Pair* on the Pairings page pairs the whole schedule at once, as for an
individual round robin. `PairingsEngine.TeamRoundRobin` runs the same Berger
table (`RoundRobin.schedule/3`) over the teams' pairing numbers, so an odd
number of teams gives each team one bye per cycle, a double round robin
reverses the colours in its second cycle, and match format repeats each match
with colours reversed.

Each scheduled pairing becomes a **match** (`matches` table) and its boards:

- **Colours.** The team the Berger table names first has White on board 1 and
  on every odd board, Black on every even board. So a team's colour in the
  match (C.04.6 Art. 1.6.1: its board-1 colour) is exactly the Berger table's.
- **Line-ups.** Each team's roster in board order, skipping anyone withdrawn,
  marked absent or forfeited, absent for that round, or not yet started; the
  first *boards-per-match* of those play, so a reserve moves up.
- **Unequal teams or a missing player.** A board only one team can fill is a
  forfeit win for the player who is there (`1-0FF` or `0-1FF`). A board
  neither team can fill is not created.
- **Board numbers** run on through the round: with four boards, match 1 is
  boards 1-4 and match 2 boards 5-8. Result entry, result slips and score
  sheets are unchanged.

A player who drops out after the schedule is paired is handled on the Pairings
page as in any round: vacate the seat, fill it, or record the forfeit. A board
added by hand from the pool belongs to no match and is not counted for either
team.

Unpairing every round gives the teams back to the Teams page (their pairing
numbers are cleared), so a team can be added or removed before the event
starts again.

The Pairings page shows the round's matches above the board list: match
number, boards, the two teams, the game-point score so far, and the match
points once every board has a result.

## Scores and standings

`PairingsEngine.TeamStandings`, from the matches and their boards:

- **Game points (GP)** - the sum of a team's board results, each board scored
  exactly as the individual standings score it (a forfeit win counts).
- **Match points (MP)** - decided by comparing the two teams' game points in
  the match. A match scores match points only once every board in it has a
  result; game points count board by board.
- The bye of an odd round robin scores nothing and counts as no match.

The Standings page of a team round robin shows the team table - rank, team,
matches played, won-drawn-lost, MP and the tie-breaks - and board statistics
below it. The individual FIDE table is not shown: its tie-breaks are team
breaks it cannot calculate.

### Team tie-breaks

Ranking is by match points, then the configured tie-breaks in order, then
pairing number (C.07 Art. 4.2 says drawing of lots; that is the arbiter's).

| Code | What | Rule |
|---|---|---|
| `MP` | match points | C.07 11.1.1 |
| `GP` | game points | C.07 11.1.2, 13.1 |
| `DE` | direct encounter on match points, among teams still tied on MP **and on every tie-break listed before DE**; decided only when all of them have met; repeated meetings averaged | C.07 6, 6.1.2, 4.2 |
| `BH` | Buchholz: the sum of each opponent's final match points | C.07 8.1 + 13 |
| `SB` | Sonneborn-Berger on the primary score: opponent's final MP x MP scored against them | C.07 9.1 + 13 (= EMMSB, 13.2.1) |
| `EMGSB` | opponent's final MP x game points scored against them | C.07 13.2.2 |
| `BB` | board points weighted by board: on B boards, a point on board k is worth B+1-k | ranks as C.07 12.1 Board Count for teams level on GP |

The Standings page has a *Working* disclosure per team that lists the parts
BH, SB and EMGSB were added up from ("R2 BSK: 4"), in the same shape
`PairingsEngine.TiebreakWorking` publishes for individuals.

Art. 16's unplayed-rounds adjustments are not applied: C.07 Art. 15.3 and 16
confine them to Swiss events, and a round robin's bye is the same for every
team. Team Swiss will need them.

### Board statistics

For every player who sat at a board: the boards played, games (forfeits
included), points, percentage and performance rating
(`PlayerStats.performance/3`, over games actually played against rated
opponents - the Players grid's figure). Grouped by the board each player
played most often, for board prizes.

## TRF

`PairingsEngine.TrfExport` writes the TRF16 team section: one `013` record
per team, its name and its players' starting ranks (their pairing numbers) in
board order, listing only players the file contains. The `082` header carries
the team count. The individual games on the `001` lines are exactly what they
would be for the same boards in an individual event; a board forfeited for
want of a player has no opponent and goes out as the point without a game,
the same record a vacated seat produces. An individual tournament's file is
unchanged: `082 0` and no `013` line.

Importing a TRF with a team section creates the teams and their board orders.
The games come back as individual games: TRF16 does not say which boards made
up which match, and the import says so.

## Backups, restore points, hand-off

The JSON envelope carries the teams (including seeding order and pairing
number), the tournament's match settings, each round's `"matches"`, and each
board's `"match_id"`, remapped on import. A restore therefore brings back the
same team standings.

## Printing

For a team round robin the Print page offers, above the individual documents:

- **Team pairings** (`/t/:id/print/team-pairings?round=n`) - one table per
  match, headed "Match n: Team A - Team B (score)", with a line per board:
  board number, the first team's colour, both players with ratings, result.
- **Team standings** (`/t/:id/print/team-standings?round=n`) - the team table
  after round n, or current.

## Publishing

**Phase 1 does not publish team tournaments to OpenResults.** The results
site has no team pages; its snapshot is players, games and an individual
standings table. Sent as that, a team round robin would show the public an
individual ranking for an event decided by match points, and a team Swiss that
still pairs player by player would look like an ordinary open. Both mislead.

So the publish switch cannot be turned on for a team tournament
(`Tournaments.set_publish_to_openresults/2` answers `{:error,
:team_tournament}`), a team tournament is never queued, and a send is refused
with the reason (`Publishing.team_refusal/0`) - including one that was
switched on before this existed, which can still be switched off. The
Settings - OpenResults page says so at the top.

Team pages on OpenResults - additive snapshot fields for teams, matches and
team standings - are a later phase.
