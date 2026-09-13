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

## Two apps, one host

Since the split, the same box runs both halves:

| | OpenPairings (this repo) | OpenResults |
| --- | --- | --- |
| public URL | `https://pairings.zerotwo.cloud` | `https://openresults.zerotwo.cloud` |
| internal port | 4001 | 4004 |
| app tree | `/apps/web/pairingsengine` | `/apps/web/openresults` |
| systemd unit | `pairingsengine.service` | `openresults.service` |
| database | `/var/lib/pairingsengine/pairings_engine.db` | `/var/lib/openresults/openresults.db` |

They share a host, a deploy script, and nothing else - separate trees,
separate units, separate databases, separate `SECRET_KEY_BASE`. Deploying one
neither touches nor restarts the other, which is the whole point: the reason
for the split is that a busy public results page and a live pairing session
should not be able to take each other down, and that would be a hollow promise
if every deploy restarted both.

The OpenResults side has its own `docs/deployment.md`, which is the place to
look for the ingest token, the tunnel hostname mapping, and why it sits on
port 4004.

## Deployment model

Not containerized, not orchestrated - a straightforward "upload the source,
compile it on the target, run it as a systemd service" deploy, driven by a
Python script (`deploy_openpairings.py`, kept outside this repo on the
maintainer's machine, not committed here since it embeds host-specific
paths and prompts for credentials at deploy time).

The script deploys either app, or both:

```bash
python deploy_openpairings.py                   # OpenPairings only - the default
python deploy_openpairings.py --openresults     # OpenResults only
python deploy_openpairings.py --both            # both, in that order
```

A bare run still means what it always meant, so nothing about existing muscle
memory changes; OpenResults has to be asked for, so that a routine arbiter-side
deploy never restarts the public site as a side effect. An **unrecognised
argument is fatal**, which is a change from when `--fast` was the only option:
a typo like `--openresult` that merely printed a complaint would go on to
deploy the default app instead, restarting the wrong service while the
operator watched a wall of output for the one they asked for.

First, once per run and not once per app, it **installs prerequisites** on the
target if they are missing (Java, Erlang, Elixir) - idempotent, safe to rerun,
and shared by both apps since they compile with the same toolchain.

Then, for each selected app in turn:

1. **Checks the port is free**, or already held by that app's own unit,
   before uploading anything. Writing a unit that points at an occupied port
   does not fail loudly: systemd starts the service, Bandit cannot bind, the
   app dies, and systemd restarts it forever. This host has four other
   services in the 3000-4003 range, so the answer is worth having while it is
   still cheap.
2. **Uploads the app tree via SFTP** to a fixed path on the server, skipping
   `.git`, `_build`, `deps`, `node_modules`, `.env`, `erl_crash.dump`, and any
   local SQLite files (dev/test databases never get uploaded - the production
   database is a separate, stable path outside the uploaded tree, see below).
3. **Ensures the database directory exists**, and on OpenPairings only,
   carries over a pre-restructure dev database exactly once if there is no
   production database yet.
4. **Builds the release on the target itself**: `deps.get --only prod`,
   `compile`, `assets.setup`, `assets.deploy`, then (after the warning below)
   `ecto.create` and `ecto.migrate` - all run with `MIX_ENV=prod` and a
   short-lived, root-only env file supplying
   `DATABASE_PATH`/`SECRET_KEY_BASE`/`PHX_HOST` (deleted immediately after
   the build, even on failure).

   **A failing build step now stops the deploy.** See "Why the build is
   allowed to fail loudly" below - this used to print a warning and carry on,
   and that is how the site went down on 2026-08-28.
5. **Writes/refreshes a systemd unit** (`pairingsengine.service`) with the
   production environment baked into `Environment=` lines (chmod 600 - the
   unit file contains `SECRET_KEY_BASE` and SMTP credentials).

   **The unit runs as a service account, not as root.** Until 2026-09-01
   both units had `User=root` on a box that also serves the public results
   site. Each app now has its own unprivileged account, with
   `NoNewPrivileges=true` so nothing it execs can climb back,
   `ProtectSystem=strict` making the whole filesystem read-only except the
   `ReadWritePaths` it genuinely needs, `ProtectHome` hiding /home and
   /root, and `PrivateTmp` giving it a /tmp of its own - which is where the
   JaVaFo scratch files go. The uploaded tree is chowned to that account
   before the service starts, because `ProtectSystem=strict` otherwise
   leaves it unable to write its own `_build`. If a unit
   already exists from a prior deploy, its `SECRET_KEY_BASE` is **reused**
   rather than regenerated, so redeploying never invalidates every existing
   user's logged-in session. Right after, OpenPairings also gets
   `/usr/local/bin/app-role` (re)installed - a small wrapper around `mix
   pairings.role` that reads this same unit's values instead of needing them
   typed by hand; see "Granting the first administrator" below.
