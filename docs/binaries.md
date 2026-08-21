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

## Running the binary

The app is a web server; it reads its config from the environment at start:

```bash
DATABASE_PATH=/var/lib/openpairings/app.db \
SECRET_KEY_BASE=$(head -c 48 /dev/urandom | base64) \
PHX_SERVER=true \
PORT=4000 \
./pairings_engine_macos_aarch64 start
```

- `DATABASE_PATH` - where the SQLite database file lives (created on first run
  after `… eval "PairingsEngine.Release.migrate"`, or migrations run at boot in
  a release).
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
