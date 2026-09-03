# KBSB/FRBE national rating list

Local copy of the Belgian national rating list (KBSB/FRBE - Koninklijke
Belgische Schaakbond / Fédération Royale Belge des Échecs), used to look up
players' national ID, national rating, club and FIDE ID when registering
them for a tournament. Mirrors the existing FIDE rating sync
(`lib/pairings_engine/fide/`) in almost everything except *how* the data
arrives.

The code lives in `lib/pairings_engine/federations/bel/` -
`PairingsEngine.Federations.BEL.{Members, Member, Api, Parser, Sync}` - with
the rest of the Belgium-specific code. The table it fills is still called
`kbsb_players`, and stays called that; see `Member`'s moduledoc for why.

## Switched on per account

All of this is optional and off by default. Three of the five switches on
`/users/features` cover it (see `PairingsEngine.Features` and
docs/architecture.md): `bel_ratings_sync` puts the panel on the Connections
page and lets the sync be started; `bel_player_lookup` and `bel_club_sync`
turn on the two things that READ the table it fills. They are independent -
with the sync off, the lookup and the club update search whatever was last
downloaded, which is a legitimate way to work.

Nothing here is ever gated on the DOMAIN side. Switching the pack off hides
buttons; it does not touch a row already in `kbsb_players`, nor any
`national_id`, `national_rating`, `club` or `club_number` already on a
player.

## Data source: the data-platform API, with the file upload as fallback

**Preferred: `PairingsEngine.Federations.BEL.Api`.** The KBSB data platform
(`kbsb-dataplatform`) exposes the Odoo-synced live roster at
`GET /api/v1/players_national/export`, and since August 2026 that export
carries each member's **club name** as well as their club number - which is
what made it usable here at all, and which the section below was written
before. Set `KBSB_API_URL` and `KBSB_API_KEY` and the rating-lists page
grows a "Sync from data platform" button; leave them unset and the page
behaves exactly as it always did.

The key travels in the `x-api-key` header. The walk is cursor-paginated
(`next_cursor` until null, ~36 pages of 1000) and is a **full** walk every
time: the import it feeds is a full replace, so re-walking cannot drift out
of step with the source. The API's `?since=` incremental mode is
deliberately unused for that reason.

The export is unfiltered - archived, deceased and non-affiliated members
included - because filtering it would make `?since=` unsound on the
platform's side. That decision therefore lands here: `kbsb_players` stores
`died` and `affiliated`, exact id lookups still resolve a deceased member
(an arbiter typing a matricule wants an answer), and `Members.name_index/0`
excludes them so a living player cannot inherit a dead namesake's club.

This does **not** change where clubs are read from at use time. The local
mirror stays, and `Federations.BEL.ClubRefresh` still reads it locally:
rounds get paired in playing halls where the internet cannot be assumed. The
API replaces how the mirror gets filled, not how it gets used.

**Fallback: the uploaded file.** Everything below still applies, and the
upload is still the only option when the API isn't configured.

## Why there was no HTTP sync originally

The FIDE sync downloads `players_list.zip` from a stable, public,
unauthenticated URL on `ratings.fide.com`. There is no equivalent for the
KBSB list. Before writing any code, the following was checked (all fetched
2026-07-13):

