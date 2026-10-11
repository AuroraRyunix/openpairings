# App-path audit, 2026-10, part 2

The same question as [part 1](audit-app-path-2026-10.md) - *the engine is
right, and then the app around it does this* - asked of what part 1 left
out: team events, round robin, Keizer, pairing by category and the Swiss
match format, the Belgian file, norms, the rating report, postponed games,
FIDE-mode bookkeeping, and the pages themselves.

Branch `app-path-audit-2`, from main at `78a82c7c`. Nothing pushed.

## Method

- **`test/pairings_engine/app_path_audit2_test.exs`** - one focused test
  per finding, as in part 1. Tests of the findings left open by the audit
  were skipped behind `APP_PATH_OPEN=1` until those were decided
  (2026-10-11); nothing in the file is skipped now. Every fixed finding's
  test was run against main's `lib/` (stashed) and failed there.
- **`test/pairings_engine/app_path_fuzz_test.exs`**, extended: every third
  seed now allows postponed games (see "Postponed games in the harness").
  The other two thirds are the tournaments they were, draw for draw.
- Probes that were run and thrown away, because they are instruments and
  not regressions: the Berger tables against the text of C.05 Annex 1; team
  Swiss events paired, unpaired and paired again, and copied through the
  JSON export; 40 synthetic tournaments through the SWAR export and import.
  Where one earned a permanent test it has one; the rest are described
  under "What agreed" with their counts.
- Reading, against the Handbook text in `fide-handbook/text/` (C.04.6 of
  2026-02, C.05 and its Annex 1, C.07, B.01 of 2024) and against the
  engine's own contract in `deps/ainalrami`.

One thing learned on the way decides how to read several findings, part
1's included: **the Players page withdraws a player with the Forfeit tick,
which sets `players.forfeit`.** `players.status` is `"withdrawn"` only for
the roster of a withdrawn team (and for whatever an import carried); the
only status that page sets is `"expelled"`. Part 1's harness, this one's,
and `round_robin_withdrawal_standings_test.exs` all withdraw a player by
writing the status - a state the app can hold and an arbiter cannot
produce for an individual. G1 is what that hid.

## Findings

Severity is about what an arbiter, a player or a spectator would see.

