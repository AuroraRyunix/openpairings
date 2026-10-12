# Live boards and Alnasl

Live boards show the games of a round as they are played, move by move, with
the clocks, on the results site. The moves come from a box in the playing
hall. Alnasl is that box: a small computer beside electronic DGT boards that
reads the moves. It talks to two programs. To **OpenPairings** it asks who sits
where, and reports back what the boards saw. To **OpenResults** it sends the
moves and clocks for the spectators.

> [!WARNING] The box is a first build
> The live pages on the results site work, and so does everything on this side
> of the link: the connect codes, the board column on the Pairings page, the
> stored games and their PGN. Alnasl itself is a first build. It runs on
> simulated boards and has read one real board, and its half of the link with
> OpenPairings is still to be built. Each part below is marked **built** or
> **planned**.

## Status at a glance {#status-at-a-glance}

| Part | Status |
| --- | --- |
| The live pages: broadcast, All boards, projector view, piece sets, PGN, broadcast delay | built |
| The ingest route that takes a board's moves and clocks, and the relay keys | built |
| The link in OpenPairings: connect codes, what the box is told, what it reports, the board column, stored games and PGN | built |
| Alnasl reading boards: simulated boards, and one real board and clock | first build |
| Alnasl's half of the link with OpenPairings | planned |
| The link from a desktop copy to a box on another machine | not built, see [Limits](#limits) |

## What Alnasl is {#what-alnasl-is}

*First build.* Alnasl is a box in the playing hall. It reads the electronic
boards, turns what they report into legal moves, and sends the moves and the
clock times on as the game is played. It keeps working when the hall's
internet does not, and a board that hangs or a loose cable cannot touch the
pairing program, because Alnasl is a separate program from OpenPairings.

The box always calls out. OpenPairings never calls the box, so the hall opens
no port and needs no fixed address.

Alnasl is not affiliated with or endorsed by DGT. The DGT name is used only to
say which boards Alnasl talks to.

## The hardware {#the-planned-hardware}

*First build.* What the Alnasl repository describes:

- **Boards:** DGT electronic boards, in their RS232 and USB-C models. Both come
  down to a serial stream, so one driver serves both. One real board and clock
  have been read; a whole game on it has not been played yet.
- **One loop:** a serial loop of up to 12 boards, each with its own address on
  the bus, polled in turn. The loop's wire format is still assumed, not
  verified.
- **Moves:** worked out from the positions the boards report, so a piece lifted
  and put back, a capture made in two steps, or a piece knocked over does not
  become a wrong move. A move the box worked out afterwards, or guessed, is
  counted as such, and the count travels with the game.
- **Clocks:** taken from a DGT clock on the board, when there is one.
- **The box:** a Raspberry Pi with a screen, keyboard and mouse for the arbiter,
  shown full screen in a kiosk browser.
- **Offline:** moves are kept on the box and sent in order once the connection
  is back.
- **Several tournaments on one box:** tables 1 to 4 can play in one tournament
  and tables 5 to 8 in another. Which table belongs to which tournament is
  decided on the box, not in OpenPairings.

## Connecting a box {#connecting-a-box}

*Built in OpenPairings; the box's side is planned.* In OpenPairings: Settings,
**Live boards**.

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

### Who may {#who-may}

Whoever may edit the tournament: its owner and the arbiters it is shared with.
Not on an archived or handed-off tournament. Making a code, withdrawing one,
saving or removing the relay key, and the first time a box uses a code are all
in the audit trail.

### What the box is told {#what-the-box-is-told}

The tournament's name, place and dates, the rate of play, the rounds, and for
each round the boards: who has White and who has Black, with name, title,
rating, federation and FIDE ID, and for a team event the match and the board
within it. Nothing else about a player leaves: no birth date, no club, no
e-mail address, no phone number.

It is also told which round is on. OpenPairings has no button that starts a
round: a round that is paired is on. So when you pair a round, the box starts
it by itself, within about five seconds. In a round robin, where every round
is paired at once, the round that is on is the first one still waiting for a
result.

A change after that reaches the box the same way: a board swapped, a player
replaced, a round paired again. If the box still reports a game for a pairing
that no longer exists, or whose players changed, the report is refused and
nothing is stored under the wrong game.

### The relay key {#the-relay-key-for-the-box}

To send moves to the results site the box needs a relay key (see
[Relay keys](#relay-keys)). An administrator of the results site makes one for
the tournament. Paste it once into **Relay key** on Settings, Live boards, and
the box receives it over the link, together with the address of the results
site and the tournament's public short name. Nothing has to be typed on the
box.

The relay key is kept on this machine so that it can be handed on. It is not
shown again once saved (only its last four characters), and it is not in an
export. The field is there only while the tournament is published.

Without a relay key the box still reads the boards and reports to OpenPairings.
It sends nothing to the results site.

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

## Relay keys {#relay-keys}

*Built.* A relay is a box in a room full of people,
and it must not be able to rewrite the whole tournament. So each relay gets its
own key. An administrator of the results site makes a relay key for one
tournament, on the page Tournaments, the tournament, Relay keys. The key is
shown once and kept only as a fingerprint. The page lists each key with the
time it was last used, and a key can be revoked.

The key is given to the box through OpenPairings: see
[The relay key](#the-relay-key-for-the-box).

A relay key works for that one tournament and for the live route only. It
cannot publish, delete, or change anything else. It has its own budget of 1200
requests a minute. Taking a tournament down removes its relay keys, and a
transfer to another installation revokes them.

The route is `POST /api/tournaments/:slug/live`. Its full contract, for whoever
writes a relay, is in OpenResults' `docs/live-boards-api.md`.

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
[The hall display](16-openresults.md#the-hall-display-and-the-projector-view).

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
as **Live link on the results site**. It is off for every tournament until you
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

- **A desktop copy reaches a box on the same computer only.** The desktop
  edition answers on its own computer and nowhere else, so its connect code
  says `http://127.0.0.1` and works for a box program running on that
  computer. A box elsewhere on the hall's network cannot reach a desktop copy.
  The hosted edition has no such limit.
- **OpenPairings does not check the moves.** It has no chess rules of its own.
  A move is stored as the box wrote it, provided it is shaped like a move. The
  box checks legality, and so does the results site.
- **A code is a key.** Whoever holds a code can read the tournament's pairings
  and report games for it. It cannot enter a result, change a pairing or read
  anything else. Withdraw a code you no longer use.
- **What travels in an export.** The games the boards reported are in the JSON
  export and in a restore point. The connect codes and the relay key are not: a
  copy on another machine makes its own.
- **Only published games are shown on the results site.** A game on a board
  that is not in the published snapshot is stored but not shown, until the
  arbiter publishes that round.
- **Clocks are the box's.** A running clock is counted down in the browser from
  the last report, and corrected at each report.
- **Illegal moves are refused by the results site.** The site checks every move
  against the rules. A move that is illegal, or that fits two legal moves,
  refuses the update and names the move, and nothing is stored from that update.
- **Only two piece sets** are offered.
