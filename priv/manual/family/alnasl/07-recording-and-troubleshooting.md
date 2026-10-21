# Recording, replay and troubleshooting

Alnasl writes down everything the boards say, so that a game that went wrong in the hall can be looked at again at a desk. This chapter covers that, the other pages that keep a record, and what to do when something is wrong.

## Recordings and replay {#recordings}

The Recordings page lists the raw captures: everything every board delivered, as it delivered it, whatever the tracker made of it. It records all the time; there is nothing to switch on.

For a capture you can:

- **Replay it** through the tracker as a dry run. Nothing is saved or sent. It shows what moves the tracker makes of it and where it lost the thread.
- **Export it as a test fixture**, so a failure in a hall becomes a test at a desk. This is for whoever maintains Alnasl; if you are not that person, you can ignore it.
- **Download it.**

The Recordings page shows the boards of the hall you are looking at; tick **All my halls** for the others. It lists fifty files a page, and a search finds a board or a file name.

## The Log {#the-log}

What happened, in sentences, with filters: board connected, moves recovered, out of sync, repaired by the arbiter, offline, back. Everything you do on a board's page, a repair or a correction, is in it with the time. It shows this hall's lines (**All my halls** shows the rest), fifty a page, and a search box finds a word in them.

## The Results page {#the-outbox}

The connections, honestly: for the results site and for every other destination, connected or not, last success, how much is waiting and why it is not going, in words, tournament by tournament. Moves of a tournament that is gone, or has no results page, can go nowhere: the page says so ("Nothing can be sent") and offers "Discard these moves" for that tournament, after a confirmation. Nothing is ever discarded by itself. Each has its own switch and its own "Send now". What waits, what the server refused, and what went out. All of it, the counts and the number in the frame included, is about the tournaments played in the hall you are looking at.

## PGN {#pgn}

Read PGN files or paste moves (they are checked for legality). Attach a game that was not captured to its board, after asking. Compare a scoresheet with the captured game and see the first difference. Export a game, or "Whole round as PGN" for the bulletin.

## When something is wrong {#when-something-is-wrong}

### A board shows "Out of sync" right after the start {#out-of-sync-start}

The starting position was wrong or the first moves were made before the board was linked. Use "Resync from here".

### "Clock not in starting position" before the round {#clock-start}

The clock always stands to the right of the board, White's display toward White. Before the first move the lever must be up on White's side, so that White's time runs first. Turn the clock or tip the lever; the message goes away by itself.

### Moves appear late {#moves-late}

A move is believed once the pieces have stood still for a moment, or as soon as the next player picks up a piece; the move's own clock press makes it immediate. Castling and promotion wait a little longer.

### "Move missing?" on a tile {#move-missing}

The clock was pressed more often than moves were seen. Compare the board with the move list.

### "Code refused" under Connections in Setup {#code-refused}

OpenPairings does not accept the connect code: it was withdrawn there, or it is not the whole line. Alnasl has stopped asking, and the boards go on with the pairings it has. Make a new code in OpenPairings (Settings, Live boards), add it, and remove the old one.

### "No answer" under Connections in Setup {#no-answer}

OpenPairings cannot be reached. Nothing is lost: the boards go on with the pairings Alnasl has, the games are kept for it, and Alnasl asks again by itself. A round paired meanwhile is started with "Start round N" and takes its names when the connection is back.

### A tournament has no results page {#no-results-page}

It is not published from OpenPairings, or no relay key is saved there (Settings, Live boards). Setup, Tournaments, says which. Until then its moves go to OpenPairings only; the address and the key arrive by themselves once they are there.

### The results site shows nothing {#results-site-empty}

Look at the Results page: is anything waiting, and why? Was the round published from the pairing program? A game is only shown for a published board.

### A bridge is "not connected" {#bridge-down}

The bridge cannot reach the server. Nothing is lost: it keeps reading and sends what it missed when the line is back (see [Bridges](03-bridges.md)). Check the bridge's own page: a red dot beside this server means the line is down from its side.

### The box was switched off by accident {#switched-off}

Switch it on. Games, queue and settings are on disk; boards reconnect and carry on. The moves played while it was off are not read.

### "Your role in this hall lets you follow the games, not change them" {#role-refused}

You are a viewer there. Ask an owner of the hall for the arbiter role (see [Accounts, halls and roles](06-accounts-and-halls.md)).

> [!TIP] Still stuck
> Open the Log and the Recordings page before you do anything drastic. They say what the boards said, and that is usually the whole story.