- `https://blog.frbe-kbsb-ksb.be/elo/`, `/elo-treatment/`, `/checklist-elo/`
  and `/software/` (the federation's current site) - no PDF/CSV/TXT/ZIP/
  SQLite download link anywhere on any of these pages. Every link was
  either navigation or one of the two authenticated tools below.
- **The national ELO system itself is retired.** Per
  `https://blog.frbe-kbsb-ksb.be/elo-treatment/`: the General Assembly of
  2025-12-06 approved migrating from national ELO to FIDE ELO, target date
  2026-07-01. As of today the page states the national ELO system "has been
  archived since July, 2026, and is available as a read-only system" - the
  July 2026 list is the *final* one. Building a live sync against a source
  that will never publish another update is far less valuable than it would
  have been a year ago, which reinforces going with the simpler
  file-based fallback rather than over-investing in an HTTP integration.
- **"Player Manager"** (`https://www.frbe-kbsb.be/sites/manager/GestionCOMMON/GestionLogin.php`)
  and its announced replacement (`https://frbe-kbsb.odoo.com/`) are the
  federation's actual bulk player databases, but both sit behind a login -
  not a stable anonymous machine-readable endpoint we can hit from a
  background job.
- The legacy per-club "Fiche" pages (e.g.
  `https://www.frbe-kbsb.be/sites/manager/GestionFICHES/FRBE_Club.php?club=130`)
  render an HTML table with no export link, are one-club-at-a-time (no bulk
  list), and are explicitly marked stale ("Data updates ceased on July 15,
  2023").
- SWAR/PairTwo (the federation's own pairing software) load ratings from
  local KBSB/FIDE SQLite files the organizer places on disk by hand
  (`blog.frbe-kbsb-ksb.be/software/`, per Bernard Malfliet's comment: *"The
  ELO's are loaded automatically from the sqlite files of KBSB and FIDE. You
  must place them on your hard drive..."*) - i.e. even the federation's own
  reference software doesn't sync this over HTTP; the file arrives by hand.

No stable, machine-readable, unauthenticated bulk download exists. Per the
task's explicit fallback rule, this feature is a **file-upload import**
instead of an HTTP sync: the tournament director downloads the official
KBSB rating-list export themselves (from the Player Manager, or whatever
the federation supplies) and uploads it on the Rating lists page. If the
federation later opens a stable bulk endpoint, only
`lib/pairings_engine/federations/bel/sync.ex`'s trigger needs to change -
the parser and storage are already format-driven, not transport-driven.

## File format

There's no verified real sample of this export in this codebase. The
parser (`lib/pairings_engine/federations/bel/parser.ex`) resolves columns
**by header name** rather than by fixed byte offsets (unlike the FIDE
parser), against a small set of recognised French/Dutch/English aliases
(e.g. `MATRICULE`/
`STAMNUMMER`/`ID` for the national ID column). This is deliberately more
forgiving than FIDE's fixed-width format: it tolerates column reordering
and doesn't need to know the delimiter or locale up front (`;` or `,` is
auto-detected from the header line; UTF-8 or Windows-1252 encoding is
auto-detected the same way `PairingsEngine.Federations.BEL.SwarImport` does
for `.swar` files).

Only `national_id` (matricule) and `last_name` are required columns -
everything else (`first_name`, `national_rating`, `fide_id`, `club_number`,
`club_name`, `federation`, `birth_year`) is optional and defaults to
nil/blank if the column is absent. **If a real export's headers don't match
`@field_headers` in `parser.ex`, add the real header string to the relevant
alias list** - no other code needs to change.

## Architecture

- `PairingsEngine.Federations.BEL.Member` - Ecto schema for `kbsb_players`,
  keyed by `national_id` (string, to preserve any leading zeros).
- `PairingsEngine.Federations.BEL.Parser` - pure parser,
  `binary -> {:ok, rows} | {:error, reason}`.
- `PairingsEngine.Federations.BEL.Sync` - GenServer, mirrors
  `PairingsEngine.Fide.Sync`'s hardening: watchdog (3 min of no progress
  fails the job), `cancel_import/0`, PubSub progress on the `"kbsb_sync"`
  topic, full-table `insert_all` with `on_conflict: :replace_all`, and a
  manual-only trigger (`start_import/1`, taking the uploaded file's raw
  bytes - never started at boot). It does *not* have FIDE's
  connect/receive-timeout or retry/backoff logic, because there's no
  network download step to protect against - the bytes are already in
  memory by the time `start_import/1` is called.
- `PairingsEngine.Federations.BEL.Members` - context module: `search/1`
  (national ID exact match, or every typed token against either name in any
  order, accents folded - see its own docstring; this line used to say
  "last-name prefix", which it has not been for a long time),
  `find_by_national_id/1`, `find_by_fide_id/1`, `player_count/0`,
  `last_sync/0`.

## UI

The existing FIDE database page (`lib/pairings_engine_web/live/fide_live.ex`,
route `/fide`) now has a second section for the KBSB list: a file picker
(`live_file_input`) instead of a sync button, the same progress bar/PubSub
pattern, and its own search box. The nav label changed from "FIDE database"
to "Rating lists" (`lib/pairings_engine_web/components/layouts.ex`) since
the page now covers both lists; the route and module name are unchanged.

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

- No automatic re-import - the source list is frozen since July 2026, and
  even before that, updates only happen when a director explicitly obtains
  and uploads a new export.
- No historical/point-in-time ratings - only the latest imported snapshot
  is kept (`DELETE FROM kbsb_players` before each import, same as FIDE).
