# Deployment

How the live instance is actually run. For the standalone-binary
distribution path (a completely separate, self-contained option), see
[`docs/binaries.md`](binaries.md).

## Where it's running

The live instance is served at **https://pairings.zerotwo.cloud** - a
Rocky Linux VPS running the app directly as a Phoenix release under
`systemd`, `MIX_ENV=prod`. This document intentionally omits the host's IP
address, SSH access details, and any credentials - those live outside this
repository (see "Secrets" below), not in version control.

## Deployment model

Not containerized, not orchestrated - a straightforward "upload the source,
compile it on the target, run it as a systemd service" deploy, driven by a
Python script (`deploy_openpairings.py`, kept outside this repo on the
maintainer's machine, not committed here since it embeds host-specific
paths and prompts for credentials at deploy time).

What the deploy script actually does, in order:

1. **Uploads the app tree via SFTP** to a fixed path on the server, skipping
   `.git`, `_build`, `deps`, `node_modules`, `.env`, and any local SQLite
   files (dev/test databases never get uploaded - the production database
   is a separate, stable path outside the uploaded tree, see below).
2. **Installs prerequisites** on the target if missing (Java, Erlang,
   Elixir) - idempotent, safe to rerun.
3. **Builds the release on the target itself**: `deps.get --only prod`,
   `compile`, `assets.setup`, `assets.deploy`, `ecto.migrate` - all run
   with `MIX_ENV=prod` and a short-lived, root-only env file supplying
   `DATABASE_PATH`/`SECRET_KEY_BASE`/`PHX_HOST` (deleted immediately after
   the build, even on failure).
4. **Writes/refreshes a systemd unit** (`pairingsengine.service`) with the
   production environment baked into `Environment=` lines (chmod 600 - the
   unit file contains `SECRET_KEY_BASE` and SMTP credentials). If a unit
   already exists from a prior deploy, its `SECRET_KEY_BASE` is **reused**
   rather than regenerated, so redeploying never invalidates every existing
   user's logged-in session.
4b. **Warns everyone who has a page open**, if `DEPLOY_NOTICE_TOKEN` is
   set - and note WHERE in the sequence this happens.

   The notice goes out after the build and **before** `ecto.migrate`, not
   just before the restart. Everything up to that point is invisible to
   users: the old release is still serving its own code against the old
   schema. Migrations are the first step that changes what the running app
   sees, and a destructive one - a dropped column, say - can break the old
   code the moment it lands. So the ten-minute wait sits before the
   migration, leaving migrate and restart back to back, seconds apart, as
   they always were.

   Waiting *after* migrating would leave the previous release running
   against a migrated schema for ten minutes, which is a better way to
   cause an outage than the one this feature prevents.

   The script does this itself (`announce_deploy_notice` /
   `wait_out_notice`). Every connected LiveView shows a banner that counts
   down and escalates: informational, then at 2 minutes "finish and save
   what you are doing", then red under 30 seconds. The countdown runs in
   the browser, so this costs one message per page, not one per second.

   `DEPLOY_NOTICE_MINUTES` overrides the ten; `0` skips the wait entirely,
   for a hotfix where being down sooner beats being polite.

   **Bootstrap:** the app being asked is the one *currently running*, so
   the first deploy after adding the token is refused - that process was
   started without it. The script reports this and carries on. From the
   next deploy onwards it works.

   If the migration fails the script withdraws the notice, so a countdown
   never hits zero waiting for a restart that is not coming. The app also
   expires it five minutes past the deadline, which covers the script dying
   outright rather than failing cleanly.

   Note what the banner does NOT say, because both would be false:

   - **Nobody is logged out.** Step 4 reuses `SECRET_KEY_BASE`, so sessions
     survive a restart.
   - **Results are not lost.** Result entry writes straight through on every
     change, so they are already saved. An early version of this banner told
     arbiters to stop entering results, which was exactly backwards.

   What a reconnect does cost is server-side state rebuilt by `mount` - an
   open dialog, a half-filled registration form, and the settings pages with
   an explicit Save button. That is what it warns about.

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
present) without ever overwriting a real process environment variable -
so a systemd `Environment=` line always wins over `.env` on the actual
server.

