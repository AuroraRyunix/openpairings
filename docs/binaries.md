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

Three triggers:

- **Every push to `main`** - the binaries are a shipped artifact, and one
  that is only built at release time is only tested at release time. This
  used to be tags plus manual dispatch, and the result was a month between
  builds while the app changed underneath them: by the time anybody looked,
  "do the binaries still build" needed an experiment to answer.
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

## Two shapes, and why

| download | what it is | when |
|---|---|---|
| `openpairings_<target>` | one self-contained executable | you want a single file |
| `openpairings_portable_<target>.zip` | a folder you unzip, runtime inside | **antivirus ate the other one** |

Both are on the release page for a tagged version, and both are build
artifacts on every push to `main`. The portable one used to be a CI artifact
only, which was backwards: the release page offered exactly the download this
document tells a Windows arbiter not to start with.

A local `mix release` still writes `burrito_out/pairings_engine_<target>` -
the OTP application name. CI renames it on the way out, because that name
predates the product being called OpenPairings and means nothing to anybody
downloading it.

**Start with the portable one if you are on Windows.** The single-file build
is nicer to hand somebody, but it gets deleted by antivirus - not flagged,
not quarantined with a prompt: removed from disk before it ran once,
observed with Symantec. Nothing is wrong with it. An unsigned executable
carrying a compressed payload, which unpacks a runtime into AppData and
spawns processes, is byte-for-byte what a dropper looks like, and a
heuristic engine has no way to tell the difference.

The real fix on Windows is an Authenticode signature. Every single-file
application that does not have this problem has one; there is no trick that
substitutes for it, because the thing being detected is precisely "an
unsigned binary of unknown origin that unpacks and executes code".

Since June 2023 the CA/Browser Forum requires the signing key on FIPS 140-2
Level 2 hardware, so a `.pfx` you can hand to CI no longer exists:

| route | cost | notes |
|---|---|---|
| Azure Trusted Signing | ~$10/month | cloud HSM, no USB token, has a GitHub Action that would drop into `binaries.yml` |
| OV certificate | ~$200-400/year | ships on a hardware token, awkward in CI |
| EV certificate | ~$400-600/year | immediate SmartScreen reputation |

Signing solves the deletion; **it does not immediately solve SmartScreen**,
which warns about any binary whose certificate has no download history yet.
EV buys past that queue, Trusted Signing earns it over time.

macOS has the same shape of problem and its own answer: notarization, which
means the Apple Developer Program at $99/year. Linux has neither.

Until that is worth paying for, the portable release costs nothing and does
not look like anything: a directory of DLLs, a bundled runtime and a `.bat`
is not a shape antivirus hunts for.

Both are built by the same CI run, both carry the whole Erlang runtime, and
both are started and checked before the build is called a success.

### The portable release

Unzip it and run the launcher next to the `bin` folder:

- **Windows** - double-click `OpenPairings.exe`
- **macOS / Linux** - `chmod +x openpairings.sh && ./openpairings.sh`

  The `chmod` is needed because GitHub's artifact upload zips without Unix
  permissions - the executable bit is set in the repository and does not
  survive the round trip. Nothing to be done about it from this side; a
  release attached to a tag has the same limitation.

Same as the binary from there: `http://localhost:4000`, no login, database in
your user data directory. The launcher exists because a plain release cannot
detect local mode for itself - the binary reads `__BURRITO`, and this is
exactly the build that is not one - so the launcher sets it explicitly.
`bin/pairings_engine_portable start` also works and gives you a server-shaped
run wanting `DATABASE_PATH`.

It is about 150 MB unpacked, most of which is the Erlang runtime and the
FIDE rating tooling.

#### It runs with Erlang distribution off

Every launcher - `OpenPairings.exe`, `OpenPairings.bat`, `openpairings.sh`
and the macOS `.app` - starts the release with `RELEASE_DISTRIBUTION=none`.

Without it a release starts two listeners nobody asked for: `epmd` on
`0.0.0.0:4369` and the node itself on `0.0.0.0:<ephemeral>`, both on every
interface. That was measured on a real portable release, not inferred - and
the web port was already correctly pinned to loopback, so these two were the
exception rather than the rule.

