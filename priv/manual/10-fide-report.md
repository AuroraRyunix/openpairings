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
  event have different IDs, enter **Per-round FIDE-ID ranges** (advanced until a row exists; from round, to
  round, ID);
- **FIDE event code**.

Settings, **Tournament**, **Options** and **Dates**: the federation, the venue,
the rate of play and the dates. Settings, **Officials & norms**: the chief
arbiter and the deputies with their FIDE IDs. The program reminds you of the recommended fields on the Players
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

Tick the rounds you want and press:

- **Send…** - builds the file for the rating office, downloads it to your
  computer and **marks every game in it as sent**, in one step. The file is
  named after the type of the tournament, the FIDE tournament ID, the name and
  the rounds. It holds only the records of the report, no comments.
- **Download a copy (not for rating)** and **All rounds (TRF copy, not for
  rating)** - copies for your own use or another program. The file name ends
  `COPY-NOT-FOR-RATING` and the file says so in a `###` comment line.

> [!IMPORTANT]
> **Downloading is not sending.** *Send…* delivers nothing to anybody: it
> hands you the file and records that it was handed over. You still have to
> send the downloaded file to your rating officer yourself (by e-mail, or
> however your federation wants it). The confirmation says so, the line
> under the button says so, and the page says it once more after the
> download, with the receipt code.

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
tournament-type records listed in [Import and export](12-import-export.md).
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

**Long events.** A tournament with the tick *Tournament lasts more than 30
days* is reported one of two ways, chosen under that tick (Settings,
Tournament). Whichever it is, a report carries as many rounds as the FIDE
registration it is sent against: a registration of 9 rounds takes a file of
9 rounds.

- *Monthly reports*: each month's rounds are reported on their own (B.02
  Art. 4.1). In FIDE mode a postponed game without a result blocks only the
  file of its own month; played later, it goes in the postponed-games file.
  The Export page reminds you beside **Send…** that each monthly file must
  match a registration of that many rounds.
- *One report at the end (as registered with FIDE)*: the tournament is
  registered once, in its last month, and every round goes in one file after
  its last day. FIDE's rating server does not mind games dated long before
  the registration. A postponed game played before that report is simply a
  result in it; the postponed-games file is only for a game played after the
  final report was sent. **Send…** with fewer rounds ticked than the
  tournament has says so before the download, and lets you go ahead: the
  registration may have shrunk with the event.

## Prohibitions changed during the event

A forbidden pairing or a pairing rule added, changed or removed after round
1 was paired is listed in the TRF copies, one line per round it first
affects, for example `### Prohibition @ Round 4: 5-12 added; rule same club
removed`. In FIDE mode the first such change is also the round the
tournament left it ([FIDE mode](02-fide-mode.md)). The file for rating holds
records only and carries no such line.

A game played after its round was sent is reported as a **separate tournament**
with its own name and its own FIDE tournament ID, and FIDE rates month by month.
Settings, Export, section *Postponed games* lists every postponed game with
its state, the date it was played and the file it is in:

- Enter the **date played** of each game (set when it is first played; changing it
  later is a separate step that is written to the audit trail).
- Enter the **tournament name** of the postponed-games file (by default the
  event's name plus *postponed games*) and its **FIDE tournament ID**.
- **Make this file** builds the file for one rating period (month); *Send…*
  downloads it and marks its games as sent - and, as with a round, you send
  the downloaded file to your rating officer yourself. A page note says which month and that the file must be
  sent before the end of that month. A game that has been sent in its round
  with its real result is never offered again.

## Checks

- Before the file leaves the program, every result code and every pair of
  opponents is validated; an error stops the download with a message.
- Importing the file back into OpenPairings (or any other program) is the
  best check that it says what you think it says ([Import and export](12-import-export.md)).
- **Receipt (JSON)** on the Export page downloads the receipt of one sent file:
  its code and fingerprint, round or period, who sent it and when, the games as
  sent, and the file's SHA-256 and name. The receipt keeps the exact file too;
  the rating inbox downloads and checks that one.

## The rating period inbox

For the rating officer, who is an administrator of the installation: **Rating
inbox**, in the **Account** menu on every page and at the top of the *Admin*
page. Only an administrator sees those links; on a tournament's Export page
an administrator also has a small *Open the rating inbox* link under the Send
button. It shows, by FIDE rating period, what was sent for rating, what is
still missing, which postponed games are still open, and which rating list
each file is for. A round counts for the month of its date.

**Which tournaments are listed.** A tournament from which at least one file
was sent, and a tournament marked **FIDE-rated** (Settings, FIDE). Nothing
else: a club evening that is not marked FIDE-homologated and never sent anything
does not appear. *Not sent yet: round N has finished and has no receipt* is
said only of a tournament marked FIDE-homologated; one that is not, but sent a
round once, is listed with that receipt and the label *not marked
FIDE-rated*, and nothing is expected of its other rounds. The FIDE-rated
tick is the only "this tournament is rated" setting there is; there is none
for a national rating.

*Sent* means the arbiter pressed **Send…** and the file was downloaded to
their computer. Whether they then sent it on to you, the page cannot know:
its **Download file** is that same file, in case it never arrived.

**The rating list.** FIDE publishes a list on the first day of every month,
and the inbox names a list by that date. The file should be uploaded in time
for the list after the month the tournament ended in, or for the list one
month later when it ended with five days or fewer left in its month (B.02
Art. 9.1); a postponed-games file counts from the date of its last game. A
tournament that lasts more than 30 days reports every month (Art. 4.1), so
its rounds of a month count from the last of them, not from the end of the
tournament: the October rounds of a championship that runs until April are
for the list of 1 November. One set to report once at the end is counted
from its last day like a short tournament, and no month of it is overdue (see
[Postponed games](#postponed-games) for the two ways). Each tournament says where it stands:

- *For the rating list of 1 …: to be uploaded by …* - in time.
- In amber, *Missed the rating list of …* (for a monthly report: *Overdue*) -
  that list is gone; the line names the next list it can still make and the
  day after which it is not rated at all.
- In red, *Will not be rated* - it missed the third list after the
  tournament's last day.

Nothing is refused: a late file can still be sent, and the inbox shows the
list it will make. Each sent file can be downloaded (**Download file**) and
replayed against the checker (**Check**), which pairs every round up to it
again and says whether the boards and standings match. The receipt keeps the
exact file that was sent (up to 2 MB). A file sent before the receipts kept
their files has none: the inbox offers a copy rebuilt from the tournament as
it is now, labelled *rebuilt copy*, which is not necessarily what was sent.

## Norm reports

The IT3 tournament report and the arbiter and player norm forms are separate
Excel files; see [Categories and norms](11-categories-and-norms.md).
