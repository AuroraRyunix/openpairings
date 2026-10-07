# Pairing a round

Pairings are made on the **Pairings** page. This chapter covers pairing a
round in every system, the explanation of a pairing, changing a pairing by
hand, and undoing a round.

## The Pairings page

The page shows one round at a time. A row of round buttons at the top moves
between the rounds; a round that has not been paired yet is shown empty with
the button that pairs it. The table has one row per board: the board number,
the White player, the result, the Black player. A player with a bye is a
board with *bye* and no Black player.

Besides the table, the page has a **Print** menu (pairings, pairings with the
absentees section, result cards, test print, stack-cut order), a **More**
menu (the live page, the public page, PGN, CSV result import, unpair), and,
for a published tournament, the control that decides what spectators see
of the round ([Publishing](14-publishing.md)).

## Before pairing

The button **Pair round N** is available when

- the tournament's setup is complete: name, number of rounds, a date for
  every round, tie-breaks. If something is missing the page lists it and
  links to the page where it is set;
- the previous round has a result on every board. A board without a result
  keeps the button disabled with the note *Previous round still has missing
  results*. If postponed games are allowed (Scoring page) a separate button,
  **Record missing results as postponed and pair round N**, records the empty boards
  as postponed and goes on, after you have read the warning;
- the presence of the players is right: players marked absent are not
  paired ([Byes and absences](05-byes-and-absences.md)).

Rounds are paired in order. The page also lists the checks that apply to the
next pairing: for example, the players of every postponed game from earlier
rounds, which are paired on a provisional score, and the players whose bye
preferences are not applied.

## Swiss

The button reads **Pair round N (Ainalrami)** or **(JaVaFo)**, naming the
engine of the tournament. Press it and confirm. The program

1. gives the pairing numbers if this is the first round (highest rating
   first; the initial colour is drawn by lot unless you set it),
2. builds the tournament as a TRF file, checks it, and hands it to the engine,
3. reads the engine's pairings, numbers the boards, gives the byes, and saves
   the round.

A large field can take up to a minute; the button says so while it works. The
round is saved only if the whole of it succeeded. If the rules allow no legal
pairing for the remaining players the program says so and writes nothing.

In every round the engine applies FIDE's absolute criteria (no repeated
pairing, the colour rules, no second pairing-allocated bye) and then the
quality criteria in the order that C.04.3 gives them. Forbidden pairings, club and federation exclusions and extra
points are given to the engine as well ([Tournament set-up](03-tournament-setup.md)).
With Baku acceleration the virtual points are given for every round.

A player with a **fixed table** ([Players and rating lists](04-players-and-ratings.md)) is
labelled with that table; it is a label for printing only and does not
change who plays whom.

## Round robin

A round robin pairs the **whole tournament at once**: the button reads *Pair
the whole tournament (Berger)*, and the program asks for confirmation,
because the schedule cannot be changed afterwards and players added later are
not in it. The rounds follow FIDE's Berger tables (C.05); for an odd number of
players each player sits out one round with a zero-point bye; a double
cycle plays the table twice with the colours reversed (with the last two
rounds of the first cycle in reverse order, if that option is on). A player
who is absent or withdrawn stays in the schedule: enter a forfeit result for
their games.

## Keizer

The Keizer system ranks the players on a ladder: the player ranked *i* is
worth a number of points that goes down by one with each place, a win is worth
the opponent's value, a draw half of it. The ladder is recalculated from all
the results every time it is needed, so an early win is worth more when that
opponent climbs. Each round the program pairs from the top: each player gets
the nearest player below who has not been met, with backtracking. Colours are
given to the player who has had White less often. The top value of the ladder
is set on the Options page. The Standings page shows the Keizer table instead
of the tie-break table.

## Team tournaments

For Swiss and round robin team tournaments, **Pair round N** pairs team
against team: each pairing is a match, shown in a table *Matches - round N*
above the boards, and the boards of a match are played board against board
(see [Teams](12-teams.md)). Team Swiss follows C.04.6 and is paired by the
Ainalrami team engine; a large field runs in the background and the page
shows that it is working.

