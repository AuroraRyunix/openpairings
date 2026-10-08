# Sending to FIDE: the rating report

A rated tournament is reported to FIDE in a TRF file (Tournament Report File).
OpenPairings builds the file; **it does not upload it**. You (or the rating
officer of your federation) send the file to FIDE's rating server in the way
your federation uses. The program's job is to build a correct file, to make
sure that no game is reported twice, and to keep a record of what has been
sent.

## Before the report

Settings, **FIDE**:

- tick **This tournament is FIDE-homologated (rated/reportable)** when the
  event is to be rated; the FIDE tournament ID is then required;
- **FIDE tournament ID**: the ID of the tournament; if different parts of the
  event have different IDs, enter **Per-round FIDE-ID ranges** (from round, to
  round, ID);
- **FIDE event code**.

Settings, **Tournament** (and **Advanced**, **Norms**): the chief arbiter and
the deputies with their FIDE IDs, the federation, the venue, the rate of play
and the dates. The program reminds you of the recommended fields on the Players
and Pairings pages; none of them blocks pairing.

> [!FIDE] Bye exclusion and bye preference
> The Export page says which rounds were changed by a bye exclusion or a bye
> preference (organiser's rules, not FIDE's), because the TRF cannot record them
> and a checker replaying the file would pair those rounds differently
> ([FIDE mode](02-fide-mode.md), [Byes and absences](05-byes-and-absences.md)).

> [!WARNING]
> A TRF cannot be built until every round has a date.

## The Export page

Settings, **Export**, section *TRF (FIDE rating report)*. A table lists every
paired round with its boards and its state:

| State | Meaning |
| --- | --- |
| *Being played* | A board has no result: the round cannot be sent yet. |
| *Ready to send* | Every board has a result. |
| *Sent* | The round has been sent; the date and a receipt code are shown (for example `R5·7F2A`). |

![The Export page, section TRF, with rounds in the states Being played, Ready to send and Sent](screenshots/11-export-trf-rounds.png "Rounds and their state on the Export page")

Tick the rounds you want and press:

- **Send…** - builds the file for the rating office and **marks every game in
  it as sent**, in one step. The file is named after the type of the
  tournament, the FIDE tournament ID, the name and the rounds. It holds only
  the records of the report, no comments.
- **Download a copy (not for rating)** and **All rounds (TRF copy, not for
  rating)** - copies for your own use or another program. The file name ends
  `COPY-NOT-FOR-RATING` and the file says so in a `###` comment line.

> [!WARNING]
> A sent round cannot be sent again, and cannot be unpaired. A sent result can
> be changed only after a confirmation; changing who played whom in a sent
> round, or a player's absence in it, needs a tick *I understand - change the
> sent round N anyway*. This protects against reporting a game twice.

Rules that follow from this:

- Two arbiters pressing **Send…** at the same moment cannot both get a file:
  the database keeps one record per game sent and refuses the second.
- A copy that has been handed off to another machine, and an archived
  tournament, send nothing.
- A tournament imported from a backup, a TRF or a SWAR file may already have
  been reported. Such a copy sends nothing until you tick **This copy reports:
  allow sending** on the Export page, to confirm that this copy is the one that
  reports.
- The program keeps a **receipt** of every send (a code, the games, who sent it
  and when). If a result, a name or a FIDE ID is changed after a round was sent,
  the round and the Export page show *Changed since sent*, with each change, so
  that you can correct it with the rating office. Nothing is ever sent again on
  its own.

## The contents of the file

The file is TRF26. Besides the players' rows (the starting rank, name, FIDE ID,
rating, title, federation, birth date, points, rank and the result of every
round with the opponent and colour) it carries the header records and the
tournament-type records listed in [Import and export](10-import-export.md).
For each round the result codes are `1`, `=`, `0` for played games, `+` and
`-` for forfeits, `U` for the pairing-allocated bye, `H` for a half-point bye,
`F` for a full-point bye, `Z` for a zero-point bye or an absence. A postponed
game whose result is unknown is `?` in a copy.

The file for the rating office never contains `?`: a postponed game that is
still open when its round is sent is written as **not played** for both players.
This way the game is neither rated twice nor lost; see below.

> [!NOTE] Left FIDE mode
> If the tournament has left FIDE mode, the copies say from which round in a
> `###` comment line. The file made by **Send…** is records only: no comment
> lines, no column ruler.

## Postponed games

In FIDE mode no file that holds the round of a postponed game without a
result is sent or copied. A file of only the rounds before it is made as
usual, such as the rating inbox's copy of a round sent earlier. The Export page lists the open games: enter each result, or press
**Not played in this event**. That asks twice and takes the tournament out of
FIDE mode; the copies then carry `### Not played @ Round 3: 5-12` for it, and
the file for rating writes it as not played (`0000 - Z`).

A game played after its round was sent is reported as a **separate tournament**
with its own name and its own FIDE tournament ID, and FIDE rates month by month.
Settings, Export, section *Postponed games* lists every postponed game with
its state, the date it was played and the file it is in:

- Enter the **date played** of each game (set when it is first played; changing it
  later is a separate step that is written to the audit trail).
- Enter the **tournament name** of the postponed-games file (by default the
  event's name plus *postponed games*) and its **FIDE tournament ID**.
- **Make this file** builds the file for one rating period (month); *Send…* marks
  its games as sent. A page note says which month and that the file must be
  sent before the end of that month. A game that has been sent in its round
  with its real result is never offered again.

## Checks

- Before the file leaves the program, every result code and every pair of
  opponents is validated; an error stops the download with a message.
- Importing the file back into OpenPairings (or any other program) is the
  best check that it says what you think it says ([Import and export](10-import-export.md)).
- A **rating validator** (YAML) is announced on the Export page and not available
  yet.

## Norm reports

The IT3 tournament report and the arbiter and player norm forms are separate
Excel files; see [Categories and norms](13-categories-and-norms.md).
