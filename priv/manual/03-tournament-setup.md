# Creating a tournament and its settings

This chapter covers the New tournament form and every Settings page except
the publishing page ([Publishing](14-publishing.md)), the Export page
([Import and export](10-import-export.md), [Sending to FIDE](11-fide-report.md))
and Categories ([Categories and norms](13-categories-and-norms.md)).

## Creating a tournament

Tournaments, **New tournament**.

| Field | Meaning |
| --- | --- |
| Name | Required. |
| Pairing system | **Swiss - FIDE Dutch**, **Round robin (Berger)** or **Keizer**. It cannot be changed after the first round is paired. |
| Rounds | 1 to 99. A round robin works out its own number of rounds from the players and the cycles. |
| Cycles | (round robin only) single or double. |
| Team tournament | Makes it a team event: Swiss teams (FIDE C.04.6) or round robin teams. Keizer cannot be a team event. See [Teams](12-teams.md). |
| Place | The city. |
| Date from | Seeds every round with this date; refine it on the Dates page. |
| Rate of play | A list of the usual time controls for the chosen format, or *none*. |
| Format | Standard, Rapid or Blitz. It decides which time controls are offered, which FIDE rating the players' ratings are refreshed from, and the report type. |

![The New tournament form with name, pairing system, rounds, place, start date and rate of play](screenshots/03-new-tournament-form.png "The New tournament form")

The form starts with your defaults (Account page, *New tournaments*: system,
rounds, format, rate of play, place, organiser, publishing mode). The
tournament is created in FIDE mode ([FIDE mode](02-fide-mode.md)).

Other ways to start a tournament: **Import** a `.swar` file, a `.trf` file, a
JSON backup, or **Receive a hand-off** (see
[Import and export](10-import-export.md) and
[Accounts, sharing and hand-off](15-accounts-and-handoff.md)); or **Copy** an
existing tournament on the list (a copy contains everything in the original,
rounds and results included, and is named *Copy of …*).

### What must be set before pairing

> [!WARNING]
> A round cannot be paired until the **tournament name**, the **number of
> rounds**, a **date for every round** and a **tie-break selection** exist.

The Players and Pairings pages say what is still missing and link to the page
where it is set. The Pairings page also warns, before round 1 and without blocking, when the
number of rounds cannot be paired for the players registered: a Swiss with more
rounds than the players allow without a rematch, or a round robin whose number
of rounds does not match the number of players. The warning links to the
setting; if you keep the number, the round that cannot be paired is made by
hand ([Pairing a round](06-pairing.md)). Recommended, but not required: the chief arbiter, the
federation, the rate of play and (for a FIDE-rated tournament) the FIDE
tournament ID.

## The Settings pages

The **Settings** menu in the top bar has these pages:

| Page | Holds |
| --- | --- |
| Tournament | name, venue, city, federation, organiser; tournament format; number of rounds; officials; tie-breaks; sharing; logo |
| Options | pairing system and engine, initial colour, acceleration, Swiss match format, teams, type and rate of play, forbidden pairings, club and federation exclusions |
| OpenResults | publishing to the results site ([Publishing](14-publishing.md)) |
| Scoring | points, byes, absences, postponed games |
| Dates | one date per round |
| Categories | see [Categories and norms](13-categories-and-norms.md) |
| Extra points | bonus or handicap points by rating band |
| FIDE | FIDE mode and the report identifiers ([FIDE mode](02-fide-mode.md)); the rating-list sequence and the consistency checks of the ratings ([Players and rating lists](04-players-and-ratings.md)) |
| Export | TRF, backups, CSV ([Import and export](10-import-export.md)) |
| About | version and the pairing engine this tournament uses |

A page saves with its own **Save settings** button. When a colleague changes
the same settings while you are typing, the page tells you that it is out of
date instead of overwriting what you typed. Every settings change is written
to the audit trail with the old and the new value.

## Tournament page

**General.** Name (required), venue, city, federation, organiser, and the
organiser's club number. **Tournament format** is the type: Swiss
(individual), Round robin (individual), Swiss (teams), Round robin (teams).
**Number of rounds** can be changed until the first round is paired (in a
round robin the number follows from the players and cycles).

**Officials.** The chief arbiter (name, and FIDE ID when known), deputy
arbiters, and the data that the FIDE reports use. The same officials can be
edited on the Norms page.

