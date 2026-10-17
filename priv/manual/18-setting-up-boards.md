# Setting up electronic boards

This chapter is the set-up guide for live boards, start to finish: what to
buy or bring, what to click in which program, and what to do when a round is
on. It has one path for a **hosted** OpenPairings (the web address your
association runs) and one for the **desktop** edition on your own PC. What the
live boards are, and what each page of them shows, is in
[Live boards and Alnasl](17-live-boards.md).

> [!WARNING] A first release
> Alnasl, the program that reads the boards, is in its first release. It has
> run on simulated boards. On real hardware it has read single boards of
> two firmware generations (one with a clock) and two boards on one cable,
> a loop. Some moves have been played on a real board, not a whole game, and
> no tournament has been played through it. Not yet tried: a whole game on a
> real board, a move or a clock on a loop, more than two boards on a loop, and
> a Raspberry Pi. The installers are published, but nobody has yet installed,
> updated or uninstalled Alnasl with them. Its own README lists what is not
> done. Try the whole set-up in your own room, with the boards you will use,
> before the event.

## What you need {#what-you-need}

- **The boards.** Electronic chessboards (USB/serial), each with its cable to the computer.
  Alnasl reads them as serial ports: a USB board directly, or a serial
  board through a USB-serial adapter. A clock on a single board has been
  read; clocks on a loop have not been tried.
- **Several boards on one cable (a loop).** Add the port in Alnasl and it finds
  the boards on that port by itself, each with its own row. Two boards on one
  cable have been read this way. Moves and clocks on a loop, and more than two
  boards, have not been seen on real hardware yet.
- **A computer in the hall for Alnasl.** Alnasl runs on a PC with Windows 10 or
  11 (64-bit), or on a Linux box: 64-bit Debian 12, Ubuntu 22.04, or Raspberry
  Pi OS "Bookworm" 64-bit or newer. There is no 32-bit build. The README
  describes a Raspberry Pi with a screen, keyboard and mouse for the arbiter,
  but no Pi has run Alnasl yet.
- **Alnasl itself.** A separate, free program. Install it with the installer for
  your system:
- **Windows.** Download **Alnasl-Setup.exe** from
  `https://github.com/AuroraRyunix/Alnasl/releases/latest/download/Alnasl-Setup.exe`
  and run it. It installs for you alone, without administrator rights, and
  starts a small window and your browser on `http://localhost:4040`. Windows
  warns the first time, because Alnasl is not signed: click **More info**, then
  **Run anyway**.
- **Linux and Raspberry Pi (64-bit).** On the box, in a terminal:
  `curl -fsSL https://github.com/AuroraRyunix/Alnasl/releases/latest/download/install.sh | sudo sh`.
  It installs Alnasl and starts it with the box; the management site is then
  `http://localhost:4040` on the box. A hall without internet can download the
  archive beforehand: the Install section of the README says how.
- **Updates.** Alnasl looks for a newer version and says so on its pages. It
  installs one only when you say yes (Setup, Updates), and never while a game
  is on a board.
- **Building from source** is still possible; see the README at
  `https://github.com/AuroraRyunix/Alnasl`.