5b. **Warns everyone who has a page open**, if `DEPLOY_NOTICE_TOKEN` is
   set - and note WHERE in the sequence this happens.

   This step is **OpenPairings only**. OpenResults has no accounts, no
   sessions and no half-filled forms held in server memory on its reading
   path, so there is nobody to warn and nothing for them to save.

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

   **`--fast`** (or `-f`) cuts the warning to 30 seconds, for a hotfix
   where the thing being fixed is worse than the interruption:

   ```bash
   python deploy_openpairings.py --fast
   ```

   At 30 seconds the banner opens straight on its red tier - there is no
   gentle phase to escalate from - so people get one loud "go and grab a
   coffee, we will be back in about 30 seconds" rather than a countdown
   they will not finish reading.

   It is a flag rather than a smaller default on purpose. Ten minutes is
   the right answer during a live tournament, and the short one should have
   to be asked for each time instead of being inherited from a `.env`
   somebody edited months ago.

   `DEPLOY_NOTICE_MINUTES` overrides the ten for every run; `0` skips the
   wait entirely.

   **Bootstrap:** the app being asked is the one *currently running*, so
   the first deploy after adding the token is refused - that process was
   started without it. The script reports this and carries on. From the
   next deploy onwards it works.

   If the migration fails the script withdraws the notice, so a countdown
   never hits zero waiting for a restart that is not coming. The app also
   expires it five minutes past the deadline, which covers the script dying
   outright rather than failing cleanly.

   Note what the banner does NOT say, because both would be false:

   - **Nobody is logged out.** Step 5 reuses `SECRET_KEY_BASE`, so sessions
     survive a restart.
   - **Results are not lost.** Result entry writes straight through on every
     change, so they are already saved. An early version of this banner told
     arbiters to stop entering results, which was exactly backwards.

   What a reconnect does cost is server-side state rebuilt by `mount` - an
   open dialog, a half-filled registration form, and the settings pages with
   an explicit Save button. That is what it warns about.

6. **Restarts the service, then proves it came back.** Not the same thing,
   and the difference is the subject of the next section.

## Why the build is allowed to fail loudly

On **2026-08-28** this script printed "Deployment Completed Successfully!"
while the same output showed the service dead, and pairings.zerotwo.cloud
stayed down for six minutes past the window users had been promised.

The chain, because the shape will recur:

1. `mix.lock` moved a git dependency to a new tag.
2. That dependency's checkout under `deps/` on the box had a stray local
   edit, so git refused to move a dirty working tree onto a different commit.
3. `mix deps.get` aborted - and because it aborted, `compile`,
   `assets.deploy` **and** `ecto.migrate` all aborted with it.
4. The script restarted the service anyway, because every build step was
   treated as advisory. The app booted against a stale dependency and a schema
   that had never been migrated.
5. Nothing checked whether it had come back. It had not.

Two rules came out of that, and they are the reason the sequence looks the way
it does.

### A failing build step stops the deploy

`deps.get`, `compile`, `assets.deploy` and `ecto.migrate` each produce part of
what the restarted app will run, so a failure in any of them means the restart
must not happen. The script aborts before it touches systemd and says so.

The old release keeps serving, untouched. That is the correct outcome, not a
consolation prize: a deploy that could not build is a deploy that has not
happened, and the running app is still the last one that did.

Only genuinely idempotent, best-effort steps - `local.hex`, `local.rebar`,
`assets.setup`, `ecto.create` - are still allowed to whinge and carry on.
`assets.setup` merely fetches the esbuild and tailwind binaries, which are
already there after the first deploy; `assets.deploy`, which produces what the
browser actually fetches, is critical and will fail loudly if they really are
missing.

If a migration fails after the countdown has gone out, the notice is withdrawn,
so nobody is left watching a clock tick down to a restart that is not coming.

### The one `deps.get` failure worth recovering from automatically

A dirty checkout under `deps/` is never worth keeping - it is a cache of
somebody else's source. So when `deps.get` fails, the script finds the dirty
git checkouts, throws each away, and retries **once**.

```
mix deps.clean <dep>           removes deps/<dep> AND its build artifacts,
                               so the next deps.get re-clones clean. This is
                               the one that fixes it.

mix deps.clean --build <dep>   removes ONLY the build artifacts and leaves
                               deps/<dep> exactly as dirty as it was.
```

`--build` is the trap, and it is worth knowing about before a live tournament
rather than during one. It reads as the more thorough of the two and it leaves
the actual problem in place: the retry fails with the identical message, and it
looks as though the recovery did nothing.

Only checkouts that are genuinely dirty are cleaned. A blanket
`deps.clean --all` would re-fetch and rebuild every dependency and turn a
thirty-second recovery into a long outage. And exactly one retry, never a loop:
if a clean re-fetch still cannot resolve the tree, the problem is the lock file
or the network, and grinding away at it only delays the moment the deploy
admits it is stuck.

This repo has three git dependencies - `heroicons`, `daisyui` and `ainalrami` -
and the engine pin moves often enough that this is not a hypothetical.

### A restart is not a deploy until the app answers

After every restart the script polls, up to `DEPLOY_HEALTH_TIMEOUT` seconds
(default 90), on two independent signals:

- **systemd.** `failed` or `inactive` means it is not coming back, and
  `NRestarts` above zero means it booted, died, and is being restarted in a
  loop - a manual `systemctl restart` zeroes that counter, so anything above
  zero was earned since the deploy. Either verdict is returned immediately
  rather than waiting out the timeout for news that has already arrived.
