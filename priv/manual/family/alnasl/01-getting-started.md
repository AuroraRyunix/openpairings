# Getting started

Alnasl reads the electronic boards in a playing hall, works out the moves from where the pieces stand, and sends the moves and the clock times to the results site while the games are played. This chapter says what it is, the two ways to run it, how to install it, and what to check before the first round.

> [!NOTE] It never decides a result
> A mate on the board or two kings in the centre is a suggestion. You confirm it. A board never enters a result anywhere.

## What Alnasl does {#what-alnasl-does}

Who plays whom, Alnasl learns from OpenPairings. What each board saw goes back there, beside the pairing. The moves and the clocks go to the results site (OpenResults), where spectators follow them. Alnasl keeps everything itself first, so a hall without internet loses nothing: what could not be sent goes out, in order, when the connection is back.

You work with it in a browser, on the box itself or on your laptop in the hall. The places are in the rail on the left, in groups:

| Group | Page | What it is for |
| --- | --- | --- |
| Play | Live | The screen during play: the boards of this hall, as tiles or as a list |
| Play | Boards | What is plugged in, the table numbers, "Ready for round N?" |
| Play | Games | Games as text (PGN): read, attach, compare, export |
| Send | Results | What has gone to the results site and the other destinations, and what waits |
| Manage | Halls | The halls you belong to, their bridges and people |
| Manage | Setup | In sections: tournaments, connections, results and Lichess, this box, access, updates, advanced |
| Look back | Log | What happened, in sentences |
| Look back | Recordings | Everything the boards said, raw, for looking at again |
| | Help | This manual |

At the top of the rail: the box's name (on the server, "server") and, when you have more than one hall, the hall picker. At its foot: the account button, with your language, the colour theme and Sign out.

On a phone the rail becomes a bar along the top (the name, the hall picker and the account button) and the places a bar along the bottom: Live, Boards, Results and More, which holds the rest. Nothing is missing on a phone; it is one tap further.

Notices (the results site cannot be reached, a board plays outside its tournament, a question about tables, a new version) stand above the page, at most two at a time. The rest wait behind "1 more notice"; press it to see them.

A page or a list with nothing in it yet says so in a sentence, and says what brings something: a connection for the tournaments, a bridge for a hall's boards, a board for a round. Where there is one obvious next step, a button takes you there.