The reason it matters is `releases/COOKIE`. It ships **inside the download**,
so it is byte-identical on every copy anybody installs, and the cookie is
what authorises a connection to those ports. A reachable Erlang node plus a
publicly known cookie is remote code execution. On an arbiter's laptop on
club or hotel wifi that is an open door, not a hardening nicety.

Nothing in a local run needs distribution. It is one person on one computer;
the browser talks HTTP to loopback; stopping is closing the window, Ctrl-C,
or - for `OpenPairings.exe` - a Windows job object. On Windows it also
removes a Firewall prompt on first run, which is an alarming thing for a
chess program to show a club arbiter.

**What it costs.** `bin/pairings_engine_portable stop`, `restart` and `pid`
are RPC to a named node, so against an instance started by a launcher they
have nothing to talk to; `remote` and `rpc` likewise. None of the launchers
used them - each has its own stop and always did.

If you need one for debugging, the three script launchers pass a pre-set
value through:

```sh
RELEASE_DISTRIBUTION=sname ./openpairings.sh
```

```bat
set RELEASE_DISTRIBUTION=sname
OpenPairings.bat
```

`OpenPairings.exe` forces `none` and ignores the variable, deliberately: it
is the front door an arbiter double-clicks, and an escape hatch on the front
door is a hole with a label on it. `OpenPairings.bat` is the diagnostic
launcher, and that is where the escape hatch belongs.

The single-file Burrito binary never had this problem. Its launcher builds
the `erl` command line itself and passes `-setcookie` without `-name` or
`-sname`, and distribution only starts when the VM is given a node name - so
it starts no `epmd` and no distribution listener, with nothing to switch off.

### The Windows launcher (`OpenPairings.exe`)

The Windows release carries two launchers, and they are for different
occasions:

| file | what happens | when to use it |
|---|---|---|
| `OpenPairings.exe` | a small window, then your browser opens | always |
| `OpenPairings.bat` | a console window with the live output | when something is wrong |

`OpenPairings.exe` is a ~100 KB native program built from
[`rel/windows/launcher.c`](../rel/windows/launcher.c), whose header comment is
the full rationale. In short it starts the release from its own directory (a
Start Menu shortcut runs with an arbitrary working directory, so relative
paths are not an option), waits for the port to actually answer before opening
a browser, runs the whole BEAM with no console window, and holds it in a
Windows **job object** so the server is terminated with the launcher rather
than left running. Closing its window stops OpenPairings; that is what the
window says, and it is the console window's old contract kept after the
console is gone.

It also starts the release with `RELEASE_DISTRIBUTION=none`, and unlike the
three script launchers it forces it rather than letting a pre-set value
through - see "It runs with Erlang distribution off" above for what that
closes and what it costs.

Two things depend on this executable existing. It is what an arbiter
double-clicks, and it is what Velopack's `--mainExe` points at, so
[`rel/windows/build_installer.ps1`](../rel/windows/build_installer.ps1)
refuses to pack a payload without it.

#### How it is built

`mix release pairings_engine_portable` builds it, as a release step that runs
after `:assemble` and writes it into the release root (see `mix.exs`). Nothing
extra to run and nothing committed: a checked-in binary would go stale in
silence, and there would be no way to review it.

It needs **Zig**, which this document already asks for. `zig cc` compiles the C
and `zig rc` compiles the icon, the application manifest and the version
resource; the target is pinned to `x86_64-windows-gnu`, so this cross-compiles
from a Linux or macOS host as happily as it builds natively. On a machine with
no Zig the step prints a warning and skips itself - the portable release still
works through `OpenPairings.bat` - and it fails loudly if Zig is present and
the build breaks.

To work on the launcher itself, build it on its own:

```powershell
py -3 rel\windows\build_brand_assets.py   # only if the icon changed
.\rel\windows\build_launcher.ps1          # writes rel\windows\OpenPairings.exe
```

The installer(s) are packed from a finished portable release by
[`rel/windows/build_installer.ps1`](../rel/windows/build_installer.ps1). CI
runs it too, on tag builds - see "CI (all five targets)" below - but read its
`.NOTES` before you ship one by hand, because it records real, verified
findings about install locations and updates that have nothing to do with
the launcher.

