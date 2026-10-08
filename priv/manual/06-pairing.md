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

![The Pairings page with round 3 paired: round buttons, the board table and the Print and More menus](screenshots/06-pairings-round-paired.png "A paired round on the Pairings page")

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
  paired ([Byes and absences](05-byes-and-absences.md));
- no session of hand edits is open on an earlier round (see *Changing a
  pairing by hand*): the button stays disabled with the note *Finish the
  hand edits to round N first*.

Before round 1 the page also warns, without blocking, when the number of
rounds cannot be paired for the number of players: a Swiss with more rounds
than the players allow without a rematch ("A round that cannot be paired will
have to be made by hand"), or a round robin whose number of rounds does not
match the players. The warning links to the setting that fixes it
([Tournament set-up](03-tournament-setup.md)).

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

> [!FIDE] C.04.3
> In every round the engine applies FIDE's absolute criteria (no repeated
> pairing, the colour rules, no second pairing-allocated bye) and then the
> quality criteria in the order that C.04.3 gives them.

Forbidden pairings, the pairing rules (same club, same federation, groups)
that hold in the round, and extra points are given to the engine as well ([Tournament set-up](03-tournament-setup.md)).
With Baku acceleration the virtual points are given for every round.

The pairing numbers are given in the order of the tournament rating, then
FIDE title, then the criterion the tournament announced
([Players and rating lists](04-players-and-ratings.md)). If the engine finds
no legal pairing at all, the program says so and offers **Pair round N by
hand…** (see *Changing a pairing by hand*).

A player with a **fixed table** ([Players and rating lists](04-players-and-ratings.md)) is
labelled with that table; it is a label for printing only and does not
change who plays whom.

## Round robin

A round robin pairs the **whole tournament at once**: the button reads *Pair
the whole tournament (Berger)*, and the program asks for confirmation.

> [!WARNING]
> The schedule cannot be changed afterwards and players added later are
> not in it.

The rounds follow FIDE's Berger tables (C.05); for an odd number of
players each player sits out one round with a zero-point bye; a double
cycle plays the table twice with the colours reversed (with the last two
rounds of the first cycle in reverse order, if that option is on). A player
who is absent or withdrawn stays in the schedule: enter a forfeit result for
their games. The starting numbers the Berger tables use are the rating order
unless you set them before round 1 on the Players page (*Starting numbers*,
by hand or by a drawing of lots; [Players and rating lists](04-players-and-ratings.md)).