**Tie-breaks.** Described in [Standings and tie-breaks](08-standings-and-tiebreaks.md).
This section also holds *How an unrated player is counted in the tie-breaks*
(with the rating typed for it) and *Players still level share a place*.

**Chess960.** The tick *Chess960* says that the tournament is played as
Chess960. The arbiter then draws a starting position for each round on the
Pairings page ([Pairing a round](06-pairing.md)).

**Share / Team.** The owner can invite other arbiters by e-mail address (see
[Accounts, sharing and hand-off](15-accounts-and-handoff.md)).

**Logo.** A PNG, JPEG, GIF or WebP image of at most 2 MB, stored with the
tournament and printed on the documents.

## Options page

**Pairing system.** The system is fixed once the first round is paired.

**Swiss engine.** *Ainalrami* is the default and is built into the program;
it follows C.04.3 as it stands from 1 February 2026. *JaVaFo* is FIDE's
reference implementation of the 2017 edition and needs Java and the JaVaFo
program file installed separately (it is not included). The engine is
fixed once the first round is paired. Both engines are given exactly the
same file (a TRF file built and checked by the program).

![The Options settings page with the pairing system, Swiss engine and tournament rating](screenshots/03-settings-options.png "Settings, Options")

**Tournament rating.** The rating that ranks the players, and so gives them
their pairing numbers, and that the rating-based tie-breaks read. The choices
are the methods of the TRF26 report: *FIDE rating only (FIDE)*, *National
rating only (NRO)*, *FIDE rating, else national (FIDON)*, which is the default,
*National rating, else FIDE (NIDOF)*, *Highest of FIDE, national and manual
(HBFN)* and *Manual rating per player (OTHER)*. A manual rating is typed per
player (*Tournament rating* on the player's form,
[Players and rating lists](04-players-and-ratings.md)).

**Equal rating and title.** Players with the same tournament rating are
ordered by FIDE title (GM, IM, WGM, FM, WIM, CM, WFM, WCM, no title), and then
by this criterion: alphabetically (the FIDE default), by FIDE ID (lowest
first), oldest first or youngest first. Announce the criterion before the
event.

**Late entrants' pairing numbers** (Swiss only). *By rating* (the default)
gives a player who joins after the numbers were given the number their rating
earns and moves everybody below one place down (C.04.2 2.4); rounds already
played keep their boards. *After the field* gives them the next free number
instead. The FIDE rules do not, so choosing it takes the tournament out of
FIDE mode ([FIDE mode](02-fide-mode.md)). A tournament created before *By
rating* became the default keeps *After the field* as it had it, without
leaving FIDE mode; so does a backup file from that time when it is imported.
Changing these three settings after round 1 renumbers nobody already
numbered; the page says so.

A player absent from round 1 (a requested bye, an absence, a later start
round) is a late entrant too: they get no pairing number when round 1 is
paired, and are numbered when they arrive, by the setting above (C.04.2 2.4).
If round 1 is unpaired and paired again with them present, they are numbered
with the field by rating. This holds for every Swiss tournament created from
version 0.79 on. A tournament created earlier, or imported from a TRF or SWAR
file, keeps numbering round-1 absentees with the field as it always did: its
numbers came from somewhere else and stay as they are. A backup file keeps
what its tournament had.

**Initial colour.** For the first round of a Swiss tournament: drawn by lot
when round 1 is paired, or White or Black chosen by you. The colour that was
used is shown on the Pairings page under round 1.

> [!FIDE] C.04.3 5.1
> Drawing the initial colour by lot is the FIDE rule.

**Cycles** (round robin): single or double. **Play the last two rounds of the
first cycle in reverse order** follows FIDE C.05. A single cycle can be made
double until the second cycle has begun.

**Keizer top value**: the value of the top rung of the Keizer ladder, or
blank for the automatic value.

**Acceleration.** None, or **Baku acceleration (FIDE C.04.7)**: the program
works out every player's virtual points in the first rounds and gives them to
the engine, round by round. It applies to Swiss tournaments only and cannot be
changed once the first round is paired. Group A is counted over the players
paired in round 1: somebody absent from round 1 (a requested bye, an absence,
a later start round) gets no pairing number until they arrive, and is then
numbered like any late entrant (C.04.2 2.4), after the field or by rating as
*Late entrants' pairing numbers* says.

