# Entering results and postponed games

## Entering a result

Results are entered on the **Pairings** page, in the round's table. Each board
has a result field between the two players.

### With the keyboard

Click the result field of the first board to give it focus (one click; the
list does not open). Then type

- <kbd>1</kbd> for a win for White (1-0),
- <kbd>2</kbd> for a draw (½-½),
- <kbd>3</kbd> for a win for Black (0-1).

The result is saved and the focus moves to the next board, so that
<kbd>1</kbd><kbd>3</kbd><kbd>1</kbd><kbd>3</kbd><kbd>1</kbd><kbd>2</kbd>
fills in six boards without touching the mouse. The digits are read by
physical key, so the top row and the numeric keypad both work on any keyboard
layout. The arrow keys walk through the other values without saving every one
on the way; a second click on the field opens the list, for the results that
have no digit.

![The results column of a round with the result list open on one board](screenshots/07-result-entry.png "Entering results on the Pairings page")

### With the mouse or a phone

Choose the result from the list. On a phone or a narrow screen each board
also has three large buttons, 1-0, ½-½ and 0-1, the one on file pressed.
Pressing the pressed one again changes nothing.

### The results in the list

| Result | Meaning |
| --- | --- |
| 1-0, ½-½, 0-1 | the normal results |
| ½-0, 0-½ | a drawn game with a disciplinary point adjustment |
| 1-0 FF, 0-1 FF | a win by forfeit (the game was not played) |
| 0-0 FF | a double forfeit: neither player turned up |
| 0-0 | both lose, the game was played |
| 1-0, 0-1, ½-½ "played, not rated" | a game that was played but is not rated |
| * postponed by White / by Black | a postponed game (only if the tournament allows it) |
| … (blank) | no result |

A forfeit is an unplayed game for the tie-breaks of C.07
([Standings and tie-breaks](08-standings-and-tiebreaks.md)); a game that was
played but is not rated is a played game that FIDE does not rate.

### Clearing and correcting a result

Choosing the blank value on a board that already has a result does not clear
it at once: a box asks *Clear the recorded result?* and you confirm with
**Yes, clear it** or cancel. Changing a result to another one is saved at
once and written to the audit trail, with the old and the new value.

A result in a round that was already **sent to the rating office** is changed
only after a confirmation.

> [!FIDE]
> In FIDE mode a result can be changed only in the
> last two rounds played ([FIDE mode](02-fide-mode.md)); an earlier mistake is
> corrected after the tournament, in the report to the rating office.

When two arbiters work on the same round, a result is refused if the
players at the board are no longer the ones your page showed - a colleague
swapped or replaced a player after your page was drawn. The message is *Not
saved: this board changed*; nothing is written. Reload the page and enter the
result on the board as it is now. A phone used for results says the same for
its board. Two arbiters entering a different result on the same, unchanged
board is not refused: the last one entered stands, and both are in the audit
trail.

### Correcting a result for the rating report only

A wrong result found after the next round is already over cannot change
the pairings that were made with it (C.04.2:4.3). Under each finished board
of such a round, **Correct for rating…** records the right result for the
rating report only: the pairings and the standings keep the result they
used, the FIDE report carries the corrected one, and its TRF26 copy adds a
`### Rating correction @ Round r` line saying which result the event used.
Changing the board's result the ordinary way removes the correction.

When the last result of a round is in, the next round can be paired.

