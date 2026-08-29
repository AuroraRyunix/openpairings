# Architecture

System design, data flow, and module boundaries. For a page-by-page feature
tour see [`docs/README.md`](README.md); for deep implementation gotchas see
[`docs/AGENTS.md`](AGENTS.md).

## Shape of the system

OpenPairings is a monolithic Phoenix/LiveView application - there is no
separate frontend build, no JSON API layer for the UI, and no external
database server. One BEAM node runs everything: the web server, the
SQLite connection pool, and a handful of long-lived GenServers.

```
                    ┌─────────────────────────────────────┐
                    │            Browser                  │
                    │  (server-rendered HTML + WebSocket)  │
                    └───────────────┬───────────────────────┘
                                    │ HTTP + Phoenix Channels (LiveView)
                    ┌───────────────▼───────────────────────┐
                    │      PairingsEngineWeb.Endpoint        │
                    │   (Bandit HTTP server, CSP plug, etc.) │
                    └───────────────┬───────────────────────┘
                                    │
              ┌─────────────────────┼─────────────────────────┐
              │                     │                          │
     ┌────────▼────────┐  ┌─────────▼─────────┐   ┌────────────▼───────────┐
     │  Router scopes   │  │  LiveView modules  │   │  Plain controllers    │
     │ (live_session x6)│  │ (one per top-bar   │   │ (print/export/norms   │
     │                  │  │  tab; PubSub-       │   │  downloads - plain    │
     │                  │  │  subscribed)        │   │  HTTP, not LiveView)  │
     └──────────────────┘  └─────────┬──────────┘   └────────────┬───────────┘
                                     │                            │
                        ┌────────────▼────────────────────────────▼───────────┐
                        │              Domain layer (lib/pairings_engine/)    │
                        │  Tournaments / Pairing / Standings / Trf / Norms /  │
                        │  SwarImport / Fide / Kbsb / Mobile / Tools / ...    │
                        └────────────┬─────────────────────────────────────────┘
                                     │
                    ┌─────────────────▼───────────────────┐
                    │        PairingsEngine.Repo           │
                    │      (Ecto, SQLite / WAL mode)        │
                    └───────────────────────────────────────┘

     Long-lived processes (started under the OTP supervision tree):
       PairingsEngine.Fide.Sync    - FIDE rating-list download/import state
       PairingsEngine.Kbsb.Sync    - Belgian rating-list upload/import state
       PairingsEngine.Tools.Session - public /tools/norms sessions (RAM only)
       PairingsEngine.RateLimit    - request/send throttling

     External process, invoked per pairing round:
       java -jar priv/javafo/javafo.jar  (Swiss pairing only)
```

## Layers

### 1. Router / LiveView (presentation)

`lib/pairings_engine_web/router.ex` defines six `live_session` scopes (see
`docs/AGENTS.md`'s "Entry points" for the full list and their auth
requirements). Everything under `lib/pairings_engine_web/live/` is a
LiveView - there is one module per top-bar tab (`PlayersLive`,
`PairingsLive`, `StandingsLive`, `SettingsOptionsLive`, `NormsLive`, ...),
plus a handful of public/no-login pages (`PublicPairingsLive`,
`ToolsNormsLive`, `MobileResultsLive`).

A small number of plain (non-LiveView) controllers exist specifically for
file downloads that don't fit the WebSocket model:
`PrintController` (HTML print views), `ExportController` (TRF/PGN/JSON
downloads), `NormsController` (IT3/FA1/IA1/IT4 `.xlsx` downloads),
`ToolsController`, `MobileEnrollController`.

### 2. Domain (`lib/pairings_engine/`)

Plain Elixir modules, mostly pure functions plus a handful of Ecto-backed
context modules (`Tournaments`, `Accounts`). The three pairing engines
(`Pairing` for Swiss/JaVaFo, `RoundRobin`, `Keizer`) share no code but all
funnel through the same `Tournaments`/`Standings` layer afterward. See
`docs/AGENTS.md` for the Swiss/JaVaFo pipeline's internal shape - it's the
most intricate part of this layer.

Import/export modules (`SwarImport`, `TrfImport`, `TrfExport`,
`TournamentExport`/`TournamentImport`, `PgnExport`) all convert between the
app's own `Tournament`/`Player`/`Round`/`Pairing` schema and an external
file format, in both directions where applicable. None of them talk to each
other directly - they all go through the same context functions
(`Tournaments.create_player/2`, etc.) that live UI-driven creation does.

