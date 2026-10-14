# Launcher details: `GET /_launcher/stats`

What the Windows launcher's **Details** panel and `./openpairings.sh details`
show, and the contract a Mac launcher can use the same way. Alnasl has the same
endpoint with the same shape; only the app-specific block differs.

## Who gets an answer

All three, or a plain `404 Not Found` with no hint which one failed:

1. **A desktop copy.** `PairingsEngine.Authz.local_mode?/0`. The hosted
   service never answers: its requests arrive from a proxy on loopback, so
   rule 2 means nothing there.
2. **From this machine.** The socket's peer address is `127.0.0.0/8` or
   `::1`. Forwarded headers are never read.
3. **With this start's secret** in the header `x-launcher-token`.

It is `GET` only, sits in the endpoint ahead of the request logger (polling
does not fill the log it shows), and is not on the board network listener
(`PairingsEngineWeb.BoardLan`, port 4747), which has its own router;
`PairingsEngineWeb.BoardLanTest` asks it with the secret and gets the 404.

## The secret

A launcher makes one per start (random, at least 16 characters; the Windows
launcher uses 48 hex digits) and passes it to the release in
`OPENPAIRINGS_LAUNCHER_TOKEN`.

A release started without it (`openpairings.sh`, a terminal) makes its own and
writes it to `<data>/run/launcher.token`:

```
<secret>
<port>
```

mode `0600` in a `0700` directory on Linux and macOS (on Windows the profile
folder's own rights apply), written empty-then-chmod-then-filled so the secret
is never in a readable file, and deleted on a clean stop. A crash leaves it;
the next start overwrites it, and an old secret opens nothing.
`<data>` is the folder holding `openpairings.db`.

## The answer

`200`, `application/json`, `cache-control: no-store`. `?lang=nl` words the
`summary` in Dutch; anything else is English. Typical cost is a millisecond or
two: nothing reads a table except `count(*)` on tournaments.

```json
{
  "app": "openpairings",
  "version": "0.86.0",
  "engine_version": "0.43.1",
  "uptime_s": 3121,
  "started_at": "2026-10-14T19:40:12Z",
  "system": {
    "os": "windows", "os_version": "10.0.26100", "arch": "x86_64-pc-windows",
    "cores": 8, "otp": "29", "elixir": "1.20.3",
    "load_average": null
  },
  "beam": {
    "memory_bytes": {"total": 0, "processes": 0, "ets": 0, "binary": 0, "code": 0},
    "processes": 620, "schedulers": 8, "run_queue": 0,
    "cpu_percent": 1.4
  },
  "database": {
    "path": "C:\\Users\\...\\OpenPairingsData\\openpairings.db",
    "size_bytes": 12900352, "wal_bytes": 41232,
    "ping_ms": 0.12,
    "slow_queries": [{"ms": 140.2, "source": "games", "query": "SELECT ...", "at": "2026-10-14T20:01:02Z"}],
    "slow_threshold_ms": 100
  },
  "log": {"source": "file", "path": "C:\\Users\\...\\OpenPairingsData\\launcher.log"},
  "openpairings": {"live_views": 3, "tournaments": 41, "board_links_online": 1},
  "summary": [
    {"label": "Version", "value": "OpenPairings 0.86.0 · Ainalrami 0.43.1"},
    {"label": "Database", "value": "0.1 ms, 12.3 MB"}
  ]
}
```

| field | meaning |
|---|---|
| `uptime_s`, `started_at` | since the runtime started |
| `system.load_average` | Linux only (`/proc/loadavg`), `null` elsewhere |
| `beam.cpu_percent` | scheduler utilisation since the previous request, all schedulers; `null` on the first request of a start (nothing to compare with yet) |
| `beam.run_queue` | processes ready to run and waiting for a scheduler |
| `database.ping_ms` | a `SELECT 1` through the pool - checkout, query, checkin; `null` if it failed |
| `database.slow_queries` | the last five queries of 100 ms or more since the start, newest first; the query text cut at 160 characters |
| `log.source` | `file` (with `path`: a launcher's `launcher.log`), `journald` (with `unit`, under systemd) or `stdout` (a terminal) |
| `openpairings.live_views` | LiveView processes: pages open in a browser, roughly |
| `openpairings.board_links_online` | connect codes whose box was heard from in the last 60 seconds |
| `summary` | the same numbers as label/value lines in words and units, in a fixed order (`PairingsEngine.LauncherDetails.Stats.labels/1`). A launcher that only wants to show them shows these, and needs no number formatting of its own |

Fields are added, not renamed; a reader ignores what it does not know.

## Showing it

- **Windows** (`rel/windows/launcher.c`): *Details* under the buttons grows the
  window with the summary (every 2 s, WinHTTP), the last 500 lines of
  `launcher.log` (every second, opened with every share flag so the server's
  writes are never blocked; left alone while somebody has scrolled up or
  selected), *Copy* (title, summary, log path and the last 200 log lines to
  the clipboard) and *Open log folder*. Dashes until the server answers.
- **Linux and macOS terminals** (`./openpairings.sh details`, built on
  `bin/pairings_engine_portable eval`): refreshes every 2 s with the last 20
  log lines below (`q` or Ctrl-C quits); `--once` prints one snapshot,
  `--json` the raw answer. It reads `<data>/run/launcher.token`, so it works
  against a copy started by `openpairings.sh`; a copy started by a launcher
  that passed its own secret has its window for this. A `journald` log is read
  with `journalctl -u <unit>` when the account may; otherwise it says how.
- The single-file (Burrito) binary has no `details` command.