With electronic boards in the hall, the Pairings page also has a column **Board
saw**: what the board reported, beside your entry. It never enters a result.
See [The board column](17-live-boards.md#the-board-column).

## Results from a file (CSV)

**More**, **Import results (CSV)** reads a file with one line `board,result`
per board (comma or semicolon; an optional header line). The board number is
the one printed on the pairing sheet. Accepted result words: `1-0`, `0-1`,
`1/2-1/2` (also `½-½`, `0.5-0.5`, `=`), `½-0`, `0-½`, `0-0`, `X`,
`1-0FF`, `0-1FF`, `0-0FF` (`+/-`, `-/+`, `-/-`), the unrated forms with `U`,
and `*W`, `*B`. Boards not mentioned keep their result.

> [!NOTE]
> **Nothing is saved unless every line is valid**: the page lists every problem
> (at most 50) and you fix the file and send it again.

## Results from phones

On the Pairings page, **More**, **Phone QR** opens a large dialog (close it
with the button, Escape or a click outside it). Its section **Enter results on
a phone** makes a QR code and an
8-digit code. A helper scans the QR code or types the code on their own phone
and can then enter results for that tournament only, without an account.

- A **helper** phone fills in boards that have no result, in the latest paired
  round only, and cannot change a result that is on file - also not one the
  arbiter entered a moment ago, before the phone's screen caught up.
- A **deputy** phone can enter and correct a result in any round, and can
  clear one: under a board that has a result there is a **Clear result**
  button. The first tap turns it into *Tap again to clear board N* for a few
  seconds, the second clears the board and puts it back among the unfinished
  ones. Tapping the result that is already chosen changes nothing. The button
  is absent where the program would refuse the clear (an archived tournament, a
  result already sent in a finalised TRF, a closed round in FIDE mode) and on
  helper phones.
- A phone can be limited to a range of boards.

The code expires after 24 hours and can be revoked at any time on the same
card. The phone's screen shows the players' ratings and scores, has a lock
that guards against accidental taps, and its own theme switch. A phone
cannot reach anything else in the program.

**On the desktop install** the program answers only this computer until you
switch on **Let phones on this network connect** in the same dialog and pick
this computer's address on the hall network (and, if you need to, a port;
4748 unless you change it). From then on, while at least one phone code is
active, phones on the same network reach the phone pages - result entry and
incidents, nothing else - at the address the QR code carries. Every other page
stays on this computer only. Switch it off when the round is done; the
computer's firewall may ask once whether to allow it. It is plain http on the
hall network, like the board link.

### Arbiters with their own account

An arbiter on the hosted program can work under their own name instead of a
shared code. The owner invites them in Settings, **Share / Team**, with the
role **Arbiter - results and incidents on a phone**. After accepting, the
arbiter opens `/m/connect` on their phone (the code page links to it), picks
the tournament and taps **Use this phone**; **Show a code for another phone**
shows a QR code for a second phone or for the installed app. An arbiter:

- enters and corrects results and logs incidents like a deputy phone, and
  everything they enter is in the audit trail under their own account;
- cannot open the tournament at the desk, pair, or change anything else;
- loses their phones the moment they are removed or leave.

In the Phone QR dialog, **Arbiters' boards** gives each arbiter a range of
boards; **My boards** on their phone then shows just those. The owner and the
editors can do everything an arbiter can.

### The hall view

- Each board says whether it is still **Playing** or **Finished**.
- A line under the round says how long it has been going: since the pairings
  were published, or, if they were not, since the first live board reported.
  It says which. Without either it says nothing rather than guess.
- **Find a player or a board** searches by name or board number.
- With live boards ([Live boards](17-live-boards.md)) every board also shows
  what the board in the hall saw: the same result, a result not entered yet,
  or, in red, a different one. It is a warning; the phone never enters it.
- When two arbiters enter different results for the same board, the second is
  refused and both phones show the disagreement in red on that board. Nothing
  is overwritten; settle it and enter the right one.
- **Keep the screen on** stops the phone from going dark while the page is open
  (where the phone supports it), and **One-handed layout** moves the controls to
  the bottom edge with bigger result buttons. Both are remembered per phone.

### Manubrium Lite, when the wifi drops

These phone pages are **Manubrium Lite**: a page in the phone's browser, served
by the program itself, nothing to install. It keeps working when the hall wifi
drops, as long as the page stays open:

- A tapped result goes into the phone's outbox first and is sent from there,
  in the order it was entered. Without a connection it waits on the phone and
  is sent when the wifi is back. The header says how many are waiting, and each
  board shows *Waiting*, *Sent* or *Not accepted*.
- The program judges every result when it arrives, not when it was tapped. A
  result that is no longer allowed - the phone's code was revoked, the round is
  no longer the latest for a helper, the players on the board changed, or the
  board got a different result in the meantime - is **not accepted**, and the
  phone says why, per board, until it is dismissed. A result entered at the
  desk is never overwritten by a phone that was out of reach.
- Sending the same result twice (a lost reply, a reload) saves it once.
- Clearing a result, the lock, the round switcher and **More** need a
  connection.
- **Leave** on a phone with results still waiting asks first: leaving drops
  them.

Running the whole tournament from a phone - pairing, players, standings - is
the full Manubrium app, which connects to the program separately.

### Incidents logged at the boards

Each board on the phone has an incident button.