Why not .NET, which is the obvious thing to reach for on Windows:
framework-dependent needs a runtime installed on the arbiter's machine, which
is the one promise the portable release makes, and self-contained adds ~60 MB
to a payload that is already 155 MB. Why C rather than Zig-the-language: CI
pins Zig 0.15.2 because Burrito requires exactly that, a developer machine has
whatever is current, and Zig's standard library changes between releases while
`zig cc` and `windows.h` do not.

#### The installers: `OpenPairings-win-Setup.msi` and `OpenPairings-win-Setup.exe`

`build_installer.ps1` packs **two** installer artifacts from the same
payload, and **the `.msi` is the recommended download** - it is what the
release page and this document point an arbiter at first. `Setup.exe` stays
beside it as the one-click alternative.

|  | `.msi` | `Setup.exe` |
|---|---|---|
| shows a wizard | yes - Welcome, Licence, install-location choice, Conclusion | no - installs and launches immediately |
| per-user install | `%LOCALAPPDATA%\OpenPairingsApp` | `%LOCALAPPDATA%\OpenPairingsApp` (same folder, unconditional) |
| per-machine install | `Program Files\OpenPairingsApp` (choice offered in the wizard) | not available |
| needs admin | only if per-machine is chosen | never |
| Add/Remove Programs entry | yes | yes |

**Why both exist.** Velopack's `Setup.exe` is, by its own design, a
"one-click" installer: `docs.velopack.io/packaging/installer` says plainly
that running it "will not show any questions / wizards to the user", and
that holds regardless of any wizard-content flags passed to `vpk pack` -
verified locally by packing a throwaway payload with and without them and
diffing the resulting `Setup.exe` files byte for byte (identical but for the
pack id string). A genuine wizard - Welcome, Licence, a real per-user/
per-machine choice, Conclusion - only exists in a second artifact, a WiX
`.msi`, which `vpk pack --msi` builds alongside `Setup.exe` from the same
`--inst*` flags. `build_installer.ps1` builds both and renames both to a
friendly name; only `Setup.exe` existed before this was added.

**Where each one installs, and what was actually checked.** Velopack's own
docs describe a per-machine install as going to
`Program Files\{publisher}\{packTitle}`. That is not what this project's
`.msi` does - established by opening a built `.msi` with the Windows
Installer COM API (`New-Object -ComObject WindowsInstaller.Installer`, no
extra tooling needed) and reading its Property, Directory and ControlEvent
tables directly, rather than trusting the docs or re-deriving it from
memory. The `.msi`'s `ApplicationFolderName` property is the **pack id**
(`OpenPairingsApp`), not the title, and its per-machine path resolves to
`[ProgramFiles64Folder][ApplicationFolderName]` - one path segment, the same
one `%LOCALAPPDATA%\OpenPairingsApp` already uses per-user. See
`rel/windows/build_installer.ps1`'s `.NOTES` for the full derivation.

Either way, this does not produce a shared tournament database: the data
directory (`%LOCALAPPDATA%\OpenPairings`, see below) is resolved per Windows
account by both `config/runtime.exs` and `OpenPairings.exe` itself, and
neither reads anything about where the program was installed. Two arbiters
sharing one machine-wide install would each get their own empty database on
first run, not one shared between them - worth knowing before recommending a
shared install as a way to get a shared database. Uninstalling likewise
never touches that directory, on either install path: Velopack's uninstaller
(both artifacts use the same underlying mechanism) deletes its own install
directory whole, not just the files it tracked, which is exactly why the
install directory's name is the pack id and not the product's name - see
`WHY THE PACK ID IS NOT "OpenPairings"` in the script's `.NOTES`.

