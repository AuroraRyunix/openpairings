# KBSB/FRBE national rating list

Local copy of the Belgian national rating list (KBSB/FRBE - Koninklijke
Belgische Schaakbond / Fédération Royale Belge des Échecs), used to look up
players' national ID, national rating, club and FIDE ID when registering
them for a tournament. Mirrors the existing FIDE rating sync
(`lib/pairings_engine/fide/`) in almost everything except *how* the data
arrives.

The code lives in `lib/pairings_engine/federations/bel/` -
`PairingsEngine.Federations.BEL.{Members, Member, Http, SqliteFile, Clubs,
Club, Settings, Parser, Sync}` - with the rest of the Belgium-specific
code. The table it fills is still called `kbsb_players`, and stays called
that; see `Member`'s moduledoc for why.

**2026-09-13: the KBSB data-platform API source
(`PairingsEngine.Federations.BEL.Api`, `KBSB_API_URL`/`KBSB_API_KEY`) and
the OpenResults relay source (`PairingsEngine.Federations.BEL.
ResultsSource`) were both removed.** KBSB's IT admin confirmed the
federation publishes the full player list publicly every month (below),
which both of those sources existed to work around before it did.

## Switched on per account

All of this is optional and off by default. Three of the five switches on
`/users/features` cover it (see `PairingsEngine.Features` and
docs/architecture.md): `bel_ratings_sync` puts the panel on the
Connections page and lets the sync be started; `bel_player_lookup` and
`bel_club_sync` turn on the two things that READ the table it fills. They
are independent - with the sync off, the lookup and the club update
search whatever was last downloaded, which is a legitimate way to work.

Nothing here is ever gated on the DOMAIN side. Switching the pack off
hides buttons; it does not touch a row already in `kbsb_players`, nor any
`national_id`, `national_rating`, `club` or `club_number` already on a
player.

## Data source: KBSB's public monthly file

KBSB publishes the full player list publicly every month, at:

```
https://www.frbe-kbsb.be/sites/manager/ELO/players_{YYYYMM}.zip
```

(e.g. `players_202608.zip` for August 2026) - a zip of about 1.8 MB
containing `players.sqlite` (about 4 MB), with one table, `players`, of
about 36,000 rows, indexed on club and name (`IdxClub`, `IdxName`). Both
hosted and desktop installs sync from this URL directly, identically -
there is no distinction between them any more (the old split existed only
because the removed data-platform key could never ship inside a desktop
release).

### The setting

**"Belgian rating list URL"**, under the Connections page's Belgian
panel (`PairingsEngine.Federations.BEL.Settings.players_url/0`, stored in
`meta` - see `PairingsEngine.Meta` - not an env var, so it is identical to
edit on hosted and desktop). Defaults to the template above; `{YYYYMM}` is
expanded to the current year and month (`PairingsEngine.Federations.BEL.
Http.fetch_players/1`). A value with **no** `{YYYYMM}` placeholder is used
exactly as configured, unchanged from month to month - a fixed mirror, or
a pinned single-month file.

### Month fallback

KBSB answers a request for a month not yet published with an HTTP **301**
(not 404). Trying the current month first, `Http.fetch_players/1` steps
back one month at a time - also on a 404 or 403, defensively - up to 3
months before giving up.

### Conditional GET

The `ETag` (falling back to `Last-Modified`) from the last successful
fetch of each RESOLVED url is remembered (one `meta` entry per URL) and
sent back as `If-None-Match` / `If-Modified-Since`. A 304 means the file
hasn't changed since last time, and the sync reports `:unchanged` rather
than re-downloading and re-importing an identical file.

### Caps

The zip is capped at 20 MB compressed (the real file is ~1.8 MB); what
`players.sqlite` may declare it inflates to is capped at 100 MB,
checked via `:zip.list_dir/1` **before** anything is inflated - the same
zip-bomb defence `PairingsEngine.Fide.Sync` uses. A 15s connect / 60s
receive timeout bounds the request itself.

### Reading the file

The zip is unpacked to a temp file; `players.sqlite` is opened
**read-only** with exqlite (`PairingsEngine.Federations.BEL.SqliteFile`).
Its `players` table and every required column (`IdNumber`, `Name`, `Sex`,
`Birthday`, `Fed`, `Club`, `Affiliated`, `Elo`, `EloPrevious`, `Gain`,
`Games`, `GamesPrevious`, `Performance`, `Opponents`, `LastGames`,
`Border`, `Arbiter`, `NatPlayer`, `NatFideSign`, `G`, `Died`, `FideId`)
are validated before anything is read; a missing table or column is a
clear error, not a silent partial import. `LoginModif` and `DateModif`
are **not** in that list - they are never read at all. The temp file is
always removed in an `after`, import or not.

The rows are then imported through the existing count-guard, full-replace
path into `kbsb_players` (`Sync.import_rows/3` - unchanged), and the
resolved month is recorded and shown ("August 2026 list" -
`Members.source_month/0`).

## Club names

