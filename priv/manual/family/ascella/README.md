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
signatures. Releases now carry them: from the next release on, every file
and `SHA256SUMS` itself have a GitHub artifact attestation (keyless, Sigstore).
Ascella does not check them yet; a person can, with
`gh attestation verify <file> --repo teapot-chess/<repo>`.

## The data

Each program's data directories are in the catalogue (`data`). `Ascella.Guard`
refuses any write, move or delete that is in a data directory or contains
one, and every installer goes through it. On Windows the install folder
(`%LOCALAPPDATA%\<pack id>`, which Velopack's uninstall deletes whole) must
not be a data folder and must not hold a database; a catalogue whose pack id
names a data folder does not load. `test/ascella/data_safety_test.exs` runs
install, update and rollback for every method against data directories full
of files and checks them byte for byte afterwards.

## Settings

| variable | what |
|---|---|
| `PORT` | the page's port, default 4090; always on 127.0.0.1 |
| `ASCELLA_DATA` | Ascella's own folder (downloads, portable programs, its secret) |
| `ASCELLA_CATALOGUE` | another catalogue |
| `ASCELLA_APPS_DIR` | macOS: where the apps go, instead of `/Applications` (then `~/Applications`) |
| `ASCELLA_RUN_AS` | Linux: the user portable programs run as when Ascella runs as root, and the user who may read the key to the page (see below). Set it in `/etc/ascella/ascella.env` |
| `ASCELLA_TOKEN_FILE` | Linux service: where the page's key is written at every start (the unit sets `/run/ascella/token`); unset everywhere else |

On a box without a screen: `ssh -L 4090:127.0.0.1:4090 box`.

### The key (Linux service)

The Linux service is root and listens on 127.0.0.1, which every process of
the box can reach, so its page wants a key. At every start the service writes
a random one to `/run/ascella/token`, readable by root and by the user
`ASCELLA_RUN_AS` names and by nobody else. The way in is a link that carries
it once:

```sh
sh /opt/ascella/current/ascella.sh open           # opens it in the browser (as that user)
sh /opt/ascella/current/ascella.sh open --print   # prints http://localhost:4090/?k=...
```

The page takes the key, remembers the browser with a signed cookie and sends
it on to the page without the key in the address. A request with neither
gets a 403 that says so. Through an SSH tunnel: run `open --print` on the box
and paste the link into the browser of the machine you came from. A restart
makes a new key, so every browser comes in again by the link. Windows, macOS
and a Linux start in a terminal have no key and nothing changes there.

Portable programs started by the root service (OpenPairings on Linux) run as
`ASCELLA_RUN_AS`: before each start Ascella gives that user a way to walk to
the program (the "execute" bit of the data folder, which is otherwise
`0750 root`) and a log folder of its own, `programs/<id>/logs`. A program that
is already gone a second after it started is a failed start and the tile shows
the end of its log. Ascella's `pid` file records when the process started
beside its number (`/proc/<pid>/stat` on Linux, `ps -o lstart` on macOS), and
a pid whose start time differs is another process: it is never reported as
running and never sent a signal.

## Installing Ascella

Like Alnasl: a Velopack installer and a portable zip on Windows, a zipped
`.app` on macOS 11 and newer (Apple Silicon) or on macOS 10.13 and newer
(Intel Macs; that build is made for releases only), and `install.sh` with a systemd
unit on Linux. On a Mac the first install is one manual step, because the
app is not notarised: see [docs/macos.md](docs/macos.md). After that,
nothing Ascella downloads is quarantined. Removing Ascella itself has its own
page, `/remove-ascella` (linked from the help), with the exact steps per
system, because a program that uninstalls itself while it runs has opinions
about the order. Releasing: [docs/releasing.md](docs/releasing.md).

### Ascella updates itself

A newer Ascella is looked for the way every other program is: the latest
GitHub release, its files checked against that release's `SHA256SUMS`
(`Ascella.Fetch`, the same code). The page shows "Ascella X.Y.Z, update
available" with an Update Ascella button. Two rules, both kept in
`Ascella.Apps` and `Ascella.Updates.decide/1`: Ascella updates **last** (Update
all does the other programs first and itself after them), and it **refuses**
while anything is being installed, updated or rolled back. The data folder is
never touched.

| | how |
|---|---|
| **macOS** | `Ascella.SelfUpdate.Mac`: download and verify the zip, unpack beside the running `Ascella.app` (same volume), make sure the new app has no `com.apple.quarantine`, rename the running app to `.ascella-previous/Ascella.app` (exactly one previous copy) and the new one into place. A detached `/bin/sh` helper, started under `env -i` like every program Ascella starts, waits for the old Ascella to quit, opens the new one and asks its port for an answer; if there is none within 45 seconds it puts the previous app back and opens that. Then Ascella quits the way Quit does. Where `Ascella.app` is in a folder you may not write to (or runs from macOS's read-only copy of a download), nothing is attempted: the page says where Ascella is and to move it to /Applications. |
| **Windows** | the launcher (`rel/windows/launcher.c`) sees Ascella quit with exit code 90 and has Velopack apply the update and start the new version. A portable zip has no updater and is updated by hand. |
| **Linux** | the request goes to `ascella-update.path`, whose `ascella-update.service` runs `update.sh`: download, verify, switch, restart, and back again if the new version does not answer. |

**What you do once.** On a Mac there is nothing to do: the app is signed and notarised and opens
with a double-click (a build from a fork is only ad-hoc signed; see
[docs/macos.md](docs/macos.md)). Ascella updates itself, and what it downloads is never quarantined.

## Licence

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
