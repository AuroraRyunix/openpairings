# Boards and ports

Everything about getting the boards recognised: plugging them in, putting several on one cable, and telling twelve identical boards apart. All of it is on the Boards page.

## What the Boards page shows {#the-boards-page}

One row per board: its live picture, the signal, its serial number and firmware, the start-position check, its table number and its board of the round. At the top: "Ready for round N?", the address and QR code for a phone, and a sheet of printable labels. A board that is not plugged in keeps its row and says "No signal" and why.

## Adding a board {#adding-a-board}

Boards, "Add a board": choose the port the board is plugged into and press Add. Electronic boards, in their RS232 and USB-C models, come down to a serial stream, so one driver serves both. An electronic board on USB is a port called `COM3` or similar on Windows, `/dev/ttyUSB0` or `/dev/ttyACM0` on Linux, `/dev/cu.usbserial-...` or `/dev/cu.usbmodem...` on a Mac. On Linux the user running Alnasl must be in the `dialout` group; the installed service is set up that way. A Mac lists every adapter twice, as `tty.` and `cu.`; Alnasl offers only the `cu.` one.

> [!WARNING] One program per port
> A port can be read by one program at a time. Close the board maker's own software before you add the board here, or the box will not get an answer.

The USB adapter of an RS232 board may need its maker's driver before it shows up on a Mac or Windows PC (FTDI works as it is; Prolific, CH340 and CP210x may not).

A simulator board is on the same list. It plays a game by itself and is there for practising: add one, and the Live page has something to show.

## Several boards on one cable {#loop}

Electronic boards can be chained on one serial cable, as in the board maker's own software. For the box that is one port. Boards, Add a board: choose the port and press Add. The box asks the port who is on it, which takes a few seconds, and every board that answers gets a row of its own. There is nothing to type and nothing to choose: one board is read as one board, two or more as a loop. A loop holds up to twelve boards.

A board plugged into the chain later gets its row by itself within some ten seconds, and the Log says so. A board taken off the chain keeps its row, which says "No signal" and why; it is back when the board is. If a board in the middle of the chain says "No signal" and the others do not, its cable in the chain is out, or it has no power. The boards before it go on.

The older boards say their serial number on a loop and are known by it, like any board. The newer ones (firmware 4) do not: such a board is shown by the number it answers to on the loop, in small print, and keeps its table number under that. Plug it into a port of its own once and the box knows its serial number from then on, on a loop too.

If a port was added while one board was on it, and several are on it now, the row says "More than one board answers on this port: it is a loop". Press "Read it as a loop": each board gets its own row.

> [!NOTE] What has been checked on real boards
> Finding the boards, who they are, and what stands on each, with two boards on one cable. Not yet seen on a real loop: a move as it is played, a clock, and more than two boards. The box reads the whole board every few seconds as well, so on a loop a move can be late but not wrong.

## Which board is which {#which-board-is-which}

Twelve boards look alike, and so do twelve cables. The box keeps three things apart.

- **Which board it is.** An electronic board tells the box its serial number (it is also on a label under the board). That is what the box knows it by, not the USB port. Unplug it, plug it in elsewhere, restart the box: it is still the same board and keeps its number. If it comes back on another port, add it on that port: the box recognises the serial and puts it back in its old place. A board the box has never seen is marked "New board" and asks for a number.
- **Its table number.** The sticker on the board: "this is table 7". You set it once for the hall and it stays. "Labels" on the Boards page prints a sheet of stickers with the table number and the serial.
- **Its board of the round.** Normally the same number as the table. For one round you can say otherwise in the column "Board of round N" ("table 7 plays board 3 today"), swap two boards, or put everything back. The next round starts from the table numbers again. On the Live page the board number is the big one; "table 7 · serial 06310" is the small print.

### Giving the table numbers {#giving-numbers}

Three ways:

- **Number by touching.** Press Start, then lift a piece on table 1's board, then on table 2's, and so on. Each board gets the next number the moment it feels the piece go. Undo takes the last one back, Skip leaves a number out, Stop ends it.
- **Number all in connection order.** One click, when the boards were connected in the order of the tables.
- **By hand.** Type the number in the column "Table".

### Which board is this? {#which-board-is-this}

Press "Which board is this?" on the Boards page and lift a piece on the board you mean: its row lights up for a few seconds. The other way round, "Show me" on a row tells you which serial to look for, and says whether the board you then touch is the right one. The box cannot make a board beep or blink; a touch is the signal.

## Numbering with your phone {#phone-numbering}

Walking along the tables with a phone in your hand is easier than going back and forth to the box.

1. Setup, Access, "Access from other machines": set a PIN, then let other machines in the hall open the site, and start Alnasl again. Do it before the hall fills up.
2. On the box, open Boards (or Setup, Access): "Open this site on your phone" shows the address and a QR code. Point the phone's camera at it and give the PIN. (On a box with accounts, the code signs you in instead; see [Accounts, halls and roles](06-accounts-and-halls.md).)
3. On the phone: Boards, "Number by touching", Start. The next table number fills the screen. Walk to that table and lift any piece; the phone flashes the number and the board's serial, buzzes (Android only) and beeps once "Sound off" has been tapped to "Sound on". A phone wants one tap per visit before it makes any sound, and an iPhone on silent plays none.
4. Undo, Skip and Stop are at the bottom of the screen. If the phone loses the network between two tables, nothing is lost: the run is kept on the box.

> [!WARNING] Never without the PIN
> Anybody on the hall's network who finds the address could renumber your boards.

Do this before the round, with the pieces set up and nobody at the boards. The run ends by itself when every board has a number, or after fifteen minutes without a touch.

## The start-position check {#start-position}

The column "Start position" compares what stands on the board with the starting position, and says in words what is different ("black queen and black king are swapped (d8, e8)"). With a clock it checks the clock as well: it must stand to the right of the board, White's display toward White, with the lever up on White's side. The cable does not reach anywhere else, and the box cannot be told otherwise. Turn the clock or tip the lever; the message goes away by itself.

"Ready for round N?" gathers all this per board. It says Ready, or lists what is wrong, board by board.

## Tables that play in no tournament {#unlinked-tables}

A board that plays in no linked tournament is never left silent: the line under the bar, the Boards page, the Live page and "Ready for round N?" all say "Board 1 is not playing in ...", with a button to put it there. How tournaments and tables go together is in [OpenPairings, OpenResults and Lichess](05-openpairings-and-openresults.md).
