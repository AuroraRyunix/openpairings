# Import and export

OpenPairings reads and writes several formats. They differ in purpose:

| Format | Purpose | Direction |
| --- | --- | --- |
| TRF26 / TRF16 | FIDE's tournament report file, for the rating office and for other pairing programs | export and import |
| JSON backup | A faithful copy of a whole tournament, for OpenPairings itself | export and import |
| SWAR (`.swar`) | The save file of the Belgian SWAR program | import and export (Belgian pack) |
| CSV results | Results of a round typed in a spreadsheet | import |
| CSV players | The player list | export |
| PGN | The games of the tournament, without moves | export |
| FIDE forms (Excel) | IT3, FA1, IA1, IT4 | export |

Importing never overwrites an existing tournament: every import makes a new
tournament.

## Importing

On the **Tournaments** page the import buttons open a panel with a file
chooser or a drag-and-drop area.

### TRF file

**Import a TRF tournament** reads a `.trf` file in TRF26 or TRF16 format and
creates a complete tournament: the header data (name, city, federation,
dates, time control, arbiters, round dates), the players with their FIDE IDs,
ratings, titles and birth dates, the rounds, the pairings, the results and the
byes. The starting rank of the file becomes the pairing number. The type of the
tournament is taken from the file (Swiss, round robin, team). The unknown result `?`
comes back as a postponed game. Team files give the teams and their board
orders, and the matches of each round that can be worked out from the boards
(a round whose matches are unclear is named, not guessed).

The program does not trust the file: it recomputes the points and lists every
player whose total differs from the file, and every round of a Swiss
tournament is **checked against the pairing rules**: a rematch, two players
who were both due the same colour, a pair that the file's own prohibition
record forbids, a second pairing-allocated bye.

**The review step.** Nothing is written until you have seen the review that
follows the choice of the file:

- *The version.* The review says whether the file was read as TRF26 or as
  TRF16. TRF16 has no records for the point system, the tournament type or the
  tie-breaks; the review then lists what the import used instead.
- *The adjustments.* Every place where the import had to decide something is
  listed: the default scoring used when the file has no point system, the
  tournament type imported when the code is missing or unknown, round-robin
  cycles reduced to what the program plays, tie-breaks that were not in the
  file or that the program does not compute, a number of rounds taken from the
  rounds the file holds, deputy arbiters beyond the fourth, team forfeit and
  bye points, extra points outside the scoring, games without an opponent that
  were imported as byes, and rounds that were not checked because only a
  Dutch-system Swiss can be.
- *Rounds that break a pairing rule.* If a round of the file breaks a rule, the
  review is headed *This file's rounds break the FIDE pairing rules* and says
  that importing is not compliant with the pairing rules. This is a warning
  that needs your explicit confirmation (Level 3). The button then reads
  **Import anyway**; otherwise it reads **Import**. **Cancel** imports
  nothing.

A confirmed import creates the tournament with the rounds exactly as the file
records them. What the import adjusted and every rule it found broken are kept
with the tournament and in its audit log. For each such round the TRF copies of
the report carry a comment line, `### Import @ Round r: ...`, so whoever checks
the file sees where the pairings were not the program's own. (The file made by
*Send…* has records only and no such line.)

### JSON backup

**Import an OpenPairings backup** reads a file made by **Export full backup
(JSON)** (below), up to 10 MB. It gives a new tournament, owned by you, with
the settings, officials, teams, every player field, rounds, results, byes,
forbidden pairings and the record of what was sent to the rating office. The
original is never touched, even when you import your own file again. If
anything goes wrong nothing is left behind.

What does not travel: restore points, the logo, the phones enrolled for result
entry, the lock of a hand-off, and everything that would act on its own:
the publishing switch and address and the open entry form (publishing has to
be switched on again for the copy, [Publishing](14-publishing.md)). The audit
trail and the collaborators travel only in a hand-off file, and the
collaborators come back as pending invitations that each person must accept.

