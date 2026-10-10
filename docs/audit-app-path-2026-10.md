# App-path audit, 2026-10

The question: *the engine might be perfect, and then the app around it does
something like this.* Four production bugs in a row were not in Ainalrami
but in what OpenPairings handed it or said about it afterwards - player
order in Baku rounds, pairing numbers never re-seeded, an explanation page
with its own opinion about colours, late entrants' rounds missing from the
results site. This audit looked for their relatives.

Branch `app-path-audit`, from main at 0.83.0. Nothing pushed.

## Method

Two instruments, both in `test/pairings_engine/`:

- **`app_path_fuzz_test.exs`** - random individual Swiss events driven only
  through the app's own context functions (`create_tournament`,
  `create_player`, `update_player`, `pair_next_round`, `delete_round`,
  `update_pairing_result`, `swap_players_in_round`, `vacate_seat`,
  `award_bye_for_vacancy`, the publish functions, the TRF and JSON export
  and import). Axes: 6-18 players, 4-7 rounds, 1-half-0 / 2-1-0 / 3-1-0, a
  bye worth a win or a draw, absences unpaid / paid a draw / paid a win /
  capped by count / capped by round, "rounds before a late entrant count as
  absences" on and off, late entrants numbered by rating or at the end,
  Baku, extra points as acceleration and as a counted handicap, the bye
  type asked per absence, forbidden pairs, shared ratings and titles, late
  entrants, withdrawals, returns, announced absences, forfeits, a round
  unpaired and paired again, an earlier result corrected after the next
  round exists, players swapped or taken off a board by hand.

  After every round the same question is asked several ways and the answers
  must agree: who is seated against who may be; played games against the
  new boards; the score in the engine's own input (captured from the
  pairing run) against the standings; the standings against their own
  per-round records; the TRF's points column; the pairing numbers against
  C.04.2 2.2 written out independently; the OpenResults snapshot round by
  round against its own standings block; a round unpaired and paired again
  against itself; the next round of a JSON copy and of a TRF copy against
  the original's; and at the end `ainalrami -c` on the exported file.

  `APP_PATH_FUZZ_COUNT` (default 6, a few seconds) and `APP_PATH_FUZZ_FIRST`.

- **`app_path_audit_test.exs`** - one focused test per finding. Tests of
  findings that are not fixed are skipped; `APP_PATH_OPEN=1` runs them, and
  they fail.

Beside those, a reading of every place that recomputes something the engine
also holds (`pairing_rationale.ex`, `restriction_check.ex`,
`manual_pairing.ex`, `player_card.ex`, `snapshot.ex`, the `Standings` to
`Ainalrami.Tiebreaks` bridge, `trf_export.ex`'s rank column), against
C.04.2, C.04.3, C.04.7 and C.07 in the Handbook text of 2026-02/03 and
against the engine's own input contract (`Ainalrami.Trf`,
`Ainalrami.Pairing`).

## Findings

Severity is about what an arbiter or a spectator would see, not about how
hard it was to find.

