# TRF import - TRF26 and TRF16 (`PairingsEngine.TrfImport`)

Imports a FIDE TRF file, TRF26 or TRF16 - the same format `PairingsEngine.TrfExport` and
`Ainalrami.Trf` already produce/consume for JaVaFo and the user-facing
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
  + the opponent's own row pointing back). `Ainalrami.Trf.parse/1`
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
- **Round verification**: since 0.49.0 every round the file records is
  checked against the pairing rules before the import returns, and a round
  that breaks one is reported as an `%{kind: :illegal_round, ...}` warning
  alongside the points mismatches. See "What the rounds are checked
  against" below for exactly what that covers.

## What the rounds are checked against

FIDE's VCL4THP asks (Q54) that an importing program verify the rounds it
imports rather than take them on trust. Before 0.49.0 this importer
recreated whatever the file said, board for board, and never asked whether
the file said anything legal - so an event carrying a rematch in round 5
imported clean and the app went on pairing round 6 from a position the
rules do not allow.

Each round is now replayed from the state that preceded it (the same
reconstruction `Ainalrami.CLI`'s Pairings Checker performs, on the parsed
players rather than on anything persisted) and scored with
`Ainalrami.Pairing.explain_round/3`. What is reported:

| Finding | Rule | Warning |
|---|---|---|
| A pair who had already met | C.04.1.b, no rematch | `reason: :rematch`, with `met_in_round` |
| Both players absolutely due the same colour | C.04.1.d | `reason: :colour`, with the `colour` both were due |
| A pair the file's own `260`/`XXP` prohibits for that round | C.05 5.2 | `reason: :forbidden` |
| A second pairing-allocated bye | C.04.1 C.2 | `reason: :bye`, with `bye_reason` |

Every warning carries `round:` and `players:` (names, not starting ranks),
and the Tournaments page turns them into a single arbiter-facing notice.

### What is deliberately NOT reported

- **"We would have paired this differently."** Only the ABSOLUTE criteria
  make a round wrong. Two conforming programs pick different rounds from
  the same position all the time - the quality criteria admit ties that
  transposition order breaks - so a difference from this engine's own
  choice is not a finding. That comparison exists, and it is a separate
  tool: `openpair -c`, whose own documentation is emphatic that a checker
  calls the same engine and therefore reports difference, not illegality.
- **Anything that is not a Dutch Swiss.** A round robin's schedule is
  fixed before a move is played: a double one rematches every pair by
  design, and even a single Berger table seats colour sequences the Dutch
  criteria forbid. Keizer is not the Dutch system, and neither are Dubov,
  Burstein, a match-format event or anything ETT26 calls CUSTOM. Judging
  any of those would report a correct file as broken, which teaches an
  arbiter to ignore the notice that matters. `192` decides where it is
  present; where it is absent the `092` label does, and a file that names
  no system at all is taken for the individual Swiss the rest of this
  importer already assumes it is. The one gap that leaves is a Keizer
  event with no `192` - Keizer has no FIDE code to declare and this app's
  own export always writes one (`CUSTOM_SWISS`), so that shape is a
  third-party Keizer TRF, which is not a thing anyone files.
- **Anything, if the check itself fails.** The whole pass is rescued and
  logged. Losing the verification must never lose the tournament.

The check never blocks an import. A file with an illegal round is
recreated exactly as it records it and the arbiter is told - the same
choice the points cross-check makes, and for the same reason: somebody
recovering a historical event needs the data more than they need our
opinion of it.

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
- **National Rating Support records and `172`** are not read, and neither
  are the team records (`013`, `300`, `310`, `320`, `330`, `352`, `362`,
  `801`, `802`).
- **A `260` limited to a range of rounds is widened to the whole event.**
  This app's forbidden pairings hold for every round, so "no clubmates in
  the first two" imports as "never". Widening is the safe direction - the
  engine will not seat a pair the arbiter separated - and the import says
  so rather than absorbing the change silently.
