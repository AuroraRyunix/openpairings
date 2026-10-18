# Pairing-flow audit, 2026-10-18

Scope: everything between the tournament state and the engine and back again,
on `main` at 0.91.0 with Ainalrami v0.43.2. The engine itself was not
re-audited. The question was the Baku one: does the app ever hand the engine a
tournament that is not the one on screen, or store something other than what
the engine answered?

The method was reading the path end to end, then writing a repro for every
suspicion. A suspicion without a failing repro is either listed under "checked
and correct" or under "notes" with the reason it has no test.

Repro tests: `test/pairings_engine/pairing_audit_1018_test.exs`. They are
tagged `:audit` and excluded by default (`test/test_helper.exs`), so the suite
stays green. `mix test test/pairings_engine/pairing_audit_1018_test.exs --only audit`
runs them. All 11 fail on 0.91.0. Each one should pass once its finding is
fixed, and then lose the tag.

## Summary

| severity | count | findings |
|---|---|---|
| wrong pairing possible | 5 | P1, P2 (with P2b), P3, P4, P5 |
| wrong state, pairing unaffected | 0 | - |
| robustness | 2 | R1, R2 (plus three notes without tests) |

## Findings

### P1 - a TRF imported mid-round loses the round's open boards

- **Severity:** wrong pairing possible.
- **Where:**
  - `lib/pairings_engine/trf_import.ex:1339`: `create_rounds` keeps a game only when `game.result not in [nil, ""]`.
  - `trf_import.ex:1499-1511`: `mutual_opponent` also requires a non-blank result on the opponent's side.
- **Scenario:**
  1. A TRF has round 2 paired, with one board finished and the others not played yet. The opponent and colour are filled in and the result is blank. This happens with a foreign file, and with this app's own export taken mid-round.
  2. On import, the unfinished boards are dropped without a word. Round 2 is stored with only the finished board.
  3. `round_complete?` therefore says yes, and the copy pairs round 3 over games nobody has played yet. The players who were seated in round 2 are treated as absent. The result is wrong scores, wrong float and colour history, and a possible rematch of the dropped pair later on.
- **Tests:**
  - `P1 ... the open boards of a foreign file are kept, and the next round is not paired over them` (1 of 2 boards kept).
  - `P1 ... this app's own TRF, exported mid-round, comes back with the round's open boards` (3 boards become 1, and the copy pairs round 3).
- **FIDE:** C.04.1 (a pairing is made on the results of the previous rounds). After the copy pairs round 3 over the dropped boards, C.04.3 C1 is no longer protected for that pair.
- **Fix:** import a board that has an opponent and no result as a pairing with result `""`, so the round is "playing". Report the open boards in the import report.

### P2 - a result cleared in an earlier round lets the pair meet again

- **Severity:** wrong pairing possible.
- **Where:**
  - `lib/pairings_engine/pairing.ex:760-769`: `round_complete?/2` checks only the round it is given. Every caller passes only the last paired round:
    - `pairing.ex:205` (Swiss);
    - `pairing.ex:447` (by hand);
    - `keizer.ex:119`;
    - `team_swiss.ex:121`.
  - `tournaments.ex:6072`: `update_pairing_result` accepts `""` on any round that `ensure_round_editable` (`tournaments.ex:6646`) allows. That includes the round before the last, even in FIDE mode.
- **Scenario:**
  1. Six players. Rounds 1 and 2 are played.
  2. The arbiter clears a round-1 result, for example to re-enter it, and does not re-enter it.
  3. Round 3 is paired. In the engine TRF the board has an opponent and no result (`opponent_rank: 5, result: nil`), and the engine does not count it as a game.
  4. Round 3 pairs the same two players again.
- **Test:** `P2: a result cleared in a round before the last - a pair whose earlier result was cleared is not paired again`.
- **FIDE:** C.04.3 C1 (two players shall not meet more than once).
- **Fix:** have `round_complete?` (or a new `all_rounds_complete?`) check every paired round, or refuse to clear a result in a round that is not the last.

#### P2b - the Swiss match format checks only the second leg

- **Where:** the same `round_complete?(tournament.id, paired)` call at `pairing.ex:205`. With `swiss_match_format`, `paired` is the second leg, so a first-leg board without a result is never looked at.
- **Scenario:**
  1. Match format, 4 rounds.
  2. In match 1, the second leg is played in full and one first-leg board is still open.
  3. Match 2 is paired anyway.
