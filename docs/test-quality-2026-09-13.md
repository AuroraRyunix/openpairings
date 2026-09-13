# Test quality, 2026-09-13

The 2026-09-05 audit listed "whether tests assert the right things" among the
areas no audit dimension had covered. A green suite proves the tests pass, not
that they would notice the bug that matters. This pass asked that question
three ways, and chased the one flaky test nobody had named.

The same pass was run on OpenResults; its report is
`openresults/docs/test-quality-2026-09-13.md`.

## Summary

| | result |
|---|---|
| the flaky test | **found and fixed.** Not one test but a class: users committed to the local test database by `MIX_ENV=test mix run` probes on 2026-09-04, colliding with fixture e-mail addresses built from `System.unique_integer/0`. Two recorded failures traced to it, a third reproduced here. Fix: `ec9e81a`. |
| full-suite runs | 27 (1 clean baseline, 10 on a copy of the main checkout's test database before the fix, 16 on the same copy after it), plus the `mix precommit` run |
| mutation sampling | 68 hand-made mutants. 58 caught by the tests nearest the code, 4 caught elsewhere in the suite, **6 survived the whole suite**. Each survivor now has a test that kills it (`c2702ba`), re-checked by re-running the mutant. |
| weak assertions | 6 tests confirmed weak by breaking the code and watching them stay green, all strengthened (`c2702ba`, `ad83ed5`); more listed below |
| excluded tests | **111 tests never run in CI** (51 `:swar_fixture`, 61 `:javafo`, one test carries both). They run only where the fixtures and the jar exist: the maintainer's machine. Proposal below. |
| test infrastructure | the skip count CI prints undercounted `:swar_fixture` by 10 (`ad83ed5`); the SWAR fixture gate missed `test3-321.swar` (`88c86c2`) |
| production code | **unchanged. No production bug found.** Every survivor was a missing test for behaviour that is correct today, so there is no CHANGELOG entry. |
| test count | 3,903 before (3,899 tests, 4 properties), 3,912 after (3,908 tests, 4 properties) |

Commits, on the worktree branch: `ec9e81a`, `c2702ba`, `ad83ed5`, `88c86c2`,
and this document.

## 1. The flaky test

### What was seen

Two failures were on record, both in `mix precommit` runs in the main checkout,
both passing on the next run:

- **2026-09-10, 23:22 local**, seed 466590, during the "2022 is really 2017"
  documentation fix. The log survived:
  `MobileEnrollControllerTest` "one device per code: a second submit of the
  same code is refused and does not get a session" failed with
  `** (MatchError) {:error, #Ecto.Changeset<... email: "has already been taken" ...>}`
  for `user-576460752303410874@example.com`, raised inside
  `AccountsFixtures.user_scope_fixture/0`. It passed in isolation and on a full
  re-run. Nobody looked further.
- **2026-09-11, 19:10 UTC**, the commit pinning Ainalrami v0.26.1. One failure
  in 3,641; `mix test --failed` passed it in 0.2 s of async time; a full
  re-run (seed 104000) passed. The output had been cut to its last three
  lines, so the test's name was lost. What survives fits the same class: an
  `async: true` module, and a test that passes in a fresh VM.

### Root cause

The main checkout's `pairings_engine_test.db` held rows that no test had
written, because no test commits:

| table | rows | written |
|---|---|---|
| `users` | 5, e-mails `user-576460752303410874@...`, `...411323`, `...410747`, `...410553`, `...418108` | 2026-09-04 19:14 to 20:22 |
| `tournaments` | 5, named "Probe", "Probe", "Footer check", "Footer check", "F" | same times |
| `meta` | `bel_swar_pseudo_mac` | same session |

They came from ad-hoc probes run that evening, for example
`MIX_ENV=test mix run test/tmp_guid_probe.exs`, which called
`user_scope_fixture/0` and `Tournaments.create_tournament/2` against the test
database with no SQL Sandbox around them, so every write committed.

That alone would be harmless. The collision needs the second half:
`AccountsFixtures.unique_user_email/0` is `"user#{System.unique_integer()}@example.com"`,
and `System.unique_integer/0` is unique **within one VM only**. Each boot
starts its counters from the same base, per scheduler thread, so the same
addresses come round again in every run. Whichever test happens to draw one of
the five leftover addresses gets `{:error, changeset}` from the fixture's
`{:ok, user} =` match and fails. Which test that is depends on the test order
(the seed) and on which scheduler ran the fixture, which is why a different
test failed each time and no re-run, not even with the same seed, reproduced
it. All three failures seen were in `async: true` modules, which run first,
while the counters are still low; that is the likely reason, not a proven one.

CI never saw it: every CI run starts from a fresh database.

The same exposure exists for every fixture that takes a unique column from
`System.unique_integer/0` (public slugs, Keycloak subjects, invite e-mails), and
for any test that assumes an empty table.

### Hunting it

The 2026-09-10 log named the address, and the address was in the main
checkout's database. To see the failure happen rather than infer it, the suite
was run on a copy of that database, with random seeds:

| run | seed | database | result |
|---|---|---|---|
| baseline | (random) | clean worktree database | 3,903 passed |
| 1-6 | 363280, 148620, 229978, 168629, 595328, 443109 | main checkout's copy | passed |
| 7 | 793413 | main checkout's copy | **1 failed**: `MobileTest` "level and board range on create_enrollment/2 refuses a non-positive board bound", same `MatchError`, same address `user-576460752303410874@example.com` |
| 8-10 | 793413 again, three times | main checkout's copy | passed |

Runs 8-10 are the flake in miniature: the seed fixes the order, not the
scheduler.

A deterministic reproduction needs more leftovers. With 400,000 committed
users covering the low `System.unique_integer/0` range, `mix test
test/pairings_engine/mobile_test.exs --seed 793413` fails 20 of 35 tests, every
one with the same `MatchError`.

Also read for, and not found: `async: true` modules touching shared state (the
suite runs with `max_cases: 1`, and every file that calls
`Application.put_env/3` restores it in `on_exit`); wall-clock dependence (the
`compute_published_at/2` tests allow a two-second window, the date-sensitive
code takes explicit dates); `Process.sleep` waits (the `Tools.Session` ones
can only make a correct implementation pass, never fail it); ordering without
`ORDER BY` in assertions; port use (the endpoint does not listen in test).

### Fix

`test/support/leftover_rows.ex`, called from `test/test_helper.exs` while the
Sandbox is still in its automatic mode: it counts the rows in every ordinary
table and deletes them, leaving `schema_migrations`, SQLite's own tables and
the FTS5 virtual and shadow tables alone (the content tables' triggers keep the
indexes in step). Foreign keys are deferred to commit, so tables can be emptied
in any order. When it finds anything it says so:

```
Cleared rows committed to the test database outside the SQL Sandbox: users (5), tournaments (5), meta (1). See PairingsEngine.Test.LeftoverRows.
```

Removing the dependence on the database's history fixes the whole class,
rather than making one fixture's addresses unique across boots and leaving the
slugs, subjects and empty-table assumptions exposed. Three tests in
`test/pairings_engine/leftover_rows_test.exs` pin what is cleared and what is
kept.

### Proof

- The 400,000-row database: the same command now passes 38 of 38, three runs in
  a row (35 `MobileTest` plus the three new tests).
- The main checkout's database, **restored before every run**: 16 full runs,
  all green, each printing the line above. Seeds 793413 (run 7's), 466590 (the
  2026-09-10 failure's), 272260 (the 2026-09-11 `--failed` run's), 137843, 338467,
  469851, 597133, 874710, 928267, 647913, 105665, 277850, 711664, 247544,
  788631 and 979315.

Before the fix: 1 failure in 10 runs on that database. After it: 0 in 16.

The main checkout's database still holds the five rows. The first `mix test`
there after this branch is merged clears them and says so.

## 2. Mutation sampling

### Method

No mutation-testing dependency. A small script applied one mutation at a time
to the worktree, ran the test files nearest the code, and if they stayed green
ran the whole suite; the file's original bytes were written back in a
`finally`, and `git diff` checked clean after every mutant. Nothing mutated was
committed: every commit in this pass touches `test/` and `docs/` only.

Areas, as the brief set them: applying pairings and results; standings and
tiebreaks; the publishing cursors and cascades; snapshot withholding;
authorization (collaborators, roles, `Authz`); the public-mode decision; TRF
import and export. Backup code was left out. `publishing.ex` was mutated only in
`mode/0` and `public_mode?/0`, never in `take_down` or `retract`.

"Caught, outside the targeted files" means the suite noticed, but not in the
files next to the code:

- A5 (the Admin page gated on the support predicate) is caught by
  `AdminAccessTest`, which is the right place; it just was not in the targeted
  list.
- PM2 (`mode/0` honouring an operator token only in local mode) was caught
  only incidentally, by `RegistrationPollTest`. The test that names the rule,
  "an operator token makes it operator mode, local or not", never tried "not".
  It does now (`c2702ba`), and PM2 fails it directly.
- ST8 (tie order falling back to lowest rating first) and PA2 (unpairing a
  round that is not the latest) are caught by LiveView tests that happen to
  depend on them. Both are real, if indirect.

### Results

| | mutants |
|---|---|
| caught by the targeted tests | 58 |
| caught, outside the targeted files | 4 |
| **survived the whole suite** | **6** |
| total | 68 |

| # | area / file | mutation | verdict | caught by / fix |
|---|---|---|---|---|
| A1 | `authz.ex` | may_administer?/1 forgets ADMIN_EMAILS | caught | `AuthzTest`: an address the deployment declares declaring writes nothing, so a demotion is not undone by a restart |
| A2 | `authz.ex` | may_support?/1 reads the role column only | caught | `AuthzTest`: an address the deployment declares and may look, which the role alone would not have given them |
| A3 | `authz.ex` | declared admin emails compared case-sensitively | caught | `AuthzTest`: an address the deployment declares matched without regard to case |
| A4 | `user.ex` | support role counts as admin | caught | `AuthzTest`: a hosted installation support may look and nothing else |
| A5 | `require_role.ex` | the Admin page gated on may_support? instead of may_administer? | caught, outside the targeted files | `AdminAccessTest`: support but not Admin, and is not offered it |
| C1 | `tournaments.ex` | a pending (unaccepted) invite grants access | caught | `TournamentsTest`: collaborators (tournament sharing by email - invite, must be accepted) a pending invite grants no access - only the owner can reach the tournament until it's accepted |
| C2 | `tournaments.ex` | authorized query forgets deleted_at (binned tournament reachable) | caught | `TournamentsTest`: recycle bin (soft delete, 3-month retention) a binned tournament is not viewable through the normal fetch paths, but shows up in list_deleted_tournaments/1 |
| C3 | `tournaments.ex` | a collaborator may invite others (owner check dropped) | caught | `TournamentsTest`: collaborators (tournament sharing by email - invite, must be accepted) add_collaborator/3 is owner-only |
| C4 | `tournaments.ex` | remove_collaborator looks the row up without its tournament (IDOR) | **survived** | new test `TournamentsTest`: remove_collaborator/3 refuses a collaborator id that belongs to another tournament (c2702ba); mutant now fails |
| C5 | `tournaments.ex` | a collaborator may remove collaborators (owner check dropped) | caught | `TournamentsTest`: collaborators (tournament sharing by email - invite, must be accepted) remove_collaborator/3 removes a collaborator (pending or accepted) and is owner-only |
| C6 | `tournaments.ex` | get_user_tournament!/2 stops checking the owner | caught | `TournamentsTest`: collaborators (tournament sharing by email - invite, must be accepted) get_user_tournament!/2 stays owner-only - an (even accepted) collaborator does not satisfy it |
| PM1 | `publishing.ex` | public_mode? true on a hosted box without a token | caught | `PublicPublishingTest`: which mode applies hosted mode has no default and never enters public mode |
| PM2 | `publishing.ex` | mode/0 only honours an operator token in local mode | caught, outside the targeted files | `RegistrationPollTest`: which tournaments get polled one that has published and is taking entries |
| PM3 | `installation.ex` | register/0 no longer refuses outside public mode | caught | `PublicPublishingTest`: which mode applies hosted mode has no default and never enters public mode |
| PM4 | `installation.ex` | register/0 no longer requires consent | caught | `PublicPublishingTest`: never re-registered silently after installation_revoked, nothing registers until the arbiter agrees again |
| PM5 | `publishing.ex` | public_mode? ignores an operator token | caught | `PublicPublishingTest`: a slug belongs to the server that minted it a tournament published with an operator token is not bound to a server |
| P1 | `tournaments.ex` | round_published?: a future published_at counts, a past one does not | caught | `SnapshotTest`: board numbers the hall would recognise an ordinary board's label is just its number |
| P2 | `tournaments.ex` | standings_through_round drops the completeness half | caught | `TournamentsTest`: standings_through_round/1 a published round with no results yet does not count until complete |
| P3 | `tournaments.ex` | publish_pairings_through leaves round N itself unpublished | caught | `TournamentsTest`: publish_pairings_through/2 - rule 1 publishes rounds 1..N, filling a gap manual publishing left held back below N |
| P4 | `tournaments.ex` | unpublish_pairings_through leaves round N public | caught | `TournamentsTest`: unpublish_pairings_through/2 - rule 4 hides round N and every round above it, leaving 1..N-1 public |
| P5 | `tournaments.ex` | unpublish_pairings_through caps standings one round too high | caught | `TournamentsTest`: unpublish_pairings_through/2 - rule 4 lowers standings_through to at most N - 1 |
| P6 | `tournaments.ex` | unpublish_standings_through cascade misses round N+1 | caught | `TournamentsTest`: unpublish_standings_through/2 - rule 3 round N > 0: drops standings to N - 1 and hides pairings above N, leaving 1..N public |
| P7 | `tournaments.ex` | unpublishing the entry list leaves 0 instead of nil (roster stays public) | caught | `TournamentsTest`: unpublish_standings_through/2 - rule 3 round 0: withholds the roster (nil) and hides any already-published round |
| P8 | `tournaments.ex` | standings publishable while the round's pairings are not public | caught | `TournamentsTest`: publish_standings_through/2 - rule 2 (and rules 5, 6, 7) refuses :pairings_not_public when the round is complete but its pairings aren't public |
| P9 | `tournaments.ex` | standings publishable for an incomplete round | caught | `TournamentsTest`: publish_standings_through/2 - rule 2 (and rules 5, 6, 7) refuses :round_not_complete when the round is published but missing a result |
| P10 | `tournaments.ex` | a published sheet implies standings after N instead of N-1 | caught | `SnapshotTest`: effective standings through the snapshot (2026-09-11 publish model) rule 1: round 2's own pairings being public floors standings at round 1, with no explicit standings publish |
| P11 | `tournaments.ex` | effective standings no longer capped at published-and-complete | caught | `TournamentsTest`: effective_standings_through/1 - the formula rule 7 safety cap: an explicit standings_through higher than the complete prefix is capped |
| P12 | `tournaments.ex` | round 0 standings always public | caught | `TournamentsTest`: standings_public?/2 - round 0's degenerate case round 0 reads NOT public when standings_through is nil and nothing is published |
| S1 | `snapshot.ex` | unpublished rounds travel | caught | `SnapshotTest`: build/1 - the security boundary an unpublished round is absent from the payload, not flagged in it |
| S2 | `snapshot.ex` | the roster is never withheld | caught | `SnapshotTest`: standings_through - withholding the roster before round 1 withheld when standings_through is nil and no round has published yet |
| S3 | `snapshot.ex` | hidden boards travel | caught | `SnapshotTest`: build/1 - the security boundary a hidden board is absent from boards, players and results alike |
| S4 | `snapshot.ex` | a player's email is published | caught | `SnapshotTest`: board numbers the hall would recognise an ordinary board's label is just its number |
| S5 | `snapshot.ex` | after_round from the cap instead of the effective (published) standings | caught | `SnapshotTest`: effective standings through the snapshot (2026-09-11 publish model) rule 1: round 2's own pairings being public floors standings at round 1, with no explicit standings publish |
| S6 | `snapshot.ex` | standings computed over every result, not through after_round | **survived** | new test `SnapshotTest`: the rows are the standings after that round, not the latest results under its label (c2702ba); mutant now fails |
| S7 | `snapshot.ex` | hidden tiebreak codes travel | caught | `SnapshotTest`: hiding individual tie-breaks a hidden code leaves the document entirely, values and all |
| S8 | `snapshot.ex` | tiebreak working travels although the arbiter switched it off | caught | `SnapshotTest`: hiding individual tie-breaks turning the working off keeps the columns |
| ST1 | `standings.ex` | through_round horizon off by one (in-memory filter) | caught | `StandingsTest`: player_scores_before_round/2 round 2 reflects round 1's results, not round 2's own (already-entered) ones |
| ST2 | `standings.ex` | SB uses raw opponent points, not the Art. 16 adjusted score | caught | `TiebreakWorkingTest`: the working totals what the standings published a player who withdrew mid-event |
| ST3 | `standings.ex` | WIN counts only rounds worth more than a win | caught | `TiebreakWorkingTest`: the working totals what the standings published a player who withdrew mid-event |
| ST4 | `standings.ex` | Koya excludes opponents on exactly 50% | caught | `TiebreakWorkingTest`: the working totals what the standings published a requested bye and an absence |
| ST5 | `standings.ex` | withdrawn opponent's missing trailing rounds not counted as draws | caught | `StandingsTest`: regression: withdrawn opponent's missing trailing rounds and DE grouping key BH counts a withdrawn opponent's missing trailing rounds as draws (Article 16.3) |
| ST6 | `standings.ex` | dummy opponent score uncapped (Art. 16.4.2) | caught | `TiebreakWorkingTest`: the working totals what the standings published an odd field, so somebody gets a pairing-allocated bye |
| ST7 | `standings.ex` | a round counts as completed when ANY board reported | caught | `StandingsTest`: a round still being played does not move anybody's tiebreaks Koya's 50% threshold does not move when one board reports |
| ST8 | `standings.ex` | final fallback order: lowest rating first | caught, outside the targeted files | `PlayersLiveTest`: the Cat column: several categories per player filtering to one category hides the rest and says so |
| ST9 | `standings.ex` | WON counts forfeit wins | caught | `TiebreakWorkingTest`: the working totals what the standings published forfeits and a played 0-0 |
| ST10 | `standings.ex` | BPG counts unplayed black rounds | caught | `TiebreakWorkingTest`: the working totals what the standings published forfeits and a played 0-0 |
| PA1 | `pairing.ex` | next round paired while the previous one has missing results | **survived** | new test `PairingTest`: pair_next_round/1 refuses the next round while the last one still has a missing result (c2702ba); mutant now fails |
| PA2 | `pairing.ex` | any round (not only the latest) can be unpaired | caught, outside the targeted files | `PairingsLiveTest`: snapshots are captured before the irreversible actions a failed action still leaves its snapshot behind, and that's fine |
| PA3 | `pairing.ex` | round_complete? never sees a missing result | caught | `TournamentsTest`: vacancies (mark absent on the board, refill from the pool) a vacated player joins the pool as absent and blocks the round from completing |
| PA4 | `pairing.ex` | late entrants (start_round) handed to the engine | caught | `PairingTest`: pair_next_round/1 leaves a late entrant out of the round entirely, with no bye row |
| PA5 | `tournaments.ex` | a result can be entered on an archived / handed-off tournament | caught | `HandoffTest`: writes are refused while handed off update_pairing_result/2 - the write that would actually diverge |
| PA6 | `pairing.ex` | any result string accepted | caught | `TournamentsTest`: update_pairing_result/2 rejects a result string that isn't in the recognized set |
| PA7 | `pairing.ex` | the last round cannot be paired | caught | `PairingEngineTest`: differential: Ainalrami vs JaVaFo on the same tournament they agree on an odd field, where a bye is allocated every round |
| TX1 | `trf_export.ex` | 142 carries the rounds in the file, not the event length | caught | `TrfExportRoundDatesTest`: a roster taken before any pairing still exports |
| TX2 | `trf_export.ex` | a FIDE id range that only partly covers the rounds is used | caught | `TrfExportTest`: applicable_fide_id/2 falls back to the tournament-wide ID when the exported rounds only partially overlap a range |
| TX3 | `trf_export.ex` | future byes appended to a partial export | **survived** | new test `Trf26RoundTripTest`: a slice of the tournament carries no future bye (the bye now granted for an unpaired round) (c2702ba); mutant now fails |
| TX4 | `trf_export.ex` | a future half-point bye exported as zero | caught | `Trf26RoundTripTest`: the older spelling carries the same bye as a column an engine reads |
| TX5 | `trf_export.ex` | 299 extra points exported even when the tournament does not count them | caught | `Trf26RoundTripTest`: extra points the tournament does not count stay out of the file |
| TX6 | `trf_export.ex` | a JaVaFo tournament labelled with the 2026 rules | caught | `Trf26RoundTripTest`: which edition of the rules paired the boards survives |
| TX7 | `trf_export.ex` | unrated players counted as rated | caught | `TrfExportTest`: 072 (number of rated players) counts only players with a fide_rating > 0 |
| TX8 | `trf_export.ex` | round 0 accepted in a rounds spec | caught | `TrfExportTest`: parse_rounds/2 clamps out-of-range tokens to 1..max_round |
| TI1 | `trf_import.ex` | an asymmetric half-zero imported as a draw | caught | `TrfImportTest`: forfeits and every TRF bye code import to the right pairing/bye rows |
| TI2 | `trf_import.ex` | non-mutual opponent entries accepted as a game | **survived** | new test `TrfImportTest`: a game is a game only when both entries name each other (c2702ba); mutant now fails |
| TI3 | `trf_import.ex` | duplicate starting ranks only refused when tripled | caught | `TrfImportTest`: a TRF file with two players sharing the same starting rank is a friendly error, not a silent orphan |
| TI4 | `trf_import.ex` | a half-point bye imported as a zero-point bye | caught | `TrfImportTest`: every result code the engine accepts is bucketed by the value it stands for |
| TI5 | `trf_import.ex` | two tournaments joined end to end accepted | caught | `TrfImportDoubledTest`: one file that contains the document twice is refused, and says which ranks collided |
| TI6 | `trf_import.ex` | byes numbered before real boards | **survived** | new test `TrfImportTest`: an imported round numbers its real boards first and the pairing-allocated bye last (c2702ba); mutant now fails |
| TI7 | `trf_import.ex` | colours swapped when the entry says white | caught | `TrfImportTest`: a result the file records as not known an ordinary result in the same file is untouched |

### The six survivors

Each is behaviour that is correct today and that no test would have defended.

1. **C4 - a collaborator row found by id alone.** `remove_collaborator/3`
   looks the row up by `id` *and* `tournament_id`. Drop the second and an owner
   of one tournament can delete a collaborator from anybody else's by sending
   that id in a page event. Nothing checked it. New test: the owner of `mine`
   removing `theirs`' collaborator gets `:not_found`, and the row stays.
2. **S6 - snapshot standings computed past `after_round`.** The snapshot's
   `standings.after_round` said "after round 1" while the rows could carry
   round 2's results, as long as round 2 was complete and its sheet public. The
   existing test checked the label, never the rows. New test on the two-player
   floor fixture: after round 1 the points are 1 and 0, not 1 and 1.
3. **PA1 - pairing over a missing result.** Delete the "Round N still has
   missing results" guard from `pair_next_round/1` and the whole suite passes.
   New test: one board open refuses round 2 with that message and pairs
   nothing; entering the result allows it.
4. **TX3 - future byes in a partial TRF export.** A test existed and could not
   fail: it granted the bye for round 2, which the test had just played, so
   there was no future bye to leak. The bye is now for round 3, and the test
   first proves the full export carries it.
5. **TI2 - a one-sided TRF reference imported as a game.** The parser lets a
   non-mutual opponent reference through, since it may be reading a partial
   roster; the importer must not pair on it. Without the mutual check one
   player was seated twice in a round. New test with exactly that file.
6. **TI6 - an imported bye numbered first.** The convention (shared with the
   SWAR importer) is real boards first, the pairing-allocated bye last. New test
   where rank 1 holds the bye.

## 3. Tests that never run, or assert nothing

### Excluded tests, and CI

**CI does not run them.** `.github/workflows/elixir.yml` sets
`SKIP_MISSING_ARTIFACTS: swar_fixture,javafo`, and the runner has neither the
gitignored SWAR fixtures nor `priv/javafo/javafo.jar`, so `test_helper.exs`
excludes them with a warning annotation. Counted with
`mix test --dry-run --only TAG`:

| tag | tests | files | what goes unguarded in CI |
|---|---|---|---|
| `:swar_fixture` | 51 | `swar_import_test.exs` 38, `tournaments_live_test.exs` 10, `federation_features_gating_test.exs` 2, `trf_export_test.exs` 1 | the whole SWAR import path against real files: 3-2-1 scoring, presence points, unresolved FIDE ids, the upload journeys |
| `:javafo` | 61 | `pairing_test.exs` 26, `mobile_results_live_test.exs` 9, `pairing_engine_test.exs` 5, `pairing_explain_live_test.exs` 4, 10 more files | pairing with JaVaFo, and the Ainalrami-against-JaVaFo differential |
| `:bbppairings` | 1 | `cross_program_test.exs` | also tagged `:javafo`, so excluded in CI anyway |

Together 111 tests run only on a machine that holds all three `.swar` files and
the jar: today, the maintainer's. The rest of the suite guards neither path.

Two defects in the reporting itself, both fixed:

- The helper counted `@moduletag` and `@tag` but not `@describetag`, so it said
  **"Skipping 41 test(s) tagged :swar_fixture"** for 51. The CI annotation
  inherited the wrong number (`ad83ed5`).
- The presence check looked for `c-reeks.swar` and `problemski.swar` only, while
  `swar_import_test.exs` also reads `test3-321.swar`; a checkout with the first
  two failed on a missing file instead of excluding the tests (`88c86c2`).

**Proposal: a self-hosted runner that already holds the files.** A second job in
`elixir.yml`, on a machine where the fixtures and the jar legitimately are (the
maintainer's PC, or the Photon VM with them copied there), so nothing
licence-restricted or personal ever leaves it:

```yaml
  artifact-tests:
    name: SWAR and JaVaFo tests
    runs-on: [self-hosted, openpairings-artifacts]
    # Never on pull_request: a self-hosted runner must not execute code from
    # a fork.
    if: github.event_name == 'push' || github.event_name == 'workflow_dispatch'
    steps:
      - uses: actions/checkout@<pinned sha>
      - name: Copy in the local artifacts
        shell: bash
        run: |
          cp "$ARTIFACTS/"*.swar test/fixtures/
          mkdir -p priv/javafo && cp "$ARTIFACTS/javafo.jar" priv/javafo/
      - run: mix deps.get --check-locked
      - run: mix test --only swar_fixture --only javafo
        env:
          # "none" allows no artifact to be missing, so a runner that lost a
          # file fails instead of skipping. Unset or "" allows all of them to be.
          SKIP_MISSING_ARTIFACTS: none
```

`ARTIFACTS` is an environment variable set on the runner, pointing at the
folder that holds the three `.swar` files and the jar; the runner also needs
Erlang, Elixir and a JRE. `workflow_dispatch` has to be added to the `on:`
block.

Rejected, or at least not decided here:

- **Committing the fixtures.** They are real people's data, and SWAR's format is
  proprietary. Not an option.
- **Synthetic `.swar` fixtures** written by `SwarExport` with invented players.
  They would cover some of the structure, but the value of these tests is that
  SWAR itself wrote the files (its version quirks, CP1252 names, blank
  results), which our exporter cannot imitate. Whether a SWAR-format file
  produced by our code may be committed at all is a licensing question for the
  maintainer, not one this pass should answer.
- **Fetching or caching the jar in CI.** `test_helper.exs` already records why
  a fetch from rrweb.org fails (no stable URL, bot protection). A cache has to
  be filled by a job that has the file. Hosting the jar somewhere CI can read
  is redistribution, which depends on JaVaFo's terms.

**Implemented 2026-09-13.** The proposal above is now
`.github/workflows/artifact-tests.yml`, a separate workflow (not a second job
in `elixir.yml`, so a runner that is offline never blocks normal CI or
releases) triggered only by `push` to `main` and manual `workflow_dispatch` -
never `pull_request`, for the reason spelled out in its own top comment.
Setting up the runner itself - registration, the artifacts folder,
`OPENPAIRINGS_ARTIFACTS`, and the security notes on why pull requests are
excluded - is `docs/self-hosted-runner.md`.

### Weak assertions, fixed (worst first)

Each was confirmed by breaking the code under it and watching it stay green.

| test | why it could not fail | fix |
|---|---|---|
| `SnapshotTest` "an unpublished round is absent from the payload" | asserted `after_round`, the label, not the standings rows beside it (mutant S6) | new rows test, `c2702ba` |
| `Trf26RoundTripTest` "a slice of the tournament carries no future bye" | the "future" bye was for a round already played (mutant TX3) | bye moved to round 3, full export proven to carry it, `c2702ba` |
| `StandingsLiveTest` "hiding 'we'/'wmwe' on the Players page hides We/W-We here too" | refuted `"We</th>"`, which is never rendered: the label sits on its own line inside the `<th>`. Forcing both columns on left it green. The companion test asserted a bare `"We"`. | whitespace-tolerant header regexes, `ad83ed5` |
| `ToolsNormsLiveTest` "player surnames are capitalised in the downloaded IT4" | downloads the IT3, which has no player rows, and checks the status. Forcing raw casing into the IT4 rows left the suite green. | renamed to what it checks; the IT4 row casing is now asserted in `Norms.FormsTest`, `ad83ed5` |
| `ArchiveLiveTest` "its JSON export still downloads" | status 200 only; an empty document passed | decodes the export and checks the tournament, `ad83ed5` |
| `PublicPublishingTest` "an operator token makes it operator mode, local or not" | only ever ran local (mutant PM2) | asserts the hosted case, `c2702ba` |

### Weak or odd, listed and not changed

- `SnapshotTest` "a real snapshot is written to the OpenResults fixture
  directory" (`@tag :snapshot_fixtures`) asserts nothing. It generates
  OpenResults' contract fixtures, and in the main checkout it **writes into the
  sibling `../openresults/test/fixtures/` on every `mix test`**. Intentional,
  but a generator running as a test: it cannot fail on contract drift, and it
  edits another repository's working tree as a side effect. A mix task, or
  asserting the written file round-trips, would say what it is.
- `PrintControllerTest` "renders one row per player with rank, name and points"
  asserts `html =~ "A"`, `"B"`, `"C"`, `"D"`: bare letters match the CSP nonce,
  which another test in the same file warns about. Only its last regex checks
  anything, and not "one row per player".
- `SettingsTournamentLiveTest` "the Tournament page carries no pointer card"
  proves the replacement sub-nav tab is there with `html =~ "OpenResults"`; any
  other mention of the product on the page satisfies it.
- `ExportControllerTest` "a nonsense parameter still yields a file" asserts the
  body contains `"Name"`. Acceptable: the default header has it.
- `BackupDownloadTest` "a local run needs no role at all" checks the status
  only. Backup code, left for the backup work.
- Five test files compile with six unused-variable or unused-alias warnings
  (`local_mode_test.exs`, `registration_poll_test.exs`, `deploy_notice_test.exs`,
  `settings_tournament_live_test.exs`, `local_owner_session_test.exs` twice).
  Harmless, but noise that hides the warning that is not.
- About 60 `refute ... =~ "..."` lines refute literals found nowhere in `lib/`
  or `priv/gettext`. Sampled: nearly all are regression guards for copy that was
  deliberately removed, which is fine, or refute a format the same test also
  asserts positively. The `We</th>` case above was the one that could never
  fire.

### Skipped, tagged, and swallowed

- No `@tag :skip` anywhere, and no `@moduletag :skip`.
- Tags in use: `:swar_fixture`, `:javafo`, `:bbppairings` (above);
  `:snapshot_fixtures` (above); `:tmp_dir` (ExUnit's own); `:public_base`, a
  label on 4 tests in `public_link_test.exs` that nothing filters on. It is
  written as `@moduletag` inside a `describe`, where `@describetag` was meant;
  it tags exactly that block's four tests only because they are the last in
  the file.
- No test swallows a failure. The `rescue`/`catch` blocks in tests either
  `flunk` with the reason (`xlsx_fill_test.exs`) or are `try ... after` cleanup
  of temporary files.

## How to repeat this

The scripts were kept out of the repository. The essentials:

- **Flake loop**: `mix test --seed N` in a loop, restoring a copy of the
  suspect `pairings_engine_test.db` before each run, logging the `Result:` line
  and every `N) test` header.
- **Mutants**: for each, replace one exact snippet (it must occur exactly once),
  run the nearest test files, run the whole suite if green, write the original
  bytes back in a `finally`, then `git diff --quiet` the file.
- **Weak assertions**: a test is weak when a mutation of the code it names
  leaves it green; heuristics (no assertion, status-only, bare-word `=~`,
  refutes of literals absent from `lib/`) only find candidates.
