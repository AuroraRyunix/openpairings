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
  Berger table. It is locked after round 1. A category with a single player
  gives that player the pairing-allocated bye; once they have had it (or a win
  without playing), the round has no legal pairing and is refused, with the
  offer to pair it by hand.

> [!FIDE] Departure from FIDE mode
> Pairing each category independently treats each category as a
> separate tournament, which is a departure from FIDE mode
> ([FIDE mode](02-fide-mode.md)).

![The Categories settings page with category rules, prizes and the two switches](screenshots/11-categories-settings.png "Category rules and switches")

## Norms and FIDE forms

**Advanced**, **Norms** produces the official FIDE forms as Excel files, filled
in from the tournament:

| Form | Purpose |
| --- | --- |
| **IT3** | the tournament report; always available |
| **FA1 / IA1** | the report for an arbiter norm (FIDE Arbiter / International Arbiter) for one candidate |
| **IT4** | the title norm report for the players who claim a title norm (up to 40) |

The forms are filled in from the officials and arbiters under Settings,
**Officials & norms**, the identifiers under Settings, **FIDE**, and the player
list ([Tournament set-up](03-tournament-setup.md)). A banner says *Not ready to
submit to FIDE* while something required is missing, and names it.

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

![The Norms page with the IT3, FA1/IA1 and IT4 forms and the Not ready to submit to FIDE banner](screenshots/11-norms-forms.png "Advanced, Norms")

The page also judges, per player, whether the event amounts to a title norm
(FIDE B.01). One rule concerns round robins only: games against an **unrated
player who scored zero** are not norm games (B.01 1.4.2). "Scored zero" is
read as the points from games actually played: a point for a bye or for a
win by forfeit is not a score, so an unrated player with only such points is
still left out, and one draw over the board is enough for their games to
count. The games stay in the standings and in the rating report; only the
norm calculation leaves them out.

The judgment uses the *event type for title norms* set under Settings,
**Officials & norms**, which can lower the number of games (B.01 1.4.1 b) or
lift the federation mix (1.4.3 a-c), and checks by itself whether the event is
a big open Swiss (1.4.3 d), which lifts the federation mix for everyone. An
exempted check passes and says which article lifted it. The table under the
heading names the event type the players were judged as.

### Norms without an account

The **Tools** tab in the top bar opens a public page for arbiters who have no
account: upload `.swar` or `.trf` files (up to ten, 5 MB each), fill in the
officials, and download the IT3, FA1 and IA1 forms, combined across the files.
Nothing is stored: the files live in memory only while you work.

## History (restore points)

**Advanced**, **History**. A restore point is a full copy of the tournament at
one moment. The program takes one automatically before an action that is hard
to undo (pairing or unpairing a round, importing results from a file, a forfeit
or score of a match, a changed line-up, a withdrawn team, a hand-off) and
before a bulk change that rewrites many players with one click (giving
everyone a category, **Assign categories**, re-seeding the pairing numbers or the
starting numbers, **Refresh ratings** and the player-data refresh, applying the
extra-points bands, re-seeding the manual ranking, ordering teams by rating).
Each is labelled with what is about to happen, for example *Before assigning
categories to 24 players*. The newest fifty automatic points are kept; the
older ones are pruned. Press **Save restore point** (with an optional name, for
example *End of day 1*) to take one yourself: those are never pruned and do not
count towards the fifty.

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