- **Test:** `P2b ... the next match is not paired while a first-leg board has no result`.
- **FIDE:** C.04.2 (the results of the previous rounds are known), and C.04.3 C1 through the same mechanism as P2.
- **Fix:** check both legs of the last match. This is covered by the all-rounds check in P2.

### P3 - Baku virtual points of past rounds are recomputed from today's settings

- **Severity:** wrong pairing possible.
- **Where:** `pairing.ex:4844-4890`, `accelerations/3`.
  - The virtual points of every past round are derived again on each pairing run, from the current `rounds_count` and `acceleration`.
  - Ainalrami judges floats and score groups on the past scores including those virtual points (`deps/ainalrami/lib/ainalrami/pairing.ex` ~2594-2632, `score_before` / `acceleration_at`).
  - `rounds_count` and `acceleration` are locked only in FIDE mode (`tournaments.ex` `fide_locked_fields`).
  - Extra points do not have this problem: they are recorded per round in `rounds.virtual_points`.
- **Scenario:**
  1. Baku, 9 rounds, 12 players, outside FIDE mode, rounds 1-2 played.
  2. The organiser shortens the event to 5 rounds. Player 1's virtual points for rounds 1-3 go from `[1, 1, 1]` to `[1, 1, 0.5]`.
  3. If acceleration is switched off instead, they go to `[]`.
  4. The round-3 pairing then sees different score groups for rounds already played. The floats given in those rounds are judged against scores the players did not have, which changes who may float again.
- **Tests:**
  - `P3 ... changing the number of rounds does not rewrite them`;
  - `P3 ... switching acceleration off does not erase them`.
- **FIDE:** C.04.7 (Baku acceleration; the virtual points apply to the rounds in which they were given). C.04.3 1.4 and the float criteria C12-C15 are judged on the pairing score.
- **Fix:** store the Baku virtual points per round in `rounds.virtual_points` when the round is paired, exactly like extra points, and read them back instead of recomputing them. Alternatively, lock both fields once round 1 is paired.

### P4 - a one-player category gets the pairing-allocated bye every round

- **Severity:** wrong pairing possible.
- **Where:** `pairing.ex:1699-1712`, `compute_category_group/8` for `[player]`. It returns `:bye` with no C2 check and no warning.
- **Scenario:**
  1. Pairing by category, with categories Open and Junior.
  2. Junior has a single player. That player gets the PAB in round 1, again in round 2, and in every round after that.
- **Test:** `P4 ... the lone player is not given the pairing-allocated bye a second time (C.04.3 C2)`.
- **FIDE:** C.04.3 C2 (no PAB for a player who already had one, or who already scored a win without playing).
- **Fix:** do not pair silently.
  - Refuse with a message naming the category, or pair the player into another group.
  - At the least, flag it so the arbiter decides. A one-player category cannot be paired legally after round 1.

### P5 - correcting pairing numbers after round 1 moves players across the Baku line

- **Severity:** wrong pairing possible.
- **Where:**
  - `pairing.ex:5007`: `baku_group_a_last` is frozen as a pairing **number**, not as a set of players.
  - `lib/pairings_engine/tpn.ex:355` (`exchange`), `tpn.ex:431` (`regenerate`) and `tpn.ex:469` (`write`) are allowed until round 3. They renumber players and never touch `baku_group_a_last`.
  - `accelerations/3` (P3) then recomputes every past round's virtual points from the new numbers.
- **Scenario:**
  1. Baku, 7 rounds, 8 players. Group A is numbers 1-4. Round 1 is played.
  2. A rating correction raises player 7 and the numbers are regenerated, or two equal-rated players on either side of the line are exchanged.
  3. Player 4 leaves Group A. Their round-1 virtual points change from `[1.0]` to `[]`. The player who moved in gains virtual points for a round in which they had none.
- **Tests:**
  - `P5 ... a regeneration after round 1 keeps Group A's players and their history`;
  - `P5 ... an exchange of two equal ratings across the line keeps Group A's players`.
- **FIDE:** C.04.7 1.3.2 (Group A is fixed before round 1 and its membership does not change). C.04.7 1.2 (the virtual points of a round are those given when it was paired).
- **Fix:** freeze Group A as player ids, or move `baku_group_a_last` together with the renumbered players. Together with the P3 fix, past rounds are then unaffected either way.

