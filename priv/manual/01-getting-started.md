# Getting started

This chapter says what OpenPairings is, how to install and start it, and how
the program is laid out. The other chapters follow the order in which an
arbiter works: set up the tournament, enter the players, pair a round, enter
the results, print, report.

## What the program does

OpenPairings runs a chess tournament from its set-up to the report for the
rating office:

- It pairs Swiss tournaments (FIDE Dutch system, C.04.3), Swiss team
  tournaments (C.04.6), round robins (Berger tables, C.05) and Keizer
  tournaments.
- It keeps the players, the results, the byes and the standings, with the tie-breaks of
  FIDE's C.07.
- It prints the lists an arbiter needs (pairings, standings, result cards,
  cross tables, player cards, place cards).
- It reads and writes the FIDE report file (TRF26, TRF16), and reads SWAR
  files.
- It can publish a tournament to a public results site (OpenResults) so that
  players and spectators follow the event on their phones.

By default a tournament is handled the way FIDE's pairing regulations say it
must be. This is called FIDE mode and is described in
[FIDE mode](02-fide-mode.md).

## Two ways to run it

**On your own computer (the desktop build).** A single person uses the
program on one computer. There is no log-in: the program starts, opens your
web browser on `http://localhost:4000` and you are signed in as the owner of
that computer. Your tournaments are stored on that computer. The program can
only be reached from that computer, never from the network.

**On a server (the online build).** The program runs on a server and you reach it
through a web address. Everyone has an account, every tournament belongs to
its owner, and the owner can invite other arbiters to share it (see
[Accounts, sharing and hand-off](15-accounts-and-handoff.md)).

Everything described in this manual works in both. The differences are
mentioned where they matter: log-in and accounts exist only online;
the update notice, the data folder and the "local view" of the live page
belong to the desktop build.

## Installing the desktop build

Download the release for your system from the project's release page.

**Windows.** The `.msi` file is the recommended download. It shows an
installer with a welcome page, the licence, and the choice between installing
for yourself only (no administrator needed) or for everybody on the computer.
The `Setup.exe` next to it installs for yourself at once, without questions.
After installing, start *OpenPairings* from the Start menu. A small window
opens and your browser follows; closing that small window stops the program.

If your antivirus removes the single-file download, use the *portable*
release instead: unzip it and double-click `OpenPairings.exe` in the folder.

**Linux.** Download the portable archive and unzip it. Run `./openpairings.sh`
(the file must be made executable once: `chmod +x openpairings.sh`). The
program opens your browser.

**macOS.** The releases no longer include a macOS build; it can be built from
the source code on a Mac. It then starts the same way as the Linux build.

No Java and no database server are needed. The Swiss pairing engine
(Ainalrami) is part of the program. JaVaFo, FIDE's own reference engine, is an
optional alternative engine; it is not included in the download (see
[Pairing a round](06-pairing.md)).

### Where your data is

The tournaments are one database file in a folder of your user account:

- Windows: `%LOCALAPPDATA%\OpenPairingsData`; backups in
  `%LOCALAPPDATA%\OpenPairingsBackups`.
- macOS: `~/Library/Application Support/OpenPairings`.
- Linux: `~/.local/share/OpenPairings`.

Uninstalling the program leaves this data in place. The program writes a
backup of its data about once a day (see "Backups" in
[Accounts, sharing and hand-off](15-accounts-and-handoff.md)).

### Updates

A desktop copy checks, on start and every few hours, whether a newer release
exists, and shows a notice at the top of the page. It never installs anything
on its own and never in the middle of your decision: a new version can contain a newer pairing
engine, so you choose the moment (not while a round is being played). On a
per-user Windows installation the notice has an *Install and restart* button;
on the other installations it links to the release page. The check can be
switched off on the Connections page.

## The first start

Open the program. The first page is **Tournaments**: the list of your
tournaments (empty at first), with *New tournament* and the import buttons.

The bar at the top of every page has:

- **Tournaments** - the list of your tournaments.
- **Tools** - the public arbiter tools (norm reports from uploaded files).
- **Changelog** - what changed in each release.
- **Help** - this manual. Inside a tournament it opens at the chapter that
  matches the page you are on.
- The colour accent, the language picker (English and Dutch) and the theme
  (light, dark).
- The account menu, with *Settings* (online), *Features* and *Log out* (online),
  and the version number.

Inside a tournament the bar shows the tournament's own tabs:

| Tab | What it is for |
| --- | --- |
| Players | the entries, ratings, presence and the player grid |
| Teams | (team tournaments only) teams, rosters, board order |
| Pairings | pairing a round, entering results, hand edits |
| Standings | the ranking and tie-break columns |
| Print | every printable document |
| Advanced | Norms, History (restore points), Audit trail, Pairing rationale, Badges |
| Settings | the tournament's settings (several pages) |

*Connections* (the rating lists, backups, publishing address) appears in the
bar on the Tournaments page, for the administrator of the installation. On a
desktop build that is always you.

## A first tournament in short

1. Tournaments, **New tournament**: name, pairing system, rounds, place,
   start date, rate of play. **Create tournament**.
2. Settings, **Dates**: enter a date for every round (no round can be paired
   until every round has a date).
3. Settings, **Tournament**: check the tie-breaks and the officials.
4. **Players**: add the players (search the FIDE list or type them in).
5. **Pairings**: **Pair round 1**.
6. Enter the results on the Pairings page. When every board has a result,
   pair the next round.
7. **Standings**, **Print** whenever needed.
8. After the last round: Settings, **Export**, send the TRF file to the
   rating office (see [Sending to FIDE](11-fide-report.md)).

The following chapters explain each step in full.

## Language

The page around the manual, and the whole program, is available in English
and Dutch (picker in the top bar; online, the choice follows your account).
This manual is written in English only.

## Keyboard and accessibility

Every action is a button or a link and can be reached with the keyboard.
Result entry is designed for the keyboard (see [Results](07-results.md)); the
player grid has its own key controls (see [Players and rating lists](04-players-and-ratings.md)).
The program follows the colour scheme you choose; there are light and dark themes
and a high-contrast mode on the live page.