- **HTTP.** `active` only proves a process exists. So the script also asks the
  app itself, over loopback.

If neither succeeds inside the timeout, the script dumps `systemctl status` and
the last 60 journal lines and **exits non-zero**. The closing banner is derived
from what actually happened, per app, rather than printed unconditionally.

The HTTP check accepts **any status code that is not `000` and not a `5xx`** -
deliberately not `200`. `curl` reports `000` when it got no response at all,
and that, plus a server error, is the real negative. Demanding `200` would fail
every healthy deploy of this app: `GET /` here is a `302` to the login page,
and a request carrying the public `Host` header answers `301` from `force_ssl`.

That the check works over plain HTTP at all depends on `config/prod.exs`
excluding `localhost` and `127.0.0.1` from `force_ssl`. Keep that exclusion.

90 seconds is sized to survive a slow first boot, not to paper over a crash
loop - a warm boot on this box takes about a second and a half, and a crash
loop is detected directly rather than by waiting for the timeout.

## Production database

`DATABASE_PATH` points at a stable location **outside** the uploaded app
tree specifically so re-running the deploy (which re-uploads the whole app
directory) never touches live tournament data. The very first deploy
carries over any pre-existing dev-mode database exactly once; every deploy
after that leaves the production database file completely untouched except
for `ecto.migrate` applying new migrations.

## Backups

`PairingsEngine.Backup.Scheduler` writes one five minutes after every boot and
then every 24 hours; **Connections → Backups** and `mix pairings.backup` write
one on demand. Each is `openpairings-<UTC time>.opbak` in `backups/` beside
the database (`/var/lib/pairingsengine/backups`): the whole database,
gzip-compressed, with the FIDE and KBSB rating lists emptied (a sync rebuilds
them).

| Variable | Default | Purpose |
| --- | --- | --- |
| `BACKUP_DIR` | `backups/` beside the database | where they are written |
| `BACKUP_RETENTION` | 30 | how many files are kept |
| `PAIRINGS_BACKUP_PASSPHRASE` | none | encrypts them (AES-256-GCM); the same value is needed to verify or restore one |

All three are read only in production (`config/runtime.exs`, prod block).
**The deploy script sets none of them**, so on this host backups are
unencrypted - and an unencrypted OpenPairings backup is a key ring, not just a
copy of results: player email addresses from the entry form, every
tournament's publishing key, the password hashes and live session tokens of
every account, and **the OpenResults operator token itself** (`meta`,
`openresults_token`), which can overwrite or delete any tournament on the
results site. Anyone an administrator hands a downloaded backup to holds all
of that.

Retention is a count, and every boot and every "take one now" spends one:
thirty files are thirty days only on a box nobody restarts.
`BACKUP_RETENTION=0` deletes every backup, the one just written included,
and a negative value deletes the newest and keeps the oldest - the drill ran
both. Keep it at 1 or more.

A backup on the same disk survives a bad deploy, not the disk: download one
from Connections now and then. Keep the copy you would restore from **outside**
`backups/`, where the next prune counts it.

## Restoring a backup

Rehearsed on 2026-09-13; `docs/restore-drill-2026-09-13.md` has the run, the
timings and everything that broke. The commands below take about fifteen
seconds; `mix` starting is most of it, so allow a minute or two on the box.
`mix pairings.backup --restore` prints four commands of its own when it
finishes. **Do not use them**: they move the database without its WAL, which
in the drill had SQLite read the old database back through the restored
file's name. Step 5 is what they should have said.

Before you start, read "What a restore undoes". If the current database still
opens, do not delete it: it is the only record of what happened after the
backup, and step 6 needs it.

All as root.

**1. Give your shell the service's environment**, and a way to run `mix` as
the service account. The tasks need `DATABASE_PATH` and `SECRET_KEY_BASE`
before they run a line of their own, and running them as the service account
keeps what they write from being owned by root.

```bash
unit=/etc/systemd/system/pairingsengine.service
for k in MIX_ENV DATABASE_PATH SECRET_KEY_BASE MIX_HOME HEX_HOME PATH PORT BACKUP_DIR PAIRINGS_BACKUP_PASSPHRASE; do
  v=$(cat "$unit" "$unit".d/*.conf 2>/dev/null | sed -n "s|^Environment=\"$k=\(.*\)\"\$|\1|p" | tail -1)
  [ -n "$v" ] && export "$k=$v"
done
app() { (cd /apps/web/pairingsengine && runuser --preserve-environment -u pairingsengine -- mix "$@"); }
```

Read line by line and exported, never sourced - the reason is in the deploy
script's `app-role` wrapper, which does the same. `PHX_SERVER` is left out on
purpose: with it set, `config/runtime.exs` also demands the SMTP credentials.

**2. Choose and check the file.**

```bash
app pairings.backup --list
app pairings.backup --verify /var/lib/pairingsengine/backups/openpairings-2026-09-13T00-24-27Z.opbak
```

Give `--verify` and `--restore` the whole path: the name `--list` prints is
not found on its own. `--verify` proves the file decrypts, decompresses and
has this app's core tables - and nothing more: it does not read the pages,
and in the drill it passed a backup whose `pairings` table was damaged. Step 3
checks that.

