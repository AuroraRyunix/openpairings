# FIDE mode

FIDE mode means that the tournament is handled the way FIDE's regulations
for pairing and reporting say it must be handled. There is no switch to turn
it on: **every new tournament is in FIDE mode**, and stays in it until the
arbiter leaves it on purpose or changes a setting that the FIDE rules do not
allow.

## What FIDE mode gives you

A new tournament starts with the settings the FIDE rules describe:

- Swiss pairing by the FIDE Dutch system, round robin by Berger tables.
- The initial colour drawn by lot (C.04.3 5.1), unless you set it yourself.
- Scoring 1 - ½ - 0, with the pairing-allocated bye worth a win.
- FIDE's default tie-breaks for the type of tournament (see
  [Standings and tie-breaks](08-standings-and-tiebreaks.md)).
- The rules of [Article 16 of C.07](08-standings-and-tiebreaks.md) for
  games not played.

## What FIDE mode refuses

Once the first round is paired, FIDE mode **locks** the settings that decide
what already happened. The locked settings are: the number of rounds (and
the number of cycles of a round robin), the points for a win, draw and loss,
the match points of a team event, the value of the pairing-allocated bye,
the acceleration, the pairing system and the tie-break list. Their fields on
the Settings pages are greyed out. There is no *Unlock* button for them in
FIDE mode (outside FIDE mode the other settings that lock after round 1
have one).

FIDE mode also closes old rounds.

> [!FIDE] C.04.2 4.3
> A wrong result, pairing or colour can be corrected only in the last two
> rounds played.

With round 7 played and round 8 paired, rounds 6, 7 and 8 can be changed;
round 5 and earlier are refused with the message that a mistake found later is
corrected after the tournament, in the rating report only. The result of a
postponed game can always be entered.

In a team event, the teams' rosters and board orders are fixed once round 1
is paired (a new player can still be added at the bottom of a team, as a
reserve).

FIDE mode makes **no TRF and no final standings while a postponed game has no
result**. Every TRF download, the file made by *Send…* and the standings
after the last round are refused, with the open games listed. Enter their
results, or record a game as **not played in this event** (Settings, Export),
which takes the tournament out of FIDE mode. See
[Postponed games](07-results.md).

## Settings that take a tournament out of FIDE mode

> [!FIDE] Departures from FIDE
> A few settings change who plays whom, or what a game is worth, in a way the
> FIDE rules do not describe. Choosing one of them takes the tournament out of
> the mode.

The settings are:

- the pairing system **Keizer** (it is not a FIDE system);
- **Pair each category independently**, which pairs each category as a
  separate tournament;
- the **Swiss match format** (each pairing played twice in a row with colours
  reversed);
- *Late entrants' pairing numbers* **After the field**, which gives a player
  who joins late the next free number instead of the one their rating earns;
- **postponed games** counted as anything other than a draw for both
  players;
- scoring in which a draw is worth more than a win, or the bye more than a
  win.

The Settings pages say which settings do this, with a link to the setting.
Nothing is refused, but while the tournament is in FIDE mode **the program
always asks first** (see *Leaving FIDE mode* below). The round in which the
tournament first left the mode is recorded for the report.

Other organiser choices that change the pairing without being a FIDE rule
(a bye exclusion or preference, "only if possible" pair wishes, extra points
counted in the pairing) are also recorded for the round they changed, and the
FIDE report lists those rounds. They ask the same question when a pairing
would actually be moved by one of them. See
[Byes and absences](05-byes-and-absences.md) and [Pairing a round](06-pairing.md).

Things that FIDE's own regulations allow are not departures and do not
change the mode: other point values for a win, draw and loss (as long as no
game scores less than a lesser result), a half-point bye, extra points,
the choice of tie-breaks, a hand-set standings order, and changing the
boards of a round by hand ([Pairing a round](06-pairing.md): hand edits are
a manual pairing alteration that the regulations foresee, so they do not end
FIDE mode; a difference from the pairing checker is recorded in the report
instead).

## Leaving FIDE mode

There are two ways out, and both ask the same two questions.

- **On purpose:** Settings, **FIDE**, **Leave FIDE mode…**
- **By an action that is not allowed in FIDE mode.** These are: saving a
  Settings page (Options, Scoring) with a setting from the list above
  (Keizer, the Swiss match format, late entrants after the field, postponed
  games counted differently, a draw or the bye worth more than a win); switching on *Pair each category
  independently* on the Categories page; and pressing a pair button when the
  round, as it would be paired, is moved by a soft rule (an "only if
  possible" wish), by a bye exclusion or a bye preference, or by extra points
  counted in the pairing; and recording a postponed game as *not played in
  this event* on the Export page.

Before anything is written the program shows the dialog *Leave FIDE mode?*
in two steps (this is the double confirmation that the FIDE tournament
handler checklist calls Level 4):

1. *This is not compliant with the FIDE regulations.* It lists what takes
   the tournament out of FIDE mode and asks whether to continue. **Yes,
   continue** goes to the second question; **Cancel** (or <kbd>Escape</kbd>) closes
   the dialog.
2. *Stay in FIDE mode?* **Yes, stay in FIDE mode** closes the dialog;
   **No, leave FIDE mode** carries out what you asked: the settings are
   saved, the toggle is switched on, or the round is paired.

![The Leave FIDE mode dialog at its first step, listing what takes the tournament out of FIDE mode](screenshots/02-leave-fide-mode-dialog.png "The first question of the Leave FIDE mode dialog")

Cancelling at either step changes nothing: the settings are not saved and
the round is not paired. The second question lists what leaving does:

- **It is for good.** The tournament can never return to FIDE mode, even if
  you set every setting back.
- The tournament records from which round it was not in FIDE mode, and the
  TRF26 copies of the report say so in a comment line (`FIDE mode exited @
  Round N`), so whoever checks the file knows where to look more closely. (The
  file made by *Send…* contains records only, no comment lines; see
  [Sending to FIDE](11-fide-report.md).)
- The locked settings and the closed rounds can be changed afterwards, and the
  program no longer stops a change that FIDE rules forbid.
- Every page of the tournament shows a line, *Not in FIDE mode*, with a link
  that explains what it means.

> [!WARNING]
> Leave FIDE mode only for an event that nobody sends to FIDE: a club
> championship with its own rules, a Keizer evening, an event where you
> have to change something the rules forbid.

## The FIDE page of the settings

Settings, **FIDE** also holds the identifiers the report to FIDE needs: the
FIDE tournament ID (one for the whole tournament, or a different one for
ranges of rounds), the event code, and the box *This tournament is FIDE-homologated
(rated/reportable)*. When that box is ticked, organiser-only bye
preferences are not applied (they are not FIDE rules), and the tournament ID
becomes a required field. The officials (chief arbiter, deputies) and the
norm-related data are entered on the Tournament page; see
[Tournament set-up](03-tournament-setup.md) and [Sending to FIDE](11-fide-report.md).

![The FIDE page of the settings with the tournament ID, event code and the homologated tick box](screenshots/02-settings-fide-page.png "Settings, FIDE")
