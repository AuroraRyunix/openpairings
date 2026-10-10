# Players and rating lists

This chapter covers the rating lists the program keeps, adding and changing
players, the player grid, refreshing ratings, and late entries. Byes,
absences and withdrawals are in [Byes and absences](05-byes-and-absences.md).

## Rating lists

The program keeps a local copy of rating lists, so that players can be found
and their ratings filled in without internet access in the playing hall.

**The FIDE rating list.** About 1.9 million players: FIDE ID, name,
federation, title, birth year, and the standard, rapid and blitz ratings.
Open **Connections** (top bar on the Tournaments page), section *FIDE
database*, and press **Download rating list** the first time. **Update from
FIDE** downloads the current list again (FIDE publishes a new list every
month). The program records which month's list it holds. Once a day, while it
runs, it also asks FIDE whether a newer list exists and downloads it only
if there is one (about once a month); nothing happens while offline. This is on
by default and has a checkbox under Connections to switch it off. The page shows how many players the local database holds and when it
was last updated. On a desktop
build you are the administrator of your own installation. On a server only the
administrator may update it. A player who is not in the list has no FIDE
rating (about two thirds of the rows in the list are unrated players): that
means "no FIDE ID or no rating", not a failure of the download.

> [!NOTE]
> The download is large (about 40 MB) and replaces the whole local copy; it
> needs a connection to the FIDE rating site.

**The national rating list.** The Belgian list (KBSB/FRBE) is a built-in
national list. It is part of the *Belgian pack* of features that is switched
off for every account unless you turn it on: Account menu, **Features**. With
*National rating list sync* on, Connections shows the section *Belgian
national rating list*, where **Sync from KBSB** downloads the federation's
public monthly file (about 36,000 players: national ID, name, club, FIDE ID,
national rating). *KBSB player lookup* adds the list to the player search.
*Bulk club update* adds the **Update clubs** button on the Players page.
An arbiter outside Belgium never sees any of it. The sync only copies the
federation's file; it never writes ratings into your tournaments by itself.

**Other national lists** are not built in. For a player of any other
federation, type the national ID and national rating by hand, or load the
list yourself as a CSV file.

**Your own rating lists (CSV).** Connections has a link to **Rating lists**
(`/rating-lists`), where you load a list of your own, for instance a national
or club list. The first row of the CSV file names the columns: `id`, `name`
and `rating` are required; `federation`, `title`, `birth_year` and `fide_id`
are optional. The separator can be a comma, semicolon or tab, and a rating
that is empty or 0 means unrated. *Check the file* shows what was found;
*Load the list* stores it, and nothing is loaded unless every row is valid. A
list with the same name is replaced. Only an administrator loads lists on a
server. The lists are shared by every tournament on the machine, turn up when
a player is added, and can be put in a tournament's rating-list sequence.

**The rating-list sequence.** Settings, **FIDE**, section *Rating lists*, sets
the lists a player's rating is taken from when the player is added or the
ratings are refreshed, in order: FIDE Standard, FIDE Rapid, FIDE Blitz,
Effective Rapid (Rapid, else Standard), Effective Blitz, the national list,
and your own lists. Use the arrows to move a list, **Leave out** to drop one and
**Add to the sequence** to add one; **Back to the default sequence** restores
the sequence that fits the tournament's rate of play. The first list is the
*main list*: its rating is entered automatically. The ratings the player has
in the other lists are shown beside the search result, and a click on one
(*Use this rating instead*) picks it. A FIDE list fills the FIDE rating; the
national list and your own lists fill the national rating.

**Which rating is used.** The *Elo used* of a player is the **tournament
rating**, which the tournament's *Tournament rating* setting defines (Settings,
Options): the FIDE rating only, the national rating only, the FIDE rating
else the national (the default), the national else the FIDE, the highest of
FIDE, national and a rating typed by hand, or the typed rating alone (see
[Tournament set-up](03-tournament-setup.md)). It is the rating that the
program orders the players by when it assigns the pairing numbers, that the
rating-based tie-breaks read, and that it prints. A rating typed by hand is
the field *Tournament rating* on the player's form; only the last two methods
read it. The FIDE rating that is filled in is the one of the
tournament's format: standard for a standard tournament, rapid for a rapid
one, blitz for a blitz one (or the standard rating when the player has no
rapid or blitz rating yet).

