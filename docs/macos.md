# OpenPairings on macOS

Since 2026-10-14 every push to `main` builds **`OpenPairings.app`** for Apple
Silicon Macs, and a release attaches it, together with a build for **Intel
Macs** (from macOS 10.13; built only for a release, see
[Intel Macs](#intel-macs)). Nobody on the project has a Mac:
everything below was built and started on GitHub's macOS runners, and the
[test list](#testing-a-build-on-a-real-mac) at the end is what a person with
a Mac still has to confirm.

| | |
|---|---|
| Apple Silicon (M1 and later) | `openpairings_app_macos_aarch64.zip`, built on `macos-15` |
| Intel | `openpairings_app_macos_x86_64.zip`, built on `macos-15-intel`, only for a release or a hand-started run |
| Runtime | Erlang/OTP 29.0.5 compiled on the runner by `rel/macos/build_otp.sh`, for macOS 11, with OpenSSL 3.5 compiled the same way and linked into `crypto` statically; Elixir 1.20 from its own precompiled zip. Cached, so only the first run with a given set of versions pays. Linux and Windows use `erlef/setup-beam`; on macOS that would be `erlef/otp_builds`, which is built for macOS 15 and made the app refuse to open on 14 (see [Why the runtime is built here](#why-the-runtime-is-built-here)) |
| Oldest macOS | Apple Silicon: 11 (Big Sur); Intel: 10.13 (High Sierra), see [Intel Macs](#intel-macs). Everything compiled on the runner is built for it (`MACOSX_DEPLOYMENT_TARGET` from the target's `macos_min` in the workflow, the SQLite NIF from source with `EXQLITE_FORCE_BUILD`), and `build_app.sh` fails the build, naming the files, if any binary asks for newer; what they accept goes into `Info.plist` |
| Signed | Developer ID, hardened runtime, notarised and stapled - see [Signing](#signing) |

The portable zip (`openpairings_portable_macos_aarch64.zip`, started with
`openpairings.sh`) is built for macOS too, for people who want a terminal.
The app is for everybody else. There is no single-file Mac binary since
2026-10-17: Burrito's precompiled Erlang needs macOS 15, and nobody should
have to find that out by double-clicking.

## Intel Macs

macOS 10 exists only on Intel Macs, so the Intel build is also the one that
reaches back. It is `openpairings_app_macos_x86_64.zip`, compiled on GitHub's
Intel runner (`macos-15-intel`; a real Intel machine, nothing is
cross-compiled) with `MACOSX_DEPLOYMENT_TARGET=10.13`, which `build_otp.sh`
and `build_app.sh` read. The workflow's `plan` job adds it to the build matrix
only when a release is about to be published or someone started the workflow
by hand (Actions > Build binaries > Run workflow, on a branch publishes
nothing): the Intel runner is slow, and on every push it cost about thirteen
minutes, which is why Intel was dropped on 2026-10-14. A release that cannot
build for Intel is not published, and the release job refuses to attach a set
without both Mac zips.

How far back, and why it stops at 10.13:

- **The runtime** (OpenSSL, Erlang/OTP, the SQLite NIF) is compiled for
  10.13 as it is for 11 on Apple Silicon. `build_app.sh` fails the build,
  naming the files, if anything in the bundle asks for newer.
- **The launcher** is Swift, and macOS before 10.14.4 has no Swift runtime.
  Below 10.15 `build_app.sh` copies the Swift libraries it uses into
  `Contents/Frameworks` (`swift-stdlib-tool`) and links with an `@rpath` to
  them. A few AppKit and Foundation calls in `Launcher.swift` are newer than
  10.13 (`scrollableTextView()`, `monospacedSystemFont`, `seekToEnd` and
  `readToEnd`); it asks `#available` and uses the older call on 10.13.
- **Not tested on a real Mac running 10.13.** The runner is macOS 15. CI
  proves that nothing in the bundle asks for more than 10.13 and that the app
  starts and answers on a current macOS; whether 10.13 runs it is for a
  High Sierra owner to say.

There is no self-updater: the in-app notice links to the release page, so
the Intel Mac downloads `openpairings_app_macos_x86_64.zip` there.

## What the app is

```
OpenPairings.app/Contents/
  Info.plist                 rel/macos/Info.plist, version filled in from the release
  MacOS/OpenPairings         rel/macos/Launcher.swift, compiled (arm64, macOS 11+; x86_64, macOS 10.13+)
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
previous run is kept once as `server.log.1`). The same folder the portable release (and the single-file
binary, while there was one) used on a Mac, so nothing moves.

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
- Nobody has tried an update replacing a signed bundle.

Worth revisiting now that the app is signed and somebody can test on a Mac. The
feed would be `releases.osx.json` beside `releases.win.json`, and nothing on
the Windows side would change.

## Signing

Every Mach-O file in the app (the Erlang runtime, `beam.smp`, the NIF
libraries) is signed with the Developer ID Application certificate, the
hardened runtime and a timestamp, from the inside out, then the bundle. The
BEAM's JIT needs entitlements the hardened runtime otherwise forbids
(`rel/macos/entitlements.plist` says which). The bundle is then sent to
Apple's notary service and the ticket is stapled to it, so a Mac with no
network at the venue opens it without a question. The workflow asks
Gatekeeper itself (`spctl -a -vvv -t exec`) and fails unless the answer is
"Notarized Developer ID".

So the first start is a double-click. Only a build from a fork, which has no
signing secrets, is ad-hoc signed; macOS then refuses it once and *System
Settings > Privacy & Security > Open Anyway* is the way in.

To try the signing without a release: run the workflow by hand on any branch
with **mac_only** ticked. It builds, signs, notarises and checks the Mac
apps and publishes nothing.

**What can still ask, signed or not:**

- *"Do you want the application beam.smp to accept incoming network
  connections?"* - only if the macOS firewall is on and you switch on
  *Settings > Live boards > Let boards on this network connect*. Allow it, or
  boxes elsewhere in the hall cannot reach you. The normal pages are on
  127.0.0.1 and never ask.
- *Local network access* (macOS 15 and newer) may be asked when OpenPairings
  talks to another machine in the hall, such as a board box. Allow it, or
  that connection fails.

**Signing** uses six secrets of the `teapot-chess` organisation (a fork has none, and
ships ad-hoc signed); the step is in `binaries.yml`:

| Secret | What |
|---|---|
| `MACOS_CERT_P12` | the *Developer ID Application* certificate with its private key and the intermediate, exported as `.p12`, then base64 |
| `MACOS_CERT_PASSWORD` | the `.p12`'s password |
| `APPLE_TEAM_ID` | the ten-character team id |
| `ASC_KEY_ID` | the App Store Connect API key's id |
| `ASC_ISSUER_ID` | the API key's issuer id |
| `ASC_KEY_P8` | the API key's `.p8` file, base64 |

`rel/macos/sign_and_notarize.sh` signs every binary with the hardened
runtime and the BEAM's entitlements (`rel/macos/entitlements.plist`: JIT,
executable memory, NIFs loaded with `dlopen`), notarises with the API key,
staples, and asks Gatekeeper, all before the zip is made.

## Why the runtime is built here

Until 2026-10-17 the Mac job took Erlang from `erlef/setup-beam`, as Linux
and Windows still do. On macOS that is `erlef/otp_builds`, which is built
on the newest runner without a deployment target, so `beam.smp`, `erlexec`
and the OTP NIFs all said "macOS 15 or newer" (`minos 15.0` in
`LC_BUILD_VERSION`), and the precompiled SQLite NIF said 14.0. The build
script wrote the newest of those into `LSMinimumSystemVersion`, faithfully,
and a Mac on 14.6 answered *You can't use this version of the application
with this version of macOS*.

So now `rel/macos/build_otp.sh` compiles OpenSSL (static) and Erlang/OTP
(no wx, no Java, no ODBC, no docs) with `MACOSX_DEPLOYMENT_TARGET=11.0`,
checks each download against a SHA-256 in the script, and installs Elixir's
precompiled zip for that OTP major. `actions/cache` keeps the result under a
key of the OTP, OpenSSL and Elixir versions, the target, the runner and the
script itself. The versions are in the workflow's `env`; a version bump
also needs its checksum in the script, which fails loudly without one.
`exqlite` is compiled from source on the Mac (`EXQLITE_FORCE_BUILD=true`,
read in `config/config.exs`), and the deployment target is in the deps
cache key so a NIF built for another macOS cannot come back from it.

`build_app.sh` fails the build if any Mach-O file in the bundle asks for a
macOS newer than 11.0, and prints each of them with its `minos`. It used to
only report the number, which is how 15.0 shipped.

## What CI checks on every push

In the macOS jobs of `.github/workflows/binaries.yml`, after the existing
checks of the portable release:

1. `build_app.sh`: `Launcher.swift` compiles (swiftc's errors become
   annotations on the run); every binary in the bundle links only to the
   system - `/usr/lib` (the Swift runtime in `/usr/lib/swift` included) and
   `/System` - since a Homebrew library would work on the runner and nowhere
   else; none asks for a macOS newer than 11.0 (the build fails and names
   the files); the oldest macOS all of them accept goes into `Info.plist`;
   the signature verifies.
2. The zip is unpacked as an arbiter would and the bundle made read-only.
   `Info.plist` must have no `LSUIElement`, `LSMinimumSystemVersion` must
   be the target's `macos_min`, and `CFBundleExecutable` must be a Mach-O
   executable of the target's architecture. The bundle's own executable is started with
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

5. Double-click it in Applications. Expect it to open with no refusal (it is
   notarised). If macOS does refuse, write down which message you saw.
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
