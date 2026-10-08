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
| **Expelled** | The arbiter ticks **Expelled** in the registration form. | The player is not paired in any later round and is left out of the standings. The games already played stay: the opponents keep the points and tie-breaks those games gave them. | Not paired in any later round. |
| **Forfeit win / loss of a game** | A pairing whose result is entered as a forfeit (1-0 FF, 0-1 FF, 0-0 FF). | A forfeit win scores the win, a forfeit loss the loss. | It is an ordinary pairing. |
| **Full-point bye** | The arbiter gives it, from the *Not playing* list of a paired round, to a player who sits that round out; or picks it for a coming round when **Ask the bye type for each absence** is on. | What a win is worth. | Not paired; the player can no longer get the pairing-allocated bye. |
| **Half-point or zero-point bye** | Arrives with an imported SWAR or TRF file, or from the hand-off of another copy; or is picked for a coming round when **Ask the bye type for each absence** is on. | A half-point bye is worth a draw; a zero-point bye nothing. | Not paired. |

Details of the scoring are in [Standings and tie-breaks](08-standings-and-tiebreaks.md).

## Marking absence on the Players page

The presence cell of a player (column *Pr.*) shows and sets presence, as
explained in [Players and rating lists](04-players-and-ratings.md):

- Open the cell's menu (right-click, or <kbd>Space</kbd> with the keyboard) to set
  the player **Absent** or **Present**; in the registration form the
  checkbox **Absent** means absent for the whole event and the field **Absent at
  the rounds** takes the rounds to sit out, written `3,5` or `2-4` (commas,
  semicolons, spaces and ranges are accepted).
- **Forfeit** in the registration form withdraws the player. The standings
  and the printed standings mark such a player *withdrawn* and keep the
  points scored so far ([Standings and tie-breaks](08-standings-and-tiebreaks.md)).
- **Expelled** in the registration form expels the player. The presence cell
  shows `E`. An expelled player is not paired any more and does not appear in
  the standings.
- The menu on the header of the column marks everybody present or absent at
  once; use this at the start of the event or the start of a round.

![The presence cell menu on the Players page with Absent and Present](screenshots/05-presence-cell-menu.png "Setting a player absent")

An absent player is not paired in that round. Their absence is scored as set
on the Scoring page (*Byes and absences*). The Pairings page and the printed
pairing list (option *with absentees section*) list the players who are not
playing, with the value of the round for each.

### Half-point byes

An absence that the Scoring page scores as a draw is a half-point bye.

> [!FIDE] C.05:6.7.4
> The rules allow a player only one half-point bye in a tournament, and none
> to a player who received conditions or free entry.

The program helps in two ways:

- When a save of the registration form would give a player a **second or
  later half-point bye**, the form shows a warning for the rounds concerned
  (*The rules allow a player only one half-point bye in a tournament*) and
  the **Save** button asks *Save it anyway?* The save goes ahead only after you
  confirm.
- The box **Not eligible for half-point byes** marks a player who may not
  have one. While it is ticked, a half-point absence is refused for that
  player, and the box cannot be ticked for a player who already has one; the
  message names the rounds.

### Asking the bye type

By default a round sat out is worth what the Scoring page pays an absence,
and that is all there is to it. Some events want to decide per absence: a
half-point bye for the player who asked in time, a zero-point one for the
player who did not. Turn on **Ask the bye type for each absence** on the
Scoring page, under *Byes and absences*. It is off by default, and only an
individual Swiss offers it.

With it on, the registration form shows a line for every round in **Absent
at the rounds** that is not paired yet, with three choices: **Half-point
bye**, **Zero-point bye** and **Full-point bye**. The one the Scoring page
would give is already picked (counting the two limits), so for most absences
**Save** is the only click. Pick another one where the answer differs.

- The pick is kept with the round. Pairing the round leaves the player out
  and scores the bye as picked; unpairing the round keeps it; taking the
  round out of the player's absences drops it.
- The FIDE report writes it with its own letter, in record 240 while the
  round is not paired, and an import of that file brings the same bye back.
- The half-point bye rules above count a picked half-point bye: a second one
  asks *Save it anyway?*, and a player marked not eligible cannot be given
  one. For such a player the zero-point bye is picked instead.
- Picking a full-point bye shows the same notice as on the Pairings page:
  the pairing regulations do not describe it, and it should stay
  exceptional. The player cannot get the pairing-allocated bye later, and
  once the round is paired the report adds its `### FPB` line.