**Ratings entered by hand.** Every rating field (FIDE rating, national
rating, tournament rating) can be typed or changed by hand on the player's
form; the program does not forbid a value because it differs from the list.
The form shows what the list says and asks whether to apply it when it
differs.

**Where a rating came from.** A rating read from a list keeps its source:
the player's form says, for example, that it is from the FIDE standard list
of a given month, that it was changed by hand (and what it was on the list),
or that it was entered by hand with no source list.

## The Players page

Top bar, **Players**. At the top: the number of registered players and the
buttons

- **Add player** (also <kbd>Ctrl</kbd>+<kbd>I</kbd>),
- **Refresh ratings**,
- **Update clubs** (only with the Belgian feature on),
- **Print player list** and **Print place cards**,
- **Enter results**, which leads to the Pairings page.

Below is the player grid: one row per player.

![The Players page with the player grid and the buttons above it](screenshots/04-players-grid.png "The Players page")

### Adding a player

Press **Add player**. The form first offers a search box:

- *Search the FIDE database (name or FIDE ID)*. With the Belgian lookup on,
  *Search the KBSB and FIDE lists (name, national ID or FIDE ID)*.
- Start typing a last name (`Lastname, Firstname`) or a number; choose the
  player from the results and the form is filled in: name, title, federation,
  FIDE ID, ratings, birth year and (Belgium) national ID and club.
- Or fill the details in by hand below the search box.

![The Add player form with the search box and the search results](screenshots/04-add-player-form.png "Adding a player")

The form fields: full name (required), title, FIDE rating, national ID,
national rating, federation, birth year, club, and further down the fixed
table, the extra points, category assignments, registration status (*No Paid*,
*Paid*, *Gratis*), *Joins in round*, and the presence settings
([Byes and absences](05-byes-and-absences.md)). A player with a FIDE ID that is
already in the tournament is refused. The registration form's **FIDE lookup** (and, with the Belgian pack, **KBSB lookup**)
looks the player up again in the local list. If the list says something
different from what is on file, the form shows what FIDE says and asks
*apply this?* for each difference.

Register the players before round 1 is paired. Their **pairing numbers**
(the starting ranks) are given when the first round is paired.

> [!FIDE] C.04.2 2
> The pairing numbers go to the highest tournament rating first, then FIDE
> title (GM, IM, WGM, FM, WIM, CM, WFM, WCM, no title), then the tournament's
> announced criterion (alphabetical by default; Settings, Options, *Equal
> rating and title*).

A player who
is added later gets, when the next round is paired, the number their rating
earns, with everybody below moving down one place (Swiss only), or the next
free number if the setting *Late entrants' pairing numbers* is *After the
field*.

**Changing the pairing numbers of a Swiss tournament.** The button **Pairing
numbers** on the Players page opens the list in pairing order. Two players with
the same rating can **exchange** their numbers (the *Exchange* button between their rows) (to order them by another rule),
and **Regenerate from ratings** renumbers everybody by the current ratings, keeping the
order you gave to players of equal rating; use it to follow a rating change or
to correct a mistake.

> [!FIDE] C.04.2
> Both are possible only until round 4 is paired.

Every change asks for your confirmation, a regeneration listing the
players whose number changes first. Rounds that were already paired used the
old numbers, so a pairing checker will no longer reproduce them; the dialog
says so. Each change is written to the audit trail. A regeneration when the
numbers already follow the ratings says so and changes nothing.

Until round 4 is paired, the Pairings page warns above *Pair round N* when the
numbers no longer follow the ratings - a rating corrected after round 1, a
late entrant numbered after the field, or numbers that came with an imported
file. It names each player with their rating, their number and the number
their rating earns, and **Regenerate from ratings…** opens this list. Players
of equal rating in any order are never reported: that is what an exchange is
for. Pressing *Pair round N* for rounds 2 to 4 then asks first
([Pairing a round](06-pairing.md), *When the pairing numbers do not follow the
ratings*).

**Starting numbers of a round robin.** Before round 1 the button **Starting
numbers** opens the list the Berger tables pair by. Enter the result of a
drawing of lots by hand (a number per player, or move a player up or down), or
press **Draw lots** (the program draws, after a confirmation), or **Order by
rating** to go back to the rating order. The numbers are used when round 1 is
paired and cannot be changed after it; a player entered later gets the next
number.

### The grid

