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
this module's own read order and reverse-mapping tables. Full detail
(what's exactly invertible and what's a documented policy choice) lives
in `SwarExport`'s moduledoc, not duplicated here. Confirmed to open in a
real SWAR v7 install.

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
constant 0 remains correct - see `reverse_player/5`'s own comment for
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
  app could not hold even if the loop were free. Round 0 goes with them: it
  produced a Round row numbered 0, a round before the first.

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
  `parse_player/2` and `SwarExport`'s `reverse_player/5`: the `[RONDE]`
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

The audits carry further, smaller divergences. Two more of this kind - the
`WIN` tiebreak counting a full-point bye here and not in SWAR, and a
round-robin bye scoring a full point in SWAR where the file itself says zero -
and one that is not: in a 3-2-1 tournament SWAR computes the Koya threshold
and several other tiebreaks on the classic 1/0.5/0 scale while the scores
themselves are on the club's own, so there it is SWAR's number that is wrong.
None of them is worth an arbiter's attention until it is reported; all are
cited in the audit documents.

## Categories: two value lists, one of them unread

`[CATEGORIES]` carries `Categorie type` plus **two** parallel lists,
`value1` and `value2`, each padded to 13 or 17 blank strings depending on
file version.

Type 0 (`NO_CATEGO`, manual §5.18) means the tournament defines no
categories and both lists are padding.

For any other type, the import reads them unevenly, and deliberately:

- the tournament's category list is `value1 ++ value2`, de-duplicated;
- a **player's** category comes from `value1` alone, at a ONE-BASED slot
  (`Categories.cpp` stores the first as 100, not 0 - this import read it as
  zero-based until 0.53.0 and put every player one category too strong),
  because §10.2 defines
  `CatIndex` as a slot in that list (stored pre-multiplied by 100 for
  indexes under 100).

So a file with a non-empty `value2` imports categories that no player can be
assigned to, sitting at list positions that correspond to no index.

**`value2` is the SECOND AXIS. Settled 2026-09-09** - not by a club file,
which is what this section spent weeks waiting for, but by reading SWAR's
own source. See [swar-source-audit-2026-09-09.md](swar-source-audit-2026-09-09.md).

`Categories.cpp` defines four category types: rating alone, age alone,
rating-then-age, and age-then-rating. For the two-axis types `value1` holds
one dimension's boundaries and `value2` the other's, and **for all four both
lists hold numeric bounds rather than names**. SWAR renders the pair as a
single label - `"-2000 # -14"` - and a player is in exactly one such
category.

None of the three meanings this section previously weighed was right. The
closest, "a second dimension", had the shape but assumed the lists held
names; the entry that guessed "boundaries of the first list" had the content
but not the structure. Worth recording, because the reason the question
survived so long is that all three readings were plausible and none could be
falsified without either a real file or the source.

**The warning stays**, and its text has been corrected rather than removed.
Knowing what `value2` is does not make this app able to hold it: a player
here carries a category NAME, and SWAR's two-axis label is a pair of numeric
bounds. So a two-axis file still imports its first axis only, and
`SwarImport.category_warnings/1` still tells the arbiter that the second set
has nobody in it.

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
