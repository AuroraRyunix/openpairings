# OpenResults: the public results site

OpenResults is the read-only site where spectators follow a tournament: the
pairings, the results, the standings, a cross-table, a card for each player
and, in a hall, the screens on the walls. Nobody needs an account, and the
site computes nothing. It shows what the arbiter's computer sends, so the
arbiter decides what is public and when. This chapter describes what a
spectator sees and what the arbiter controls. How a tournament is sent from
OpenPairings is in [Publishing](14-publishing.md).

## What OpenResults is {#what-openresults-is}

OpenResults is a separate program from OpenPairings. The arbiter's computer
is the only writer. Standings arrive already computed, with the tie-breaks the
arbiter chose, and the site shows them as they are. If the arbiter set the
order by hand, the page says so. The site is meant to agree with the hall at
all times, and it never holds tournament state of its own.

Because the public pages are only read, a busy page cannot disturb a pairing
session, and a laptop in a hall with a bad connection can keep pairing. The
public copy catches up when the connection is back.

## How a tournament gets there {#how-a-tournament-gets-there}

Nothing reaches OpenResults until the arbiter switches publishing on for the
tournament, in OpenPairings. The arbiter connects the results site once, then
chooses **Off**, **Link only** or **Listed** for each tournament. See
[Connecting a results site](14-publishing.md#connecting-a-results-site) and
[Publishing a tournament](14-publishing.md#publishing-a-tournament).

Once a round is published it does not change on the site. The site keeps it
for a long time, so a page that has already been loaded stays quick.

## What spectators see {#what-spectators-see}

### The standings page {#the-standings-page}

The standings page is the front of a tournament. It shows the standings in the
order the arbiter chose, with the columns and tie-breaks the arbiter allowed.
A tie-break value can be opened to show the working behind it: the opponent of
each round and its value. Before round 1 the page shows the starting ranking
of the entered players instead of an empty table.

The table can be sorted by any column, and filtered by club, federation or
category, all in the browser. A club or federation filter is kept in the
address, so a link can be copied and shared. The page refreshes itself about
every 20 seconds without reloading the whole page.

The front page lists the tournaments on the site in three groups: live,
upcoming and finished. It can be searched.

### Rounds and pairings {#rounds-and-pairings}

Each published round has its own page, with the pairings and, when the arbiter
allows it, the results as they come in. A postponed game is marked as such.
How much of a round is
public is set by the arbiter, round by round: see
[What the public sees, round by round](14-publishing.md#what-the-public-sees-round-by-round).

### The cross-table {#the-cross-table}

The cross-table has a row for each player and a column for each round. In a
team Swiss it also has a table with a row for each team. It appears only for
the rounds the public standings already reflect, so it never runs ahead of
them.

### Player cards {#player-cards}

Each player has a card. A name in a table is
a link to the card. A player who played in more than one tournament on the same
site has a history page too, found by their FIDE id, and it is linked from the
card when there is an id. Ratings, titles, federations and clubs appear on the
card only when the arbiter shows them.

### Teams {#teams}

A team tournament has a list of teams, a page for each team with its matches,
and a page for each round's team matches. Teams are shown by their full name.
When OpenPairings sends a team rating, the team list shows it in a *Rating*
column.

### The hall display and the projector view {#the-hall-display-and-the-projector-view}

For a television or projector in the playing hall there are two full-screen
pages, linked from the standings, cross-table and round pages.

The **hall display** cycles through a page at a time: the pairings of the
newest round, a *Find your board* list of every player in alphabetical order,
the results as they arrive, the standings, and the arbiter's announcement. A
view with nothing to show is skipped. While a new round has no result yet, the
screen holds on the pairings, the name list and the announcement. The views,
the seconds per page, the number of standings rows and the announcement are
set in OpenPairings, see [The hall display](14-publishing.md#the-hall-display).

The **projector view** shows only the pairings of the newest round, in large
type. It follows a newly published round and the results as they arrive,
without reloading.

Both screens have a Full screen button (or the <kbd>F</kbd> key) and three
colour choices: Black, the default; White; and Ultra contrast, pure black and
white with bold lines. The choice is remembered in that browser. The address
can set the colour and the views for a screen that has no picker, for example
`?theme=white` or `?views=names,pairings`.

> [!NOTE] Never more than the public pages
> The hall screens follow the same rules as the public pages. No pairings
> appear while the arbiter withholds them, and no result from a round whose
> results are not public.

### Languages and themes {#languages-and-themes}

The pages are in English, Dutch and French. A language picker is on the
pages, and the address can set it too, for example `?lang=nl`. The choice is
in the address, so a link keeps its language. The pages also have a theme
picker, and the choice is remembered in the browser. When printed, the rounds
and the cross-table are black on white whatever theme is chosen.

### Printing, feeds and embedding {#printing-feeds-and-embedding}

Any page can be printed from the browser. Each tournament has an Atom feed,
with an entry each time a round's pairings, its results or its standings
become public, so a feed reader shows each one once.

A page can also be put into another site with `?embed=1`. The site's own
header and footer are left out, and one link back to the full page stays.
Which sites may show the pages is set by whoever runs the results site.

### Reporting a page {#reporting-a-page}

Every tournament page has a **Report this page** link. A report has a reason
(wrong or fake results, personal data, spam or offensive content, or other), up
to 2000 characters of detail, and an optional contact email. A visitor can
send five reports every ten minutes. A report stays on record when its
tournament is taken down.

## What the arbiter controls {#what-the-arbiter-controls}

Everything a spectator sees comes from the arbiter's computer, so the arbiter
controls it from OpenPairings. The site cannot show more than was sent.

| What | Where in OpenPairings |
| --- | --- |
| Whether a tournament is published, and listed or not | [Publishing a tournament](14-publishing.md#publishing-a-tournament) |
| Which rounds are public, and how far (pairings, results, standings) | [What the public sees, round by round](14-publishing.md#what-the-public-sees-round-by-round) |
| Automatic publishing, and its delay | [Automatic publishing](14-publishing.md#automatic-publishing) |
| Ratings, titles, federations, clubs, categories, player cards and the tie-break columns | [What the public page shows](14-publishing.md#what-the-public-page-shows) |
| The starting ranking before round 1 | [What the public page shows](14-publishing.md#what-the-public-page-shows) |
| The hall screens: views, seconds per page, announcement | [The hall display](14-publishing.md#the-hall-display) |
| Entries for the tournament | [Entries through the results site](14-publishing.md#entries-through-the-results-site) |
| Moving to a new address, or taking the tournament off the site | [The address](14-publishing.md#the-address) |

Three things follow from how the site is built:

- **A hidden column keeps its order.** Hiding a tie-break column does not change
  the order it decides. When the order used a hidden tie-break, the page says
  so.
- **A withheld round is absent.** A round the arbiter has not published, or a
  result it has withheld, is not sent to the site at all. It is not filtered
  out on the page.
- **A hand-set order is labelled.** If the arbiter set the order by hand, the
  standings say that.

## Entries {#entries}

The results site can take entries for a tournament. An entry goes into a queue
on the site. It does not enter the tournament by itself: the arbiter pulls the
queue in OpenPairings and decides who is in. Entries are accepted only for a
tournament that has already been published, and the form stops accepting them
when the arbiter closes it or the maximum is reached. The arbiter's settings
are in [Entries through the results site](14-publishing.md#entries-through-the-results-site).

## Privacy and limits {#privacy-and-limits}

- **The reading pages set no cookies.** No account, no session and no consent
  banner are needed. A language chosen in the address travels in the address. A
  colour or theme chosen on a page is remembered in the browser.
- **Names, board numbers, results and places are always shown.** A tournament
  that must not show them should not be published. See
  [Link only is not privacy](14-publishing.md#publishing-a-tournament).
- **Personal data is kept for a limited time.** The periods are on the site's
  terms page. By default, entries are kept until 30 days after the tournament
  ends, a report's contact email for 90 days after the report is resolved, and
  a reporter's address for 30 days.
- **A page can lag a little.** A published round is not changed, and the
  standings page refreshes about every 20 seconds, so a result may take a moment
  to appear.
- **A site that is down does not stop the hall.** Pairing and entering results
  go on in OpenPairings whether or not the site answers.