The same question comes up in a round already paired: **Mark absent for
this round** on the Pairings page (see [Byes by hand](#byes-by-hand)) shows
the three choices in its confirmation, picked the same way. A half-point bye
for a player marked not eligible cannot be applied there; a second
half-point bye needs its own tick, *I understand - give it anyway*; a
full-point bye shows the notice above.

> [!NOTE]
> The two limits on paid absences decide the answer picked in advance. For
> *only a player's first N rounds sat out are paid*, every earlier
> half-point or full-point bye counts as one of the N, exactly as an absence
> would: with N = 2, a player's third round off is offered as a zero-point
> bye. A zero-point bye pays nothing and uses nothing up. The bye you pick
> is scored as picked, though, whatever the limits say: where they would pay
> less for that round (you pick a half-point bye for the third round anyway),
> the form and the confirmation say so, and do not stop you. Changing the
> absence points later does not change a bye already picked.

> [!WARNING]
> Mark the absences **before** you pair the round. A player who turns up late
> can be marked present again and paired by hand (see below), or entered in the
> next round.

## The pairing-allocated bye (odd number of players)

If the number of players to be paired in a Swiss round is odd, one of them
gets the pairing-allocated bye.

> [!FIDE] C.04.3
> The pairing engine selects the player by the rules of C.04.3: the bye is
> given to a player in the lowest score group in which a legal pairing of
> everybody else is still possible, and never to a player who has already had
> a pairing-allocated bye or has won a game by forfeit or been given a
> full-point bye.

The player is shown on the Pairings page as a board
with *bye*, and the explanation page says why that player was chosen and
what each other candidate would have cost
([Pairing a round](06-pairing.md)).

The bye is scored as the **Pairing-allocated bye** value (Settings, Scoring):
a win by default, but it can be set to a half point or to another value.

> [!NOTE]
> The value cannot be changed after the first round in FIDE mode.

In a round robin with an odd number of players, each player sits out one round
(the Berger table pairs the "highest number" against nobody). The program
records that round as a zero-point bye for that player. In Keizer a player
without an opponent scores half of his own rung.

## Byes by hand

In a paired round, the Pairings page lets you change who plays whom or who
sits out. The *Hand edits* menu (right-click a player's name in the round)
offers:

![The Hand edits menu opened on a player's name in a paired round](screenshots/05-hand-edits-menu.png "The Hand edits menu")


- **Mark absent for this round**: the player's seat is emptied and the
  player moves to the *Not playing* list; with **Ask the bye type for each
  absence** on, the confirmation asks which bye it is
  ([Asking the bye type](#asking-the-bye-type));
- **Pair with another player who isn't playing**: puts two players of the
  *Not playing* list in a board of their own;
- **Give the pairing-allocated bye** (on a player of the *Not playing*
  list): gives that player the bye, scored as the Scoring page says;
- **Award a bye to the remaining player**: gives the pairing-allocated bye to
  the player left alone on a board whose opponent was removed;
- **Put in an empty seat**, **Swap with…**, **Delete this board**.
- **Give a full-point bye…** (on a player of the *Not playing* list): the
  player scores a win for the round without playing. The FIDE report writes
  it as `F`, with a `### FPB @ Round r` line, and the player cannot get the
  pairing-allocated bye in a later round. **Take back the full-point bye…**
  makes the player absent again.

> [!FIDE] Full-point byes
> A notice first says that the pairing regulations do not describe full-point
> byes and that they should stay exceptional.

Every hand edit first shows a confirmation with the boards as they are now
and as they will be, and warns, with a tick, when the bye would go to a
player who already had one, won a game by forfeit or had a full-point bye.
Hand edits are made in a session that is checked when it is finished. See
[Pairing a round](06-pairing.md).

*A half-point or zero-point bye for a coming round is requested by marking
the player absent for it: the Scoring page decides what it is worth, or,
with **Ask the bye type for each absence** on, the registration form asks
(see [Asking the bye type](#asking-the-bye-type)).*

## Organiser's bye preferences

Some events want to keep a bye away from a player (a long journey), or
want to give it to a particular player.

> [!FIDE] Departure from FIDE mode
> These preferences are not FIDE rules. They are switched off by default, and
> are not applied when the tournament is FIDE-homologated.

To use them turn on **Bye preferences**
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

All of these apply to the Ainalrami engine only (they are not given to JaVaFo)
and are recorded in
the round's explanation, the audit trail and the notes of the TRF export,
because the round no longer is what a FIDE-endorsed program would pair.

## Byes in the FIDE report

The TRF report (see [Sending to FIDE](11-fide-report.md)) writes each kind
with its own code: `U` for the pairing-allocated bye, `F` for a full-point
bye, `H` for a half-point bye, `Z` for a zero-point bye or an absence, `-` for a
forfeit loss and `+` for a forfeit win. A bye the arbiter has already granted for a round
that has not been paired is written in record 240.
