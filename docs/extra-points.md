# Extra points (XtPts)

SWAR parity #12: players can hold points on top of their game points - SWAR
calls them "XtPts". They are set per player on the Players page, by
Elo-band auto-assign on the Extra points settings page
(`/t/:id/settings/extra-points`, `PairingsEngineWeb.ExtraPointsLive`), by a
SWAR import, or by a TRF26 import (`299` records).

What they are FOR is the tournament's `extra_points_mode`. There are two,
because the same number means two different things in the two programs this
app is measured against:

| | **Handicap** (`"handicap"`, the default) | **Acceleration** (`"acceleration"`) |
|---|---|---|
| What it is | A head start for weaker players | SWAR's XtraPoints: stronger players meet each other sooner |
| Bands pay players | **below** a rating | **at or above** a rating |
| Pairing | on points + extra points, **while counted** | on points + extra points, **always** |
| Standings | points + extra points **while counted** | points + extra points only if "Keep acceleration points in the final standings" |
| The toggle (`count_extra_points`) | "Count extra points (standings and pairing)" | "Keep acceleration points in the final standings" |
| FIDE TRF report | game points in `001`, the points in `299`; **no** `250`/`XXA` | game points in `001`, `250` records (and `299` while kept) |
| SWAR export | `ExtraPts` only while counted; bands not written | `ExtraPts` always; bands written as SWAR's table; each round's `XtraPts` |

Both modes use one column, `count_extra_points`, and it keeps one meaning in
both: "the standings rank on points plus extra points". Every surface that
shows a score - `Standings.rank_score/2`, the Standings page's XtPts/Total
columns, printed standings and cross tables, the results-site snapshot, the
SWAR and TRF exports - reads that and nothing else. Which of the two modes
also feeds the pairing is `Tournament.extra_points_pairing?/1`.

## How the pairing sees them: virtual points (`XXA`)

The engine is handed the extra points as **virtual points** - TRF's `XXA`
extension, the same mechanism Baku acceleration uses
(`docs/acceleration.md`): one value per player per round, added to the
player's score when the engine builds the score groups. Ainalrami reads it
(since `451c749`, which adds
`accelerations[round]` to every score the pairing reads, float history
included). The TRF's own points column (`001`, columns 81-84) stays game
points: an engine reconciles that column against the games it holds
(`Ainalrami.Pairing.reconciled_points/2`, a port of bbpPairings'
`trf.cpp:885-925`), and a total that includes a head start reconciles to
nothing - the engine would fall back to the stored value and every historic
score behind the float criteria would be wrong. `XXA` is the channel the
engines define for exactly this.

`Pairing.accelerations/3` builds the history, one value per round
1..current:

- a round already paired gives the value that round was paired with, from
  `rounds.virtual_points` (`%{"player id" => points}`, non-zero entries
  only; a player missing from it had none);
- a round paired before that column existed (or by hand) records nothing
  and reads the player's current extra points - the closest answer there is;
- the round being paired, which has no row yet, is the player's current
  value.

The history matters. The engine judges a float by the two players' scores
AS THEIR BRACKETS SAW THEM in that round, virtual points included - which is
why the FIDE Dutch engines need "the full record of the fictitious points
assigned round by round". SWAR does the same: each round's `ROUND.XtraPts`
is frozen when the round is set up (`InitNextRonde`,
`AssignXtraPointsManuels`) and `EcrireXXA_AccelereManuel` writes them all.
So `create_round/6`, `insert_category_round/4` and the mirrored second leg
of a match-format round each record what they were paired with
(`Pairing.virtual_points_used/2`).

A player whose whole history is zero gets no `XXA` line, so a tournament
where nobody holds extra points hands the engine exactly the file it always
did. `order_for_pairing/4` sorts the rows by points plus this round's extra
points too, as SWAR sorts its `.trn` by its own standings.

Virtual points go to one decimal in `XXA` (`Ainalrami.Trf`'s
`format_points/1`), so a quarter point pairs as the nearest tenth. SWAR's
own values are whole and half points.

Virtual points are never negative. A negative extra point - a penalty -
still counts in the standings when they count, but it goes to the engine as
zero: the fixed-column `XXA` field cannot carry a negative value (JaVaFo,
measured on a real SWAR file with a -1.0 in one round, failed with
`NumberFormatException: For input string: "0-1.0"`). A
round's recorded value is kept as it came (a SWAR import can bring a
negative one, and the export writes it back); the floor is applied on the
way to the engine (`Pairing.virtual_value/1`).

## Handicap

