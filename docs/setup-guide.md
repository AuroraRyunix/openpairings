# Setup guide

Environment setup, local prerequisites, and the day-to-day development
workflow. For where the code actually lives and how it fits together, see
[`docs/architecture.md`](architecture.md); for the live deployed instance,
see [`docs/deployment.md`](deployment.md).

## Prerequisites

| Tool | Version | Why |
| --- | --- | --- |
| Erlang/OTP | 29 | BEAM runtime |
| Elixir | 1.20 (`~> 1.17` per `mix.exs`) | language + `mix` |
| Java (JRE) | 8+ | runs `javafo.jar` for Swiss pairing |
| SQLite | (bundled via `ecto_sqlite3`/Exqlite) | no separate install needed |

No Node.js, no `npm`/`yarn`, no separate database server. `esbuild` and
`tailwind` are fetched as standalone binaries by `mix assets.setup` — there
is no `package.json` anywhere in this repo.

### Installing Erlang/Elixir without a system-wide installer

On a machine without admin rights to run the official installers (this
project's own dev machine is one such case), a fully portable install works:

1. Download the Erlang/OTP 29 portable Windows zip (or your platform's
   equivalent binary release) and extract it somewhere on `PATH`, e.g.
   `~/tools/erlang`.
2. Download the matching Elixir release zip, extract to `~/tools/elixir`.
3. Prefix every shell invocation with both `bin/` directories on `PATH`:

   ```bash
   t="$HOME/tools"
   export PATH="$t/erlang/bin:$t/elixir/bin:$PATH"
   ```

   (On Windows PowerShell: `$t="$env:USERPROFILE\tools"; $env:Path="$t\erlang\bin;$t\elixir\bin;"+$env:Path`.)

   If `mix`/`elixir`/`erl` aren't found and you didn't install them
   system-wide, this is almost always why — check `PATH` before assuming
   something else is broken.

### JaVaFo

The Swiss pairing engine is © Roberto Ricca and is **not bundled** in this
repository (not committed, not a dependency). Download it from
https://www.rrweb.org/javafo/ and place the jar at:

```
priv/javafo/javafo.jar
```

Round robin and Keizer tournaments work with no jar present at all — only
pairing a Swiss round needs it. Tests that exercise real JaVaFo pairing are
tagged `@tag :javafo` and are automatically excluded by `test_helper.exs`
when the jar (or a JRE) isn't available, so `mix test` is safe to run
without it; you'll just see those tests in the "excluded" count.

## First-time setup

```bash
mix setup      # deps.get + ecto.create + ecto.migrate + seeds + assets.setup + assets.build
mix phx.server
```

Then visit http://localhost:4000 and register an account. In dev there's no
real SMTP configured by default, so the confirmation/magic-link e-mail is
captured locally — open http://localhost:4000/dev/mailbox to read it (this
route only exists when `dev_routes` is enabled, i.e. never in prod).

If you want real Gmail SMTP delivery locally instead of the dev mailbox,
drop a `.env` file in the repo root with `SMTP_USERNAME=`/`SMTP_PASSWORD=`
(a Gmail app password, not your account password) — `config/runtime.exs`
loads it automatically and switches the mailer over. See
[`docs/email.md`](email.md).

## Day-to-day workflow

```bash
mix phx.server              # dev server, hot code reload on save
mix test                    # full suite (excludes :javafo/:swar_fixture if unavailable)
mix test --exclude javafo --exclude swar_fixture   # explicit, matches CI exactly
mix precommit                # compile --warnings-as-errors, deps.unlock --unused, format, test
```

`mix precommit` is the pre-flight check to run before pushing — it's what CI
effectively re-checks. Keep it green.

### Database resets

```bash
mix ecto.reset               # drop + recreate + migrate + seed, dev DB
MIX_ENV=test mix ecto.reset  # same, for the test DB
```

If tests start failing in a way that looks like stale/corrupted state
(especially right after switching branches with different migrations), a
test DB reset is the first thing to try:

```bash
MIX_ENV=test mix ecto.drop && MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate
```

### A one-off "Database busy" test flake

If a single test run reports a small number of unrelated-looking failures
right after a fresh compile, especially anything touching SQLite directly,
just rerun — this project's own history has hit a one-time
"Exqlite.Error: Database busy" flake immediately following a clean rebuild
before. If it persists across reruns, it's a real problem, not this flake;
see `docs/AGENTS.md`'s "SQLite concurrency" section.

## Editing files — a Windows-specific gotcha

**Never write `.ex`/`.exs`/`.heex` files via shell redirection or a
PowerShell `Out-File`/`Set-Content` without `-Encoding utf8`** — the default
encoding on Windows PowerShell writes a UTF-8 BOM, which the Elixir compiler
rejects outright. Use a real editor or a tool that writes plain UTF-8
without a BOM. `.gitattributes` also pins every source file type to LF line
endings — an editor that reintroduces CRLF will make `mix format
--check-formatted` start failing on files you didn't mean to touch (see
`docs/AGENTS.md`'s note on this).

## Building assets manually

Normally `mix phx.server` handles this via its watchers, but if you need to
build once (e.g. before a manual release):

```bash
mix assets.setup   # installs tailwind/esbuild standalone binaries if missing
mix assets.build    # dev build
mix assets.deploy   # minified prod build + phx.digest
```

## Building a standalone binary locally

See [`docs/binaries.md`](binaries.md) for the full Burrito workflow
(needs Zig + xz in addition to the above). Not part of the normal dev loop
— only needed if you're testing the standalone-distribution path itself.

## Where to look next

- [`docs/architecture.md`](architecture.md) — how the pieces fit together.
- [`docs/AGENTS.md`](AGENTS.md) — the non-obvious gotchas, invariants, and
  patterns worth knowing before making a change.
- [`docs/README.md`](README.md) — per-feature guides (pairing systems, TRF/
  SWAR import, norms, printing, sharing, mobile, ...).
