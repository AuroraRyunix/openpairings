# Following games, corrections and rounds

What to watch during a round, what the tiles are telling you, how to repair a board that went wrong, and how rounds start and finish. Keep the Live page open and most of this takes care of itself.

## The Live page {#the-round-page}

Live is the front page. It shows the hall you are in (the hall picker at the top of the rail says which): the tournaments placed in this hall, and of those only the boards of this hall and the games played here. A tournament played in two halls, boards 1-8 here and 9-16 in the annex, shows boards 1-8 here and 9-16 there. With more than one tournament here, a row of names at the top shows one alone; with one, there is no row.

A tile per board: the players, the position Alnasl is sure of, the clocks, the last move, and the state as a shape and a word. Colour never carries the meaning alone.

| State | What it means |
| --- | --- |
| Waiting for start | The round is set up, nothing has been played |
| Live | The game is being followed |
| Settling | A hand is over the board, or a move is half made. Nothing to do |
| Reconstructed | Moves were not seen one by one and were worked out from the position |
| Out of sync | The board does not match the game and nothing is being sent for it |
| No signal | The board does not answer. Check cable and power. The game is kept |
| Clock wrong way | Black's clock is running and White has not moved |
| Finished | A result has been set |

A banner across the top means the results site cannot be reached. Play goes on and nothing is lost; the Results page says how much is waiting and why.

### Tiles or a list {#live-views}

"Boards" and "List" at the top switch between the tiles and a list with one row per board: the board number, the players, the last move, the clocks and the state. The list is the one for a hall of forty boards. The choice is kept in this browser; a browser that has chosen nothing gets the list from 24 boards on. The board number in the list opens the board's page, as a tile does.

"Share" beside a tournament shows the QR code of its live page on the results site, to hold up in the hall; press Close (or Share again) to put it away.

A tile is the way to the board's own page. Under it: "Finish game" and "New game".

Only boards that exist here get a tile: a board of this hall seated on that board number, or a board that already has a stored game. Pairings without either are counted in one line under the heading ("26 pairings without a board here"). A tournament with no board here and no game at all is not drawn, and neither is one placed only in another hall; one line at the bottom says how many there are ("14 more tournaments are not on the boards here") and leads to Setup, Tournaments. With a single tournament nothing is hidden: every pairing gets a tile, board or no board, and a hall that has no pairings yet says so, and what to do about it. A tournament you open by its own address is always shown, counted the same way as above.

## A board's page {#a-board}

The position large, the move list, and the tools. The Left and Right arrow keys, the buttons under the board, or a tap on a move step back through the game; Home is the start, End or "Live" is the game as it is played. Moves that arrive while you look back are added to the list and do not move the board.

When board and game have parted ways, the page shows what the board reads beside what is certain. One case is named: the board stands in the starting position while the game already has moves. That is nearly always a new game set up on a board still linked to the old one; start a new game with "New game", or put the position back if the pieces were knocked over.

## Moves Alnasl worked out {#reconstructed}

When Alnasl did not see every move, it works them out from the position, so that the board keeps up. Each such move is marked in the list:

- **Reconstructed** (orange, a diamond): only one line of moves fits.
- **Guessed** (red, a question mark): several fitted and Alnasl took one.

The tile and the Boards list count them. Tap a guessed move, or "Check them" on the board's page, and Alnasl asks which move it was, one question at a time, each option on a small board, the likeliest first. "Keep it as it stands" is one tap. When no other line fits, it says so and offers to keep the moves, take them back, or go to where you type the right ones.

The results site and Lichess get these moves like any other, without the mark. A correction replaces the game there. The count of reconstructed and guessed moves travels with the game to OpenPairings, so the arbiter there can see how much of a game was read and how much was worked out.

## Alarms that say what they saw {#alarms}

Some alarms name what the board shows:

