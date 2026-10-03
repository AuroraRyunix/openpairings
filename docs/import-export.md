# Import / export

OpenPairings has two, deliberately different, download/upload formats:

| | FIDE TRF26 export | Full JSON backup |
|---|---|---|
| Module | `PairingsEngine.TrfExport` | `PairingsEngine.TournamentExport` / `PairingsEngine.TournamentImport` |
| Purpose | Feed the result to FIDE, another pairing program, or a rating submission | Faithful backup/restore of a tournament inside OpenPairings itself |
| Direction | Export only | Export **and** import |
| Scope | One tournament, one chosen set of rounds | One tournament, or every tournament you own |
| Contains | Roster + round-by-round results, FIDE-report-shaped | Settings, officials, every player field (incl. norm data), teams, rounds, pairings/results, byes, forbidden pairings - see "What does not travel" below |

They solve different problems: TRF26 is what a rating office or another
program expects, and intentionally *doesn't* carry OpenPairings-specific
bookkeeping (extra points, norm judgment data, forbidden pairings, ...). The
JSON backup carries all of that, but nothing outside OpenPairings can read
it.

## FIDE TRF26 export

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

### TRF26, and the older spelling the pairing programs read

Since 0.47.0 the download is a **TRF26** file - FIDE's Tournament Report
File Format Version 2026, approved by Council on 12 May 2025 and applied
from 1 September 2025. The player rows are byte-identical to TRF16's; what
changed is the tournament section and the extension records, and this
export writes them in FIDE's own spelling:

  * **`142`** - the number of rounds represented in *this file* (a
    `?rounds=1-3` export of a 5-round tournament reports `142 3`, honestly).
  * **`152`** - the initial colour, when the tournament records one.
  * **`162`** - the point system, only when it is not 1 / half / 0 (a 3-1-0
    event, a half-point pairing-allocated bye).
  * **`182`** - `OpenPairings v<version>`, the program that produced the file.
  * **`192`** - the encoded type of tournament, from FIDE's code table
    (`TournamentTypeCodeTable192-TRF26`): `FIDE_DUTCH_2025` for a round
    paired by Ainalrami (before 0.69.0 this was written `FIDE_DUTCH_2026`,
    a code the table does not have; import still reads it),
    `FIDE_DUTCH_2017` for one paired by
    JaVaFo, `_BAKU` appended under Baku acceleration, `BERGER_ROUNDROBIN_Gn`
    for a round robin, `FIDE_TEAM_TYPEA_MP_GP` (or `BERGER_TEAM_ROUNDROBIN_Gn`
    for a team round robin) for a team event, and `CUSTOM_SWISS` for Keizer,
    which has no FIDE code.
  * **`202`** - the configured tie-breaks, which are already C.07's codes.
  * **`222`** - the rate of play, encoded (`90min/end+30sec/move from move
    1` is `5400+30`) where the wording allows it; a Bronstein delay or a
    free-text rate has no encoding and the line is left out.
  * **`250`** - Baku virtual points, one record per rank range per round
    range; **`260`** - prohibited pairings, explicit and by club or
    federation, for every round of the tournament.
  * **`240`** - a bye the arbiter has already granted for a round nobody
    has paired yet. Everything else in the report is a record of rounds
    played; this is the one forward-looking thing in it, because whoever
    pairs the next round from this file needs to know who is not playing.
    Only on a full export - a round slice is a historical excerpt.
  * **`299`** - a player's administrative extra points, the bonus or
    penalty the standings add on top of the game points. TRF's own points
    column is game points by definition, so before this the bonus left the
    building nowhere at all. Written only when the tournament counts them.
  * **A column ruler + field-code legend** before the player rows, a
    human-readability courtesy copied from Swiss-Manager. Not in the file
    sent for rating (below).
  * **`?`** - a postponed game still to be played (VCL4THP Q164-165),
    written for both players, with **`X`** in the `162` record at a draw's
    value, and scored at that value in the points column, so the file adds
    up from itself whatever the tournament counts a postponed game as. A
    game sent while still open stays `?` in every later copy; its played
    result goes in the postponed-games TRF (the Postponed games part of
    Settings, Export), never back into the round. **The file sent for
    rating never carries `?`** - see "The file sent for rating" below. A
    file carrying `?` is not a final report, and
    the Pairings page says so beside the export buttons while one is open.
    `Ainalrami.Trf.serialize/2` refuses `?`, so `TrfExport` writes the game
    as the draw the engine is handed and swaps the one character afterwards.
    The older spelling below keeps the draw, and scores it as one: it is
    read by pairing programs, which pair a postponed game as one and cannot
    read `?`. (Where a tournament counts a postponed game as something other
    than a draw, an outside pairing program or checker - JaVaFo, a FIDE
    pairing checker - cannot reproduce the rounds paired since from either
    download: the TRF26 file marks the game `?` but values it at a draw
    through `X`, and this one writes the draw itself. Only the app's own
    engine is handed the provisional points. The Pairings page says so in
    its note beside the export buttons.)
    On import, a `?` comes back as a postponed game.

    Until the change described under "The file sent for rating" below, the
    file sent for rating wrote the open game as `?` too, on the assumption
    that FIDE's rating server does not rate a `?` at the draw `X` says it is
    worth. FIDE never answered that question, so the file for rating no
    longer asks it: it leaves the open game out of the round instead.

