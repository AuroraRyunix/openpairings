# OpenPairings integration

How `plugins/openpairings_polis` gets into OpenPairings, what it needs once
it is there (very little), and where it stops.

## What the plugin is

An OpenPairings plugin (`PairingsEngine.Plugin`, see that module's docs in
the OpenPairings repository) with two pages, two plain routes and two
tables.

Pages (signed in, administrators only: the core's `:plugins` live_session):

| Path                       | What                                                                 |
|----------------------------|----------------------------------------------------------------------|
| `/p/polis`                 | Every print station of every tournament this account can open        |
| `/p/polis/tournaments/:id` | The tournament's stations; "Add a print station"; Remove; Print again |

Plain routes (`http_routes/0`: no pipeline, no session, no CSRF, no sign-in;
the plugin checks the caller itself):

| Route                       | What                                                         |
|-----------------------------|--------------------------------------------------------------|
| `POST /p/polis/join/:code`  | A station joining with a one-time code (`JoinPlug`)          |
| `GET /p/polis/link`         | The station's WebSocket (`LinkPlug` -> `LinkSocket`)         |

The wire format of both is the hall-link protocol, version 1, in
`docs/protocol.md`.

The plugin adds the feature `polis_print_station` (no federation, so it
sits with the general features on the account's Features page). With it on,
a tournament's menu gets "Print station".

## What happens

1. On `/p/polis/tournaments/:id` the arbiter presses "Add a print station".
   The page shows a join link `https://<host>/p/polis/join/<code>` (built
   from `PairingsEngineWeb.Endpoint.url()`), a copy button and a QR code.
   The code is 16 base32 characters, good once, for 15 minutes, bound to
   that tournament; only its SHA-256 is stored.
2. Polis on the hall PC posts to that link and gets a key (32 random bytes,
   base64url). Only the key's SHA-256 is stored. Joining the same tournament
   again from the same device replaces the key and undoes a removal.
3. Polis opens `wss://<host>/p/polis/link`, says `hello` with the key, and
   gets `welcome` plus the latest published round, if there is one.
4. The socket listens to the core's tournament topic
   (`PairingsEngine.Tournaments.tournament_topic/1`). Any change is a nudge:
   300 ms later it recomputes the latest published round's payload and
   sends it when its `rev` differs from the last one it sent. That covers
   pairing with the automation on, publishing by hand and a delayed publish
   running out (the last needs the core commit that broadcasts it, see
   below). A round taken back is never sent; an older round is ignored.
5. The page's "Print round N again" (pairings, place cards or both) goes to
   every connected station of the tournament as `print`. Remove marks the
   station revoked: a connected one is told `leave`, and the next `hello`
   from it is answered `refused revoked`.

The page and the sockets meet on the plugin's own PubSub topic,
`"polis:tournament:<id>"` on `PairingsEngine.PubSub`. The plugin starts no
process of its own: each socket is its own process, and nothing else runs.

Online, on the page, means a socket is up and was heard from (a ping, a
status) in the last 90 seconds. Wrong or spent join codes are counted per
client address in the core's `:board_link_auth` rate-limit bucket (under
keys of the plugin's own), 30 per 10 minutes.

### The round payload

Built by `OpenPairingsPolis.RoundPayload` from the same public functions
the core's printed pairing list uses
(`PairingsEngineWeb.PrintController.pairing_list/2`): hidden pairings left
out, `PairingsEngine.PairingDisplay.with_display_boards/1` for the board
labels and their order, `PairingsEngine.Standings.player_scores_before_round/2`
for the score in brackets, `Player.rating/2` with the tournament's rating
method. `rating` is an integer, `0` for an unrated player, as the core
reports it. `locale` is the tournament owner's account language (`nl` or
`en`); OpenPairings has no per-tournament language.

Team tournaments send their board pairings as the core lists them, with
`team: true`. Polis prints individual tournaments well and team ones
adequately; a team-shaped sheet is not in this version.

## Tables

`priv/migrations/20261018000101_create_polis_stations.exs`, run with the
core's (`migrations_path/0`; the hosted `ecto.migrate` alias adds the
directory):

- `polis_join_codes`: `tournament_id` (cascade), `code_hash` (unique),
  `expires_at`, `used_at`, `created_by_id`.
- `polis_stations`: `tournament_id` (cascade), `device_id` (unique per
  tournament), `name`, `software`, `key_hash`, `status` (what the station
  last reported: `printer`, `last_printed_round`), `last_seen_at`,
  `connected`, `connection_ref` (so an old socket closing late cannot mark a
  reconnected station offline), `revoked_at`.

Deleting a tournament for good removes its rows; one in the recycle bin
answers `refused revoked`.

## Building OpenPairings with the plugin

OpenPairings compiles plugins only with `PAIRINGS_EDITION=hosted`. Each
plugin is a directory with an `openpairings_plugin.exs` manifest; its `lib/`
is compiled into `:pairings_engine` itself, and the directory is a path
dependency with `compile: false, app: false`. This plugin has a `mix.exs`
with no dependencies: everything it uses (Phoenix, Ecto, Jason, EQRCode,
WebSockAdapter, Bandit) OpenPairings has already. No `mix.lock` change.