### R1 - two pairing runs at once number a late entrant twice

- **Severity:** robustness.
- **Where:**
  - `pairing.ex:217` / `464` call `ensure_pairing_numbers` (`pairing.ex:1049`).
  - It writes the numbers outside the round transaction, from a player list read before the run.
- **Scenario:**
  1. Two pair clicks arrive together, from two tabs or two arbiters.
  2. Both runs see the late entrant without a number. The first numbers them 2 and shifts the others.
  3. The second run starts from its stale list and shifts again, which leaves a gap (`[1, 3, 4, 5, 6]`).
  4. The second run's round insert then fails on the unique index (see N1), so no wrong round is stored. The numbers are wrong until the next regeneration, and are frozen once round 3 is paired.
- **Test:** `R1 ... the second run does not number them again`.
- **Fix:** number from fresh rows inside the round transaction, or take a per-tournament lock around the whole pairing run.

### R2 - the open hand-edit guard lives only in the LiveView

- **Severity:** robustness.
- **Where:**
  - `lib/pairings_engine_web/live/pairings_live.ex:3657` refuses to pair while `ManualPairing.open_round` returns a round. `Pairing.pair_next_round` does not check it.
  - `create_round_by_hand` and `ManualPairing.start` are two separate steps (`pairings_live.ex` ~1211-1263), not one transaction.
- **Scenario:** a round is created by hand and its hand-pairing session is still open. Any caller other than that LiveView handler can pair the next round over it: the API, the plugin seam, or a second LiveView that was mounted before the session opened.
- **Test:** `R2 ... the next round is not paired over it`.
- **Fix:** check `ManualPairing.open_round/1` inside `Pairing.pair_next_round`, and create the round and start the session in one transaction.

### Notes (no test)

- **N1.** The second of two concurrent pairing runs raises `Ecto.ConstraintError` from the unique index on `rounds(tournament_id, number)` instead of returning a message. The index does its job, and no duplicate round is stored. The user only sees a crash instead of "already paired".
- **N2.** The JSON import does not reject duplicate `pairing_number`s within a tournament. Nothing in the app produces such a file, so this has no test. A hand-edited file with a duplicate would give the engine two players with the same rank.
- **N3.** In match format, an absentee in leg 2 has the known limitation that is already documented. It is not re-reported here.

## Checked and correct

- `trf_game` result mapping: every stored result code maps to the right TRF code, both sides. A forfeit's colour is ignored by the engine (`game_was_played?`).
- A full-point absence is written as `F`. That is correct: it counts for C2 (a win without playing) and for the 1.4.3 downfloat.
- Engine ranks are the full roster in pairing-number order. Ineligible and withdrawn players are `Z` rows, not removed, so the ranks never shift (the Baku class of bug is closed on this path).
- `Tpn.order` keeps the numbers of withdrawn players. In FIDE mode, the departure guard rolls numbers back.
- Late entrants:
  - LateEntry absences exclude the rounds in which the player was seated;
  - `release_round_one_absentees`;
  - the Baku line moves correctly for a late entrant numbered into Group A.
- Future byes set `absent_rounds` before the pairing reads them.
- Extra points are recorded per round and read back, not recomputed.
- Team Swiss: the engine input takes colours from team A = board-1 White, which matches `team_rounds.ex`. `swap_home` is consistent on both sides.
- `create_round` / `create_mirrored_leg` write the engine's answer in one transaction. Boards, colours and the bye match the engine output.
- The LiveView refreshes the tournament struct on PubSub broadcasts. A pairing run uses current settings, not the ones from mount.
- The pair event is not replayed on reconnect: it is a `phx-click`, and the `pairing_in_progress` guard also prevents a double run.
- FIDE mode locks `rounds_count` and `acceleration`. Outside FIDE mode they are not locked, which is the root of P3.

## Not covered

- SWAR import: there are no fixtures in the worktree.
- KBSB import: only read, not exercised.
- Cross-checking the app's engine input against an independent checker (`ainalrami -c`) over a corpus. Prior audits did this (`docs/audit-app-path-2026-10*.md`), and big corpora were out of scope here.
- Round robin: read only. It does not go through `accelerations` or `round_complete?` in the same way, and nothing suspicious was found.
