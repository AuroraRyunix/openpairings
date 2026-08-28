# CSV results import

Bulk-enter a round's results from a CSV file instead of clicking through
each board's result `<select>` one at a time - handy when an arbiter already
has the round's results typed up (a spreadsheet export, a scanner app's
output, ...) and just wants to drop that file in. Implemented by
`PairingsEngine.ResultsImport`, wired up on the Pairings page
(`PairingsEngineWeb.PairingsLive`).

## File format

One line per board: `board,result` (or `;`-separated - the separator is
auto-detected per file, not configurable). An optional header row is
tolerated and skipped automatically (its first field won't parse as a plain
board number). Blank lines are ignored.

**The board number is the one printed on the pairing sheet.** For almost
every tournament that is also the board number the engine assigned, and
there is nothing to think about. They come apart only when a player has a
fixed table (Players -> Fixed table, for a wheelchair-accessible board or a
separate room): that pairing is labelled with its table number and printed
last, and the ordinary boards close the gap it leaves, so a pinned real
board 3 of 5 makes the sheet read 1, 2, 3, 4 against real boards 1, 2, 4, 5.

Type what the sheet says. Until 2026-08-28 this importer matched the
engine's number instead, so transcribing such a sheet wrote results onto
the wrong games and reported success.

A fixed table set to a number no ordinary board uses - SWAR's own range
starts at 1001 - has a label of its own and can be entered like any other
line. A fixed table deliberately set to a number an ordinary board already
uses produces two rows with the same label; there, that number means the
ordinary board, and the fixed table is entered from the Pairings page
instead.

```csv
board,result
1,1-0
2,0-1
3,1/2-1/2
```

### Accepted result tokens (case-insensitive)

| Token(s) | Meaning |
|---|---|
| `1-0` | White wins |
| `0-1` | Black wins |
| `1/2-1/2`, `½-½`, `0.5-0.5`, `=` | Draw |
| `0-0`, `X` | Both lose - game actually **played** |
| `1-0FF`, `+/-` | White wins by forfeit |
| `0-1FF`, `-/+` | Black wins by forfeit |
| `0-0FF`, `-/-` | Double forfeit - neither player showed up |

These map onto exactly the same result strings the inline result
`<select>` on the Pairings page writes (`PairingsEngine.Tournaments.Pairing`'s
`@results` list) - a CSV import and a manual click are indistinguishable
once saved.

### Encoding

The file is read as raw bytes: valid UTF-8 (with or without a leading BOM)
is used as-is; anything that isn't valid UTF-8 is decoded as Windows-1252
(reusing `PairingsEngine.SwarImport.cp1252_decode/1`, the same fallback the
SWAR importer uses) so a file saved by an older Windows spreadsheet tool
still imports cleanly.

## Partial entry is fine

A CSV only needs to mention the boards you actually have results for -
boards left out keep whatever result they already had (blank if nothing was
entered yet, or their existing result if you're correcting one board and
re-uploading). This is not a wholesale "replace the round" operation.

## All-or-nothing validation

Nothing is written to the database unless **every** line in the file is
valid. Two passes:

1. **Parsing** (`ResultsImport.parse_text/1`, no database access): malformed
   lines (wrong shape, unparsable board number, unrecognized result token)
   and duplicate board numbers *within the file itself* are collected -
   every bad line is reported, not just the first one.
2. **Applying** (`ResultsImport.apply_import/3`, needs the round's actual
   pairings): a board number that doesn't exist in the selected round, or
   that belongs to a bye (byes have no result to enter), is also collected
   as an error.

If either pass finds any problem, the whole import is rejected and the
Pairings page shows every collected error in a list - nothing is saved. Fix
the file and re-upload.

## Where it writes

`apply_import/3` calls `PairingsEngine.Tournaments.update_pairing_result/2`
- the exact same context function the inline result `<select>` calls - once
per board, inside a single transaction with per-write broadcasting
suppressed (mirroring `PairingsEngine.SwarImport`'s bulk-write pattern).
After the transaction commits, one `:results` broadcast fires and
`Tournaments.refresh_status!/1` recomputes round/tournament status, so any
other open tab (the public pairings page, the live round view, ...) updates
instantly, exactly as if the results had been entered by hand.

## Where the control lives

The Pairings page has an "Import results (CSV)" button next to the print
and PGN export links, for the currently selected round. Clicking it reveals
a drag-and-drop file panel (`live_file_input`, same pattern as the SWAR/TRF/
backup dropzones on the Tournaments page) with an "Import" button; a
successful import shows a flash with the number of results written, a
failed one lists every error inline and closes nothing.