The head start this feature was first built for. Off - the default - the
points do nothing anywhere: `extra_points` can be set on players without any
effect on standings or pairing. On, they count everywhere: the standings
rank on the total, and the pairing groups on the same total, so the score
groups are the standings' own. A player given a point and a half who loses
round 1 still leads the field on the total, and meets the round-1 winners
chasing it, not another loser (`test/pairings_engine/extra_points_pairing_test.exs`).

Until 2026-09 pairing never saw a handicap, and a counted one produced
standings the pairing contradicted. Counting now puts it in the pairing as
well; turning counting off removes it from both.

The FIDE report does not carry a handicap as virtual points: `001` is game
points, the handicap goes in TRF26's `299` (free points) while it counts,
and `Pairing.accelerated_rows/4` leaves it out of `250`/`XXA`. A pairing
checker replaying the file therefore sees the rounds as paired on game
points - which a handicap event, by definition, was not. That is the
trade-off chosen: the official report states results, not house rules.

## Acceleration

SWAR's XtraPoints, as SWAR uses them: every round the points go to the
engine, so the stronger players - the bands pay at or above a rating - start
in a higher score group and meet each other from round 1. With the four
strongest of eight given a point, round 1 pairs 1-3, 2-4, 5-7, 6-8 instead
of 1-5, 2-6, 3-7, 4-8.

"Keep acceleration points in the final standings":