`players.sqlite` carries no club NAMES - only `Club`, a bare club number.
Three sources, in this precedence, decided fresh on every sync
(`PairingsEngine.Federations.BEL.Clubs.resolve/2`):

1. **A `clubs` table inside the same `players.sqlite`.** Confirmed against
   the real file (`players_202608.zip`, republished 2026-09-13):

   ```sql
   CREATE TABLE clubs
   (
       Club       INT NOT NULL
           PRIMARY KEY,
       Name       VARCHAR(100),
       Federation VARCHAR(20)
   );
   ```

   131 rows in the real file. `Name` is nullable in the schema (though no
   row had a blank one on 2026-09-13) - a NULL or blank `Name` is treated
   the same as no row at all for that club. `Federation` (`VSF`/`FEFB`/
   `SVDB` - the Flemish, francophone and German-speaking wings) is
   **ignored**: only `Club` and `Name` are read, so an extra column here
   is harmless and nothing here depends on it being present.

   Not every club number in `players.Club` has to have a row - KBSB's
   real file has 6 that don't (all clubs with `Affiliated = 0` players
   only, i.e. defunct clubs). Those show by their bare number, same as
   any other unmatched club - never a reason to fail the import.

   Matched case-SENSITIVELY as `Club`/`Name` first; a wider
   case-insensitive alias list (`IdClub`/`ClubNumber` for the number,
   `ClubName` for the name) is a **lenient fallback only**, in case a real
   export ever differs from this shape. Detected automatically - no
   setting. Older monthly files with no `clubs` table fall through to
   source 2.

2. **The "Belgian club names URL" setting**
   (`PairingsEngine.Federations.BEL.Settings.clubs_url/0`) - a second,
   independent, optional file, fetched the same way as the players list
   (conditional GET, size cap, timeout). Either:
     - CSV with a header naming `number` and `name` columns (order and
       any other columns don't matter), or
     - JSON, as either `[{"number": 417, "name": "..."}]` or
       `{"417": "..."}`.

   Format is auto-detected (a `.json` URL, or a body starting with `{`
   or `[`, is parsed as JSON; anything else as CSV).

3. **Whatever `kbsb_clubs` already has on file.** This is a SEPARATE,
   durable table (`PairingsEngine.Federations.BEL.Club`/`Clubs`) that
   survives a full player-roster replace - a name learned once is kept
   even if a later month's zip omits its `clubs` table, or the clubs URL
   goes offline for a while. A name from source 1 or 2 is upserted into
   it (source 1 wins on overlap with source 2), so it only ever grows
   more current, never loses a name to an absent source.

A club with no name known from ANY of the three is shown by its **number**
in the UI (`Member.club_label/1`, e.g. `"#417"`) rather than hidden or
guessed at. This is what `bel_club_sync`
(`PairingsEngine.Federations.BEL.ClubRefresh`) and the Players page both
read - `club_name` is still resolved and stored denormalized onto each
`kbsb_players` row at import time (unchanged from before), so neither of
those readers needed to change.

## Fields stored - only what a feature reads

`Member`'s schema, and what's dropped from the source file:

| Stored | Source column | Notes |
| --- | --- | --- |
| `national_id` | `IdNumber` | primary key, kept as a string |
| `last_name` / `first_name` | `Name` | split on the first comma ("Last, First") |
| `national_rating` | `Elo` | |
| `fide_id` | `FideId` | |
| `club_number` | `Club` | |
| `club_name` | (resolved) | see "Club names" above |
| `federation` | `Fed` | |
| `birth_year` | `Birthday` | **year only** - the leading 4 digits. The full birth date is never stored: no feature reads a day of birth, only the year (`ClubRefresh.year_agrees?/2`) |
| `died` | `Died` | boolean (`1`/`0` -> `true`/`false`) |
| `affiliated` | `Affiliated` | boolean, same conversion |

Never stored, from anywhere: `Sex`, `EloPrevious`, `Gain`, `Games`,
`GamesPrevious`, `Performance`, `Opponents`, `LastGames`, `Border`,
`Arbiter`, `NatPlayer`, `NatFideSign`, `G`, and - deliberately, always -
`LoginModif`/`DateModif`, which are not even read off disk.

### `Affiliated` and `Died`

The file is unfiltered - archived, deceased and non-affiliated members
included, same as the removed data-platform API mirrored. That decision
carries over unchanged: `kbsb_players` stores `died` and `affiliated`,
exact id lookups (`Members.find_by_national_id/1`,
`Members.find_by_fide_id/1`) still resolve a deceased or unaffiliated
member (an arbiter typing a matricule wants an answer), and
`Members.name_index/0` excludes the deceased so a living player cannot
inherit a dead namesake's club. Neither flag ever filters what gets
IMPORTED - only what a lookup is willing to match a live player onto.

## The uploaded file (manual fallback)

Still available, unconditionally - the original fallback, and the only
option with no network path at all. It now accepts, auto-detected by
content (`PairingsEngine.Federations.BEL.SqliteFile.zip?/1`/`sqlite?/1`):

- **The same monthly zip** KBSB publishes, or
- **A bare `players.sqlite`** (the file the zip contains), or
- **The older delimited-text format** (unchanged - see "File format"
  below), for whatever a director already had on hand from before.

A zip or sqlite upload goes through the exact same `SqliteFile.read/1` +
`Clubs.resolve/2` path as the HTTP sync (minus the clubs-URL round trip,
since an upload has no network expectation - only a bundled `clubs`
table, or names already on file, apply). A delimited-text upload goes
through the unchanged `Parser`, below.

## File format (the older delimited-text upload)

There's no verified real sample of this export in this codebase. The
parser (`lib/pairings_engine/federations/bel/parser.ex`) resolves columns
**by header name** rather than by fixed byte offsets (unlike the FIDE
parser), against a small set of recognised French/Dutch/English aliases
(e.g. `MATRICULE`/`STAMNUMMER`/`ID` for the national ID column). This is
deliberately more forgiving than FIDE's fixed-width format: it tolerates
column reordering and doesn't need to know the delimiter or locale up
front (`;` or `,` is auto-detected from the header line; UTF-8 or
Windows-1252 encoding is auto-detected the same way
`PairingsEngine.Federations.BEL.SwarImport` does for `.swar` files).

Only `national_id` (matricule) and `last_name` are required columns -
everything else (`first_name`, `national_rating`, `fide_id`,
`club_number`, `club_name`, `federation`, `birth_year`) is optional and
defaults to nil/blank if the column is absent.

## Architecture

- `PairingsEngine.Federations.BEL.Member` - Ecto schema for
  `kbsb_players`, keyed by `national_id` (string, to preserve any leading
  zeros). `club_label/1` is what to show for a player's club: the name if
  known, else the bare number, else nil.
- `PairingsEngine.Federations.BEL.Club`/`Clubs` - the durable
  `kbsb_clubs` club-number -> name mirror and its precedence logic; see
  "Club names" above.
- `PairingsEngine.Federations.BEL.Settings` - the two `meta`-backed
  settings: the players list URL/template, and the optional club names
  URL.
- `PairingsEngine.Federations.BEL.Http` - resolves the URL (month
  walk-back, `{YYYYMM}` expansion), does the conditional-GET download
  with its caps, and fetches the optional club names URL the same way.
- `PairingsEngine.Federations.BEL.SqliteFile` - reads a `players.sqlite`
  (bare, or unzipped from either the download or a manual upload):
  schema validation, row reading, the optional `clubs` table, and
  `to_member_row/2`, which applies the field allowlist above.
- `PairingsEngine.Federations.BEL.Parser` - pure parser for the older
  delimited-text upload, `binary -> {:ok, rows} | {:error, reason}`.
- `PairingsEngine.Federations.BEL.Sync` - GenServer, mirrors
  `PairingsEngine.Fide.Sync`'s hardening: watchdog (3 min of no progress
  fails the job), `cancel_import/0`, PubSub progress on the `"kbsb_sync"`
  topic, full-table `insert_all` with `on_conflict: :replace_all`, and a
  manual-only trigger (`start_import/1`, taking an uploaded file's raw
  bytes - never started at boot). `start_http_import/0` is the other
  trigger, for KBSB's public file; both feed the same `import_rows/3`
  count-guard and full-replace.