`Norms/` is a self-contained sub-domain: `Forms` (pure data → cell-map
mappers), `XlsxFill` (generic in-place `.xlsx` editing, knows nothing about
which FIDE form it's filling), `TitleNorms` (automatic B.01 judgment),
`Combine` (multi-tournament "festival" merging). None of these touch the
database directly except `Forms`, which reads already-loaded
tournament/player/standings data passed in by its caller.

### 3. Persistence (`PairingsEngine.Repo`, SQLite)

One SQLite file, WAL journal mode, a generous `busy_timeout` (see
`docs/AGENTS.md`'s "SQLite concurrency" section for why both matter). No
Postgres, no separate DB server, no connection string beyond a file path.
Migrations live in `priv/repo/migrations/`; a released/binary build runs
them automatically at boot via `Ecto.Migrator` in the supervision tree
(gated on `RELEASE_NAME` being set, so plain `mix phx.server` in dev still
uses the normal `mix ecto.migrate` workflow).

One notable schema-design choice: the `byes` table has **no Ecto schema
module** - it's queried/written via `Ecto.Query`'s schemaless
`from(b in "byes", ...)` / `Repo.insert_all("byes", ...)` forms throughout.
Keep that in mind if you go looking for a `Byes` schema and don't find one.

## Data flow: pairing a round (the core loop)

```
Arbiter clicks "Pair next round" on PairingsLive
        │
        ▼
Tournaments.get_authorized_tournament!/2  (scope check)
        │
        ▼
Pairing.pair_next_round/1  (dispatches on tournament.pairing_system)
        │
   ┌────┼────────────────────┬─────────────────────┐
   │ swiss              round_robin              keizer
   ▼                          ▼                      ▼
build TRF16 text        pure Berger           backtracking ladder
  (full roster,          schedule fn            matcher (own algo,
   local rank map)        (frozen pairing         no external process)
   │                       numbers)                │
   ▼                          │                     │
java -jar javafo.jar          │                     │
   │                          │                     │
   ▼                          ▼                     ▼
parse pairs               map ranks to        assign colours,
   │                        real players        build pairing rows
   └───────────────┬──────────┘                     │
                   ▼                                │
         Repo.transaction: insert Round + Pairing    │
         rows + bye rows (all-or-nothing) ◄──────────┘
                   │
                   ▼
      Tournaments.broadcast_tournament_change/2
                   │
                   ▼
   every open LiveView on "tournament:#{id}" reloads live
```

Round robin and Keizer never invoke JaVaFo or write a TRF file at all - only
the `swiss` branch does. See `docs/AGENTS.md` for the Swiss branch's actual
internal steps (full-roster scoping, scratch-file lifecycle, acceleration,
match-format legs) - this diagram is intentionally the high-level version.

## Data flow: standings/tiebreaks

`Standings.standings/1` (and `grid_standings/1`) never trusts a
precomputed total on the `Player` row. Every call replays the tournament's
full pairing/bye history from the `rounds`/`pairings`/`byes` tables and
recomputes points and every configured tiebreak from scratch. This is
deliberately expensive-looking but correct-by-construction: imported data
(SWAR/TRF) is trusted for game *history*, never for pre-computed *totals*,
and there is exactly one code path that turns history into points/tiebreaks
regardless of where that history came from.

`through_round: n` (an option on `standings/2`) computes the same
replay but truncated to rounds `<= n` - used for "standings as they stood
after round N" views, and is the same code path live/current standings use,
just with a smaller round window.

## Live-refresh architecture

No polling anywhere. Every write that changes what a tournament page shows
calls `Tournaments.broadcast_tournament_change/2` (topic
`"tournament:#{id}"`) or `broadcast_user_tournaments/1` (topic
`"tournaments_user:#{user_id}"`, for the tournament list). Every
tournament-scoped LiveView subscribes on mount and reloads its own assigns
on receipt. See `docs/AGENTS.md`'s "Live-refresh model" for the
dirty-tracking pattern that protects an in-progress form edit from being
clobbered by an incoming broadcast.

## Public / no-database surfaces

Two parts of the app deliberately avoid the main authenticated data model:

- **`/tools/norms`** (`Tools.Session`) - a public, no-login page that
  accepts an uploaded `.swar`/`.trf` file, parses it in memory, and lets the
  visitor download filled FIDE report forms. Nothing is ever written to the
  database; parsed data lives only in an in-memory `Tools.Session` GenServer
  entry, keyed by a random download token, expiring after a fixed TTL.
There are no public views of a real tournament in this app. A tournament
becomes readable by the public by being published to OpenResults, which is a
separate application - see docs/public-pages.md. The local `/p/:slug/...`
pages were removed on 2026-08-29.

## Module boundaries - what NOT to couple

- The three pairing engines (`Pairing`, `RoundRobin`, `Keizer`) do not call
  into each other. Shared concerns (pairing-number freezing, active-player
  filtering) live in small shared helpers, not by one engine reaching into
  another's internals.
- `Norms.XlsxFill` knows nothing about IT3/FA1/IA1/IT4 specifically - all
  form-specific field mapping lives in `Norms.Forms`. If you're tempted to
  special-case a template name inside `XlsxFill`, that logic belongs in
  `Forms` instead.
- `Standings` is the only module allowed to compute tiebreak values. Display
  code (`player_card.ex`, print controllers, LiveViews) reads `Standings`'
  output; none of it re-derives points or tiebreaks independently.
- Import/export modules (`SwarImport`, `TrfImport`, `TrfExport`,
  `TournamentExport`/`Import`, `PgnExport`) write through the same
  `Tournaments` context functions a live UI action would use - none of them
  bypass validation by writing Ecto structs directly into `Repo`.
