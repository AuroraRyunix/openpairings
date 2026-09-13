# Restore drill, 2026-09-13

The 2026-09-05 audit said, in so many words, "No load test, no live probing,
no restore drill". Both apps had backups, and nobody had ever proven that
restoring one gives back a working system. This is that drill, run for
OpenPairings and OpenResults together, because the property that justifies
the backups existing - an arbiter can always withdraw a tournament they
published - only exists across the two. OpenResults' write-up is its own
`docs/restore-drill-2026-09-13.md`.

**Verdict for OpenPairings: yes, a restore gives back a working system** -
the restored database matched the original table for table, the app booted
on it, pages rendered, a result was entered, a round was paired, and **the
restored installation withdrew a tournament it had published before the
backup**. But the procedure an operator would have followed at 3am had no
page in `docs/` at all, and the four commands `mix pairings.backup --restore`
printed could put the old data back live without a word; a backup one
migration old booted and failed every tournament page; and a restore
silently undid takedowns on the results site. None of the backup code was
changed here (by instruction - another change to it was in flight); the
procedure is rewritten in `docs/deployment.md` ("Backups", "Restoring a
backup", "What a restore undoes", "Restoring on a desktop install") and was
re-run from that text. Everything that needs code is a recommendation below.

## How it was run

Local only, on a Windows 11 workstation (16 threads). No SSH, no deploy, no
connection to `pairings.zerotwo.cloud` or `openresults.zerotwo.cloud`.

- **Code**: this repo at `6a11122`, OpenResults at `65fb180`. `main` moved
  during the drill: `f618654` taught `PairingsEngine.Backup` to strip a desktop
  installation's results-site key, which does not change anything measured
  here.
- **Mode**: `MIX_ENV=prod`, `PHX_SERVER=true`, `mix phx.server`, exactly as
  `pairingsengine.service` runs it, on scratch databases; OpenResults beside it
  the same way. The nodes ran with loopback-only distribution so the drill
  could drive them; `systemctl stop` was reproduced by `init:stop/0` (what
  SIGTERM does to a BEAM) and a crash by killing the process.
- **Instance**, built through the app's own contexts - the functions the
  LiveView handlers call, audit rows included: three accounts (admin, owner,
  support) with passwords and live sessions; a published 16-player Swiss open
  with an entry form, a collaborator, a mobile enrolment, a forbidden pair,
  restore points and four and a half rounds of results; a second published
  event; a round robin; an archived, a binned and a handed-off tournament; one
  not yet published; three entries pulled from the results site (one accepted,
  one discarded); a publish queued with a failure while OpenResults was down;
  the publishing address and token, a site notice and the SWAR version string;
  five FIDE and three KBSB rows. At backup time: 7 tournaments, 55 players, 15
  rounds, 76 pairings, 131 audit rows, 11 restore points, 8 `meta` rows.
- **Backups** were taken by the scheduler: its five-minutes-after-boot run fired
  on time, and the reference backup was `Backup.Scheduler.run_now/0`, the call
  the 24-hour timer makes. The live database was fingerprinted table by table
  immediately before and after; only the publish queue's retry bookkeeping
  moved in between.
- **Then** the arbiters kept working: a tournament taken off the results site,
  another published for the first time, a new one created and published, a
  password changed, a role removed. Then somebody ran a `DELETE` on the wrong
  tournament ids - the open and the round robin, with everything that
  cascades from them - and the restore began.

## Timings

Local; the VPS's `mix` starts slower, so read these as proportions.

| Step | As documented before | As documented now |
| --- | --- | --- |
| find the procedure | nothing in `docs/`; the task's moduledoc and output | `docs/deployment.md` |
| `--list` | 2.3 s | 2.3 s |
| `--verify` | 2.2 s to "no such file" with the listed name, then 2.3 s | 2.4 s |
| `--restore` | 2.2 s | 2.2 s |
| page-by-page check of the recovered file | - | under 0.2 s |
| stop | ~1-2 s graceful | (the second run was a kill) |
| swap | 0.3 s, two `mv`s | 0.5 s, sidecars included |
| carry publishing forward + report | - | 0.6 s |
| `mix ecto.migrate` | - | 2.4 s, one `database is locked` line |
| start to listening | ~3 s, then two `database is locked` errors | 2.6 s, no errors |
| **total, mechanical** | **about 11 s** | **about 13 s** |

## What came back

The restored file, compared with the live database at the moment of the
backup, by row count and content digest per table: **identical on all 33
tables except the rating lists**, which were empty and present - `fide_players`,
`kbsb_players` and both FTS indexes with their shadow tables - with the whole
file passing `PRAGMA integrity_check`. 81 migrations recorded, the schema
(triggers included) identical. On it the app
booted; the arbiter and the administrator signed in with passwords over HTTP;
the tournament list, standings, pairings, players, entries, audit, history,
results-site settings, TRF export, admin and Connections pages rendered with
their rows; a result was entered, a round completed and the next one paired,
and standings computed; the queued publish went out, and the registration
poll pulled the entry sent after the backup.

**The property the backups exist for held**: with the key from the backup,
the restored installation took the open - published before the backup - off
the results site, and OpenResults answered 404.

## Findings, worst first

Nothing here was fixed in code: `backup.ex` and the export code were off
limits for this drill. "Documented" means the procedure now works around it.

### 1. The printed swap could put the old data back live, silently - DOCUMENTED; code recommended

`--restore` prints `mv live live.before-restore` and `mv restored live`. That
moves the database without its `-wal` and `-shm`. After a clean stop those do
not exist (measured). After a crash, an OOM kill, a stop that hits systemd's
timeout, or a `mix` task that exits without checkpointing, they do. Measured:
`mix ecto.migrate` on a fresh database left a **4,096-byte database and a
1,479,112-byte WAL** - all 81 migrations uncheckpointed. Restoring a backup
over that with the printed commands, and asking SQLite:

| What SQLite was given | `schema_migrations` | tournaments | `integrity_check` |
| --- | --- | --- | --- |
| the restored file alone | 80 | 1 | ok |
| **the restored file + the `-wal`/`-shm` the `mv` left behind** | **81** | **0** | **ok** |
| the `before-restore` copy the output says to keep | no tables at all | | |

The app would have served the pre-restore database, and the next checkpoint
would have written it over the restored file for good. The copy kept "until
you are sure" held nothing. SQLite pairs a database with whatever `-wal`
carries its name and cannot tell it belongs to another file. On OpenResults'
data the same thing produced a mixture of the two databases, also passing the
integrity check.

Documented: step 5 renames all three files together
(`pairings_engine.db.before-restore-<stamp>`, `...-wal`, `...-shm`, which
still open as one database). Re-run after killing the node mid-write: the rows
that existed only in the old WAL were in the `before-restore` copy and not in
the restored database.

Recommended: make `Mix.Tasks.Pairings.Backup` print that swap (OpenResults'
task now does, with a test), and correct its moduledoc, which promises "three
commands" and prints four.

### 2. A restore undoes takedowns on the results site - DOCUMENTED; code recommended

A tournament taken down after the backup still has its key, its address and
`publish_to_openresults` in the restored database. The takedown had released
the claim on the results site, so the next change to the tournament publishes
it again and claims the address afresh. Measured: after the restore, pairing
the next round of the event withdrawn after the backup put it back online -
**404 before, 200 after**. The arbiter is not told. For a tournament withdrawn
over personal data, that is the whole of the harm the takedown existed to
undo. "Move to a new address" has the same shape, and would revive the old,
revoked link.

Documented: step 6 takes each tournament's publishing state (address, key,
switch) from the database the restore replaced, before the app starts, and
drops queued publishes for tournaments that are no longer publishing. Tested
on the drill's databases: exactly the two affected tournaments changed.