## The pairing rationale (explanation)

Every round paired by the program has an explanation: **Advanced**, **Pairing
rationale**, then the round. (While the explanation of a round is still being
worked out, a link *Working out the explanation…* on the Pairings page leads
to it.)

For a Swiss round paired by Ainalrami the page shows

- a map of the score brackets, with each pairing drawn as a line between the
  groups, so that floaters are seen to cross from one group to another;
- a card per board with the colours, whether the colour due was given, and
  the floats;
- for each float and for the bye, the question *why this player and not
  another*. Open it to see what each other candidate would have cost, in
  terms of the criteria of C.04.3, and whether the engine's choice is the best.
  The answers are worked out when you open a question, and are saved.

Round robin and Keizer have an exact account too. For a Swiss round paired by
JaVaFo the page is an honest comparison of input and output only: JaVaFo's
reasoning is not available.

If an organiser's rule changed the round (a bye preference, a pair wish), the
page says which board it moved and what the FIDE rules alone would have given.

## Preview of the next round

While the last few games of a Swiss round are still being played, **Preview
next round** (on the Pairings page) works out the next round for every
combination of the open results (six or fewer open games; up to 729
combinations) and saves nothing. Each board is then shown as **fixed**
(the same in every outcome: the name cards can go out), **fixed but may
shift** (the board range is given), **fixed with colours open**, or **open**,
with the players it could involve and the games that decide it. The preview
updates itself when a result is entered and can be printed (fixed boards
and a list by name). It is available for individual Swiss tournaments with the
Ainalrami engine.

## Changing a pairing by hand

Sometimes a pairing must be changed after the round is made: a player
arrives late, a mistake in the entry, two players who have met under another
name. Open the **Hand edits** menu by right-clicking a player (or press the
context-menu key) on the Pairings page. The menu offers, according to what
you clicked:

| Action | What it does |
| --- | --- |
| Swap with… | Click the player, choose *Swap with…*, then click a second player on a board: the two exchange seats. |
| Swap with a player on a board… | Exchanges a not-playing player with a player on a board. |
| Put in an empty seat | Puts a player from the *Not playing* list into an empty seat. |
| Mark absent for this round | Takes the player out of the board and puts them in the *Not playing* list. |
| Pair with another player who isn't playing… | Pairs two players of the *Not playing* list on a new board; you choose the table number. |
| Award a bye to the remaining player | Gives the bye to a player left over. |
| Delete this board… | Removes an empty board (a fully-vacated board can be hidden and un-hidden). |

Every edit first shows a confirmation with the boards before and after, which
you accept or cancel (`Escape` cancels). While an edit is half-made, a banner
says so. Two additional confirmations exist:

- **A round that is not the latest.** Editing an earlier round asks for a
  tick, because later rounds were paired from it. In FIDE mode only the last
  two rounds played can be changed ([FIDE mode](02-fide-mode.md)).
- **A round that was already sent to the rating office.** Changing who played
  whom in a sent round needs the tick *I understand - change the sent round N
  anyway* ([Sending to FIDE](11-fide-report.md)).

A result that is on a board that you change is cleared; the confirmation says
so.

Hand edits are not checked by the pairing engine: the program does not
warn when an edit repeats a pairing or breaks a colour rule, and the edit is
written to the audit trail. After a hand edit, check the round against the
rules yourself. (This is described for the current version.)

## Undoing a round

**More**, **Unpair round** (shown on the last paired round only) deletes that
round and every result in it, after a confirmation. The program takes a
restore point first ([Accounts, sharing and hand-off](15-accounts-and-handoff.md)).
In a Swiss match format the two rounds of a match go together. A round that
has been sent to the rating office cannot be unpaired.

## Entering results

Results are entered on the same page. See [Results](07-results.md).
