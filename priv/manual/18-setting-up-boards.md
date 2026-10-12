# Setting up electronic boards

This chapter is the set-up guide for live boards, start to finish: what to
buy or bring, what to click in which program, and what to do when a round is
on. It has one path for a **hosted** OpenPairings (the web address your
association runs) and one for the **desktop** edition on your own PC. What the
live boards are, and what each page of them shows, is in
[Live boards and Alnasl](17-live-boards.md).

> [!WARNING] A first build
> Alnasl, the program that reads the boards, is a first build. It has run on
> simulated boards and has read one real DGT board and clock; a whole game on
> a real board, and a loop of several boards, are not yet proven. Its own
> README says so under "What is not done". Try the whole set-up in your own
> room, with the boards you will use, before the event.

## What you need {#what-you-need}

- **The boards.** DGT electronic boards, each with its cable to the computer.
  Alnasl reads them as serial ports. A DGT clock on the board gives the clock
  times.
- **A computer in the hall for Alnasl.** The README describes a Raspberry Pi
  with a screen, keyboard and mouse for the arbiter; a PC works too. It needs a
  C compiler and `make` to build the serial library (on Windows the serial
  library is off unless you ask for it, and has a quirk with folders that
  contain a space: see "Serial ports" in the README).
- **Alnasl itself.** It is a separate, free program. Get it from its
  repository, `github.com/AuroraRyunix/Alnasl`, and install it as its README
  says. **There is no installer, no ready-made image and no system service
  yet**: you build it from the source with Elixir and start it with
  `mix phx.server`. If that is more than you want to do, ask whoever
  looks after your computers, or read the README with them.
