# OpenPairings

Web-based chess tournament manager: FIDE Swiss pairings, round robin
(Berger), the Keizer system, FIDE tiebreaks (C.07), result entry,
live standings, printing, TRF26/TRF16 export/import, SWAR import, FIDE/KBSB rating
sync, automatic FIDE title-norm judgment (B.01), and no-account mobile result
entry. Runs locally and deploys unchanged to a server or as a standalone
binary, with user accounts and per-user tournaments.

Swiss pairing runs on **[Ainalrami](https://github.com/AuroraRyunix/Ainalrami)**,
a FIDE Dutch-system engine written for this project in Elixir, with no JVM
and no external binary. It implements C.04.3 **effective 1 February 2026**,
the current rules rather than the 2017 edition most other engines still
ship. See [Pairing engine](#pairing-engine).

## Tech stack

- **Elixir 1.20 / OTP 29**, **Phoenix 1.8** + **LiveView 1.2** (server-rendered,
  no SPA build step - pages update live over a WebSocket, not JSON+JS).
- **SQLite** (via `ecto_sqlite3`/Exqlite) - one file, WAL mode, no separate
  database server to run.
- **Bandit** as the HTTP server (not Cowboy).
- Hand-written CSS (`assets/css/app.css`, no Tailwind components) + esbuild
  for JS - no Node toolchain, no `package.json`.
- **[Ainalrami](https://github.com/AuroraRyunix/Ainalrami)** for Swiss
  pairing - an in-house Elixir dependency, so it runs in-process with no
  subprocess and no JVM.
- **Burrito** for standalone single-file binaries (bundles the BEAM runtime
  itself - see [`docs/binaries.md`](docs/binaries.md)).

## Quick start

Requires Erlang/OTP 29 + Elixir 1.20. Nothing else: no Java, no external
pairing program.

```bash
mix setup
mix phx.server
```

Then open http://localhost:4000 and register an account (in dev, the
confirmation e-mail appears at http://localhost:4000/dev/mailbox).

For a from-scratch environment setup (installing Erlang/Elixir, first-run
gotchas), see [`docs/setup-guide.md`](docs/setup-guide.md).

## Pairing engine

Every Swiss tournament is paired by
**[Ainalrami](https://github.com/AuroraRyunix/Ainalrami)**, in-process, by
C.04.3 as it stands from **1 February 2026**. Round robin (Berger) and Keizer
compute their own pairings and never call it. Earlier versions could also
run JaVaFo (the 2017 rules) as an external `.jar`; that option is gone.

Ainalrami is cross-checked against **bbpPairings 6.0.0**, an independent
Apache-2.0 implementation of the same 2026 rules, by replaying whole
generated tournaments round by round and diffing every board:

**2,536,328,265 individual pairings compared, across 217,470,056 rounds, in
6 corpora over 82 distinct axes - two disagreements, both a defect in
bbpPairings that a third engine resolves Ainalrami's way, and zero illegal
rounds.**

The axes vary round count (1 to 20), field size (2 to 500), forfeits,
requested and arbiter-allocated byes, forbidden pairings, acceleration,
which colour is drawn first, both TRF extension dialects, mid-event
withdrawals, and rating shape from a full spread down to a field where
every player is unrated. FIDE's FE1 endorsement bar is one difference per
500 tournaments; this is roughly one per 3 million.

Methodology and per-axis detail:
[Ainalrami's validation notes](https://github.com/AuroraRyunix/Ainalrami/blob/main/docs/validation.md).
What this means for a FIDE-rated event, and what the app reports to FIDE
either way: [`docs/fide-endorsement.md`](docs/fide-endorsement.md).

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
priv/bbppairings/          bbpPairings binaries (bundled - Apache-2.0 - used
                            only by the cross-program-agreement test
                            harness, see docs/fide-endorsement.md)
priv/norm_templates/       official FIDE .xlsx report templates
assets/                    hand-written CSS + JS (esbuild), no Node deps
test/                      ExUnit; test/fixtures/ holds real anonymized
                            .swar/.csv sample files
docs/                      per-feature guides + this project's deep docs
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
- **[TODO](TODO.md)** - current roadmap, tech debt, and backlog.

## History

The repository originally contained a Node/React prototype (`server/` +
`client/`); it was superseded by the Elixir/Phoenix rewrite and removed - it
remains available in the git history.

## Licence

**Elastic License 2.0** (see [LICENSE](LICENSE)), (c) 2026 Jorian Burssens.
Source-available, not open source - the difference is real and worth stating
plainly rather than letting anyone find out the hard way.

**You may** read it, run it, modify it, self-host it for your own club,
federation or tournament - including one you charge entry for - and use it
for teaching or research.

**You may not** offer it to others as a hosted or managed service, work
around its licensing, or strip the notices.

If you want to do something the licence does not cover, ask - the answer is
often yes.

The pairing engine, [Ainalrami](https://github.com/AuroraRyunix/Ainalrami),
is Apache-2.0 and deliberately stays that way: a conformance engine is worth
more checked than owned. Third-party components are listed in [NOTICE](NOTICE).