`?dialect=javafo` on the download URL asks for the older spelling instead -
`XXR`, `XXP`, `XXA` and the `BB*` point lines - which is what JaVaFo,
bbpPairings and older checkers read. The file the app builds for its own
pairing engines is always that spelling (see `Ainalrami.Trf`'s "Two
dialects"), and the two spellings parse to the same tournament.

Team records (`300` onwards, `310`, `801`, `802`) and national-rating
records are not written; team pairing is not part of the app.

One thing this export deliberately does **not** do: reorder rows by final
standing. Both SWAR (inconsistently - its own row order doesn't even match
its own printed Rank column) and real-world testing showed Swiss-Manager
keeping rows in original starting-rank order, same as this app - TRF's
"Rank" column (086-089) is where final-standing order belongs, not physical
row position.

### Sending for rating, copies, and the postponed-games file

Only one download is the file for rating: "Send…" on Settings, Export
(`POST /t/:id/export/trf` with `finalise=true`), and "Send…" for the
postponed-games file. It builds the file and
records every game in it as sent in one write transaction
(`PostponedGames.send_rounds/4`), so the file exists only if the record
landed. The record (`trf_sent_games`) has a unique index - one `"sent"`
record per game per kind of file - and a second request for the same round
is refused with no file, however the two interleave. A copy that is locked
(handed off to another machine, archived) sends nothing.

Every other TRF download is a **copy**: "Download a copy", "All rounds",
the postponed-games file's "Download a copy", and a `POST` without
`finalise=true`. A copy's name ends `_COPY-NOT-FOR-RATING` (translated: in
Dutch `_KOPIE-NIET-VOOR-RATING`), and in the TRF26 spelling its text carries
a comment line after the header records:

```
### COPY - NOT FOR RATING. Round 1 of this file already went to the rating officer: ...
```

`###` is the comment form VCL4THP asks a program to write its own notes in
(`docs/design-fide-mode.md`, section 4); `Ainalrami.Trf.parse/1` skips it,
so a copy reads exactly as the file sent. No TRF record is added or
changed. Any download of a round already sent carries the line, whatever
route produced it. The older spelling (`?dialect=javafo`) carries no
comment line - it is read by pairing programs - and refuses to write a
round with an open postponed game at all: it has no `?` and would have to
write a draw that never happened.

**The file sent for rating.** Both files "Send…" hands out -
`TrfExport.export/3` with `for: :rating`, and `TrfExport.postponed_export/2`
without `copy: true` - look like the FIDE files SWAR sends, which the
FRBE→FIDE path accepts (SWAR v6.65, `EnvoiFIDE.cpp`): **only records**. No
column ruler, no `DDD` legend line and no comment line of any kind (`###`):
no copy mark, no "FIDE mode exited" note, no receipt line. The other TRF26
records (`142`, `152`, `162` for a point system other than 1/half/0, `192`,
`202`, `222`, `250`, `260`, `299`) are written as in any TRF26 download.

**And no unknown result.** A postponed game whose result is not known when
its round is sent is written as **not played** in that file, for both
players:

```
0000 - Z
```