The columns can be sorted by clicking the header. Abbreviated headers have a
tooltip in plain language. The **Display** panel chooses which columns are
shown, per user; the standard set has the pairing number, title, name, rating,
federation, club, games played, points and presence. Further columns include
the birth year, national and FIDE ID, both ratings, *Elo used*, the categories,
the registration status (Paid), fixed table, extra points and the rounds-present
column (*Rds*). The same columns can be shown on the Standings page.

Some cells open a small menu (right-click, or <kbd>Space</kbd> /
<kbd>Shift</kbd>+<kbd>F10</kbd> / the context-menu key on the keyboard): the presence cell sets a player present
or absent, the *Paid* cell sets the registration status, the category cell
assigns categories, and the header of the presence column sets everybody
present or absent at once. The arrow keys move between the cells; the cell
menu is announced to screen readers with a sentence that says what the letter
in the cell means.

**Presence cell.** What the letters in the cell mean:

| Cell | Meaning |
| --- | --- |
| `F` | forfeited / withdrawn |
| `A` | absent for the whole event |
| `A(3,5)` | sits out those rounds, and the round about to be paired is one of them (absent now) |
| `a(3,5)` | has sat out those rounds, but is available in the round about to be paired |

Double-click a player's name (or press <kbd>Enter</kbd> or <kbd>Space</kbd> on it) to open the
**Player registration** form. Right-click the name (or press the context-menu
key) to open the **Players Card**: the player's opponents, colours and results
round by round, with a print button and previous/next buttons.

### Removing a player

> [!WARNING]
> **Remove** deletes a player. A player who has already played cannot be
> deleted in FIDE mode if the deletion would change a round that is no longer
> open; such a player is withdrawn instead (forfeit).

## Refreshing ratings

**Refresh ratings** looks every player up in the local FIDE list (by FIDE ID)
and shows a table of what would change: the player, the field, the old and the
new value, with a line such as *12 checked, 5 changes, 3 without id match*.
Only the **FIDE rating** and the **title** are proposed, and a title is only
proposed when FIDE's list actually carries one. A player without a FIDE ID is
not touched. Nothing is written until you press **Apply**; **Cancel** writes
nothing. It is an all-or-nothing action, and it is a manual action: the
program never writes ratings on its own.

**The check by itself.** While the Players or Pairings page is open (and after a
finished update of the list), the program compares the ratings and titles on
file with the FIDE list that was valid in the month the tournament started and, when
they differ, shows a notice: *The FIDE list (month) gives a different rating
or title for N players*, with a **Review** button that opens the same table. It
writes nothing. The month of the list must match the tournament's start month,
otherwise the program proposes nothing and says why (only the current list
is kept). The notice can be switched off per tournament (Settings, **FIDE**,
*Consistency checks*); the **Refresh ratings** button still works on request.
Before a requested check, the program asks FIDE whether its list on this
machine is current and updates it first, or says that it could not.

In the table of proposed changes each line has a tick, and there is **Select
all**: **Apply selected** writes only the ticked ones.

**Update clubs** (Belgian pack) works the same way for the club and the club
number, matching by national ID, then FIDE ID. It never blanks a club.

> [!TIP]
> Refresh the ratings before round 1 is paired. Changing a rating afterwards
> does not change the pairing numbers already given.

## Late entries

A player added after rounds have been paired can be given a round in which
they join (**Joins in round** on the form; the next round to be paired is
offered). In a Swiss tournament their pairing number follows the setting
*Late entrants' pairing numbers* (by rating, or after the field). A tournament
that still numbers them after the field because it is older than the default
says so once, on the Pairings page and on the Options page, and offers to
switch ([Tournament set-up](03-tournament-setup.md)). The form says what the rounds before it count as. When absences
score points (Scoring page), the rounds before the entry count as absences
as set on the Scoring page. In a Swiss tournament the new player is paired in
the round they join, with the others. In a round robin a player who is added
after round 1 is paired is not part of the schedule: the Berger table is fixed
once it exists.

## Entries from the results site

When a tournament is published (see [Publishing](14-publishing.md)) and entries
are open, players can register themselves on the results site. The page
**Entries from the results site** lists them; **Fetch entries** checks for new
ones, and each entry is accepted (it becomes a player) or discarded. An
accepted entry can be put back.

> [!NOTE]
> The entry form itself is configured on the OpenResults settings page.

## Export of the player list

Settings, **Export**, *Export players (CSV)*: the columns you choose, in the
order you choose, with a separator (comma, semicolon, tab or pipe), ordered
by starting rank or by name, optionally without absent players and with a
marker for Excel. See [Import and export](10-import-export.md).
