# Several categories per player

**Superseded in part by the condition-set category rules (2026-09-11).**
This document was written before `category_rules` had any shape at all -
every citation below still describes the legacy `"kind"`/`"value"` shape,
which no longer exists in a live tournament (see
`PairingsEngine.CategoryRules.migrate_legacy_rules/2` and the
`MigrateLegacyCategoryRules` data migration). The single-valued
pairing-pool problem this document diagnoses, and the "one pairing
category, many tags" split it proposes, are exactly what shipped and
still stand; the RULE part - "one threshold per category, tightest wins" -
is superseded by `PairingsEngine.CategoryRules`'s any-combination-of-five-
conditions model (rating from/below, age from/below, women), and by the
per-category prize counts on `tournament.category_prizes`. Read this for
the pairing-pool history, not for the current rule shape.

Design for the TODO.md item "Several categories per player, and sorting on
them - wanted 2026-09-08". Nothing here has been built; every claim about
current behaviour was checked against the source and carries a file and
line. Where a claim could not be established from the code it says so.

Working version at the time of writing: **0.51.0** (`mix.exs:7`).

## The shape of the problem

A player has exactly one category today -
`lib/pairings_engine/tournaments/player.ex:53`, `field :category, :string,
default: ""` - drawn from the tournament's own list,
`lib/pairings_engine/tournaments/tournament.ex:179`, `field :categories,
{:array, :string}, default: []`. Real events need more than one per player,
because each category is a prize list and the same player wins in several.

The obstacle is that a category is not only a label. It can decide pairing,
and that use is structurally single-valued.

## The constraint, verified

`pair_by_category` (`tournament.ex:472`) pairs each category as an
independent tournament. The partition is
`PairingsEngine.Pairing.category_groups/2`,
`lib/pairings_engine/pairing.ex:721-739`:

```elixir
named_groups =
  Enum.map(named_categories, fn cat_name ->
    {cat_name, Enum.filter(players, &(&1.category == cat_name))}
  end)

uncategorized =
  Enum.filter(players, fn p ->
    p.category in [nil, ""] or not MapSet.member?(named_set, p.category)
  end)
```