**3. Recover it beside the live database, and read every page of it.**

```bash
app pairings.backup --restore /var/lib/pairingsengine/backups/openpairings-2026-09-13T00-24-27Z.opbak
runuser -u pairingsengine -- python3 -c "import sqlite3; print(sqlite3.connect('file:/var/lib/pairingsengine/pairings_engine.db.restored?mode=ro', uri=True).execute('PRAGMA integrity_check').fetchone()[0])"
```

The second line must print `ok`. Anything else: delete the `.restored` file
and try an older backup. (Read-only on purpose: a plain `connect` on a path
that is not there creates an empty database, which checks `ok`.)

**4. Stop the service, and make sure it stopped.**

```bash
systemctl stop pairingsengine
systemctl is-active pairingsengine       # must print: inactive
```

**5. Swap - moving the WAL with the database.**

```bash
cd /var/lib/pairingsengine
stamp=$(date -u +%Y%m%dT%H%M%SZ)
for f in pairings_engine.db pairings_engine.db-wal pairings_engine.db-shm; do
  [ -e "$f" ] && mv "$f" "${f/pairings_engine.db/pairings_engine.db.before-restore-$stamp}"
done
mv pairings_engine.db.restored pairings_engine.db
chown --reference=. pairings_engine.db
```

After a clean stop there is no `-wal` or `-shm`. After a crash, an OOM kill, a
stop that ran into systemd's timeout - or a `mix` task that exited without
checkpointing, which `mix ecto.migrate` on a fresh database does - there is,
and the newest writes are in it. Moving the `.db` alone does two kinds of
damage, both reproduced in the drill: the `before-restore` copy is missing
everything in the WAL (it was a single empty page), and the WAL left behind is
read INTO the restored file, because SQLite cannot tell it belongs to a
different database - in the drill SQLite read the old database back under
the restored file's name, and `PRAGMA integrity_check` said `ok`. Renamed
together, the `before-restore` file and its `-wal` still open as one
database.

`chown`: if the recovered file was written by root rather than through `app`,
SQLite opens it read-only for the service - pages load and nothing saves.
`--reference=.` takes the owner of the directory, which the deploy gives the
service account.

**6. Carry the results site forward, and see what else the restore undid.**