| # | Severity | What | Reproduce | Test | Fixed |
|---|---|---|---|---|---|
| G1 | **High** | **A round robin's final standings count the games of a player who withdrew early - unless they were expelled.** C.05 6.6 (2) 1: under 50% of the games completed, the results stay in the table "but they shall not be counted in the final standings". `Standings.uncounted_withdrawals/2` read `status in ~w(withdrawn expelled)`. The Players page withdraws with **Forfeit** (`forfeit: true`, status untouched), so the rule - in the code, in the manual (chapter 8), in the changelog, and green in its own test file - applied to expulsions and to nobody withdrawn the documented way. | Six players, single round robin; P06 plays two games, forfeits three, and is ticked **Forfeit**: the other five still hold their points against P06 and P06 has a place. | `a round-robin player withdrawn with the Forfeit tick` (3) | **Yes** - `Player.withdrawn?/1` or `expelled?/1`, which is what the page calls withdrawn. Decided 2026-10-11: it applies to a round robin imported from SWAR with a *forfait général* player too, which is what the code does (the importer sets the Forfeit tick); tested (`the same event imported from a SWAR file`) and in the manual, chapter 8. |
| G7 | **Medium** | **A helper's phone could write over a result the arbiter had just entered.** A helper fills blank boards only (`Mobile.permit_result/4`, "fill-once", described there as the enforcement behind the hidden button). Blank was judged on the struct the phone's LiveView was holding, which is blank for as long as that page is behind. | Pair a round; hold a board; enter `1-0` on it from the desk; `permit_result(helper, held_board, 1, 1)` is `:ok`. | `a helper's phone that is a moment behind` (2) | **Yes** - the rule reads the stored row. |
| G5 | **Medium** | **An expelled player goes to SWAR as Present.** `SwarExport.reverse_absent_code/1` read the Forfeit and Absent ticks and never the status. An expelled player (and a withdrawn team's player) left as SWAR's code 4: SWAR pairs them in the next round, and so does this app when the file comes back. | Six players, round 1, expel P06, export, import, pair: P06 is on a board. | `an expelled player, exported to SWAR's format` (3) | **Yes** - written as SWAR's Forfeit (code 1), with a line under the export button. Imported back the player is a forfeit, not expelled: the format has no word for it. **Not verified in SWAR itself**, see "Not covered". |
| G3 | **Medium** | **A title norm counts the FIDE flag as a foreign federation.** B.01 1.4.2: players with federation `FID` "are accepted, but do not count as a foreign player"; 1.4.3 asks for two federations other than the applicant's. `TitleNorms` counted `FID` as one of them. The one place found where the judgment could say *achieved* against the regulation - the module's own promise is that it never does. | A BEL applicant, nine opponents: four BEL, four FID, one NED. The federation check passes with "2 federations". | `a norm and an opponent under the FIDE flag` (2) | **Yes** |
| G2 | **Medium** | **Keizer: expel a player and everybody who beat them loses the points for it.** The ladder is the players whose status is `active` (`Keizer.ladder_players/1`); a win pays the opponent's ladder value; an opponent off the ladder has none. The manual says of an expelled player that "the opponents keep the points and tie-breaks those games gave them" (chapter 5, after VCL4THP Q198). In Keizer they keep nothing, and the expelled player's row is gone. A player withdrawn with **Forfeit** stays on the ladder and is not affected. | Six players, Keizer, round 1; expel the loser of board 1: the winner's Keizer points go from 9 to 0. | `Keizer: an opponent who is expelled` (3) | **Yes** (2026-10-11, as proposed) - an expelled or status-withdrawn player who sat at a board stays in the pool that is ranked and valued; `compute_standings/2` leaves their row out and numbers the rest. One who left before ever being paired is not in the pool. |
| G8 | Low | **The results site cannot tell that a round-robin player's results are not counted.** The arbiter's Standings page prints `-` for the place and *withdrawn, not counted*. The snapshot sends the row last, with a place, with points the players above it do not have, and nothing to tell it apart; the other players' rounds add up to more than their rows say. G1's fix makes this case reachable from the Players page, so it will now be seen. | G1's event, published: P06's row is `{"rank": 6, "points": 2.0}` and nothing else. | `a round-robin player whose results are not counted (C.05 6.6)` (2) | **Yes** (2026-10-11) - `"uncounted": true` on the row, absent otherwise; the published tie-break working is built from the counted games (it listed the withdrawn player's games beside a total that left them out). OpenResults (branch `uncounted-rows`) shows the row without a place, muted, with a footnote in three languages, and leaves the games out of the other players' running scores. Contract fixture `snapshot_roundrobin_uncounted.json`. |
| G4 | Low | **Results site: a dash for the smaller category of a round robin with a table per category.** Part 1's F4 again, in the system it was not fixed for on the grounds that a round robin "seats everybody". With a Berger table per category the shorter table ends first; its players have no figure in the later rounds. | Categories of six and four, pair by category, pair all, publish: the four have nothing in rounds 4 and 5. | `the snapshot's per-round figures in a round robin` (2) | **Yes** - `not-paired`, 0 points, as for a Swiss. A round robin over one table publishes what it did. |
| G6 | Low | **SWAR export: an absence worth a full point leaves as half a point, and nothing says so.** SWAR's *Pt ABSENT* is a tick box (`TOptions.cpp`): half a point or nothing. `abs_value` 1.0 was written as the tick, and read back as 0.5. The line under the export button, which exists to list exactly this kind of thing, did not list it. | `abs_value` 1.0, export, import: 0.5, and a player's score is half a point lower per absence - in every synthetic round trip that paid one. | `an absence worth more than half a point, exported to SWAR's format` (2) | **Yes** - the note. The file is what it was. |
| G9 | Low | **A TRF26 with `?` in it has the standings' places beside its own points.** A postponed game is written `?` and scored at the file's own `X`, a draw - deliberately (`TrfExport.report_unknown/2`), so that the file adds up from itself. The place column is still the standings', which count the board as the win or the loss the tournament gave it. Only with a postponed valuation that is not a draw, which is already outside FIDE mode; the file sent for rating re-ranks (`rerank/2`) and is not affected. | 3-1-0, requester *win*, opponent *loss*; postpone board 1 by White, play board 2; export: places 1-2-3-4 beside points 1, 3, 0, 1. | `a TRF26 with an unknown result, the game counted as a win meanwhile` | **Yes** (2026-10-11, as proposed) - `rerank/2` runs when the file holds a `?` and a board in it is valued at anything but the file's draw (`valued_otherwise?/2`, read from the boards, where the valuation is frozen). `Ainalrami.Trf.parse/1` reads `?` and `Tiebreaks.rank/2` ranks the file at its `X`. Draw/draw files are not touched. |
| G10 | Low | **A norm in a round robin counts the game against an unrated player who scored nothing.** B.01 1.4.2 excludes "games against unrated players who score zero against rated opponents in round robin tournaments". Not implemented, not listed among the module's known omissions. Including the game usually helps the applicant (a point against an opponent raised to the rating floor), so this is the unsafe direction, in a rare event. | Ten players, one unrated who loses every game: the applicant has 9 counted games, the regulation 8. | `a norm in a round robin with an unrated player who scored nothing` (5) | **Yes** (2026-10-11) - the reading decided: the unrated player's points from games actually PLAYED are zero; a bye, a win by forfeit or any other unplayed award is not a score. `TitleNorms.scoreless_unrated/2`, individual round robins only. |
| G11 | Low | **A result lands on a board whose players somebody else has just changed.** `Tournaments.update_pairing_result/3` reads the warnings from the stored row (good) and writes onto the row whose id the caller holds, whoever sits there now. Between a co-arbiter's swap and this page's refresh, "1-0 on the board I am looking at" is recorded for two other players. Last write wins, silently, for results as well - that part is the design. | Pair; hold board 1; swap one of its players with a co-arbiter's click; write `1-0` with the held struct: `{:ok, _}`. | `a result entered on a board somebody else has just changed` (3) | **Yes** (2026-10-11, as proposed) - `{:error, :board_changed}` when the stored seats are not the caller's, nothing written; the Pairings page, the phone and the CSV import say so in words. Results stay last-write-wins. |
| G12 | Low | **Keizer on the results site: the rounds do not add up to the row.** The snapshot's per-round figures are the Swiss arithmetic (`Standings.bye_points_for_row/3`: an absence pays `abs_value`); the Keizer row's `score` pays an absence nothing. Only a Keizer tournament with *Points for a round sat out* set. | Keizer, `abs_value` 0.5, a player absent in round 2, published: rounds 1.5, score 1.0. | `Keizer` / `the snapshot's rounds add up to the Keizer row's score` (2) | **Yes** (2026-10-11) - decided the other way round from the guess here: Keizer has its own absence rule, so the snapshot stops sending `abs_value` for a Keizer event. A `byes` row is published at what the row's `score` gives it (`Keizer.raw_bye_points/2`). OpenResults needed no change: it adds up what it is sent. |

Twelve findings: 1 high, 4 medium, 7 low. Six fixed in the audit; the other
six (G2, G8, G9, G10, G11, G12) decided and fixed on 2026-10-11, branch
`audit-decisions`. None open.

### Format limits found on the way (not findings; part 1's F6 has company)

- **A TRF cannot say what a postponed game counts as meanwhile.** `?` is
  worth the file's `X`. A copy imported from it pairs on the draw where the
  original pairs on the win or the loss. 45 of 240 harness tournaments at
  some round; counted, not failed. In FIDE mode the valuation is a draw and
  the file is refused while a game is open, so there is nothing to lose.
- **A `.swar` file** does not hold Keizer (written as a Swiss), Baku, a
  point system other than SWAR's own outside its 3-2-1 type, a round
  robin's zero-point free round, or the withdrawn status. All but the last
  were already said under the export button; G5 and G6 are the two that
  were not.

### An observation that is not the app's

**O2.** `Ainalrami.Berger.round/4` applies `reverse_last_two?` to a single
cycle; `RoundRobin.schedule/4` ignores it there (C.05 Annex 1 recommends
the reversal for a double round robin only). They agree on everything the
app can ask for. Worth a guard in the engine, or a line in its doc.

## What the fixes ask of somebody else

- **G8 follows G1 out of the door** - and has (2026-10-11). The snapshot
  marks the row; OpenResults, from its branch `uncounted-rows`, reads the
  mark. An OpenResults that has not been upgraded shows what it showed: a
  last row with more points than the row above it. The contract fixture
  for it lives in OpenResults, so that branch merges first or this
  repository's drift check has nothing to compare with.
- **G5 was not opened in SWAR.** The code written (1) is the one the
  importer documents as SWAR's Forfeit and the one this app already wrote
  for the Forfeit tick; the round trip through this app's own importer is
  tested. Whether SWAR then keeps the player out of its next pairing is
  what the code means and was not watched happening.
- The pair-click golden did not change (`pair_click_golden_test.exs`
  passes untouched): its scenarios hold no round robin by category.

## What agreed

| | |
|---|---|
| **Berger tables.** `RoundRobin.schedule/4` against every round of every table C.05 Annex 1 prints (3 to 16 players: 63 rounds, each also for the odd size with the highest number as the bye) | all equal (probe, reading the Handbook text) |
| the same against `Ainalrami.Berger.round/4`, 2 to 30 players, one to three cycles, the reversed last two rounds of a double round robin | all equal (kept as a test) |
| a double round robin without the reversal: players with three games in a row of one colour, 4/6/8/10 players | 2 each; with it, 0 - the Annex's stated reason |
| **Team Swiss.** 4 events (7, 7, 8, 9 teams; custom bye points; 3-1-0 match points; initial colour Black), 4 rounds each: a round unpaired and paired again | the same matches, 16 of 16 |
| the next round of a JSON copy against the original's | the same, 12 of 12 |
| the snapshot's per-round match and game points against the team standings | equal for every team, byes included |
| **Postponed games in the harness**, 240 tournaments, 80 with postponed games allowed: boards postponed / played later / never played | 242 / 212 / 30 |
| an open postponed board in the standings against the valuation written out in the harness; the engine's score against the standings | no disagreement |
| the snapshot's `provisional` flag and count against the games open in the rounds it covers | no disagreement |
| rounds sent for rating, late games sent after; player-games played over the board in all files against the tournament's | equal, 80 of 80; 53 late files |
| JSON round trips, same next round | 372 of 372 |
| TRF round trips: same / the limits of part 1 / the postponed valuation (above) | 147 / 171 / 45 |

Read and found consistent, without a test of their own here:

- **What the team engine is told** (`TeamSwiss.engine_input/4`) against
  C.04.6 and `Ainalrami.TeamPairing.Team`: match and game points with the
  bye's draw (1.4) or the tournament's own bye points, opponents and
  colours of matches actually played (1.6.1, board 1's colour), the three
  ways into [C2], the float on the pairing and not the result (1.5),
  `absent` for teams that have arrived and sit out (4.3.1). The existing
  `team_flow_validation_test.exs` rebuilds exactly this from the final
  report on generated events and is the instrument for it; it was not run
  again (it is the heavy kind).
- **Team seeding** (`Tournaments.team_rating/3`, `team_seed_key/3`) against
  the Olympiad Pairing Rules 3.1 as quoted there: average of the
  `team_boards` highest ratings, then the next player's, then the name; an
  unrated player and an empty board at `team_unrated_rating`.
- **The C.05 6.6 arithmetic itself** once it is reached (completed games
  over the board, games due from the Berger table, strictly under half),
  and its twin for teams (`TeamStandings.annulled_team_ids/2`).
- **Norms**: the `dp` table, the rating floors and the single raise to the
  floor (1.4.6), 1400 for an unrated opponent, the rounding of the average
  and of the percentage (1.4.7, "0.5% is rounded up"), the titled-opponent
  counts and the double round robin's halving, the 3/5 and 2/3 maxima
  rounded down. A 9-round GM norm at average 2380 needs 7 (78%, +220) and
  at 2434 needs 6.5 (72%, +166), which is the published table.
- **The fill-once and round rules of the phone** apart from G7; the
  blank-over-a-result guard on the Pairings page; that
  `PostponedGames.result_warnings/2` reads the board as stored.
- **The Swiss match format and the last round** (part 1's suspicion): the
  engine is told `rounds_count` legs and pairs leg 1 of the last match as
  round n-1, so C.04.3's last-round relaxation for topscorers never
  applies. It has nothing to relax: after any complete match a player's
  last two colours differ and the colour difference is 0, so no absolute
  preference exists to be waived. The exception is a player with an
  unplayed leg; not tested, and not a finding.

## Postponed games in the harness

Every seed divisible by 3 creates its tournament with postponed games
allowed and a valuation taken off the seed (requester and opponent each a
draw, a win or a loss - one in nine is FIDE's draw/draw). About one board
in ten is then postponed, by White, by Black or by nobody named. Before
each pairing 40% of the open games are played, some days after their
round; at the end three quarters of what is left; the rest never.

On top of part 1's checks:

- the standings hold, for both players of every open postponed board, the
  value the tournament's setting gave it when it was postponed - worked out
  in the harness from the result code and the setting, never asked of the
  app - and the engine's input score equals the standings (part 1's check,
  unchanged);
- the snapshot's `provisional` and `postponed_games` are exactly the games
  open in the rounds its standings cover;
- at the end the rounds are sent for rating (`PostponedGames.send_rounds/4`,
  open games first reported as not played in this event, as the Export page
  has it), the games still open are played, the late games are sent a file
  per rating period, and the player-games played over the board in all the
  files together are counted against the tournament's boards: a game rated
  twice, or never, is a different number.

The rounds of such a tournament are not handed to `ainalrami -c`: they
were paired on a score that is not in the file.

## Not covered

Honestly:

- **Real SWAR files, and SWAR.** The `.swar` fixtures are not on this
  machine (55 tests excluded). Everything said about the Belgian format
  here comes from the code, its documentation, and files this app wrote
  and read back: 40 synthetic tournaments, every difference between the
  original and the copy traced to a limit the export already announces, to
  G5, to G6, or to the withdrawn status (which an arbiter cannot set).
  Nothing was opened in SWAR. Whether a file continued THERE pairs the
  round this app would is not something this pass can say.
- **Team events beyond the probes above.** No team fuzz was written. Not
  looked at: line-up changes after pairing (`TeamMatches.set_lineups/4`),
  `swap_home`, forfeits by decision, match scores entered as one figure,
  the team tie-breaks' values (they are Ainalrami's, checked there against
  FIDE's TieBreakServer), the `310`/`320`/`330` records, team round robin
  with a plugin's schedule.
- **The rating report beyond the harness's count.** The header records,
  the per-period rating fields, results corrected for rating only
  (C.04.2 4.3), and the receipts' "games as sent" were not read.
  `trf_flow_validation_test.exs` drives the whole Send flow with its own
  fixed-column reader; it was not run again.
- **FIDE-mode bookkeeping.** `Compliance` and the places that stamp
  `fide_compliance_lost_round` were read (settings through the changeset,
  the pairing's own deviations, a prohibition changed after round 1, "not
  played in this event", the JSON import's watermark); no path was found
  that departs without a stamp or stamps without a departure, and none was
  tested. A SWAR or TRF import arriving with a departing setting is judged
  by the settings, which is the design.
- **Pairing by category**: read, not tested. One thing an arbiter should
  know and the page does not say: a category of one player is given the
  pairing-allocated bye every round, a full point each time; no engine is
  asked, so the once-only rule is nobody's to apply.
- **Keizer's matcher** (repeats, the bye, colours): read against its own
  documented rules, not fuzzed. The ladder the pairing uses and the one the
  Standings page shows are one function (`recalculate/5`), so they cannot
  differ. Forfeited boards count as a meeting and as a White game for its
  purposes; documented nowhere, harmless.
- **Two arbiters at once, and double clicks.** The Pair button is guarded
  inside one page (`pairing_in_progress`), and two pages cannot both write
  round N: `rounds` has a unique index on tournament and number. The
  loser of that race raises instead of being told; not reproduced, so not
  a finding. Settings forms and their dirty tracker were not exercised.
  G11 is the one race that was.
- **Archived and handed-off tournaments.** The gates
  (`ensure_writable/1`, `write_refused/1`) are in every write path that
  was read for another reason; no sweep of all of them was made.
- **IT3, FA1, IA1, IT4 forms**: `Forms` was read. Two things noticed and
  not pursued: IT4's points column is the tournament's own scale (a 3-1-0
  event reports 3-1-0 points), and a Keizer event's IT3 says "Swiss".
- **The LiveViews as renderers.** As in part 1: a page that shows a right
  number wrongly is not something these tests can see.