- TRF26's zero-point bye, "Known absence from round - Not rated", the
columns SWAR writes for a round a player was not paired in (`0000 - Z`;
SWAR never writes an unknown result, it refuses to send a round with a
result missing). So there is no `?`, and no `X` in a `162` record. The game
counts zero in the points column (81-84) for both players, and the rank
column (86-89) follows the file's own games: where a game was written this
way, the places are taken from the file itself with its own tie-break list
(`212`, or the score then `202`), by the same `Ainalrami.Tiebreaks` a
checker reading the file uses; players still level keep the standings'
order among themselves. Every later file for rating that holds the round
writes the game the same way. Once played, it goes - with its result,
exactly once - in the postponed-games file, a FIDE tournament of its own.
So the game is never rated twice and never lost. A ½-0 is still `=`/`0`, a
played 0-0 `0`/`0` and a double forfeit `-`/`-`.

Every other file is unchanged by this: the copies, the TRF26 and engine
downloads, and the file the app hands its own pairing engine (which pairs a
postponed game as the draw it counts as) and `ainalrami -c` checks.

**The postponed-games file is a tournament of its own.** Late games are
reported in practice as a separate FIDE tournament ("Clubkampioenschap
25-26 uitgestelde partijen"), so that is what the file is: its `012` name
is the tournament's postponed-games name (default the event's name +
" postponed games", in Dutch " uitgestelde partijen", editable on Settings,
Export), its FIDE tournament ID is its own (`postponed_fide_tournament_id`,
in the file name like the main report's: `<X>_<its ID>_<its name>_<YYYY-MM>.trf`),
its `042`/`052` dates are the first and last day its games were played,
and it carries only those games. FIDE rates month by month, so one file
holds one rating period: a file mixing two months is refused, and the page
offers one file per month. A game with no date played belongs to no period
and waits until it has one.

**Which game a record is about.** Every board has a `game_uid`, given by
the database when the board is created and carried by every export,
snapshot and hand-off file. A sent record names the game by it, so a
restore that recreates the board under a new id - after a player's FIDE
ID was filled in, or a name corrected - still knows it. Records older than
the identity, and records of games no longer in the tournament, are
matched by round and players as before.

**The sent receipt.** Every send - a round's report or a postponed-games
file - also stores a receipt (`trf_sent_receipts`,
`PairingsEngine.SentReceipts`): proof a person can see of exactly what went
out, and what the tournament is compared with afterwards. It guards nothing
and replaces nothing: the sent-games record, its unique index and the
locked send still decide whether a send may happen; the receipt is written
inside that same transaction, after the record landed.

* **Fingerprint.** A SHA-256 over the kind of file, its round (or rating
  period), every game as sent - its `game_uid`, its round, both players'
  FIDE ID and name (so the colours too) and the result as sent (`?` for
  an open postponed game, which the file writes as not played) - ordered
  by identity, and the
  SHA-256 of the file's bytes as built. The same games, round and file
  always give the same fingerprint. Board numbers are not in it: a TRF has
  none. The receipt also keeps the games themselves, who sent it, when,
  and `final_sha256`, the hash of the bytes handed out.
* **Code.** `R5·7F2A` - the round and the fingerprint's first four hex
  digits - or `P·9C01` for a postponed-games file; six or eight digits when
  four would repeat a code the tournament already has. The Pairings page
  shows it beside a sent round ("Sent 03-10-2026 14:02 UTC · R5·7F2A",
  who sent it and the hashes in its tooltip), Settings, Export in the round
  table and under the postponed-games file, and the audit trail in the
  `trf.finalised` / `trf.postponed_sent` row.
* **Not in the file.** The file "Send…" hands out holds only records, so
  the receipt is not written into it: `final_sha256` is the hash of the
  file as built and handed out. (Before that change it carried a
  `### SENT FOR RATING. Receipt R5-7F2A: ...` comment line.) In a copy the
  code is written ASCII, with a hyphen for the dot.
* **Copies.** Every copy ("Download a copy", "All rounds") says per round
  whose copy it is, next to its `COPY - NOT FOR RATING` line:
  `### Round 5: copy of R5-7F2A (sent ...), not for rating.`,
  `### Round 6: never sent.`, or `sent before receipts`; a round that
  changed since it was sent adds that this copy is not what the rating
  officer has. A postponed-games copy says its games were never sent.
* **Drift.** The latest receipt of each round, and every postponed-games
  receipt, is compared with the tournament as it is now. A result
  corrected, a postponed game sent unplayed and played since but not yet in a
  postponed-games file, a player's FIDE ID or name changed, colours
  swapped, a game removed or one added: the round (on the Pairings page)
  and Settings, Export show a red "Changed since sent (R5·7F2A) — the
  rating body has the old version" listing each change. Nothing is ever
  sent again on its own; the round stays sent, and the correction goes to
  the rating officer. A game whose late result went out in a
  postponed-games file is that file's receipt's business, not its round's.
* **Sends before receipts.** No file sent before receipts existed was
  kept, so no code can be computed for one truthfully. The migration gives
  each such send a receipt marked "sent before receipts": no code, no
  fingerprint, and the games the sent-games record names (identity,
  players' keys, result as sent) - so a change to them is still detected.
  A round known sent only from its boards' marks (sent before the
  sent-games record existed) has no games on its receipt and shows no
  drift. A copy imported from a backup older than receipts gets the same.
* **Copies of the tournament.** The JSON backup carries the receipts
  (`"sent_receipts"`), and an import or a hand-off return adds them like
  the sent-games record (`origin` `"import"` / `"handoff"`), so a copy
  shows the same codes and tells the same drift. A restore never touches
  them.

### Where the export controls live

Settings, Export (`/t/:id/settings/export`) has an "Export TRF (all rounds)" link
(on the Pairings page until 0.65.x; a TRF is made after a round, not during
one, and the page used during play had no room for it)
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
      "tournament": { "name": "...", "type": "swiss", "tiebreaks": ["BH", "SB"], /* most Tournament fields - some are held back, see below */ },
      "openresults": { "key": "...", "slug": "...", "endpoint": "https://..." },  // or null - see below
      "teams":   [{ "id": 7, "name": "Team A", "captain": "..." }],
      "players": [{ "id": 42, "name": "...", "team_id": 7, "norm_data": {...}, /* every Player field except tournament_id/timestamps */ }],
      "rounds":  [{ "id": 3, "number": 1, "date": "...", "status": "finished",
                    "pairings": [{ "board": 1, "result": "1-0", "white_player_id": 42, "black_player_id": 43, "game_uid": "5acd..." }] }],
      "byes":               [{ "player_id": 42, "round": 2, "type": "pairing-allocated" }],
      "forbidden_pairings":  [{ "player_a_id": 42, "player_b_id": 43 }],
      "sent_games":          [{ "round": 1, "game_uid": "5acd...", "kind": "report", "sent_as": "1-0", "sent_at": "...", "white_key": "fide:...", "black_key": "name:...", "origin": "sent" }],
      "sent_receipts":       [{ "kind": "report", "round": 1, "code": "R1·7F2A", "fingerprint": "7f2a...", "file_sha256": "...", "final_sha256": "...", "games": [{ "game_uid": "5acd...", "sent_as": "1-0", ... }], "status": "receipt", "origin": "sent", "sent_at": "...", "sent_by": "arbiter@example.com" }],
      "audit_log":           [{ "action": "tournament.settings_updated", "details": {"changed_fields": {}}, "inserted_at": "...", "actor": "arbiter@example.com" }],  // only with include_handoff: true - see below
      "collaborators":       [{ "email": "co-arbiter@example.com", "role": "editor" }]  // only with include_handoff: true - see below
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

`"sent_games"` is the tournament's record of what it sent to the rating
officer (see "Sending for rating" above), and `"sent_receipts"` the
receipts of those sends, travelling the same way. A restore ignores it - the record
is never rolled back - but an import adds it to the new copy's record, as
sends another copy made, so a backup taken after round 1 was sent cannot
send round 1 again. A copy cannot know what the original sent after the
file was made, though: a tournament imported from a backup, TRF or
`.swar` file of an event that may already have been reported (it has a FIDE
tournament ID or is FIDE-homologated, something in it was sent, or - for a
TRF or `.swar` - a game in it has a result) sends nothing until an arbiter
confirms on Settings, Export that this copy is the one that reports
(`send_confirmation_needed`, audited as `trf.copy_confirmed`). That flag is
the import's, never the file's, and nothing clears it on its own. A
hand-off is the exception: the other copy is locked while this one carries
on.

A team tournament's matches travel too: each round carries a `"matches"`
list (`id`, match number, the two team ids) and each pairing a `"match_id"`
naming one of them, both remapped on import like player ids. Teams carry
their seeding order and frozen pairing number. See
[`team-tournaments.md`](team-tournaments.md).

### Writing a version 1 file by hand (required vs optional)

The shape above is what OpenPairings itself writes. A file written by
another tool needs much less - everything not listed as required may be
left out and takes the same default a tournament created in the app gets.

| Where | Required | Notes |
|---|---|---|
| envelope | `"format": "openpairings-export"`, `"version": 1`, `"tournaments"`: a non-empty array | `exported_at` is optional and not read. |
| each entry of `tournaments` | `"tournament"`: an object | `teams`, `players`, `rounds`, `byes`, `forbidden_pairings`, `sent_games`, `sent_receipts`, `openresults`, `audit_log`, `collaborators` are all optional; absent means empty. |
| `tournament` | `name` (string) | `type` defaults to `swiss` (else `roundrobin`, `team-swiss`, `team-roundrobin`), `rounds_count` to 9 - give both. Every other Tournament field is optional. `status` is not trusted: it is re-derived from what was imported, so `"setup"` with no rounds is fine. |
| each entry of `players` | an object with `name` | `id` is only needed when something else in the file points at the player (a pairing, a bye). `birth_date` (`YYYY-MM-DD`), `national_id` (string), `fide_id` (integer) are optional. |
| each entry of `rounds` | an object with `number` | `pairings` is optional; a pairing names its players by the file's player `id`s. |

Keys OpenPairings does not know (`club_number`, `affiliated`,
`organizer_club_number`, `event_code`, ...) are ignored, never an error.
Each entry of `teams`, `players`, `rounds`, a round's `pairings` and
`matches`, `byes` and `forbidden_pairings` must be a JSON object; anything
else is refused as *entry N of "players" is not a JSON object*. A value the
schema refuses is reported with the record it is in - *Could not import
player entry 2 (id 2): birth_date is invalid*, *Could not import the
"tournament" block: name is invalid* - and nothing is saved.

### What does not travel

The backup carries the tournament as an arbiter configured it, not the row
as the database holds it. A few of the tournament's fields are held back
(`TournamentExport.@excluded_tournament_fields`), in three groups:

- **Identity and ownership** - `id`, `user_id`, `inserted_at`, `updated_at`.
  An import always mints a new row owned by whoever imports it.
- **Things that would act on their own** - `public_slug`,
  `registration_open`, `publish_to_openresults`. Sharing has to be an
  explicit opt-in per tournament, never inherited from a file somebody was
  handed; an imported copy must get its own unguessable link rather than
  share the original's.
- **State that belongs to this machine** - `deleted_at`, `archived_at`,
  `swar_uploaded_at`, `swar_published_at`, `logo_data`,
  `logo_content_type`, `head_snapshot_id`, `openresults_key`,
  `openresults_claim`, the public-address and hand-off bookkeeping, and
  `send_confirmation_needed` (whether this copy was confirmed as the one
  that reports - decided by each import, see "Sending for rating" above).

The SWAR bookkeeping **does** travel: `swar_guid` (the tournament's identity
in SWAR and on the federation's results site), `swar_settings` (the imported
`.swar` file's own settings), `swar_category_type`/`swar_category_axis2`
(two-axis categories) and `categories_ranked_separately`. A restored copy
therefore exports the same `.swar` file as the original, byte for byte, and
a round robin continued from SWAR keeps SWAR's full-point free round
(`swar_backup_test.exs`). A backup from before these travelled restores with
the defaults (no guid - a new one is minted on the first SWAR export - and
no SWAR settings); restoring a restore point never takes away a guid the
tournament has since been given. "Duplicate" in the tournament list is the
one copy that drops the guid: it sits beside the original, so it gets its
own identity the first time it goes to SWAR. The same holds for any import
as a new tournament: when some tournament on this machine - whoever owns
it, in the recycle bin or not - already has the file's guid, the new one is
imported without it and the import says so
(`TournamentImport.import_with_notes/2`), because two tournaments with one
guid would upload to the federation's results site as the same event.
Moving to a new machine, or receiving a hand-off, finds no such tournament
and keeps it.

`openresults_key` is the one exception worth naming: it is not in the
tournament map but it does leave, in the entry's own `"openresults"` block
above, so a takeover can be offered deliberately rather than by accident.

Every **player** field does travel, which is why the shape above says so
without a caveat.

The hand-off lock itself never travels either, whatever option is passed:
`handed_off_at`, `handed_off_to`, `handoff_token` and `handoff_origin` are
excluded unconditionally, for the same reason as the rest of this list - see
[`handoff.md`](handoff.md) for why an imported or restored copy is always
live rather than arriving pre-locked.

### Hand-off blocks (opt-in): `audit_log` and `collaborators`

Two more blocks travel in the envelope, but only when the caller asks for
them: `TournamentExport.export_tournament/2` and `export_all/2` both take
`include_handoff: true`, which adds `"audit_log"` and `"collaborators"` to
each tournament entry above. An ordinary backup (the Settings page's
"Export / backup" card, "Export all (JSON)" on the Tournaments page) never
passes it, and the two keys are then simply **absent** - not an empty array,
since an empty array would claim the trail was empty when it was never taken
at all.

- **`audit_log`** - every audit row for the tournament, oldest first:
  `action`, `details` (with any database id inside it remapped to the
  matching record elsewhere in this same file, or dropped if it names
  something the file doesn't carry - a pairing, a snapshot, another
  tournament), `inserted_at`, and `actor` - the acting user as an email
  string, never as an id. A user id from another installation is meaningless
  here, and could even collide with an unrelated real account on the machine
  that imports it.
- **`collaborators`** - who the tournament was shared with: `email` and
  `role` only, nothing that identifies a local account. On import each one
  is filed as a fresh, PENDING invitation - nobody gains access because the
  file arrived, no email is sent, and every person has to accept again on
  whichever machine now holds the tournament.

**Why opt-in.** `export_tournament/1` with no options is not only the plain
backup route - it is also the function behind every restore point
(`PairingsEngine.Snapshots.capture/4` calls it, unqualified, before every
destructive action) and behind "Duplicate tournament"
(`PairingsEngineWeb.TournamentsLive`), which round-trips a copy through
export and import to produce "Copy of ...". Neither of those is a hand-off:

- A restore point is this tournament's own past - the audit trail and the
  collaborator list never left in the first place, so embedding the whole
  log in every single snapshot would multiply each one by the length of the
  history it is attached to, for data that already lives in its own table.
- A duplicate is a new event. The original's audit trail describes actions
  nobody took in the copy, and carrying its collaborator list across would
  turn duplicating a tournament into a fresh round of invitations for people
  who were never asked about the copy at all.

So both blocks default to off, and the one caller that actually moves a
tournament between machines - `PairingsEngine.Handoff` - is the one that
passes `include_handoff: true`. See [`handoff.md`](handoff.md) for that flow,
including the third, hand-off-only block (`"handoff"`, carrying the unlock
token) that wraps this envelope and is not part of the export format itself.

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

1. Measures the file on disk and refuses anything past
   `TournamentImport.max_bytes/0` (10 MB) **before reading it**, then reads
   and decodes it. The order matters: decoding a megabyte of JSON costs
   between 5 and 11 megabytes of memory depending on shape, so a size check
   that happened after the decode would be checking a bill already paid.
   The 10 MB itself is measured rather than picked - a 400-player,
   13-round tournament with a 2,000-row audit trail exports at 220 KB, and
   the largest Swiss ever played scales to about 5 MB. A file holding a
   dozen such events at once is refused with a note to export in batches;
   the machine backup (`PairingsEngine.Backup`, compressed and never on
   this path) is the tool for a whole archive. The same limit feeds the
   upload box's `:max_file_size`,
   so the browser refuses early and the server refuses regardless.
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
5. Last, and only if the envelope actually carries them: `audit_log` rows
   (with any player id inside `details` remapped the same way) and
   `collaborators` (filed as pending invitations). This importer doesn't
   care *how* the file got here - a hand-off file opened through this same
   "Import backup" panel, instead of the dedicated "Receive a hand-off"
   screen, still brings its audit trail and its team across; it just
   doesn't unlock anything, because that needs the separate `"handoff"`
   block this route never looks at. See [`handoff.md`](handoff.md).

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

This is specifically about the "Import backup (JSON)" panel and
`TournamentImport.import/2`. A sibling function,
`TournamentImport.restore_into!/2`, *does* overwrite - it wipes an existing
tournament's contents and re-imports the envelope into that same row rather
than minting a new one. Nothing in this UI calls it directly; it is what a
restore point uses to bring an earlier state of a tournament back, and what
`PairingsEngine.Handoff.release/3` uses to apply a returning hand-off file
before unlocking - see [`handoff.md`](handoff.md) for that flow.

### Round-trip integrity

The property that actually matters - export a tournament, import it back,
and the copy is indistinguishable from the original in every way a user
would notice (same players, same round-by-round results, same standings and
points) - is asserted directly in
`test/pairings_engine/tournament_import_test.exs`, both for a single
tournament and for a multi-tournament `export_all` envelope.