What the backup says about publishing is older than what the results site
knows. A tournament taken down after the backup still has its key here and is
published again on its next change (the drill's came back online); one first
published after the backup has no key here, and the results site refuses every
update from it. Both are fixed by taking each tournament's publishing state
from the database you just moved aside, before the app starts:

```bash
runuser -u pairingsengine -- python3 - pairings_engine.db pairings_engine.db.before-restore-$stamp <<'EOF'
import sqlite3, sys
restored, before = sys.argv[1], sys.argv[2]
db = sqlite3.connect(f"file:{restored}", uri=True)
db.execute("ATTACH ? AS old", (f"file:{before}?mode=ro",))
moved = db.execute(
    "UPDATE main.tournaments AS t SET public_slug = o.public_slug, openresults_key = o.openresults_key, "
    "publish_to_openresults = o.publish_to_openresults FROM old.tournaments AS o "
    "WHERE o.id = t.id AND (t.openresults_key IS NOT o.openresults_key OR t.public_slug IS NOT o.public_slug "
    "OR t.publish_to_openresults IS NOT o.publish_to_openresults)").rowcount
dropped = db.execute(
    "DELETE FROM main.publish_queue WHERE tournament_id IN "
    "(SELECT id FROM main.tournaments WHERE publish_to_openresults = 0 OR openresults_key IS NULL)").rowcount
db.commit()
db.close()
print(f"publishing state carried forward for {moved} tournament(s); {dropped} stale queued publish(es) dropped")
EOF
```

Then list what is left to re-apply by hand:

```bash
runuser -u pairingsengine -- python3 - pairings_engine.db pairings_engine.db.before-restore-$stamp <<'EOF'
import sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
db.execute("ATTACH ? AS old", (f"file:{sys.argv[2]}?mode=ro",))
def show(title, sql):
    rows = db.execute(sql).fetchall()
    print(f"\n{title}: {len(rows)}")
    for r in rows: print("  ", *r)
show("CREATED after the backup - lost here; a published copy can now only be removed with the operator token",
     "SELECT o.id, o.name, ifnull(o.public_slug, '') || CASE WHEN o.openresults_key IS NULL THEN '' ELSE '  (published)' END "
     "FROM old.tournaments o WHERE o.id NOT IN (SELECT id FROM main.tournaments)")
show("deleted after the backup - back now", "SELECT id, name FROM main.tournaments WHERE id NOT IN (SELECT id FROM old.tournaments)")
show("accounts whose role or password changed after the backup - the old ones are back",
     "SELECT m.email, m.role || ' -> ' || o.role, CASE WHEN m.hashed_password IS NOT o.hashed_password THEN 'password changed' ELSE '' END "
     "FROM main.users m JOIN old.users o USING (id) WHERE m.role <> o.role OR m.hashed_password IS NOT o.hashed_password")
show("accounts created after the backup - gone", "SELECT email FROM old.users WHERE id NOT IN (SELECT id FROM main.users)")
show("sign-in sessions ended after the backup - valid again",
     "SELECT u.email, count(*) FROM main.users_tokens t JOIN main.users u ON u.id = t.user_id "
     "WHERE t.context = 'session' AND t.id NOT IN (SELECT id FROM old.users_tokens) GROUP BY u.email")
show("machine settings that differ (restored -> before)",
     "SELECT key, CASE WHEN key LIKE '%token%' OR key LIKE '%key%' THEN 'differs' ELSE ifnull(m.value, '-') || ' -> ' || ifnull(o.value, '-') END "
     "FROM (SELECT key FROM main.meta UNION SELECT key FROM old.meta) k LEFT JOIN main.meta m USING (key) LEFT JOIN old.meta o USING (key) "
     "WHERE m.value IS NOT o.value AND key NOT LIKE 'openresults_last_publish%'")
EOF
```

Both run as the service account, because SQLite may create a `-shm` even for
a database it only reads. If the old database is gone, skip this step and use
"What a restore undoes" as a checklist.

**7. Migrate.**

```bash
app ecto.migrate
```

The service runs `mix phx.server`, which does not migrate - only a release
does. A backup older than the code boots and answers HTTP while every page
that reads a tournament fails: the drill restored a backup one migration
behind and got `no such column: t0.standings_through` on the tournament list.
On a freshly restored file this step logs one `database is locked` line: the
file comes back from the backup in rollback-journal mode, and the migrator's
second connection loses the switch to WAL and retries. It is harmless, and it
is better here than on the service's first boot, where it would otherwise
appear.

**8. Start, and check.**

```bash
systemctl start pairingsengine
curl -s -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:${PORT:-4001}/"   # 302, to the login page
journalctl -u pairingsengine -n 20 --no-pager
```

Then, signed in as an administrator:

- **Connections**: the rating lists are empty (they are not in a backup) -
  start a FIDE sync, and a KBSB one if you use it. The page may still show
  the last sync's date beside "0 players"; the count is the truth.
- **Connections → publishing**: the address and token are the backup's. If the
  OpenResults token was rotated since, the indicator says "refused" - run the
  deploy, or `app pairings.publishing --ensure --force` with the current
  values, as the deploy does.
- Re-apply what step 6 listed: role changes, password resets, and - if a
  session was ended for a reason - sign that account out again.
- Tournaments created after the backup exist only in the `before-restore`
  file. A published one can be withdrawn from the results site only with the
  operator token (OpenResults' `docs/deployment.md`, "It is also the
  break-glass key").

Keep the `before-restore` files until all of that is done.

## What a restore undoes

Everything written after the backup. The rows are the obvious part; these are
the ones that bite:

| After the backup, somebody... | After the restore |
| --- | --- |
| took a tournament off the results site, or moved it to a new address | the old key is back, and the next change to the tournament publishes it again under the old address - withdrawn, then silently back online (step 6 fixes it) |
| published a tournament for the first time | no key here; every update is refused as "a different machine published this tournament" - a message that is wrong about which machine (step 6 fixes it) |
| created and published a tournament | the tournament is gone from here, and its public page has nobody who can take it down except the operator |
| changed a password, lost a role, or was signed out | the old password works, the role is back, the session is valid again |
| accepted an entry from the form | the entry is pending again; ones still on the results site are pulled again on the next poll |
| rotated the OpenResults token | the old token is back in `meta`; publishing is refused until it is set again |

The per-installation results-site key of a desktop copy in public mode (see
OpenResults' `docs/public-publishing.md`) is deliberately never in a backup:
after a restore that copy registers again and the operator moves its
tournaments to the new installation.

## Restoring on a desktop install

A desktop copy writes the same backups, to `backups\` beside its database
(`%LOCALAPPDATA%\OpenPairings` on Windows), and has no `mix` to restore them
with. The portable release's own `eval` can - tested in the drill with a
0.56.0 portable build:

1. Close OpenPairings.
2. Put this in a file, say `restore.exs`, with the backup's real path:

   ```elixir
   IO.inspect(PairingsEngine.Backup.restore("C:/path/to/openpairings-2026-09-13T00-24-27Z.opbak"))
   ```

3. From the release folder, in a Command Prompt:

   ```bat
   set OPENPAIRINGS_LOCAL=1
   set RELEASE_DISTRIBUTION=none
   bin\pairings_engine_portable.bat eval "Code.eval_file ~S[C:\path\to\restore.exs]"
   ```

   No parentheses or pipes on that command line: the `.bat` launcher passes
   its arguments through `cmd`, which eats both. That is why the call lives in
   a file.
4. In the data folder, rename `openpairings.db` and any `openpairings.db-wal`
   and `openpairings.db-shm` together (for example to
   `openpairings.db.before-restore`, `openpairings.db.before-restore-wal`,
   `openpairings.db.before-restore-shm`), then rename
   `openpairings.db.restored` to `openpairings.db`.
5. Start OpenPairings. A release migrates at boot.

On Windows the restore also leaves a full, decrypted copy of the database in
`%TEMP%` (`opbak-verify-*.db`) - see the drill document. Delete it.

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
| `PORT` | no (default 4000) | internal HTTP port - **the unit sets 4001**, see "Ports on this host" |
| `SMTP_USERNAME` / `SMTP_PASSWORD` | yes | magic-link login sends real e-mail in prod - **the app refuses to boot without both**, since there is no local mailbox fallback outside dev |
| `POOL_SIZE` | no (default 5) | Ecto connection pool size |
| `OPENPAIRINGS_LISTEN_IP` | no (default `127.0.0.1`) | which address to bind. The default is loopback, because the only client here is the cloudflared process on the same host; set `0.0.0.0` (every IPv4 address) or `::` (every address) only for a deployment that is genuinely reached directly. An unparseable value refuses to boot rather than falling back to a wide bind |
| `TRUSTED_PROXY_HOPS` | no (default 0) | how many proxies sit in front of the app, i.e. how many entries to trust from the right of `x-forwarded-for` &mdash; **the unit sets 1**, for the single cloudflared hop. Left at 0 the app trusts no forwarded address at all and every visitor shares one rate-limit bucket, which makes the login throttle effectively global |
| `DEPLOY_NOTICE_TOKEN` | no | shared secret for the pre-restart warning below. Unset means the endpoint refuses everything, so the only cost of omitting it is no banner |
| `BACKUP_DIR` / `BACKUP_RETENTION` / `PAIRINGS_BACKUP_PASSPHRASE` | no | see "Backups" above |
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

## Granting the first administrator

**A hosted installation has no administrators until you name one.** Nobody can
change the publishing connection, download a backup, or start a rating-list
sync until you do, and the Connections page will say so in as many words.

Signing in through SSO is deliberately not enough: that says how somebody
authenticated, not what they may do, and treating the two as one made every
account in the federated directory an administrator of this installation's
wiring.

Set `DEPLOY_ADMIN_EMAILS` in the deploy script's `.env`, comma-separated,
and the deploy does the rest:

```bash
DEPLOY_ADMIN_EMAILS=you@example.com
```

That one setting drives **two independent routes to the same authority**,
which is deliberate - either one alone is enough to administer the box:

1. It reaches the systemd unit as `ADMIN_EMAILS`, and those addresses may
   administer with no database row at all, from the moment the app boots.
2. After migrating and before restarting, the deploy runs
   `mix pairings.role --ensure "$ADMIN_EMAILS" admin`, so they also hold the
   role in the database - which survives somebody later editing the unit.

The redundancy is the point: an installation nobody can administer is
recoverable only over SSH, so it is worth two mechanisms that fail
independently.

**`--ensure` re-grants on every deploy.** So `DEPLOY_ADMIN_EMAILS` is the
source of truth for who administers, and demoting somebody still listed
there lasts until the next deploy. To revoke for good, take the address out
of the deploy configuration **and** run:

```bash
app-role you@example.com owner
```

Doing only the second is the mistake worth naming: it looks like it worked,
and undoes itself the next time you ship.

An address with no account yet is reported and skipped rather than failing,
so a first deploy - where nobody has signed in and there is no row to
promote - is not aborted by it. Those people are covered by route 1 until
they first sign in, and picked up by route 2 on the next deploy.

Granting by hand is still there, and is what you want for `support`, or for
somebody who should hold a role independently of the deploy configuration:

```bash
app-role you@example.com admin
```

Run with no arguments it lists whoever currently holds a role. `support` grants
sight of the diagnostics without the ability to change them; `owner` revokes.

Two operational notes:

- This needs `DATABASE_PATH` and `SECRET_KEY_BASE` in the environment,
  because `config/runtime.exs` loads before the task does - and the deploy
  script's own build-env file is **deleted immediately after the build**, so
  it is never there to source by the time anyone actually needs this. That is
  what `app-role` (above) is: a wrapper the deploy script installs at
  `/usr/local/bin/app-role` on every deploy of OpenPairings, which reads
  those values straight out of the systemd unit itself (`pairingsengine.service`,
  root-only, chmod 600) and hands them to `mix pairings.role` - so `app-role
  you@example.com admin` is the command to actually run over SSH, not `mix
  pairings.role you@example.com admin` on its own, which will fail with a
  missing-`DATABASE_PATH` error the moment you try it on the box. It never
  echoes what it reads, matching `mix pairings.backup`'s own long-standing
  wrapper (installed by hand, for the identical reason) - and being rewritten
  on every deploy, it can't go stale the way a hand-installed script can.
  Local dev needs none of this: `mix pairings.role` alone is fine there,
  because `.env` already supplies both variables.
- There is no screen for this and there should not be. Shell access on the box
  can already read the database, the secrets and the backups, so making it the
  way roles are granted keeps the authority to grant admin from being something
  admin itself confers.

Local installations need none of this - see `PairingsEngine.Authz` for why.

## Ports on this host

Nothing is reachable from the internet except SSH - firewalld's public zone
opens exactly one port, and every public hostname arrives through the
Cloudflare tunnel, which dials these over loopback. A port number here is not
a security boundary, only a promise not to collide with a neighbour.

| Port | Service |
| --- | --- |
| 3000 | `dataplatform-api.service` |
| **4001** | **`pairingsengine.service` - OpenPairings** |
| 4002 | `personalsite.service` (`python3 -m http.server`) |
| 4003 | `kbsb-database-manager.service` |
| **4004** | **`openresults.service` - OpenResults** |
| 5432 | PostgreSQL |
| 8080 | nginx, in front of Keycloak on 8081 |
| 8099 | nginx default server |

OpenResults' *dev* config defaults to 4002 so both halves can run side by side
on a laptop. On this host 4002 and 4003 are taken, so production gives it
4004 - the first free port in the same block, keeping the two halves adjacent.

4000 is free and was left that way on purpose. It is what `mix phx.server`
binds when `PORT` is unset, so anything that loses its `PORT=` line - a stray
dev server, a hand-edited unit, a release someone runs by hand to check
something - lands there. Leaving it unclaimed means that accident collides
with nothing instead of quietly stealing traffic from a live service.

## Reverse proxy / TLS

The app listens on a plain internal HTTP port; TLS termination and the public
hostname routing happen in front of it. On this host that is **cloudflared**,
running as `cloudflared.service` and dialling 4001 over loopback. nginx is
installed on the box but is not involved with either app - it fronts Keycloak
only.

`config/prod.exs` sets `force_ssl` with `rewrite_on: [:x_forwarded_proto]`, so
the app trusts a forwarded-proto header from whatever sits in front rather than
terminating TLS itself. `localhost` and `127.0.0.1` are excluded from it, which
is what lets the deploy's health check speak plain HTTP over loopback.

### The tunnel hostname mapping is a manual step

**It cannot be automated from the box, and that is not an oversight.** The
tunnel is run token-based:

```
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --token <token>
```

There is no `config.yml` and no `/etc/cloudflared` ingress file - nothing on
the server says which hostname maps to which port. A token-based tunnel fetches
its entire routing table from Cloudflare at connect time, so the routing lives
in the dashboard and the dashboard is the only place it can be edited. Writing
an ingress file on the box would change nothing.

`pairings.zerotwo.cloud` is already mapped. Bringing **OpenResults** up needs
one hostname added, once, in **Cloudflare Zero Trust → Networks → Tunnels →**
the tunnel serving `zerotwo.cloud` **→ Public Hostnames → Add a public
hostname**:

| Field | Value |
| --- | --- |
| Subdomain | `openresults` |
| Domain | `zerotwo.cloud` |
| Path | *(empty)* |
| Type | `HTTP` |
| URL | `localhost:4004` |

`HTTP`, not `HTTPS`: the tunnel terminates TLS at Cloudflare's edge and speaks
plain HTTP to the app, which is exactly what the `x_forwarded_proto` rewrite
expects. Pointing it at `HTTPS` aims the tunnel at a TLS listener that does not
exist.

The DNS record is created for you when the hostname is added to a zone
Cloudflare already manages, and nothing on the box needs restarting - the
tunnel picks the new route up on its own. The `PORT` in the unit and the port
in this mapping have to agree; if one moves, move both.

The tunnel token is not recorded in this repository, in the deploy script, or
anywhere else in version control, and must not be. It is worth knowing that it
is consequently visible in `cloudflared.service`'s `ExecStart` and in `ps`
output to anyone who can read them - a property of token-based tunnels rather
than a choice made here.

## Publishing to OpenResults

The other manual step, and the one people get wrong, because the configuration
is not symmetric.

**OpenResults** reads its bearer token from `OPENRESULTS_INGEST_TOKEN` in its
systemd unit, which the deploy script writes from its own `.env`.

**OpenPairings does not read that variable at all.** An arbiter types the
endpoint and the token into **Settings → the publishing card**, and they are
stored in that machine's own database
(`PairingsEngine.Publishing.put_endpoint/1` and `put_token/1`) - because a
laptop in a school gym has no systemd unit to put them in, and the same app
runs in both places.

**On a hosted install the deploy now does this for you.** Between migrating
and restarting it runs `mix pairings.publishing --ensure`, passing all three
values from the same `.env` it already reads:

| setting | from | on this host |
| --- | --- | --- |
| sends to | `DEPLOY_OPENRESULTS_PORT` (default 4004) | `http://localhost:4004` |
| spectators go | `DEPLOY_OPENRESULTS_PHX_HOST` | `https://openresults.zerotwo.cloud` |
| token | `DEPLOY_OPENRESULTS_INGEST_TOKEN` | (never echoed) |

The deploy uses **`--force`**, so the box is reconciled to this `.env` on
every run. That is the opposite of the task-s own default, deliberately: the
task refuses to overwrite because a general tool should not stamp over a
setting somebody chose on purpose, but this script deploys one known host and
its `.env` IS how that host is wired. A step that declined to apply its own
configuration every deploy would be a warning nobody reads.

**So change these values here, not on the Connections page** - an edit made
there is undone by the next deploy. The token is compared without ever being
printed.

An installation that has never configured publishing is therefore wired
correctly by its first deploy. Setting it by hand still works and is what a
laptop does, since it has no systemd unit and no deploy script:

- **Address** (sends to): `http://localhost:4004` on this host, or
  `https://openresults.zerotwo.cloud` anywhere else
- **Public address**: `https://openresults.zerotwo.cloud`, and **only**
  needed when the two differ - leave it blank and share links use the
  address above
- **token**: the same value as `OPENRESULTS_INGEST_TOKEN` on the server

The two addresses exist because one field was doing both jobs. On this host
both applications share a machine, and publishing still went out to
Cloudflare and back through the tunnel to reach a process one loopback hop
away - because the single address had to be the public one, since
`PairingsEngineWeb.PublicLink` builds every share link, QR code and printed
URL from it. Sending over loopback also means the two apps no longer need DNS
and a CDN to be up in order to talk to each other.

Both halves are required - `Publishing.configured?/0` returns false unless each
is a non-empty string, because an endpoint with no token would fail every send
with a 401, which is a worse experience than saying so up front. Publishing is
then per-tournament and opt-in, via that tournament's **Publish to
OpenResults** toggle.

With the token unset on the server, OpenResults still boots and still serves
every tournament already published - only publishing is refused, with a 401.
That is the right failure: the read side keeps working while the token is
sorted out.

## The deploy script's own `.env`

Separate from the app's `.env` and from anything on the server: a gitignored
file sitting next to `deploy_openpairings.py` on the maintainer's machine.
Anything absent is prompted for, or falls back to the default shown.

| Key | Applies to | Notes |
| --- | --- | --- |
| `DEPLOY_HOST` / `DEPLOY_PORT` / `DEPLOY_USER` | both | SSH connection |
| `DEPLOY_SSH_KEY` | both | path to the private key to authenticate with. The intended way in; with it set, nothing else is tried |
| `DEPLOY_ALLOW_PASSWORD` | both | set to `1` to permit password authentication, taken from `DEPLOY_PASSWORD` or prompted for. **Off by default**: the credential is the box's root password and it is replayable. `DEPLOY_PASSWORD` on its own does nothing but print a line saying so |
| `DEPLOY_PASSWORD` | both | only used when `DEPLOY_ALLOW_PASSWORD=1` |
| `DEPLOY_APP_PORT` | OpenPairings | default 4001 |
| `DEPLOY_PHX_HOST` | OpenPairings | `pairings.zerotwo.cloud` |
| `DEPLOY_SMTP_USERNAME` / `DEPLOY_SMTP_PASSWORD` | OpenPairings | only asked for when this app is in the run |
| `DEPLOY_ADMIN_EMAILS` | OpenPairings | comma-separated; who administers this installation. Unset means it has **no administrators** until `mix pairings.role` is run on the box &mdash; see "Granting the first administrator" |
| `DEPLOY_OPENRESULTS_PHX_HOST` / `DEPLOY_OPENRESULTS_PORT` / `DEPLOY_OPENRESULTS_INGEST_TOKEN` | both | also used to wire OpenPairings publishing on deploy - see "Publishing to OpenResults" |
| `DEPLOY_FIDE_LIST_URL` | OpenPairings | see above |
| `DEPLOY_KBSB_API_URL` / `DEPLOY_KBSB_API_KEY` | OpenPairings | see above |
| `DEPLOY_SSO_BLOCKED_REGISTRATION_DOMAIN` | OpenPairings | see above |
| `DEPLOY_NOTICE_TOKEN` / `DEPLOY_NOTICE_MINUTES` | OpenPairings | the pre-restart countdown |
| `DEPLOY_OPENRESULTS_PORT` | OpenResults | default 4004 |
| `DEPLOY_OPENRESULTS_PHX_HOST` | OpenResults | default `openresults.zerotwo.cloud` |
| `DEPLOY_OPENRESULTS_INGEST_TOKEN` | OpenResults | the publish bearer token; unset means every publish is refused |
| `DEPLOY_HEALTH_TIMEOUT` | both | seconds to wait for the app to answer after a restart, default 90 |

The script also **refuses an unknown SSH host key** rather than adding it: it
loads the system `known_hosts` and rejects anything not in it. A new target
therefore has to be connected to once by hand, which is the only moment at
which anyone actually looks at a fingerprint. (Before 2026-09-01 it accepted
any key and authenticated as root with a typed password, so a
network-position attacker was handed that password once per deploy.)

Everything here that ends up on the server travels in the systemd unit rather
than in a file on the box, because the deploy **rewrites that unit every run**:
anything the script generates is reproducible from your machine, while anything
hand-added to the unit gets wiped. Long-lived hand-managed values belong in a
drop-in instead (see `KEYCLOAK_*` above).

## Secrets

Nothing production-sensitive is committed to this repository:

- `.env` (SMTP credentials for local dev) is gitignored.
- The deploy script itself lives outside the repo and prompts for
  credentials interactively (or reads them from its own local, gitignored
  `.env` next to it) rather than storing them anywhere in version control.
- Both systemd units on the server are `chmod 600`, root-only -
  `pairingsengine.service` because it holds `SECRET_KEY_BASE` and the SMTP
  credentials, `openresults.service` because it holds a `SECRET_KEY_BASE` of
  its own and the ingest token.
- The two apps get **separate** `SECRET_KEY_BASE` values, each reused across
  its own redeploys. Neither can sign a cookie the other would trust, which is
  what it should mean that they share only a host.

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