Recommended: this should not depend on the old file surviving. Options: the
restore task could carry publishing state forward itself when the live
database is readable; or, on boot after a restore, ask the results site
whether each key still holds its address before republishing anything.

### 3. Tournaments published after the backup become unmanageable - DOCUMENTED; code recommended

- **First published after the backup**: the restored row has no key. Turning
  publishing back on mints a new one, and every update is refused with "the
  results site says a different machine published this tournament (403)" -
  measured, and wrong about the machine: it was this one, before the restore.
- **Created and published after the backup**: the tournament is gone from
  here, and its public page is not - nothing on this installation can remove
  it. Only the OpenResults operator token (break-glass) can.

Documented: step 6 copies the key back when the old database survives; the
report lists what it cannot fix. Recommended: when the results site answers
`key_mismatch` for a tournament that has never had a key here, say that a
restore is the likely cause and what the operator can do.

### 4. A backup older than the code boots and fails every tournament page - DOCUMENTED

The service runs `mix phx.server`, which skips migrations (only a release runs
them at boot), and the restore instructions never said to migrate. A backup
one migration behind, restored as instructed: the app booted and answered
`/` with 302 and the login page with 200 - a health check would have passed -
and every tournament query failed with `no such column:
t0.standings_through`. After `mix ecto.migrate`: all 81 up, tournaments
listed, no errors. Step 7.

