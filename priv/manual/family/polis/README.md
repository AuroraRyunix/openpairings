# Polis

The print station of a chess hall. A small program on a computer with a
printer: it joins a tournament in [OpenPairings](https://github.com/teapot-chess/OpenPairings)
with a join link, keeps a line open to it, and prints the pairings list and
the place cards of every round the arbiter publishes - once, on its own,
and again only when somebody asks.

It always dials out. Nothing in the hall's network needs to be opened.

## Install

Every push to `main` builds all of these; a release attaches them. The
addresses are the same for every release.

| What | Download |
|---|---|
| Windows installer (one click, updates itself) | [Polis-Setup.exe](https://github.com/teapot-chess/Polis/releases/latest/download/Polis-Setup.exe) |
| Windows, no install | [polis-windows-x86_64-portable.zip](https://github.com/teapot-chess/Polis/releases/latest/download/polis-windows-x86_64-portable.zip) |
| Linux, PC | [polis-linux-x86_64.tar.gz](https://github.com/teapot-chess/Polis/releases/latest/download/polis-linux-x86_64.tar.gz) |
| Linux, Raspberry Pi (64-bit) and other arm64 | [polis-linux-aarch64.tar.gz](https://github.com/teapot-chess/Polis/releases/latest/download/polis-linux-aarch64.tar.gz) |
| Mac, Apple Silicon (macOS 11 and newer) | [polis-macos-aarch64.zip](https://github.com/teapot-chess/Polis/releases/latest/download/polis-macos-aarch64.zip) |
| Mac, Intel (macOS 10.13 and newer) | [polis-macos-x86_64.zip](https://github.com/teapot-chess/Polis/releases/latest/download/polis-macos-x86_64.zip) |
| Checksums | [SHA256SUMS](https://github.com/teapot-chess/Polis/releases/latest/download/SHA256SUMS) |

**Checking a download.** From the next release on, every file in a release, `SHA256SUMS` included, carries signed build provenance: a GitHub artifact attestation, signed keylessly through Sigstore, so there is no key of ours to lose. With the [GitHub CLI](https://cli.github.com/):

```sh
gh attestation verify <file> --repo teapot-chess/Polis
sha256sum --check --ignore-missing SHA256SUMS
```

The first line says this exact file was built by this repository's release workflow. `SHA256SUMS` is attested too, so the second line is as trustworthy as the first.

**Linux**, one line, as a service that starts with the machine:

```sh
curl -fsSL https://github.com/teapot-chess/Polis/releases/latest/download/install.sh | sudo sh
```

The program lives in `/opt/polis`, the data in `/var/lib/polis`, and
neither an update nor `/opt/polis/uninstall.sh` touches the data. Printing
goes through CUPS (`lp`), which the machine must have with the printer set
up in it. The log is `journalctl -u polis`.

**Windows**: Windows says it does not know the program, as it does of any
unsigned installer: "More info", then "Run anyway". The data is in
`%LOCALAPPDATA%\PolisData`, never in the install folder. **macOS**: signed and
notarised; unzip and open `Polis.app` ([docs/macos.md](docs/macos.md)).

An installed copy looks for a newer release now and then (one small
request to GitHub, switched off by a checkbox) and offers it; it installs
nothing without a yes, and not while a sheet is printing unless the yes is
given twice. How releases are cut and what each file is:
[docs/releasing.md](docs/releasing.md).

## Using it

```sh
mix deps.get
mix phx.server
```

Open `http://localhost:4061`. In OpenPairings (on pairings.cloud): the
tournament's *Settings* → *Print station* → *Add a print station*; paste the
link it shows into the page. Choose the printer and the paper. That is the
setup.

From then on, per tournament:

- **A new round** prints its pairings list (1 to 5 copies) and its place
  cards, each behind its own switch, both on. Once.
- **No printer chosen yet**: the jobs wait in the queue as "waiting for a
  printer" and go when one is chosen. Polis never picks a printer by
  itself.
- **A round changed after it was printed** (the arbiter moved a pairing):
  nothing prints by itself. The page says "changed since it was printed"
  and offers Reprint. A sheet on the wall that changes by itself is worse
  than one that is old.
- **"Print round N again" in OpenPairings** prints what it names, at once.
- **A share of the round.** A station can print only some categories and
  some board numbers (`1-20, 35, 40-45`), and has a name and a room. When the
  tournament has rooms in OpenPairings, the room is picked from them and a
  board prints only if it is in that room; a server without rooms gets a
  free-text label as before. All four are set on the station's page under *This station* or in
  OpenPairings, and OpenPairings keeps them: a change made in either place
  shows in the other at the next push. Nothing set is everything. A board
  prints when it is in the room, its number is in the list and either player
  is in a ticked category (a bye: its one player). A round with no board for this station
  prints nothing at all; a sheet that is printed says its room and share in
  the heading.

The queue keeps the last fifty jobs with what happened to each, a Reprint
button and the PDF. "Test print" prints a frame along the margins.

`POLIS_LISTEN=lan` opens the page to the hall's network; the default is
this machine only, because there is no PIN in this version. Either way the
station answers only to its own names: `localhost`, `127.0.0.1`, `PHX_HOST`
and, with `lan`, the machine's host name and addresses. A request that asks
for any other host (a web page that pointed its own name at this machine, or
a reverse proxy that forwards one) gets a 403.
`POLIS_PRINTER=dry-run` writes every sheet as a PDF into
`<data>/dry-run/` instead of printing it; development and the tests always
do that.

## Licence

Apache-2.0. See `LICENSE` and `NOTICE`.
