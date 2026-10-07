# Categories, norms and the Advanced tools

## Categories

Categories divide a tournament's players into groups for prizes, for separate
standings and, optionally, for separate pairing (rating groups such as U1800,
age groups such as 65+, women).

Settings, **Categories**:

- **New category name** (for example `U1800` or `65+`) adds a category.
- Each category may have a **rule**, any combination of five conditions:
  *rating from*, *rating below*, *age from*, *under age* and *women only*. A
  category with no rule is **hand-assigned**. Nested, banded and combined
  categories can all be written this way. Age is counted by the FIDE
  convention, as of 1 January of the year: the editor shows the birth year
  that a limit means ("under 16 = born 2010 or later").
- The button that assigns categories fills each category from its rule and
  says how many of the players it assigned, or that nobody needs changing.
- A player can be in several categories. On the Players page the category
  cell (right-click or <kbd>Space</kbd>) assigns categories one at a time, and the
  header of that column assigns everybody.
- **Prizes**: an optional number of prizes per category. The standings of that
  category mark the places that win a prize. This is informational; the program
  does not allocate prizes or apply a "one prize per player" rule.

Two switches on the page:

- **Rank each category separately**: the Standings page gets a filter and each
  category has its own ranking.
- **Pair each category independently (beta)**: each category is paired by its
  own engine run and the results are merged into one round with continuous board
  numbers and a single pairing sheet. In a round robin each category gets its own
  Berger table. It is locked after round 1.

> [!FIDE] Departure from FIDE mode
> Pairing each category independently treats each category as a
> separate tournament, which is a departure from FIDE mode
> ([FIDE mode](02-fide-mode.md)).

![The Categories settings page with category rules, prizes and the two switches](screenshots/13-categories-settings.png "Category rules and switches")

## Norms and FIDE forms

**Advanced**, **Norms** produces the official FIDE forms as Excel files, filled
in from the tournament:

| Form | Purpose |
| --- | --- |
| **IT3** | the tournament report; always available |
| **FA1 / IA1** | the report for an arbiter norm (FIDE Arbiter / International Arbiter) for one candidate |
| **IT4** | the title norm report for the players who claim a title norm (up to 40) |

The page first shows the **FIDE settings** and **Officials & FIDE report
data**: chief arbiter, organiser, person responsible for the pairings, IT4 event
type, link to the pairings web page, deputy arbiters and extra arbiters with
e-mail addresses, and special remarks for the IT3. A banner says *Not ready to
submit to FIDE* while something required is missing.

- For **FA1/IA1**, *Pick an arbiter* takes the candidate from the event's
  officials, or type the name, FIDE ID and federation of any arbiter; nothing is
  stored.
- For **IT4**, a player is included once a claimed title has been set for them
  (*Edit norm data*: the title claimed, the norm description, medal percent,
  group, participating federations, remarks).
- A **combined report** (festival) joins several of your tournaments into one
  report: choose the other tournaments, one of them as *master tournament*
  (it supplies the header, schedule and name) and download the combined IT3,
  FA1 or IA1. Duplicate players across tournaments are detected.

The forms use the FIDE house style for names (given name, SURNAME in capitals).

![The Norms page with the IT3, FA1/IA1 and IT4 forms and the Not ready to submit to FIDE banner](screenshots/13-norms-forms.png "Advanced, Norms")

### Norms without an account

The **Tools** tab in the top bar opens a public page for arbiters who have no
account: upload `.swar` or `.trf` files (up to ten, 5 MB each), fill in the
officials, and download the IT3, FA1 and IA1 forms, combined across the files.
Nothing is stored: the files live in memory only while you work.

## History (restore points)

**Advanced**, **History**. A restore point is a full copy of the tournament at
one moment. The program takes one automatically before an action that is hard
to undo (pairing or unpairing a round, importing results from a file, a forfeit
or score of a match, a changed line-up, a withdrawn team, a hand-off); the newest fifty are kept. Press **Save
restore point** (with an optional name, for example *End of day 1*) to take one
yourself.

**Go back to this point** restores the tournament to that moment.

> [!WARNING] Overwrites live results
> Every result, pairing and player change made after the
> point goes away, and you must type `RESTORE` to confirm. The page lists
> any game that was already sent to the rating office and would not be in the
> restored state, and needs a tick to restore anyway. Restoring changes the
> contents only: not the owner, not whether the tournament is archived, not what
> is published.

## Audit trail

**Advanced**, **Audit trail**. Every action that changes anything is recorded:
who, when, what, with the old and the new value for a settings change. The
rows can be filtered (players, pairings, settings, standings, imports,
collaborators, the tournament). The audit trail travels with a hand-off.

## Pairing rationale

**Advanced**, **Pairing rationale** is the explanation of a paired round
([Pairing a round](06-pairing.md)).

## Badges

**Advanced**, **Badges** opens the accreditation badge editor for this
tournament ([Printing](09-printing.md)).
