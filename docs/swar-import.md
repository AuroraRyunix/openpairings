# SWAR import (`PairingsEngine.SwarImport`)

`.swar` is the native binary save format of SWAR (by Georges Marchal /
FRBE-KBSB), the tournament software most Belgian clubs already use.
`PairingsEngine.SwarImport` parses that binary format directly (no
intermediate export step) and creates a full tournament — players, rounds,
pairings, results — from it. Reached from the Tournaments page's "Import
SWAR file" panel.

## File versions, and what SWAR v7 changed

The format is a sequential binary serialization with no index: every field
is read in exact order, and a single field of drift turns the rest of the
file into garbage. Each release that adds or removes a field therefore needs
a version gate in `swar_import.ex` (`version_gte?/2`, against the version
string in the file header — `"v6.78"`, `"v7.04"`, …).

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
  follow — so either reading imports correctly, and a file matching neither
  fails loudly instead of silently shifting every field after it.
- **Which int left the `NbParties`..`Perf` run** is likewise unprovable from
  it (the tournament hadn't started, so every int in that run is zero). It's
  read as `Pts_Corr` being the one dropped, which fails safe: `Pts_Corr` is
  the only field of that run this importer reads at all, so guessing wrong
  can't shift anything persisted — at worst it silences the advisory
  `points_adjusted_warnings/3`. To settle it, re-export a **played** v7
  tournament and check whether `points`/`perf` land where expected.

`EloFide` is the one v7 change that needed a judgement call rather than a
gate. Belgium retired its own rating list — the KBSB export's `Elo` column
is zero for everyone now — so the single Elo a v7 record still carries *is*
the FIDE rating. Verified against the local FIDE database: across the 126
players of a 128-player v7 open that resolve by `fide_id`, that Elo tracks
`standard_rating`, differing only by the month between SWAR's rating list
and ours. `parse_player/2` mirrors it into `elo_fide` so `fide_rating_or/1`
keeps working instead of filing every v7 player as unrated.

## Officials: what SWAR carries, and what it doesn't

SWAR stores officials as free text in two `[TOURNOI]` fields, with a grade
prefix and **multiple people comma-separated in one field**:

```
Arbiter1 = "IA Luc Cornet"
Arbiter2 = "IA Sylvin De Vet, NA Marc Van Dyck"
```

That's the opposite convention to FIDE's "Last, First", so within these fields
a comma is a *person* boundary, never a name boundary — which is what makes
splitting on it safe here and nowhere else.

On import (`swar_officials/1`, `strip_arbiter_title/1`):

- the grade (`IA`/`FA`/`NA`/`IO`/`NO`/…, including stacked ones) is stripped —
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
than guessed** — BEL has two `Van Dyck, Marc`, so that deputy imports with a
name and no id, for a human to disambiguate on the Norms page.

This same matcher (`SwarImport.match_official_fide_player/1`, public for
exactly this reason) is reused on the public Tools page's upload prefill —
see [`tools.md`](tools.md)'s "Officials: FIDE lookup" section — except there
a non-match doesn't even leave the raw name in the field: the box stays
empty with a hint, since that page never has the fallback of "fill it in
by hand on the Norms page later" this persisting path does.

**Not in the SWAR file at all:** the organizer's FIDE ID, and any e-mail
address. SWAR has an organizer *name* (`Organizer`) but no id for them, so
those fields on the Norms page always start empty and are filled in by hand.

### FIDE event code

`[TOURNOI]`'s FIDE block holds up to 16 homologation entries, each with a
tournament id — one for a plain event, several for a festival rated in
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
in — the IT3 template's own printed privacy notice states FIDE requires both.
An empty deputy slot is fine — not every event has two.

## Rate of play (`Cadence` / `Cadence_Other`)

`Cadence` (manual field 88) is a 0-based index into one of **three** dropdown
lists SWAR's own UI fills at runtime — which list applies depends on the
sibling `TournoiStd` field (0=Standard/1=Rapid/2=Blitz, the same field
`map_standard/1` reads). None of this is in the binary-format notes this
importer otherwise leans on; the mapping (`SwarImport.cadence_label/2`,
`@std_cadences`/`@rap_cadences`/`@bli_cadences`) was reverse-engineered
directly from **SWAR's own C++ source** (`Utils.cpp`'s `GetCadence/2` +
`Languages/Swar.Lang.fr.ini`'s `[CADENCES]` section) rather than inferred
from a `.swar` sample, since the integer alone carries no information without
that table.

`Cadence_Other` (free text) is only meaningful for the list's own last entry
("autre cadence" / "Other cadence") — SWAR's UI itself detects "Other" by
comparing the current label against the list's last entry, not a fixed
sentinel index, so `cadence_label/2` deliberately leaves that last index out
of each table and returns `nil` for it. `tournament_attrs/1` maps
`rate_of_play` as `cadence_label(t.tournoi_std, t.cadence) || t.cadence_other`
— the dropdown pick wins whenever it resolves to something, `Cadence_Other`
only fills in for "Other" (or, defensively, an index outside all three known
tables).

## Two ids per player: national vs. FIDE — never crossed

Every SWAR player record carries **two separate identifiers**, read from
two separate fields (`MatNat` and `MatFide`) at fixed, adjacent offsets in
the binary layout:

| SWAR field | Meaning | Maps to |
|---|---|---|
| `MatNat` | the player's national federation number (KBSB/FRBE membership id) — short, typically well under 100,000 | `players.national_id` (stored as text) |
| `MatFide` | the player's FIDE id — the number used on ratings.fide.com. Historically 6-8 digits; **FIDE now issues 9-digit ids too** (e.g. 551061350), so don't treat a long value here as a sign of a misparse | `players.fide_id` |

This mapping has been cross-checked against real ratings.fide.com profiles
(not just the bundled test fixtures) — e.g. `test/fixtures/c-reeks.swar`'s
`MatFide` value for "Waegeman, Willem" is 292052, which is in fact
ratings.fide.com's profile for that exact player (federation Belgium, born
1982). The two fields are read once, in a fixed position, and used exactly
once each, by name (`p.mat_nat` → `national_id`, `p.mat_fide` → `fide_id`)
in `create_players/3` — there is no code path anywhere in this module that
copies one into the other, or falls back from one to the other.

