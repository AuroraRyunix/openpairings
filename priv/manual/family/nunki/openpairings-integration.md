# OpenPairings integration

How `plugins/openpairings_nunki` gets into OpenPairings, what it needs
once it is there (very little), and how it sits beside its sister plugin
for Polis, the print station.

## What the plugin is

An OpenPairings plugin (`PairingsEngine.Plugin`, see that module's docs in
the OpenPairings repository), id `nunki`, with two pages, two plain plugs
and three tables of its own.

| Path                        | What                                                              |
|-----------------------------|-------------------------------------------------------------------|
| `/p/nunki`                  | Every announcer of every tournament the account can open          |
| `/p/nunki/tournaments/:id`  | One tournament's announcers: add, remove, name and room, countdown, read, stop |
| `POST /p/nunki/join/:code`  | A hall PC spending its one-time join code (JSON in, JSON out)     |
| `GET /p/nunki/link`         | The announcer's WebSocket (`docs/protocol.md`)                    |

The pages are for administrators only (the core's `:plugins`
live_session). The plugin adds the feature `nunki_hall_announcer` (in the
Belgian pack of the account's Features page); with it switched on, a
tournament's Settings get "Hall announcer" (`tournament_settings_entries/2`,
group "publishing"), and the page sits in the Settings frame with the rail
beside it. It is not in the tournament's top bar.

An announcer's name and room are kept in `nunki_announcers` and are the
truth for both sides; see "Name and room" in `docs/protocol.md`.

The room is one of the tournament's rooms (`PairingsEngine.Rooms`, made in
the tournament's Settings, Rooms): `room_id` points at it, so a rename there
follows, and a deleted room is no room. `room` keeps the name, or, for a
row from before rooms, the free text it was typed as, which stays a label
and matches no room. The page offers the tournament's rooms in a select.
An announcer in a room is sent only the boards that room holds (the round
payload is cut per announcer; `rev` follows what is sent), and the
`settings` frame lists the room names (`rooms_available`).

The two plugs sit outside every pipeline (`http_routes/0`): no session,
no CSRF token, no sign-in. The join code (16 characters, 80 random bits,
fifteen minutes, one use) and then the device's key (32 random bytes,
stored as its SHA-256, compared in constant time) are the only
credentials. Refused join codes are rate-limited per client address in the
core's `:board_link_auth` bucket, under keys of the plugin's own.

The plugin starts no process of its own. Each connected announcer's
WebSocket handler is the process; it listens to the core's tournament
topic (`PairingsEngine.Tournaments.tournament_topic/1`, see "Listening" in
`PairingsEngine.Plugin`) for rounds going public, and to the plugin's own
topic (`nunki:tournament:<id>`) for what the arbiter presses on the page.

### Tables

