# Byes and absences

A player who does not play a round is recorded in one of a few ways. They
differ in how the pairing treats the player, in what the round is worth, and
in how the tie-breaks of C.07 treat it.

## The kinds

| Kind | How it arises | Worth | Paired? |
| --- | --- | --- | --- |
| **Pairing-allocated bye** | The program gives it, when the number of players to be paired is odd. | The *Pairing-allocated bye* value on the Scoring page (a win by default). | It is a board of the round with no opponent. |
| **Absent for a round** | The arbiter marks the player absent for certain rounds, or for the whole event. | *Points for a round sat out* on the Scoring page (nothing by default). | Not paired in that round. |
| **Withdrawn (forfeit)** | The arbiter marks the player as withdrawn (*Forfeit*). | Nothing: the player is not paid the absence value either, and in a round robin every game from then on is a forfeit loss. | Not paired in any later round. |
| **Forfeit win / loss of a game** | A pairing whose result is entered as a forfeit (1-0 FF, 0-1 FF, 0-0 FF). | A forfeit win scores the win, a forfeit loss the loss. | It is an ordinary pairing. |
| **Half-point or zero-point bye** | Arrives with an imported SWAR or TRF file, or from the hand-off of another copy. | A half-point bye is worth a draw; a zero-point bye nothing. | Not paired. |

Details of the scoring are in [Standings and tie-breaks](08-standings-and-tiebreaks.md).

## Marking absence on the Players page

The presence cell of a player (column *Pr.*) shows and sets presence, as
explained in [Players and rating lists](04-players-and-ratings.md):

- Open the cell's menu (right-click, or `Space` with the keyboard) to set
  the player **Absent** or **Present**; in the registration form the
  checkbox **Absent** means absent for the whole event and the field **Absent at
  the rounds** takes the rounds to sit out, written `3,5` or `2-4` (commas,
  semicolons, spaces and ranges are accepted).
- **Forfeit** in the registration form withdraws the player.
- The menu on the header of the column marks everybody present or absent at
  once; use this at the start of the event or the start of a round.

An absent player is not paired in that round. Their absence is scored as set
on the Scoring page (*Byes and absences*). The Pairings page and the printed
pairing list (option *with absentees section*) list the players who are not
playing, with the value of the round for each.

Mark the absences **before** you pair the round. A player who turns up late
can be marked present again and paired by hand (see below), or entered in the
next round.

## The pairing-allocated bye (odd number of players)

If the number of players to be paired in a Swiss round is odd, one of them
gets the pairing-allocated bye. The pairing engine selects the player by the
rules of C.04.3: it is given to a player in the lowest score group in which a
legal pairing of everybody else is still possible, and never to a player who
has already had a pairing-allocated bye or has won a game by forfeit or been
given a full-point bye. The player is shown on the Pairings page as a board
with *bye*, and the explanation page says why that player was chosen and
what each other candidate would have cost
([Pairing a round](06-pairing.md)).

The bye is scored as the **Pairing-allocated bye** value (Settings, Scoring):
a win by default, but it can be set to a half point or to another value.
The value cannot be changed after the first round in FIDE mode.

In a round robin with an odd number of players, each player sits out one round
(the Berger table pairs the "highest number" against nobody). The program
records that round as a zero-point bye for that player. In Keizer a player
without an opponent scores half of his own rung.

## Byes by hand

In a paired round, the Pairings page lets you change who plays whom or who
sits out. The *Hand edits* menu (right-click a player's name in the round)
offers:

- **Mark absent for this round**: the player's seat is emptied and the
  player moves to the *Not playing* list;
- **Pair with another player who isn't playing**: puts two players of the
  *Not playing* list in a board of their own;
- **Award a bye to the remaining player**: gives a player the
  pairing-allocated bye;
- **Put in an empty seat**, **Swap with…**, **Delete this board**.

Every hand edit first shows a confirmation with the boards as they are now
and as they will be. See [Pairing a round](06-pairing.md).

*This chapter describes the current behaviour. The program has no separate
button to *request* a half-point or zero-point bye for a future round; a
half-point bye arrives from an import, and a player who will miss a round is
marked absent for it, scored by the Scoring page.*

## Organiser's bye preferences

Some events want to keep a bye away from a player (a long journey), or
want to give it to a particular player. These preferences are not FIDE rules.
They are switched off by default. To use them turn on **Bye preferences**
on the Features page (Account menu, *Features*, Belgian pack). The player's
form then offers *Exclude from the pairing-allocated bye* and *Pairing-allocated
bye preference*, each for all rounds or certain rounds:

- **Must get it, if a legal pairing allows** - the player gets the bye
  whenever the round has one, provided the rest can still be paired legally
  and the player has not had one before (FIDE rule C2 is never overridden);
- **Rather gets it** and **Rather not** - decide among the players on the
  score that gets the bye, never lifting it to another score.

**Exclude from the pairing-allocated bye** means the player is treated as
one who already had a bye: the engine never gives it to them. When no legal
round can keep the bye away from every excluded player, the Pairings page says so and offers **Pair anyway,
ignoring the exclusion for <name>**.

All of these apply to the Ainalrami engine only (they are not given to JaVaFo),
are not applied when the tournament is FIDE-homologated, and are recorded in
the round's explanation, the audit trail and the notes of the TRF export,
because the round no longer is what a FIDE-endorsed program would pair.

## Byes in the FIDE report

The TRF report (see [Sending to FIDE](11-fide-report.md)) writes each kind
with its own code: `U` for the pairing-allocated bye, `F` for a full-point
bye, `H` for a half-point bye, `Z` for a zero-point bye or an absence, `-` for a
forfeit loss and `+` for a forfeit win. A bye the arbiter has already granted for a round
that has not been paired is written in record 240.
