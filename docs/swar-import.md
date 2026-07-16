# SWAR import (`PairingsEngine.SwarImport`)

`.swar` is the native binary save format of SWAR (by Georges Marchal /
FRBE-KBSB), the tournament software most Belgian clubs already use.
`PairingsEngine.SwarImport` parses that binary format directly (no
intermediate export step) and creates a full tournament — players, rounds,
pairings, results — from it. Reached from the Tournaments page's "Import
SWAR file" panel.

## Two ids per player: national vs. FIDE — never crossed

Every SWAR player record carries **two separate identifiers**, read from
two separate fields (`MatNat` and `MatFide`) at fixed, adjacent offsets in
the binary layout:

| SWAR field | Meaning | Maps to |
|---|---|---|
| `MatNat` | the player's national federation number (KBSB/FRBE membership id) — short, typically well under 100,000 | `players.national_id` (stored as text) |
| `MatFide` | the player's FIDE id — the standard 6-8 digit number used on ratings.fide.com | `players.fide_id` |

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