- **A full-point bye granted for a round not yet paired is not imported.**
  The `byes` table records the half-point and zero-point kinds an arbiter
  grants; a full point is a pairing's own allocation and needs the round
  to exist. Reported as a note.
- **Virtual points that Baku does not reproduce are not imported.** FIDE
  C.04.7 Baku is the one acceleration method this app implements, so a
  `250`/`XXA` line is applied only when that method produces the file's own
  numbers for this roster (see `import_acceleration/3`); anything else
  would be mislabelled and would pair the rest of the event differently
  from the way it started.

## What the tournament settings come from

Until 0.48.0 every setting below was parsed and then dropped, so a
re-imported tournament looked complete and was configured differently from
the one that left. What a file says now lands where it belongs:

| Record | Setting |
|---|---|
| `162` / `BB*` | `points_win`, `points_draw`, `points_loss`, `bye_value`, and `abs_value` when the zero-point bye differs from a loss |
| `192` | `pairing_system`, `pairing_engine` (`FIDE_DUTCH_2017` is JaVaFo, `FIDE_DUTCH_2026` Ainalrami), `rr_cycles`, and `acceleration` from a `_BAKU` suffix |
| `202` / `212` | `tiebreaks`, filtered to the codes this installation can compute |
| `142` / `XXR` | `rounds_count` - the tournament's length, which is not how much of it has been played |
| `250` / `XXA` | `acceleration`, when Baku reproduces the file's numbers |
| `260` / `XXP` | `forbidden_pairings` rows, every pair within each group |
| `240` | `byes` rows, for a round the file has not paired |
| `299` (untyped) | `players.extra_points`, and `count_extra_points` with them |

A code this app has no system for - Dubov, Burstein, a `CUSTOM_*`, a team
system - leaves the defaults alone rather than guessing, and the
plain-language `092` line still decides `type`.

## Encoding

TRF files exported by Windows chess software (SWAR and similar) are often
Windows-1252 encoded rather than UTF-8, which shows up as invalid UTF-8 bytes
in an accented player name (e.g. "Boûtchon", "Gaëtan"). `import_text/2`
detects this before parsing: a leading UTF-8 BOM (`EF BB BF`) is stripped
first, then the content is used as-is if it's already valid UTF-8, otherwise
it's decoded as Windows-1252 via `PairingsEngine.Encoding.cp1252_decode/1`
(the same helper the `.swar` importer uses). This mirrors the identical
strip-BOM-then-detect pattern `PairingsEngine.Federations.BEL.Parser.parse/1` uses for
the KBSB rating-list import. Since every byte 0x00-0xFF has *some*
Windows-1252 mapping, the fallback itself never fails - content that's
neither valid UTF-8 nor a real TRF file still surfaces as an ordinary parse
error (e.g. "no player records") rather than a crash.

## Error handling

`TrfImport.import_text/2` never raises. It returns `{:error, reason}` for:
a parse failure (including content that isn't TRF16 at all - no `"001"`
player lines is treated as a parse failure, since `Trf.parse/1` itself
silently ignores unrecognized lines rather than raising on them),
`Ainalrami.Trf.ValidationError` (an illegal or mutually inconsistent
result code), or a database validation failure (e.g. two players sharing a
FIDE id already used elsewhere in the same tournament). `error_message/1`
turns any of these into a single flash-ready string; the "Import TRF file"
panel shows it as an inline error block rather than crashing.

## TRF26

Since 0.47.0 (Ainalrami 0.22.0) the parser reads FIDE's Tournament Report File
Format Version 2026 as well: a `162` point system, `250` acceleration, `260`
prohibited pairings, `240` byes for a round not yet paired, `299` abnormal
point assignments (the global forms; one limited to a round or to named
players is refused rather than dropped), and the `192`/`202`/`212`/`222`
headers. The player rows are byte-identical between the two versions, so
there is one importer. Team records (`300` onwards, `310`, `801`, `802`) and
national-rating records are not read - see `Ainalrami.Trf`.
