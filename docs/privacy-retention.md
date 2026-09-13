# Personal data and how long it is kept

OpenPairings holds one piece of personal data about people who did not sign
in to it: the email address an entrant typed into the OpenResults entry form.
The FIDE and KBSB rating-list mirrors are downloaded copies of public lists,
not data about this app's users, and are not listed. Account data (the email
and password hash of arbiters who sign in) exists only for as long as the
account does.

| Data | Where | Why | Kept in the live database | Longest it can survive, backups included |
| --- | --- | --- | --- | --- |
| Entrant's email address | `openresults_registrations.payload` → `player.email` (the only place; never copied to `players`, snapshots, TRF exports or public pages) | So the arbiter can contact the entrant about their entry (accepted, field full, schedule) | Until `PAIRINGS_REGISTRATION_RETENTION_DAYS` (default 30) days after the tournament's `end_date`, then cleared daily by `PairingsEngine.Registrations.Retention`. A tournament with no `end_date` keeps it until one is set or the tournament is deleted | Retention days + up to 1 day for the daily job + `BACKUP_RETENTION` (default 30) days: once removed from the live database, a value is gone from every backup written after it, and backups written before are pruned after at most `BACKUP_RETENTION` days (the single newest backup is always kept regardless of age) |
| Arbiter account email and password hash | `users` | Signing in | While the account exists | Account removal + `BACKUP_RETENTION` days, same rule |

Backups carry the same data as the live database; set
`PAIRINGS_BACKUP_PASSPHRASE` so they are encrypted (see `docs/deployment.md`,
"Backups"). A backup copied off the server - downloaded from Connections -
is outside these bounds and is the operator's to delete.
