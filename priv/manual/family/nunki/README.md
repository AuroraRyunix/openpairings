# Nunki

The hall announcer. A small program on a computer in the playing hall,
with speakers attached, that reads the pairings aloud as soon as they are
published in [OpenPairings](https://github.com/teapot-chess/OpenPairings)
and counts down to the start of the round:

> Pairings for round 3 are published. Board 1: ... against ... -
> Round 3 starts in five minutes. - Round 3 starts now. Please start the
> clocks.

In English or Dutch, whichever the tournament speaks. What is announced and
when is decided in OpenPairings (the tournament's Settings, *Hall announcer*:
add an announcer, name it, start a countdown, read again, stop); Nunki is where it
is said out loud. Its own pages are a control page and a hall screen for a
projector.

Nunki is one of the hall programs beside OpenPairings: Alnasl reads the
boards, Polis prints, Nunki speaks. They share a protocol
([docs/protocol.md](docs/protocol.md)) and a habit of dialling out, so
nothing in the hall's network has to be opened.

## Why the operating system speaks, not the browser

A browser can talk: `speechSynthesis` is in every one. Nunki does not use
it, on purpose.

- **Chromium refuses to speak until somebody has clicked the page**, and
  asks again after every load. A hall PC that restarts, reloads, updates or
  loses its connection is silent until somebody walks up to it and clicks.
  The arbiter finds out when the round should have started.
- **A background tab is throttled.** The tab with the countdown is behind
  the arbiter's other tabs; its timers run when the browser feels like it.
- **The hall screen may be on a projector, or not open at all.** Speech
  belongs to the machine with the speakers, not to whichever page is in
  front.

So Nunki is a program that runs a program: PowerShell on Windows, `say` on
a Mac, `espeak-ng` on Linux. It needs nothing from any browser, and keeps
announcing with every page closed.

The costs, honestly:

- **The voices are whatever the system has.** Windows has English; Dutch
  only once the Dutch speech pack is added (Settings, Time & language,
  Speech). A Mac has Dutch voices to download (System Settings,
  Accessibility, Spoken Content). Linux has espeak-ng, which you install,
  and which sounds like a robot - a clear, punctual robot.
- **Quality varies** from pleasant (the newer Windows and Mac voices) to
  functional. "Test voice" on the control page is there so you hear it in
  the hall before the players do.
- **Without the right voice, the system picks one.** That is sometimes
  English reading Dutch. The control page says when a language has no
  voice.

## Voices per system

| System | Engine | How Nunki asks |
|---|---|---|
| Windows 10, 11 | WinRT speech (the OneCore voices), SAPI as a fallback | Windows PowerShell 5.1 runs `priv/voice/windows.ps1`: synthesises to a WAV, plays it, returns |
| macOS | `say` | `say -v <voice> -f <file>`; voices from `say -v '?'` |
| Linux | `espeak-ng`, or `spd-say` | `espeak-ng -v <voice or language> -f <file>`; voices from `espeak-ng --voices=<lang>` |

The text is written to a file in the data folder and the program is told
the file's name: nothing said is ever part of a command line. One line is
said at a time; Stop kills the program and anything it started
(`taskkill /T /F` on Windows, `kill` elsewhere) and forgets the queue.

## Installing

Every release carries the same files under the same names:

| What | Download |
|---|---|
| Windows installer (one click, updates itself) | [Nunki-Setup.exe](https://github.com/teapot-chess/Nunki/releases/latest/download/Nunki-Setup.exe) |
| Windows, no install | [nunki-windows-x86_64-portable.zip](https://github.com/teapot-chess/Nunki/releases/latest/download/nunki-windows-x86_64-portable.zip) |
| Linux, PC | [nunki-linux-x86_64.tar.gz](https://github.com/teapot-chess/Nunki/releases/latest/download/nunki-linux-x86_64.tar.gz) |
| Linux, Raspberry Pi (64-bit) and other arm64 | [nunki-linux-aarch64.tar.gz](https://github.com/teapot-chess/Nunki/releases/latest/download/nunki-linux-aarch64.tar.gz) |
| Mac, Apple Silicon (macOS 11 and newer) | [nunki-macos-aarch64.zip](https://github.com/teapot-chess/Nunki/releases/latest/download/nunki-macos-aarch64.zip) |
| Mac, Intel (macOS 10.13 and newer) | [nunki-macos-x86_64.zip](https://github.com/teapot-chess/Nunki/releases/latest/download/nunki-macos-x86_64.zip) |
| Checksums | [SHA256SUMS](https://github.com/teapot-chess/Nunki/releases/latest/download/SHA256SUMS) |

**Checking a download.** From the next release on, every file in a release, `SHA256SUMS` included, carries signed build provenance: a GitHub artifact attestation, signed keylessly through Sigstore, so there is no key of ours to lose. With the [GitHub CLI](https://cli.github.com/):

```sh
gh attestation verify <file> --repo teapot-chess/Nunki
sha256sum --check --ignore-missing SHA256SUMS
```

The first line says this exact file was built by this repository's release workflow. `SHA256SUMS` is attested too, so the second line is as trustworthy as the first.

**Windows.** The installer is per user, one click, no administrator; Windows
says it does not know the program, as it does of any unsigned installer:
"More info", then "Run anyway". Or the portable zip: unpack, run
`Nunki.exe`. The data (`state.json`) is in `%LOCALAPPDATA%\NunkiData` and
survives uninstalling. "Start Nunki when Windows starts" is a switch on the
control page of an installed copy, off until you turn it on.

**Linux** (Debian, Ubuntu, Raspberry Pi OS, 64-bit):

```
curl -fsSL https://github.com/teapot-chess/Nunki/releases/latest/download/install.sh | sudo sh
sudo apt install espeak-ng
```

A systemd service, user `nunki` in the `audio` group, data in
`/var/lib/nunki`, the control page on http://localhost:4062.

**macOS** (Apple Silicon, or Intel from macOS 10.13): `nunki-macos-aarch64.zip` or
`nunki-macos-x86_64.zip`, unzip, open
`Nunki.app` (signed and notarised, so no question; [docs/macos.md](docs/macos.md)).

**Updates.** An installed copy looks for a newer release now and then (one
small request to GitHub, switched off by a checkbox) and says so at the top
of the control page and the help. It installs nothing without a yes, and
not while a countdown runs or Nunki is speaking unless the yes is given
twice: an update in the last minute before a round is the one announcement
nobody wanted. The hall screen never shows it; the players have no use for
our version numbers.

Nunki listens on this machine only (port 4062). `NUNKI_LISTEN=lan` opens
the pages to the hall's network - there is no PIN, so anybody on that
network can then start a countdown or stop a reading. That is the trade.
Either way Nunki answers only to its own names: `localhost`, `127.0.0.1`,
`PHX_HOST` and, with `lan`, the machine's host name and addresses. A request
for any other host (a web page that pointed its own name at this machine, or
a reverse proxy that forwards one) gets a 403.

## Sound on Linux: an open question

A systemd service runs outside anybody's desktop session. On a machine
with only ALSA, the `audio` group is enough and the service is heard. On a
desktop with **PipeWire or PulseAudio**, the sound server belongs to the
logged-in user's session, and a system service may well not reach it:
espeak-ng runs, says nothing, and exits happily.

This has not been tested on real hardware yet. Until it has, the
workaround: run Nunki as the desktop user instead of as the service -

```
sudo systemctl disable --now nunki
/opt/nunki/nunki.sh
```

(its data is then in `~/.nunki`, so join the tournament again from there),
or use a machine without a desktop, where ALSA is the sound server.

## Joining a tournament

1. In OpenPairings (on pairings.cloud): the tournament's Settings → *Hall announcer* →
   "Add an announcer". A link appears, good once and for fifteen minutes.
2. Paste it into "Join a tournament" on Nunki's control page, press Join.
3. The tournament is in the list with a green dot. From now on, a round
   published there is read here.

A print station's link is refused before it is used up. One Nunki can join
several tournaments; each has its own line and its own countdown.

Each tournament also gives this announcer a name and a room. OpenPairings
keeps them (the truth is on the server); change them there, or in the
tournament's row on the control page while the line is up. A change made
here is a request, and the row shows the new value once the server has sent
it back.

The room is one of the tournament's rooms, chosen from a list the server
sends (a text field, as before, with an older server). An announcer in a
room is sent only the boards that room holds; with no room it gets them
all. A room name the tournament does not have is refused, and the page says
so.

## The pages

- **`/`, the control page.** The joined tournaments (line up or down, and
  why), the last round received, Read now, a countdown of your own (1, 2,
  5, 10 or 15 minutes), Remove. The join field. The language of the
  announcements (follow the tournament, English, Nederlands), the voice per
  language and "Test voice", "Read the pairings when they are published",
  Stop.
- **`/hall`, the hall screen.** Dark, full screen: during a countdown the
  minutes in very large digits, then "Round 3 has started"; otherwise the
  latest pairings; at the bottom, the line being said. `?t=<id>` picks a
  tournament.
- **`/help`**, the manual, English and Dutch.

## Licence

Apache License 2.0 - see [LICENSE](LICENSE) and [NOTICE](NOTICE).
