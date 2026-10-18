# OpenPairings, OpenResults and Lichess

Alnasl does not know who plays whom, and it does not host the spectators' page. OpenPairings tells it the pairings and receives what the boards saw; OpenResults shows the games to the public; Lichess can show them too. This chapter is how the three are connected, and what each one gets.

## Where the games go {#where-the-games-go}

Each destination has its own queue, its own pause after a failure, its own line on the Results page (connected or not, last success, how many wait, the last error in words), its own switch and its own "Send now". They do not wait for each other.

| Destination | What it gets |
| --- | --- |
| Results site (OpenResults) | Every change: the whole game so far, with the clock |
| OpenPairings | Each game as it stands: moves, clocks, PGN, the result the board saw, how many moves were reconstructed or guessed |
| Lichess broadcast | The PGN of each game of one round, whenever it changed |

Each game goes to the places of its own tournament: that tournament's results page, that tournament's Lichess round, the OpenPairings it came from. A tournament whose key is refused, or which is not published yet, holds up nobody else's.

Sending is automatic: to OpenPairings from the moment a tournament is linked, to the results site from the moment it has an address and a key (a game recorded before that goes out in full). Lichess stays off until you fill in a round and a token. "Send now" on the Results page only nudges a destination that is waiting out a pause, and always says what it did or why it did nothing.

## Linking to OpenPairings {#linking-to-openpairings}

1. In OpenPairings: Settings, Live boards, make a connect code, for one tournament or for a group of tournaments. It is shown once, as a line of text and as a QR code holding the same text.
2. In Alnasl: Setup, Connections, press "+ Add" (it is open already when there is no connection yet), paste the line and press Add. From a phone: scan the QR code with the phone's own camera, copy the link it shows instead of opening it, and paste it in the field. Alnasl cannot scan it itself: a browser only lends its camera to a page served over https, and the box is not.
3. The tournaments the code reaches appear, each with what came with it: players, the rounds that are paired, the rate of play, and, when the tournament is published, its results page and relay key. Nothing is typed in Alnasl for the results site. A tournament added to the group later appears by itself.
4. The boards are put in the tournament for you. With one tournament and nothing played yet in the hall's own tournament, every board of the hall plays there at once, its table number being its board; the line under the bar says so and has an Undo. With a group, or a game already under way, Alnasl asks which tables play in which, with ranges filled in: "Tables from 5 to 8", table 5 being the tournament's board 1. One board can also be put in a tournament on the Boards page.

Press "Test connection": it really asks, and explains failures in words (a wrong code, a withdrawn one, nobody home, a tournament that is not published).

### All your tournaments at once {#whole-account}

Instead of a code per tournament, connect a whole OpenPairings account:

1. In Alnasl: Setup, Connections, "+ Add", **Connect an OpenPairings account**. Type the address of your OpenPairings (or `http://127.0.0.1:4000` for a copy on this computer). It is remembered; on the hosted server it is filled in already.
2. OpenPairings opens. Sign in if it asks, check which Alnasl is asking, and press **Allow**. You are back in Alnasl.
3. Alnasl now has every current tournament you may edit in OpenPairings, as owner or collaborator - including the ones you make later. Finished more than 14 days ago, archived or handed off: left out. The list shows it as *All your tournaments on* the host, with the count.

Owners and arbiters of the hall can do this. To stop it, withdraw it in OpenPairings (your account page, Live boards) or remove it here. One account holds at most 8 copies of Alnasl. A desktop copy's hall-network listener does not offer this: there the single codes still do the job.

### What the bar says {#statuses}

The bar names what it is about. "OpenPairings: connected" is the code you pasted; "Results site: ..." is the tournament's results page. "No relay key yet" means OpenPairings has not saved a relay key for the tournament: in OpenPairings, Settings, Live boards, The results site. Alnasl starts sending by itself a few seconds after the key is saved. "Live" and the number beside it is this browser's connection to the box, not to the internet.

### A board that plays nowhere {#unlinked}

The line under the bar, the Boards page, the Live page and "Ready for round N?" all say "Board 1 is not playing in ...", with a button to put it there. If a game is under way on it, the button offers "these moves are board N of round R" (the moves stay, under the pairing's names, and are sent in full) or "start fresh" (the game is closed without a result and kept where it was). A board connected later joins the only linked tournament by itself, as long as the box's own has not been used.

### What goes back to OpenPairings {#goes-back}

Per game: the moves, the clocks, the PGN, and the result the board saw, with how many moves Alnasl reconstructed or guessed. It is shown beside the pairing there, in red when it differs from the result the arbiter entered. A board never enters a result.

### Two codes for one tournament {#two-codes}

Two codes that reach one tournament, a group's and the tournament's own, or a desktop copy's code for this computer and for the hall's network, make one tournament in Alnasl, not two. The second code says "This code reaches ..., which Alnasl already has through ...". When the old code was withdrawn and a new one made, press "Use this code" under the new one: the tournament keeps its boards and games, and the old code goes when it reaches nothing else. When the new code is another hall's and the tournament is not played there yet, the same place offers "Also play it in this hall": still one tournament, now in both halls (see [Tournaments and halls](06-accounts-and-halls.md#placements)).

### A desktop copy of OpenPairings {#desktop}

With a desktop copy of OpenPairings on the same computer, the code begins with `http://127.0.0.1` and everything works with no internet at all. Such a code does not work from a box elsewhere in the hall: the desktop copy answers only on its own computer.

### Without OpenPairings {#without-openpairings}

Alnasl still works. Type the results page in on Setup, Results and Lichess (the results site's address, the tournament and the relay key), and say who plays on each board's page ("Players") or attach a PGN that says it. Alnasl does not read pairings from the results site.

## The results site {#results-site}

OpenResults is where spectators follow the games. To see what they see: on the Live page, "Open the results site" opens the live boards of the round in a new tab, "Share" shows a QR code of the tournament's live page to hold up in the hall, and each tile has a "Live page" link to its board. A board's page has "This game on the results site". A tournament that is not on a results site has no link, and says so.

> [!NOTE] The public page may be behind on purpose
> The results site can hold live boards back by a delay that its admin sets, so a move made a minute ago may not be there yet. That is not a fault, and nothing is missing.

A game is only shown for a board of a published round. If the results site shows nothing, see [Recording, replay and troubleshooting](07-recording-and-troubleshooting.md).

## Broadcasting on Lichess {#lichess}

Two ways, and they can run side by side. Either way, first make a broadcast on Lichess (lichess.org/broadcast/new) and a round in it.

### Push: Alnasl sends the games to Lichess {#lichess-push}

1. On Lichess, leave the round's source empty: the games will be pushed. Copy the link to the round.
2. On Lichess, make a personal access token (lichess.org/account/oauth/token) with the permission to create and update studies and broadcasts. It is shown once: copy it.
3. In Alnasl, Setup, Results and Lichess, "Lichess broadcast": paste the link and the token, say which round of the tournament it is, tick "Send the games", Save. "Test" asks Lichess whether the token and the round are right, and says in words what is not.
4. From then on every move, correction and result goes to Lichess within a couple of seconds, with the clocks. The Results page shows Lichess as a destination of its own.

It needs internet where Alnasl runs. A new round on Lichess is a new round id: change it in Setup, Results and Lichess, when the round changes.

### Pull: Lichess fetches the games from the results site {#lichess-pull}

The results site serves each round as one PGN at `https://<results site>/t/<tournament>/live/<round>/pgn`. Give that address to Lichess as the round's source and Lichess reads it every few seconds. Alnasl needs no Lichess token for this; it only has to reach the results site. Spectators on Lichess then see what the results site shows, including its delay.
