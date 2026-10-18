# Ascella

Ascella installs, updates, starts and stops the chess hall's programs on one
computer: OpenPairings, Alnasl, Arkab, Polis and Nunki. It is one local page
(<http://localhost:4090>, opened when Ascella starts) with a tile per program:
its mark, the version installed, the version out, whether it runs, and
Install / Update / Start / Stop / Open buttons. Update all does the lot, one
program at a time.

It never touches a program's data. Not on an update, not on a rollback, not
when it is asked nicely. That is the whole design, and the rest is plumbing.

Named after zeta Sagittarii, which was there first.

## What it does, per system

Every action keeps to the same order: refuse if the program is open ("Close X
first, then update", with a Stop button beside the message: it may be in the
middle of a round); download and verify; unpack and check beside the
program; swap. Nothing waits for ever: every command Ascella runs has a
deadline (`Ascella.Runner`), and a program that does not answer in time ends
the action with an error the tile shows in words. Ascella never kills
anything.

A catalogue entry with `"rollback": false` has no way back, and the button and
the function both refuse. That is OpenPairings and Alnasl: their databases
migrate forward on an update, and an older program over a newer database is
how tournaments get damaged.

| | install / update | stop | rollback |
|---|---|---|---|
| **Windows** | the program's own Velopack: `Setup.exe --silent` the first time, `Update.exe apply --norestart --package <verified .nupkg>` after. Installed-for-everyone copies (.msi) are left to their .msi | `WM_CLOSE` to the launcher window, the launcher's own no-questions close | none: Velopack keeps no previous version |
| **macOS** | the release zip, unpacked with `ditto`, the `.app` swapped by renames in the same folder | `SIGTERM` to the app's launcher, which stops its server cleanly | the previous `.app` is kept in `.ascella-previous/` and swapped back |
| **Linux / Pi** | the program's own `install.sh`, then its own `update.sh --from <verified folder>`; its own systemd unit runs it | `systemctl stop` | the program's previous release from `/opt/<id>/releases` |
| **portable** (OpenPairings on Linux) | versions side by side in Ascella's folder, `current` switched by a rename | `SIGTERM` (Windows: `taskkill` without `/F`) | the previous version is still there |

On Windows, programs are started through WMI, not as Ascella's children:
Ascella's launcher holds what it starts in a job object that dies with it,
and OpenPairings closing in round five because someone closed Ascella would
be a poor advertisement.

On Linux and macOS a program is started from an empty environment (`env -i`,
with only what Finder or a desktop session would give it: home, user, locale,
a system `PATH` and the display). Ascella's own `PORT` and friends are not
theirs, and an Arkab that reads a `PORT` it did not mean to inherit will
conclude that the port is taken by something else.

## Shortcuts and removal

Right after an install the tile asks whether to make the program easy to
start, and every installed tile has a Shortcuts list: a Start menu and Desktop
shortcut on Windows (to pin to the taskbar, right-click the shortcut), the Dock
(edited through `defaults export` / PlistBuddy / `defaults import`, because the
Dock's preferences live in a daemon that ignores a plist written behind its
back, and read back the same way) and login items on a Mac, a menu entry, Desktop file and GNOME favourite on
Linux (`Ascella.Launchers`, one adapter per system). What Ascella makes is recorded in `launchers.json` in
its own folder, and only that is ever removed. They point at paths that an
update does not move. Remove on a tile stops the program and removes it the
system's way (Velopack's `Update.exe`, the Bin, the app's `uninstall.sh`),
keeps the data unless asked twice, and takes the shortcuts with it.

## Downloads, and what is trusted

Only from the GitHub repositories in the catalogue, only over HTTPS, and
redirects only to GitHub's own hosts. Every file is checked against the
`SHA256SUMS` its release publishes, and checked again just before it is run.
A release without `SHA256SUMS`, a file not on it, or a file whose sum is
wrong is refused and deleted. Nothing unverified is ever unpacked or run.

That catches a broken or swapped download, not a release that was bad when
it was published: the sums come from the same release. That would take
signatures, and nobody signs anything yet.

## The data

Each program's data directories are in the catalogue (`data`). `Ascella.Guard`
refuses any write, move or delete that is in a data directory or contains
one, and every installer goes through it. On Windows the install folder
(`%LOCALAPPDATA%\<pack id>`, which Velopack's uninstall deletes whole) must
not be a data folder and must not hold a database; a catalogue whose pack id
names a data folder does not load. `test/ascella/data_safety_test.exs` runs
install, update and rollback for every method against data directories full
of files and checks them byte for byte afterwards.

## The catalogue

`priv/catalogue.json` (or the file `ASCELLA_CATALOGUE` names) is data, not
code. A program that ships the way Alnasl does is one entry:

```json
{
  "id": "polis",
  "name": "Polis",
  "repo": "teapot-chess/Polis",
  "layout": "hall",
  "mark": "polis.svg",
  "accent": ["#1f4f8a", "#8fb8ec"],
  "port": null,
  "blurb": {"en": "Prints the hall's paper.", "nl": "Drukt het papier van de zaal."}
}
```

`"layout": "hall"` means Alnasl's assets with the name filled in:
`Polis-Setup.exe`, `PolisApp-{version}-full.nupkg`, `polis-macos-aarch64.zip`
holding `Polis.app`, `polis-linux-<arch>.tar.gz` installed in `/opt/polis` as
`polis.service`, data in `%LOCALAPPDATA%\PolisData`,
`~/Library/Application Support/PolisData` and `/var/lib/polis`. Anything
written out in `platforms` or `data` wins. The mark goes in `priv/marks/`.
See `Ascella.Catalogue` for every field.

## Settings

| variable | what |
|---|---|
| `PORT` | the page's port, default 4090; always on 127.0.0.1 |
| `ASCELLA_DATA` | Ascella's own folder (downloads, portable programs, its secret) |
| `ASCELLA_CATALOGUE` | another catalogue |
| `ASCELLA_APPS_DIR` | macOS: where the apps go, instead of `/Applications` (then `~/Applications`) |
| `ASCELLA_RUN_AS` | Linux: the user portable programs run as when Ascella runs as root |

On a box without a screen: `ssh -L 4090:127.0.0.1:4090 box`.

## Installing Ascella

Like Alnasl: a Velopack installer and a portable zip on Windows, a zipped
`.app` on macOS 11 and newer (Apple Silicon), and `install.sh` with a systemd
unit on Linux. On a Mac the first install is one manual step, because the
app is not notarised: see [docs/macos.md](docs/macos.md). After that,
nothing Ascella downloads is quarantined. Removing Ascella itself has its own
page, `/remove-ascella` (linked from the help), with the exact steps per
system, because a program that uninstalls itself while it runs has opinions
about the order. Releasing: [docs/releasing.md](docs/releasing.md).

## Developing

```sh
mix setup
mix phx.server
```

The tests use a made-up catalogue (`test/fixtures/catalogue.json`), a fake
GitHub and a fake computer in a temporary folder. They never run a real
installer or touch a real program.

## Licence

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