Beside it, **Pair round N by hand…** makes the next round yourself instead
of taking the table's
([A round robin paired by hand](#a-round-robin-paired-by-hand)). Once a
round exists, the main button reads *Pair the remaining rounds (Berger)*
and pairs the rest from the table - unless the rounds made by hand have
left the table behind, and its next round would pair two players who
already met in that cycle: then it refuses and says which two.

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

A result entered for one of the open games needs no new pairing: every
combination already worked out is remembered, so the preview updates at once.
Clearing a result only works out the combinations that are new.

### Announcing fixed boards

When the name cards of the fixed boards go out, press **Announce fixed boards**
in the preview. Printing the fixed boards announces them as well while
**Printing announces them** is ticked (it is by default). Each board is stored
with its number, White and Black, the time and who announced it, and the
audit trail records it. The Pairings page then shows how many boards of the
next round are announced; **Withdraw** removes the announcement.

If something changes that could break an announced board - a result outside
the open games, a forfeit, a player withdrawn, absent or added, a forbidden
pairing, a setting - the page says so. **Check again** works the preview out
again and lists the announced boards that are no longer certain.

When the round is paired, every announced board is compared with the
pairing. If a board's opponent, colours or number differ, a large warning
lists each one, announced and paired: take those cards back and print the
pairing again. The pairing itself is never changed to match an announcement -
that would be manipulating the pairing. If all announced boards hold, a short
line says so. Unpairing and pairing again compares again.

## Chess960

If **Chess960** is ticked on the Tournament settings page, the Pairings page
shows, for a paired round, the button **Draw Chess960 position**. It draws one
of the 960 starting positions at random (each is equally likely), shows its
number and the pieces of the first rank, and prints it with the round's
pairings. A round gets one position: the draw cannot be repeated until a
position pleases, and a second attempt is refused. The draw is written to the
audit trail.

## Changing a pairing by hand

Sometimes a pairing must be changed after the round is made: a player
arrives late, a mistake in the entry, two players who have met under another
name. The program calls it a
**manual pairing alteration** and works in sessions.

> [!FIDE] C.04.2 4.4
> The regulations allow an arbiter to alter a pairing, so
> this does not take the tournament out of FIDE mode.

### The session

- A session on a round **starts** with **More**, **Edit pairings by hand**,
  or implicitly with the first hand edit of the round. While it is open, a
  banner says *Hand edits to round N are open* and carries the button
  **Finish hand edits**.
- Hand edits are made with the **Hand edits** menu: right-click a player (or
  press the context-menu key) on the Pairings page. The menu offers,
  according to what you clicked:

| Action | What it does |
| --- | --- |
| Swap with… | Click the player, choose *Swap with…*, then click a second player on a board: the two exchange seats. |
| Swap with a player on a board… | Exchanges a not-playing player with a player on a board. |
| Put in an empty seat | Puts a player from the *Not playing* list into an empty seat. |
| Mark absent for this round | Takes the player out of the board and puts them in the *Not playing* list. |
| Pair with another player who isn't playing… | Pairs two players of the *Not playing* list on a new board; you choose the table number. |
| Give the pairing-allocated bye | Gives a player of the *Not playing* list the pairing-allocated bye, scored as set on the Scoring page. |
| Award a bye to the remaining player | Gives the bye to the player left alone on a board whose opponent was removed. |
| Delete this board… | Removes an empty board (a fully-vacated board can be hidden and un-hidden). |

- The session **ends** only when you press **Finish hand edits**. The next
  round cannot be paired while a session is open, so the check below cannot
  be skipped by moving on.

Every edit first shows a confirmation with the boards before and after,
which you accept or cancel (<kbd>Escape</kbd> cancels). While an edit is half-made, a
banner says so. A result that is on a board that you change is cleared; the
confirmation says so. Every edit is written to the audit trail.

![The confirmation of a hand edit, showing the boards before and after](screenshots/06-hand-edit-confirmation.png "Confirming a swap")

### Rule warnings while editing

For a tournament the checker can judge (an individual Dutch Swiss, see
below) the confirmation of an edit also lists
the pairing rules that the boards it creates would break:

- two players who already played each other, or are a prohibited pairing;
- the pairing-allocated bye for a player who already had one, won a game by
  forfeit, or had a full-point bye;
- a player getting the same colour for the third time running, or a colour
  difference above two, before the last round;
- two players who both get the colour opposite to the one each is due.

Such an edit is applied only after you tick the box that acknowledges the
warning. An edit that breaks nothing needs no tick.

### Finishing: the check against the pairing checker

**Finish hand edits** first asks that every seat is filled (fill it, give the
remaining player a bye, or empty the board) and that at least one board is
paired. Then the program runs the pairing engine over the players as the
round now seats them, and compares its pairing with your boards, colours
included but board order not:

- **Nothing changed since the session began, or the boards are the engine's
  own:** the session ends; nothing is recorded.
- **The boards differ from the engine's pairing:** a dialog shows the
  checker's pairing, what is only in yours and what is only in the checker's,
  and the rule warnings that still apply. Choose **Keep editing** to go back,
  or tick *I understand - keep my pairings and record the alteration* and
  press **Finish and record**. The round keeps your boards and records the
  alteration, which the TRF copies of the report carry as a comment line:
  `### MPA @ Round r: <checker's boards> => <the round's boards>`. Finishing
  a session again replaces the line of that round, or removes it when the
  boards now agree with the engine. The file made by *Send…* contains records
  only, so it has no such line ([Sending to FIDE](11-fide-report.md)).
- **The checker cannot judge the round** (it is a Dutch-system check, so a
  team, round robin, Keizer, per-category or Swiss match format round is
  out of its reach): if the
  boards differ from where the session began, the alteration is recorded
  without a check.

### A round with no legal pairing

If the rules leave no legal pairing for the next round, the program says so
and writes nothing. The Pairings page then offers **Pair round N by hand…**.
The dialog says that the round is created with no boards and every player in
the *Not playing* list, and that no pairing of the round can follow the
rules, so the round is recorded as a manual pairing alteration. You confirm
with the tick *I understand - create round N to pair by hand*. After
**Create round N** you pair the players from the list (pair two players, give
the pairing-allocated bye) and finish the hand edits as above.

### A round robin paired by hand

In a round robin (one table for the whole field, not in match format, not a
team event), **Pair round N by hand…** sits next to the Berger button. The
dialog says the round is created with no boards and every player in the
*Not playing* list, and that a round that differs from the table is
recorded as a manual pairing alteration; you confirm with the tick *I
understand - create round N to pair by hand*. Then pair two players at a
time from the list. A player you leave off the boards sits the round out
with the round robin's zero-point bye, given when you finish; the
pairing-allocated bye is not offered in a round robin.

Each board is checked as you make it, and a breach needs its own tick:

- **Two players who already meet in this cycle** - in a single round robin
  everyone meets everyone exactly once, in a double one once per cycle.
- **A third same colour running** - a player given White (or Black) in
  three consecutive rounds. The Berger table never does that within a
  cycle; a hand easily does.

**Finish hand edits** compares the round with the same round of the Berger
table, and checks that the rounds left in the cycle can still pair
everyone who has not met yet exactly once (a player left out of an even
field, say, cannot catch up). If the round differs from the table the
dialog shows the table's boards, the differences, any breach and the line
the TRF gets, for example `### MPA @ Round 1: 1-4 2-3 => 1-2 3-4`
(starting numbers; `5=BYE` for the player sitting out). As for a Swiss
round, the tick *I understand - keep my pairings and record the alteration*
keeps them. A round robin's earlier rounds can also be edited by hand in
the same way, and are judged the same.

### Other confirmations

- **A round that is not the latest.** Editing an earlier round asks for a
  tick, because later rounds were paired from it. In FIDE mode only the last
  two rounds played can be changed ([FIDE mode](02-fide-mode.md)).
- **A round that was already sent to the rating office.** Changing who played
  whom in a sent round needs the tick *I understand - change the sent round N
  anyway* ([Sending to FIDE](11-fide-report.md)).

## Undoing a round

> [!WARNING] Unpairing deletes results
> **More**, **Unpair round** (shown on the last paired round only) deletes that
> round and every result in it, after a confirmation. The program takes a
> restore point first ([Accounts, sharing and hand-off](15-accounts-and-handoff.md)).

In a Swiss match format the two rounds of a match go together. A round that
has been sent to the rating office cannot be unpaired.

## Entering results

Results are entered on the same page. See [Results](07-results.md).
