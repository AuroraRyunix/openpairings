# SWAR import (`PairingsEngine.Federations.BEL.SwarImport`)

`.swar` is the native binary save format of SWAR (by Georges Marchal /
FRBE-KBSB), the tournament software most Belgian clubs already use.
`PairingsEngine.Federations.BEL.SwarImport` parses that binary format
directly (no intermediate export step) and creates a full tournament -
players, rounds, pairings, results - from it. Reached from the Tournaments
page's "Import SWAR file" panel.

Both modules live in `lib/pairings_engine/federations/bel/`, with the rest
of the Belgium-specific code. The rest of this document says `SwarImport`
and `SwarExport` unqualified.

## Switched on per account

Both directions are optional and off by default, under separate switches on
`/users/features` - `bel_swar_import` and `bel_swar_export` (see
`PairingsEngine.Features`). With a switch off the control is not on the
page at all, and the handler or route refuses the event or URL anyway.

**A tournament already imported from a `.swar` file is untouched by either
switch.** It keeps its `swar_guid`, its 3-2-1 scoring settings
(`abs_value`, `abs_jusque`, `abs_nbfois`, `presence_value`,
`presence_on_allocated_bye`), its players' clubs and national IDs, and it
produces exactly the same standings. Those fields live in the core
`Tournament`/`Player` schemas and are deliberately outside the pack.

The one place a `.swar` is still read with no switch involved is the public
`/tools/norms` page, which has no account and no user to ask - see
`PairingsEngine.Tools.Parser`'s moduledoc.

## Export (`PairingsEngine.Federations.BEL.SwarExport`)

The inverse - `GET /t/:id/export/swar`, "Export .swar (v7, experimental)"
on the Settings page - writes a v7 `.swar` binary field-for-field against
this module's own read order and reverse-mapping tables. Confirmed to open
in a real SWAR v7 install. Everything the import reads goes back out, and
an import of the export is the tournament that was exported - see
"Import and export: what goes where" below for the field-by-field table,
the round-trip results and the short list of what SWAR's format cannot
hold. The export page lists, beside the button, what of THIS tournament
the file cannot carry (`SwarExport.export_notes/1`).

**Does the pairing "seed" survive an export → re-open-and-continue-in-SWAR
round trip?** Yes - but getting there took one real wrong answer, found
by actually doing it: exporting a real tournament, pairing round 1 in a
real SWAR install, and comparing boards against what a rating-seeded
pairing should look like. They didn't match at all.