**Per-machine installs cannot update without an admin prompt.** This was
checked before shipping the `.msi`, per the maintainer's own condition for
doing so. Velopack's docs state that "updates work identically via
`Update.exe` regardless of whether the app was installed with `Setup.exe` or
the `.msi`" - and a per-machine install puts `Update.exe`, like everything
else, under `Program Files`, which an ordinary user process cannot write to
without elevation. A per-machine install can only update by prompting for
admin every time it does, the same as installing it did. Per-user has no
such problem: `%LOCALAPPDATA%` is always writable by its own owner, which is
why the per-user install stays the one this document actually recommends -
per-machine exists because the `.msi` genuinely offers the choice, not
because it is the better path for an arbiter's own laptop. **The in-app
update notice (see "Updates" below) reads this too** - a per-machine
install is told plainly that an administrator is needed, rather than being
offered an action that would only fail.

**Unsigned, so expect prompts.** Neither installer is code-signed (see "The
real fix on Windows is an Authenticode signature" above - the same economics
apply here). `Setup.exe` and a per-user `.msi` install get SmartScreen's
"Windows protected your PC" wall on a fresh download, same as the portable
release. A per-machine `.msi` install additionally triggers Windows' UAC
elevation prompt, and because the binary is unsigned that prompt reads
"Unknown publisher" rather than naming OpenPairings - unsettling to see on a
club laptop, and worth saying so before someone clicks through it for an
arbiter who is watching.

## Running it locally (the default)

Run it. That is the whole setup:

```bash
./openpairings_macos_aarch64 start
```

A standalone binary is in **local mode by default** - it is a single file
somebody downloaded onto their own computer, and nobody deploys one of those
to a server, so it does not make you say so. (It knows because Burrito's
launcher exports `__BURRITO`.)

`OPENPAIRINGS_LOCAL` overrides it either way: `=1` turns local mode on for a
plain `mix release` or a dev run, `=0` turns it off inside a binary if you
really do want to point one at a server configuration.

Local mode:

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
- **opens your browser there** once the server is actually ready to answer,
  so there is nothing to know or type in - see
  `PairingsEngine.BrowserLauncher`. Set `OPENPAIRINGS_NO_BROWSER=1` to skip
  it, for a headless run or one started over SSH.

Before this was the default, running the binary with no environment gave you
`environment variable DATABASE_PATH is missing` and a multi-megabyte
`erl_crash_dump` - a server's error, shown to somebody who is not running a
server. The CI smoke test now starts each binary with no configuration at
all, for exactly that reason.

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

**Never put the binary behind a tunnel or a reverse proxy** - cloudflared,
ngrok, nginx, an SSH forward, anything that makes a local port reachable from
elsewhere. Local mode signs in whoever asks from loopback, and to a tunnel
running on the same machine every visitor is loopback. If other people need
to reach it, run a normal server (below), which has accounts.

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
./openpairings_macos_aarch64 start
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

### The Windows installers and the update feed

On a **tag** build only, the Windows runner also packs
`rel/windows/build_installer.ps1` (`vpk` pinned to the exact version used
locally) and the release job attaches the result. What gets attached is
deliberately not "everything vpk wrote":

- `OpenPairings-win-Setup.msi` and `OpenPairings-win-Setup.exe` - the two
  human-facing downloads, friendly-named exactly as a local build produces
  them.
- `releases.win.json` and the `.nupkg` file(s) - the update feed. Nothing in
  this repository fetches these yet (the "Updates" section below checks
  GitHub's Releases API directly, not this feed - see why there), but a
  future Velopack-native updater would read them by these exact names, so
  they are **never renamed**.
- `RELEASES` is deliberately **not** attached. It exists only for migrating
  from Squirrel.Windows/Clowd.Squirrel, and OpenPairings has never shipped on
  either, so there is no legacy client for it to serve.
- `assets.win.json` is deliberately **not** attached either - it is `vpk`'s
  own manifest of what it built, not part of what any updater reads, and
  nothing in this repository consumes it.

CI runs `vpk download github` against this repository before packing, so
that if a previous tag's release already carries a `.nupkg`, this build can
diff against it and produce a **delta package** - a much smaller download
for anyone already on the previous version. That step is best-effort: the
very first tag to carry this feed has nothing to diff against yet, and a
transient network failure here should not fail the whole release, so `vpk
pack` below it still runs (and still succeeds, just without a delta) either
way.

## Updates

Desktop builds - the standalone binary, the portable release, either Windows
installer, the macOS `.app` - check GitHub for a newer OpenPairings release
and say so. **`openpairings.zerotwo.cloud` never does**, and it is not a
configuration choice: `PairingsEngine.Updates.eligible?/0` reads
`PairingsEngine.Authz.local_mode?/0`, the same signal that already decides
whether this is a local run everywhere else in the app (no login, no SMTP
required, where the database lives), checked three times over - before the
checker's own timer is ever scheduled, again on every tick since the
on/off setting can change while it does not, and a third time by the notice
itself - so a hosted server cannot show this even if state somehow existed.
See `PairingsEngine.Updates`'s moduledoc for the full reasoning.

**Notify, and the arbiter applies it. Never automatic.** An update can
change Ainalrami's (the pairing engine's) version, and a tournament locks
the engine's *name*, not its version - applying one under a running event
could change the pairing algorithm mid-tournament. So this only ever
answers "is there something newer" and links to the release page; nothing
is downloaded or installed on its own.

