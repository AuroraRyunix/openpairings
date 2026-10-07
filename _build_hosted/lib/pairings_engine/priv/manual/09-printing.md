# Printing

Every printable document opens in a new browser tab as an ordinary page that
starts the browser's print dialog.

> [!TIP]
> Because it is an ordinary page, you can also save it as a PDF from the print
> dialog. The tab can be closed without disturbing the program.

## Where to print from

The **Print** tab lists every document, with a short description and a
**Print…** button. A document that needs a paired round is greyed out until the
first round is paired. Several documents can also be reached from the page they
belong to: the Pairings page has a **Print** menu, the Players page has **Print
player list** and **Print place cards**, the Standings page has **Print**, the
postponed games list has the notices.

![The Print tab listing the documents of a tournament](screenshots/09-print-tab.png "The Print tab")

A tournament logo (Settings, Tournament, *Logo*) is printed on the
documents. Print documents of a tournament in which a postponed game is
still open, or a board has no result, carry a line saying that the figures are
not final.

## The documents of an individual tournament

| Document | What it is |
| --- | --- |
| **Player list** | All registered players: title, name, ratings, federation, club. |
| **Player cards** | One card per player with every round of the tournament listed, to fill in over the board. |
| **Pairing list** | The boards of a round, to post at the venue. The Pairings page also offers *Pairings, with absentees section*, which adds the players who are not playing, with the value of the round for each. A player with a fixed table is marked, for example `5 (table 5)`. |
| **Alphabetical pairing list** | "Where do I sit": the players sorted by name, to find your board. |
| **Standings** | The ranking with the points and the tie-breaks. |
| **Result cards** | One card per board of a round, eight to an A4 page, with the names, ratings, pairing numbers and the three results to circle, a line for another result, and signature boxes. Byes are skipped. |
| **Score sheets** | One pre-filled sheet per board: names, ratings, move columns and signatures. |
| **Cross table** | The full results grid. A Swiss or Keizer tournament gets one row per player in standing order and one column per round; each cell reads *opponent's pairing number, colour, result* (`12w1`: White against number 12, won). A round robin gets the classic players-by-players grid, with both cycles in a cell of a double round robin. |
| **Place cards** | One folded tent card per player on a full A4 page (see below). From the Players page. |
| **Postponed-game notices** | One slip per player of every open postponed game ([Entering results](07-results.md)). |
| **Next-round preview** | The boards that are fixed whatever the open results are, with a list by name for name cards ([Pairing a round](06-pairing.md)). |

### Which round

The pairing list, result cards and score sheets take a round: the Print page
uses the latest paired round, and the Pairings page prints the round you are
looking at. In the address of a print page `?round=N` selects a round. The
pairing list defaults to round 1 and the result cards to the latest paired
round if you leave it out. A round that is not paired gives the answer *Round N
has not been paired yet*, not another round. The standings print takes a
round in the same way (`?round=N`) and then shows the standings as they stood
after that round.

### Result cards: test print and stack cutting

- **Result cards: test print (first 3)** prints three cards, to check the
  alignment of your printer before you print a stack.
- **Result cards: stack-cut order** orders the cards so that after you
  print every page, stack the printout and cut it in eight strips with a
  guillotine, each pile is in board order. Slots that remain empty at the end are
  printed blank.

### Place cards

Each player gets a whole A4 page divided at the middle by a fold line. The
top half is printed upright and the bottom half the other way up, so that when
the sheet is folded with the print on the outside and stood up as a tent, it
reads correctly from both sides of the board. The address takes switches to
show or hide fields: `?title=`, `?rating=`, `?federation=`, `?club=`,
`?board=` (each accepts `0` to turn the field off). By default the card shows the
name, title, rating and the board of the latest paired round; federation and
club are off. The board line is left out if no round is paired.

## The documents of a team tournament

Team pairings (a table per match with the boards, colours, ratings and
result), team standings, **team cross table** (round robin: team by team with the
game points; Swiss: opponent, colour of board 1, match score and running match
points per round), **match result sheets** (one A4 page per match with both
line-ups, result boxes, the match score and signature lines for both
captains and the arbiter), **team rosters** and **board prizes** (per board
number, the players ranked by percentage, points and performance, with an
optional minimum number of games). See [Teams](12-teams.md).

## Accreditation badges

A6 badges, two to an A4 sheet, are made in a separate tool: **Advanced**,
**Badges**. A badge has a name, photo, title, federation, FIDE ID, a coloured
role banner, up to twelve numbered rooms, logos and a QR code. An event
linked to a tournament imports its players and officials; press, VIP and staff
badges are added by hand. See [Categories and norms](13-categories-and-norms.md)
for the other tools under Advanced.


## Printing the FIDE forms

The IT3, FA1, IA1 and IT4 forms are filled-in Excel files from **Advanced**,
**Norms**, not print pages ([Categories and norms](13-categories-and-norms.md)).
