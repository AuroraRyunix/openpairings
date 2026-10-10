# Live boards and Alnasl

Live boards show the games of a round as they are played, move by move, with
the clocks, on the results site. The moves come from a relay in the playing
hall. Alnasl is that relay: a small box beside electronic DGT boards that reads
the moves and sends them to OpenResults. The spectator pages are built and on the results site; they stay empty until a
relay sends moves. Alnasl itself is planned.

> [!WARNING] The relay is not available yet
> The live pages are part of the results site, but a tournament shows boards
> only when a relay in the hall sends its moves - and Alnasl, that relay, is
> not finished: its repository holds the plan and a tool for recording the
> board's signal, and nothing runs yet. Each part below is marked **built** or
> **planned**.

## Status at a glance {#status-at-a-glance}

| Part | Status |
| --- | --- |
| The live pages: broadcast, All boards, projector view, piece sets, PGN, broadcast delay | built |
| The ingest route that takes a board's moves and clocks, and the relay keys | built |
| Alnasl, the relay in the hall | planned, design stage |
| An arbiter's switch in OpenPairings that says a tournament has live boards | built |

## What Alnasl is {#what-alnasl-is}

*Planned.* Alnasl is a relay in the playing hall. It reads the electronic
boards, turns what they report into legal moves, and sends the moves and the
clock times to OpenResults as the game is played. It keeps working when the
hall's internet does not, and a board that hangs or a loose cable cannot touch
the pairing program, because Alnasl is a separate program from OpenPairings.

Alnasl is not affiliated with or endorsed by DGT. The DGT name is used only to
say which boards Alnasl talks to.

## The planned hardware {#the-planned-hardware}

*Planned.* These are the plans in the Alnasl repository. None of them is built.

- **Boards:** DGT electronic boards, in their RS232 and USB-C models. Both come
  down to a serial stream, so one driver serves both.
- **One loop:** a serial loop of up to 12 boards, each with its own address on
  the bus, polled in turn.
- **Moves:** worked out from the positions the boards report, so a piece lifted
  and put back, a capture made in two steps, or a piece knocked over does not
  become a wrong move.
- **Clocks:** taken from a DGT clock on the board, when there is one.
- **The box:** a Raspberry Pi with a screen, keyboard and mouse for the arbiter,
  running Photon OS and shown full screen in a kiosk browser.
- **Offline:** moves are kept on the box and sent in order once the connection
  is back. A finished game is also kept as a PGN file on the box.
- **A local screen for the arbiter:** which boards answer, each board's live
  position, linking a board to a game of a round, and the connection to
  OpenResults with the number of moves waiting.

Later plans are more loops per box and more makes of board, each behind the
same interface.

The Alnasl repository has a guide for recording a real loop, with DGT's own
software driving the boards through a proxy that writes down every byte. The
plan is to write the driver against such a recording before it meets a board.
No setup steps are given here, because the sources do not describe them yet.

## Relay keys {#relay-keys}

*Built.* A relay is a box in a room full of people,
and it must not be able to rewrite the whole tournament. So each relay gets its
own key. An administrator of the results site makes a relay key for one
tournament, on the page Tournaments, the tournament, Relay keys. The key is
shown once and kept only as a fingerprint. The page lists each key with the
time it was last used, and a key can be revoked.

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
the flag alone, without the code). A player listed under FIDE itself (code
FID) gets a white flag with the word FIDE on it. A code that names no
federation keeps the code and gets no picture.

## Turning live boards on {#turning-live-boards-on}

*Built.* In OpenPairings: Settings, OpenResults, the card *Publishing each
round*, the switch **Live boards**. It is off for every tournament until you
switch it on, and it is offered only while the tournament is published.

On, OpenPairings sends a word in the snapshot (`live_boards: true` in the
tournament part) and publishes the tournament again at once. The public pages
then link to the live boards. Off, the word is not sent and the link goes with
the next copy. The live pages themselves work with or without the word, for
anyone who has their address.

The switch is your statement that the boards are being relayed. It does not
start Alnasl and does not look for it: with no relay sending moves, the link
leads to boards in the starting position. The setting is in a JSON backup and
is written to the audit log.

## Limits {#limits}

- **Only published games are shown.** A game on a board that is not in the
  published snapshot is stored but not shown, until the arbiter publishes that
  round.
- **Clocks are the relay's.** A running clock is counted down in the browser
  from the last report, and corrected at each report.
- **Illegal moves are refused.** The site checks every move against the rules.
  A move that is illegal, or that fits two legal moves, refuses the update and
  names the move, and nothing is stored from that update.
- **Only two piece sets** are offered.