**The check.** On start, then at most every six hours
(`PairingsEngine.Updates.Checker`, always in the supervision tree and idle
everywhere but a desktop install - see its moduledoc for why that is safer
than a conditional child). It asks
`https://api.github.com/repos/AuroraRyunix/openpairings/releases` (`Req`,
already a dependency) for the newest release that is neither a draft nor a
prerelease, and compares its tag to this build's own version with
`Version.compare/2`. GitHub's unauthenticated API is capped at 60
requests/hour/IP; this uses at most 4. Offline, a timeout and the rate limit
all look the same from here: logged at `:debug`, never shown as an error -
an arbiter at a venue with no wifi must never see a warning about a
background check they did not ask to watch.

**The setting.** On by default, since it contacts a third party an arbiter
must always be able to stop. Lives on the Connections page (`/fide`) next to
everything else this machine talks to, and is hidden there entirely on a
hosted install - a toggle for a check that can never run anywhere but a
desktop build would be a control that visibly does nothing.

**The notice.** A non-modal card at the top of every page (threaded through
`Layouts.app` the same way the publishing-status pill is, and for the same
reason - it is not free to compute, so it is assigned once per mount rather
than read on every render). It names the version, links to the release, and
- if any tournament currently has a round paired but not yet finished
(`PairingsEngine.Tournaments.running_tournament_names/0`) - says so
explicitly next to the install action, since that is exactly the moment an
update should wait.

**The install action depends on how this copy was installed**
(`PairingsEngine.Updates.InstallKind`, pure filesystem detection - reads
`RELEASE_ROOT` and whether `Update.exe` sits beside its parent directory,
touches no Velopack library to answer it):

| install | told | why |
|---|---|---|
| per-user Velopack (`%LOCALAPPDATA%\OpenPairingsApp`) | the installer updates it in place | writable by its own owner, same as the manual path above |
| per-machine Velopack (`Program Files\OpenPairingsApp`) | an administrator is needed | `Update.exe` sits under `Program Files` either way - see "Per-machine installs cannot update without an admin prompt" above |
| portable zip, the single-file binary, macOS, Linux | a plain link to the release page | no `Update.exe` exists for any of these to detect |

**Why there is no "Install and restart" button yet.** Velopack's supported
mechanism for a non-.NET app is `velopack_libc`, a plain C ABI
(`vpkc_*`) - confirmed during this feature's implementation to link and run
correctly against this project's own toolchain (`zig cc -target
x86_64-windows-gnu`), so the mechanism itself is not what is missing. What
blocks it is architectural: that call has to be made by the process
Velopack's own apply-and-restart is built around, `OpenPairings.exe`
(`rel/windows/launcher.c`, which already handles Velopack's `--veloapp-*`/
`--squirrel-*` hook arguments - see the comment near its line 627) - not by
the Phoenix/LiveView process an "Install and restart" click would reach,
which is a *child* of that launcher's own job object. Signalling across
that boundary, with no second real release yet to update FROM and no way to
exercise a live Windows install end to end in the environment this was
built in, was judged exactly the "poke at Velopack internals" this feature
was asked not to do speculatively. A real button belongs in
`rel/windows/launcher.c`, as a follow-up, once there is a release to test it
against.
