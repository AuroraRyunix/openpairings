# PGN export

`GET /t/:id/export/pgn?round=N&board=1` downloads a metadata-only PGN file
(`application/x-chess-pgn`, `Content-Disposition: attachment`, filename
`<tournament-slug>.pgn`) built by `PairingsEngine.PgnExport`. Owner-scoped
the same way every other export route is
(`Tournaments.get_authorized_tournament!/2` — a tournament id you don't own
or collaborate on 404s).

## Why "metadata-only"

OpenPairings never records moves — there's no move-entry UI anywhere in the
app. So a PGN export here is exactly what the app actually knows about each
game: who played whom, in which round, with what result. Each game's
"movetext" is just its result token (or `*` when the result is unknown), no
actual moves. This is still a legal PGN file — the Seven Tag Roster header
is all a PGN reader strictly requires — just not a game you can replay.

## The `round` query parameter

Omit `round` (or pass anything that doesn't parse as an integer) to export
every paired round, one game per non-bye pairing, in round order. Pass
`?round=N` to export only round `N`'s games. A round that hasn't been
paired yet (or doesn't exist) simply contributes no games — never a 404 —
so `?round=99` on a 9-round tournament downloads an empty file rather than
erroring, same spirit as `TrfExport.parse_rounds/2`'s "unparsable/
out-of-range silently drops" behavior (see `docs/import-export.md`).

Byes are always skipped — there's no opponent to record a game against.

## The `board` query parameter

Omit `board` (or pass anything other than `1`) to leave board numbers out
entirely — the export's long-standing default. Pass `?board=1` to add a
supplemental `[Board "N"]` tag to every game, right after `Round`. `N` is
the same DISPLAY board number every other view in the app shows
(`PairingDisplay.with_display_boards/1`: fixed-table pairings relabeled to
their fixed board and moved to the end, byes/vacant seats excluded from the
renumbering) — not the raw stored `pairing.board` — so it matches what an
arbiter actually sees on the pairing sheet for that game.

## Header (Seven Tag Roster) mapping

| Tag | Source |
|---|---|
| `Event` | Tournament name |
| `Site` | Tournament venue if set, else city, else `"?"` |
| `Date` | The round's own date (`"YYYY.MM.DD"`), or `"????.??.??"` if the round has no date set |
| `Round` | The round number |
| `Board` | Only with `?board=1` — see above |
| `White` / `Black` | Player names, exactly as stored (already `"Last, First"` for anyone imported from SWAR/TRF/FIDE data) |
| `Result` | See below |

Two more pairs are added when the data is known, omitted otherwise:

- `WhiteElo` / `BlackElo` — FIDE rating if the player has one, else national
  rating, else omitted entirely (never `"0"`).
- `WhiteFideId` / `BlackFideId` — only when the player has a FIDE id on
  file.

### Result mapping

| Stored result | PGN `Result` tag |
|---|---|
| `1-0` | `1-0` |
| `0-1` | `0-1` |
| `1/2-1/2` | `1/2-1/2` |
| `1-0FF` (white wins by forfeit) | `1-0` — forfeits carry a nominal decisive result even though the game was never played |
| `0-1FF` (black wins by forfeit) | `0-1` |
| `0-0FF` (double forfeit), `0-0` (both lose, played), blank/not yet entered | `*` — PGN's own "unknown result" marker; a double forfeit or a played double-loss has no single-sided PGN equivalent to fall back to |

Header values are escaped per the PGN spec (`\` and `"` are backslash-escaped
inside the quoted string) before being written.

## Where the control lives

The Pairings page has an "Export PGN" link next to the print and TRF export
links, scoped to the currently selected round (`?round=<selected round>`) —
plain `GET`/`<a target="_blank">`, so it opens in a new tab without routing
through the LiveView socket, same as every other export/print link there.
Right-click it (same `.PrintMenu` hook the "Print pairings"/"Print result
cards" buttons use) for three more variants: this round with board numbers,
every round, and every round with board numbers.
