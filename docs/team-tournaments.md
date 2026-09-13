# Team tournaments

A team tournament is one whose type is **Round robin (teams)** or **Swiss
(teams)**: tick *Team tournament* when creating it. Teams play matches; a
match is a set of individual games, board against board. The individual games
are ordinary games everywhere else in the app - result entry, player cards,
the FIDE rating report - and the team layer is built on top of them.

What exists today (phases 1 and 2):

| | Team round robin | Team Swiss |
|---|---|---|
| Teams page (teams, rosters, board order, seeding) | yes | yes |
| Paired team against team | yes (Berger tables) | yes (FIDE C.04.6, Ainalrami) - except an event already paired player by player, below |
| Match points, game points, team standings | yes | yes, the bye scoring a draw |
| Team tie-breaks, board statistics | yes | yes, with C.07 Art. 16 |
| TRF team section (`013`) | yes | yes |
| Team pairing sheet and team standings print | yes | yes |
| Published to OpenResults | yes | yes |

`Tournament.paired_as_teams?/1` is the one question for "does this event
have matches and team standings": true for a team round robin and for a team
Swiss paired by teams (or not yet paired), false for an individual event and
for a team Swiss paired player by player. `Tournament.team?/1` only says the
event is classified as a team event.

Phase 2's design was [`teams-phase-2-plan.md`](teams-phase-2-plan.md); where
the build departed from it is recorded there.

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

## Pairing a team Swiss

*Pair* on the Pairings page pairs one round at a time, once every board of
the previous round has a result. `PairingsEngine.TeamSwiss` builds, for each
team, what C.04.6 needs from the stored matches and hands it to
`Ainalrami.TeamPairing.pair_round/2`, then writes the round with the same
match writer as the round robin (`PairingsEngine.TeamRounds`): the team the
colour rules give White is team A, White on board 1 and every odd board.

| Rule | Source |
|---|---|
| The procedure, criteria [C1]-[C10], the bye (3.4), upfloaters (3.5), brackets (3.6), colours (Art. 4) | local PDF, *C.04.6 Swiss Team Pairing System (effective 1 February 2026)*; Ainalrami's `docs/conformance-c0406-teams.md` |
| The bye pays a draw's match points and game points (1.4) | same |
| A team's colour is its board-1 colour in a match actually played (1.6.1) | same |
| A match not played is not a meeting (a forfeited match can be paired again) | local PDF, *C.04.2 General handling rules* Art. 3.5 |
| Late entries get a number when they arrive; 4.3.1's parity is on the arrival numbering | C.04.2 Art. 2.4; the SPP ruling of 2026-08-27 |

What each team is, per round:

- **Match points and game points** - including a previous bye's draw.
- **Opponents** - the teams it has played. A match in which no game was
  played (every board a forfeit or an empty seat) is not a meeting.
- **Colours** - White as team A, Black as team B, in played matches only.
- **Had the bye** - a previous pairing-allocated bye.
- **Won a match by forfeit** (bars the bye, [C2]) - a match in which no game
  was played and the team scored more game points: the opponent did not turn
  up. One game played makes it a played match. This is open question 6 of
  the plan, answered by research rather than by the SPP; the reading is in
  `TeamSwiss.won_match_by_forfeit?/1`.
- **Floated last round** - paired in the previous round against a team on a
  different match-point score (the pairing, whether or not the match was then
  played; a bye is not a float).

**Who plays.** A team with at least one player available for the round is in
the field; a team that cannot field anyone (every player withdrawn, absent or
not yet started) sits the round out, with no match written. If it has played
before, it keeps its place in 4.3.1's numbering (Ainalrami's `:absent`).

**Team numbers** are the Teams page's seeding order, frozen when round 1 is
paired. A team added later is numbered after the highest number when it is
first paired; nobody is renumbered.

**The options are FIDE's defaults and not settable**: match points primary,
game points breaking a first-team tie for colours, Type A colour preferences.

