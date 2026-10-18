# Arkab

Electronic chessboard drivers for Elixir, and a bridge that sends a hall's boards to
one or more [Alnasl](https://github.com/teapot-chess/Alnasl) servers.

Arkab is used in two ways:

- **As a library.** `Arkab.Driver.DgtSerial`, `Arkab.Driver.DgtBus`, the serial protocol, loop and bus (`Arkab.Dgt.*`), a board emulator, the UART and fake transports, the capture format (`Arkab.Capture`), its recorder, and the replay player. Alnasl reads its local boards with these. As a dependency, Arkab starts no processes; whoever uses the drivers supervises them (`Arkab.Drivers`).
- **As a bridge.** A small program next to the boards, such as a Raspberry Pi in the hall. It reads every board on its ports, writes each event to a queue on disk first, and sends the queue over an outgoing WebSocket to every server it has joined. It never needs an open port facing the internet.

## Install

Every push to `main` builds all of these; a release attaches them. The
addresses are the same for every release.

| What | Download |
|---|---|
| Windows installer (one click, updates itself) | [Arkab-Setup.exe](https://github.com/teapot-chess/Arkab/releases/latest/download/Arkab-Setup.exe) |
| Windows, no install | [arkab-windows-x86_64-portable.zip](https://github.com/teapot-chess/Arkab/releases/latest/download/arkab-windows-x86_64-portable.zip) |
| Linux, Raspberry Pi (64-bit) and other arm64 | [arkab-linux-aarch64.tar.gz](https://github.com/teapot-chess/Arkab/releases/latest/download/arkab-linux-aarch64.tar.gz) |
| Linux, PC | [arkab-linux-x86_64.tar.gz](https://github.com/teapot-chess/Arkab/releases/latest/download/arkab-linux-x86_64.tar.gz) |
| Mac, Apple Silicon (macOS 11 and newer) | [arkab-macos-aarch64.zip](https://github.com/teapot-chess/Arkab/releases/latest/download/arkab-macos-aarch64.zip) |
| Checksums | [SHA256SUMS](https://github.com/teapot-chess/Arkab/releases/latest/download/SHA256SUMS) |

**Linux and the Raspberry Pi**, one line, as a service that starts with the
machine (Debian 12, Ubuntu 22.04, Raspberry Pi OS "Bookworm" 64-bit, or
newer; the runtime is inside):

```sh
curl -fsSL https://github.com/teapot-chess/Arkab/releases/latest/download/install.sh | sudo sh
```

(`--local` keeps the page to the box itself.) The program lives in
`/opt/arkab`, the data in `/var/lib/arkab`, and neither an update nor
`/opt/arkab/uninstall.sh` touches the data. Its log is
`journalctl -u arkab`.

**Windows**: Windows says it does not know the program, as it does of any
unsigned installer: "More info", then "Run anyway". The data is in
`%LOCALAPPDATA%\ArkabData`, never in the install folder. **macOS**: open
`Arkab.app` the first time with *Open Anyway* in System Settings; see
[docs/macos.md](docs/macos.md).

An installed copy looks for a newer release now and then (one small request
to GitHub, switched off by a checkbox on the status page) and offers it; it
installs nothing without a yes. How releases are cut and what each file is:
[docs/releasing.md](docs/releasing.md).

## The bridge

```sh
mix deps.get
mix run --no-halt          # or: iex -S mix
```

Open `http://<bridge>:4050`. Paste or scan the join link that Alnasl shows:
Halls, your hall, Bridges, *Add a bridge* (Alnasl's Setup wizard leads
there too). The link is good for fifteen minutes and one bridge. That is the
whole setup: the bridge fetches its own key, and the server decides which
table each board belongs to. The page speaks English and Dutch, the choice
kept in a cookie; `/help` says what the page's parts mean.

| variable | |
|---|---|
| `ARKAB_DATA` | where the queue, the servers, the settings and the captures live (default `./data` from a checkout; an installed copy keeps it where `Arkab.DataHome` says, never inside the install folder) |
| `ARKAB_PORT` | the status page's port (default 4050; `PORT` is read too, as the installers set it) |
| `ARKAB_LISTEN=local` | serve the page to this machine only |
| `ARKAB_UART=0` / `1` | build without or with the serial library (default: with it, except on Windows where it has to be asked for). When it is not set, `ALNASL_UART` decides, so a server built with `ALNASL_UART=0` builds Arkab without it too |

What the bridge promises:

- An event is on disk before it is sent anywhere.
- Each server has its own cursor, so a server that is down holds up nobody else.
- An event leaves the queue only when every server has acknowledged it.
- Commands from the servers (rescan, add or forget a port, send a board again, recording on or off) are applied in the order they arrived. Only a server joined as owner may make the bridge forget a board or a port.
- Remove, on either side, ends the link for both.

The link itself is described in [docs/protocol.md](docs/protocol.md).

## As a dependency

```elixir
{:arkab, git: "https://github.com/teapot-chess/Arkab.git", tag: "v0.1.0"}
```

Add `Arkab.Drivers` to your supervision tree if you read loops: it holds
the buses' registry and supervisor. Drivers send their owner
`{:driver, id, event}` as described in `Arkab.Driver`. A board on a loop
that nobody reads yet is reported to the function in
`config :arkab, loop_stranger: {Module, :function}`.

## Tests

```sh
mix test
```

The tests use the fake transport, the emulator and played-back captures,
and never open a serial port. The bridge tests run stand-in servers on
real sockets on free local ports.

## Licence

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). Arkab is not
affiliated with any board maker.
