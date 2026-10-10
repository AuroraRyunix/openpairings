# Publishing: the results site and the live page

A tournament can be published to **OpenResults**, a separate read-only
results site. The public sees the pairings, the results and the standings,
and a card for each player, on their own phones, without an account.
OpenPairings serves no public pages itself: the arbiter's computer is the
source of the data and sends it to the results site, and a busy public page
cannot disturb a pairing session.

Publishing is optional and off by default. Nothing is sent until you switch it
on for a tournament.

![The OpenResults settings page with the On the results site choice, Spectators see and Automatically](screenshots/14-openresults-settings.png "Settings, OpenResults")

## Connecting a results site

**Connections** (top bar on the Tournaments page), section *Public results
site (OpenResults)*. Enter the **Address** of the results site (and, where a
token is needed, the **Token**; it is never shown again once saved), then press
**Test connection**. **Register again** and **Try again** appear when a
connection has failed. The page says whether the results site answered. A desktop copy can
register itself with the results site; if that failed, **Register again**
tries again. Until an address is set, the switch for a tournament does nothing.

## Publishing a tournament

Settings, **OpenResults**.

**On the results site:** three choices.

| Choice | Meaning |
| --- | --- |
| Off | nothing is sent. Going down to Off asks first; a copy that is already on the site stays until you remove it (see *The address*). |
| Link only | published, but not listed: anyone with the address can follow it. |
| Listed | published and on the results site's front page. |

> [!WARNING] Link only is not privacy
> The address is long and cannot be guessed, but
> anyone who is sent it can pass it on.

### What the public sees, round by round

On the Pairings page, a control **Spectators see:** (also in the round's
right-click menu) sets how much of each round is public, in four cumulative
levels:

| Level | Public |
| --- | --- |
| Nothing | the round is not shown |
| Pairings | who plays whom |
| + Results | the results as they come in |
| + Standings | the standings after the round too |

A newly published round starts at *Pairings*: live results are a deliberate
choice. Going down asks first and names what disappears.

### Automatic publishing

Settings, OpenResults, **Automatically**, one setting for how far up the
ladder the program moves each round by itself:

- **By hand**: nothing moves by itself.
- **Pairings once paired**: the round's pairings go public when it is
  paired; an optional delay *Pairings go public after N minutes* (0: at once).
- **+ results live**: the results go public as they are entered.
- **+ standings when the round is finished**: the standings go public once
  the round and every round before it are finished.

The automation only ever moves a round up; you can always take a round down
by hand, and it stays where you put it.

**Before round 1, spectators see the starting ranking** (off by default).
Without it the public sees only the list of players once a round is public.

**Live boards** (off by default, and offered only while the tournament is
published). Switch it on when a relay in the hall is sending the moves of the
games to the results site: the published pages then carry a **Live boards**
link beside the rounds. The switch only puts the link there. It does not
start a relay and does not check that one is running, so with nothing sending
moves the link leads to boards that stay in the starting position. Switching
it on or off sends the tournament to the results site again. See
[Turning live boards on](17-live-boards.md#turning-live-boards-on).

### What the public page shows

Switches choose which details a published page may show (ratings, titles,
federations, clubs, categories, player cards, the standings page, the pairings
pages, the columns of the standings, and which tie-breaks), and, separately,
whether the working of the tie-breaks is published. A detail you hide is not sent to the results site at all. Hiding a
tie-break column does not change the order it decides, and the page says
when the order used a tie-break that is hidden. The tie-break working
answers a spectator's *why am I fourth* (the opponent of each round and its value).
The *Rounds-present* column is public only if you tick it.
*Federation flags* draws a small flag beside each federation code; it is on
unless you untick it, and shows nothing where *Federations* is off. A player
listed under FIDE itself (code FID) gets a white flag with the word FIDE; a
code that names no federation gets the code and no flag.

> [!WARNING]
> Names, board numbers, results and places are always shown: a tournament that
> must not show them should not be published.

### The hall display

A full-screen page for a television or projector in the playing hall, at an
address shown on the settings page once the tournament is published. The
**Hall display** card chooses what it cycles through (pairings, the *Find your
board* list by name, results, standings), seconds per page, how many
places of the standings to show, whether to hold on the pairings until the
first result of a new round is in, and an **Announcement** (plain text, up to 500
characters) shown on the screen. Saving sends it at once.

### The address

*Share link* is the public address (a QR code to it appears on the Live page).
**Move to a new address** takes the old copy down, makes a new address and
publishes again (use it if a link has leaked). **Remove from the results site**
takes the tournament off the site. When a tournament file or a backup
carries a publishing key, you are asked whether to *Take over publishing it* or
*Start fresh*.

### Teams

Team tournaments are published too, with team standings and matches.

> [!NOTE]
> What the results site shows is described on that site; this manual covers only
> the part in OpenPairings.

## Entries through the results site

**Entry form** on the OpenResults settings page lets players register on the
results site: switch on **Accepting entries**, set when it opens and closes, a
maximum number of players, and whether the list of entrants is shown on the
form. **Review entries** opens the page of entries, where you fetch new ones,
accept them as players or discard them
([Players and rating lists](04-players-and-ratings.md)).

## The Live page (projector view)

**Pairings** page, **More**, **Local view & phone QR** (the page
`/t/:id/live` of this program): the current round full-screen for a projector,
cycling through pairings, results and standings, with a pause button, a leave
button and a high-contrast option. It shows a QR code for the public address
if the tournament is published. It also holds the card **Enrol a phone to
enter results** ([Results](07-results.md)). The page updates itself whenever
a result changes. It is served by this program, so the screen must be on the
same computer or a computer that can reach it; the public page (above) is for
everybody else.

## If there is no network

> [!NOTE]
> Publishing never blocks pairing or result entry.

A change is sent a few seconds after you make it; the label in the top bar
says *Sending* meanwhile. When nothing has changed for spectators (a dialog
confirmed with nothing to do, a result typed and taken back at once), nothing
is sent, and the label stays as it was. **Try again**, switching publishing off
and on, and a restart of the program always send.

A send that does not arrive is
kept and tried again with longer pauses; the status of the connection is shown
as a small label in the top bar, and the page says what is wrong. The public
page catches up to the hall when the connection is back.