- **The hall's network**, for a hosted OpenPairings: the computer with Alnasl
  must reach the internet. For the desktop edition, no internet is needed: with
  Alnasl on the same PC no network at all, and with Alnasl on another machine
  a cable or a small network of your own between the two (see
  [Set-up with the desktop edition](#set-up-desktop)).
- **Table numbers on the boards.** Stickers with the number of each table.
  Alnasl prints a sheet of labels (Boards, **Labels**).

## Who talks to whom {#who-talks-to-whom}

Three programs, two directions of conversation.

- **OpenPairings** runs the tournament and owns the results. **Alnasl calls
  it** about every five seconds to ask who plays whom and which round is on,
  and tells it what each board saw: the moves, the clocks, the PGN and the
  result on the board. OpenPairings never calls Alnasl, so the hall opens no
  port. A board never enters a result.
- **Alnasl** sits in the hall, reads the boards over their cables, and turns
  what it sees into moves. It has its own management site in a browser,
  `http://localhost:4040` on its own computer (from a phone or laptop on the
  hall's network too, see below).
- **OpenResults**, the public results site, shows the games live. Alnasl sends
  the moves there directly, and one way only: it reads nothing from it. The
  address of the results site, the tournament's short name and the permission
  to send there all come to Alnasl **through OpenPairings**, which fetches the
  permission from the results site by itself. Nothing about them is typed on
  the box, and nobody has to ask an administrator for anything.

## Set-up with a hosted OpenPairings {#set-up-hosted}

OpenPairings is on the web, Alnasl is in the hall with internet.

### In OpenPairings {#in-openpairings}

1. **Put the tournament on the results site.** Settings, **OpenResults**,
   **On the results site**: **Link only** or **Listed**. The results site must
   be connected first (see
   [Connecting a results site](14-publishing.md#connecting-a-results-site)).
   Once the tournament is on the site, Settings, **Live boards** says
   *Connected to … as …*.
2. **Make a connect code.** Settings, **Live boards**, card **Codes for this
   tournament**, press **New code**. The page shows the code as a line of text
   and as a QR code, **once**: *The new code. It is shown this once.* Copy the
   line now. If you lose it, make another; a code is one click.

   That is all the box needs. The card **The results site** on the same page
   goes from *Getting permission from the results site…* to *Yes. The box may
   send moves there.* by itself, usually within seconds. There is no key to
   ask for, copy or paste. (What happens behind it:
   [The box's permission](17-live-boards.md#the-relay-key-for-the-box).)
3. **Decide about the public link.** The switch **Live link on the results
   site** (On / Off) puts a *Live boards* link on the public pages. Connecting
   a box does not switch it on: it is yours to say, when the boards are really
   being relayed.

Steps 1 and 2 may be done in either order. A code made before the tournament
is on the results site works for the pairings at once, and the permission for
the results site follows as soon as the tournament has arrived there.

### In Alnasl, in the hall {#in-alnasl}

4. **Paste the code.** Open Alnasl (`http://localhost:4040`), **Setup**,
   panel **Tournaments**. Paste the whole line in **Connect code** and press
   **Add**. From a phone: scan the QR code with the phone's *own* camera, copy
   the link it shows instead of opening it, and paste that. Alnasl's own page
   cannot scan the QR code (a browser only lends its camera to pages served
   over https), so the code is paste-only on the box.
5. **Test connection.** It checks three things, each in words: *Address*
   (OpenPairings answers), *Code* (the connect code is accepted), *Tournaments*
   (*The code reaches N tournament(s)*). Under each tournament you should see
   the round that is on and *its results page and relay key came with it*
   (the relay key is the permission OpenPairings fetched; you did nothing for it).
   Anything else is explained in [When something is wrong](#troubleshooting).
6. **Say which tables play in the tournament.** Under the tournament:
   **Tables from** … **to** …, then **These tables play here**. Table 5 is
   then the tournament's board 1. The box shows how many boards it now has.
7. **Number the boards.** Boards, **Number by touching**: press Start, lift a
   piece on table 1's board, then on table 2's, and so on. (On a phone this
   page is made to be held in one hand. To open the box from a phone, start it
   with `ALNASL_LISTEN=lan` and **set a PIN** in Setup first, before the hall
   fills up.) Or **Number all in connection order**, or type the number in the
   **Table** column.
8. **Check "Ready for round N?"** on Boards. It must say *Ready*. If not, it
   lists what is wrong, board by board: two boards with the same number, a
   board that does not answer, a wrong starting position, a clock that is
   not in its starting position (the lever up on White's side).
9. **Check the Round page.** Every tile should read *Waiting for start*.

### The round {#the-round}

10. **Pair the round in OpenPairings** as always (**Pair round N**). OpenPairings
    has no button that starts a round: a round that is paired is on. Within
    about five seconds the boards of that tournament show the new round, with
    names, ratings and colours. If it does not (no connection), **Start round
    N** on Alnasl's Round page does it by hand.
11. **Play.** Keep Alnasl's Round page open. A tile per board shows the state
    as a shape and a word: *Live*, *Settling*, *Reconstructed*, *Out of sync*,
    *No signal*, *Clock wrong way*, *Finished*. On the Pairings page of
    OpenPairings, the column **Board saw** shows what the board reported,
    beside the result you enter.
12. **Enter the results in OpenPairings**, on the Pairings page, as you always
    do ([Entering results](07-results.md)). A board never enters one. If the
    board saw another result than the one you entered, the entry is red with
    *differs* and the hover text says *Check the scoresheets. Nothing is
    blocked.* Check the scoresheet, correct whichever is wrong, and go on.
13. **Spectators** see the moves on the results site's live pages. They only
    see a game for a board of a **published** round.

## Set-up with the desktop edition {#set-up-desktop}

OpenPairings runs on your own PC (the desktop edition). Alnasl runs **on the
same PC**, or **on another machine in the hall** that is on the same local
network.

> [!IMPORTANT] Two ways, two codes
> The desktop edition answers on its own computer and nowhere else. For an
> Alnasl on the same computer that is enough, and the connect code says
> `http://127.0.0.1:<port>`. An Alnasl on another machine can reach it only
> after you switch on **Let boards on this network connect**; the code for it
> carries your computer's address on the network instead. A code is for one or
> the other, and the page says which.

Steps 2 to 13 above are the same, with these differences:

- **The code, Alnasl on the same PC.** Settings, **Live boards** says, instead
  of a server address: *This copy answers on this computer only*. Press **New
  code for a box on this computer** (step 2) and paste it in the Alnasl on the
  same PC (step 4). Test connection works with no internet.
- **The code, Alnasl on another machine.** See
  [Alnasl on another machine](#desktop-on-the-network) below.
- **The results site is optional.** With internet, do step 1 as in the
  hosted set-up, and the moves also go to the results site. Without internet at
  all, skip it: Alnasl and OpenPairings still work together.
- **Publish while you still have internet.** The results address, the short
  name and the permission that Alnasl needs exist only once the tournament has
  reached the results site and the desktop copy has fetched the permission. If
  the event has no internet, do steps 1 and 2 at home and wait until the card
  **The results site** says *Yes. The box may send moves there.* Offline, the
  card keeps saying *Getting permission from the results site…* and tries
  again by itself when there is a connection.

### Alnasl on another machine {#desktop-on-the-network}

For a box beside the boards and OpenPairings on your laptop at the arbiter's
table. No internet is needed, only a network the two machines share.

1. **Join the two machines.** Best: one network cable between them, or a small
   router of your own with nobody else on it. A wifi the players use works
   too, and is the one to avoid: read the warning on the page.
2. In OpenPairings, Settings, **Live boards**, card **Boxes elsewhere on this
   network**: switch on **Let boards on this network connect**. Read what it
   says; it is short.
3. **Windows asks** whether to allow the program on the network. Tick
   **Private networks**, choose **Allow**. If you never saw the question and
   the box gets no answer, allow OpenPairings by hand: Windows Security,
   Firewall and network protection, Allow an app through firewall.
4. The card shows the address your computer has on that network, for example
   `http://192.168.1.20:4747`. If the computer is on several networks, pick the
   one the box is on and press **Use these**.
5. Press **New code for a box on the network**. The page says where the code
   leads. Paste it in Alnasl on the other machine (step 4 of the hosted
   set-up) and press Test connection.
6. From here on it is the same as any other set-up.

What to know:

- The door that this opens answers the board box and **nothing else**. Your
  tournaments and the pages of OpenPairings stay on your own computer.
- A network code works until it is withdrawn. Withdraw it when the event is over.
- **If your computer's address changes** (another day, another network, the
  router restarted), the box says *No answer* and the page in OpenPairings
  says *This computer's address changed from … to …*. Pick the new address,
  make a new code, give it to the box. A fixed address for your computer, or
  a cable between the two machines, prevents it.
- After the event: withdraw the code. With no network code left the door
  closes by itself; you can also switch it off, on the same card or under
  Connections.

### What works without internet {#what-works-offline}

| | With internet | Without internet |
| --- | --- | --- |
| Names, boards, colours and rounds from OpenPairings to Alnasl | works | works (on the same PC, or over a network of your own to another machine) |
| The round starting by itself when you pair it | works | works |
| Moves, clocks, PGN and the result the board saw, back to OpenPairings | works | works |
| The **Board saw** column, the game page and the PGN with moves | works | works |
| Moves to the results site (live pages for spectators) | works | **waits** in Alnasl's queue (the Outbox page says how much), and goes out in order when there is a connection |
| Lichess broadcast (if you set one up in Alnasl) | works | waits in the same way |
| Publishing the tournament, and OpenPairings fetching the box's permission for the results site | works, by itself | waits, and happens by itself when there is a connection |

A banner on every Alnasl page says when the results site cannot be reached.
Play goes on and nothing is lost.

## Several tournaments in one hall {#several-tournaments}

Tables 1 to 4 may play one category and tables 5 to 8 another. One box holds
several tournaments, each with its own pairings, round in play and results
page.

- **A code per tournament**, or **one code for a group**. A tournament in a
  [group](03-tournament-setup.md#tournament-groups) also has the card **Codes
  for the group**. One group code brings every tournament of the group that *the
  maker of the code* may open, and a tournament added to the group later
  appears on the box without a new scan. A tournament run by another arbiter,
  whom you cannot open, does not come to your box.
- **Which table plays in which tournament is said on the box**, not in
  OpenPairings: under each tournament **Tables from 5 to 8**, **These tables
  play here**. Board numbers begin again in each tournament.
- **A round starts by itself, for that tournament's boards only.** The other
  tournaments' boards are not touched.
- **One code per tournament on one box.** Two codes that reach the same
  tournament make Alnasl hold it twice, and every game is reported twice. If
  you made a tournament code and a group code for the same event, add only one
  of them (**Remove** the other in Setup).
- A tournament can have up to 8 codes, and so can a group. Withdraw a code you
  no longer use.

## During the round {#during-the-round}

- **A board that is out of sync.** The tile says *Out of sync*; nothing is
  being sent for that board. Open the board's page in Alnasl: it shows what the
  board reads beside what is certain, and the repairs (*The board is right -
  resync from here*, *Type the moves*, *Undo last move*). Everything you do
  there is in the Log. A board that comes right comes back by itself.
- **The marks on moves.** Orange (*Reconstructed*): the box did not see the
  move happen and worked it out, one line of moves fits. Red (*Guessed*): more
  than one line fitted and the box took one; tap it and the box asks which it
  was. *read as d3* beside a move: it was read one square off and put right
  later. These counts travel to OpenPairings with the game and are on its game
  page. The details are in Alnasl's own Help (the **Help** page on the box).
- **Pairing changed.** If you change a pairing in OpenPairings after the round
  started, a board where nothing was played takes the new pairing. A game that
  has moves is kept and its tile says *Pairing changed in OpenPairings*. Open
  the board and choose: **These moves are that game** (the players are the ones
  in the new pairing) or **Set it aside, begin again**. A game that only got
  another board number moves by itself.
- **A withdrawn code.** If you press **Withdraw** on a code, the box that holds
  it is refused at its next request. Its link says *Code refused*; it stops
  asking and the boards go on with the pairings it has. Make a new code and
  add it.
- **A board unplugged.** The tile says *No signal*. Check cable and power; the
  game is kept. A board that comes back on another port is recognised by its
  serial number once you add it on that port.
- **No internet.** Described in [What works without internet](#what-works-offline).

## After the round and the event {#after-the-round}

1. **Check the results.** Look down the **Board saw** column for red. Nothing
   is blocked: you can pair the next round and publish. Each entry is a link
   to the game page.
2. **Finish games on the box** that need it (*Finish game*, under the tile or
   on the board's page: a result, or *No result*). That is Alnasl's own record;
   it is not the result in OpenPairings.
3. **PGN with the moves.** The game page offers **Download PGN**, and **The
   box's own PGN** for comparison. Settings, **Live boards**, card **Games the
   boards reported**: **PGN, whole tournament** and a button per round. The
   result in the file is the one you entered, or `*` until you have. The
   Pairings page's own PGN export (**More**, PGN) still carries no moves.
   Alnasl has its own PGN page (*Whole round as PGN*).
4. **What is kept where.** The games are kept with the tournament in
   OpenPairings and are in its JSON export and its restore points. The connect
   codes and the box's permission for the results site are not: a copy
   elsewhere makes its own codes and fetches its own permission. On the box,
   the games, the queue and the settings are on disk in Alnasl's data folder,
   with a PGN file per game. That folder is `%LOCALAPPDATA%\AlnaslData` on
   Windows (installed or portable), `/var/lib/alnasl` on an installed Linux
   box, and `~/.alnasl` for a copy run from source in production. Setup, **This
   copy of Alnasl**, shows the one in use. An update or a reinstall does not
   touch that folder, and uninstalling keeps it too; delete it yourself when
   you mean to. A copy started another way on the same computer, from source
   for instance, has a data folder of its own, with its own boards and games.
5. **Withdraw the codes** when the event is over: Settings, Live boards,
   **Withdraw**, and in Alnasl **Remove** under Setup, Tournaments. Removing a
   tournament from the box forgets its games there (the PGN files already
   written stay on disk); OpenPairings keeps what was reported to it.
6. **Take the public link down** if you no longer want it: the switch **Live
   link on the results site**.

## When something is wrong {#troubleshooting}

| What you see | Why | What to do |
| --- | --- | --- |
| Alnasl: *That is not a whole connect code: the part after the # is missing.* | The line was cut when copied. | Copy the whole line, from `https://` to the end. |
| Alnasl: *OpenPairings does not know this code* or *OpenPairings refuses the connect code*; link says *Code refused* | Mistyped, or **withdrawn** in OpenPairings. The box has stopped asking. | Make a new code (Settings, Live boards), add it in Alnasl, remove the old one. |
| Alnasl: *OpenPairings cannot be reached*; link says *No answer* | The server or the hall's network is down. Nothing is lost: the boards go on with the pairings they have and the box asks again by itself. | Check the network. A round paired meanwhile: **Start round N**. |
| *No answer. This code is for an OpenPairings on this same computer: is it running?* | A code *for a box on this computer* is used on a computer that is not the one OpenPairings is on, or OpenPairings is not running. | Run Alnasl on the same PC as the desktop OpenPairings and start OpenPairings; or make a code *for a box on the network* (see [Alnasl on another machine](#desktop-on-the-network)). |
| Alnasl on another machine: *OpenPairings cannot be reached*, with a desktop OpenPairings | One of: the switch is off; Windows' firewall did not allow it; the two machines are not on the same network; your computer's address changed; no network code exists any more, so the door is closed. | Settings, Live boards, card **Boxes elsewhere on this network** says which. Address changed: pick the new one, make a new code. Firewall: allow OpenPairings on private networks in Windows Security. |
| OpenPairings: *Port 4747 is in use by another program on this computer* | Another program has that port. | Pick another port on the same card and press **Use these**, then make a new code. Nothing else is affected. |
| Alnasl: *Code refused*, with a network code that worked before | The code was withdrawn, or it is a code *for a box on this computer* used from another machine. | Make a new code *for a box on the network*. |
| The **Board saw** column is empty after you paired a round again | The games of the old pairings were removed with them. | Nothing: the box starts the new games. The old ones are still on the box. |
| *Something answers at that address, but not as OpenPairings' board link* | A login page of the hall's network, or another program on that port. | Log in to the hall's network, or check the address. |
| *… is not published on a results site, so its moves go to OpenPairings only* | The tournament is not on the results site. | Publish it (step 1). The address and the permission come by themselves afterwards. |
| *… it is on a results site, but no relay key is saved in OpenPairings* | OpenPairings has not got the box's permission from the results site (yet). Usually it is seconds away; otherwise the results site cannot be reached, said no, or is an older version. | Open Settings, Live boards, card **The results site**: it says which. *Getting permission…*: wait, it is tried again by itself. *Not yet … : reason*: read the reason, then **Try again**. *Older version*: see the next row. |
| The card says *it is an older version that cannot do this by itself* and shows a **Relay key** field | The results site is from before it could hand out the permission. | Ask that site's administrator for a relay key for the tournament and paste it in the field. See [Relay keys](17-live-boards.md#relay-keys). |
| The card says *Put the tournament on the results site first* | The tournament is not on the results site yet. | Publish it (step 1). |
| *That does not look like a relay key: 16 to 200 characters, no spaces.* | Only with an older results site: the pasted key was cut or has spaces. | Paste it again. |
| The box was sending and the results site now refuses it | The permission was replaced or revoked (by you, or by the site's administrator). | Settings, Live boards, **Replace the box's permission**. The box picks the new one up by itself. |
| *There are already 8 codes.* | The limit. | Withdraw a code you no longer use. |
| *The code reaches no tournament just now* | The tournament was deleted or archived, or the group is empty. | Check the tournament; it cannot be on a box when archived or handed off. |
| *OpenPairings asks to slow down* | Too many requests. | Nothing: the box tries again by itself. |
| The new round does not appear | The box asks about every five seconds. | Wait a few seconds. If still nothing, look at the link state in Setup, or use **Start round N**. |
| *Clock not in starting position: … the clock is turned or the lever is the wrong way* | The clock is not set for White (it stands to the right of the board, the lever up on White's side). | Turn the clock or tip the lever. The message goes by itself. |
| The same game is reported twice | Two codes reach the same tournament on one box. | Keep one code (see [several tournaments](#several-tournaments)). |
| No **Board saw** column on the Pairings page | No code reaches this tournament yet and no board has reported a game. | Make a code (step 2) and add it to the box. |
| Red *differs* in the Board saw column | The board saw another result than the one entered. | Check the scoresheets. Nothing is blocked. |
| A tile says *Pairing changed in OpenPairings* | A pairing changed after moves were played. | See [During the round](#during-the-round). |
| The results site shows nothing | Games wait in the queue; or the round is not published; or the box has no permission yet (the tournament is not on the results site, or the site is unreachable, said no, or is too old). | Alnasl's **Outbox** page says what waits and why, and Settings, Live boards, card **The results site** says where the permission stands. A game is only shown for a board of a published round. |

## Limits today {#limits-today}

- **Team events** show on the box as flat boards, numbered through the round,
  not grouped by match, and without the team names.
- **Only the first game of a board in a round leaves the box.** A second game
  on the same board (a new game after a stoppage) stays on the box and in its
  PGN; the results site, Lichess and OpenPairings know one game per board and
  round.
- **Chess960** is not supported.
- **A box on another machine uses a desktop OpenPairings over plain http.**
  It works on the hall's own network after you switch it on, the code crosses
  that network readable, and a changed address means a new code; see
  [Alnasl on another machine](#desktop-on-the-network). It has been run on one
  computer talking to its own network address, not yet between two machines
  in a hall.
- **The connect code is paste-only on the box.** Scan the QR code with the
  phone's own camera, copy the link, paste it.
- **No Raspberry Pi image, and no 32-bit build.** The Linux install needs a
  64-bit system, and no Pi has run Alnasl yet; see [What you need](#what-you-need).
- More limits of the link itself are in [Limits](17-live-boards.md#limits).