- "Black moved (Nc6), but it is White's turn" and "A move that is not legal: white bishop c1-g5": somebody moved out of turn, or made a move the rules do not allow. Alnasl adds nothing to the game for it and invents no moves to make it fit. Put the piece back and the alarm is gone.
- "A move is missing before this" takes you to where moves are typed, for when the board missed a move.
- "Clock not in starting position" or a clock running the wrong way: stop it, put it right, start it again. The alarm goes away by itself. The moves are still followed.
- "White knight not seen on f3" is a warning, not an alarm: a piece left its square (parked beside the board, or the sensor lost it) and the game went on, so Alnasl takes it to be standing there still. It goes away when the piece is seen there again, moves, or is taken. If the piece was in fact captured, correct the moves on the board's page.
- "read as d3" beside a move means the board read that move one square off (a piece set down between two squares) and a later move showed where it really went - or somebody straightened the piece, which the board can read as a move of its own; with a clock, a press that belongs to no move gives that away. Alnasl has put it right and says so above the moves; "Check it" has the move as it was read.

## Repairing a board {#repairing}

On the board's page.

- **The board is right - resync from here.** Searches deeper and longer for the moves that were missed, and says which it added. If several lines fit, one is taken and marked as a guess for you to check. Moves you have just taken back with Undo are not put back by it.
- **Type the moves** from the scoresheet, like `Nf3 Nc6 Bb5`.
- **Undo last move** and **Change a move.** The spectators' copy is corrected too.
- **Start from a position**, for a resumed game, or when nothing else helps.
- **Pause sending.** The board is followed but nothing goes out until you resume.

Everything you do here is written in the Log with the time.

> [!TIP] Blitz and bullet
> Setup, Advanced, has "Bullet / fast play" for games of a few minutes or less: a move has to stand for a shorter time, and a board put back is not read as a takeback. Alnasl works out up to two moves it did not see; beyond that the board goes "Out of sync" and "Resync from here" searches deeper.

## Finishing a game {#finishing}

Set the result on every board, or confirm the suggestion: "Finish game" on the board's page, or under its tile on the Live page. There are three results, or "No result" for a game that was abandoned.

### Another game on the same board {#new-game}

"New game on this board". The game before it is kept and listed with its PGN. One game of a board goes to the results site, Lichess and OpenPairings:

- Where a pairing names the board and its game has **no result** (abandoned, a false start, "No result"), the new game is that one: it replaces the old game on all three, and the old one stays in Alnasl.
- Where the game **has a result**, the new game is an extra one that stays in Alnasl, so a finished game is never overwritten. "It replaces the game of the pairing" is there for when you mean it. A game that stays in Alnasl says so on its tile, on its page and on the Results page, with "Send this one instead".
- On a board no pairing names, setting up the pieces again starts the next game by itself. Setup, This box (This server), can make that always, or never.

A game that was not captured at all: Games page, read the scoresheet's moves, and "Attach" it to its board.

## Rounds {#rounds}

With OpenPairings, a round starts by itself a few seconds after the arbiter pairs it there: that tournament's boards show the new round with names, ratings and colours. The boards of the other tournaments are not touched. "Start round N" on the Live page stays for when there is no connection, and a tournament can be told not to start rounds by itself (Setup, Tournaments, open the tournament).

Without OpenPairings, "Start round N" moves the tournament's boards on to the next round.

### When a pairing changes {#pairing-changed}

If the arbiter changes a pairing in OpenPairings after the round began:

- A board where nothing was played simply takes the new pairing.
- A game that has moves is kept as it is, and its tile says "Pairing changed". Open the board and choose: **These moves are that game** when the players are the ones in the new pairing (a colour switch, a corrected name), or **Set it aside, begin again** when the game on the board is nobody's any more. It is kept in Alnasl with its PGN, and the board begins again.
- A game that only got another board number moves there by itself.

## Team events {#team-events}

A team event reads as matches on the Live page: "Match 3: Team A - Team B", the match's boards under it in board order, each tile naming the team of each player and its place in the match. Beside the match is its score as the boards saw it finish. Only that: the score that counts is the one the arbiter enters in OpenPairings.

"Keep each match together" (on by default) counts a tournament's tables match by match, so a match sits side by side and numbering by touching goes match by match. The PGN of a team game carries WhiteTeam and BlackTeam, and Round as round and board ("3.6").