- `PairingsEngine.Federations.BEL.Members` - context module: `search/1`
  (national ID exact match, or every typed token against either name in
  any order, accents folded), `find_by_national_id/1`,
  `find_by_fide_id/1`, `player_count/0`, `last_sync/0`, `source_month/0`
  (which month's file the local copy came from, if it ever synced from
  KBSB's site).

## UI

The existing FIDE database page (`lib/pairings_engine_web/live/fide_live.ex`,
route `/fide`) has a section for the KBSB list: a "Sync from KBSB" button,
a collapsible settings panel for the two URLs above, a file picker
(`live_file_input`) for the manual fallback, the same progress bar/PubSub
pattern as FIDE, and its own search box. The nav label is "Rating lists"
(`lib/pairings_engine_web/components/layouts.ex`) since the page covers
both lists; the route and module name are unchanged.

## Player autofill

`lib/pairings_engine_web/live/players_live.ex`:

- **Add-player form**: picking a FIDE search result now also looks the
  player up in `kbsb_players` by FIDE ID and, if found, fills in the
  national ID/national rating alongside the FIDE fields (mirrors how the
  FIDE pick already fills FIDE fields). Typing/leaving a National ID field
  also triggers a KBSB lookup that fills national rating (and FIDE ID, if
  KBSB has one and the field is still blank).
- **Edit modal** ("Player registration"): a second "Refresh" button next to
  the existing FIDE-oriented one queries KBSB by the National ID field and
  merges in national rating, club, federation, birth year, and FIDE ID
  (only into fields that are still blank for FIDE ID, since that field is
  the FIDE list's territory).

## Not implemented (out of scope for this wave)

- No historical/point-in-time ratings - only the latest imported snapshot
  is kept (`DELETE FROM kbsb_players` before each import, same as FIDE).
  `kbsb_clubs` is the one exception, kept deliberately durable - see
  "Club names" above.