### SWAR file

With the *SWAR import* feature on (Account menu, **Features**, Belgian pack),
**Import a SWAR tournament** reads a `.swar` file with players, rounds,
results, byes, scoring configuration (including the 3-2-1 club scoring),
absences and the categories. Players without a FIDE ID are looked up in the
FIDE list and you confirm the matches in a *Resolve FIDE ids* step. If a
tournament that looks the same already exists, the panel says so and offers to
open it or import another copy. A SWAR team competition can be imported as
an individual tournament (the games), not as a team event.

### Results from a CSV file

On the Pairings page, **More**, **Import results (CSV)**. See
[Results](07-results.md).

### Receive a hand-off

**Receive a hand-off** takes in a tournament that another copy of the program
handed over. See [Accounts, sharing and hand-off](15-accounts-and-handoff.md).

## Exporting

Settings, **Export** (the page *Export / backup*):

### TRF (FIDE rating report)

The TRF26 file for the rating office. A table lists every paired round with
its state (being played, ready to send, sent) and a tick; **Download a copy
(not for rating)** and **All rounds (TRF copy, not for rating)** give copies,
and **Send…** gives the file for the rating office and marks the games as
sent. This is a part of the reporting procedure and is explained in
[Sending to FIDE](11-fide-report.md).

The file written is TRF26, the 2026 report format. It has the player rows in
the TRF16 layout, and the tournament records: number of rounds (142), initial
colour (152), the point system if it is not 1, ½, 0 (162), the program (182),
the type of tournament (192, for example `FIDE_DUTCH_2025` for rounds
paired by the Ainalrami engine, `FIDE_DUTCH_2017` for JaVaFo, `_BAKU` with
acceleration, `BERGER_ROUNDROBIN_Gn`, `FIDE_TEAM_TYPEA_MP_GP`, or
`CUSTOM_SWISS` for Keizer), the tie-breaks (202), the rate of play (222), the
Baku virtual points (250), the prohibited pairings (260), a bye granted for a
round that is not yet paired (240) and the administrative extra points (299).
Notes the program wants a human reader of the file to see are written as `###`
comment lines in copies. Each paired round can also be selected by
`?rounds=1-5` in the address of the download (ranges and single rounds, such
as `1-3,6`).

The older TRF16 spelling of the extension lines, which JaVaFo and
bbpPairings read, is available by adding `?dialect=javafo` to the address of
the download.

### Backup and copy

- **Export full backup (JSON)** - the file described above, for this
  tournament. On the Tournaments page **Export all (JSON)** exports every
  tournament you own in one file.
- **Export .swar (v7, experimental)** (Belgian pack) writes a SWAR file. A
  line lists what the SWAR format cannot hold of this tournament.
- **Export SWAR results page (.html)** (Belgian pack) writes the SWAR-style
  results page.
- **Publish to the federation's results site** (Belgian pack, administrator).

### Players (CSV)

**Export players (CSV)**: you choose the columns (add, remove, move up or
down), the column separator (comma, semicolon for Excel on a Belgian or Dutch
machine, tab, pipe), the order of the rows (starting rank and rating, or
name), whether to leave out absent players, and whether to add the UTF-8
marker that makes Excel read the accents right.

### PGN

Pairings page, **More**, **PGN (metadata only - no moves are recorded)**:
this round or all rounds, with or without board numbers, or a range of boards.
The program does not record moves; each game in the PGN file has the
players, the round, the date, the result and a result token as its move text.
It is a valid PGN file, but a game that cannot be replayed.

### The FIDE forms

**Advanced**, **Norms** ([Categories and norms](13-categories-and-norms.md)).

## Backups made by the program

A tournament database backup is written automatically about once a day (see
[Accounts, sharing and hand-off](15-accounts-and-handoff.md)), and a restore
point is saved before every action that is hard to undo. These are separate
from the files above.