- **The hall's network**, for a hosted OpenPairings: the computer with Alnasl
  must reach the internet. For the desktop edition, no network is needed (see
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
  address of the results site, the tournament's short name and the key all
  come to Alnasl **through OpenPairings**, so nothing about them is typed on
  the box.

## Set-up with a hosted OpenPairings {#set-up-hosted}

OpenPairings is on the web, Alnasl is in the hall with internet.

### In OpenPairings {#in-openpairings}

1. **Publish the tournament to the results site.** Settings, **OpenResults**,
   **On the results site**: **Link only** or **Listed**. The results site must
   be connected first (see
   [Connecting a results site](14-publishing.md#connecting-a-results-site)).
   Wait until the tournament is on the site: Settings, **Live boards** then
   says *The box sends the moves to … tournament …*. That line is not shown
   before the tournament is on the site, and neither is the Relay key field.
2. **Get a relay key.** The relay key lets the box send moves to the results
   site, for this one tournament. **An administrator of the results site makes
   it**, on the results site's page Tournaments, the tournament, **Relay
   keys**. It is shown once. Ask that administrator for it. (The key is described in [Relay keys](17-live-boards.md#relay-keys).)
3. **Paste the relay key.** Settings, **Live boards**, card **The results
   site**, field **Relay key**, then **Save**. The card then says *A relay
   key is saved (ends in …)*. It is kept on this server, is not shown again and
   is not in an export. Without it the box still reads the boards and reports
   to OpenPairings, but sends nothing to the results site.
4. **Make a connect code.** On the same page, card **Codes for this
   tournament**, press **New code**. The page shows the code as a line of text
   and as a QR code, **once**: *The new code. It is shown this once.* Copy the
   line now. If you lose it, make another; a code is one click.
5. **Decide about the public link.** The switch **Live link on the results
   site** (On / Off) puts a *Live boards* link on the public pages. Connecting
   a box does not switch it on: it is yours to say, when the boards are really
   being relayed.

### In Alnasl, in the hall {#in-alnasl}

6. **Paste the code.** Open Alnasl (`http://localhost:4040`), **Setup**,
   panel **Tournaments**. Paste the whole line in **Connect code** and press
   **Add**. From a phone: scan the QR code with the phone's *own* camera, copy
   the link it shows instead of opening it, and paste that. Alnasl's own page
   cannot scan the QR code (a browser only lends its camera to pages served
   over https), so the code is paste-only on the box.
7. **Test connection.** It checks three things, each in words: *Address*
   (OpenPairings answers), *Code* (the connect code is accepted), *Tournaments*
   (*The code reaches N tournament(s)*). Under each tournament you should see
   the round that is on and *its results page and relay key came with it*.
   Anything else is explained in [When something is wrong](#troubleshooting).
8. **Say which tables play in the tournament.** Under the tournament:
   **Tables from** … **to** …, then **These tables play here**. Table 5 is
   then the tournament's board 1. The box shows how many boards it now has.
9. **Number the boards.** Boards, **Number by touching**: press Start, lift a
   piece on table 1's board, then on table 2's, and so on. (On a phone this
   page is made to be held in one hand. To open the box from a phone, start it
   with `ALNASL_LISTEN=lan` and **set a PIN** in Setup first, before the hall
   fills up.) Or **Number all in connection order**, or type the number in the
   **Table** column.
10. **Check "Ready for round N?"** on Boards. It must say *Ready*. If not, it
    lists what is wrong, board by board: two boards with the same number, a
    board that does not answer, a wrong starting position, a clock that is
    not in its starting position (the lever up on White's side).
11. **Check the Round page.** Every tile should read *Waiting for start*.

### The round {#the-round}

12. **Pair the round in OpenPairings** as always (**Pair round N**). OpenPairings
    has no button that starts a round: a round that is paired is on. Within
    about five seconds the boards of that tournament show the new round, with
    names, ratings and colours. If it does not (no connection), **Start round
    N** on Alnasl's Round page does it by hand.
13. **Play.** Keep Alnasl's Round page open. A tile per board shows the state
    as a shape and a word: *Live*, *Settling*, *Reconstructed*, *Out of sync*,
    *No signal*, *Clock wrong way*, *Finished*. On the Pairings page of
    OpenPairings, the column **Board saw** shows what the board reported,
    beside the result you enter.
14. **Enter the results in OpenPairings**, on the Pairings page, as you always
    do ([Entering results](07-results.md)). A board never enters one. If the
    board saw another result than the one you entered, the entry is red with
    *differs* and the hover text says *Check the scoresheets. Nothing is
    blocked.* Check the scoresheet, correct whichever is wrong, and go on.
15. **Spectators** see the moves on the results site's live pages. They only
    see a game for a board of a **published** round.

## Set-up with the desktop edition {#set-up-desktop}

OpenPairings runs on your own PC (the desktop edition) and Alnasl runs **on the
same PC**.

> [!IMPORTANT] Same computer
> The desktop edition answers on its own computer and nowhere else. The connect
> code therefore says `http://127.0.0.1:<port>` and works only for an Alnasl on
> that computer. **An Alnasl on another machine in the hall cannot reach a
> desktop OpenPairings today.** That is a known limit. If the box must be a
> separate small computer, use the hosted edition.

Steps 4 to 15 above are the same, with these differences:

- **The code.** Settings, **Live boards** says, instead of a server address:
  *This copy answers on this computer only, so the box program has to run on
  this computer too*. Make the code (step 4) and paste it in the Alnasl on the
  same PC (step 6). Test connection works with no internet.
- **The results site is optional.** With internet, do steps 1 to 3 as in the
  hosted set-up, and the moves also go to the results site. Without internet at
  all, skip them: Alnasl and OpenPairings still work together.
- **Publish while you still have internet.** The results address and the short
  name that Alnasl needs exist only once the tournament has reached the results
  site. If the event has no internet, do steps 1 to 3 at home.

### What works without internet {#what-works-offline}

| | With internet | Without internet |
| --- | --- | --- |
| Names, boards, colours and rounds from OpenPairings to Alnasl | works | works (on the same PC) |
| The round starting by itself when you pair it | works | works |
| Moves, clocks, PGN and the result the board saw, back to OpenPairings | works | works |
| The **Board saw** column, the game page and the PGN with moves | works | works |
| Moves to the results site (live pages for spectators) | works | **waits** in Alnasl's queue (the Outbox page says how much), and goes out in order when there is a connection |
| Lichess broadcast (if you set one up in Alnasl) | works | waits in the same way |
| Publishing the tournament, getting the relay key | works | needs internet at that moment |

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
   codes and the relay key are not: a copy elsewhere makes its own. On the box,
   the games, the queue and the settings are on disk in Alnasl's data folder
   (`~/.alnasl` in production), with a PGN file per game.
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
| *No answer. This code is for an OpenPairings on this same computer: is it running?* | A desktop code is used on a computer that is not the one OpenPairings is on, or OpenPairings is not running. | Run Alnasl on the same PC as the desktop OpenPairings, and start OpenPairings. |
| *Something answers at that address, but not as OpenPairings' board link* | A login page of the hall's network, or another program on that port. | Log in to the hall's network, or check the address. |
| *… is not published on a results site, so its moves go to OpenPairings only* | The tournament is not on the results site. | Publish it (step 1). The address and key come by themselves afterwards. |
| *… it is on a results site, but no relay key is saved in OpenPairings* | The relay key was not pasted. | Step 3. |
| Settings, Live boards has no **Relay key** field | The tournament is not on the results site yet. | Publish it first (step 1). |
| *That does not look like a relay key: 16 to 200 characters, no spaces.* | The key was cut or has spaces. | Paste it again. |
| *There are already 8 codes.* | The limit. | Withdraw a code you no longer use. |
| *The code reaches no tournament just now* | The tournament was deleted or archived, or the group is empty. | Check the tournament; it cannot be on a box when archived or handed off. |
| *OpenPairings asks to slow down* | Too many requests. | Nothing: the box tries again by itself. |
| The new round does not appear | The box asks about every five seconds. | Wait a few seconds. If still nothing, look at the link state in Setup, or use **Start round N**. |
| *Clock not in starting position: … the clock is turned or the lever is the wrong way* | The clock is not set for White (it stands to the right of the board, the lever up on White's side). | Turn the clock or tip the lever. The message goes by itself. |
| The same game is reported twice | Two codes reach the same tournament on one box. | Keep one code (see [several tournaments](#several-tournaments)). |
| No **Board saw** column on the Pairings page | No code reaches this tournament yet and no board has reported a game. | Make a code (step 4) and add it to the box. |
| Red *differs* in the Board saw column | The board saw another result than the one entered. | Check the scoresheets. Nothing is blocked. |
| A tile says *Pairing changed in OpenPairings* | A pairing changed after moves were played. | See [During the round](#during-the-round). |
| The results site shows nothing | Games wait in the queue; or the round is not published; or no relay key. | Alnasl's **Outbox** page says what waits and why. A game is only shown for a board of a published round. |

## Limits today {#limits-today}

- **Team events** show on the box as flat boards, numbered through the round,
  not grouped by match, and without the team names.
- **Only the first game of a board in a round leaves the box.** A second game
  on the same board (a new game after a stoppage) stays on the box and in its
  PGN; the results site, Lichess and OpenPairings know one game per board and
  round.
- **Chess960** is not supported.
- **A box on another machine cannot use a desktop OpenPairings.**
- **The connect code is paste-only on the box.** Scan the QR code with the
  phone's own camera, copy the link, paste it.
- **No installer or Pi image for Alnasl**; see [What you need](#what-you-need).
- More limits of the link itself are in [Limits](17-live-boards.md#limits).