If a future SWAR export still shows the wrong id in the wrong field,
suspect a *different* SWAR file version with a shifted binary layout
before suspecting this mapping — the field read order is not
version-branched today (unlike several other `[TOURNOI]`/`[JOUEURS]`
fields, which are, see the version-gate comments in `swar_import.ex`).

## Players with no FIDE id: matching against the local FIDE database

Real SWAR files routinely have players with `MatFide == 0` — SWAR simply
has no FIDE id on file for them (this is normal, not a parsing error; see
e.g. `c-reeks.swar`'s own "Vanmassenhove, Claude" and "Cobert, Quinten").

For each such player, the importer searches the local FIDE database
(`PairingsEngine.Fide.FidePlayer`, synced separately — see `lib/pairings_engine/fide/`)
for an **exact** match on name (case-insensitive, "Last, First" as both
sides already store it) + federation + birth year:

- **Exactly one exact match** → adopted automatically: `fide_id`, `title`
  (only if the FIDE database has one), and `fide_rating` (only if SWAR's
  own `EloFide` was 0 — SWAR's own nonzero rating always wins, since it
  reflects the rating *at the time of the tournament*, not today's).
- **No match, or more than one same-name-and-federation candidate (with a
  different or unknown birth year)** → left for a human to resolve. The
  candidate list still surfaces same-name/federation matches regardless of
  birth year, so "right person, wrong year on one side" is a one-click
  pick rather than a dead end.

`name` is never touched by a FIDE match, in either case — SWAR's own
spelling is always canonical (a FIDE-database name is sometimes a
different transliteration/spelling of the same person).

### What counts as "the same name", and how wide the search goes

Two deliberate widenings, both of which only ever grow the *candidate list* —
the auto-adopt rule above is unchanged:

- **Diacritics are folded**, not just case. SWAR carries whatever the arbiter
  typed while the FIDE list is inconsistent about accents, so a plain downcase
  made "Müller" and "Muller" two different people — and the player then showed
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
is **not** just rated players — roughly 70% of its ~1.9M rows have no standard
rating — so absence really does mean "no FIDE id", not "unrated".

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
  unresolved is simply imported without a `fide_id` — there's nobody to
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
  entity* organizes the tournament (FRBE/KBSB — the federation itself,
  language variants; FEFB/VSF/SVDB — its Walloon/Flemish regional leagues;
  "direct FIDE homologation" with no sub-federation) — none of these are
  actual ISO/FIDE country codes, and this importer only ever sees
  KBSB/FRBE-organized tournaments, so all of them normalize to `"BEL"` for
  both `tournament.federation` and each `player.federation`. TRF export
  reads these fields directly, so a raw league marker there would produce
  an invalid TRF file.

## Absence scoring: SWAR's "Pt ABSENT" (`AbsValue`/`AbsJusque`/`AbsNbFois`)

A player marked genuinely ABSENT for a round (SWAR's `TABLE_ABSENT`, as
opposed to a pre-arranged bye — see "Requested bye vs. genuine absence"
below) can still be paid points for it, but SWAR's own "Pt ABSENT" club
option caps that three separate ways, all three read from the general
`[TOURNOI]` header (unconditional on tournament type, unlike the 3-2-1
fields below):

- **`AbsValue`** — whether the option is on at all. Confirmed against
  SWAR's own source (`TOptions.cpp`'s `TOptionsGetValues`): this is a
  plain UI checkbox, raw `0` (unchecked) or `1` (checked) — checked pays
  `0.5` points. **A previous version of this importer mapped raw `5` to
  `0.5`** (the `Tournament.abs_value` field's own doc comment said "UChar:
  0 or 5"), which happened to satisfy every synthetic test fixture (they
  all hardcoded the test input as `5`, since nobody had checked it
  against a real file with the box actually checked) but silently scored
  every real absence-paying tournament as if the option were OFF — raw
  byte `1` doesn't equal `5`, so `abs_value` always came out `0.0`. Caught
  by importing a real production `.swar` file (`AbsValue: 1`) whose
  organizer had confirmed the box was checked (0.5 points, through round
  7) and finding the imported tournament scored those absences as zero.
  The stale "0 or 5" comment traces to `Swar.h`'s
  `enum USE_POINTS { PTS_1, PTS_5, PTS_0 }` — `PTS_0`'s ordinal value is
  `2`, not `0` or `5` either, and that enum describes the unrelated,
  pre-v4.21 `AbsValueOld` field this one replaced; the "5" was never a
  real byte value SWAR writes for this field.
- **`AbsJusque`** ("jusque ronde", "until round") — the last round,
  **inclusive**, an absence still pays `AbsValue`. Round `AbsJusque + 1`
  onward scores a plain loss instead, same as if the option were off.
- **`AbsNbFois`** ("nombre de fois", "number of times") — how many
  absences, cumulative across the tournament **up to and including the
  round being scored**, still pay `AbsValue`. The `(AbsNbFois + 1)`th and
  any later absence scores a plain loss instead, even if it's still
  within `AbsJusque`.

Both caps are read from the file even when `AbsValue` is unchecked — SWAR
itself resets both to `0` in that case (`TOptionsGetValues`), which is
also what makes `AbsJusque: 0` correctly fail every round's cutoff check
without a separate "is this feature even on" flag needed on our side.

Mapped onto `Tournament.abs_jusque`/`abs_nbfois` (plain integers, `nil` for
every non-SWAR-import tournament) and enforced in
`PairingsEngine.Standings.bye_points/4`'s `"absent"` branch — see that
function's doc for the exact precedence, and `bye_points_for_row/2` for
the version display code (`PairingsEngineWeb.PairingsLive`/`LiveRoundLive`/
`PublicPairingsLive`/`PrintController`) should call instead of working out
the cumulative count itself.

All three fields (`abs_value`/`abs_jusque`/`abs_nbfois`) are also settable
by hand, for a tournament with no SWAR file at all, on
`PairingsEngineWeb.SettingsOptionsLive` (`/t/:id/settings/options`, the
"Scoring" card) — blank means the same "not applicable"/"no cap" nil does
here. Like the pairing-shape controls on that same page, all three lock
(greyed out, server-side enforced regardless of the HTML `disabled`
attribute) once round 1 has been paired — not because changing them later
would corrupt anything (scores are computed live from these fields, never
baked into a stored row), but because a tournament that far along is
presumably still being run under whatever rule it started with, and
silently changing who's owed points partway through would be confusing.

### Requested bye vs. genuine absence — two different `byes`-table rows

Easy to conflate, so worth stating plainly: a **requested bye** (arranged
with the arbiter ahead of the round, SWAR's `WIN_BYE`/`DRAW_BYE`/
`LOST_BYE` result codes) and a **genuine absence** (`TABLE_ABSENT`, no
result code at all — the player just didn't show and nobody arranged
anything) are different `byes`-table rows with different scoring rules,
and always have been (`swar_import.ex`'s `classify_unpaired/1`):

- Requested: `type: "requested-half"` / `"requested-zero"` — scored at
  `points_draw` / `presence_value || points_loss`, from SWAR's `ByeValue`
  (or `SW321_Bye` for a 3-2-1 tournament).
- Genuine absence: `type: "absent"` — scored at `abs_value`, subject to
  the `abs_jusque`/`abs_nbfois` caps just described. Never affected by
  `ByeValue`.

## 3-2-1 scoring (`[TOURNOI].Type == SWISS_321`)

SWAR's "3-2-1" tournament type (`Type == 3` in the on-disk `[TOURNOI]`
header) lets a club configure its own win/draw/loss/bye point values
instead of the fixed 1.0/0.5/0.0/1.0 every other tournament type uses. The
importer previously read the four `SW321_Win/Nul/Los/Bye` fields (it always
had — see `parse_tournoi/2`) but never mapped them onto the tournament,
so a 3-2-1 import silently landed on the schema defaults regardless of
what the club had configured.

- **Guard.** The mapping only fires when `t.type == 3`
  (`TOURNOI_TYPE.SWISS_321`, confirmed from the SWAR source-derived format
  manual). Every other type leaves `points_win`/`points_draw`/
  `points_loss`/`bye_value` at the `Tournament` schema defaults, exactly as
  before — a standard import is unaffected.
- **Scale: ÷4.** The format manual annotates `SW321_Win` as "×4 internally",
  but do NOT lean on that alone: this manual is known to be wrong about
  scaling elsewhere — it states the ordinary per-player `Points` field is
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
  win imported as 1.0) — this was the KBSB-reported bug: "players don't get
  the full 3-2-1 points from played games". The ÷8 divisor had passed a
  check that looked rigorous but wasn't: dividing the file's raw per-player
  `points` total by 8 reproduced `wins*1.0 + draws*0.5 + losses*0.0`
  exactly — but `SW321_Los` is 0 in this fixture, so losses contribute 0
  points under *any* divisor, and the check only ever verified the win:draw
  *ratio* (2:1), never the absolute scale. Any divisor "passes" a ratio-only
  check.
  Non-circular re-derivation: `points_raw` for every player in the fixture
  equals **exactly** `wins*SW321_Win + draws*SW321_Nul + losses*SW321_Los +
  lost_byes*SW321_Pre` — no further scaling — checked across every player
  with an unpaired bye. That formula is what proves the `SW321_*` fields
  share the `Points` field's scale; combined with the c-reeks anchor that
  `Points` is ×4, `points_raw / 4` is each player's real point total. E.g.
  player `ni=39` ("Ghijselinck, Kris"): record 2 wins / 1 draw / 1 loss
  (played) + 2 unpaired "LOST_BYE" rounds. Stored `points = 28`. Under this
  club's actual configured scale (win=2.0, draw=1.0, loss=0.0, plus 1.0
  presence point per unpaired bye): `2*2.0 + 1*1.0 + 1*0.0 + 2*1.0 = 7.0`,
  and `28 / 4 = 7.0` — exact match. `SW321_Win/Nul/Los` in the real file are
  configured to 8/4/0 raw → **2.0/1.0/0.0** real points — "3-2-1" is SWAR's
  feature name, not a claim that the values are literally 3/2/1; each club
  sets its own scale, and this club's happens to be 2/1/0. `SW321_Bye` is 4
  raw → 1.0 real, diverging from the file's separate, unrelated `ByeValue`
  field (→ 0.0 via `map_bye_value/1`) — an unpaired bye in this 3-2-1
  tournament should score a full point, not zero.
  Caveat: no `WIN_BYE`/`DRAW_BYE` round occurs anywhere in the fixture, so
  `SW321_Bye`'s role is inferred from being part of the same field group
  (same manual annotation, same serialization pattern) rather than
  independently confirmed the way `SW321_Win/Nul/Los/Pre` are.
- **`SW321_Pre` ("presence points") DOES appear in the real fixture**,
  contrary to what an earlier version of this doc claimed. Every unpaired
  "LOST_BYE" round for every affected player (e.g. `ni=10`, `ni=15`,
  `ni=39`, `ni=43`) is scored as `SW321_Pre` raw points, not `SW321_Bye` —
  see the worked example above. There is no field in the `Tournament`/
  `byes` schema for "points awarded just for being marked present" as
  distinct from `bye_value`, so this mechanic is **not modeled**: a
  pairing-allocated bye in a 3-2-1 tournament still imports at `bye_value`
  points only, which may undercount relative to what SWAR itself displays
  whenever `SW321_PreBye` (field 85, "add presence points for bye games")
  is set — as it is (`1`) in the real fixture. This is a real, separate
  scoring gap; fixing it needs a schema decision (where do presence points
  live?), not just a divisor change, so it is left as a follow-up rather
  than guessed at here.
- Test fixture: `test/fixtures/test3-321.swar` (gitignored, real personal
  data, same convention as `c-reeks.swar`/`problemski.swar`) — a real
  club-championship file saved with 3-2-1 mode on.