### 5. There was no restore procedure - FIXED (docs)

Nothing in `docs/` said how to restore: the four printed commands, a CHANGELOG
entry and the task's moduledoc were all of it. Nothing said which user to run
the task as, what environment it needs (`config/runtime.exs` refuses to load
without `DATABASE_PATH` and `SECRET_KEY_BASE`, and demands SMTP credentials if
`PHX_SERVER` is set), or where the hand-installed backup wrapper this guide
mentions under "Granting the first administrator" lives and what user it runs
as. A recovered file
written by root and moved into place is root's; SQLite opens a file it cannot
write read-only, so the app would load pages and save nothing - from the
unit's `User=` and SQLite's documented fallback, not reproduced on Windows.
Step 1 and step 5's `chown` cover it.

### 6. An unencrypted backup is a key ring - RECOMMENDED

The deploy script sets no `PAIRINGS_BACKUP_PASSPHRASE`, so production backups
are plain. Inspected, the drill's backup held: player email addresses, every
published tournament's key, every account's password hash and session tokens,
the publishing address - and **`openresults_token`, the OpenResults operator
token**, which can overwrite or delete any tournament on the results site.
Connections hands this file to any administrator who asks. The moduledocs warn
about the emails and the tournament keys and not the token.

Recommended: strip `openresults_token` from the staging copy the way the
installation key now is - the deploy re-applies it on every run
(`mix pairings.publishing --ensure --force`) - and set the passphrase in a
drop-in on the VPS.

### 7. `verify/1` does not read the pages - DOCUMENTED; code recommended

A correct envelope around a database with a damaged `pairings` or
`audit_logs` page verified, restored, and failed `PRAGMA integrity_check`.
Every damaged envelope (truncated, tail cut, a flipped bit, a zeroed block, a
damaged header, no header, garbage inside) was refused before anything was
written - that promise holds - but a damaged database inside a good envelope
is exactly a backup of a database with a bad page. Step 3 runs the integrity
check. Recommended: `verify/1` should, as OpenResults' now does. Its error for
a malformed file also reads `<<109, 97, 108, 102, ...>>` rather than words.

### 8. On Windows, every `verify/1` leaves a decrypted copy of the database in `%TEMP%` - RECOMMENDED

`tables/1` and `scalar/2` never release their prepared statements, and SQLite
defers the close of a connection with live statements until they are
finalised - so the staging file is still open when `File.rm/1` runs, and on
Windows the delete fails. A refusal after the file opened never closes the
connection at all. Measured: 5 verifies, 5 copies left; this workstation's
`%TEMP%` held **977 `opbak-verify-*.db` files, 303 MB**, from test runs since
2026-09-10. For an encrypted backup each copy is the plaintext, emails, keys,
token and all; a desktop restore through the release's `eval` leaves one too.
On Linux the unlink succeeds and only the handle leaks until collection.
OpenResults' identical code is fixed (release every statement, close on every
path); the same few lines fix this one.

### 9. `BACKUP_RETENTION` of 0 or less deletes the newest backups - RECOMMENDED

`prune/1` is `Enum.drop(list, keep)`, and `config/runtime.exs` accepts any
integer. With 0 the scheduler writes a backup and deletes it, with every
other one (measured: 35 backups to none). With -1 it deleted the four newest
and kept the oldest. The promise that the newest is never pruned holds for a
count of 1 or more. Recommended: never keep fewer than one, and refuse the
value at boot - OpenResults does both now.

### 10. "A month of retention" is thirty files - RECOMMENDED

Every boot writes one five minutes in, and every "take one now" another. A
week with a few deploys a day is a week of backups, not a month. And a backup
copied into `backups/` to restore from, older than thirty others, was deleted
by the next prune (measured) - five minutes after the next boot. Documented.
Recommended: skip the boot-time run when the newest backup is younger than
the interval.

### 11. The first boot after a restore logs `database is locked` - DOCUMENTED