**Swiss match format.** Each pairing is played twice in a row, the second
game with the colours reversed. It needs an even number of rounds (each match
is two rounds).

> [!FIDE] Departure from FIDE mode
> The Swiss match format is a departure from FIDE mode.

**Teams** (team tournaments): whether line-ups are required, the way a team's
rating is worked out for the order of the teams, and the rating counted for
an unrated player. See [Teams](12-teams.md).

**Type and rate of play.** The type (Standard, Rapid, Blitz) and the time
control, from a list or typed in. The rate of play is written into the TRF
report.

**Forbidden pairings.** Two players who must not meet: choose Player A and
Player B and press *Pair*. A rule applies to every round and is kept by both
Swiss engines and by Keizer (a round robin ignores them). **Only if possible**
makes it a wish instead of a rule: the Ainalrami engine honours it as long as
the FIDE criteria allow, and the pairing explanation shows when it gave way.

> [!FIDE] Departure from FIDE mode
> A wish is not a FIDE rule and is recorded as a departure for the round it
> changed.

**Club / federation exclusions.** Players from the same club (or the same
federation) are not paired together: for all shared clubs, or only for the
clubs or federations you list. A second control, *Keep clubmates apart for the
first N rounds*, asks the engine to separate clubmates early without making
it a rule, and *How hard to try* chooses whether that wish ranks before the
colour and float criteria (strong) or only as a last tie-break (weak).

## Scoring page

**Points** for a win (default 1), a draw (½) and a loss (0), and the value of
the **pairing-allocated bye** (default: a win).

> [!FIDE] Scoring
> In FIDE mode these cannot be changed after round 1, and a value in which a
> draw or the bye is worth more than a win marks the tournament as departing
> from the FIDE rules.

**Match points** (team events): 2 for a won match, 1 for a drawn match, 0 for
a lost match by default; the match points and game points of a
pairing-allocated bye; and the treatment of a team that withdraws.

**Byes and absences.** *Points for a round sat out* is the value of a round a
player was absent for (blank: absences score nothing). Two optional limits go
with it: the last round it still applies to, and a cap on how many of a
player's rounds are paid. *Treat a round sat out as a voluntary unplayed round
for tiebreaks* changes how the tie-breaks of C.07 treat those rounds. *Rounds
before a late entrant joins count as absences* pays the rounds before a late
entry in the same way. These settings change the points, the tie-breaks and
with them the standings, and are locked after round 1. *Ask the bye type for
each absence* (individual Swiss, off by default) makes the registration form
ask whether each round sat out is a half-point, zero-point or full-point bye,
with the answer the points above give already picked; see
[Byes and absences](05-byes-and-absences.md#asking-the-bye-type).

**Postponed games.** *Allow postponed games* offers a postponed result on the
Pairings page. Until a postponed game is played it counts for the player who
postponed it, and for the opponent, as set here (a draw for both by default,
which is the FIDE rule). See [Results](07-results.md).

## Dates page

One date for each round:

- **Fill sequentially from round 1** puts consecutive days,
- **Calculate weekly from round 1** puts one week between rounds,
- **Clear all** empties them.

The dates are used on the printed lists, the TRF report
(record 132), the match result sheets and the results site. The start and end
date of the tournament are derived from them.

## Extra points page

Extra points are points added on top of the game points by an arbiter. There
are two kinds:

- **Handicap**: a head start for players *below* a rating.
- **Acceleration**: SWAR's extra points, for players *at or above* a rating;
  they bring the strong players together earlier.

*Elo bands* are written as `rating:bonus` pairs, separated by commas.
**Apply bands to players** gives each player the points of their band; points
can also be typed per player on the Players page. *Count extra points
(standings and pairing)* makes the standings (and, for a handicap, the
pairing) use them; for acceleration the switch is called *Keep acceleration
points in the final standings*. In the TRF report they appear in record 299.

> [!FIDE] Departure from FIDE mode
> Extra points are not part of the FIDE rules; a round that the pairing used
> them for is recorded as a departure.

## Locks

After the first round is paired some settings are locked because they decide
what already happened: the pairing system and engine, the match formats, the
pairing by category, the absence scoring, the initial colour and (team events)
the boards per match and line-up rules. In FIDE mode the list is longer; see
[FIDE mode](02-fide-mode.md).

> [!TIP]
> Outside FIDE mode a locked field has an *Unlock* control that opens it for
> one save.
