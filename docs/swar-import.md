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