**Match order** on the Pairings page follows C.04.2 Art. 3.6's recommended
sort (the pair's first team's score, the sum of both scores, the first
team's number); board numbers run on through the round as in a round robin.

If no legal pairing exists (C.04.6 3.3.3: "the Chief Arbiter shall decide"),
*Pair* says so and pairs nothing.

### Old team Swiss events stay player by player

Before phase 2 every team Swiss was paired player by player on the individual
Swiss path. Such an event is not converted part-way: C.04.6 pairs from a team
history those rounds do not have. `tournaments.team_pairing_mode` tells the
two apart:

| value | meaning | set by |
|---|---|---|
| nil | nothing paired yet - the next pairing is by teams | default; unpairing every round resets it |
| `"teams"` | paired team against team | `TeamSwiss` at its first round |
| `"players"` | paired player by player; stays on the individual path | the migration, for every team Swiss that had a round; a TRF import with games; `TeamSwiss.settle_mode/1` for data without the flag whose rounds have no matches |

The Teams page of such an event says it carries on player by player, and its
Standings page keeps the individual table. Unpairing every round makes it a
new team Swiss.

## The initial colour

C.04.3 Art. 5.1 and C.04.6 Art. 4.1: the initial colour is "determined by
drawing of lots before the pairing of the first round". Settings - Options -
*Initial colour* (individual and team Swiss):

- **Drawn by lot** (default) - drawn when round 1 is paired
  (`Tournaments.ensure_initial_colour/2`), stored in
  `initial_colour_drawn`, and shown on the Pairings page and in Settings
  ("Initial colour: drawn by lot: White"). Unpairing and re-pairing round 1
  keeps the draw.
- **White** / **Black** - the arbiter's choice; nothing is drawn.

It locks when round 1 is paired. Both engines are told it: the engine TRF
carries `XXC white1` / `XXC black1` (JaVaFo does not read `152`, and without
`XXC` it draws its own lot on every run), Ainalrami takes it as
`:initial_colour`, and the team engine as `:initial_colour`. A tournament that
paired round 1 before the setting existed has no draw on record and is left
exactly as it was: no line is written and each engine works the colour out as
it always did. Backups, restore points and TRF imports (`152` or `XXC`) carry
the draw.

## Scores and standings

`PairingsEngine.TeamStandings`, from the matches and their boards:

- **Game points (GP)** - the sum of a team's board results, each board scored
  exactly as the individual standings score it (a forfeit win counts).
- **Match points (MP)** - decided by comparing the two teams' game points in
  the match. A match scores match points only once every board in it has a
  result; game points count board by board.
- The bye of an odd round robin scores nothing and counts as no match.
- A team Swiss's pairing-allocated bye scores a drawn match (C.04.6 1.4):
  the draw's match points, and the draw's points on every board as game
  points.

The Standings page of a tournament paired as teams shows the team table - rank, team,
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

**Art. 16 (unplayed rounds) applies to a team Swiss only** - C.07 Art. 15.3
and 16 confine it to Swiss events, and a round robin's bye is the same for
every team. For a team Swiss, `TeamStandings` sorts every round of every team
into Art. 16.2's categories (read from the local C.07 text):

| round | category |
|---|---|
| a match with at least one game played | played |
| the pairing-allocated bye | 16.2.1 |
| a match with no game played, won on game points | 16.2.2 forfeit win |
| a match with no game played, not won | 16.2.4 forfeit loss |
| not paired (sat out, withdrew, not yet entered), followed by a round that is not a bye or a forfeit loss | 16.2.3 |
| the same, followed only by byes and forfeit losses, or in the last round | 16.2.5 |

- **Adjusted match points** (16.3), which an opponent's BH, SB and EMGSB
  read: every round as awarded, except 16.2.5's, which count as a draw.
- **A team's own unplayed round** (16.4) counts against a dummy whose match
  points are the team's own, capped by the scheduled opponent's adjusted
  match points for a forfeit (16.4.1) and by a draw's match points times the
  rounds of the tournament otherwise (16.4.2); times the match points (SB) or
  game points (EMGSB) the round awarded. "For team competitions, points means
  match points and game points": the dummy stands in for the opponent's
  match points, the factor all three tie-breaks read.
- The *Working* line names such rounds: "R2 bye: 3", "R1 T3 (forfeit win):
  2", "R3 not paired: 0".

This follows the text where the individual standings do something slightly
different: `Standings` gives a forfeited round the scheduled opponent's
adjusted score rather than the capped dummy, and counts trailing forfeit
losses as draws for opponents. Cut-1 (16.5) is not offered for teams.

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

For a tournament paired as teams (a team round robin, or a team Swiss paired\nby teams) the Print page offers, above the individual documents:

- **Team pairings** (`/t/:id/print/team-pairings?round=n`) - one table per
  match, headed "Match n: Team A - Team B (score)", with a line per board:
  board number, the first team's colour, both players with ratings, result.
- **Team standings** (`/t/:id/print/team-standings?round=n`) - the team table
  after round n, or current.

## Publishing

Team tournaments publish to OpenResults like any other. `PairingsEngine.Snapshot`
adds `tournament.team_event`, `teams`, each round's `matches`, `team_standings`
and `board_stats` for a team event - additive fields, documented in
OpenResults' `docs/snapshot-schema.md`, that an individual tournament's
snapshot never carries. OpenResults never computes a team result: every team
number, match score and board statistic in those fields is exactly what
OpenPairings worked out.

Every existing withholding rule still applies: an unpublished round's matches
never leave with it; a match in a round whose results are not public shows
its two teams with `game_points`/`match_points` both `null`, the same as a
board's own result; and `team_standings`/`board_stats` stop at whatever round
the arbiter has published standings through, exactly like the individual
table. Settings - OpenResults explains, for a team event, that publishing
sends the team standings, matches and board statistics OpenPairings
computed.

A team Swiss paired by teams publishes the same fields as a team round robin.
A team Swiss that was already paired player by player before team pairing
arrived (`team_pairing_mode` "players") publishes as an individual event,
with no team fields at all: `Snapshot` gates every team field on
`Tournament.paired_as_teams?/1`, so the results site shows its real
individual standings rather than empty team ones.