- A **deputy** phone logs an incident: illegal move, clock problem, phone or
  electronic device, complaint, time added, game rewound, arbiter call or
  other, with a short note and, if useful, a photo taken there and then (the
  phone shrinks it before sending; at most about 2 MB arrives). The
  board, the round, the players and the time come with it; the note is not the
  place for names.
- A **helper** phone has **Call arbiter** instead: it only logs an arbiter call
  for that board.

Incidents go through the same outbox as results, so they also wait for the
wifi. On the Pairings page a line under the round says how many it has, and
**More**, **Incidents** lists them all, per round, newest first; a new one
appears while the page is open. A photo shows as a thumbnail there, and only
there: it is not on any public page, an arbiter account cannot open it, it
does not travel in an export, and it goes when the tournament is deleted.
Every incident is also in the audit trail. A printable incident report comes
later.

## Postponed games

A game that cannot be played in its round (moved by agreement or adjourned)
is **postponed**. The tournament goes on.

**Turn it on.** Settings, Scoring, *Postponed games*: **Allow postponed
games**. With it off, no postponed result is offered anywhere, except in a
round robin, which always offers it: its schedule does not depend on scores,
so the switch is shown on and cannot be turned off there. The same
page sets what a postponed game counts as until it is played, for the player
who postponed it and for the opponent: a draw for both by default. The value is
saved on each game when it is postponed, so changing the setting later
affects only new postponed games.

> [!FIDE]
> A draw for both players is the FIDE rule. Any other value takes the tournament
> out of FIDE mode.

**Record it.** Choose *postponed by White* or *postponed by Black* as the
result of the board. Until the game is played it counts as the setting says
in the standings, the tie-breaks and the pairing of every later round. A
postponed game is also recorded automatically when you pair a round while
boards without a result remain and choose **Record missing results as
postponed and pair round N**. Pairing a round while a postponed game from an
earlier round is open asks for a confirmation that names the players: they
are paired on a provisional score.

**Boards nobody entered, in a round robin.** A round robin pairs every round
in advance, so a game that is not played often just stays without a result.
Once a *later* round has all its results, such a board counts as a postponed
game nobody asked for: both players get what the setting gives the opponent
(a draw by default) in the standings and the tie-breaks, the standings say how
many games are still open, and the results site shows *Result not yet in* on
the board. Nothing is written on the board: the TRF and the files for rating
still see a board without a result, and the round cannot be sent until it has
one. A game played early in a later round does not count as that round having
its results; the round must be complete. To have the standings go on the same
evening, mark the board *postponed by White* or *postponed by Black* yourself.
Swiss, Keizer and team tournaments do not do this: there, the next round cannot
be paired past an empty board anyway.

**Open games.** The Pairings page lists the open postponed games with a
button to their round. Each game may carry the agreed date (never a deadline;
nothing becomes overdue) and a short history of changes. A game can be played
at any time: enter the real result, with the date it was played. A result
that is not a draw over a postponed game asks for a confirmation first.

**Printed notices.** A notice for each player with the round, board,
opponent, colour, agreed date and venue is on the Print page (*Postponed-game
notices*) and can be printed per game; a calendar file (`.ics`) for the agreed
date can be downloaded from the same list.

**Everywhere the standings go.** While a game is open the standings, the prints and the
published standings say that they are *not final*, mark the player or team
with *1 pending*, and the tournament stays running. A round with an open
postponed game, or with only the round-robin boards described above left
without a result, does not stop the published standings: they go through the
latest such round and say how many games are still to be played (on the
results site: *Provisional: 2 games have no result yet and count as draws
until they have*). A round that is still being played does stop them, as
before. Archiving the tournament
tells you how many games are still unplayed.

**Reporting.** In FIDE mode there is no TRF that holds the round of a
postponed game without a result, and no final standings: Settings, Export
lists the open games. A file of only the rounds before it is still made, and
OpenResults keeps showing the standings, marked not final. Enter the
result, or press **Not played in this event** beside the game. That second way
asks twice (it takes the tournament out of FIDE mode, for good), and the
report then says which game it was in a `###` line. The game stays postponed:
the file for rating writes it as not played (`0000 - Z`), and if it is played
later after all, its real result goes to the FIDE in a separate file for the
postponed games, because a game played in another rating period is reported
as a separate tournament. Outside FIDE mode a postponed game is written `?` in
the TRF copies and as not played in the file for rating, without asking. See
[Sending to FIDE](10-fide-report.md).
