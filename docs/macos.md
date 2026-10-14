# OpenPairings on macOS

Since 2026-10-14 every push to `main` builds **`OpenPairings.app`** for Apple
Silicon Macs, and a release attaches it. Nobody on the project has a Mac:
everything below was built and started on GitHub's macOS runners, and the
[test list](#testing-a-build-on-a-real-mac) at the end is what a person with
a Mac still has to confirm.

| | |
|---|---|
| Apple Silicon only (M1 and later) | `openpairings_app_macos_aarch64.zip`, built on `macos-15` |
| Runtime | Erlang/OTP 29.0.5 and Elixir 1.20 from `erlef/setup-beam`, the same action and versions as the Linux and Windows jobs. On macOS it installs `erlef/otp_builds`, which links OpenSSL statically, so the app needs nothing from Homebrew |
| Oldest macOS | 11 (Big Sur) is what the build asks for (`MACOSX_DEPLOYMENT_TARGET`); the build log prints what the binaries really accept and writes that into `Info.plist` |
| Signed | ad-hoc only, for now - see [Unsigned, for now](#unsigned-for-now) |

The single-file binary (`openpairings_macos_aarch64`) and the portable zip
(`openpairings_portable_macos_aarch64.zip`, started with `openpairings.sh`)
are built for macOS too, as before 2026-09-14. They are for people who want
a terminal. The app is for everybody else.

## What the app is

```
OpenPairings.app/Contents/
  Info.plist                 rel/macos/Info.plist, version filled in from the release
  MacOS/OpenPairings         rel/macos/Launcher.swift, compiled (arm64, macOS 11+)
  Resources/launcher.sh      rel/macos/launcher.sh
  Resources/app/             the portable release (pairings_engine_portable), whole
  Resources/OpenPairings.icns
```

`rel/macos/build_app.sh` builds it on the runner around the portable
release, and compiles the launcher there with `swiftc` (plain AppKit, one
file, no Xcode project). The two halves:

- **`Launcher.swift`** is what you see. A normal **Dock icon**: the running
  dot, *Options > Keep in Dock*, Cmd-Tab. A **small window** with the name,
  what the server is doing ("OpenPairings is running at
  http://localhost:4000"), *Open in browser* and *Stop OpenPairings*.
  Closing the window only hides it; clicking the Dock icon brings it back,
  and the Dock icon's menu has *Open in browser* too. The browser opens by
  itself once the server answers. English, or Dutch when the Mac's first
  language is Dutch.
- **`launcher.sh`** is what it runs. It starts the release in local mode
  with Erlang distribution off and everything it writes outside the bundle,
  waits until the port answers, and stops the server on SIGTERM (clean
  `init:stop()`, twenty seconds, then insists). It also watches its parent:
  if the app is force-quit, the server goes with it.

**Quitting stops the server**: *Stop OpenPairings*, Cmd-Q, the Dock's
*Quit*, logging out and shutting down all send the server SIGTERM, which
closes the database cleanly, and the app leaves once the server has. No
question first, as on Windows. A second start (another copy of the app, or
one started while the server already answers) opens a browser tab instead
of a second server. If the server dies on its own, the app says so and names
the log.

Until 2026-10-14 the launcher was the shell script alone, with an
AppleScript `display dialog` for a window and `LSUIElement` set, so the app
had no Dock icon and could not be kept in the Dock. The Swift half exists
for that.

The launcher writes nothing into the app. A fresh download is run by
Gatekeeper from a read-only, "translocated" copy, and writing into a signed
bundle breaks its seal. So the release's runtime files go to the temporary
folder, a crash dump would land in the data folder, and CI starts the app
from a **read-only** bundle and checks its seal afterwards to prove it.

## Where the data is

`~/Library/Application Support/OpenPairings` - the database
(`openpairings.db`), `secret_key_base`, `backups/` and `logs/server.log`,
the server's output for the current run (a fresh file on every start; the
previous run is kept once as `server.log.1`). The same folder the portable release and the single-file
binary have always used on a Mac, so nothing moves.

It is never inside the app: replacing the app (an update) or dragging it to
the Bin (an uninstall) leaves it alone. `config/runtime.exs` refuses to
start with an `OPENPAIRINGS_DATA_DIR` inside any `.app` bundle, and
`test/pairings_engine/desktop/macos_test.exs` holds the runtime, the
launcher and the build scripts to that.

## Updates

**The in-app update notice links to the release page; it does not install.**
On a Mac the notice says "Download the new version and use it in place of
this one", which is the same text the portable zip and Linux get
(`PairingsEngine.Updates.InstallKind` answers `:other`: there is no Velopack
`Update.exe` beside a Mac app). To update: stop OpenPairings, download the
new zip, and replace `OpenPairings.app` in Applications.

Velopack was considered and not used, for now:

- On Windows the update is applied by the launcher (`launcher.c`, through
  `velopack_libc.dll`), never by the app. A Mac would need the same: a
  compiled launcher linking Velopack's macOS library and answering its
  install hooks. That is a second native program written blind, with no Mac
  to run it on.
- Velopack's macOS installer is a `.pkg` that installs into `/Applications`
  as root, so an in-app update needs an administrator - the same situation
  as the Windows per-machine install, which this project already declines
  to offer a button for.
- Unsigned, a `.pkg` gets the same Gatekeeper refusal as an app, and an
  update replacing an ad-hoc signed bundle has not been tried by anybody.

Worth revisiting once the app is signed and somebody can test on a Mac. The
feed would be `releases.osx.json` beside `releases.win.json`, and nothing on
the Windows side would change.

## Unsigned, for now

There is no Apple Developer account yet. The app is **ad-hoc signed** (every
binary carries a signature, which Apple Silicon requires before it runs
anything, but no identity), so Gatekeeper does not know who made it.

**Opening it the first time** (once per download):

- **macOS 15 Sequoia and newer**: double-click the app; macOS says it could
  not verify it. Click *Done*. Open *System Settings > Privacy & Security*,
  scroll down to "OpenPairings was blocked...", click **Open Anyway**,
  confirm with your password or Touch ID, then *Open*. (Right-click > Open no
  longer does this on Sequoia.)
- **macOS 14 and older**: right-click (or Control-click) the app, choose
  **Open**, then *Open* in the dialog.
- **If macOS says the app "is damaged and can't be opened"**: it is not; that
  is how some versions describe a quarantined app without a known developer.
  In Terminal:

  ```sh
  xattr -dr com.apple.quarantine /Applications/OpenPairings.app
  ```

  then open it normally.

**What can still ask, signed or not:**

- *"Do you want the application beam.smp to accept incoming network
  connections?"* - only if the macOS firewall is on and you switch on
  *Settings > Live boards > Let boards on this network connect*. Allow it, or
  boxes elsewhere in the hall cannot reach you. The normal pages are on
  127.0.0.1 and never ask.
- *Local network access* (macOS 15 and newer) may be asked when OpenPairings
  talks to another machine in the hall, such as a board box. Allow it, or
  that connection fails.

**When the account exists**, signing is five repository secrets and nothing
else: the workflow already contains the step, and skips it while
`APPLE_CERTIFICATE_P12_BASE64` is empty.

| Secret | What |
|---|---|
| `APPLE_CERTIFICATE_P12_BASE64` | the *Developer ID Application* certificate with its private key, exported as `.p12`, then base64 |
| `APPLE_CERTIFICATE_PASSWORD` | the `.p12`'s password |
| `APPLE_TEAM_ID` | the ten-character team id |
| `APPLE_ID` | the Apple ID used to notarise |
| `APPLE_APP_PASSWORD` | an app-specific password for that Apple ID (appleid.apple.com) |

`rel/macos/sign_and_notarize.sh` then signs every binary with the hardened
runtime and the BEAM's entitlements (`rel/macos/entitlements.plist`: JIT,
executable memory, NIFs loaded with `dlopen`), notarises, staples, and asks
Gatekeeper whether it agrees, all before the zip is made. The opening
instructions above then become "double-click it". The first signed build
needs a Mac test of its own: the entitlements are right on paper.

## What CI checks on every push

In the macOS jobs of `.github/workflows/binaries.yml`, after the existing
checks of the single-file binary and the portable release:

1. `build_app.sh`: `Launcher.swift` compiles (swiftc's errors become
   annotations on the run); every binary in the bundle links only to the
   system - `/usr/lib` (the Swift runtime in `/usr/lib/swift` included) and
   `/System` - since a Homebrew library would work on the runner and nowhere
   else; the oldest macOS all of them accept goes into `Info.plist`; the
   ad-hoc signature verifies.
2. The zip is unpacked as an arbiter would and the bundle made read-only.
   `Info.plist` must have no `LSUIElement`, and `CFBundleExecutable` must be
   a Mach-O arm64 executable. The bundle's own executable is started with
   `--headless` (no window, no browser; it runs `launcher.sh` and passes
   signals on) with a scratch data folder on port 4003. It must serve a
   signed-in page, with nothing listening but `127.0.0.1:4003` and no
   `epmd`.
3. A second start must leave at once, leaving one server.
4. SIGTERM to the launcher must stop the server, and nothing may be left
   running.
5. The bundle's seal must still verify (nothing was written into it), and
   the database must be in the data folder.

What CI cannot check: the window, the Dock, the browser opening, Gatekeeper
on a downloaded copy, a real logout. That is the list below.

## Testing a build on a real Mac

For the owner's M1 Pro, before anything is released. About twenty minutes.

**Get the build**

1. On GitHub: **Actions > Build binaries**, open the newest green run for
   `main` (or for the branch you were asked to test - *Run workflow* on that
   branch builds one without releasing anything).
2. At the bottom, under *Artifacts*, download
   **`openpairings_app_macos_aarch64`** (you must be signed in to GitHub).
3. Your Mac unpacks it to a folder or a file called
   `openpairings_app_macos_aarch64.zip`; double-click that zip if you see it.
   You now have **`OpenPairings.app`**.
4. Drag `OpenPairings.app` into **Applications**.

**First start**

5. Double-click it in Applications. Expect macOS to refuse ("could not
   verify..."). Follow [Opening it the first time](#unsigned-for-now) for
   your macOS version. Write down which message you saw.
6. Expect, within about ten seconds: an OpenPairings icon in the **Dock**
   with a running dot, a small window **"OpenPairings is running at
   http://localhost:4000"** with *Stop OpenPairings* and *Open in browser*,
   and your browser on the Tournaments page, signed in as
   `<you>@<your-mac>.local`. No Terminal window.
7. In Finder, *Get Info* on the app: the version should be the one on the
   run's commit.
8. Create a tournament and add two players.

**Where the data went**

9. Finder > *Go > Go to Folder...* > `~/Library/Application Support/OpenPairings`.
   Expect `openpairings.db`, `secret_key_base` and `logs/server.log`. Nothing
   should have appeared inside the app.

**Running, and stopping**

10. Close the browser tab, click *Open in browser*: the page comes back.
11. Cmd-Tab: OpenPairings is in the list.
12. Close the small window (red button). The Dock icon keeps its dot and
    the page still works. Click the **Dock icon**: the window comes back.
13. Right-click the Dock icon: *Open in browser* opens a tab. Choose
    *Options > Keep in Dock*.
14. Double-click the app in Applications again: a browser tab opens; still
    one Dock icon, no second server.
15. Click **Stop OpenPairings**. The app leaves the Dock's running list (the
    icon stays, without a dot, because you kept it), and
    `http://localhost:4000` no longer answers. In *Activity Monitor*, search
    for `beam`: nothing.
16. Start the app again **from the Dock icon** (no Gatekeeper question this
    time). The tournament from step 8 is there.
17. Quit it with **Cmd-Q**, then start it again and quit it with the Dock
    icon's *Quit*. Each time: the app goes and Activity Monitor shows no
    `beam`.
18. With it running, log out of macOS and back in (or restart). The logout
    is not held up by a question. Start the app: it starts normally and the
    tournament is there.

**Updates**

19. *Connections* page: the update check setting is there and on. A build
    of the newest version shows no notice. If a newer release exists than
    your build, the notice at the top says "Download the new version and use
    it in place of this one", with a link to the release page and no
    install button. That is the intended behaviour on a Mac.

**Removing it**

20. Quit OpenPairings, drag `OpenPairings.app` from Applications to the
    Bin, empty the Bin.
21. Check `~/Library/Application Support/OpenPairings` is **still there**,
    with `openpairings.db` in it.
22. Install the app again (steps 3-5): your tournament is back.

**Report back**: your macOS version, the Gatekeeper message from step 5,
which steps did something else, and `logs/server.log` from step 9 if anything
went wrong. To remove everything after testing, delete that data folder too
- the app never does.
