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

> [!NOTE]
> Importing never overwrites an existing tournament: every import makes a new
> tournament.

## Importing

On the **Tournaments** page, the **Import** menu holds the ways in (backup,
hand-off, SWAR, TRF). Each one opens a panel with a file chooser or a
drag-and-drop area.

### TRF file

**Import a TRF tournament** reads a `.trf` file in TRF26 or TRF16 format and
creates a complete tournament: the header data (name, city, federation,
dates, time control, arbiters, round dates), the players with their FIDE IDs,
ratings, titles and birth dates, the rounds, the pairings, the results and the
byes. A bye or absence the file records for the round not yet paired (a 240
record, or the `XXZ` line SWAR writes for the players absent from the next
round) comes in as a bye for that round, so the next round leaves those
players out. The starting rank of the file becomes the pairing number. The type of the
tournament is taken from the file (Swiss, round robin, team). The unknown result `?`
comes back as a postponed game, worth what the file's `X` (record 162) says an
unknown result is worth - a draw when the file says nothing. An `X` that is a
win or a loss in the file's own points also becomes how the tournament counts a
postponed game (Settings, Scoring), which takes it out of FIDE mode; an `X` that
is none of the three is refused, with the value named. On the Pairings page such
a board shows as `* postponed`; pick the real result there once it is known. A
board the file pairs without a result yet (a
file saved while the round was being played) comes back as a game still being
played: the import report names its round, and the next round waits for its
result. Team files give the teams and their board
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
  tournament type imported when the code is missing or unknown, a Swiss whose
  code says it was paired by the 2017 edition of the Dutch system (its rounds
  are kept as played; the rounds paired here follow the current one), round-robin
  cycles reduced to what the program plays, tie-breaks that were not in the
  file or that the program does not compute, a number of rounds taken from the
  rounds the file holds, deputy arbiters beyond the fourth, team forfeit and
  bye points, extra points outside the scoring, virtual points that are not
  FIDE's Baku method (imported as extra points in acceleration mode: each round
  keeps the virtual points it was paired with, and each player holds the
  points the file gives for the next round), games without an opponent that
  were imported as byes, and rounds that were not checked because only a
  Dutch-system Swiss can be.
- *Result symbols that are not result codes.* A symbol in a result column that
  is not a result code (a `5`, an `x`, a `%`) is read as a game with an unknown
  result and imported as a postponed game, like `?`. Every one is listed with the
  player, the starting rank, the round and the symbol found. The opponent's
  result in that round is set to unknown as well, and the list says so, because
  both sides of a game must agree. A symbol in a round with no opponent (`0000`) is
  not a game and the file is still refused; the message names the player, the
  round and the symbol. Cancel imports nothing.
- *Results assumed for the check.* The rounds after a game with an unknown
  result (`?`, or a symbol read as one) are still checked against the pairing
  rules, counting that game as played and worth the file's `X` for both players
  (a draw without one) - what the import makes of it, a postponed game. The review says which rounds were checked that way
  and lists every game assumed, with its round and its two players.