It needs a core with `http_routes/0` and the delayed-publish broadcast
(OpenPairings commit "Plug-ins can answer hall devices", branch
`hall-plugins` at the time of writing). On an older core the build fails
loudly, which is the right way round.

```sh
cd openpairings   # or, better, a throwaway worktree of it
PAIRINGS_EDITION=hosted \
PAIRINGS_PLUGINS_DIR="<polis>/plugins" \
PAIRINGS_PLUGINS=openpairings_polis \
  mix deps.get && mix compile && mix ecto.migrate
```

| Variable               | Meaning                                                                 |
|------------------------|-------------------------------------------------------------------------|
| `PAIRINGS_EDITION`     | `hosted`, at build AND run time (`mix phx.server` reads `mix.exs` again) |
| `PAIRINGS_PLUGINS_DIR` | the directory the plugin names are relative to                          |
| `PAIRINGS_PLUGINS`     | comma-separated plugin directories, relative to `PAIRINGS_PLUGINS_DIR`  |

The plugin has no settings of its own: no environment variables, no
`config`.

### Both hall plugins at once

Polis and Nunki live in two repositories, so their plugins sit in two
different `plugins/` directories. Either point `PAIRINGS_PLUGINS_DIR` at
their common parent and name both with relative paths:

```sh
PAIRINGS_EDITION=hosted \
PAIRINGS_PLUGINS_DIR="<VPS projects>" \
PAIRINGS_PLUGINS=polis/plugins/openpairings_polis,nunki/plugins/openpairings_nunki \
  mix compile
```

or copy (or link) both directories under one `plugins/` directory and name
them plainly, `PAIRINGS_PLUGINS=openpairings_polis,openpairings_nunki`,
which is what the server ends up with anyway. Their migrations do not
collide (`202610180001xx` here, `202610180002xx` for Nunki) and neither
plugin knows the other exists.

## On the server

`openpairings-deploy/deploy_openpairings.py` uploads each plugin listed in
`OPENPAIRINGS_PLUGINS` into `<app>/plugins/<name>`, sets `PAIRINGS_EDITION`,
`PAIRINGS_PLUGINS_DIR` and `PAIRINGS_PLUGINS` at build and run time, runs
`mix deps.get` and the build on the box, and migrates. The plugin has been
on the hosted OpenPairings at pairings.cloud since 2026-10-18, as
`<app>/plugins/openpairings_polis`, through this one line (the deploy
repository is not this one's to change, so the line lives there):

```python
("openpairings_polis", os.path.join(LOCAL_PROJECTS_ROOT, "polis", "plugins", "openpairings_polis")),
```

What the server needs beyond that: nothing but HTTPS reaching it, and
WebSocket upgrades (`wss://`) let through for `/p/polis/link` by whatever
stands in front of it. The hall PC dials out; nothing dials in to the hall,
so no port forwarding anywhere. A proxy that idles WebSockets out sooner
than the station's 25-second ping is a proxy to configure, not a bug to
fix here.

## Tests

The plugin's tests need OpenPairings around them (`ConnCase`, the accounts,
the tournaments, `PairingsEngine.BoardLinkFixtures`), so they run in an
OpenPairings build:

```sh
# from a worktree of OpenPairings, never its own checkout (Git Bash)
MIX_BUILD_PATH=_build_hosted_hall_polis \
PAIRINGS_EDITION=hosted \
PAIRINGS_PLUGINS_DIR="<polis>/plugins" \
PAIRINGS_PLUGINS=openpairings_polis \
MIX_TEST_PARTITION=polis \
  mix test "<polis>/plugins/openpairings_polis/test/openpairings_polis_web/join_plug_test.exs" \
           "<polis>/plugins/openpairings_polis/test/openpairings_polis_web/link_socket_test.exs" \
           "<polis>/plugins/openpairings_polis/test/openpairings_polis/round_payload_test.exs" \
           "<polis>/plugins/openpairings_polis/test/openpairings_polis_web/stations_live_test.exs"
```

`MIX_BUILD_PATH` drops the per-environment subdirectory, so a dev compile
into the same path leaves protocols consolidated without the test-only
`lazy_html`, and every LiveView test then dies in
`Phoenix.LiveViewTest.DOM`. Delete
`<build>/lib/pairings_engine/consolidated` and run the tests again.

The socket tests drive `LinkSocket`'s callbacks directly in the test
process; no real WebSocket, no printer, nothing printed.

## Translations

`mix gettext.extract --merge`, run the same way (hosted, plugin selected),
updates the plugin's `priv/gettext` (English and informal Dutch). It also
rewrites the core's own catalogues while it is at it: `git checkout --
priv/gettext` in the OpenPairings tree afterwards. The references come out
as absolute paths; strip the prefix up to the plugin directory.
