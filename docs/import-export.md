# Import / export

OpenPairings has two, deliberately different, download/upload formats:

| | FIDE TRF16 export | Full JSON backup |
|---|---|---|
| Module | `PairingsEngine.TrfExport` | `PairingsEngine.TournamentExport` / `PairingsEngine.TournamentImport` |
| Purpose | Feed the result to FIDE, another pairing program, or a rating submission | Faithful backup/restore of a tournament inside OpenPairings itself |
| Direction | Export only | Export **and** import |
| Scope | One tournament, one chosen set of rounds | One tournament, or every tournament you own |
| Contains | Roster + round-by-round results, FIDE-report-shaped | Everything the app models: settings, officials, every player field (incl. norm data), teams, rounds, pairings/results, byes, forbidden pairings |

They solve different problems: TRF16 is what a rating office or another
program expects, and intentionally *doesn't* carry OpenPairings-specific
bookkeeping (extra points, norm judgment data, forbidden pairings, ...). The
JSON backup carries all of that, but nothing outside OpenPairings can read
it.

## FIDE TRF16 export

`GET /t/:id/export/trf` downloads a `.trf` text file (`text/plain`,
`Content-Disposition: attachment`, filename
`<X>_<fideid>_<tournament-slug>_<rounds>.trf`) for the tournament,
owner-scoped the same way every other tournament route is
(`Tournaments.get_user_tournament!/2` - a tournament id you don't own 404s).

  * `<X>` is `B`/`R`/`S` for `tournament.standard` (blitz/rapid/standard).
  * `<fideid>` is whichever FIDE tournament ID applies to the exported round
    range - a configured `fide_id_ranges` entry if one fully covers it, else
    the tournament-wide `fide_tournament_id`, omitted entirely if neither
    resolves (see `PairingsEngine.TrfExport.applicable_fide_id/2` and the
    FIDE settings page).
  * `<rounds>` is a compact descriptor of the exported round span, e.g.
    `r1-5`, `r1-3+8` for a non-contiguous selection.

Only players who have actually been included in a paired round (i.e. have a
`pairing_number`) are included - a player added after the fact who was
never paired has nothing meaningful to report.

### Round selection: the `rounds` query parameter

By default the export includes every round that's been paired so far. Pass
`?rounds=...` to narrow it down. The syntax (parsed by
`PairingsEngine.TrfExport.parse_rounds/2`) accepts a comma-separated mix of
single round numbers and dash ranges:

| Example | Meaning |
|---|---|
| `?rounds=1-5` | Rounds 1 through 5 |
| `?rounds=1,2,4` | Rounds 1, 2 and 4 only |
| `?rounds=1-3,6,8-9` | Any mix of ranges and singles |

Tokens are deduped and sorted, and clamped to `1..<latest paired round>` -
asking for round 12 of a 9-round tournament (or a round that simply hasn't
been paired yet) silently drops that token rather than erroring. If nothing
valid remains after parsing (a typo, an empty string, or the param omitted
entirely), the export falls back to every paired round.

Selecting a subset doesn't just hide columns cosmetically: each player's
`:games` list is filtered down to exactly the chosen rounds before the TRF
is built, so the file only ever contains that many round-columns per player
(TRF16's round data is purely positional - there's no round-number field in
the row itself). Points are recomputed from the filtered games only, and
the header's round-dates ("132") line is filtered to match. This is the
same computation used by
[round-scoped standings for printing](printing.md#round-scoped-standings-how-its-computed) -
trimming the game set before computing anything downstream, rather than
computing everything and truncating the display.

### Validation

`Ainalrami.Trf.serialize/2` (shared with the JaVaFo pairing input
builder) validates every result code and every mutually-referencing pair of
opponents before returning text, raising `Ainalrami.Trf.ValidationError`
on anything illegal. One error type for the condition, and one
implementation raising it: the app used to carry its own `PairingsEngine.Trf`
as well, serialising with that and then handing the text to Ainalrami's
parser on the pairing path, so a file was written by one implementation and
read by another.
`TrfExport.export/2` catches that and returns
`{:error, %Ainalrami.Trf.ValidationError{}}` instead of letting it raise;
`PairingsEngineWeb.ExportController.trf/2` turns that into a flash message
and redirects back to the Pairings page - never a raw 500. In practice this
can only happen with data corruption that bypassed the app entirely (see the
test suite for how it's provoked), since every route that actually **writes**
results keeps opponents' recorded results consistent with each other by
construction.

### Beyond the official TRF16 fields: `142`, `182`, and the column legend

Real-world TRF exports (SWAR, Swiss-Manager) all extend TRF16 with a handful
of extra, unofficial-but-harmless header lines and a readability aid, so this
export matches:

  * **`142`** - number of rounds represented in *this file* (following the
    same round-selection filtering as everything else - a `?rounds=1-3`
    export of a 5-round tournament reports `142 3`, honestly). Not part of
    official TRF16, but Swiss-Manager already emits it, and it's one of the
    handful of fields FIDE's TRF25/26 draft extension formalizes.
  * **`182`** - `OpenPairings v<version>`, naming the program that produced
    the file (Swiss-Manager does the same with its own name/version).
  * **A column ruler + field-code legend** (`DDD SSSS sTTT NNN...`, plus two
    position-marker lines) inserted right before the player rows - purely a
    human-readability courtesy for whoever opens the raw file in a text
    editor, copied from Swiss-Manager's own convention.

All three are additive and inert to any TRF16 reader: an unrecognized header
code (or a line that doesn't start with one of the three-digit codes at all)
is silently skipped, both by spec convention and by this app's own
`Ainalrami.Trf.parse/1`. They're opt-in via `Trf.serialize/2`'s
`column_legend: true` (and the `number_of_rounds`/`generator` tournament
fields) - `TrfExport` turns them on; the JaVaFo-input path
(`PairingsEngine.Pairing.javafo_input/4`) never does, since JaVaFo is a far
more fragile consumer and has no use for any of this.

One thing this export deliberately does **not** do: reorder rows by final
standing. Both SWAR (inconsistently - its own row order doesn't even match
its own printed Rank column) and real-world testing showed Swiss-Manager
keeping rows in original starting-rank order, same as this app - TRF's
"Rank" column (086-089) is where final-standing order belongs, not physical
row position.

### Where the export controls live

The Pairings page (`/t/:id/pairings`) has an "Export TRF (all rounds)" link
plus a small `rounds=` text field for a subset - both are plain
`GET`/`<a target="_blank">`/`<form method="get" target="_blank">`, so
middle-click / open-in-new-tab work and nothing routes through a LiveView
socket.

## Full JSON backup (`PairingsEngine.TournamentExport` / `TournamentImport`)

### Envelope format

```jsonc
{
  "format": "openpairings-export",
  "version": 1,
  "exported_at": "2026-07-11T12:00:00Z",
  "tournaments": [
    {
      "tournament": { "name": "...", "type": "swiss", "tiebreaks": ["BH", "SB"], /* every Tournament field except id/user_id/timestamps */ },
      "openresults": { "key": "...", "slug": "...", "endpoint": "https://..." },  // or null - see below
      "teams":   [{ "id": 7, "name": "Team A", "captain": "..." }],
      "players": [{ "id": 42, "name": "...", "team_id": 7, "norm_data": {...}, /* every Player field except tournament_id/timestamps */ }],
      "rounds":  [{ "id": 3, "number": 1, "date": "...", "status": "finished",
                    "pairings": [{ "board": 1, "result": "1-0", "white_player_id": 42, "black_player_id": 43 }] }],
      "byes":               [{ "player_id": 42, "round": 2, "type": "pairing-allocated" }],
      "forbidden_pairings":  [{ "player_a_id": 42, "player_b_id": 43 }]
    }
  ]
}
```

`format`/`version` identify the envelope so a garbage or foreign file is
rejected up front rather than partially imported. `"id"` on teams/players/
rounds is **not** a promise about anything outside this one JSON file - it
only lets sibling records within the same envelope point at the right team/
player (a pairing's `white_player_id`, a bye's `player_id`, ...). The owning
user is never included: who exported a tournament has no bearing on who can
import it.

`matches` (team-match boards) isn't included: nothing in the app writes to
that table yet (team tournaments don't have a matches UI), so there's
nothing to round-trip there today.

### The `openresults` block is a credential

Present only for a tournament that has actually published to an OpenResults
server; `null` (in practice, absent) for every other one. It holds that
tournament's **publishing key** and the address the key is authority over.

**Anyone holding a file with this block can update the published copy of
that tournament, or delete it - its public page, every earlier snapshot in
its history, and any entries its form collected.** Treat such a file like a
password. The app says so wherever it offers an export that would carry one.

It travels on purpose, and it is the one deliberate exception to the rule
that sharing state stays on the machine that owns it. Rebuilding a laptop
from a backup has to recover the ability to manage what that laptop
published; a key left on the dead disk strands a tournament full of player
names, ratings and clubs in public with nobody able to take it down.

`public_slug` and `publish_to_openresults` keep their exclusions unchanged,
which is why the address is repeated inside this block rather than the slug
field being un-excluded. The imported copy still gets its own fresh public
link and still has to opt in to publishing.

**Importing never adopts the key.** It is stored dormant on the new row
(`tournaments.openresults_claim`), nothing in the publishing path reads it,
and the imported copy behaves as a different tournament: turning publishing
on gives it a new address under a new key of its own. If the key were
adopted automatically, two people importing the same file would both believe
they owned that tournament, both publish to the same slug, and either could
delete the other's work.

Taking the published tournament over is a separate, explicit action on
Settings → Tournament ("Take over publishing it", beside "Start fresh"),
which moves both the key and the address onto this row. It lives there
rather than in the import flow for two reasons: one envelope can hold dozens
of tournaments, and a machine being rebuilt from backups usually has not
been told the results site's address yet - so import time is the worst
possible moment to demand the decision. Doing nothing is the safe branch and
requires no button.

Duplicating a tournament ("Copy of ...") strips the block, even though it
runs through the same export → import round trip. The original is still
right there and still publishing; offering its copy a takeover would put two
rows one click away from fighting over one address.

### Export routes

Both owner-scoped, downloaded as `application/json`:

| Route | Contents | Filename |
|---|---|---|
| `GET /t/:id/export/json` | One tournament | `<tournament-slug>.json` |
| `GET /export/tournaments.json` | Every tournament the current user owns | `openpairings-export-<date>.json` |

Found on the Settings page ("Export / backup" card) for a single
tournament, and on the Tournaments page ("Export all (JSON)", plus a
per-row "Export" link) for the rest.

### Import

There's no `GET` import route - a file upload needs a form, so it lives on
the Tournaments page (`PairingsEngineWeb.TournamentsLive`) as an "Import
backup (JSON)" panel using `live_file_input`, parallel to the existing SWAR
import panel. Importing:

1. Reads and `Jason.decode!`s the uploaded file.
2. Validates the envelope's `format`/`version`/`tournaments` shape. Anything
   that doesn't match is rejected with a flash - no crash, no partial write.
3. For **every** tournament in the envelope (one for a single-tournament
   export, one-or-more for `export_all`), inserts a brand-new tournament
   row owned by the importing user, then teams, then players, then rounds
   (each with its pairings), then byes, then forbidden pairings - in that
   order, because each later step needs the previous step's *new* ids.
4. Every reference to an old id (a player's `team_id`, a pairing's
   `white_player_id`/`black_player_id`, a bye's/forbidden-pairing's player
   ids) is rewritten through an old-id → new-id map built as each record is
   inserted, so the imported tournament shares **no** ids with the source -
   not the tournament, not a single player, round or pairing.

The whole thing runs inside one `Repo.transaction` (broadcasts suppressed
until it commits, then `Tournaments.broadcast_user_tournaments/1` fires
once) - if anything fails partway (a malformed sub-record, a changeset
validation error), the transaction rolls back and nothing is left behind.
Byes and forbidden pairings referencing a player id that doesn't resolve
(only possible from a hand-edited file) are skipped individually rather than
failing the whole import, since they're not load-bearing for the rest of
the tournament.

**Importing never overwrites anything.** A re-imported tournament is always
a new tournament owned by whoever ran the import - including re-importing
your own export back into your own account. If you want a real backup/
restore workflow, that's the point: nothing is destructive.

### Round-trip integrity

The property that actually matters - export a tournament, import it back,
and the copy is indistinguishable from the original in every way a user
would notice (same players, same round-by-round results, same standings and
points) - is asserted directly in
`test/pairings_engine/tournament_import_test.exs`, both for a single
tournament and for a multi-tournament `export_all` envelope.