- *Players who look withdrawn.* A TRF file cannot say that a player withdrew:
  it shows a player with nothing in the later rounds, which is also what an
  absence looks like. So the review lists, under *Looks withdrawn - will be
  paired in the next round unless you mark them withdrawn*, every player who
  played or had a bye earlier and has no game and no bye in the last round of
  the file, or in the last several in a row. Each has a tick **Import as
  withdrawn**. Ticked, the player is imported as withdrawn and is not paired
  again; unticked, as active, and the next round pairs them. A player with
  nothing in the last two rounds or more is ticked already; a player who missed
  only the last round is not, because one missed round is usually just that.
  Change either as you see fit, here or afterwards in the player list. Not
  listed: a late entrant (blank rounds at the start, games at the end), a
  player with nothing in any round, a player with a half-point or full-point
  bye in the last round or a bye already granted for the next one, anyone in a
  file whose rounds have all been played, and the players of a round robin or
  a team event. A zero-point bye counts as nothing. What you chose is kept
  with the tournament and in its audit log.
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
forbidden pairings, pairing rules, the record of what was sent to the rating office and the
games that live boards reported ([Live boards](17-live-boards.md#games-and-pgn)). The
original is never touched, even when you import your own file again. If
anything goes wrong nothing is left behind.

What does not travel: restore points, the logo, the phones enrolled for result
entry, the connect codes and the relay key of a board box, the lock of a hand-off, and everything that would act on its own:
the publishing switch and address and the open entry form (publishing has to
be switched on again for the copy, [Publishing](14-publishing.md)). The audit
trail and the collaborators travel only in a hand-off file, and the
collaborators come back as pending invitations that each person must accept.

A tournament in a group ([Tournament groups](03-tournament-setup.md#tournament-groups))
carries the group's name, its label and its place in the file, for whoever
reads it. The import does not use them: the copy arrives in no group, and you
add it to one on its Settings page if you want it there.

### SWAR file

With the *SWAR import* feature on (Account menu, **Features**, Belgian pack),
**Import a SWAR tournament** reads a `.swar` file with players, rounds,
results, byes, scoring configuration (including the 3-2-1 club scoring),
absences and the categories. Players without a FIDE ID are looked up in the
FIDE list and you confirm the matches in a *Resolve FIDE ids* step. A SWAR
team competition can be imported as an individual tournament (the games), not
as a team event.

#### Uploading a SWAR file again

If the file is a tournament you already have here (SWAR keeps one id per
tournament in every file it saves), the panel says so and offers three ways
on: **Compare and merge**, open the tournament, or import another copy.

**Compare and merge** lists everything that differs between the file and the
tournament, and nothing changes until you press **Merge**:

- **Tournament settings** - keep the ones here or take the file's. Settings
  that decide how rounds are paired stay as they are once a round is paired.
  Settings the file does not have (norms, a manual ranking, publishing) are
  never touched.
- **Player details** - keep or take the file's. Players are recognised by
  FIDE ID, then national ID, then name and year of birth. Players only in the
  file can be added: they get the next free pairing numbers and join after
  the last round here. Nobody is renumbered, and players only here stay.
- **Results and byes** - one choice per game. A result the file has where
  there is none here is taken unless you say otherwise. A result that
  differs from one entered here is a conflict, marked in the margin, and is
  kept as it is here unless you pick the file's.
- **Pairings that differ** are shown and never changed: a round paired here
  is not re-paired from a file. To use the file's pairing, delete the round
  here and merge again.
- **Rounds only in the file**, after the last round here, can be added.

Before anything is written, the tournament as it was is saved as a restore
point on its **History** page, so a merge you regret is one click away from
undone. If the tournament changes while you are looking at the comparison,
nothing is merged and you are asked to upload the file again.

### Results from a CSV file

On the Pairings page, **More**, **Import results (CSV)**. See
[Results](07-results.md).

### Receive a hand-off

**Receive a hand-off** takes in a tournament that another copy of the program
handed over. See [Accounts, sharing and hand-off](16-accounts-and-handoff.md).

## Exporting

Settings, **Export** (the page *Export / backup*):

### TRF (FIDE rating report)

The TRF26 file for the rating office. A table lists every paired round with
its state (being played, ready to send, sent) and a tick; **Download a copy
(not for rating)** and **All rounds (TRF copy, not for rating)** give copies,
and **Send…** gives the file for the rating office and marks the games as
sent. This is a part of the reporting procedure and is explained in
[Sending to FIDE](10-fide-report.md).

The file written is TRF26, the 2026 report format. It has the player rows in
the TRF16 layout, and the tournament records: number of rounds (142), initial
colour (152), the point system if it is not 1, ½, 0 (162), the program (182),
the type of tournament (192, for example `FIDE_DUTCH_2025` for a Swiss,
`_BAKU` with acceleration, `BERGER_ROUNDROBIN_Gn`, `FIDE_TEAM_TYPEA_MP_GP`, or
`CUSTOM_SWISS` for Keizer), the tie-breaks (202), the rate of play (222), the
virtual points (250), the prohibited pairings (260), a bye granted for a
round that is not yet paired (240) and the administrative extra points (299).
Notes the program wants a human reader of the file to see are written as `###`
comment lines in copies. Each paired round can also be selected by
`?rounds=1-5` in the address of the download (ranges and single rounds, such
as `1-3,6`).

**Extra points in the file.** Extra points that count in the standings are
written as record 299: a handicap from before round 1 (round `000`), points
kept in the final standings in acceleration mode at round `999`. Extra points
in acceleration mode are also virtual points (250): the points each round was
paired with, and, while rounds remain, the points the next round will be
paired with. A tournament imported from the file has them all back and pairs
its next round as this one does. Extra points that neither count in the
standings nor reach the pairing (a handicap that is not counted, or a negative
value in acceleration mode when the points are not kept) have no record in a
TRF: a line under the downloads says how many players hold such points, and a
tournament imported from the file has none.

The older TRF16 spelling of the extension lines, which TRF pairing programs
such as bbpPairings read, is available by adding `?dialect=engine` to the
address of the download.

A postponed game is written as the unknown result `?`, worth a draw in the
file (the `X` of record 162). When every postponed game in the file counts as
the same win or loss for both players - a tournament imported from a file whose
`X` said so, say - `X` is that value instead, so the file's points match the
standings and importing the file again gives the same tournament. When the
tournament counts postponed games as different things meanwhile - a win for
the player who did not ask, say, which is only possible outside FIDE mode -
the standings and the file differ in points, so the file's rank column is then
worked out from the file's own points and tie-breaks, not copied from the
Standings page. With the default valuation (a draw for both) the two are the
same.

### Backup and copy

- **Export full backup (JSON)** - the file described above, for this
  tournament. On the Tournaments page **Export all (JSON)** exports every
  tournament you own in one file.
- **Export .swar (v7, experimental)** (Belgian pack) writes a SWAR file. A
  line lists what the SWAR format cannot hold of this tournament - among them
  an absence worth anything but half a point (SWAR has a tick box for the
  half point and nothing else) and an expelled player, who is written as
  SWAR's *Forfeit*, as a withdrawn player is.
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

A tournament with live boards also has the games the boards reported, with
their moves: see [Games and PGN](17-live-boards.md#games-and-pgn), and
[Setting up electronic boards](18-setting-up-boards.md) for how they get there.

### The FIDE forms

**Advanced**, **Norms** ([Categories and norms](11-categories-and-norms.md)).

## Backups made by the program

A tournament database backup is written automatically about once a day (see
[Accounts, sharing and hand-off](16-accounts-and-handoff.md)), and a restore
point is saved before every action that is hard to undo. These are separate
from the files above.
