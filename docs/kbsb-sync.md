# KBSB/FRBE national rating list

Local copy of the Belgian national rating list (KBSB/FRBE — Koninklijke
Belgische Schaakbond / Fédération Royale Belge des Échecs), used to look up
players' national ID, national rating, club and FIDE ID when registering
them for a tournament. Mirrors the existing FIDE rating sync
(`lib/pairings_engine/fide/`) in almost everything except *how* the data
arrives.

## Data source: why a file upload, not an HTTP sync

The FIDE sync downloads `players_list.zip` from a stable, public,
unauthenticated URL on `ratings.fide.com`. There is no equivalent for the
KBSB list. Before writing any code, the following was checked (all fetched
2026-07-13):

- `https://blog.frbe-kbsb-ksb.be/elo/`, `/elo-treatment/`, `/checklist-elo/`
  and `/software/` (the federation's current site) — no PDF/CSV/TXT/ZIP/
  SQLite download link anywhere on any of these pages. Every link was
  either navigation or one of the two authenticated tools below.
- **The national ELO system itself is retired.** Per
  `https://blog.frbe-kbsb-ksb.be/elo-treatment/`: the General Assembly of
  2025-12-06 approved migrating from national ELO to FIDE ELO, target date
  2026-07-01. As of today the page states the national ELO system "has been
  archived since July, 2026, and is available as a read-only system" — the
  July 2026 list is the *final* one. Building a live sync against a source
  that will never publish another update is far less valuable than it would
  have been a year ago, which reinforces going with the simpler
  file-based fallback rather than over-investing in an HTTP integration.
- **"Player Manager"** (`https://www.frbe-kbsb.be/sites/manager/GestionCOMMON/GestionLogin.php`)
  and its announced replacement (`https://frbe-kbsb.odoo.com/`) are the
  federation's actual bulk player databases, but both sit behind a login —
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
  must place them on your hard drive..."*) — i.e. even the federation's own
  reference software doesn't sync this over HTTP; the file arrives by hand.

No stable, machine-readable, unauthenticated bulk download exists. Per the
task's explicit fallback rule, this feature is a **file-upload import**
instead of an HTTP sync: the tournament director downloads the official
KBSB rating-list export themselves (from the Player Manager, or whatever
the federation supplies) and uploads it on the Rating lists page. If the
federation later opens a stable bulk endpoint, only
`lib/pairings_engine/kbsb/sync.ex`'s trigger needs to change — the parser
and storage are already format-driven, not transport-driven.

## File format

There's no verified real sample of this export in this codebase. The
parser (`lib/pairings_engine/kbsb/parser.ex`) resolves columns **by header
name** rather than by fixed byte offsets (unlike the FIDE parser), against
a small set of recognised French/Dutch/English aliases (e.g. `MATRICULE`/
`STAMNUMMER`/`ID` for the national ID column). This is deliberately more
forgiving than FIDE's fixed-width format: it tolerates column reordering
and doesn't need to know the delimiter or locale up front (`;` or `,` is
auto-detected from the header line; UTF-8 or Windows-1252 encoding is
auto-detected the same way `PairingsEngine.SwarImport` does for `.swar`
files).

Only `national_id` (matricule) and `last_name` are required columns —
everything else (`first_name`, `national_rating`, `fide_id`, `club_number`,
`club_name`, `federation`, `birth_year`) is optional and defaults to
nil/blank if the column is absent. **If a real export's headers don't match
`@field_headers` in `parser.ex`, add the real header string to the relevant
alias list** — no other code needs to change.

## Architecture

- `PairingsEngine.Kbsb.KbsbPlayer` — Ecto schema for `kbsb_players`,
  keyed by `national_id` (string, to preserve any leading zeros).
- `PairingsEngine.Kbsb.Parser` — pure parser, `binary -> {:ok, rows} |
  {:error, reason}`.
- `PairingsEngine.Kbsb.Sync` — GenServer, mirrors
  `PairingsEngine.Fide.Sync`'s hardening: watchdog (3 min of no progress
  fails the job), `cancel_import/0`, PubSub progress on the `"kbsb_sync"`
  topic, full-table `insert_all` with `on_conflict: :replace_all`, and a
  manual-only trigger (`start_import/1`, taking the uploaded file's raw
  bytes — never started at boot). It does *not* have FIDE's
  connect/receive-timeout or retry/backoff logic, because there's no
  network download step to protect against — the bytes are already in
  memory by the time `start_import/1` is called.
- `PairingsEngine.Kbsb` — context module: `search/1` (national ID exact
  match, or last-name prefix), `find_by_national_id/1`,
  `find_by_fide_id/1`, `player_count/0`, `last_sync/0`.

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

- No automatic re-import — the source list is frozen since July 2026, and
  even before that, updates only happen when a director explicitly obtains
  and uploads a new export.
- No historical/point-in-time ratings — only the latest imported snapshot
  is kept (`DELETE FROM kbsb_players` before each import, same as FIDE).
