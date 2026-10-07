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
month). The page shows how many players the local database holds and when it
was last updated. The download is large (about 40 MB) and replaces the whole
local copy; it needs a connection to the FIDE rating site. On a desktop
build you are the administrator of your own installation. On a server only the
administrator may update it. A player who is not in the list has no FIDE
rating (about two thirds of the rows in the list are unrated players): that
means "no FIDE ID or no rating", not a failure of the download.

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
federation, type the national ID and national rating by hand.

**Which rating is used.** The *Elo used* of a player is the FIDE rating
when they have one, otherwise the national rating. This is the rating that the
program orders the players by when it assigns the pairing numbers, and the
rating it prints. The FIDE rating that is filled in is the one of the
tournament's format: standard for a standard tournament, rapid for a rapid
one, blitz for a blitz one (or the standard rating when the player has no
rapid or blitz rating yet).

**Ratings entered by hand.** Every rating field (FIDE rating, national
rating) can be typed or changed by hand on the player's form; the program does
not forbid a value because it differs from the list. The form shows what the list says
and asks whether to apply it when it differs.

## The Players page

Top bar, **Players**. At the top: the number of registered players and the
buttons

- **Add player** (also `Ctrl+I`),
- **Refresh ratings**,
- **Update clubs** (only with the Belgian feature on),
- **Print player list** and **Print place cards**,
- **Enter results**, which leads to the Pairings page.

Below is the player grid: one row per player.

### Adding a player

Press **Add player**. The form first offers a search box:

- *Search the FIDE database (name or FIDE ID)*. With the Belgian lookup on,
  *Search the KBSB and FIDE lists (name, national ID or FIDE ID)*.
- Start typing a last name (`Lastname, Firstname`) or a number; choose the
  player from the results and the form is filled in: name, title, federation,
  FIDE ID, ratings, birth year and (Belgium) national ID and club.
- Or fill the details in by hand below the search box.

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
(the starting ranks) are given when the first round is paired: highest rating
first, then by name (FIDE C.04.2.B). From then on a player's number does not
change; a player who is added later gets the next free number when the next
round is paired.

### The grid

The columns can be sorted by clicking the header. Abbreviated headers have a
tooltip in plain language. The **Display** panel chooses which columns are
shown, per user; the standard set has the pairing number, title, name, rating,
federation, club, games played, points and presence. Further columns include
the birth year, national and FIDE ID, both ratings, *Elo used*, the categories,
the registration status (Paid), fixed table, extra points and the rounds-present
column (*Rds*). The same columns can be shown on the Standings page.

Some cells open a small menu (right-click, or `Space` / `Shift+F10` /
the context-menu key on the keyboard): the presence cell sets a player present
or absent, the *Paid* cell sets the registration status, the category cell
assigns categories, and the header of the presence column sets everybody
present or absent at once. The arrow keys move between the cells; the cell
menu is announced to screen readers with a sentence that says what the letter
in the cell means.

**Presence cell.** `F` = forfeited / withdrawn; `A` = absent for the whole
event; `A(3,5)` = sits out those rounds, and the round about to be paired is
one of them (absent now); `a(3,5)` = has sat out those rounds, but is
available in the round about to be paired.

Double-click a player's name (or press `Enter` or `Space` on it) to open the
**Player registration** form. Right-click the name (or press the context-menu
key) to open the **Players Card**: the player's opponents, colours and results
round by round, with a print button and previous/next buttons.

### Removing a player

**Remove** deletes a player. A player who has already played cannot be
deleted in FIDE mode if the deletion would change a round that is no longer
open; such a player is withdrawn instead (forfeit).

## Refreshing ratings

**Refresh ratings** looks every player up in the local FIDE list (by FIDE ID)
and shows a table of what would change: the player, the field, the old and the
new value, with a line such as *12 checked, 5 changes, 3 without id match*.
Only the **FIDE rating** and the **title** are proposed, and a title is only
proposed when FIDE's list actually carries one. A player without a FIDE ID is
not touched. Nothing is written until you press **Apply**; **Cancel** writes
nothing. It is an all-or-nothing action, and it is a manual action: the
program never refreshes ratings on its own.

**Update clubs** (Belgian pack) works the same way for the club and the club
number, matching by national ID, then FIDE ID. It never blanks a club.

Refresh the ratings before round 1 is paired. Changing a rating afterwards
does not change the pairing numbers already given.

## Late entries

A player added after rounds have been paired can be given a round in which
they join (**Joins in round** on the form; the next round to be paired is
offered). The form says what the rounds before it count as. When absences
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

*Brief chapter section: the entry form is configured on the OpenResults settings
page.*

## Export of the player list

Settings, **Export**, *Export players (CSV)*: the columns you choose, in the
order you choose, with a separator (comma, semicolon, tab or pipe), ordered
by starting rank or by name, optionally without absent players and with a
marker for Excel. See [Import and export](10-import-export.md).
