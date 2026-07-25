# Deployment

How the live instance is actually run. For the standalone-binary
distribution path (a completely separate, self-contained option), see
[`docs/binaries.md`](binaries.md).

## Where it's running

The live instance is served at **https://pairings.zerotwo.cloud** — a
Rocky Linux VPS running the app directly as a Phoenix release under
`systemd`, `MIX_ENV=prod`. This document intentionally omits the host's IP
address, SSH access details, and any credentials — those live outside this
repository (see "Secrets" below), not in version control.

## Deployment model

Not containerized, not orchestrated — a straightforward "upload the source,
compile it on the target, run it as a systemd service" deploy, driven by a
Python script (`deploy_openpairings.py`, kept outside this repo on the
maintainer's machine, not committed here since it embeds host-specific
paths and prompts for credentials at deploy time).

What the deploy script actually does, in order:

1. **Uploads the app tree via SFTP** to a fixed path on the server, skipping
   `.git`, `_build`, `deps`, `node_modules`, `.env`, and any local SQLite
   files (dev/test databases never get uploaded — the production database
   is a separate, stable path outside the uploaded tree, see below).
2. **Installs prerequisites** on the target if missing (Java, Erlang,
   Elixir) — idempotent, safe to rerun.
3. **Builds the release on the target itself**: `deps.get --only prod`,
   `compile`, `assets.setup`, `assets.deploy`, `ecto.migrate` — all run
   with `MIX_ENV=prod` and a short-lived, root-only env file supplying
   `DATABASE_PATH`/`SECRET_KEY_BASE`/`PHX_HOST` (deleted immediately after
   the build, even on failure).
4. **Writes/refreshes a systemd unit** (`pairingsengine.service`) with the
   production environment baked into `Environment=` lines (chmod 600 — the
   unit file contains `SECRET_KEY_BASE` and SMTP credentials). If a unit
   already exists from a prior deploy, its `SECRET_KEY_BASE` is **reused**
   rather than regenerated, so redeploying never invalidates every existing
   user's logged-in session.
5. **Restarts the service** and prints the last systemd/journalctl output
   so a failed boot is visible immediately.

## Production database

`DATABASE_PATH` points at a stable location **outside** the uploaded app
tree specifically so re-running the deploy (which re-uploads the whole app
directory) never touches live tournament data. The very first deploy
carries over any pre-existing dev-mode database exactly once; every deploy
after that leaves the production database file completely untouched except
for `ecto.migrate` applying new migrations.

## Configuration (environment variables)

All read in `config/runtime.exs`, which also loads a local `.env` file (if
present) without ever overwriting a real process environment variable —
so a systemd `Environment=` line always wins over `.env` on the actual
server.

| Variable | Required in prod? | Purpose |
| --- | --- | --- |
| `DATABASE_PATH` | yes | absolute path to the SQLite file |
| `SECRET_KEY_BASE` | yes | cookie/session signing — generate once, keep stable |
| `PHX_HOST` | yes | public hostname (also the LiveView websocket origin-check value) |
| `PHX_SERVER` | yes (`true`) | actually serve HTTP — a release doesn't by default |
| `PORT` | no (default 4000) | internal HTTP port |
| `SMTP_USERNAME` / `SMTP_PASSWORD` | yes | magic-link login sends real e-mail in prod — **the app refuses to boot without both**, since there is no local mailbox fallback outside dev |
| `POOL_SIZE` | no (default 5) | Ecto connection pool size |
| `DNS_CLUSTER_QUERY` | no | multi-node clustering, unused in this single-node deployment |

The prod-boot refusal on missing SMTP credentials is deliberate, not a bug:
this app has no account-recovery path other than magic-link e-mail, so a
production boot with no way to actually deliver that e-mail would silently
lock every user out.

## Reverse proxy / TLS

The app listens on a plain internal HTTP port; TLS termination and the
public hostname routing happen in front of it (a reverse proxy/tunnel, not
configured inside this repository). `config/prod.exs` sets `force_ssl` with
`rewrite_on: [:x_forwarded_proto]`, so it trusts a forwarded-proto header
from whatever sits in front rather than terminating TLS itself.

## Secrets

Nothing production-sensitive is committed to this repository:

- `.env` (SMTP credentials for local dev) is gitignored.
- The deploy script itself lives outside the repo and prompts for
  credentials interactively (or reads them from its own local, gitignored
  `.env` next to it) rather than storing them anywhere in version control.
- The systemd unit on the server (containing `SECRET_KEY_BASE` and SMTP
  credentials) is `chmod 600`, root-only.

If you're setting up a **new** deployment target from scratch rather than
redeploying the existing one, you need: a target host reachable over SSH,
Java + Erlang + Elixir (the deploy script installs these if absent on a
Rocky/RHEL-family target), a Gmail account with an app password (or another
SMTP provider — the mailer config in `config/runtime.exs` is Gmail-specific
today), and a domain pointed at the host for `PHX_HOST`.

## CI (does not deploy anything)

`.github/workflows/elixir.yml` runs the Elixir test/format/compile checks on
every push — it has no deployment step. `.github/workflows/binaries.yml`
builds the standalone Burrito binaries and attaches them to GitHub as
release assets on a `v*` tag push — a completely separate distribution
channel from the VPS deployment described above, see
[`docs/binaries.md`](binaries.md). Deploying to the live VPS is always a
manual, maintainer-run action.
