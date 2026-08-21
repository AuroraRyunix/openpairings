# OpenPairings

Web-based chess tournament manager: FIDE Swiss pairings (JaVaFo), round robin
(Berger), the Keizer system, FIDE tiebreaks (C.07), result entry,
live standings, printing, TRF16 export/import, SWAR import, FIDE/KBSB rating
sync, automatic FIDE title-norm judgment (B.01), and no-account mobile result
entry. Runs locally and deploys unchanged to a server or as a standalone
binary, with user accounts and per-user tournaments.

## Tech stack

- **Elixir 1.20 / OTP 29**, **Phoenix 1.8** + **LiveView 1.2** (server-rendered,
  no SPA build step - pages update live over a WebSocket, not JSON+JS).
- **SQLite** (via `ecto_sqlite3`/Exqlite) - one file, WAL mode, no separate
  database server to run.
- **Bandit** as the HTTP server (not Cowboy).
- Hand-written CSS (`assets/css/app.css`, no Tailwind components) + esbuild
  for JS - no Node toolchain, no `package.json`.
- **JaVaFo** (© Roberto Ricca), an external `.jar`, run as a subprocess for
  Swiss pairing - not bundled, see Quick start below.
- **Burrito** for standalone single-file binaries (bundles the BEAM runtime
  itself - see [`docs/binaries.md`](docs/binaries.md)).

## Quick start

Requires Erlang/OTP 29 + Elixir 1.20 and Java 8+ (for JaVaFo).

```bash
mix setup
mix phx.server
```

Then open http://localhost:4000 and register an account (in dev, the
confirmation e-mail appears at http://localhost:4000/dev/mailbox).

**JaVaFo:** the pairing engine JAR is not bundled (it is © Roberto Ricca).
Download it from https://www.rrweb.org/javafo/ and save it as
`priv/javafo/javafo.jar`. Round robin and Keizer tournaments work without it;
only Swiss pairing needs it.

For a from-scratch environment setup (installing Erlang/Elixir/Java, first-run
gotchas), see [`docs/setup-guide.md`](docs/setup-guide.md).

## Directory structure

```
lib/pairings_engine/       domain logic - pairing engines, tiebreaks, TRF,
                            importers/exporters, FIDE/KBSB sync, norms
lib/pairings_engine/*/     accounts, tournaments (schemas), fide, kbsb,
                            mobile, norms, tools, audit
lib/pairings_engine_web/   Phoenix web layer - router, LiveViews, controllers,
                            components, layouts
lib/pairings_engine_web/live/   one LiveView per top-bar tab/page
priv/repo/migrations/      Ecto migrations (SQLite)
priv/javafo/               javafo.jar goes here (not bundled)
priv/bbppairings/          bbpPairings binaries (bundled - Apache-2.0, unlike
                            JaVaFo - used only by the cross-program-agreement
                            test harness, see docs/fide-endorsement.md)
priv/norm_templates/       official FIDE .xlsx report templates
assets/                    hand-written CSS + JS (esbuild), no Node deps
test/                      ExUnit; test/fixtures/ holds real anonymized
                            .swar/.csv sample files
docs/                      per-feature guides + this project's deep docs
  ├── AGENTS.md             deep technical context for AI coding agents
  ├── architecture.md       system design, data flow, module boundaries
  ├── deployment.md         where/how this app is actually deployed
  ├── setup-guide.md        environment setup & dev workflow
  └── README.md             index of per-feature guides
```

## Documentation

- **[Features & roadmap](docs/features.md)** - one-page overview of everything
  the app does.
- **[Per-feature guides](docs/README.md)** - pairing systems, TRF/SWAR import,
  norms, printing, sharing, mobile, etc.
- **[Architecture](docs/architecture.md)** - system design and module map.
- **[Setup guide](docs/setup-guide.md)** - environment setup, dev workflow.
- **[Deployment](docs/deployment.md)** - how the live instance is actually run.
- **[AGENTS.md](docs/AGENTS.md)** - deep technical context for AI agents
  working on this codebase (invariants, non-obvious patterns, gotchas).
- **[TODO](TODO.md)** - current roadmap, tech debt, and backlog.

## History

The repository originally contained a Node/React prototype (`server/` +
`client/`); it was superseded by the Elixir/Phoenix rewrite and removed - it
remains available in the git history.