`VACUUM INTO` writes a rollback-journal database. The boot that meets it has
five pooled connections all trying to switch it to WAL - the race
`PairingsEngine.Application`'s own comments describe for a fresh install, which
releases avoid by migrating on one connection first and `mix phx.server`
skips. Measured: two `[error] ... database is locked` lines at boot,
self-healing. With step 7 the migrator takes the switch instead (one line,
harmless) and the boot is clean. Recommended: `restore/1` should switch the
recovered file to WAL itself, as OpenResults' now does.

### 12. A restore revives passwords, roles and sessions - DOCUMENTED

Measured: the password the arbiter changed after the backup was the old one
again (the arbiter signed in with it); the support role removed after the
backup was back; the session token that password change deleted was back in
the database, so a browser still holding its cookie is signed in again (same
`SECRET_KEY_BASE`). Revoked mobile enrolments follow the same rule.
Step 6's report lists the accounts; "What a restore undoes" says what to
re-apply.

### 13. What travels that is bound to the machine - REPORT

In the backup, and restored wherever the file is restored:

- `openresults_endpoint` - `http://localhost:4004` on this host, loopback, so
  wrong on any machine without OpenResults beside it;
- `openresults_token` - see 6; a restore also undoes a token rotation;
- `fide_last_sync` / `kbsb_last_sync` - the sync dates stay while the tables
  are emptied, so Connections would show the last sync's date beside "0
  players" (read from `FideLive`; the drill never synced);
- `bel_swar_pseudo_mac` - one per installation by design; restored onto a
  second machine while the first lives, two installations share it;
- hand-off tokens, session tokens (dead with a different `SECRET_KEY_BASE`),
  mobile enrolments;
- the per-installation results-site key of a desktop copy in public mode is
  now stripped (`main`, `f618654`), so it never travels - and a restore onto
  the same machine loses it too; that machine registers again and the
  operator transfers its tournaments. That is the design as written in
  `PairingsEngine.Backup`, recorded here because a same-machine restore could
  instead carry the live database's key rows forward, as step 6 does for
  tournament keys.

### 14. A desktop install cannot restore its own backups - DOCUMENTED; code recommended

A desktop copy writes backups beside its database, and `Backup.restore/1` is
reachable only from `mix pairings.backup`, which a desktop copy does not
have. Tested: the portable release's `eval` works - with the call in a file,
because the `.bat` launcher passes its arguments through `cmd`, which eats
parentheses and pipes. "Restoring on a desktop install" gives the steps.
Recommended: a restore an arbiter can reach without a terminal.

### 15. `--list` prints names `--verify` and `--restore` cannot find - DOCUMENTED

Typed back as listed: "no such file". The guide gives full paths; OpenResults'
task now resolves listed names.

### Aside

`mix pairings.publishing` (like any task that only loads config) logs SQL at
debug level when run by hand, and the `INSERT INTO meta` line carries the
token in clear. The deploy script redacts its output; a person at a shell does
not.

## Tests added

`test/pairings_engine/backup_restore_test.exs`, 3 tests - each a promise the
module makes that had no test against the app itself:

- the restored file matches its source table for table, with the rating lists
  present and empty;
- the app's own Repo, started on the restored file, sees every migration
  `:up` through `Ecto.Migrator` - the "emptied, not dropped, so
  `schema_migrations` still matches" promise asked the way a boot asks it -
  and reads the tournament, a usable publishing key and its results;
- seven kinds of refused file (truncated, tail cut, flipped bit, damaged
  header, not a database inside, an OpenResults backup, empty) are refused by
  both `verify/1` and `restore/1` with nothing written beside the live
  database.

The tests stage in their own temp directory, so they do not add to finding 8
while it is open. Every `bash` block of the new guide sections was also run
verbatim against a mock unit file and drop-in, an unclean stop's sidecars,
and the drill's real before/after databases.

## The corrected procedure

It is `docs/deployment.md`, "Restoring a backup". In one breath: load the
unit's environment into a root shell and run `mix` as the service account;
verify with a full path; recover beside the live file and run the integrity
check on it; stop and confirm; rename the database **with** its `-wal` and
`-shm`; restore ownership; carry publishing state forward from the replaced
database and read the report; `mix ecto.migrate`; start and check for a 302;
then sync the rating lists, check the publishing connection, and re-apply
what the report listed.
