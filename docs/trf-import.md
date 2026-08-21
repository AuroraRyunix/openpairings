# TRF16 import (`PairingsEngine.TrfImport`)

Imports a FIDE TRF16 file - the same format `PairingsEngine.TrfExport` and
`PairingsEngine.Trf` already produce/consume for JaVaFo and the user-facing
TRF download - as a brand-new tournament: players, rounds, pairings and
byes, owned by the importing user. Reached from the Tournaments page's
"Import TRF file" panel, right next to "Import SWAR file". Unlike SWAR
import, this is a single step: there's no FIDE-id resolve modal, since a
TRF file's own `fide_number` column is either present or it isn't - there's
nothing to disambiguate.

## What's imported

- **Tournament**: name (012), city (022), federation (032), start/end date
  (042/052), chief arbiter and up to 4 deputy arbiters (102/112, each
  parsed back into `officials.chief_arbiter_fide_id` /
  `officials.deputyN_fide_id` when the line has a leading FIDE id - the
  exact inverse of `TrfExport`'s own `chief_arbiter_line/1` /
  `deputy_arbiter_lines/1`), time control (122), round dates (132).
  `pairing_system` is always set to `"swiss"` and `type` is inferred from
  the 092 label by substring match (`"Team"` / `"Round Robin"`), defaulting
  to `"swiss"` if 092 is missing or unrecognized. `rounds_count` is not
  read from any header - it's the number of round-columns actually present
  in the player data (the max across all players), at least 1.
- **Players**: name, sex, title, FIDE id (058-068; TRF's `"0000000"` /
  blank both become no FIDE id), FIDE rating, federation, birth date
  (070-079 - a full date when present, or the `"YYYY/00/00"` year-only
  form `TrfExport` itself writes for a birth_year-only player). Starting
  rank (005-008) becomes `pairing_number`, set once at import and never
  touched again - same as every other import path in this app.
- **Rounds, pairings, byes**: reconstructed by walking each player's
  per-round columns in starting-rank order and pairing up two players
  whenever they mutually reference each other for that round (opponent id
  + the opponent's own row pointing back). `PairingsEngine.Trf.parse/1`
  already guarantees any such *mutual* pair is a legal FIDE result
  combination (see `Trf.validate_games!/1`), so this only needs to check
  the reference actually is mutual. TRF16 has no board-number field -
  boards are assigned 1..N in that same discovery order, real games before
  byes (unpaired rows go last), matching the convention `SwarImport` uses
  for its own pairing-allocated byes.
- **Points cross-check**: TRF's own per-player points column (081-084) is
  never trusted outright - after import, points are recomputed from what
  was actually written to the database via the same code `TrfExport` uses
  (`PairingsEngine.Pairing.trf_player_rows/2`), and any player whose
  recomputed total disagrees by more than 0.01 is returned in the import
  result's `warnings` list. The import still proceeds either way; the UI
  shows a notice listing every mismatched player rather than blocking the
  import or silently overwriting the file's own figure.

## Result-code mapping

| TRF code | Meaning | Import result |
|---|---|---|
| `1` / `0` (mutual) | played win/loss | `"1-0"` / `"0-1"` |
| `0` / `0` (mutual) | played, both lose | `"0-0"` |
| `=` / `=` | draw | `"1/2-1/2"` |
| `+` / `-` | single forfeit | `"1-0FF"` / `"0-1FF"` |
| `-` / `-` | double forfeit | `"0-0FF"` |
| `U` | pairing-allocated bye | a `pairings` row, no black player, result `"bye"` |
| `H` | half-point bye | `byes` row, `type: "requested-half"` |
| `Z` | zero-point bye | `byes` row, `type: "requested-zero"` |
| `F` | full-point bye | **collapses onto the same `"bye"` row as `U`** - see below |

## Known limitations

- **`F` and `U` are not distinguished.** OpenPairings models exactly one
  "full points, no game" outcome - the pairing-allocated bye (a `pairings`
  row with no black player, worth the tournament's `bye_value`, default
  1.0). TRF16 distinguishes `U` (the pairing engine's own odd-player-out
  allocation) from `F` (an arbiter-awarded full-point bye for some other
  reason); both import to the same row. Points are correct either way;
  only the "why" is lost.
- **A playing code with an unresolvable opponent falls back to a bye**,
  reinterpreted by the point value it represents (`1`/`+` → full-point
  bye, `=` → half-point bye, `0`/`-` → zero-point bye) - the exact inverse
  of `PairingsEngine.Pairing.bye_safe_result/2`, which does the same
  normalization in the opposite direction for TRF export. This only
  applies to a genuinely dangling reference (the opponent doesn't exist in
  the file, or doesn't reference back for that round); an ordinary game
  between two players who are both present and agree with each other is
  never affected.
- **Teams (TRF16 `013` lines) are not imported.** Only individual
  tournaments are handled; a team TRF's `013` rows are silently ignored.
- **062/072/082 (player/rated-player/team counts) are not read** - they're
  derivable from the roster that's actually imported, so the app never
  needs to trust a header count that could disagree with the data.
- **`rating_type`, `points_win/draw/loss`, `bye_value`, `tiebreaks`,
  `acceleration` and every other non-TRF setting** are left at the
  `Tournament` schema's defaults - TRF16 has no header for any of them.
- A tournament imported from TRF always starts as a fresh **Swiss**
  (`pairing_system: "swiss"`) tournament regardless of what the file's 092
  line claims about round-robin - `type` (the FIDE-report classification)
  is still inferred from 092 for reporting purposes, but which pairing
  engine continues the tournament is always JaVaFo/Swiss.

## Encoding

TRF files exported by Windows chess software (SWAR and similar) are often
Windows-1252 encoded rather than UTF-8, which shows up as invalid UTF-8 bytes
in an accented player name (e.g. "Boûtchon", "Gaëtan"). `import_text/2`
detects this before parsing: a leading UTF-8 BOM (`EF BB BF`) is stripped
first, then the content is used as-is if it's already valid UTF-8, otherwise
it's decoded as Windows-1252 via `PairingsEngine.SwarImport.cp1252_decode/1`
(the same helper the `.swar` importer uses). This mirrors the identical
strip-BOM-then-detect pattern `PairingsEngine.Kbsb.Parser.parse/1` uses for
the KBSB rating-list import. Since every byte 0x00-0xFF has *some*
Windows-1252 mapping, the fallback itself never fails - content that's
neither valid UTF-8 nor a real TRF file still surfaces as an ordinary parse
error (e.g. "no player records") rather than a crash.

## Error handling

`TrfImport.import_text/2` never raises. It returns `{:error, reason}` for:
a parse failure (including content that isn't TRF16 at all - no `"001"`
player lines is treated as a parse failure, since `Trf.parse/1` itself
silently ignores unrecognized lines rather than raising on them),
`PairingsEngine.Trf.ValidationError` (an illegal or mutually inconsistent
result code), or a database validation failure (e.g. two players sharing a
FIDE id already used elsewhere in the same tournament). `error_message/1`
turns any of these into a single flash-ready string; the "Import TRF file"
panel shows it as an inline error block rather than crashing.
