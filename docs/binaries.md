# Standalone binaries

OpenPairings can ship as a **single self-contained executable per OS/arch** -
no Elixir, Erlang or Node needed on the target - via
[Burrito](https://github.com/burrito-elixir/burrito). One file bundles the
BEAM runtime, the compiled app and its assets.

Targets built:

| OS      | x86_64            | aarch64 (ARM)      |
| ------- | ----------------- | ------------------ |
| macOS   | `macos_x86_64`    | `macos_aarch64`    |
| Linux   | `linux_x86_64`    | `linux_aarch64`    |
| Windows | `windows_x86_64`  | (see below)        |

There is no Windows/ARM target: Erlang/OTP publishes no Windows/ARM runtime for
Burrito to bundle. Windows on ARM runs `windows_x86_64` under its built-in
x86_64 emulation.

## Building them in CI (the normal way)

`.github/workflows/binaries.yml` builds all five, each on its own native
runner, so the SQLite NIF is compiled natively rather than cross-guessed.

Two triggers:

- **Push a `v*` tag** - builds every target and attaches the binaries to a
  GitHub release for that tag. This is the release path.
- **Run it by hand** - Actions -> Build binaries -> Run workflow, or:

  ```bash
  gh workflow run binaries.yml --ref main
  ```

  Same build, but the results are uploaded as workflow artifacts instead of
  being attached to a release. Use this to check a branch builds before
  tagging it.

Each target is also **started after it is built** and asked for a page, in
local mode, and the run fails unless the page comes back with the
auto-signed-in owner's address on it. A Burrito build can succeed and still
produce a binary that dies at boot - `config/runtime.exs` is evaluated by
the real release at start, and no unit test exercises that path.

To cut a release:

```bash
git tag -a v0.17.0 -m "0.17.0" && git push origin v0.17.0
```

## Building locally

Needs **Zig** and **xz** on the build machine (`brew install zig xz`, or your
package manager). A build host can only reliably build **its own OS/arch** -
the SQLite driver is a native NIF, so cross-OS builds are done per-arch in CI
(see below).

```bash
# 1. digest assets (needs a prod compile first, for the colocated CSS)
MIX_ENV=prod mix compile
MIX_ENV=prod mix assets.deploy

# 2. build only the current machine's target (fast); omit BURRITO_TARGET to
#    build every target the host can produce
MIX_ENV=prod BURRITO_TARGET=macos_aarch64 mix release
```

The binary lands in `burrito_out/` (e.g. `burrito_out/pairings_engine_macos_aarch64`).

## Running it locally (`OPENPAIRINGS_LOCAL=1`)

For one person on their own machine, set one variable and nothing else:

```bash
OPENPAIRINGS_LOCAL=1 ./pairings_engine_macos_aarch64 start
```

That is the whole setup. Local mode:

- **has no login at all.** There is nobody to tell apart from anybody else,
  so the first request signs you in as this machine's owner - an account
  named after your OS user and hostname
  (`ann@her-laptop.local`), created on first start and reused forever after,
  so your tournaments are still there next time. Nothing to remember, no
  email, no password.
- **needs no SMTP.** A server refuses to boot without it, because magic-link
  login has no other way to reach you. Nothing here needs to reach you; the
  few emails the app can still send (a collaborator invitation) are printed
  to the terminal instead.
- **generates `SECRET_KEY_BASE` once** and keeps it, so a restart does not
  log you out.
- **puts the database** in the OS's own per-user data directory
  (`%LOCALAPPDATA%\OpenPairings` on Windows,
  `~/Library/Application Support/OpenPairings` on macOS,
  `~/.local/share/OpenPairings` on Linux). Override with
  `OPENPAIRINGS_DATA_DIR`, or point `DATABASE_PATH` somewhere specific.
- **serves `http://localhost:4000`**, and `PORT` moves it.

Migrations run at boot in any release, so the database is created and
brought up to date on first start. There is nothing to run first.

**It binds to loopback only, and you cannot turn that off** - not with
`PHX_HOST`, not with anything. A mode that signs in whoever asks must not be
reachable from another machine, so the pin is in `config/runtime.exs` rather
than in the instructions.

That is not the only guard. The sign-in itself checks, per request, that the
connection physically came from this machine, and ignores `X-Forwarded-For`
while doing it - so a reverse proxy in front of the app, or a later change to
how the endpoint is configured, cannot turn local mode into an open door. Both
conditions have to hold.

If you want other people on the network to reach this - a second arbiter at
the same event, results entry from a phone - you want a normal server run,
where everyone has their own account. Local mode is for one person on one
computer, and it is not a shortcut to skip setting up the other thing.

No Java is needed for either mode. Pairing is done by Ainalrami, which is
Elixir and is inside the binary; JaVaFo is the only thing that ever wanted a
JVM, and it is now the non-default alternative.

## Running the binary

The app is a web server; it reads its config from the environment at start:

```bash
DATABASE_PATH=/var/lib/openpairings/app.db \
SECRET_KEY_BASE=$(head -c 48 /dev/urandom | base64) \
PHX_SERVER=true \
PORT=4000 \
./pairings_engine_macos_aarch64 start
```

- `DATABASE_PATH` - where the SQLite database file lives. Created and
  migrated on first start: `PairingsEngine.Application` supervises
  `Ecto.Migrator`, which runs whenever `RELEASE_NAME` is set, i.e. in every
  release. There is no `mix ecto.migrate` step and no `eval` to run first.
- `SECRET_KEY_BASE` - required; generate once and keep it stable.
- `PHX_SERVER=true` - actually serve HTTP (a release doesn't by default).
- SMTP (`SMTP_USERNAME` / `SMTP_PASSWORD`) is required in prod for magic-link
  login - see `config/runtime.exs`.

Burrito binaries also accept `maintenance` sub-commands, e.g.
`./pairings_engine_… maintenance uninstall` to clear the self-extracted cache.

## Not in the binary

- **JaVaFo** (Swiss pairing engine) is © Roberto Ricca and not bundled. Install
  a JRE on the target and drop `javafo.jar` at `priv/javafo/javafo.jar` inside
  the extracted release, or run non-Swiss systems (round-robin / Keizer).

## CI (all five targets)

`.github/workflows/binaries.yml` builds every target on its **native** GitHub
runner (native NIFs, no cross-compile guesswork) and uploads the executables as
workflow artifacts - and as release assets when you push a `v*` tag.