Migrations in `priv/migrations` (`20261018000201`, `20261018000202` for the room, `20261018000203` for `room_id`), run with the core's
(`migrations_path/0`; the hosted `mix ecto.migrate` alias and the
application's own start-up migrator both pick them up):

| Table              | What                                                                        |
|--------------------|-----------------------------------------------------------------------------|
| `nunki_announcers` | one joined device per tournament: device id, name, room, room id, key hash, status, online |
| `nunki_join_codes` | one-time codes, as their hash, with expiry and use                          |
| `nunki_countdowns` | the running round countdown per tournament (round, ends_at, id)             |

All three reference `tournaments` with `on delete cascade`. Additive only:
a build without the plugin never reads them.

## How the hosted build picks it up

OpenPairings compiles plugins only with `PAIRINGS_EDITION=hosted`. Each
plugin is a directory with an `openpairings_plugin.exs` manifest; its
`lib/` is compiled into `:pairings_engine` itself (so its pages use the
core's layouts and components), and the directory is also added as a path
dependency with `compile: false, app: false`. This plugin's `mix.exs`
declares no dependencies: Ecto, Phoenix, WebSockAdapter, EQRCode and Jason
are all the core's already. `mix.lock` does not change.

| Variable               | Meaning                                                                     |
|------------------------|-----------------------------------------------------------------------------|
| `PAIRINGS_EDITION`     | `hosted`, at build time AND run time (`mix phx.server` reads mix.exs again) |
| `PAIRINGS_PLUGINS_DIR` | the directory the plugin directories are in                                 |
| `PAIRINGS_PLUGINS`     | comma-separated plugin directories, relative to `PAIRINGS_PLUGINS_DIR`      |

The plugin reads no environment variable of its own.

### Locally, against a Nunki checkout

```sh
cd openpairings   # better: a worktree of it, never the checkout you work in
PAIRINGS_EDITION=hosted \
PAIRINGS_PLUGINS_DIR="<nunki>/plugins" \
PAIRINGS_PLUGINS=openpairings_nunki \
  mix deps.get && mix compile
```

Use your own `MIX_BUILD_PATH` for a hosted build if the same checkout also
builds the desktop edition. Note that `MIX_BUILD_PATH` is used as it is,
for every `MIX_ENV`: compiling `dev` into a directory the tests use
replaces the test build's consolidated protocols, and the LiveView tests
then fail on `LazyHTML`. Delete `<build>/lib/pairings_engine/consolidated`
and they come back.

### Both hall plugins at once (Nunki and Polis)

They do not collide: different ids (`/p/nunki`, `/p/polis`), tables
(`nunki_*`, `polis_*`), migration timestamps (`202610180002xx` and
`202610180001xx`), feature keys and modules. Two ways to name both:

1. A common parent for `PAIRINGS_PLUGINS_DIR`, with relative entries:

   ```sh
   PAIRINGS_EDITION=hosted \
   PAIRINGS_PLUGINS_DIR="<VPS projects>" \
   PAIRINGS_PLUGINS=nunki/plugins/openpairings_nunki,polis/plugins/openpairings_polis \
     mix compile
   ```

2. Both copied (or linked) under one plugins directory, as the deploy
   does:

   ```sh
   PAIRINGS_PLUGINS_DIR="<app>/plugins" \
   PAIRINGS_PLUGINS=openpairings_nunki,openpairings_polis
   ```

Other plugins (`openpairings_kbsb`, `openpairings_ctip`) go in the same
list the same way.

## On the server

`openpairings-deploy/deploy_openpairings.py` uploads each plugin listed in
`OPENPAIRINGS_PLUGINS` into `<remote_dir>/plugins/<name>`, sets
`PAIRINGS_EDITION`, `PAIRINGS_PLUGINS_DIR` and `PAIRINGS_PLUGINS` at build
and run time, and builds on the box. The plugin has been on the hosted
OpenPairings at pairings.cloud since 2026-10-18, through this one entry
(the deploy repository is not this one's to change, so the entry lives there):

```python
("openpairings_nunki", os.path.join(LOCAL_PROJECTS_ROOT, "nunki", "plugins", "openpairings_nunki")),
```

It then lives at `<app>/plugins/openpairings_nunki`, inside the app tree,
so the rollback snapshot covers it with the app it was built with. Its
migrations run on the next start like the core's.

Nothing else is needed on the server: no port, no service, no secret, no
configuration. The announcers dial out to the same `https://` address
people use for OpenPairings, and upgrade `/p/nunki/link` to `wss://`. A
reverse proxy in front must pass WebSocket upgrades for that path (the
ones in front of OpenPairings already do for `/live`); the server holds an
idle link for 90 seconds and the announcers ping every 25.

The join link shown on the page is built from the endpoint's own URL
(`PairingsEngineWeb.Endpoint.url/0` and `path/1`), so it carries whatever
host, scheme and sub-path the endpoint is configured with. If that is
wrong, the QR code is wrong in the same way.

## Behaviour worth knowing

- A round reaches the announcers whenever it becomes public: paired with
  the automation on, published by hand, or when a delayed publish runs out.
  "Public" is `PairingsEngine.Tournaments.round_published?/2`. A round
  taken back is not sent again, and a lower latest round is ignored; the
  device keeps what it had.
- The payload is the printed pairing list's (boards, order, scores coming
  into the round, the tournament's rating method), as JSON identical to the
  Polis plugin's. Its `locale` is the tournament owner's account language;
  OpenPairings has no per-tournament language. Unrated players carry
  `"rating": 0`.
- Team tournaments send their board pairings as the core lists them, which
  is a limit, not a design.
- The countdown is always for the latest published round. Starting one
  replaces the one that runs. An announcer that connects mid-countdown is
  told the seconds that are left; one that connects after it ran out is
  told nothing.
- Removing an announcer marks it revoked: a connected one is told `leave`,
  one that is offline is told `refused revoked` when it next calls. Joining
  the same device again with a new code gives it its row back with a new
  key.

## Tests

The plugin's tests need OpenPairings around them (`ConnCase`, accounts,
tournaments), so they run in an OpenPairings build:

```sh
# from a worktree of OpenPairings, never the checkout you work in
MIX_BUILD_PATH=_build_hosted_hall_nunki \
PAIRINGS_EDITION=hosted \
PAIRINGS_PLUGINS_DIR="<nunki>/plugins" \
PAIRINGS_PLUGINS=openpairings_nunki \
MIX_TEST_PARTITION=nunki \
  mix test "<nunki>/plugins/openpairings_nunki/test"
```

The WebSocket handler's callbacks are driven directly, with the test
process standing in for the socket; nothing listens on a port and nothing
speaks.

`mix gettext.extract --merge`, run the same way, updates the plugin's
`priv/gettext` (English and informal Dutch). It also rewrites the core's
own `.po`/`.pot` files in passing (references and line endings); put those
back with `git checkout -- priv/gettext` in the OpenPairings tree, and
strip the absolute paths it writes into the plugin's references.