| # | Severity | What | Reproduce | Test | Fixed |
|---|---|---|---|---|---|
| F4 | **High** | **The results site shows a dash for a player who missed a round with nothing recorded for it.** `Snapshot` sent no figure for a round in which a numbered player had neither a board nor a bye row: a withdrawn player from the round they left, a player who withdrew and came back (their running score is a dash on every later pairing list), a player taken off a board by hand. OpenResults adds the rounds up and reads silence as "unknown". The late-entrant fix of 2026-10-10 (`not_joined/3`) covered one of four cases. | Six players, round 1; withdraw P03, round 2; reactivate P03, round 3; publish. P03 has no entry in round 2 of the snapshot. Fuzz: the first 40 tournaments (38 withdrawals) reported it 70 times. | `the snapshot's per-round figures` (4 tests); fuzz `check_snapshot` | **Yes** - every such round is published as `not-paired`, 0 points (`Snapshot.not_paired/4`). Individual Swiss only. **OpenResults should learn the word** (`bye_kind("not-paired")`); until then it prints it as sent. |
| F1 | **Medium** | **The explanation page calls the engine's legal pairing a REMATCH.** `PairingRationale.prior_opponents/2` counted every earlier board with two players, forfeits included. C.04.2 3.5: two participants who did not play their game "may be paired together in a future round", and the engine does. The same disease as the colour bug of 0.82.0, one function further down. | Two players, round 1 `1-0FF`, pair round 2: the page reports one rematch anomaly on the only board there is. | `the explanation page and a pair whose first board was a forfeit` (3 tests) | **Yes** |
| F3 | **Medium** | **A restriction added after a round, then that round unpaired.** `from_round` ("holds from the next round", VCL4THP Q217) was not moved when the round before it was unpaired. For a forbidden PAIR the engine was handed the prohibition for the re-paired round anyway (`Pairing.forbidden_pairs/4` does not read `from_round`) while the row, and the TRF's `260`, went on saying "from the round after": the file misreports which rounds were paired under it. For a pairing RULE it was the other way round - `Exclusions.rounds/2` does read it, so the rule the arbiter had just added was not applied to the round they unpaired in order to apply it. | Four players, round 1 played, round 2 paired (1-2, 3-4); add a group rule {P01, P02}; unpair round 2; pair it: 1-2 again. | `a forbidden pair added after a round that is then unpaired` (3), `a pairing rule added after a round that is then unpaired` (2) | **Yes** - unpairing moves any later `from_round` to the first round still to be paired, nil when none is (`Pairing.reopen_prohibitions/2`). |
| F10 | **Medium** | **A paired round was checked under the next round's pairing rules.** `Pairing.engine_field/2` - the field behind the manual-pairing checker (`ManualPairing.assess/2`, whose verdict is written to the TRF as a PIBE line), "Explain again" (`reexplain_round/2`, `deepen_round/3`) and the explanation page's "why not this pairing" answers - built its TRF through `trf_input/5`, which always wrote the exclusions of round `paired + 1`. A club or federation rule for "the first N rounds" was missing from round N's field as soon as round N existed; a rule for "the last N rounds", for a range, or one added later (`from_round`) was read back into the round before it started. The pairing itself and the stored explanation computed right after it were right (`section_input/5` passes the round); everything asked afterwards was not. | Six players, P01 and P04 of one club, rule "same club, first 1 round", pair round 1: `engine_field(t, 1).opts[:forbidden_pairs]` is empty. | `the field a paired round is checked in` (3 tests) | **Yes** - `trf_input/6` takes the round; `engine_field/2` passes it. |
| F2 | Low | **"This round cannot be paired" was not a proof.** `RestrictionCheck.met_keys/1` counted forfeited boards as meetings; the page's red warning (and its `isolated` list) could name a round the Pair button then paired. | Two players, round 1 `0-0FF`: `pairable: false`, and `pair_next_round/1` returns `{:ok, _}`. | `the restriction check and forfeited boards` (2) | **Yes** |
| F5 | Low | **An absence paid a full point: the standings and the TRF disagree about what it is.** `Standings` marked every `absent` row voluntary (a requested bye) when `absent_counts_as_vur` is on, whatever it paid. C.07 16.1.1 defines a requested bye as "a half-point-bye or a zero-point-bye"; an unplayed round worth a win is 16.2.1's full-point bye, and the app's own TRF writes it `F`. In the last round (16.2.5 / 16.3.2) the standings counted it as a draw in the opponents' Buchholz and the file's rank column did not follow from the file - `ainalrami -c` says "rank(s) do not follow". Only tournaments with `abs_value == points_win`. | Eight players, `abs_value` 1.0, P05 absent in the last round: an opponent's BH is half a point below the sum of their opponents' scores. Fuzz: 4 of 260. | `an announced absence worth a full point` (3) | **Yes** - such a row is not voluntary. **A rules reading; veto it if you read 16.1.1 otherwise.** |
| F9 | Low | **The TRF's place column counts players who are not in the file.** `TrfExport.with_final_ranks/4` took each row's place from the standings, which also rank a player with no pairing number (a late entrant not yet paired who already holds paid absences; a no-show withdrawn before round 1). The file's places then skip a number. Not the file for rating when it re-ranks (`rerank/2`), every other TRF26. | `abs_value` 0.5, four players, round 1, add a late entrant for round 2, export: places 1, 2, 4, 5. | `the TRF's places when the standings hold a player the file does not` | **Yes** |
| F7 | Low | **A backup older than `absent_counts_as_vur` is restored with the opposite setting.** DB default `false` (migration of 2026-08-05), schema default `true` (changed later, no data migration). A file without the key got the schema's answer; the tournament it was taken from had the migration's. The same shape as the grandfathered `late_entry_numbering`, which has its `legacy_` function; this one had none. | Export, delete the key, import: `true`. | `an export written before absent_counts_as_vur existed` | **Yes** (`legacy_absent_counts_as_vur/1`) |
| F6 | Low | **A TRF cannot say "withdrew", and the import does not ask.** Export a tournament with a withdrawn player to TRF, import it, pair the next round: the copy pairs them. The file shows a player with nothing in the later rounds, which is also what an absentee looks like. Same for the players' extra points when they are in the pairing: the rounds paired with them are in the file (`XXA`/`250`), what the next round is paired with is not. The JSON export carries both; 100% of JSON round trips paired identically. | Six players, round 1, withdraw P06, round 2, TRF out and in, pair round 3: P06 is on a board. Fuzz: every TRF round trip with a withdrawal. | `a withdrawn player, exported to TRF and imported again` (skipped, open) | **No** - a format limit. What would help is an import note naming every player with nothing in the trailing rounds ("withdrawn? they will be paired"). |
| F8 | Low | **In a Baku round the explanation page counts floaters by game points.** The page builds its brackets on game points and says so in a note; it then flags every board between a Group A loser and a Group B winner (one pairing-score bracket) as a floater, and counts them in the summary. | Eight players, Baku, round 1, pair round 2: `summary.floaters == 2`. | `the explanation page in a Baku round` (skipped, open) | **No** - the fix is to carry Baku's virtual points into `pre_round_scores/3` as the recorded extra points already are, and reword the note (EN + NL). Not small, so not done here. |

Ten findings: 1 high, 3 medium, 6 low. Eight fixed, two documented.

Each fixed finding's test was run against the code as it was (the files
checked out from 0.83.0) and failed there; the two open ones fail now.

### What the fixes ask of somebody else

- **OpenResults has to learn `not-paired`** (F4): one clause in
  `OpenResultsWeb.TournamentHTML.bye_kind/1` and its Dutch string. Until
  then the site prints the word as sent, which is legible and not pretty.
  A withdrawn player is now listed under each later round's byes as not
  paired, 0 - the same place a late entrant's "not yet joined" rounds are
  listed. If that is more than the round pages should say, the cure is on
  the results site (do not list the kind), not in the snapshot: the figure
  has to travel or the running score cannot be added up.
- **The cross-repo contract fixtures are not touched by this branch**: every
  one of them matches openresults at `faf39a8`, the commit that goes with
  0.83.0. Four of those tests fail on this machine today all the same,
  because the openresults checkout beside it moved to `1afbc4e` while this
  was being written and its fixtures gained `"flags": true` from a newer
  OpenPairings. They pass again once this branch sits on that main.
- `test/fixtures/pair_click/golden.term` was regenerated: two `not-paired`
  rows in the public snapshot of the first scenario, and with those taken
  out the file is equal, term for term, to the one before.

### An observation that is not the app's

**O1.** `ainalrami -c` credits a bye granted for a round not yet paired (a
TRF26 `240` record) in the score it ranks by, then reports that the file's
place column "does not follow". The file's places are the standings as
they are. Seen on every exported tournament that stopped with an announced
absence still ahead. This is the checker, in the Ainalrami repository; the
harness asks only for the rounds to match when a `240` is present.

## What agreed

Over the 600 tournaments of the final run (seeds 1-600; counts in the
`APPPATH` line the test prints):

| | |
|---|---|
| tournaments / rounds / games | 600 / 3,183 / 17,956 |
| late entrants / withdrawals / returns / announced absences | 681 / 496 / 279 / 1,187 |
| tournaments with a forbidden pair | 169 |
| rounds unpaired and paired again | 766 |
| seats vacated by hand / byes given for them / forfeit wins recorded on them / swaps | 346 / 181 / 165 / 169 |
| JSON round trips, same next round | 905 of 905 |
| TRF round trips: same / a player with no number yet is not in the file / a withdrawn player came back (F6) / extra points not carried (F6) | 414 / 222 / 218 / 49 |
| `ainalrami -c` on the final file: passes / rounds pass, places differ for O1 / not asked (round changed by hand or result corrected) / not asked (counted handicap) | 185 / 1 / 374 / 38 |
| tournaments that stopped at "no legal pairing" (small fields, many rounds) | 19 |

Two more tournaments had the place column skip a number (F9; that run was
before its fix).

A further 200 tournaments (seeds 601-800) were run on the finished branch:
no failures, and no place column skipping a number.

Nothing failed that is not a finding above. In particular, none of these produced a single
disagreement:

- the score the engine was paired on against the standings, for every
  player of every round - under every point system, paid and capped
  absences, late-entry absences, typed byes, hand-vacated seats and forfeit
  wins recorded on them;
- "nobody paired who is not in the round", "everybody in the round is on a
  board", "at most one pairing-allocated bye", "no two who played meet
  again", "no forbidden pair";
- a round unpaired and paired again is the same round, and the pairing
  numbers do not move;
- with numbering by rating, the pairing numbers are C.04.2 2.2's order -
  rating, title, name - after any number of late entries;
- the JSON export and import pairs the same next round, every time;
- the TRF's points column against the standings;
- `ainalrami -c` reproduces every round of every exported file it was asked
  about (it is not asked once a round was changed by hand or an earlier
  result was corrected, and not for a counted handicap, which is
  deliberately not in the file as virtual points).

Also read and found consistent with the engine: `ManualPairing.warnings/4`
(rematch and colours from `Ainalrami.Trf.game_was_played?/1` over the
engine's own field), the bye-eligibility warning (`Ainalrami.Pairing.
bye_eligibility/2`), `PairingRationale`'s colour ladder (ported from the
engine, fixed in 0.82.0), the `Standings` to `Ainalrami.Tiebreaks` bridge
apart from F5, and the letters `Pairing.unplayed_code/2` writes against
C.04.3 1.4.3 and [C2].

## Settings that change what the engine is told

Every tournament column that reaches the engine's input or the score it
brackets by, and where its value comes from.

| Column | DB default | Schema default | Created in the app | JSON import, key missing | Note |
|---|---|---|---|---|---|
| `late_entry_numbering` | `end` | `rating` | `rating` | `end` (`legacy_late_entry_numbering/1`) | **Mismatch, handled.** The grandfathered `end` is asked about once (0.83.0). TRF and SWAR imports get `rating`. |
| `absent_counts_as_vur` | `false` | `true` | `true` | was `true`, now `false` | **Mismatch, was not handled: F7.** Tie-breaks only, not pairing. |
| `round_one_absentees_late` | `false` | `false` | `true` (`create_tournament/1,2`) | `false`, or the live row's on a restore | **By design**: a TRF or SWAR import keeps `false` because the file's numbers stand (`pairing_numbers_origin: "import"`). Baku ignores it (always late). |
| `late_entry_absences` | `true` | `true` | `true` | `false` for a finished tournament (`legacy_late_entry_absences/1`) | Handled. SWAR import sets it from the file. |
| `publish_mode` | `immediate` | `manual` | `manual` | `legacy_publish_mode/1` | Not engine input; listed because it is the third DB/schema mismatch. |
| `rating_method` | `FIDON` | `FIDON` | `FIDON` | `FIDON` | Decides the initial order. |
| `initial_order_tiebreak` | `name` | `name` | `name` | `name` | |
| `points_win` / `draw` / `loss`, `bye_value` | 1 / 0.5 / 0 / 1 | same | same | same | |
| `abs_value`, `abs_jusque`, `abs_nbfois`, `presence_value` | null | nil | nil | nil | Set by the Scoring page or a SWAR import. |
| `presence_on_allocated_bye`, `ask_bye_type`, `pair_by_category`, `swiss_match_format`, `count_extra_points`, `postponed_games` | `false` | `false` | `false` | `false` | |
| `acceleration` | `none` | `none` | `none` | `none` | |
| `extra_points_mode` | `handicap` | `handicap` | `handicap` | `legacy_extra_points_mode/2` | Handled. |
| `initial_colour` | `lot` | `lot` | `lot` | `lot` | `initial_colour_drawn` nil until round 1. |
| `soft_position` | `strong` | `strong` | `strong` | `strong` | |
| `postponed_requester_outcome` / `opponent_outcome` | `draw` | `draw` | `draw` | `draw` | The provisional score a postponed game is paired on. |
| `baku_group_a_last`, `pairing_numbers_origin`, `team_pairing_mode` | null | nil | nil | carried by hand, see `TournamentImport` | Facts the app records, not choices. |
| `teams_ordered_by_hand`, `team_rating_method`, `team_unrated_rating` | `false` / `olympiad` / 1400 | same | same | same | Team seeding. |

`players.paid` (`paid` in the DB, `nopaid` in the schema) is the only other
mismatch in the seven tables compared, and has nothing to do with pairing.
The comparison is `PRAGMA table_info` against the struct defaults, for
`tournaments`, `players`, `rounds`, `pairings`, `teams`,
`forbidden_pairings` and `pairing_rules`.

## Known and left as it is

- A round's value that is none of nothing, a draw's or a win's (an absence
  paid half a point in a 3-1-0 event) has no TRF letter and is written `Z`;
  the score column stays exact. `Tournament.engine_point_system/1` documents
  it. C.04.3 1.4.3 would give that player a downfloat for the round and the
  engine cannot see one. Not exercised by the harness (its absences pay a
  draw or a win).
- A counted handicap is in the pairing and not in the file as virtual
  points (`Pairing.accelerated_rows/4`), so no checker reproduces those
  rounds from the TRF. Deliberate, and such an event is out of FIDE mode.
- The player card's float column and the Baku note on the explanation page
  both work from game points. F8 is the part of that which misleads.

## Not covered

Honestly:

- **Team events** (C.04.6): team seeding (`teams_ordered_by_hand` against
  rating), match and game points, line-ups, board order. `TeamSwiss` was
  read for its input contract only; nothing was run. The existing
  `team_flow_validation_test.exs` is the instrument there.
- **Keizer and round robin.** The harness is individual Swiss only. F4's
  fix deliberately does not touch them, so a Keizer or round-robin player
  with nothing in a published round can still be a dash on the results
  site.
- **Pairing by category** and **Swiss match format** (in the latter the
  engine is told `rounds_count` legs, so the last-round colour exception
  falls on the wrong leg - a suspicion, not tested).
- **SWAR** import and export: the `.swar` fixtures are not in this
  checkout, and those 55 tests were excluded.
- **Postponed games** in the harness (the existing
  `trf_flow_validation_test.exs` drives them; this one does not), and with
  them the file sent for rating.
- **Norms**, the **rating report**'s choice of games, **Compliance**, the
  **TRF import's round check**, the **next-round preview**'s what-if
  outcomes: read in passing (the preview and the import check both run the
  engine's own code), not tested.
- **The LiveViews.** Everything here is at the context layer; a page that
  shows a right number wrongly is not something these tests can see.
- `bbpPairings` was not used as a second opinion: `cross_program_test.exs`
  already does that for the engine's input, and the class looked for here
  is the app disagreeing with itself.