| Variable | Required in prod? | Purpose |
| --- | --- | --- |
| `DATABASE_PATH` | yes | absolute path to the SQLite file |
| `SECRET_KEY_BASE` | yes | cookie/session signing - generate once, keep stable |
| `PHX_HOST` | yes | public hostname (also the LiveView websocket origin-check value) |
| `PHX_SERVER` | yes (`true`) | actually serve HTTP - a release doesn't by default |
| `PORT` | no (default 4000) | internal HTTP port |
| `SMTP_USERNAME` / `SMTP_PASSWORD` | yes | magic-link login sends real e-mail in prod - **the app refuses to boot without both**, since there is no local mailbox fallback outside dev |
| `POOL_SIZE` | no (default 5) | Ecto connection pool size |
| `DEPLOY_NOTICE_TOKEN` | no | shared secret for the pre-restart warning below. Unset means the endpoint refuses everything, so the only cost of omitting it is no banner |
| `DNS_CLUSTER_QUERY` | no | multi-node clustering, unused in this single-node deployment |
| `KEYCLOAK_CLIENT_ID` | no | 02cloud SSO client id (`openpairings`). Omit to disable SSO entirely |
| `KEYCLOAK_CLIENT_SECRET` | no | the confidential client's secret - **treat like `SECRET_KEY_BASE`** |
| `KEYCLOAK_ISSUER` | no | defaults to `https://auth.zerotwo.cloud/realms/zerotwo` |
| `KEYCLOAK_REDIRECT_URI` | no | defaults to `https://$PHX_HOST/auth/keycloak/callback` |
| `FIDE_LIST_URL` | no | where the monthly rating-list zip is fetched from. Defaults to `https://ratings.fide.com/download/players_list.zip`. **Set this on any host FIDE blocks** - see below |
| `SSO_BLOCKED_REGISTRATION_DOMAIN` | no | the e-mail domain self-serve registration/email-change is blocked on (accounts there must come from SSO instead - see `PairingsEngine.Accounts.User.blocked_registration_domain/0`). Defaults to `zerotwo.cloud`. Only relevant if a second federated domain is ever added |

### `FIDE_LIST_URL` - working around FIDE's hosting-range blocks

ratings.fide.com refuses a lot of VPS address ranges outright, and the
symptom is unhelpful: the sync sits on "Contacting FIDE…" and eventually
fails the 3-minute watchdog with `%Req.TransportError{reason: :timeout}`,
looking exactly like a hang. Pointing `FIDE_LIST_URL` at a mirror or a
pass-through proxy is the only fix available from the app's side.

Whatever it points at is unzipped and loaded straight into `fide_players`, so
it is trusted exactly as much as FIDE is - **only set it to something you
control.**

The deploy script passes `DEPLOY_FIDE_LIST_URL` (or plain `FIDE_LIST_URL`)
from its own `.env` into the systemd unit's `Environment=` lines. That's the
right home rather than a `.env` on the server: the deploy **rewrites the unit
every run**, so anything the script generates is reproducible from your
machine, while anything hand-added to the unit gets wiped. (Long-lived
hand-managed values instead belong in a drop-in under
`/etc/systemd/system/pairingsengine.service.d/`, which the deploy leaves
alone - that's where the `KEYCLOAK_*` values live.)

To confirm which source is live, the sync's progress line names the host it's
dialling: `Contacting FIDE…` means the override didn't take (unset, mistyped,
quoted - the `.env` loader does not strip quotes - or the service wasn't
restarted), while `Contacting <your-host>…` means it did.

## 02cloud SSO (Keycloak)

Unlike SMTP, SSO is **optional and never blocks boot**: it's one login option
among magic link and password, not the only account-recovery path. With
`KEYCLOAK_CLIENT_ID`/`KEYCLOAK_CLIENT_SECRET` unset, `Keycloak.configured?/0`
returns false, the "Sign in with SSO" button is not rendered at all, and
`/auth/keycloak` answers with a flash instead of a crash. That's what every dev
checkout looks like.

The identity provider is `auth.zerotwo.cloud` (Keycloak 26, realm `zerotwo`,
AD-federated) - a separate project, see its own `auth framework` repository.
The client registered there for this app:

| Setting | Value |
| --- | --- |
| clientId | `openpairings` |
| type | confidential (`publicClient: false`), standard flow only |
| redirect URIs | `https://pairings.zerotwo.cloud/auth/keycloak/callback`, `http://localhost:4000/auth/keycloak/callback` |
| `alwaysDisplayInConsole` | `true` - required for it to appear as a tile in the 02cloud launcher; a `baseUrl` alone does **not** imply it |

The secret is generated by Keycloak, not chosen. To read it again later, or
after a rotation, run on the auth host (`root@10.10.102.21`):

```bash
kcadm.sh get clients -r zerotwo -q clientId=openpairings --fields id,secret
```

Add both values to the production systemd unit as `Environment=` lines (the
deploy script writes that file `chmod 600`, alongside `SECRET_KEY_BASE` and the
SMTP credentials) and restart. Nothing about SSO belongs in the repository.

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
SMTP provider - the mailer config in `config/runtime.exs` is Gmail-specific
today), and a domain pointed at the host for `PHX_HOST`.

## CI (does not deploy anything)

`.github/workflows/elixir.yml` runs the Elixir test/format/compile checks on
every push - it has no deployment step. `.github/workflows/binaries.yml`
builds the standalone Burrito binaries and attaches them to GitHub as
release assets on a `v*` tag push - a completely separate distribution
channel from the VPS deployment described above, see
[`docs/binaries.md`](binaries.md). Deploying to the live VPS is always a
manual, maintainer-run action.