SWAR's Swiss pairing sorts players by `(Category, Class, Rank)` before
calling its own pairing engine (checked against a real copy of SWAR's
source, not inferred - `Swar - 20250906 v6.65 FRBE`). Both `Class`
(current standing) and `Rank` (the seed) are commented `à Calculer` ("to
be calculated") in `Swar.h`'s own struct definition, which reads like
"neither is ever trusted from the file" - and for `Class` that's true:
`CalculLeClassement()`, which recomputes it from each player's actual
points, runs unconditionally right before every Swiss pairing action
(`SwarView.cpp`: "Première chose à faire avant appariement", "first
thing done before pairing"). `Rank` is the trap: `RecomputeRank()` only
runs from the "add a player" UI action or Round Robin's own pre-pairing
prompt - never from a plain file load. `SwarExport`'s first version
wrote `rank` as `Ni` (registration order), which is exactly what a
freshly-opened export then paired round 1 by.

Fixed in `SwarExport.assign_ranks/1`: computes the same
rating-descending / title-descending / name-ascending sort SWAR's own
`Joueur.cpp:CmpRnkNormal` does.
`test/pairings_engine/federations/bel/swar_export_test.exs` pins it down with deliberately scrambled rating vs. registration order,
so a regression back to `rank = ni` fails loudly. `Class` staying a
constant 0 remains correct - see `reverse_player/6`'s own comment for
the full citations on both.

## Re-opening an exported TRF file in SWAR: byes do not survive

This is about a different file - a TRF export
(`PairingsEngine.TrfExport`/`Ainalrami.Trf`), not the `.swar` binary this
document is mostly about - but the hazard is real enough, and specific enough
to this pairing, to belong here rather than only in the audit document that
found it
([swar-source-audit-pass3-2026-09-09.md, §2.4](swar-source-audit-pass3-2026-09-09.md#24-f24--chasing-the-question-into-swars-own-trf-importer)).

**If an arbiter exports a TRF file from OpenPairings and opens it in SWAR,
every bye in it turns into an ordinary rated game.** SWAR's own TRF importer
(`ImportTrfFile.cpp:GetResult`) maps the three standard arbiter-decided bye
codes onto plain results instead of onto anything tagged "not played":

| TRF code | What it means | What SWAR's importer does with it |
|---|---|---|
| `H` (half-point bye) | player did not play, scores half | becomes an ordinary **draw**, against opponent `0000` |
| `F` (full-point bye) | player did not play, scores a full point | becomes an ordinary **win**, against opponent `0000` |
| `Z` (zero-point bye) | player did not play, scores nothing | becomes an ordinary **loss**, against opponent `0000` |
| `U` (pairing-allocated bye) | the pairing engine gave this player a bye | correctly becomes a tagged bye - **this one survives** |

The one other place that information could have survived is overwritten in
the same loop. SWAR marks a round as not played with a table number of
`-1`, and its own TRF writers test that field to decide a game was a bye.
The importer sets every imported round's table field to `0` instead, and
says so in its own comment - `-1 == non jouee, donc on y met 0`. So after
an import there is nothing left anywhere in that player's record to say the
game didn't happen.
Every tiebreak that specifically excludes unplayed rounds will silently
include these instead.

**OpenPairings' own export is not at fault.** `bye_code/1` (`pairing.ex`) and
`future_bye_code/1` (`PairingsEngine.TrfExport`) write exactly the FIDE-
standard codes (`F`/`H`/`Z`/`U`), matching `Ainalrami.Trf.result_codes/0`, and
`Ainalrami.Trf`'s own importer preserves all four correctly. The corruption
happens only if the file is subsequently opened in SWAR - reading it back into
OpenPairings itself is unaffected.

**What to do about it:** nothing changes in this codebase - there is no way to
write a TRF file that both conforms to the FIDE spec and survives SWAR's own
import bug for three of its four bye codes. If a report ever comes in of a
tournament's bye scores or tiebreaks looking wrong immediately after being
reopened in SWAR, check whether it passed through a TRF export/import step
first before assuming the bug is on this side.

## What the parser refuses before anything is written

Two pre-flight checks in `parse/1`, both because the alternative is damage
rather than a bad import:

* **Two `[JOUEURS]` records sharing an `NI`.** Every later step keys players
  by it through `Map.new/2`, which keeps only the last entry - so both would
  be imported as rows and the first one's games handed to the second.
* **A `[RONDE]` round number outside 1 to `Tournament.max_rounds/0` (30).**
  The number is a raw signed 32-bit integer straight off the disk, and
  `create_rounds/3` turns the highest one it finds into the range
  `1..max_round`, inside the import transaction and therefore holding
  SQLite's single write lock. One record saying 2,000,000,000 used to stop
  the whole application, not just the import. 30 is the ceiling because it
  is what a tournament may be here - a longer file describes an event this
  app could not hold even if the loop were free. A round 0 with a game or a
  result in it goes with them: it produced a Round row numbered 0, a round
  before the first.

An EMPTY round 0 - no opponent, no result, no table - is not refused but
taken off (`strip_round_zero/1`): SWAR's own "base" files, a club's player
list saved once and opened to start every new event from ("TOURNOI ZERO" in
SWAR's archive, 333 players), give every player one. Such a file imports as
a tournament with its players and no rounds, and says so.

## Team competitions: what a `.swar` file can and cannot say

**A `.swar` file has no teams in it, so a SWAR team event cannot be imported
as a team tournament.** Established 2026-09-27 from SWAR's own source
(`Swar - 20250906 v6.65 FRBE`) and from every real `.swar` file on hand, not
from a team sample - none exists, because SWAR does not write one:

- **The writer.** `TournoiReadWrite.cpp` writes exactly `[TOURNOI]`,
  `[DATES]`, `[TIE_BREAK]`, `[EXCLUSION]`, `[CATEGORIES]`, `[XTRA_POINTS]`,
  `[JOUEURS]` and each player's `[RONDE]`, then closes the file. No team,
  roster, board order, match, match point or team tie-break anywhere.
- **The types.** `Swar.h`'s `TOURNOI_TYPE` has nine values, all individual:
  Swiss, double Swiss, accelerated, 3-2-1, three round robins, two American.
  `DEPARTAGES` (the tie-break list) is individual criteria only.
- **The files.** 48 real files, SWAR v5.34 to v7.05, all parse to one of
  those nine types, and all end exactly at the last player's rounds.

What SWAR does have for team competitions is two ways of running one as an
individual event, and the import handles each:

| SWAR feature | What the file holds | What the import does |
|---|---|---|
| **Team mode** (v4.45, `PairingManual.cpp`, asked for by Luc Cornet): an ordinary Swiss (type 0) whose name contains `" - team"`, or whose file is named `"... - team.swar"` | the individual games only. SWAR stops pairing the event and reads each round's boards from a text file of player-number pairs (`<name>.R01.C01.txt`) made elsewhere; which team each player plays for, the board order, the matches and the team scores are not in the `.swar` | asks first (`SwarImport.team_marked?/2`, SWAR's own test, case-sensitive): the organiser can import the games as an individual tournament, or set the team tournament up here |
| **Club or nationality exclusion** (`[EXCLUSION]`, "ICN style" in SWAR's manual - schools, the NATO event): an individual Swiss in which players of one club, or one nationality, never meet | the rule | carried over onto the club/federation exclusion rules and forbidden pairings (below) |

Two checks guard the places a newer SWAR could start writing teams:

- **a tournament type outside the nine** is refused
  (`SwarImport.check_importable/1`, run by `prepare_import/2` and
  `import_file/3`, not by the norms tool's `build_structs/1`) - it used to
  import silently as a Swiss, and a type never seen may score or pair
  differently;
- **data after the player list** is imported without it, with a warning
  that gives its size and the SWAR version and asks for the file
  (`trailing_data_warnings/1`). It was refused for a while; everything
  before it reads exactly as always, so refusing only cost the organiser
  their tournament.

If either ever fires on a real file, that file is the sample a team import
would need.

### `[EXCLUSION]` is imported

It used to be read and dropped. SWAR's `USE_EXCLUSION` (`Swar.h`) and what
`EnvoiJAVAFO.cpp` makes of `Exclusion.Values`:

| SWAR | Values | Here |
|---|---|---|
| -1 none | | nothing |
| 0 players | `"1,4:12,15,21"` - groups of player numbers; every pair within a group never meets | forbidden pairings, every pair within each group |
| 1 listed clubs | `"618:621"` - club numbers | club rule "listed", by the names of the players holding those numbers |
| 2 listed nationalities | `"BEL:FRA"` | federation rule "listed" |
| 3 every club | | club rule "all" |
| 4 every nationality | | federation rule "all" |

Two differences, both toward what the file says rather than what SWAR's code
does with it:

- SWAR groups clubs by **number** (`BuildAllClub`, formatting even club 0 as
  a club), this app by **name**. Where the two groupings would keep a
  different set of players apart - a club spelled two ways, two clubs with
  one name, several players without a club number - the import says so.
- Every-nationality does nothing in SWAR v6.65 (`BuildAllNat` is empty -
  [swar-source-audit-2026-09-09.md](swar-source-audit-2026-09-09.md), F2).
  The file asks for it, so it applies here.

The export writes the section back (`SwarExport.exclusion_for_export/3`):
one rule alone as SWAR's own, forbidden pairs as the groups they came from,
and anything SWAR's single rule cannot say - two rules at once, or a club
rule SWAR's club numbers would group differently - as groups of player
numbers that keep exactly the same players apart, with a note on the export
page. See "Import and export: what goes where".

### The sample that would settle a team import

A team import needs evidence of where the team layer is kept. The file that
would provide it, if one exists:

1. a `.swar` from a real team competition in SWAR's team mode - tournament
   name ending in `" - team"`, at least two rounds played, with a bye or a
   forfeit - **together with** its round pairing files
   (`<name>.R01.C01.txt`, ...) and whatever the organiser kept the teams,
   board order and match results in (the TeamChess spreadsheet in SWAR's
   own `DocLocal`, or similar); or
2. any `.swar` that this import refuses as an unknown type or for data after
   the player list - a newer SWAR's own team format, if it has one.

## File versions, and what SWAR v7 changed

The format is a sequential binary serialization with no index: every field
is read in exact order, and a single field of drift turns the rest of the
file into garbage. Each release that adds or removes a field therefore needs
a version gate in `federations/bel/swar_import.ex` (`version_gte?/2`,
against the version string in the file header - `"v6.78"`, `"v7.04"`, …).

**v7 removes three things** relative to v6, which is why v6-era code fails
on a v7 file with a `{:parse_failed, ...}` on a nonsense string length:

| Section | v6 | v7 |
|---|---|---|
| `[TOURNOI]` tail | FIDE-id block (16 × 3 ints) + 4 trailing strings | 12 bytes shorter |
| `[JOUEURS]` | `Elo` **and** `EloFide` | `Elo` only |
| `[JOUEURS]` | `NbParties`..`Perf` run includes `Pts_Corr` (v6.49+) | one int shorter |

Two of those carry a caveat worth knowing before trusting a v7 import:

- **Which 12 bytes left `[TOURNOI]`** can't be determined from the v7 file
  this was reverse engineered against, because that whole region is zeroed
  in it: "three of the four trailing strings are gone" and "the FIDE-id
  block is one 3-int entry shorter" are byte-for-byte identical on zeroes.
  They only diverge once a v7 file turns up with a non-empty FIDE arbiter id
  or remark. `parse_tournoi_section/2` therefore tries both and keeps
  whichever leaves the parser looking at the `[DATES]` marker that must
  follow - so either reading imports correctly, and a file matching neither
  fails loudly instead of silently shifting every field after it.
- **Which int left the `NbParties`..`Perf` run** is likewise unprovable from
  it (the tournament hadn't started, so every int in that run is zero). It's
  read as `Pts_Corr` being the one dropped, which fails safe: `Pts_Corr` is
  the only field of that run this importer reads at all, so guessing wrong
  can't shift anything persisted - at worst it silences the advisory
  `points_adjusted_warnings/3`. To settle it, re-export a **played** v7
  tournament and check whether `points`/`perf` land where expected.

`EloFide` is the one v7 change that needed a judgement call rather than a
gate. Belgium retired its own rating list - the KBSB export's `Elo` column
is zero for everyone now - so the single Elo a v7 record still carries *is*
the FIDE rating. Verified against the local FIDE database: across the 126
players of a 128-player v7 open that resolve by `fide_id`, that Elo tracks
`standard_rating`, differing only by the month between SWAR's rating list
and ours. `parse_player/2` mirrors it into `elo_fide` so `fide_rating_or/1`
keeps working instead of filing every v7 player as unrated.

## Verified against the real source, and two real v7 files

Everything in this file up to here was reverse-engineered from `.swar`
files and cross-checked against our own reader/writer agreeing with each
other - real evidence, but not proof a genuine SWAR install reads what we
write the same way. Since then, two more real artifacts turned up and are
worth recording:

- **The actual SWAR v6.65 FRBE C++ source** (`TournoiReadWrite.cpp`,
  `Base.cpp`, `Joueur.cpp`, …) - not just a `.swar` file to guess from, the
  literal read/write code. Checked field-by-field against `SwarImport`'s
  `parse_player/2` and `SwarExport`'s `reverse_player/6`: the `[RONDE]`
  record (`round_nr`/`table`/`advers`/`result`/`color`/`float`/`xtra_pts`,
  all `int32`, in that order) matches exactly, as does the surrounding
  player-record field order - both confirmed correct, not just
  self-consistent.
- **Two genuine SWAR-native `.swar` files, not an OpenPairings export** -
  `v7.02` and `v7.04`, one with a populated `Arbitre2` field, the specific
  "does a v7 file exist with non-empty data in the ambiguous `[TOURNOI]`
  tail" case `parse_tournoi_section/2`'s own comment flagged as untested.
  Both parse cleanly end to end - every player's name, club, rating and
  round history reads as real, plausible data all the way to the last
  player in a 128-player roster, not garbage partway through. (Neither
  happened to have FIDE homologation turned on, so the FIDE-arbiter-id
  question specifically is still open - everything else in the file
  format that a non-homologated tournament touches is now confirmed, not
  just self-consistent.)

This is also where the real "genuine absence" numbers referenced
elsewhere in this codebase's history came from: a real historical SWAR
file with `AbsValue` genuinely checked (`abs_value: 1` → half a point),
capped to the first absence (`abs_nbfois: 1`) through round 3
(`abs_jusque: 3`) - confirming those three fields really do get used with
real, non-default, non-zero values in the wild, not just in theory.

## Officials: what SWAR carries, and what it doesn't

SWAR stores officials as free text in two `[TOURNOI]` fields, with a grade
prefix and **multiple people comma-separated in one field**:

```
Arbiter1 = "IA Luc Cornet"
Arbiter2 = "IA Sylvin De Vet, NA Marc Van Dyck"
```

That's the opposite convention to FIDE's "Last, First", so within these fields
a comma is a *person* boundary, never a name boundary - which is what makes
splitting on it safe here and nowhere else.

On import (`swar_officials/1`, `strip_arbiter_title/1`):

- the grade (`IA`/`FA`/`NA`/`IO`/`NO`/…, including stacked ones) is stripped -
  FIDE stores names without them, and they'd otherwise land in an IT3 name cell
- `Arbiter2` is split into the numbered `deputyN_name` slots the IT3 form
  (B62-B69) expects; `deputy_arbiter` keeps the original free text verbatim for
  exports
- each name is matched against the local FIDE database to fill in
  `deputyN_fide_id` / `chief_arbiter_fide_id`

Matching compares an **order-independent token set**, because SWAR writes
"Sylvin De Vet" and FIDE stores "De Vet, Sylvin"; sorting the diacritic-folded
tokens makes those equal without having to guess which words are the surname.
As everywhere else in this importer, an ambiguous name is **left blank rather
than guessed** - BEL has two `Van Dyck, Marc`, so that deputy imports with a
name and no id, for a human to disambiguate on the Norms page.

This same matcher (`SwarImport.match_official_fide_player/1`, public for
exactly this reason) is reused on the public Tools page's upload prefill -
see [`tools.md`](tools.md)'s "Officials: FIDE lookup" section - except there
a non-match doesn't even leave the raw name in the field: the box stays
empty with a hint, since that page never has the fallback of "fill it in
by hand on the Norms page later" this persisting path does.

**Not in the SWAR file at all:** the organizer's FIDE ID, and any e-mail
address. SWAR has an organizer *name* (`Organizer`) but no id for them, so
those fields on the Norms page always start empty and are filled in by hand.

### FIDE event code

`[TOURNOI]`'s FIDE block holds up to 16 homologation entries, each with a
tournament id - one for a plain event, several for a festival rated in
sections. Import takes the distinct non-zero ids in file order and joins them
(`"111, 222"`), since `event_code` is a single free-text field on both our
schema and the FIDE forms; deleting the one that doesn't apply is recoverable,
silently keeping only the first is not.

> **Unverified against real data.** Every entry in that block is zeroed in the
> only v7 file available, so this is covered by synthetic fixtures only. If an
> imported event code ever looks wrong, this is the first thing to re-check
> against a genuinely homologated file.

### Reports are gated on complete officials

FIDE identifies every official by FIDE ID and bounces a report missing one, so
`NormsLive.report_blockers/1` blocks the IT3/FA1/IA1 downloads (red bar, naming
each missing field) until the chief arbiter and every *named* deputy has one,
**and** the chief arbiter's and organizer's e-mail addresses are both filled
in - the IT3 template's own printed privacy notice states FIDE requires both.
An empty deputy slot is fine - not every event has two.

## Rate of play (`Cadence` / `Cadence_Other`)

`Cadence` (manual field 88) is a 0-based index into one of **three** dropdown
lists SWAR's own UI fills at runtime - which list applies depends on the
sibling `TournoiStd` field (0=Standard/1=Rapid/2=Blitz, the same field
`map_standard/1` reads). None of this is in the binary-format notes this
importer otherwise leans on; the mapping (`SwarImport.cadence_label/2`,
`@std_cadences`/`@rap_cadences`/`@bli_cadences`) was reverse-engineered
directly from **SWAR's own C++ source** (`Utils.cpp`'s `GetCadence/2` +
`Languages/Swar.Lang.fr.ini`'s `[CADENCES]` section) rather than inferred
from a `.swar` sample, since the integer alone carries no information without
that table.

`Cadence_Other` (free text) is only meaningful for the list's own last entry
("autre cadence" / "Other cadence") - SWAR's UI itself detects "Other" by
comparing the current label against the list's last entry, not a fixed
sentinel index, so `cadence_label/2` deliberately leaves that last index out
of each table and returns `nil` for it. `tournament_attrs/1` maps
`rate_of_play` as `cadence_label(t.tournoi_std, t.cadence) || t.cadence_other`
- the dropdown pick wins whenever it resolves to something, `Cadence_Other`
only fills in for "Other" (or, defensively, an index outside all three known
tables).

## Two ids per player: national vs. FIDE - never crossed

Every SWAR player record carries **two separate identifiers**, read from
two separate fields (`MatNat` and `MatFide`) at fixed, adjacent offsets in
the binary layout:

| SWAR field | Meaning | Maps to |
|---|---|---|
| `MatNat` | the player's national federation number (KBSB/FRBE membership id) - short, typically well under 100,000 | `players.national_id` (stored as text) |
| `MatFide` | the player's FIDE id - the number used on ratings.fide.com. Historically 6-8 digits; **FIDE now issues 9-digit ids too** (e.g. 551061350), so don't treat a long value here as a sign of a misparse | `players.fide_id` |

This mapping has been cross-checked against real ratings.fide.com profiles
(not just the bundled test fixtures) - e.g. `test/fixtures/c-reeks.swar`'s
`MatFide` value for "Waegeman, Willem" is 292052, which is in fact
ratings.fide.com's profile for that exact player (federation Belgium, born
1982). The two fields are read once, in a fixed position, and used exactly
once each, by name (`p.mat_nat` → `national_id`, `p.mat_fide` → `fide_id`)
in `create_players/3` - there is no code path anywhere in this module that
copies one into the other, or falls back from one to the other.

If a future SWAR export still shows the wrong id in the wrong field,
suspect a *different* SWAR file version with a shifted binary layout
before suspecting this mapping - the field read order is not
version-branched today (unlike several other `[TOURNOI]`/`[JOUEURS]`
fields, which are, see the version-gate comments in
`federations/bel/swar_import.ex`).

## Players with no FIDE id: matching against the local FIDE database

Real SWAR files routinely have players with `MatFide == 0` - SWAR simply
has no FIDE id on file for them (this is normal, not a parsing error; see
e.g. `c-reeks.swar`'s own "Vanmassenhove, Claude" and "Cobert, Quinten").

For each such player, the importer searches the local FIDE database
(`PairingsEngine.Fide.FidePlayer`, synced separately - see `lib/pairings_engine/fide/`)
for an **exact** match on name (case-insensitive, "Last, First" as both
sides already store it) + federation + birth year:

- **Exactly one exact match** → adopted automatically: `fide_id`, `title`
  (only if the FIDE database has one), and `fide_rating` (only if SWAR's
  own `EloFide` was 0 - SWAR's own nonzero rating always wins, since it
  reflects the rating *at the time of the tournament*, not today's).
- **No match, or more than one same-name-and-federation candidate (with a
  different or unknown birth year)** → left for a human to resolve. The
  candidate list still surfaces same-name/federation matches regardless of
  birth year, so "right person, wrong year on one side" is a one-click
  pick rather than a dead end.

`name` is never touched by a FIDE match, in either case - SWAR's own
spelling is always canonical (a FIDE-database name is sometimes a
different transliteration/spelling of the same person).

### What counts as "the same name", and how wide the search goes

Two deliberate widenings, both of which only ever grow the *candidate list* -
the auto-adopt rule above is unchanged:

- **Diacritics are folded**, not just case. SWAR carries whatever the arbiter
  typed while the FIDE list is inconsistent about accents, so a plain downcase
  made "Müller" and "Muller" two different people - and the player then showed
  up with *no candidates at all*, which reads as "not in FIDE" rather than
  "spelled differently". Same folding the `fide_players_fts` index uses
  (`remove_diacritics 2`), so the index and the comparison agree.
- **Federation is no longer a hard filter.** Candidates were scoped to the
  player's own federation, which left a transferred player (or one whose SWAR
  country simply disagrees with FIDE's) with an empty list and no way to
  resolve them by hand. When the same-federation search finds nothing, the
  search widens across all federations via the FTS index. Auto-adopt stays
  federation-scoped, so a cross-federation hit still has to be picked by a
  human.

A player genuinely absent from the rating list gets no candidates, and that's
correct. Worth knowing when judging "but they're in FIDE": the downloaded list
is **not** just rated players - roughly 70% of its ~1.9M rows have no standard
rating - so absence really does mean "no FIDE id", not "unrated".

### The two-step API and the confirm step

- `SwarImport.prepare_import/1` parses the file and resolves everything it
  can automatically, returning `{:ok, %{data: ..., unresolved: [...]}}`.
  `unresolved == []` means every player is settled.
- If `unresolved != []`, `PairingsEngineWeb.TournamentsLive` shows a
  "Resolve FIDE ids" step listing each unresolved player with their
  candidates as radio choices, plus "import without a FIDE id". Nothing is
  written to the database until this is confirmed.
- `SwarImport.commit_import/3` takes the prepared data plus the user's
  choices (a `%{ni => fide_id_or_nil}` map, keyed by the player's SWAR
  internal number) and performs the actual import, in one transaction,
  exactly like before this confirm step existed.
- `SwarImport.import_file/2` is kept as the original one-step,
  non-interactive entry point (used by tests and any future
  non-interactive caller): the same auto-matching runs, but anyone left
  unresolved is simply imported without a `fide_id` - there's nobody to
  ask.

## Other per-player field fixes

- **Full birth date.** SWAR stores birth as `YYYYMMDD` (`"19000101"` is its
  placeholder for "unknown"). `players.birth_date` now carries the full
  date when known, kept in sync with the year-only `players.birth_year`
  (both derived from the same source field). A known year with an
  unknown/zeroed month or day still sets `birth_year` even though
  `birth_date` falls back to `nil`.
- **Federation is always a FIDE country code.** SWAR's own
  `[TOURNOI] federation` field identifies *which Belgian federation
  entity* organizes the tournament (FRBE/KBSB - the federation itself,
  language variants; FEFB/VSF/SVDB - its Walloon/Flemish regional leagues;
  "direct FIDE homologation" with no sub-federation) - none of these are
  actual ISO/FIDE country codes, and this importer only ever sees
  KBSB/FRBE-organized tournaments, so all of them normalize to `"BEL"` for
  both `tournament.federation` and each `player.federation`. TRF export
  reads these fields directly, so a raw league marker there would produce
  an invalid TRF file.

## Absence scoring: SWAR's "Pt ABSENT" (`AbsValue`/`AbsJusque`/`AbsNbFois`)

A player marked genuinely ABSENT for a round (SWAR's `TABLE_ABSENT`, as
opposed to a pre-arranged bye - see "Requested bye vs. genuine absence"
below) can still be paid points for it, but SWAR's own "Pt ABSENT" club
option caps that three separate ways, all three read from the general
`[TOURNOI]` header (unconditional on tournament type, unlike the 3-2-1
fields below):

- **`AbsValue`** - whether the option is on at all. Confirmed against
  SWAR's own source (`TOptions.cpp`'s `TOptionsGetValues`): this is a
  plain UI checkbox, raw `0` (unchecked) or `1` (checked) - checked pays
  `0.5` points. **A previous version of this importer mapped raw `5` to
  `0.5`** (the `Tournament.abs_value` field's own doc comment said "UChar:
  0 or 5"), which happened to satisfy every synthetic test fixture (they
  all hardcoded the test input as `5`, since nobody had checked it
  against a real file with the box actually checked) but silently scored
  every real absence-paying tournament as if the option were OFF - raw
  byte `1` doesn't equal `5`, so `abs_value` always came out `0.0`. Caught
  by importing a real production `.swar` file (`AbsValue: 1`) whose
  organizer had confirmed the box was checked (0.5 points, through round
  7) and finding the imported tournament scored those absences as zero.
  The stale "0 or 5" comment traces to `Swar.h`'s
  `enum USE_POINTS { PTS_1, PTS_5, PTS_0 }` - `PTS_0`'s ordinal value is
  `2`, not `0` or `5` either, and that enum describes the unrelated,
  pre-v4.21 `AbsValueOld` field this one replaced; the "5" was never a
  real byte value SWAR writes for this field.
- **`AbsJusque`** ("jusque ronde", "until round") - the last round,
  **inclusive**, an absence still pays `AbsValue`. Round `AbsJusque + 1`
  onward scores a plain loss instead, same as if the option were off.
- **`AbsNbFois`** ("nombre de fois", "number of times") - how many
  absences, cumulative across the tournament **up to and including the
  round being scored**, still pay `AbsValue`. The `(AbsNbFois + 1)`th and
  any later absence scores a plain loss instead, even if it's still
  within `AbsJusque`.

Both caps are read from the file even when `AbsValue` is unchecked - SWAR
itself resets both to `0` in that case (`TOptionsGetValues`), which is
also what makes `AbsJusque: 0` correctly fail every round's cutoff check
without a separate "is this feature even on" flag needed on our side.

Mapped onto `Tournament.abs_jusque`/`abs_nbfois` (plain integers, `nil` for
every non-SWAR-import tournament) and enforced in
`PairingsEngine.Standings.bye_points/4`'s `"absent"` branch - see that
function's doc for the exact precedence, and `bye_points_for_row/2` for
the version display code (`PairingsEngineWeb.PairingsLive`/`LiveRoundLive`/
`PublicPairingsLive`/`PrintController`) should call instead of working out
the cumulative count itself.

All three fields (`abs_value`/`abs_jusque`/`abs_nbfois`) are also settable
by hand, for a tournament with no SWAR file at all, on
`PairingsEngineWeb.SettingsOptionsLive` (`/t/:id/settings/options`, the
"Scoring" card) - blank means the same "not applicable"/"no cap" nil does
here. Like the pairing-shape controls on that same page, all three lock
(greyed out, server-side enforced regardless of the HTML `disabled`
attribute) once round 1 has been paired - not because changing them later
would corrupt anything (scores are computed live from these fields, never
baked into a stored row), but because a tournament that far along is
presumably still being run under whatever rule it started with, and
silently changing who's owed points partway through would be confusing.

### Requested bye vs. genuine absence - two different `byes`-table rows

Easy to conflate, so worth stating plainly: a **requested bye** (arranged
with the arbiter ahead of the round, SWAR's `WIN_BYE`/`DRAW_BYE`/
`LOST_BYE` result codes) and a **genuine absence** (`TABLE_ABSENT`, no
result code at all - the player just didn't show and nobody arranged
anything) are different `byes`-table rows with different scoring rules,
and always have been (`federations/bel/swar_import.ex`'s
`classify_unpaired/1`):

- Requested: `type: "requested-half"` / `"requested-zero"` - scored at
  `points_draw` / `presence_value || points_loss`, from SWAR's `ByeValue`
  (or `SW321_Bye` for a 3-2-1 tournament).
- Genuine absence: `type: "absent"` - scored at `abs_value`, subject to
  the `abs_jusque`/`abs_nbfois` caps just described. Never affected by
  `ByeValue`.

### Rounds before a late entrant joined

SWAR has no "joined in round N". A player added after rounds were paired
gets a round record for every one of them, `Table = TABLE_ABSENT`, no
opponent, no result (`JoueurInit`, Joueur.cpp:581-596) - an absence like
any other. `GetPoints` pays it `AbsValue` under both caps
(Utils.cpp:1254-1257 via `GetSpecialAbsValue`, 1159-1170) and
`GetNbAbsence` counts it towards `AbsNbFois` (1102-1118), so those rounds
use up the allowance. Only a 3-2-1 event differs: `GetPoints` scores it
with `ConvertPoint321` and never pays `AbsValue` (1232-1234).

On import those records are ordinary `"absent"` rows (the players keep
`start_round` 1), so a file's late entrants score exactly what SWAR stored -
and, having a row in round 1, are never given a worked-out join round
(`LateEntry.effective_start_round/4`).
The import also sets the tournament's `late_entry_absences` to what SWAR
does - on, off for 3-2-1 - which decides what the rounds before a player's
`start_round` count as for a player added here afterwards (see
`PairingsEngine.LateEntry`). The export writes those rounds back as SWAR's
own absence record when they count as absences, and as a plain not-played
record otherwise - never leaving them out: SWAR finds a round by its
position in the player's array, so a missing round 1 shifted every later
round. A declared absence is written the same way SWAR writes one
(`TABLE_ABSENT`, Advers -1); it used to go out as a zero table, which SWAR
neither pays nor counts.

## Tiebreaks: three places our numbers legitimately differ from SWAR's

Everything above is about reading the file correctly. This section is about
the case where the file was read correctly and **the printed numbers still
disagree** - where OpenPairings' Buchholz Cut-1 column and SWAR's Buchholz
Cut-1 column, on the same tournament, are different numbers.

The first two of these are deliberate on both sides. **SWAR is not broken
there**: it implements a Belgian convention that predates the current FIDE
text and documents it to its own users. The third is different in kind - it
is a SWAR bug, not a house convention, and it is worth knowing that too,
because "both programs are right" is not always the honest answer and an
arbiter deserves to be told when it isn't. OpenPairings implements FIDE C.07
as written throughout.

Read this before answering a "your tiebreak is wrong" report. The source
citations are in
[swar-source-audit-2026-09-09.md](swar-source-audit-2026-09-09.md),
[swar-source-audit-pass2-2026-09-09.md](swar-source-audit-pass2-2026-09-09.md)
and
[swar-source-audit-pass3-2026-09-09.md](swar-source-audit-pass3-2026-09-09.md);
what follows is the arbiter-facing summary.

### 1. SWAR cuts fewer results than "Cut-1"/"Cut-2" names, and cuts none at all before round 5

**This is the one that moves numbers for everybody**, not just for a player
with something unusual on their card.

`TieBucholtz` (`Classement.cpp:1131-1286`) does not take the cut count from
the tiebreak. It computes one up front, from the number of rounds played
(`Classement.cpp:1144-1154`), as `min((rounds played - 1) / 4, n)` with `n`
being 1 for Cut-1 and Median-1 and 2 for Cut-2 and Median-2. Integer division:

| Rounds played | SWAR's Cut-1 / Median-1 drops | SWAR's Cut-2 / Median-2 drops |
|---|---|---|
| 1-4 | **0** | **0** |
| 5-8 | 1 | **1** |
| 9 or more | 1 | 2 |

A zero makes the whole drop loop (`Classement.cpp:1276-1282`) a no-op. So a
tournament configured for Buchholz Cut-1 **shows plain Buchholz for its first
four rounds, and forever if it is a four-round event**, and a **seven-round
event configured for Cut-2 never cuts more than one result**, including in the
final standings that decide the prizes.

**It is deliberate and it is documented to arbiters.** SWAR's code attributes
the scheme to Luc Cornet, the KBSB's tiebreak authority, and dates it to v3.93
(`Classement.cpp:1121-1125`). SWAR's own arbiter manual carries a footnote on
all four variants saying that for rounds 1-4 SWAR removes no results at all
(`(**)`, "on enlève pas de résultats"), one from round 5, and two from round 9
- and the table rows themselves say the count follows the number of games
played. So Belgian arbiters using SWAR have been told this is how it works,
and it has worked this way since long before the version audited here.

**What OpenPairings does.** `tiebreak("BHC1"/"BHC2"/"MBH", ...)`
(`standings.ex`) calls `cut/3` with a fixed count of 1, 2, and 1-high-1-low.
There is no round-count term anywhere in the calculation, at any point in the
tournament.

**Which the regulations support: OpenPairings.** C.07's Cut modifiers
(Article 14.1) define Cut-1 as cutting one contribution and Cut-2 as cutting
two. Nothing in the regulation makes the count a function of the round number.
SWAR is applying a national convention on top of a FIDE tiebreak while keeping
FIDE's name for it, which is a house choice it is entitled to make and is not
the same tiebreak C.07 describes.

**Who this reaches.** Everyone, in the events this importer exists for.
Belgian club and weekend tournaments run 5 to 7 rounds; on Cut-2 every player
in one of those has a different number in the two programs. On Cut-1 - which
is **FIDE's own first tiebreak for a Swiss**, and therefore what a new
tournament here starts with (`Tiebreaks.fide_defaults/1`) - a four-round event
diverges for every player. And in a longer
event the mid-tournament standings diverge even where the final ones agree: a
nine-round Swiss on Cut-2 prints plain Buchholz from SWAR after rounds 1-4,
Cut-1 after rounds 5-8, and Cut-2 only at the end.

**The one-line answer:** SWAR's Cut-1 and Cut-2 scale the number of cuts to
the number of rounds played and cut nothing before round 5; ours cut what the
FIDE tiebreak name says, always. If the Belgian convention is what the
tournament regulations actually announced, that is a display convention to
record in the regulations, not a defect here - and if it is ever wanted in
this app it belongs behind a per-tournament switch, not inside the FIDE codes.

### 2. SWAR drops the cut entirely for a player who was declared absent

The second divergence only moves numbers for players with an absence - but
where it applies, it applies to a whole tiebreak.

**Buchholz Cut/Median variants.** `TieBucholtz` gates the entire
drop-lowest/drop-highest block on the player having had no declared absence at
all (`Classement.cpp:1275`, `if (Dep > DEP_BUCHOLTZ && nbAbsent == 0)`, over
the block at `:1273-1283`). So a player with one or more absences gets **plain
Buchholz reported in the Cut-1 column**. The extent, mapped in full by the
second audit:

- **Only the four cut/median variants.** Plain Buchholz has no drop to
  suppress, and Sonneborn-Berger is a different function and is untouched.
- **Only a declared absence** (`TABLE_ABSENT`). A pairing-allocated bye does
  not suppress the cut, a withdrawal does not, and a forfeited game at a real
  board does not. This is narrower than it first looks.
- **Per player.** Everyone else in the same tournament still gets their cuts.
- **Invisible before round 5**, because of the divergence above - there is no
  cut to suppress yet.

**ARO-Cut1, with a much wider trigger.** `TieAro` (`Classement.cpp:335-382`)
performs its cut only when a flag is clear (`:373`), and four separate things
set it: an unpaired round, no opponent, **any** unplayed result including a
forfeit at a real board, and - the one nobody guesses - **a single unrated
opponent** (`elo == 0`). SWAR's own comment at `:329` gives the reasoning for
the first group: a bye or an absence is treated as a Cut-1 already taken.

**What OpenPairings does.** `cut/3` and `drop_lowest_with_vur_priority/2`
always perform the configured number of cuts, and implement Article 16.5.1 as
what it says it is - a **preference** about which contribution to cut, taking
a voluntary-unplayed-round contribution first where one exists. `aro/3` cuts
unconditionally. The unrated case is answered one level up and much more
loudly: `Standings.effective_tiebreaks/2` **drops ARO and ARO-Cut1 from the
whole tournament** when any unrated player is entered, and
`dropped_tiebreaks_with_reasons/2` puts the reason on the page rather than
silently showing one fewer column.

**Which the regulations support: OpenPairings, on both halves.**

- Article 16.5.1 is a rule about *which* contribution to cut when a cut
  applies. It is not a licence to skip the cut, and SWAR's own comment cites
  an internal analysis document rather than a FIDE article.
- Article 16's opening sentence names its own scope - Buchholz,
  Sonneborn-Berger and their variants - and **ARO is not in it**, so 16.5.1
  does not reach ARO-Cut1 at all.
- For the unrated opponent, Article 10's answer is that the rating-based
  tiebreak is dropped from the tournament unless the arbiter published a rule
  in advance. It gives no substitute rating and no "leave that opponent out of
  the average". Quietly excluding one opponent from one player's average is
  inventing the rule FIDE declined to write; the long note above
  `effective_tiebreaks/2` in `standings.ex` argues this at length.

**Where the two agree by coincidence, and where they visibly do not.** For the
common case - one absence, Cut-1, from round 5 on - skipping the contribution
and cutting it come to the same number, so nobody notices. They diverge for
Cut-2 with one absence (SWAR performs one effective cut, we perform two) and
for any player with two or more absences under any cut variant. On ARO-Cut1
with an unrated player in the field the difference is not a number at all:
SWAR prints an uncut average, and this app prints no ARO column and a line
saying Article 10 is why.

**The one-line answer:** for a player with a declared absence, SWAR reports
plain Buchholz in the Cut column by design; we cut, and prefer to cut the
unplayed round, which is what Article 16.5.1 asks for.

### 3. SWAR's mid-round tiebreaks can run a round ahead of ours, for players who haven't played that round yet

This one only shows up while a round is still being entered. It disappears
the moment the round finishes, and it never affects a tournament's final
standings.

**SWAR's round horizon is "at least one result reported this round", not "all
of them".** `GetLastRoundWithResult` (`Utils.cpp:652-662`) scans backward and
returns the first round with any real result in it at all - its own comment
says so: "la dernière ronde possédant **au moins un** résultat". That value is
not a display number; it is the literal loop bound (`LastRoundWithResult`,
recomputed every time standings are shown, `Classement.cpp:1368`) inside
*every* tiebreak in `Classement.cpp` - Buchholz, Sonneborn-Berger, Koya, ARO,
even a player's own raw point total. None of those loops test whether the
specific game being summed was actually decided, only whether the player was
paired that round at all.

**Concretely:** the moment one board in the newest round reports a result,
every player who was paired that round - not just the two on that board -
has the round folded into their Buchholz and Koya numbers, using opponents
whose own games in that same round may still be unplayed.

**What OpenPairings does.** `completed_rounds/2` (`standings.ex`) requires
every pairing in a round to have a result before the round counts at all. This
is not a house-convention difference the way the first two items are - an
earlier version of this codebase had exactly SWAR's bug (`rounds_played_count/1`,
long since replaced), found because it let one reported board give every other
player in the round a phantom result. `completed_rounds/2` exists specifically
to close that hole.

**Which the regulations support:** OpenPairings. This isn't a case of two
defensible readings - full detail, including why it reads as an unintentional
bug in SWAR rather than a deliberate choice, is in
[swar-source-audit-pass3-2026-09-09.md](swar-source-audit-pass3-2026-09-09.md#1-f23--swars-tiebreak-horizon-moves-the-instant-one-board-reports).

**The one-line answer:** if the two programs' live standings disagree
mid-round, check whether every board in the newest round has reported yet -
if not, that's why, and both sides will agree again once it has. This does
not affect final results.

### What not to do about any of these

Do not change the calculations toward SWAR. All three audits landed on the
same answer, and the regulations are on this side throughout - including
item 3, where SWAR's own comments disagree with each other about what the
code is supposed to do. The value of this section is that it turns a
*predictable* support report into a one-line answer instead of a
re-derivation from SWAR's source, which is what producing the answer the
first time actually took.

The audits carry further, smaller divergences. One of this kind - the `WIN`
tiebreak counting a full-point bye here and not in SWAR - and one that is
not: in a 3-2-1 tournament SWAR computes the Koya threshold and several
other tiebreaks on the classic 1/0.5/0 scale while the scores themselves are
on the club's own, so there it is SWAR's number that is wrong. Neither is
worth an arbiter's attention until it is reported; both are cited in the
audit documents.

A related item used to sit in this same "leave it, it's small" list: a
round-robin bye scoring a full point in SWAR where the file itself says
zero. That one is no longer left alone - see the next section - because
unlike the two above it is not a case of two defensible readings of the
same rule; it is this importer not reading the file the way SWAR itself
does.

### Measured: SWAR's own stored standings, re-ranked here (2026-09-27)

Every `[JOUEURS]` record carries SWAR's own place (`Class`), score and five
tie-break values as `CalculLeClassement` left them when the file was saved.
`tools/swar_rerank.exs` imports each file through this module into a
throwaway database, ranks it with `Standings` (Ainalrami's tie-breaks), and
compares - with a port of SWAR v6.65's `Classement.cpp` beside it, so a
difference can be called SWAR's algorithm (the port reproduces SWAR's
number) rather than guessed. The run and its report stay outside the
repository; the files are real events.

On the SWAR archive at hand (43 files compared, 13 of them finished events)
the port reproduced every stored value of every file saved by v6.49-v6.77
(bar the direct-encounter number of one part-played round robin; older
files and v7 compute Buchholz and SB differently), and every rank
difference in a finished event came down to one of these:

* **C.07 2024 vs 2026.** SWAR's Article 16.4 dummy is the player's own
  score, uncapped - the 1 August 2024 text. The 2026 text caps it (16.4.1
  at a forfeit opponent's adjusted score, 16.4.2 at a draw per round).
* **SWAR defects, in both texts.** `TieBucholtz` compares an opponent's
  forfeit opponent with the player's *Rank* instead of their *Ni*: a forfeit
  opponent is counted as if played (on top of the dummy), and a played
  opponent who forfeited against somebody else is left out. Trailing forfeit
  losses count as draws in the adjusted score (16.3.2 covers requested byes
  only). `TieSonneborn` ignores an opponent's single last-round absence
  (SWAR's own Buchholz does not). Cut-1 never cuts the dummy.
* **The Belgian conventions above**: cut count scaled by rounds played, no
  cut for a player with an absence; `WIN` without the pairing-allocated bye;
  black games counted whatever the result.
* **Categories ranked separately** (`CatSepares`): SWAR ranks, and applies
  direct encounter, per category; this app ranked one field. A file of
  several round-robin groups in one tournament is the case that shows it.
  **Fixed since** - see below.
* **Extra points**: SWAR ranks a Swiss on points plus `ExtraPts`; an import
  left `count_extra_points` off (docs/extra-points.md). **Fixed since** -
  the import switches it on for such a file.

Three import defects it found are fixed: a v6.50 file with 12 categories
did not import at all (`parse_categories/2`), a round robin kept
`pairing_system: "swiss"` and was ranked by C.07's Swiss rules
(`system_attrs/1`), and a round SWAR had prepared but not paired came in as
a finished round of absences (`drop_unpaired_rounds/1`).

**After the SWAR import and export were completed (2026-09-27).** The two
causes marked fixed are gone: a file with SWAR's separate categories
imports ranked per category (`categories_ranked_separately`), and one with
extra points counts them (the first run already counted them by hand, so
that part changes no number). Re-run over the same archive, now 44 files
compared (SWAR's 333-player "TOURNOI ZERO" player list imports now):

| | before | after |
|---|---|---|
| finished events, ranks equal | 424 / 456 | **436 / 456** |
| finished events, tie-break values equal | 1848 / 1995 | **1890 / 1995** |
| unfinished events, ranks equal | 926 / 1543 | 1170 / 1876 (+ the 333-player list) |
| unfinished events, values equal | 5450 / 6273 | 5446 / 6273 |

The 16-group round-robin club event went from 16 rank differences to 4.
Its last two discordant pairs are C.07, not SWAR: one pair level after the
whole tie-break list (C.07 shares the place; SWAR orders by seed, this app
by rating), and one pair C.07 Article 6.2 separates by applying direct
encounter again to the two players left level, where SWAR's `TieBetween`
counts it once for the whole tied group. Every other finished-event
difference is in the first three bullets above. The four unfinished-event
values that moved are one SWAR 7.05 file with separate categories, whose
stored direct-encounter numbers count games across categories; this app
now agrees with the v6.65 port of SWAR's own per-category rule there, and
SWAR 7's source is not available.

## Round robin: SWAR forces a bye to a full point, and this import now matches it

**If you import a round robin with an odd number of players, the
pairing-allocated bye is worth a full point here, whatever the file's own
`ByeValue` setting says - because that is what SWAR itself shows for the
same file.**

`TournoiReadStream` (SWAR's file-load routine) forces `Tournoi.ByeValue` to
a full point for every round-robin file, unconditionally, the moment the
file is opened - regardless of what byte `ByeValue` is actually stored as.
A separate, dialog-only forcing to zero also exists in SWAR's Options
dialog code, but it only reaches the tournament if the arbiter opens that
tab and the dialog writes back; the load-path forcing above runs every
time, so it is the one that matters. Confirmed against SWAR's own source -
see
[swar-source-audit-pass2-2026-09-09.md, §3](swar-source-audit-pass2-2026-09-09.md#3-f11--swar-forces-a-round-robin-bye-to-a-full-point-at-load-pass-ones-f8-concluded-the-opposite).

This importer's job is to reproduce the tournament the file describes, and
for a round robin that tournament always has a full-point bye once SWAR has
opened it - so `scoring_attrs/1` mirrors SWAR's forcing rather than the
file's stored value, and an import warning names it whenever the file
actually has a pairing-allocated bye to score (an even-sized round robin
has none, and says nothing).

**This does not touch OpenPairings' own round robin.** A round robin built
and paired here, with no SWAR file involved, still gives its structural
bye zero points (`round_robin.ex`'s `"requested-zero"` row) - a deliberate,
correct choice, since FIDE does not award a point for an odd-player
round-robin bye either. The forcing above only concerns a round robin
**read from** a `.swar` file.

## XtraPoints: SWAR's manual acceleration, and acceleration mode here

SWAR's `[XTRA_POINTS]` band table and each player's `ExtraPts` are not only
a number on a standings column - in SWAR itself they are an input to
**manual acceleration**. `CalculLeClassement` (SWAR's standings routine)
adds `ExtraPts` into the sort unconditionally, and separately,
`AssignExtraPointsNextRound` copies each player's `ExtraPts` into the round
record and writes it into the `.trn` file handed to JaVaFo as an `XXA`
line - so JaVaFo brackets the *next* round by score-plus-acceleration, the
same mechanism Baku uses here, just driven by hand instead of by a formula.
See
[swar-source-audit-pass2-2026-09-09.md, §5.4](swar-source-audit-pass2-2026-09-09.md#54-f13--swars-xtrapoints-reach-the-pairing-engine-openpairings-extra_points-never-can).

Until 2026-09 this app had no counterpart - its extra points were a
handicap that pairing never read - and the import warned that any round
paired here would differ from SWAR's. It has one now: **extra points in
acceleration mode** (`docs/extra-points.md`), and every SWAR file imports in
that mode:

- each player's `ExtraPts` is their extra points, sent to the pairing engine
  as virtual points every round;
- each `[RONDE]` record's `XtraPts` - the value SWAR froze into that round
  when it set it up - is that round's recorded virtual points
  (`rounds.virtual_points`), so the next round paired here hands the engine
  the same `XXA` history SWAR's own `.trn` would have;
- the `[XTRA_POINTS]` table becomes the tournament's bands, which in this
  mode pay players AT OR ABOVE a rating, as SWAR's do (an Elo-0 slot, which
  SWAR's `AssignExtraPoints` stops at and never pays, is left out); the
  table is also still kept in `swar_settings`;
- a file that gives any player extra points imports with "Keep acceleration
  points in the final standings" on, so it ranks on points plus extra
  points exactly as `CalculLeClassement` does.

SWAR's "Remove" (half a point off everyone in a rating range) is "Remove
half a point" on the Extra points page. A round robin or 3-2-1 file has its
extra points and per-round values zeroed, as SWAR's loader zeroes them. The
import note now says what was carried over rather than what was lost.
## Categories: two axes, two tag sets

`[CATEGORIES]` carries `Categorie type` plus **two** parallel lists,
`value1` and `value2`, each padded to 13 or 17 blank strings depending on
file version.

Type 0 (`NO_CATEGO`, manual §5.18) means the tournament defines no
categories and both lists are padding.

`Categories.cpp` defines five types (`Categories.cpp:191-224`,
`CategorieExplain`): 1 rating alone, 2 age alone, 5 free-text names -
single-axis, `value1` only, `value2` blank - and two TWO-axis types, 3
age-then-rating and 4 rating-then-age, where `value1` holds one dimension's
numeric bounds and `value2` the other's. SWAR renders a two-axis category as
one joined label, `"-2000 # -14"`, and packs BOTH axis indexes into one
per-player integer, `CatIndex` (`Categories.cpp:719-726`): the axis-1 slot
times 100, the axis-2 slot added raw - `idx / 100` and `idx % 100` recover
them, both **one-based** (slot 0 is stored as 100/1, not 0/0).

**Settled 2026-09-09**, not by a club file (which is what this section spent
weeks waiting for) but by reading SWAR's own source. See
[swar-source-audit-2026-09-09.md](swar-source-audit-2026-09-09.md).

### The model: one set of tags per axis, not one combined name

SWAR itself has exactly one category per player, always - the joined string
is a display, not two independent memberships. OpenPairings has no such
"one name, two axes" concept, but a player already carries a SET of category
tags (`PairingsEngine.Categories` moduledoc: "a player who is both a junior
and a woman is correctly in both"). Reusing that set is a better fit than
inventing a combined name:

- **Vocabulary.** Both axes become their own named categories -
  `map_categories/1` reads axis 1 and axis 2 the same way a single-axis
  import always has (reject blanks, de-duplicate), axis 1 first. A prize
  ("U16"), a filter (OpenResults' filter bar), and a per-category standings
  table all already work on one name at a time; a combined "-16 / U1800"
  name would need every one of those to learn a new compound vocabulary for
  no gain, since nothing about SWAR's own `CatIndex` requires the combined
  form - see below.
- **Per player.** `SwarImport.category_axes/2` decodes `CatIndex` into
  `{axis1, axis2}`; `player_attrs/2` tags the player with both (blanks
  dropped), so a player imported from a two-axis file is simultaneously in
  their age band and their rating band, exactly like any other
  multi-category player. `category` (the single-valued override field) is
  always axis 1 - see pairing, next.
- **Why not the combined-cell option.** The only thing that would force a
  single joined category is `CatIndex` itself, if it indexed a cross-product
  list rather than two independent axes - it does not. `Categories.cpp:1142-
  1156`'s `AssignCatToPlayer` makes two separate `SetCat*` calls, one per
  axis, and SWAR's own JSON export (`Json.cpp:725-729`) writes
  `CategoryValue_1`/`CategoryValue_2` as two fields, not one. Nothing about
  the per-player slot needs a combined cell, so the option that fits this
  app's existing tag-set model wins.

### Per-player assignment

`category_axes/2` mirrors `Categories.cpp:737`'s
`CatIndex += (value == 1 ? (i + 1) * 100 : i + 1)`: axis 1 is
`div(normalized, 100) - 1` into `value1`, axis 2 is `rem(normalized, 100) - 1`
into `value2`, both 0-based array positions. `normalized` first re-scales a
legacy un-multiplied index the same way single-axis import always has (see
the "Also settled" note below on the 0.53.0 off-by-one fix, which applies
equally to axis 2). A slot past either list, or an all-zero `CatIndex`,
resolves to `""` for that axis rather than guessing.

### Pairing category: axis 1, deterministically

`PairingsEngine.Categories.pairing_category/2` stays single-valued - it has
to, `pair_by_category` runs one independent pool per category. It needs no
special two-axis case: `tournament.categories` lists axis 1 before axis 2
(`map_categories/1`'s order), and the imported player's `category` override
is always set to axis 1, so `pairing_category/2`'s own rule - honour the
override while it is still a tag of the player's and a category of the
tournament's, otherwise fall back to the first of the player's tags in
`tournament.categories` order - lands on axis 1 either way. **The rule, in
one line: a two-axis import always pairs by axis 1** (age, for
age-then-rating; rating, for rating-then-age). If a tournament's use case
ever needs the other axis to drive pairing instead, that is a manual swap
on the Categories page (move the axis-2 category earlier, or set the
player's own override) - nothing here prevents it, but nothing does it
automatically.

### Export round-trips both axes

`Tournament.swar_category_type` (3 or 4) and `swar_category_axis2` (the
subset and order of `categories` that is axis 2) are set only by a two-axis
import; `SwarExport.reverse_categories/3` uses them to split `categories`
back across `value1`/`value2` with the original type integer, and
`reverse_cat_index/4` re-packs each player's `CatIndex` from their pairing
category (axis 1) and whichever of their tags is in axis 2. A plain
single-axis list (`swar_category_type` nil) exports into `value1` alone,
with the type the imported file had (1 ratings, 2 ages, 5 names) or 5 for
categories made here. `SwarTwoAxisCategoriesTest` pins the whole
loop down: import a two-axis export, export it again, import that - same
categories, same per-player tag sets, both times.

**Also fixed alongside this:** the previous exporter wrote `value1` with a
leading blank slot (`["" | categories]`), meant to mimic SWAR's own implicit
slot-0 "+bound" bucket. It never actually agreed with how this module's own
`reverse_cat_index/2` encodes a `CatIndex` - encoding `categories[0]` as
`100` and then decoding `100` against `["", categories[0], ...]` resolves to
the blank, not `categories[0]`, so an export/reimport round trip silently
lost every player's category. No test reimported an export and resolved the
name (only the raw `value1` shape was checked), which is how it survived.
`value1`/`value2` are now written with no leading blank on either axis, 0-
based, matching the decode exactly.

**Also settled, and this one needed no change:** `SW321_PreBye` is a plain
0/1 checkbox adding `SW321_Pre` on top of the bye's own value, which is
exactly what `presence_on_allocated_bye` already models. Two bonuses fell
out of the same read: the divide-by-four scale of the 3-2-1 point values is
now *proven* rather than inferred (`TOptions.cpp` stores `4 * value`), and
`abs_value` is inert under 3-2-1.

## 3-2-1 scoring (`[TOURNOI].Type == SWISS_321`)

SWAR's "3-2-1" tournament type (`Type == 3` in the on-disk `[TOURNOI]`
header) lets a club configure its own win/draw/loss/bye point values
instead of the fixed 1.0/0.5/0.0/1.0 every other tournament type uses. The
importer previously read the four `SW321_Win/Nul/Los/Bye` fields (it always
had - see `parse_tournoi/2`) but never mapped them onto the tournament,
so a 3-2-1 import silently landed on the schema defaults regardless of
what the club had configured.

- **Guard.** The mapping only fires when `t.type == 3`
  (`TOURNOI_TYPE.SWISS_321`, confirmed from the SWAR source-derived format
  manual). Every other type leaves `points_win`/`points_draw`/
  `points_loss`/`bye_value` at the `Tournament` schema defaults, exactly as
  before - a standard import is unaffected.
- **Scale: ÷4.** The format manual annotates `SW321_Win` as "×4 internally",
  but do NOT lean on that alone: this manual is known to be wrong about
  scaling elsewhere - it states the ordinary per-player `Points` field is
  ×2, and that is false (verified ×4 against the real c-reeks file, where
  `points_raw / 4` reproduces Deloof's actual 9.0 total). Treat the manual
  as a hint, never as proof, on any scale question.
  The load-bearing evidence for ÷4 is instead: the `SW321_*` fields are in
  the **same scale as the per-player `Points` field** (see the exact
  per-player formula below, which holds with no extra factor), and that
  field is independently established as ×4 by the c-reeks anchor above.
  Same scale + a real-world-anchored ×4 ⇒ ÷4, with no appeal to the
  manual's own annotation.
  A previous version of this mapping used ÷8, which silently **halved**
  every point value the club had actually configured (e.g. a real 2.0-point
  win imported as 1.0) - this was the KBSB-reported bug: "players don't get
  the full 3-2-1 points from played games". The ÷8 divisor had passed a
  check that looked rigorous but wasn't: dividing the file's raw per-player
  `points` total by 8 reproduced `wins*1.0 + draws*0.5 + losses*0.0`
  exactly - but `SW321_Los` is 0 in this fixture, so losses contribute 0
  points under *any* divisor, and the check only ever verified the win:draw
  *ratio* (2:1), never the absolute scale. Any divisor "passes" a ratio-only
  check.
  Non-circular re-derivation: `points_raw` for every player in the fixture
  equals **exactly** `wins*SW321_Win + draws*SW321_Nul + losses*SW321_Los +
  lost_byes*SW321_Pre` - no further scaling - checked across every player
  with an unpaired bye. That formula is what proves the `SW321_*` fields
  share the `Points` field's scale; combined with the c-reeks anchor that
  `Points` is ×4, `points_raw / 4` is each player's real point total. E.g.
  player `ni=39` ("Ghijselinck, Kris"): record 2 wins / 1 draw / 1 loss
  (played) + 2 unpaired "LOST_BYE" rounds. Stored `points = 28`. Under this
  club's actual configured scale (win=2.0, draw=1.0, loss=0.0, plus 1.0
  presence point per unpaired bye): `2*2.0 + 1*1.0 + 1*0.0 + 2*1.0 = 7.0`,
  and `28 / 4 = 7.0` - exact match. `SW321_Win/Nul/Los` in the real file are
  configured to 8/4/0 raw → **2.0/1.0/0.0** real points - "3-2-1" is SWAR's
  feature name, not a claim that the values are literally 3/2/1; each club
  sets its own scale, and this club's happens to be 2/1/0. `SW321_Bye` is 4
  raw → 1.0 real, diverging from the file's separate, unrelated `ByeValue`
  field (→ 0.0 via `map_bye_value/1`) - an unpaired bye in this 3-2-1
  tournament should score a full point, not zero.
  Caveat: no `WIN_BYE`/`DRAW_BYE` round occurs anywhere in the fixture, so
  `SW321_Bye`'s role is inferred from being part of the same field group
  (same manual annotation, same serialization pattern) rather than
  independently confirmed the way `SW321_Win/Nul/Los/Pre` are.
- **`SW321_Pre` ("presence points") DOES appear in the real fixture**,
  contrary to what an earlier version of this doc claimed. Every unpaired
  "LOST_BYE" round for every affected player (e.g. `ni=10`, `ni=15`,
  `ni=39`, `ni=43`) is scored as `SW321_Pre` raw points, not `SW321_Bye` -
  see the worked example above.

  **Modelled since 0.16.x, and the engine was told about it in 0.17.1.**
  `Tournament.presence_value` holds the points and
  `Tournament.presence_on_allocated_bye` (SWAR field 85, "add presence
  points for bye games") says whether a pairing-allocated bye pays them ON
  TOP of `bye_value`. `Standings.bye_points/4` adds the bonus, and
  `Tournament.engine_point_system/1` passes the same total to the pairing
  engine - which it did not until 0.17.1, so for a while the crosstable
  and the pairing file disagreed about what a 3-2-1 allocated bye was
  worth. An earlier version of this document described the mechanic as
  "not modeled" and left it as a follow-up; that is no longer true.
- Test fixture: `test/fixtures/test3-321.swar` (gitignored, real personal
  data, same convention as `c-reeks.swar`/`problemski.swar`) - a real
  club-championship file saved with 3-2-1 mode on.

## Import and export: what goes where

Completed 2026-09-27: everything a `.swar` file holds is either used by the
tournament or kept for the way back, and the export writes every piece SWAR
can hold. What changed on the way:

- **Extra points count as SWAR counts them.** A Swiss whose players have
  `ExtraPts` imports with `count_extra_points` on; a round robin or 3-2-1
  file has them zeroed, as SWAR's loader does (see "XtraPoints" above).
  Since the extra-points modes, they also pair as SWAR pairs them:
  acceleration mode, with each round's `XtraPts` as its recorded history.
- **Pairing numbers are SWAR's seed order** (`SwarImport.prepare_players/1`):
  players in `(category when separate, Rank)` order, which is how SWAR
  numbers its Berger tables and orders its JaVaFo input. `Ni` only finds a
  record's opponent. A round robin continued here therefore plays SWAR's
  own table, one per category when categories are separate
  (`RoundRobin.schedule_groups/2`), and keeps SWAR's full-point free round -
  docs/pairing-systems.md.
- **SWAR's separate categories** (`CatSepares`) are `pair_by_category` plus
  `categories_ranked_separately`, a tournament setting of its own (the
  Categories page, "Rank each category separately") that `Standings`
  honours: each category ranked on its own, places from 1, and no tie -
  so no direct encounter - reaching across a category
  (`Standings.ranked_separately?/1`). A file with categories imports with
  them switched on.
- **Data after the player list** imports without it, with a warning.
- **An empty round 0** (SWAR's player-list template) imports as a
  tournament with players and no rounds, with a warning.
- **A SWAR "double rounds" Swiss** is match format; an accelerated Swiss is
  a plain one, with a warning (SWAR's acceleration is not FIDE's Baku).
- **FIDE homologation and SWAR's per-round FIDE ids** set
  `fide_homologated` and `fide_id_ranges`; SWAR's "colour of the top seed in
  round 1" sets the initial colour.
- **Everything else SWAR has and this app does not** is kept in
  `Tournament.swar_settings` and written back.

### Field by field

`[TOURNOI]`:

| SWAR | Here | Written back |
|---|---|---|
| `Tournoi`, `Organisateur`, `ClubOuLogo`, `Lieu` | name, organizer, organizer club number, city | yes |
| `Arbitre1` | chief arbiter, title taken off (FIDE-matched name when one matches) | the file's text while the name is the one the import made of it, else the chief arbiter |
| `Arbitre2` | deputy arbiter text, and the deputies on the Norms page | yes |
| `DateDebut`, `DateFin`, `[DATES]` | start and end date, round dates | yes, as SWAR's `dd/mm/yyyy` (the export wrote ISO) |
| `Cadence`, `CadenceAutre` | rate of play | the file's index while it reads as the rate of play, else the index of the rate of play in SWAR's list for the standard (rapid and blitz lists were never searched), else "other" with the text |
| `NbRondes` | rounds | yes |
| `FRBEfrom/to`, `FIDEfrom/to` (games to report) | `swar_settings` | yes |
| `CatSepares` | pair by category + rank each category separately | on when either is on (a note when only one is) |
| `AfficherEloOuPays`, `SW_EloR1`, `SW_AmerPresence`, `Plusieurs`, `FirstTable`, `EloUsed`, `TbPersonel`, `EloEqual`, `FF_Value` | `swar_settings` | yes (they were fixed defaults) |
| `FideHomologation` | FIDE homologated | yes |
| `FideIdDe/AA/Id` (16) | event code (every id), FIDE id ranges (the usable ones) | the file's block while the tournament still derives the same ranges and code from it, else from the ranges, then any other id of the event code |
| `FideArbitre1/2` | `swar_settings` | no: a v7 file has one string there |
| `FideRemarques` | `swar_settings` | yes (the export wrote the deputy arbiter there) |
| `Type` | tournament type, pairing system, cycles, match format | the file's type while it still reads the same (an accelerated or American Swiss is a plain Swiss here); else round robin 4, 5 (match format) or 6 (two cycles), Swiss 0, 1 (match format) or 3 (points other than 1/½/0) |
| `SW321_*` | 3-2-1 point values (the import refuses a 3-2-1 file) | the tournament's for a 3-2-1 file, else the file's own |
| `TournoiStd` | standard | yes |
| `ApparOrder` | initial colour (Swiss: 0 white, 1 black, 2 drawn by lot) | the initial colour, or the colour the lot drew; a round robin's as the file had it |
| `ByeValue` | bye value (a round robin's forced to a point) | the file's while it agrees, else the tournament's |
| `AbsValue`, `AbsNbFois`, `AbsJusque` | absence points and caps | yes |
| `Federation` | "BEL" | the file's Belgian federation code while the tournament is Belgian, else 2 |
| `Version`, `Guid`, `MacAdress` | SWAR guid; `swar_settings` | always "v7.00"; the guid; the MAC address (was blank) |

The other sections:

| SWAR | Here | Written back |
|---|---|---|
| `[TIE_BREAK]` | tie-breaks (12 of SWAR's 15 codes) | the file's five while the tournament still ranks by what the import made of them, so median-2, performance and black wins stay in place; else every code SWAR has (the export knew six) |
| `[EXCLUSION]` | club and federation rules, forbidden pairs | one rule as SWAR's own; forbidden pairs as the groups they came from; anything else as groups of player numbers, with a note |
| `[CATEGORIES]` | categories, switched on; two-axis bookkeeping | yes; type as the file had it, or 5 (names) for categories made here (the export wrote 1, ratings) |
| `[XTRA_POINTS]` | the acceleration-mode bands, and `swar_settings` | yes, from the bands in acceleration mode (highest Elo first, at most four), else as the file had it (the export wrote zeros) |

`[JOUEURS]` and `[RONDE]`:

| SWAR | Here | Written back |
|---|---|---|
| `Ni` | finds opponents only | the pairing number |
| `Rank` | the pairing number (seed order) | the order of the pairing numbers, unnumbered players by rating after them (the export always sorted by rating) |
| `Nom`, `Sexe`, `Pays`, `MatNat`, `MatFide`, `Titre`, `ClubNr`, `Club`, `Dnaiss`, `Paye`, `Absent`, `AbsentRondes`, `HandyTable`, `CatIndex` | the player's fields | yes |
| `Affilie` | affiliated (a G-licence, 2, is affiliated) | 1 or 0 |
| `Elo`, `EloFide` | national and FIDE rating (a v7 file has one, both) | the FIDE rating: a v7 file has one |
| `ExtraPts` | extra points, acceleration mode (none for a round robin or 3-2-1) | always in acceleration mode; a handicap only while counted |
| `Class`, `NbParties`, `Points`, `TieBreak`, `Perf`, `Pts_Corr`, `AmericanPts`, `SpecialPts` | recomputed here (`Pts_Corr` warns) | games played, points (in quarter points - the export wrote halves), the rest 0: SWAR recomputes them |
| `[RONDE]` | boards, results, byes, absences; `XtraPts` as the round's recorded virtual points | yes; SWAR's floats are 0 (the pairing engine works floats out itself), `XtraPts` the recorded virtual points |

What this app has that SWAR cannot hold is listed on the export page for the
tournament at hand (`SwarExport.export_notes/1`): soft pairing wishes; more
than one exclusion rule; Keizer; teams; Baku acceleration; a standings order
set by hand; a round robin's own point values; other point values for a
Swiss (written as SWAR's 3-2-1 type, which cannot be imported back yet);
a handicap the tournament does not count, and a handicap's bands; more than four acceleration bands;
more than 16 categories, and the conditions that fill them; tie-breaks SWAR
has no code for (WON, TPN and the team ones) and more than five; a national
rating that differs from the FIDE one; the rounds before a late entrant
joined, when the tournament does not count them as absences (SWAR only has
the absence); unrated and postponed results. The settings that are about this
app rather than the event - publishing, the postponed-game outcomes, the
unplayed-round rule for Buchholz, norms data, e-mail addresses - have no
SWAR field at all.

### Round trip

`test/pairings_engine/federations/bel/swar_round_trip_test.exs` imports a
synthetic file for each feature above (every result and bye, absence and
player field; SWAR's own settings; FIDE ids; every tie-break code; extra
points, the band table and each round's `XtraPts`; absence points; round robins single, match and
double, with and without separate categories; separate and two-axis
categories in a Swiss; double rounds; an accelerated Swiss; each initial
colour; each of the five exclusion rules; an unpaired round; the round-0
template; trailing data), exports it, imports the export, and checks that
the second tournament is the first (`SwarFixture.snapshot/1`: every
column, player, board, bye and forbidden pair) and that exporting it again
gives the same bytes.

Over the real files at hand (run by hand; they are real events and are
never committed): all 47 distinct files import, export and re-import as the
same tournament, and every re-export is byte for byte the export before it.
The one field that changes is the national rating, on the 44 files saved
before SWAR 7: a v7 file has one Elo per player. For every single-table
round robin among them (10 files, 114 rounds) the Berger table built from
the imported pairing numbers is the one SWAR paired into the file. The
16-group club round robin is the exception, and needs none: its stored
Ranks were renumbered after it was paired (they run 1-119 across the
groups, where SWAR's own round-robin pairing leaves them 1-8 in each), so
no numbering can rebuild its table - and all its rounds are in the file.

What does not come back the same, all of it said on the export page or
above:

- a national rating that differs from the FIDE rating (v6 files);
- SWAR's two FIDE-arbiter strings (a v7 file has no place for them);
- a G-licence affiliation, which comes back as an ordinary one;
- two or more exclusion rules at once, or a club rule SWAR's club numbers
  would group differently, which come back as forbidden pairs;
- ranking categories separately without pairing them separately (or the
  reverse), which comes back as both;
- a Swiss with its own point values, written as SWAR's 3-2-1 type, which
  cannot be imported yet;
- a handicap the tournament does not count, which is left out, and acceleration points kept out of the standings, which SWAR will count;
- SWAR's player numbers: the export numbers players in seed order, so a
  file that went through here comes back to SWAR with the same players,
  seeds and games under new numbers.