Setup is in sections, each with its own address and a list beside it (a drop-down on a phone): the **Setup wizard** (see [below](#setup-wizard)), **Tournaments** (a line each; open one for its details, its halls and tables and its automatic start; the ones with boards in this hall come first, the finished and the not started are behind a toggle), **Connections** (codes and account links, a line each with a menu for Test, Retry and Remove, and "+ Add"), **Results and Lichess**, **This box** (on the server **This server**), **Access** and **Updates** (a box only) and **Advanced** (the tracker, for admins). A section your edition or role cannot use is not drawn.

## The setup wizard {#setup-wizard}

The first section of Setup is the **Setup wizard**. Until every step of it is done, Setup opens there; after that it opens on Tournaments, and the wizard stays in the list for the next change. It is per hall: on the server, open it in each hall with the hall picker at the top.

It starts with a few questions: what the hall looks like (one hall with one tournament, one hall with several tournaments, or several halls or rooms), how many Arkab bridges (on the server always; on a box only for rooms beyond its own), roughly how many boards, and what else you want: results for spectators, a Lichess broadcast, a print station, a hall announcer, and on a box phones and laptops behind a PIN. One cable chain takes up to twelve boards; more boards is a second chain on a port of its own.

Then it lists the steps for exactly that hall, in order, with one button each that goes where the step is done. The first step not done is the current one. Each tick comes from what Alnasl really has, not from anybody pressing Next:

| Step | Ticked when |
| --- | --- |
| Make the halls (server, several halls) | You can see as many halls as you said |
| Plug the boards in (box) | The box has as many boards on its own ports as you said |
| Install Arkab | A bridge of this hall has connected at least once |
| Bridge 1 of N, 2 of N... | That bridge has joined this hall and connected; "not connected now" if it is down |
| Boards arriving (server) | The hall has as many boards as bridges times boards per bridge |
| Connect the tournament(s) | That many tournaments from OpenPairings are in this hall |
| Tables per tournament (several tournaments) | At most one tournament keeps "every free table"; the others have a range |
| Number the boards | Every board of the hall has a table number |
| Results for spectators | A tournament here has a results page and its relay key |
| Lichess | A tournament here has a Lichess round and its token |
| Phones and laptops (box) | Other machines in the hall are let in (Setup, Access) |
| Print station, hall announcer | You mark them done: Polis and Nunki talk to OpenPairings, not to Alnasl, so Alnasl cannot see them |

The connect code comes from OpenPairings: open the tournament, then Settings, Live boards, and press "New code". A step you cannot act on with your role keeps its tick, loses its button and says who can. Only the hall's owner answers the questions; "Change the answers" asks them again and the ticks carry on.

## Two ways to run it {#two-ways}

It is the same program either way. What differs is where it runs and what is plugged into it.

**A box in the hall.** A small computer (a Raspberry Pi, a mini PC, the arbiter's laptop) with the boards plugged into it by USB or serial cable. It reads them itself. This is the normal case, and it works with no internet at all.

**The hosted server.** The same program runs on a server, at alnasl.zerotwo.cloud. A server has no boards of its own: it has no ports to read. It takes **bridges** instead: Arkab, a small program in a hall that read the boards there and send them on over the internet (see [Bridges](03-bridges.md)). The pages are the ones you know: the round, the games, the corrections. The difference is that every page asks who you are, always, and accounts come by invitation only (see [Accounts, halls and roles](06-accounts-and-halls.md)).

The server leaves out what only a box can do, instead of greying it out: adding boards and the list of serial ports on the Boards page, simulator boards, the Updates panel and starting with Windows, the PIN and the hall network, and the box's name. Setup, This server, says which edition you are looking at, under "This copy of Alnasl"; the sections Access and Updates are not there at all.

> [!TIP] Which one?
> Boards in your own hall and you want it simple: a box in the hall. Several halls, an arbiter at home, or nobody wants a computer in the hall: bridges and the server. Both can be used together, because one bridge may feed more than one server.

## Installing {#installing}

**Windows.** Alnasl-Setup.exe installs for you alone, without an administrator, and puts "Alnasl" in the Start menu. The program is not signed, so the first time Windows says "Windows protected your PC": choose "More info", then "Run anyway". The small Alnasl window is the program: closing it stops Alnasl, and while it is stopped the boards are not read. There is also a zip that installs nothing: unzip it and start Alnasl.exe.

**Linux and the Raspberry Pi.** One line installs Alnasl as a service that starts with the box (64-bit; Debian 12, Ubuntu 22.04, Raspberry Pi OS Bookworm, or newer):

```
curl -fsSL https://github.com/teapot-chess/Alnasl/releases/latest/download/install.sh | sudo sh
```

**Mac.** Download alnasl-macos-aarch64.zip for a Mac with an Apple chip (M1 and later; there is no build for Intel Macs), open it, and drag Alnasl into Applications. Apple has not signed it yet, so the first time macOS refuses to open it: in System Settings, Privacy & Security, click "Open Anyway" beside the message about Alnasl. Quitting Alnasl (Cmd-Q) asks first, because while it is stopped the boards are not read.

Then open the site in a browser: on the box itself at `http://localhost:4040`; from a laptop on the hall's network, the box's address with the same port (Boards and Setup, Access, show it, with a QR code for a phone, once other machines are let in).

### Updating {#updating}

The box asks once every half hour whether a newer version is out, and says so at the top of the page. It downloads nothing until you say yes under Setup, Updates, where it also says how big the download is. It will not restart while a game is being played unless you insist: the moves played during the restart are not read. "Later" asks again tomorrow; "Don't ask again" stops the looking, and Setup switches it back on.

### Where your data is {#where-your-data-is}

Not in the program's folder. Windows: `%LOCALAPPDATA%\AlnaslData` (type that in Explorer's address bar). Linux, installed: `/var/lib/alnasl`. Mac: `~/Library/Application Support/AlnaslData`. It holds the database, the PGN of every game, the raw recordings, and the keys and codes you pasted. Updating and uninstalling leave it alone; installing again finds it. To move to another computer, copy that folder while Alnasl is stopped.

Setup, This box, "This copy of Alnasl", says the version, how this copy was started and where its data folder is. A second copy started another way on the same computer has a data folder of its own: its own boards, numbers and tournaments.

## Before the round {#before-the-round}

The same short list every time. Each step has a page that says in words what is wrong, if something is.

1. Setup, Connections: paste the connect code from OpenPairings (and, under Tournaments, say which tables play in which tournament) (see [OpenPairings, OpenResults and Lichess](05-openpairings-and-openresults.md)). Press "Test connection".
2. Boards: every board should show a state other than "No signal", and its picture should match the pieces on it.
3. Boards: the column "Start position" must say "Right" for every board. If not, it names the pieces and squares. A king and queen swapped is the usual one.
4. A board with a clock is only "Right" when its clock is too: to the right of the board, the lever up on White's side so that White's time runs first.
5. Boards: give each board its table number (see [Boards and ports](02-boards-and-ports.md)).
6. Boards: "Ready for round N?" must say Ready. If not, it lists what is wrong, board by board.
7. Live: every tile should read "Waiting for start".

## Language and colours {#language-and-colours}

The site is in English or Dutch. The language is yours, not the box's: choose it in the account menu (the button at the foot of the rail, top right on a phone). With an account, the choice is kept with the account and follows you to any browser; without accounts, it is kept in that browser. Either way nobody else's language changes, and this manual follows yours.

Whoever has chosen nothing reads Alnasl's default language. An admin sets it under Setup, "This box" ("This server"), Default language.

The colours come in the same themes as OpenResults: Paper, Night, Board, Slate and High contrast, and Match device, which follows the phone or computer. Choose in the account menu, under Colour theme; it is the only place. The choice is kept in that browser only. High contrast is the one for a projector at the back of the hall.

More themes can be added as theme packs: one folder per theme, in the folder `themes` inside the data folder. On the next page load they are offered after the built-in ones. A pack Alnasl will not load is listed in grey, with the reason.

## Words used here {#words}

The screens and this manual use one word for each thing:

| Word | Means |
| --- | --- |
| Alnasl | The program, wherever it runs. A sentence the server shows too says "Alnasl", not "the box" |
| box | Alnasl on its own computer in a hall, reading boards on its own ports |
| server | The hosted Alnasl at alnasl.zerotwo.cloud, which reads boards through bridges |
| bridge | Arkab, beside the boards of a hall, sending them to a box or the server |
| hall | A room with tables and boards; every page is about one |
| the hall's own tournament | Where a hall's boards play when no pairing names them |
| connection | A connect code or an account link to OpenPairings |
| results site | OpenResults, where spectators follow the games |
| results page | One tournament's page on the results site |
| Results | The page in the rail that shows what was sent and what waits |
| live board | An electronic board; the screens never name a brand |
| arbiter, viewer | Roles in a hall: an arbiter corrects and starts rounds, a viewer watches |

A game that "stays in Alnasl" is kept here and not sent anywhere; the log says "Arbiter in Alnasl" when a person changed a game through these pages.