Each group then gets its own engine run (`compute_category_group/8`,
`pairing.ex:607-650`), its own pairing-allocated bye
(`compute_category_group/8`'s 1-player clause at `pairing.ex:594-605`), and
the groups are merged into ONE `Round` with board numbers running
continuously in `tournament.categories` order
(`insert_category_round/3`, `pairing.ex:660-719`).

A player appears in exactly one group by construction: `named_groups` uses
equality on a single string, and `uncategorized` is the complement. A
player carrying three categories cannot be paired in three pools - they
would get three opponents in one round.

So the concept splits, exactly as TODO.md says: **one single-valued pairing
category, and many tags for everything else.** The rest of this document is
about how.

### A discrepancy found while verifying this

`PairingsEngine.PairingRationale.category_for/2`
(`lib/pairings_engine/pairing_rationale.ex:485-489`) labels a board with the
player's raw `category` string with **no membership check** against
`tournament.categories`:

```elixir
defp category_for(%{pair_by_category: true}, %Player{category: c}) when c not in [nil, ""],
  do: c

defp category_for(%{pair_by_category: true}, _player), do: "Uncategorized"
```

`category_groups/2` (above) puts a player whose category is not in
`tournament.categories` into the **"Uncategorized"** pool. So a player with
`category = "Z"` where `"Z"` is not on the tournament's list is *paired* in
Uncategorized and *labelled* "Z" on the pairing-explanation page
(`pairing_explain_live.ex:2486-2487`). The label and the pool disagree.

This matters for the design because the fix falls out of it for free (see
"The pairing category" below), and because it means the upgrade changes one
label. That is a `[Fix]`, and it belongs in the CHANGELOG rather than
happening quietly.

## 1. The data model

### 1a. Per-tournament, or a property of the player?

TODO.md leaves this open and says it decides whether this is one table or
two. Both are designed below; the recommendation is **per-tournament**, and
the reason is not preference but that the alternative requires inventing
something this app does not have.

**Per-tournament (recommended).** Tags are names drawn from
`tournament.categories`, stored against the player row, meaningful only
inside that event. One table's worth of change (or none - see 1b).

**Per-player, outliving the event.** Requires a durable person identity to
hang tags on. **This app has no such thing.** A `players` row belongs to
one tournament (`players.tournament_id`), and `fide_id` is unique only
*within* a tournament
(`player.ex:375-377`, `unique_constraint(:fide_id, name:
:players_tournament_id_fide_id_index)`). `fide_players` and `kbsb_players`
are rating-list caches synced from external sources
(`priv/repo/migrations/20260709170320_create_core_tables.exs:113-124`), not
app-owned people. So a durable tag would need a new identity table, keyed
on what? FIDE ID is optional and frequently absent in club play - the
snapshot schema says so in its own words
(`openresults/docs/snapshot-schema.md:136-138`: `fide_id`, `rating`,
`federation`, `club`, `title` are "all optional, all frequently absent in
club play"). Name plus birth year is not an identity. That is a project of
its own, not a column.

Two further facts point the same way:

- **Tournaments move between owners.** `lib/pairings_engine/handoff.ex`
  transfers a tournament to another user. A tag vocabulary scoped to a user
  would either follow the tournament (and collide with the receiving user's
  vocabulary) or not (and the tags become dangling names). Scoping it to
  the instance makes one arbiter's "Junior" everyone's.
- **JSON import mints a new tournament.**
  `TournamentImport.import_players!/3`
  (`lib/pairings_engine/tournament_import.ex:280-287`) inserts fresh
  `Player` rows under a new tournament id. A global vocabulary would need
  reconciliation on every restore - matching foreign tag names against
  local ones, with no key to match on.

And the durable facts the request actually names are **already stored as
first-class player fields**: `sex` (`player.ex:11`), `birth_year`
(`player.ex:17`), `club` (`player.ex:19`), `federation` (`player.ex:16`).
`PlayerStats.assign_category/4`
(`lib/pairings_engine/player_stats.ex:44-68`) already derives brackets from
rating and birth year via `category_rules`. "Junior" is not a fact that
needs storing per person; it is a fact this app can compute. What is left -
"club prize eligible", "sponsor guest", "school team", "plays for the B
squad this weekend" - is genuinely per-event.

**Recommendation: per-tournament.** If the maintainer later wants durable
tags, they arrive as a *separate* feature - a person registry - and
per-tournament tags become its projection. Nothing here forecloses that.

### 1b. Array column or join table

Given per-tournament, the vocabulary already exists (`tournament.categories`)
and the only question is how a player's subset of it is stored.

**Option A - array column on `players`.**

```elixir
field :categories, {:array, :string}, default: []
```

- `ecto_sqlite3` stores `{:array, _}` as JSON in a TEXT column and loads it
  with `Codec.json_decode/1`
  (`deps/ecto_sqlite3/lib/ecto/adapters/sqlite3.ex:410-413`;
  `.../sqlite3/data_type.ex:49-52`). The precedent is
  `tournament.categories` itself, stored the same way since
  `priv/repo/migrations/20260710120000_add_swar_admin_fields.exs:33-34`.
- **Cannot be filtered in SQL.** `deps/ecto_sqlite3/lib/ecto/adapters/
  sqlite3/connection.ex:1382-1387` raises `Ecto.QueryError` - "Array
  literals are not supported by SQLite3" - for a list literal in a query.
  A `fragment("EXISTS (SELECT 1 FROM json_each(...))")` would work (the
  bundled SQLite is 3.53.3, `deps/exqlite/c_src/sqlite3.c:470`, so JSON is
  core), but it is a hand-written escape hatch.
- **That cost is zero today.** Nothing filters players by category in SQL.
  `Tournaments.list_players/1` (`lib/pairings_engine/tournaments.ex:1935-1950`)
  selects the whole roster ordered by rating and name; every category
  filter in the codebase is an in-memory `Enum.filter` -
  `pairing.ex:727`, `pairing.ex:734`,
  `print_controller.ex:978`, `print_controller.ex:991`. A tournament is a
  few hundred players.
- **Travels for free.** It is a schema field, so
  `TournamentExport.@player_fields`
  (`lib/pairings_engine/tournament_export.ex:190-197`) carries it by adding
  one name, and `TournamentImport` restores it through the existing
  `Player.changeset/2` cast with no code change at all
  (`tournament_import.ex:280-287`).
- **No preload discipline.** There are 15 distinct `from p in Player`
  query sites across `lib/` (`pairing.ex:328, 2653, 2671, 2688, 2878`;
  `pairing_rationale.ex:717`; `round_robin.ex:355`; `snapshots.ex:434`;
  `tournaments.ex:1937, 1953, 2019, 2341, 2539, 2548, 3043`) plus 29
  `list_players/1` call sites. Every one of them returns a `Player` struct
  that some template may render. An array field is always loaded.

**Option B - join table.**

```
player_categories(player_id, name)          -- names as strings
-- or --
tournament_categories(id, tournament_id, name, position, rule)
player_categories(player_id, tournament_category_id)
```

- SQL filtering, grouping and counting become possible.
- Referential integrity: renaming a category is one row; deleting one
  cascades. Today, removing a category on the Categories page
  (`categories_live.ex:261-276`) deletes the name from
  `tournament.categories` and its rule from `category_rules` but **does not
  touch any player still holding that string** - verified, there is no
  player write in that handler. The join table fixes that class of bug
  structurally.
- **The cost is preload discipline across 44 call sites.** A missed preload
  is `%Ecto.Association.NotLoaded{}` reaching a template - a crash, or (if
  someone defends with a `case`) a silently empty tag list on a printed
  prize sheet. This codebase has been bitten repeatedly by exactly this
  shape of "two places kept in agreement by a comment rather than by the
  compiler" (`player.ex:185-197`, the `absent_rounds` duplicated-parser
  note ending "One rule, one home"; `player.ex:21-38`, the two `paid`
  defaults).
- **The export guard does not cover `Player`.** `tournament_export_test.exs`
  has a regression guard that fails when a schema field is neither exported
  nor deliberately excluded (`test/pairings_engine/
  tournament_export_test.exs:251-262`), but `guarded_schemas/0`
  (`:50-64`) lists only `Tournament`, `Round`, `Pairing`, `AuditLog` and
  `Collaborator`. **`Player` and `Team` are not guarded.** So neither a new
  `Player` field nor a new association would be caught by it. Under
  Option B the export needs a whole new nested section in the JSON envelope
  and matching id-remapping in `TournamentImport`, with no test forcing
  the decision.

**Recommendation: Option A, the array column**, named `categories` on
`players` to sit beside `tournament.categories`.

The deciding argument is that Option B buys SQL filtering the app does not
use, and pays for it with a preload obligation at 44 call sites that no
test enforces, in a repository whose own comments say the recurring bug is
the invariant kept by convention rather than by the compiler. Option A's
one real weakness - a tag name that no longer exists in
`tournament.categories` - already exists today with the single `category`
field and is already handled in the UI
(`players_live.ex:2157-2163` renders a "(not in list)" option to preserve
such a value), and is fixed cheaply by having "remove category" also strip
the name from every player, which is a five-line addition to
`categories_live.ex:261-276`.

**Prerequisite either way:** add `Player` (and `Team`) to
`guarded_schemas/0` in `tournament_export_test.exs` *before* adding the
field, so the backup/restore decision is forced rather than assumed.

## 2. The pairing category

### The rule

Keep `players.category`, but **redefine it as an override**, and put the
answer behind one function:

```elixir
# lib/pairings_engine/categories.ex  (new)
def pairing_category(%Tournament{} = t, %Player{} = p) do
  listed = t.categories || []
  tags   = p.categories || []

  cond do
    p.category in listed and p.category in tags -> p.category
    true -> Enum.find(listed, "", &(&1 in tags))
  end
end
```

Read out loud: *the player's pairing pool is the category they were
explicitly placed in, if they still carry it and the tournament still lists
it; otherwise the first of their tags in the tournament's own category
order; otherwise none, which means the Uncategorized pool.*

Both branches are deterministic and both are visible: the order is the one
the arbiter sees on the Categories page, and the override is a control on
the player.

### Why derived-with-an-override rather than either extreme

**Purely stored** (two independent fields, arbiter maintains both) is the
drift bug this codebase keeps re-learning. The arbiter tags someone
"Women" for the prize list, the stored pairing category still says `""`,
and `pair_by_category` pairs them in Uncategorized while the screen shows
a category. Nothing would detect it.

**Purely derived** (first tag in list order, no override) is honest and has
a precedent - `PlayerStats.assign_category/4` already breaks a cross-kind
tie exactly this way, and documents it at
`player_stats.ex:31-35`: "the tie is broken by `category_order`: whichever
kind's winning category comes FIRST in that list wins outright. Arbiters
who want a specific kind to take priority should list it first." But the
priority is only genuinely the arbiter's if they can reorder the list, and
today they cannot: `categories_live.ex:241` appends
(`"categories" => categories ++ [trimmed]`) and the page offers add and
remove only (`categories_live.ex:476-497`). Under pure derivation, adding
a prize tag could silently move a player between pairing pools mid-event
with no way to say otherwise.

The override costs one `cond` and removes that hazard. It cannot drift,
because it is honoured only while it is still one of the player's tags and
still one of the tournament's categories - a stale override self-heals into
the derived answer rather than fighting it.

### What happens to `pair_by_category`

Nothing changes about the mechanism. `category_groups/2`
(`pairing.ex:721-739`) becomes:

```elixir
named_groups =
  Enum.map(named_categories, fn cat_name ->
    {cat_name, Enum.filter(players, &(Categories.pairing_category(tournament, &1) == cat_name))}
  end)

uncategorized =
  Enum.filter(players, &(Categories.pairing_category(tournament, &1) == ""))
```

Still a partition: every player yields exactly one value, and the values
are `listed ++ [""]`. Independent runs, independent byes, one merged Round,
continuous boards - all untouched.

`PairingRationale.category_for/2`
(`pairing_rationale.ex:485-489`) calls the same function, which closes the
label-versus-pool discrepancy found above: both sides now get their answer
from one place.

`pair_by_category` stays in `locked_fields/1`
(`tournaments.ex:766`) and its two exclusions - Baku acceleration and match
format (`tournament.ex:950-968`) - are unaffected.

## 3. Migration

The app is deployed to a live server used by real arbiters, and
`docs/deployment.md:118-128` says the deploy runs `ecto.migrate` **before**
restarting, "seconds apart". So for a few seconds the *previous* release
runs against the *new* schema. Every constraint below follows from that.

### The migration

```elixir
defmodule PairingsEngine.Repo.Migrations.AddPlayerCategories do
  use Ecto.Migration

  def up do
    alter table(:players) do
      add :categories, :text, null: false, default: "[]"
    end

    # Backfill in the same migration, not a follow-up task: a window where
    # every player has an empty tag list is a window where a prize list is
    # wrong.  json_array() rather than string concatenation so a category
    # name containing a quote cannot produce invalid JSON.
    execute """
    UPDATE players
       SET categories = json_array(category)
     WHERE category IS NOT NULL AND category <> ''
    """
  end

  def down do
    alter table(:players) do
      remove :categories
    end
  end
end
```

`:text` with a `"[]"` default rather than `add :categories, {:array, :string}`
because the adapter maps `{:array, _}` onto a plain string column anyway
(`data_type.ex:49-52`) and writing it out makes the storage explicit and
the default literal correct. The schema declares
`field :categories, {:array, :string}, default: []` and the adapter's
JSON loader (`sqlite3.ex:410-413`) does the rest.

Note the shape difference from `20260710120000_add_swar_admin_fields.exs:33-34`,
which used `add :categories, {:array, :string}, null: false, default: []`.
Either form works; the explicit one is clearer about what SQLite actually
holds. Whichever is chosen, **check the generated default with
`.schema players` before shipping** - not established which literal the
migration DSL emits for `default: []` on this adapter version.

### Why nothing is lost

1. **`players.category` is never dropped and never rewritten.** Its meaning
   narrows from "the category" to "the pairing-pool override", and for
   every existing row the two are the same value. No `UPDATE` touches it.
2. **Pools after the upgrade are identical to pools before it.** For a
   migrated player, `categories == [category]`. Feed that through
   `pairing_category/2`:
   - `category` listed in `tournament.categories`: first branch matches
     (it is in `listed` and in `tags`), returns `category`. Same pool as
     `category_groups/2` gave before.
   - `category` **not** listed: first branch fails, `Enum.find` over
     `listed` finds nothing in `["Z"]`, returns `""` - the Uncategorized
     pool, which is exactly where `pairing.ex:734` put them before.
   - `category` blank: `tags == []`, returns `""`. Same.

   So the round paired after the upgrade is the round that would have been
   paired before it. That is the property a mid-event upgrade has to have.
3. **Already-paired rounds cannot change.** A paired round's pairs are
   `Pairing` rows and its explanation is stored JSON;
   `Pairing.reexplainable?/1` (`pairing.ex:1343`) is
   `t.pairing_system == "swiss" and not t.pair_by_category`, so a
   category-paired round is never re-analysed. Nothing recomputes history.
4. **The old release survives the gap.** Ecto compiles a `SELECT` naming
   only the fields its schema declares, so the previous release does not
   see the new column and reads `category` exactly as before. The migration
   is additive and the backfill writes only the new column.
5. **Rollback.** `down/0` drops the column (SQLite 3.53 supports
   `ALTER TABLE DROP COLUMN`, so no table rebuild). Rolling the *code* back
   without rolling the schema back is also safe, for the same reason as
   point 4.

### Backups across the boundary

- **Old backup restored on the new build.** The player map has no
  `"categories"` key; `Player.changeset/2` leaves the field at its
  `default: []`. `category` restores as it always did, so
  `pairing_category/2` returns the override and the tournament behaves as
  it did on the old build. The tag list is empty, which is honest - the
  backup never carried one. Consider a one-line repair in
  `TournamentImport.import_players!/3` that seeds
  `categories: [category]` when `categories` is absent and `category` is
  not, so an old backup restores fully rather than half.
- **New backup restored on an old build.** `Ecto.Changeset.cast/3` with an
  explicit permitted list silently ignores unknown keys, so `"categories"`
  is dropped and `category` survives. Tags are lost, the pairing category
  is not. State this in `docs/import-export.md`.

### The one behaviour change to announce

Under the new rule a player whose `category` is not in
`tournament.categories` is labelled "Uncategorized" on the pairing
explanation instead of by their unlisted name. That is the
`pairing_rationale.ex:485` bug being fixed, it only affects the
explanation text of rounds paired **after** the upgrade, and it needs a
`[Fix]` CHANGELOG line rather than passing unremarked.

## 4. Sorting, honestly

A set has no order. The grid must not pretend otherwise, and the way not to
pretend is to offer three separate things and name each of them.

Today's machinery: `PlayersLive.sort_entries/3`
(`players_live.ex:199-207`) maps every entry through `sort_value/2` and
compares with `sort_lte?/3` (`:216-220`), which sorts a `{blank?, value}`
pair and pins blanks last in both directions. The category clause is
`sort_value(entry, "cat"), do: text_sort_value(entry.grid["cat"])`
(`:249`), fed from `"cat" => entry.player.category || ""`
(`:397`) and rendered by `cell(entry, "cat")` (`:1283-1288`).
Column definition and tooltip: `:61-64`.

### What the column should offer

**1. Sort by the pairing category** - the default meaning of clicking the
"Cat" header. This is legitimate because it is single-valued.

```elixir
defp sort_value(entry, "cat"), do: category_rank(entry)
```

returning `{0, index_in_tournament_categories}` for a player with a pairing
category and `{1, nil}` for one without. Sorting by list position rather
than alphabetically is the improvement: `"-1800"` before `"-2000"` is
alphabetical nonsense, and the arbiter's own order is the meaningful one.
Blanks last in both directions is correct here - unlike the `pr` column,
where it was wrong and was fixed in 0.51.0, "no category" really is the
absence of an answer.

**2. Group by one tag** - "show me the U16s first". The existing
`{sort_col, sort_dir}` pair carries this with no new assigns by encoding
the tag in the column key:

```elixir
defp sort_value(entry, "cat:" <> tag),
  do: {0, if(tag in (entry.player.categories || []), do: 0, else: 1)}
```

Ascending puts carriers first, descending puts them last, and within each
group the grid keeps its secondary order. This is the "sorting on whether a
player carries one" that TODO.md names, and it is a real order because the
predicate is boolean.

**3. Filter to one tag** - "give me only the U16s". A chip row above the
grid, or a "Show only this" item in the header menu. A filter, not a sort;
it changes which rows exist, and the standings rank column keeps showing
the player's rank in the whole event rather than a re-ranked position -
the same choice `print_controller.ex:916-920` already documents for its
per-category standings tables ("same ordering (each category's ranks are
the overall ranks, just filtered), not re-ranked within the category").

### What it must not do

- Sort by "the tags this player has". A set is not comparable, and the
  three plausible collapses - alphabetically first tag, tag count, joined
  string - are each arbitrary and none is visible to the arbiter.
- Sort by tag count. It reads like information and is not.
- Silently pick one tag to sort by. If a tag is being sorted on, the header
  says which one.

### The cell and the bulk menu

`CELL_MENUS` in `assets/js/app.js:49-66` is a static object with fixed
`items`/`bulkItems`, keyed by column, driving both the per-row menu and the
column-header bulk menu (`:84-122`, `openCellMenu` at `:143`). Categories
are per-tournament, so a `cat` entry cannot be a literal - the menu has to
be built from data the server puts in the DOM.

Smallest change that fits the existing structure:

- The grid element carries the vocabulary,
  `data-categories='["-1100","-1800","Women"]'`, and each `cat` cell carries
  the player's own set, `data-tags='["Women"]'`.
- `CELL_MENUS.cat` gains `dynamic: true` plus a builder; `openCellMenu`
  reads the attributes and emits one toggle per category ("Add Women" /
  "Remove Women" depending on the cell's current set), pushing
  `toggle_category` with `{id, name, value}`.
- The header (bulk) menu offers "Add <tag> to everyone" / "Remove <tag>
  from everyone" plus "Show only <tag>" and "Show all". The bulk writes go
  through `Tournaments.bulk_update_players/2` - one transaction, one
  broadcast - the pattern `set_all_players_paid/2`
  (`tournaments.ex:2149-2155`) and `auto_assign_categories/1`
  (`tournaments.ex:2223-2235`) already use.
- The row handler mirrors `set_paid`
  (`players_live.ex:651-679`): read the player, update, audit the change,
  reassign. `@audited_player_fields` (`players_live.ex:1098-1101`) gains
  `categories`, and a new audit action code for the bulk case needs an
  entry in `HistoryLive.@kinds` (`history_live.ex:63-80`) or it falls
  through to the neutral colour - which the comment there says is
  deliberate and safe.

The header still sorts on left click and opens the menu on right click, as
it does for `pr` and `paid` today (`app.js:85-94`).

### The player dialog

`players_live.ex:2147-2172` is a single `<select name="player[category]">`
with an option per `@tournament.categories`, a preserved "(not in list)"
option (`:2157-2163`) and a free-text input when the tournament has no
categories (`:2168-2170`). It becomes a checkbox group over
`@tournament.categories` writing `player[categories][]`, plus a small
"pairing pool" radio - shown **only** when `tournament.pair_by_category` is
on, since that is the only setting where the override means anything - and
the free-text escape hatch is kept for tournaments with no defined list.

## 5. Blast radius

39 references to a player's category across `lib/`, grouped by what each
one needs. Verified file and line; the "unrelated" list at the end matters
as much, because four modules use the word "category" for something else.

### Group 1 - the schema and the new rule (must change)

| Where | What it is |
|---|---|
| `lib/pairings_engine/tournaments/player.ex:53` | `field :category, :string, default: ""` - stays, meaning narrows to "pairing-pool override"; its comment must say so |
| `lib/pairings_engine/tournaments/player.ex:115` | cast list - add `:categories` |
| `lib/pairings_engine/categories.ex` | **new** - `pairing_category/2`, the one home for the rule |

### Group 2 - pairing (must read the derived value)

| Where | What it is |
|---|---|
| `lib/pairings_engine/pairing.ex:727` | `Enum.filter(players, &(&1.category == cat_name))` - the named pools |
| `lib/pairings_engine/pairing.ex:734` | `p.category in [nil, ""] or not MapSet.member?(named_set, p.category)` - the Uncategorized pool |
| `lib/pairings_engine/pairing_rationale.ex:452` | `category: category_for(tournament, white)` |
| `lib/pairings_engine/pairing_rationale.ex:485-489` | `category_for/2` - delete, call `Categories.pairing_category/2`; this is the discrepancy fix |
| `lib/pairings_engine/pairing_rationale.ex:761` | `category: b.category` - serialises the board's category into the stored explanation; unchanged, but now always a listed name or "Uncategorized" |
| `lib/pairings_engine/round_explanation.ex:33` | `category: section["category"]` - reads stored JSON; **no change**, old records keep their old labels |
| `lib/pairings_engine_web/live/pairing_explain_live.ex:2486-2487` | board tag render - no change |
| `lib/pairings_engine_web/live/pairing_explain_live.ex:2795` | section heading render - no change |

### Group 3 - rule-driven assignment (becomes multi-valued, cheaply)

| Where | What it is |
|---|---|
| `lib/pairings_engine/player_stats.ex:44-68` | `assign_category/4` - already computes **all** matching candidates, one per rule kind, then collapses to one at `:66` with `Enum.min_by(..., order_index)`. A sibling `assign_categories/4` that returns the whole candidate list, ordered by `order_index`, is that one line deleted. This is the request's core use case - junior *and* woman - falling out of machinery that already exists |
| `lib/pairings_engine/tournaments.ex:2261` | `PlayerStats.assign_category(player, tournament.categories, tournament.category_rules)` |
| `lib/pairings_engine/tournaments.ex:2263` | `%{player: player, from: player.category \|\| "", to: category}` - preview diff becomes set-to-set |
| `lib/pairings_engine/tournaments.ex:2227` | `{player, %{category: category}}` - the write |
| `lib/pairings_engine_web/live/categories_live.ex:285-337, 520-566` | the dry-run preview and confirm modal - the diff renders two sets instead of two strings |
| `lib/pairings_engine_web/live/categories_live.ex:261-276` | "remove category" - currently deletes the name from `tournament.categories` and `category_rules` and **leaves it on every player**. Should also strip it from every player's tag list |

Note the destructive semantics documented at `tournaments.ex:2202-2210`:
auto-assign **overwrites**, resetting a non-matching player to `""`. With
tags the honest choices are "replace the ruled tags, leave hand-set ones"
or "replace everything". Open question below.

### Group 4 - display surfaces showing one category (must decide which)

| Where | What it is |
|---|---|
| `lib/pairings_engine_web/live/players_live.ex:61-64` | `{"cat", "Cat", false, "Prize category (SWAR CATEGORIES)..."}` - tooltip needs rewriting |
| `lib/pairings_engine_web/live/players_live.ex:249` | `sort_value(entry, "cat")` |
| `lib/pairings_engine_web/live/players_live.ex:394-397` | `"cat" => entry.player.category \|\| ""` |
| `lib/pairings_engine_web/live/players_live.ex:1098-1101` | `@audited_player_fields` includes `category` |
| `lib/pairings_engine_web/live/players_live.ex:1152` | `player_to_form/1`'s `"category" => p.category` |
| `lib/pairings_engine_web/live/players_live.ex:1283-1288` | `cell(entry, "cat")` |
| `lib/pairings_engine_web/live/players_live.ex:2147-2172` | the `<select name="player[category]">` |
| `lib/pairings_engine_web/live/standings_live.ex:253-255` | `category_or_dash/1` |
| `lib/pairings_engine_web/live/standings_live.ex:535` | Swiss standings cell, gated on `@tournament.categories != []` |
| `lib/pairings_engine_web/live/standings_live.ex:617` | Keizer standings cell, same gate |
| `lib/pairings_engine_web/live/categories_live.ex:476-497` | the category table - one row per category, add/remove only, **no reorder** |

Both standings gates test `tournament.categories != []` and **not**
`categories_enabled` (`tournament.ex:522`). That inconsistency predates
this feature; preserve or fix deliberately, not by accident.

### Group 5 - printing

| Where | What it is |
|---|---|
| `lib/pairings_engine_web/controllers/print_controller.ex:339` | `{:cat, "Cat", false}` in `@player_list_columns`, opt-in via `?cols=` |
| `lib/pairings_engine_web/controllers/print_controller.ex:450` | `player_list_value(:cat, p, _), do: esc(p.category)` |
| `lib/pairings_engine_web/controllers/print_controller.ex:927-939` | Keizer standings, `has_categories` gate and per-category tables |
| `lib/pairings_engine_web/controllers/print_controller.ex:946-966` | Swiss standings, same |
| `lib/pairings_engine_web/controllers/print_controller.ex:955` | `category_or_dash(e.player.category)` cell |
| `lib/pairings_engine_web/controllers/print_controller.ex:972-985` | `category_standings_tables/2` - `Enum.filter(&(&1.player.category == category))` |
| `lib/pairings_engine_web/controllers/print_controller.ex:987-999` | `keizer_category_standings_tables/2` - same equality filter |
| `lib/pairings_engine_web/controllers/print_controller.ex:1014-1017` | `keizer_standings_row/2` cell |
| `lib/pairings_engine_web/controllers/print_controller.ex:1034-1036` | `category_or_dash/1` |

This is where the feature pays off: the two `Enum.filter(&(&1.player.category
== category))` lines become membership tests, and one player then correctly
appears in the U16 table *and* the Women table. That is the prize-list
problem the request is actually about. `print_controller.ex:916-920`'s
promise of byte-identical output for a tournament with no categories still
holds.

### Group 6 - interop that is structurally single-valued (SWAR)

SWAR's wire format has **one signed 32-bit category index per player**, in
the 5th slot of the `[JOUEURS]` record:

| Where | What it is |
|---|---|
| `lib/pairings_engine/federations/bel/swar_import.ex:420` | `{cat_index, bin} = read_i32(bin)` |
| `lib/pairings_engine/federations/bel/swar_import.ex:477` | `cat_index:` - the only category key in the parsed player map |
| `lib/pairings_engine/federations/bel/swar_import.ex:1490-1496` | `category_name/2` - `0` means none; otherwise `Enum.at(value1, div(cat_index, 100))` |
| `lib/pairings_engine/federations/bel/swar_import.ex:1623` | `category: category_name(p.cat_index, categories)` |
| `lib/pairings_engine/federations/bel/swar_export.ex:141` | `tournament.categories |> Enum.take(16)` - silent truncation at 16 |
| `lib/pairings_engine/federations/bel/swar_export.ex:379-389` | `reverse_categories/1` - writes `value1` with a leading blank, `value2` always empty |
| `lib/pairings_engine/federations/bel/swar_export.ex:529` | `w_i32(reverse_cat_index(p.category, categories))` |
| `lib/pairings_engine/federations/bel/swar_export.ex:601-609` | `reverse_cat_index/2` - `""`/`nil` → 0; otherwise `Enum.find_index` in the list, `nil` → 0 |

SWAR has **no** multi-category concept. Searched: no junior/veteran/women/
prize-group flags anywhere in either module. The one candidate - the second
value list in `[CATEGORIES]` - is explicitly documented as *unknown in
meaning* at `swar_import.ex:1440-1446`, and players cannot reference it at
all, since `category_name/2` resolves against `value1` alone
(`swar_import.ex:1434-1438`). SWAR's own pairing sorts by
`(Category, Class, Rank)` with a single Category - quoted from SWAR's
source at `swar_export.ex:478-481`.

**The export must write the pairing category, not a tag.** The dangerous
failure is silent: `reverse_cat_index/2`'s fallback clause
(`swar_export.ex:604-608`) does `Enum.find_index(categories, &(&1 ==
category))`, and a list argument matches nothing, so `nil -> 0` would
export **every player as uncategorised** with no crash and no warning. The
change is one line - pass `Categories.pairing_category(tournament, p)` -
but it must not be missed. Add a guard clause that raises on a non-binary,
and a test.

Import writes both: `category: name` and `categories: [name]` (or `[]`),
which keeps the round trip exact for a SWAR-sourced tournament.

Tests pinning the single-value shape:
`test/pairings_engine/federations/bel/swar_export_test.exs:109, 119, 339-346,
363-371`; `.../swar_category_warning_test.exs:33-71`.

### Group 7 - interop that is additive

| Where | What it is |
|---|---|
| `lib/pairings_engine/player_export.ex:70` | `{:category, "Category", :text}` in the CSV `@columns`. Add `{:categories, "Categories", :text}` rendering the tags joined; keep the existing column meaning the pairing category |
| `lib/pairings_engine/tournament_export.ex:190-197` | `@player_fields` - add `categories` |
| `lib/pairings_engine/tournament_export.ex:79` | `categories category_rules categories_enabled` in `@tournament_fields` - the vocabulary already round-trips |
| `lib/pairings_engine/snapshot.ex:224` | `"category" => blank_to_nil(p.category)` in `player_row/1` - see section 6 |
| `lib/pairings_engine/snapshot.ex:425` | Keizer standings row's `"category"` |
| `lib/pairings_engine/snapshot.ex:500` | Swiss standings row's `"category"` |
| `lib/pairings_engine/public_display.ex:105-116` | the `"category"` display toggle, label "Categories" - tags ride under this key, no new key crosses to OpenResults |
| `lib/pairings_engine_web/live/history_live.ex:63-80` | `@kinds` maps audit action prefixes to timeline colours; already has `"category"` and `"categories"`. A new bulk action code needs an entry or falls to the neutral default, which `:64-66` says is deliberate |

### Group 8 - verified as untouched

- **TRF export and import carry no category at all.** `trf_export.ex`,
  `trf_import.ex` and `deps/ainalrami/lib/ainalrami/trf.ex` have zero
  case-insensitive matches for `categor`. The player row handed to the
  serializer is built at `pairing.ex:2472-2487` and its keys are `id, rank,
  sex, title, name, fide_rating, federation, fide_number, birth_date,
  points, games`. Nothing to do, in either TRF16 or TRF26.
- **The norms pipeline never reads a player's category.**
  `norms/forms.ex`, `norms/counts_breakdown.ex`, `norms/combine.ex`,
  `norms_live.ex`, `norms_controller.ex` and `it3_counts_explain.ex` use
  "category" for two other things: the rated/unrated/GM/IM/FM count buckets
  of the IT3 count block (`counts_breakdown.ex:19-33`, built from
  `Player.rating/1` and `player.title` at `forms.ex:262`), and a festival's
  "category groups", which in this app are **separate `Tournament` rows**
  merged into one report (`combine.ex:5, 20, 103`). Neither touches
  `players.category`. Nothing to do.
- **`audit_live.ex`** (25 hits) - audit *event* categories, a log filter.
  Unrelated.
- **`pairing_display.ex:56`** - the English word. Unrelated.

## 6. The snapshot contract

`openresults/docs/snapshot-schema.md` states the rule at `:20-26`:
"**Additive only.** A field is never removed, never renamed, and never
repurposed"; "**The reader ignores what it does not recognise.**" The
envelope is versioned, the fields are not (`:25-26`), and
`openresults/lib/openresults/envelope.ex:29-56` validates only the schema
id, the version and the presence of a slug - it does not reject unknown
keys.

### What must not change

- **`players[].category`** (schema doc `:82`; written at
  `snapshot.ex:224`). Keeps meaning "this player's single category". Under
  the new model that value is `Categories.pairing_category(tournament, p)`.
  For a tournament that never uses more than one tag per player this is
  byte-identical to today. It must not become a joined string, an array, or
  the first tag alphabetically.
- **`standings.rows[].category`** (schema doc `:123`; written at
  `snapshot.ex:425` for Keizer and `:500` for Swiss). Same value, same
  meaning. OpenResults reads it directly -
  `openresults/lib/openresults_web/controllers/tournament_html.ex:184`
  decides whether to show the column with
  `Enum.any?(standings_rows, & &1["category"])` and `:254` renders
  `dash(row["category"])`. Changing the shape breaks the standings table on
  every already-published tournament.
- **The `display` key `"category"`.** `public_display.ex:105-116` emits it
  and `tournament_html.ex:869` lists it in the allowlist that
  `display_rules/1` resolves. Tags ride under the same toggle, so no new
  key crosses and OpenResults needs no change for the payload to stay
  valid.

### What gets added

One field:

```json
"players": [
  {
    "no": 1,
    "name": "Carlsen, Magnus",
    "category": "A",
    "categories": ["A", "Women", "Club"]
  }
]
```

- **`players[].categories`** - array of strings, in `tournament.categories`
  order, optional. Absent means "not known" (an older arbiter's laptop),
  exactly as `fide_id` and `rating` already work (schema doc `:136-138`).
  When present it is a superset of `category`: the pairing category is
  always one of the tags, or `null` when the player has none.

### What must not be added

- **`standings.rows[].categories`.** The row already references the player
  by `no`, and `players[]` carries the tags; adding an array there would
  duplicate a duplicate. The existing `standings.rows[].category` is
  already redundant with `players[].category` and exists for the
  standings renderer's convenience - a precedent worth not extending.
- **A new `display` key.** See above.

The OpenResults side (rendering per-tag prize tables) is a separate change
in a separate repository and is not blocked by this: the payload is valid
and ignored until that app is taught the field.

## 7. Build plan

Seven phases, each ending somewhere shippable. Day figures are engineering
days for one person including tests, and are estimates rather than
measurements. The suite is ~3322 tests across 108 files; 30 files mention
categories.

**Phase 0 - the rule, no schema change. ~0.5 day.**
Create `PairingsEngine.Categories` with `pairing_category/2` reading only
today's `category` field. Repoint `pairing.ex:727/734` and
`pairing_rationale.ex:485-489` at it. This alone fixes the
label-versus-pool discrepancy. Ships as a `[Fix]`, no migration, no UI.
*Prerequisite in the same phase:* add `Player` and `Team` to
`guarded_schemas/0` in `test/pairings_engine/tournament_export_test.exs:50-64`,
so the next phase's new field cannot silently miss the backup.

**Phase 1 - schema, migration, backfill. Nothing reads tags yet. ~1 day.**
`players.categories` array; cast in `Player.changeset/2`; add to
`@player_fields`; the seed-from-`category` repair in
`TournamentImport.import_players!/3`; `pairing_category/2` gains its
override branch. Every migrated row has exactly one tag, so behaviour is
provably unchanged - assert that with a test that pairs a
`pair_by_category` round before and after the backfill and compares boards.
Invisible, shippable, and it is the risky half done on its own.

**Phase 2 - the Players grid. ~2-3 days.**
Tag chips in the `cat` cell; the checkbox group and pairing-pool radio in
the player dialog; the dynamic `CELL_MENUS.cat` in `assets/js/app.js`; the
row and bulk handlers via `bulk_update_players/2`; audit entries; the
honest sorting of section 4 (pairing-category sort by list position,
`"cat:<tag>"` grouping, tag filter chips). This is the feature as asked
for.

**Phase 3 - the other display surfaces. ~1 day.**
Standings column (`standings_live.ex:535, 617`); printed per-category
standings tables become membership tests
(`print_controller.ex:978, 991`) so one player lands in several; the CSV
`Categories` column in `player_export.ex`.

**Phase 4 - the snapshot. ~0.5 day here.**
`players[].categories` in `snapshot.ex:215-226`, plus the schema-doc entry
in the OpenResults repository. The OpenResults rendering work is separate
and unblocked.

**Phase 5 - the Categories page. ~1 day.**
Reorder controls (the derivation's priority is only the arbiter's if the
order is); "remove category" strips the name from every player;
`assign_categories/4` and a preview/confirm diff that shows sets.

**Phase 6 - SWAR. ~0.5 day.**
Export writes the pairing category with a guard clause that raises on a
non-binary rather than silently exporting zeros; import writes both fields;
tests. Document the loss in `docs/swar-import.md` - SWAR cannot carry a
second category, so a round trip through `.swar` keeps the pairing category
and drops the rest.

**Phase 7 - documentation. ~0.5 day.**
A `docs/categories.md` in the style of `docs/extra-points.md`, the TODO.md
entry closed, CHANGELOG entries per phase (the repo's rule: a user-visible
change gets its CHANGELOG entry in the same commit).

Total: roughly 7-8 days. The irreducible risk is concentrated in phases 1
and 6 - the migration, and the silent-zeros SWAR export path.

## 8. Open questions for the maintainer

1. **Per-tournament or per-player?** Recommended above: per-tournament,
   because a durable tag needs a person identity this app does not have and
   the durable facts named in the request (sex, birth year, club) are
   already first-class player fields. Confirm before phase 1, since it is
   the one decision phase 1 cannot walk back cheaply.

2. **Does the pairing-pool override belong in the UI at all?** The
   `cond` in `pairing_category/2` is nearly free either way. But a control
   that only means something when `pair_by_category` is on - a beta feature
   - may be a control most arbiters should never see. Show it only when
   that setting is on, or never, and derive silently?

3. **What should `auto_assign_categories/1` do now?** Today it
   **overwrites**, resetting a non-matching player to `""`, and the doc at
   `tournaments.ex:2202-2210` says a hand-set category does not survive a
   re-run. With tags there are three defensible behaviours: replace the
   whole set, replace only tags that have rules and leave hand-set ones, or
   add without removing. The second is the least surprising and the most
   work. Not decided here.

4. **Should categories be reorderable?** Recommended in phase 5 because
   derivation priority follows list order and the page currently only
   appends (`categories_live.ex:241`). If reordering is out of scope, the
   override in question 2 becomes mandatory rather than optional.

5. **Is there an upper bound on tags per player?** Nothing in the design
   needs one, but the SWAR export truncates the *vocabulary* at 16
   (`swar_export.ex:141`) and the printed grid cell has finite width. A
   soft cap keeps the Cat column readable; no cap keeps the model honest.

6. **Should removing a category strip it from players?** Recommended yes
   (phase 5). It changes existing behaviour: today a removed category stays
   on the player rows and reappears if the name is re-added
   (`categories_live.ex:261-276` writes no player rows). Some arbiters may
   rely on that as an undo.

7. **`standings_live.ex` gates the category column on
   `tournament.categories != []` rather than `categories_enabled`**
   (`:535`, `:617`). `print_controller.ex:927, 946` does the same. Was that
   deliberate? The feature touches both lines either way; worth settling
   rather than copying forward.

8. **Should the CSV export's existing "Category" column keep its name?**
   Recommended: yes, meaning the pairing category, with a new "Categories"
   column beside it. A spreadsheet someone has a macro against should not
   change shape. Confirm.