- **on** - SWAR's behaviour: `CalculLeClassement` ranks on `Points +
  ExtraPts + SpecialPts` (`Classement.cpp:1425`), so the points still held
  at the end count. A SWAR import sets it on when the file gives anyone
  extra points.
- **off** - like Baku: the standings are game points only, and the points
  exist for the pairing alone.

**Winding it down.** SWAR's "Remove" button takes half a point off every
player in a rating range who still has some (`XtraPoints.cpp`,
`OnBnClickedXtraButtonRemove`). "Remove half a point" on the Extra points
page is the same (`Tournaments.reduce_extra_points/4`): from/to rating, half
a point each, never below zero, audited as `standings.extra_points_reduced`.
The next round is paired with what is left; rounds already paired keep
their recorded values. Editing a player's value on the Players page works
the same way, one player at a time.

Baku and extra points in the pairing are not combined: both are one `XXA`
value per player per round, and no rule says how Baku's Group A and a
player's extra points add up. The changeset refuses Baku while the extra
points feed the pairing (acceleration mode, or a counted handicap) and the
other way round (`Tournament.validate_extra_points_excludes_baku/1`); a row
that reaches the database holding both some other way pairs on Baku alone.
Pairing by category and match format are allowed: each category's file
carries the whole roster with each player's own values, and a second leg
records its first leg's values.

## Elo bands

`extra_points_bands` is a comma-separated list of `"threshold:bonus"` pairs.
The stored string is re-normalized on every save (trimmed, sorted ascending
by threshold, integer bonuses without a decimal point), and malformed input
is rejected with a changeset error. `Tournament.band_extra_points/3`:

- **Handicap - below the rating.** A rated player matches every band whose
  threshold is strictly above their rating; the lowest such threshold wins.
  `"1400:1, 1600:0.5"`: 1350 gets 1.0, 1550 gets 0.5, 1700 nothing. An
  unrated player (rating 0) only matches an explicit `0:bonus` band.
- **Acceleration - at or above the rating.** A player matches every band
  whose threshold is at or below their rating; the highest such threshold
  wins - SWAR's rule (`AssignExtraPoints`: bands sorted by Elo descending,
  the first with `EloUsed >= Elo` wins). `"1800:0.5, 2000:1"`: 2100 gets
  1.0, 1900 gets 0.5, 1700 nothing. A `0:bonus` band matches everybody
  else, unrated players included. (SWAR's own table stops at an Elo-0 slot
  and never pays it, so the SWAR import leaves such a slot out.)

"Apply bands to players" (`Tournaments.apply_extra_points_bands/1`)
overwrites every player's `extra_points` with the saved mode's band result,
including `0.0` for anyone who matches nothing, so a re-run always reflects
the current rule. It is a manual button, never triggered by saving the bands
or by a rating change. The page's wording follows the mode chosen in the
form before it is saved; "Apply" uses the saved mode and bands.

## Where else they show

- **Standings** (`PairingsEngine.Standings`): every entry carries `points`,
  `extra_points` and `total`; ranking uses `rank_score/2`. FIDE tie-breaks
  always use opponents' game `points`.
- **Standings page, printed standings and cross tables**: XtPts and Total
  columns while the standings rank on them.
- **Results-site snapshot** (`PairingsEngine.Snapshot`): standings rows of
  a tournament that ranks on extra points carry two additive fields,
  `extra_points` and `total` (the score the order is by). Absent otherwise,
  like `rounds_played`. Not `score`, which a Keizer row already uses. The
  OpenResults repo does not read them yet; nothing breaks without them.
- **Pairing explanation** (`PairingsEngineWeb.PairingExplainLive`): a round
  that recorded virtual points says so above the boards, and its brackets
  are explained on game points plus those (`PairingRationale`); a Baku
  round within the accelerated span says so too.
- **JSON backups and restore points** carry `extra_points_mode` and each
  round's `virtual_points`, re-keyed to the new players on import. A backup
  written before the mode existed gets the migration's rule on import.
- **SWAR** (`docs/swar-import.md`): a SWAR file imports in acceleration
  mode, its band table as the bands, and each `[RONDE]` record's `XtraPts`
  as that round's recorded virtual points; the export writes all three back.

## Checked against SWAR (2026-09-27)

Six real SWAR files carry XtraPoints (they are real events and are never
committed). Each round of five of them was replayed by hand through the app -
import, unpair from that round on, give every player the `XtraPts` SWAR
froze into that round, mark absent everyone SWAR did not pair, pair it here,
and compare the boards with SWAR's - once in acceleration mode and once
with extra points kept out of the pairing (the old behaviour):

| event (anonymised) | rounds with XtraPts | boards equal, acceleration | boards equal, without |
|---|---|---|---|
| A - bands, 52 of 101 accelerated for two rounds | 1-2 | 48/48, 49/49 | 0/48, 2/49 |
| A, the rounds after (history only) | 3-5 | 49/49, 48/48, 48/48 | 47/49, 41/48, 48/48 |
| B - bands, 138 of 201 | 1-3 | 95/98, 91/100, 46/93 | 0/98, 0/100, 6/93 |
| C - bands, 101 of 209 | 1 | 68/93 | 0/93 |
| D - one late entrant given a point | 2-9 | 22/22 (rounds 2-5), 17, 14, 18, 22 of 22 | 14, 13, 17, 13, 14, 13, 19, 17 of 22 |
| E - one player given a point | 2-9 | 34/44, then 44/44 or 42/42 ... 41/41 | 24/44 ... 37/41 |

Acceleration mode reproduces SWAR where the old behaviour could not, and
the rounds after an acceleration was removed (A, rounds 3-5) show the
per-round history at work: the floats are judged on the scores the
brackets had. D's rounds 6-8 still differ; C from round 2 on (nobody holds
extra points any more) and a sixth file's last two rounds (whose only
XtraPts are negative, which go to the engine as zero) differ just as much
in both modes, i.e. for reasons that are not extra points - a re-paired or
hand-edited round in the file, most likely.

`tools/swar_rerank.exs` over the six files ranks as before: the standings
code did not change, and the two finished events rank 129 of 135 places as
SWAR does, every remaining difference one of SWAR's documented tie-break
departures.

## Existing tournaments (migration `20260927160856`)

The column arrived with every tournament as "handicap" except a SWAR
tournament that uses extra points: a SWAR guid or SWAR's own settings, no
bands of this app's own (the SWAR import never writes `extra_points_bands`,
and the export gives a native tournament a guid too), and the toggle on or
some player holding extra points. Those became "acceleration", which is what
SWAR did with them. Their rounds paired before the upgrade have no recorded
virtual points and read the players' current values.

## FIDE compliance

Extra points in the pairing - acceleration mode, or a counted handicap -
are not what the FIDE rules pair. No setting shows it, since acceleration
mode changes nothing while nobody holds points, so the pairing marks it:
the first round in which extra points reach the engine (a player in the
round holds some, or an earlier round's recorded points are in the `XXA`
history) is stamped as `fide_compliance_lost_round`, and the Pairings page
writes a `tournament.fide_compliance_lost` audit row with setting
`extra_points_pairing` and code `extra_points_acceleration` or
`extra_points_handicap` (`Pairing.pairing_deviations/2`). Nothing is
recorded while nobody holds any. Baku is FIDE's own (C.04.7) and is never
marked. The Extra points page shows the warning whenever the form puts
extra points in the pairing.

## Not here

- A pairing checker replaying the FIDE report of a counted-handicap event
  sees game-point pairings (see Handicap above).
- SWAR's automatic accelerated Swiss (type 2, `EcrireXXA_AccelereAuto`) is
  not this: it gives points to groups by the size of the field. It imports
  as a plain Swiss, with its per-round values as history.
