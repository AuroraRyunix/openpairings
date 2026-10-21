# Live boards and Alnasl

Live boards show the games of a round as they are played, move by move, with
the clocks, on the results site. The moves come from a box in the playing
hall. Alnasl is that box: a small computer beside electronic chessboards that
reads the moves. It talks to two programs. To **OpenPairings** it asks who sits
where, and reports back what the boards saw. To **OpenResults** it sends the
moves and clocks for the spectators.

> [!NOTE] Setting it up
> This chapter says what live boards are and what each page of them shows. For
> the set-up, step by step, hosted or on a desktop copy, see
> [Setting up electronic boards](18-setting-up-boards.md).

> [!WARNING] Alnasl is a first build
> The live pages on the results site, the connect codes, the board column on
> the Pairings page and the stored games with their PGN are built here. Alnasl,
> the program in the hall, has the other side of the link and has run it
> against OpenPairings with simulated boards. It has read one real board; a
> whole game on a real board is not yet proven (see its README, "What is not
> done").

## Status at a glance {#status-at-a-glance}

| Part | Status |
| --- | --- |
| The live pages: broadcast, All boards, projector view, piece sets, PGN, broadcast delay | built |
| The ingest route that takes a board's moves and clocks, and the box's permission to use it (fetched by OpenPairings, nothing to copy) | built |
| The link in OpenPairings: connect codes, what the box is told, what it reports, the board column, stored games and PGN | built |
| Alnasl's side of the link with OpenPairings | built, in Alnasl; run with simulated boards, not yet in a hall |
| The link from a desktop copy to a box on another machine in the hall | built, off until you switch it on; see [A box elsewhere on the network](#boxes-on-the-network) |

## What Alnasl is {#what-alnasl-is}

Alnasl is a box in the playing hall. It reads the electronic
boards, turns what they report into legal moves, and sends the moves and the
clock times on as the game is played. It keeps working when the hall's
internet does not, and a board that hangs or a loose cable cannot touch the
pairing program, because Alnasl is a separate program from OpenPairings.

The box always calls out. OpenPairings never calls the box, so the hall opens
no port and needs no fixed address.

## The hardware {#the-planned-hardware}

What the box works with. For what a given version of Alnasl supports, see
Alnasl's own documentation.

- **Boards:** electronic chessboards, in their RS232 and USB-C models. Both come
  down to a serial stream, so one driver serves both.
- **One loop:** a serial loop of up to 12 boards, each with its own address on
  the bus, polled in turn.
- **Moves:** worked out from the positions the boards report, so a piece lifted
  and put back, a capture made in two steps, or a piece knocked over does not
  become a wrong move. A move the box worked out afterwards, or guessed, is
  counted as such, and the count travels with the game.
- **Clocks:** taken from a clock on the board, when there is one.
- **The box:** a Raspberry Pi with a screen, keyboard and mouse for the arbiter,
  shown full screen in a kiosk browser.
- **Offline:** moves are kept on the box and sent in order once the connection
  is back.
- **Several tournaments on one box:** tables 1 to 4 can play in one tournament
  and tables 5 to 8 in another. Which table belongs to which tournament is
  decided on the box, not in OpenPairings.

## Connecting a box {#connecting-a-box}

*Built.* A box is connected to OpenPairings with a connect code. In
OpenPairings: Settings, **Live boards** - or, with no code at all, by
[connecting your account](#connecting-your-account). The same, as steps, is in
[Setting up electronic boards](18-setting-up-boards.md).

### A code for the tournament {#a-code-for-the-tournament}

Press **New code**. The page shows a line of text and the same line as a QR
code. Scan it with the box, or copy the line into the box's setup page. That is
all the setting up there is: the code carries the address of this server and a
secret, and the box learns the rest over the link.

The code is shown **once**. When you leave the page it cannot be shown again,
because OpenPairings does not keep it, only a fingerprint. If you lose it, make
another: a code costs one click.

Make one code per box. The list under the button shows each code by its last
four characters, with the box that uses it, its version, when it last called
and how many boards it has on this tournament. **Withdraw** ends a code: the
box that holds it is refused from its next request and needs a new one. A
tournament can have up to 8 codes.

### A code for a group {#a-code-for-a-group}

A tournament in a [group](03-tournament-setup.md#tournament-groups) also gets **Codes for the
group**. One scan of a group code sets the box up for every tournament of the
group, and a tournament added to the group later reaches the box without a new
scan.

A group code reaches the tournaments of the group that **the person who made
the code** may open, and no others. A section run by another arbiter, which you
cannot open, is not handed to your box either.

### Connecting your account {#connecting-your-account}

The third way needs no code at all. On the box, Alnasl's **Setup ->
Tournaments -> Connect an OpenPairings account** sends your browser here. You
sign in if you were not, and a page asks whether that box may read your
tournaments. It names the box and, in large letters, the address you will be
sent back to: check that it is your box before you press **Allow**. **Cancel**
connects nothing.

An account connection reaches every tournament you may edit - your own and the
ones shared with you - that is **current**: not finished, or finished within
the last 14 days (counted from the last round's date). A tournament with no
round yet counts as current, and so does one still waiting for a postponed
game. Archived and handed-off tournaments never reach it, and one you lose
access to drops off at the box's next request. A tournament you make next week
appears on the box by itself.

The connections of your account are on your **account page, Live boards**:
the box's name, when it last called, and the last characters of its code.
**Withdraw** cuts a box off from its next request on. An account can have up
to 8 boxes connected. Making and withdrawing one are in the installation's
audit trail, since they belong to no single tournament.

A tournament's own **Settings, Live boards** page also lists the account
connections that reach it, under **Account-wide links**: the box, the account,
when it was made and when it last called. The list is read-only and only people
who may edit the tournament see it. Each entry links to the account page, where
the account it belongs to withdraws it.

On a desktop copy this works for a box program on the same computer. A box
elsewhere on the hall network still needs a network code (below): the network
listener does not take account connections.

### A box elsewhere on the network {#boxes-on-the-network}

*Built, desktop edition only. Off until you switch it on.* The desktop edition
answers on its own computer and nowhere else, and that does not change. A box
that is not on that computer (a small computer beside the boards, a second
laptop) needs a way in, and you can give it one: Settings, **Live boards**,
card **Boxes elsewhere on this network**, switch **Let boards on this network
connect**.

What the switch does:

- It opens **one extra door** on your computer, on the network address you
  choose, for the board box and nothing else. Your tournaments, the pages of
  OpenPairings and everything else stay reachable from your own computer only,
  exactly as before. Somebody who opens that door in a browser gets "nothing
  here".
- The page then offers **two kinds of code**: *New code for a box on this
  computer* (as before, `http://127.0.0.1`) and *New code for a box on the
  network*, which carries your computer's address on the hall's network. The
  page says in words where each code leads, next to the QR code.
- The door only answers a code made for the network, only to machines on a
  local network, and it is **closed whenever no such code exists**: withdraw
  the last one and it shuts. A network code works until it is withdrawn; withdraw it when the event is over.
- It is a setting of your computer, for all tournaments, and it is remembered:
  after a restart the door is back by itself. Connections shows where it
  stands and has a **Turn off** button.

> [!WARNING] The code travels readable
> The door speaks plain http. The code of a box crosses the network unprotected,
> every few seconds. On **a cable between the two machines**, or **a network of
> your own** (your own small router, nobody else on it), that is fine. On **a
> wifi that the players are on too**, anybody who knows how can read the code,
> and then see the pairings and send in moves as if they were a board. They
> cannot enter a result (a board never does), change a pairing, or see
> anything else. Prefer a cable or your own network, and withdraw the code
> after the event.

> [!IMPORTANT] Windows will ask
> The first time, Windows shows *Windows Security: do you want to allow this
> app to communicate on these networks?* Tick **Private networks** and choose
> **Allow**. OpenPairings cannot answer that for you. If you chose Cancel, or
> never saw the question, the box gets no answer: open Windows Security,
> Firewall and network protection, **Allow an app through firewall**, and
> allow OpenPairings on private networks.

**Which address.** If your computer is on one local network, the page takes
that address. If it is on several (a cable to the box and the venue's wifi),
pick the one the box is on: only that one is opened. The port is `4747` unless
you change it; if another program already uses it the page says so and you
pick another. Nothing else is affected by that.

**If the address changes.** Most networks hand out addresses themselves, and
tomorrow yours may be another one. The code made today then points at an
address where nothing is. OpenPairings notices, when it starts and on this
page: *This computer's address changed from … to …: boxes with the old code
cannot find it.* It does **not** move the door to the new address by itself,
because a laptop that is suddenly on another network is exactly when you want
to be asked first. Pick the new address, make a new code and give it to the
box. To stop it happening, give the computer a **fixed address** (in the
router, or in Windows' network settings), or use a cable between the two
machines and nothing else. The list of codes marks each network code with the
address it was made for, and says so in red when that is no longer where the
computer answers.

On a computer with one network, the page may also show the same code with the
computer's **name** instead of its address. A name survives a changed address,
but only works if the box can look the name up, which depends on the network.
Try the address first.

### Who may {#who-may}

Whoever may edit the tournament: its owner and the arbiters it is shared with.
Not on an archived or handed-off tournament. Making a code, withdrawing one,
the results site handing out or refusing the box's permission, replacing it, and
the first time a box uses a code are all in the audit trail.

### What the box is told {#what-the-box-is-told}

The tournament's name, place and dates, the rate of play, the rounds, and for
each round the boards: who has White and who has Black, with name, title,
rating, federation and FIDE ID, and for a team event the match and the board
within it. Nothing else about a player leaves: no birth date, no club, no
e-mail address, no phone number.

It is also told which round is on. OpenPairings has no button that starts a
round: a round that is paired is on. So when you pair a round, the box starts
it by itself, within about five seconds. Of the rounds paired last
together (one in a Swiss or a Keizer, both legs of a two-leg match, every round
of a round robin), the round that is on is the first with a game still open,
or the last of them when none is. So a result cleared in round 2 while round 3
is played does not send the boards back to round 2.

A change after that reaches the box the same way: a board swapped, a player
replaced, a round paired again. If the box still reports a game for a pairing
that no longer exists, or whose players changed, the report is refused and
nothing is stored under the wrong game.

### The box's permission for the results site {#the-relay-key-for-the-box}

To send moves to the results site the box needs that site's permission, for
this one tournament. **OpenPairings arranges it by itself.** There is nothing
to ask anybody for, nothing to copy and nothing to paste.

The card **The results site** on Settings, Live boards says where it stands:

| The card says | What it means |
| --- | --- |
| *Put the tournament on the results site first* | The tournament is not published, so there is nowhere to send moves. Settings, OpenResults. |
| *Not asked yet.* | The tournament is on the site and no box is in sight. Nothing to do: it is asked as soon as there is a connect code or the live link is on. |
| *Getting permission from the results site…* | Being asked. Usually a few seconds. If the site cannot be reached it is tried again by itself, and the card says so. |
| *Yes. The box may send moves there.* | Done. The box receives the permission over the link, with the site's address and the tournament's short name. Nothing is typed on the box. |
| *Not yet. The results site did not give permission: …* | The site said no, and the card says why. **Try again** asks at once; it is also asked again by itself a few times a day. |

OpenPairings asks when the tournament is on the results site and one of these
is true: a connect code reaches it (its own, or its group's), a box has
reported a game, or **Show the live boards on the results site** is on. It does not matter
in which order you do things. A code made before the tournament was published
is served as soon as the first publish has arrived.

**Replace the box's permission** asks the results site for a new one. The site
stops accepting the old one at that moment. A connected box picks the new one
up within seconds; a box that is switched off picks it up when it is back. Use
it when a box is lost or lent out.

Without the permission the box still reads the boards and reports to
OpenPairings. It sends nothing to the results site.

What happens behind this, and the one case where a key is still pasted by
hand, is in [Relay keys](#relay-keys).

## The board column {#the-board-column}

*Built.* On the Pairings page, to the right of the pairings, a tournament with
live boards gets a column **Board saw**. A tournament without a box does not
have the column.

**A board never enters a result.** You enter results as before. The column
shows what the board reported, beside what you entered:

| The column shows | It means |
| --- | --- |
| `-` | The board reported nothing for this game. |
| *playing* | A game is in progress. |
| a result, in bold | The board saw a result and you have not entered one yet. |
| a result, quiet | The board saw the result you entered. |
| a result in red, *differs* | The board saw another result than the one you entered. |
| *no result* | The board saw the game end and could not tell how. |

Red is a warning and nothing more. It blocks nothing: you can pair the next
round, publish and send as usual. Check the scoresheets, and correct the result
if it is the entered one that is wrong. A forfeit you entered is compared by who
got the point: a board that saw `1-0` agrees with `1-0FF`.

On a phone the board's report is a line of its own under the result buttons.
The column is not printed and is not in the pairing list for the wall: it is
the arbiter's check, not part of the pairing.

## Games and PGN {#games-and-pgn}

*Built.* Every entry in the column is a link to the game: the moves, the clocks
at the last report, the board's result beside yours, and how many moves the box
worked out afterwards or guessed. A guessed move is the box's best reading of
an unclear board, not something it saw.

The games are kept with the tournament. There are three downloads:

- **one game**, on the game's page;
- **one round** and **the whole tournament**, on Settings, Live boards.

In each file the headers come from the tournament: event, site, date, round
and board (`3.12` is board 12 of round 3), White, Black, ratings, FIDE IDs and
the time control. The **result is the one you entered**, or `*` until you have.
A board that saw `1-0` on a game you have not entered is still `*` in the file.
Clock times are written after the moves as `{[%clk 1:29:58]}` where the box
reported them.

The game's page also offers **The box's own PGN**, the file exactly as the box
wrote it, for comparison.

The PGN export on the Pairings page (**More**, PGN) is unchanged and still
carries no moves.

**A game goes with its pairing.** When you unpair a round and pair it again,
the games the boards had reported for the old pairings are removed from
OpenPairings at that moment: they belong to games that no longer exist. The
same holds for a board you delete, a team line-up that drops a board, and a
restore point that does not have the pairing. The audit trail gets one line
with how many games were removed. The box keeps its own copy and its own PGN.
A game whose pairing merely moved to another board, or changed a player, is
kept. If you go back to a restore point from before the re-pairing, the old
pairings return with their games as they stood when the point was taken; the
box does not send the later moves again by itself, but you can send a game
again from the box.

## Relay keys {#relay-keys}

*Built.* This section is reference. In the normal flow you never see a relay
key: see [The box's permission](#the-relay-key-for-the-box).

A relay is a box in a room full of people, and it must not be able to rewrite
the whole tournament. So the box is never given what OpenPairings publishes
with. It gets a **relay key**: a credential that works for one tournament and
for the live route only. It cannot publish, delete, or change anything else,
and it has its own budget of 1200 requests a minute.

**How the box gets one.** OpenPairings asks the results site, with the same
credentials it publishes the tournament with, and the site hands a relay key
to exactly that publisher, for that tournament only. OpenPairings keeps it on
its own machine and hands it to the box over the link. The results site keeps
only a fingerprint. The key is not in an export, not in a restore of another
machine's backup, and not shown anywhere: the settings page and the audit
trail show its last four characters.

**Asking again replaces.** Because the site keeps only a fingerprint, it
cannot hand the same key out twice. Each time OpenPairings asks, it gets a new
key and the previous one stops working. That is what **Replace the box's
permission** does.

**When it ends.** Taking the tournament down from the results site removes its
relay keys there, and OpenPairings drops its copy. A transfer to another
installation revokes them, and so does the site's administrator revoking the
installation. The administrator of the results site sees every relay key of a
tournament on the page Tournaments, the tournament, Relay keys (who made it,
when, when it was last used) and can revoke any of them there. If that
happens, press **Replace the box's permission**.

**An older results site.** A results site from before this cannot hand out a
relay key. The card then says *Not yet. The results site did not give
permission: it is an older version that cannot do this by itself*, and only
then shows a field **Relay key**. Ask the administrator of that results site
to make a key for the tournament (Tournaments, the tournament, Relay keys) and
paste it once. The box receives it over the link as usual. Once the site is
updated, **Try again** fetches one the normal way.

The route the box posts to is `POST /api/tournaments/:slug/live`, and the one
OpenPairings asks on is `POST /api/tournaments/:slug/relay-keys`. The full
contract of both is in OpenResults' `docs/live-boards-api.md`.

## Spectator pages {#spectator-pages}

*Built.* The pages are sockets: they re-read the
games themselves, so a move appears within a second and no page is served from
a cache.

### The broadcast {#the-broadcast}

The broadcast is the page for a round's games, at `/t/<tournament>/live`, which
goes to the newest round. It has three columns:

- **Left:** the round buttons, a search box, and every game of the round, with
  the board, both players, the result (`1-0` or `½-½`), and live games marked.
  A team round's boards sit under their match.
- **Middle:** one game, large, with a bar above and below the board. The bars
  show the name, title, federation and rating, the clock in a box, and the
  score once there is a result. The last move is lit, and there is a full-screen
  button.
- **Right:** the event name, dates, place and round, and the moves as a table in
  figurine notation, with the current move highlighted. A *Game info* tab sits
  beside it.

The page opens on the first game in progress. A link to one board,
`/t/<tournament>/live/<round>/<board>`, opens on that game, and picking a game
from the list changes the middle without a reload. On a phone the columns stack
and nothing scrolls sideways. There is no evaluation bar, because there is no
engine.

### All boards {#all-boards}

*Built.* All boards, at
`/t/<tournament>/live/<round>/all`, is a grid of every board of a round, with a
clock on each tile and a live badge on the games in progress. It is one click
from the broadcast and back.

### The projector view {#the-projector-view}

*Built.* The projector view puts the games you choose
on a screen in the hall. It opens from the broadcast or All boards with the
*Projector* button, which shows a list of the round's boards to tick: all of
them, none, or a few.

The link it opens can be bookmarked for the hall computer, for example
`/t/<tournament>/live/<round>/projector?boards=1,3,5&auto=1&pieces=chessnut`.
With no list of boards it shows every board. A colour can be fixed in the
address too.

The screen holds only the games: no header, no moves and no buttons for stepping
through. Each tile shows Black's bar, the position with the last move lit, and
White's bar. The tiles fill the window, and the page works out how many columns
give the largest boards. Press <kbd>f</kbd> for full screen.

With `auto=1`, which is on by default in the list, finished games leave the
screen by themselves. A game that ends shows its result across its board for
half a minute, then makes room for the others. Forfeits are not shown in this
mode. When the last game has gone, the screen says so and lists the results.
Without the automatic mode, finished games stay where they are with their
result. The older projector screen of pairings, on the results site, is a
separate page and is not changed. See
[The hall display](15-openresults.md#the-hall-display-and-the-projector-view).

### Piece sets {#piece-sets}

*Built.* The boards are drawn with one of two piece
sets: Cburnett, the default, and Chessnut. The viewer chooses with the Pieces
picker on the live pages, and the choice is remembered in the browser. A screen
with no picker can be given a set in the address, with `?pieces=chessnut`.

### Forfeits and results {#forfeits-and-results}

*Built.* A forfeit that the arbiter published
(`1-0FF`, `0-1FF` or `0-0FF`) shows as a forfeit whatever the relay sends. Nobody
sits at a forfeited board, so the board shows *Forfeit* or *Double forfeit*, the
result as `1-0 FF`, and an empty board marked *Not played - forfeit*. A board with
a published result and no game from the relay shows *Game over*, not *Not
started*.

A published result always wins. Otherwise, once the game is finished and the
round's results are public, the relay's result is shown and marked as
provisional. In a round where the arbiter withholds results, a finished game
shows only *Game over*.

### The broadcast delay {#the-broadcast-delay}

*Built.* Some organisers must show the game a number
of minutes behind the play, under anti-cheating rules. An administrator of the
results site sets this per tournament, in minutes, on the page Tournaments, the
tournament, *Live board delay*. The default is 0. Every page, the hall display
and the PGN download then show the game as it stood that many minutes ago. The
server still stores everything in real time, and nothing after the cutoff is
sent to a browser. A change takes effect at once, both ways.

### PGN download {#pgn-download}

*Built.* A game can be downloaded as a PGN file. The
address ends in `/pgn`, for example `/t/<tournament>/live/<round>/<board>/pgn`.
The file is built on each request, at the broadcast delay.

### Federation flags {#federation-flags}

*Built.* Where OpenPairings sends the setting for
flags (the *Federation flags* tick, on unless it is unticked), a small flag is
shown beside a player's federation code: on the starting list, the entry list,
the player card, the hall display and the live pages (on the projector view,
the flag alone, without the code). A player listed under FIDE itself, or with a
code that names no country, keeps the code and gets no picture.

## Turning live boards on {#turning-live-boards-on}

*Built.* In OpenPairings: Settings, OpenResults, the card *Publishing each
round*, the switch **Live boards**. The same switch is on Settings, Live boards,
as **Show the live boards on the results site**. It is off for every tournament until you
switch it on, and it is offered only while the tournament is published.

On, OpenPairings sends a word in the snapshot (`live_boards: true` in the
tournament part) and publishes the tournament again at once. The public pages
then link to the live boards. Off, the word is not sent and the link goes with
the next copy. The live pages themselves work with or without the word, for
anyone who has their address.

The switch is your statement that the boards are being relayed. Connecting a
box does not switch it on, and the switch does not start a box: with nothing
sending moves, the link leads to boards in the starting position. The setting
is in a JSON backup and is written to the audit log.

## Limits {#limits}

- **A desktop copy reaches a box on another machine only if you let it.** The
  desktop edition answers on its own computer and nowhere else. A box program
  on that computer needs nothing more. A box elsewhere in the hall needs the
  switch **Let boards on this network connect**, a code made for the network,
  and a network both machines are on; see
  [A box elsewhere on the network](#boxes-on-the-network). That link is plain
  http, IPv4 only, and its codes work until they are withdrawn. The hosted edition has none of
  these limits, and no such switch.
- **OpenPairings does not check the moves.** It has no chess rules of its own.
  A move is stored as the box wrote it, provided it is shaped like a move. The
  box checks legality, and so does the results site.
- **A code is a key.** Whoever holds a code can read the tournament's pairings
  and report games for it. It cannot enter a result, change a pairing or read
  anything else. Withdraw a code you no longer use.
- **What travels in an export.** The games the boards reported are in the JSON
  export and in a restore point. The connect codes and the box's permission for the
  results site (the relay key) are not: a copy on another machine makes its own
  codes and fetches its own permission.
- **Only published games are shown on the results site.** A game on a board
  that is not in the published snapshot is stored but not shown, until the
  arbiter publishes that round.
- **Clocks are the box's.** A running clock is counted down in the browser from
  the last report, and corrected at each report.
- **Illegal moves are refused by the results site.** The site checks every move
  against the rules. A move that is illegal, or that fits two legal moves,
  refuses the update and names the move, and nothing is stored from that update.
- **Only two piece sets** are offered.
- **Team events show as flat boards on the box**, numbered through the round,
  not grouped by match.
- **Only the first game of a board in a round leaves the box.** Further games on
  the same board stay on the box.
- **Chess960 is not supported.**
