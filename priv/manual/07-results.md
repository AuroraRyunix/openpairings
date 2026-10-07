# Entering results and postponed games

## Entering a result

Results are entered on the **Pairings** page, in the round's table. Each board
has a result field between the two players.

### With the keyboard

Click the result field of the first board to give it focus (one click; the
list does not open). Then type

- `1` for a win for White (1-0),
- `2` for a draw (½-½),
- `3` for a win for Black (0-1).

The result is saved and the focus moves to the next board, so that `131312`
fills in six boards without touching the mouse. The digits are read by
physical key, so the top row and the numeric keypad both work on any keyboard
layout. The arrow keys walk through the other values without saving every one
on the way; a second click on the field opens the list, for the results that
have no digit.

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
only after a confirmation. In FIDE mode a result can be changed only in the
last two rounds played ([FIDE mode](02-fide-mode.md)); an earlier mistake is
corrected after the tournament, in the report to the rating office.

When the last result of a round is in, the next round can be paired.

## Results from a file (CSV)

**More**, **Import results (CSV)** reads a file with one line `board,result`
per board (comma or semicolon; an optional header line). The board number is
the one printed on the pairing sheet. Accepted result words: `1-0`, `0-1`,
`1/2-1/2` (also `½-½`, `0.5-0.5`, `=`), `½-0`, `0-½`, `0-0`, `X`,
`1-0FF`, `0-1FF`, `0-0FF` (`+/-`, `-/+`, `-/-`), the unrated forms with `U`,
and `*W`, `*B`. Boards not mentioned keep their result. **Nothing is saved
unless every line is valid**: the page lists every problem (at most 50) and
you fix the file and send it again.

## Results from phones

The **Live** page of a tournament (Pairings page, **More**, *Local view &
phone QR*) shows the round for projection and has a card **Enrol a phone to
enter results**. It makes a QR code and an
8-digit code. A helper scans the QR code or types the code on their own phone
and can then enter results for that tournament only, without an account.

- A **helper** phone fills in boards that have no result, in the latest paired
  round only, and cannot change a result that is on file.
- A **deputy** phone can enter and correct a result in any round.
- A phone can be limited to a range of boards.

The code expires after 24 hours and can be revoked at any time on the same
card. The phone's screen shows the players' ratings and scores, has a lock
that guards against accidental taps, and its own theme switch. A phone
cannot reach anything else in the program.

## Postponed games

A game that cannot be played in its round (moved by agreement or adjourned)
is **postponed**. The tournament goes on.

**Turn it on.** Settings, Scoring, *Postponed games*: **Allow postponed
games**. With it off, no postponed result is offered anywhere. The same
page sets what a postponed game counts as until it is played, for the player
who postponed it and for the opponent: a draw for both by default (the FIDE
rule). Any other value takes the tournament out of FIDE mode. The value is
saved on each game when it is postponed, so changing the setting later
affects only new postponed games.

**Record it.** Choose *postponed by White* or *postponed by Black* as the
result of the board. Until the game is played it counts as the setting says
in the standings, the tie-breaks and the pairing of every later round. A
postponed game is also recorded automatically when you pair a round while
boards without a result remain and choose **Record missing results as
postponed and pair round N**. Pairing a round while a postponed game from an
earlier round is open asks for a confirmation that names the players: they
are paired on a provisional score.

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
with *1 pending*, and the tournament stays running. Archiving the tournament
tells you how many games are still unplayed.

**Reporting.** A postponed game is written `?` in the TRF report; the real
result goes to the FIDE in a separate file for the postponed games, because
a game played in another rating period is reported as a separate tournament.
See [Sending to FIDE](11-fide-report.md).
