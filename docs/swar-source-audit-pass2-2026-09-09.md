# OpenPairings vs SWAR v6.65 FRBE — audit pass two

Date: 2026-09-10. Read-only. **Nothing in any repository was modified.**

**Pass one is
[swar-source-audit-2026-09-09.md](swar-source-audit-2026-09-09.md)**, and this
document continues it rather than replacing it — the two together are the tier
A pass. Where they disagree, this one is later and wins: §5.1 records pass one's
only real bug as fixed, §6.5 sharpens its F2, §6.2 settles the caveat its F4
left open, and §3 **reverses its F8 outright**. Pass one's findings are left
standing as written, with a forward pointer at its head, so the reasoning that
produced a wrong inference stays readable.

Sources:

* SWAR: `C:/Users/jorian/Downloads/Swar - 20250906 v6.65 FRBE/` (proprietary).
* OpenPairings: `C:/Users/jorian/Desktop/02cloud/VPS projects/openpairings`
  (branch `main`, 0.53.2).
* SWAR's own arbiter manual, `Docs/SWAR_Manuel_fr.odt`, read as text. This is
  documentation shipped with the program, and it settles one of the two biggest
  findings below by confirming that a code behaviour is deliberate and known to
  Belgian arbiters rather than a bug.

Scope: the rest of tier A after pass one's `Categories.cpp` — `Classement.cpp`
(read in full), `EnvoiJAVAFO.cpp` (read in full), `TournoiReadWrite.cpp`,
`XtraPoints.cpp` (read in full), and the parts of `Utils.cpp` pass one left.

**Licensing constraint observed.** Nothing below transcribes SWAR's
implementation. Quotations are single identifiers, single expressions, or
SWAR's own French comments and manual text, used only to establish a factual
claim about behaviour. No SWAR function is translated into Elixir anywhere in
this document and no recommendation amounts to copying one. Every
recommendation has the form "SWAR behaves like X; OpenPairings behaves like Y;
here is which the rules support, or that they do not decide it."

**VERIFIED** means read on both sides, at the cited lines. **INFERRED** means
read on one side and reasoned about, or dependent on a runtime path that cannot
be exercised without running SWAR. SWAR was never run.

---

## 0. Headline

Six things worth acting on, in descending order of how likely an arbiter is to
see them:

| # | What | Class |
|---|---|---|
| F9 | SWAR cuts **fewer** results than "Cut-1"/"Cut-2" names, by round count, and its manual says so | Divergence; OpenPairings follows C.07, SWAR follows a Belgian convention |
| F10 | Five SWAR tie-breaks that OpenPairings **can** compute are dropped on import, which silently promotes a different tie-break to primary | **Real defect in OpenPairings** |
| F11 | SWAR forces a round-robin bye to a **full point** at file-load time — pass one's F8 guessed the opposite | Import divergence; settles a pass-one inference |
| F12 | The Buchholz cut-suppression is now fully mapped, and it extends to **ARO-Cut1** with a much wider trigger | Map completed |
| F13 | SWAR's XtraPoints reach JaVaFo as `XXA` acceleration; OpenPairings drops that on import | Gap |
| F14 | The Elo-band extra-points rule runs in **opposite directions** in the two programs | Documentation gap, near-miss |

Pass one's one real bug (F1, `category_name/2` off by one) is **fixed** — see
§5.1. Two pass-one inferences are corrected (F2 sharpened, F8 reversed).

---

## 1. F9 — SWAR reduces the number of cut results by round count, and calls it Cut-1/Cut-2

**VERIFIED on three independent sources: SWAR's code, SWAR's own manual, and
OpenPairings' code.**

### What SWAR does

`TieBucholtz` (`Classement.cpp:1131-1286`) decides up front how many
contributions the cut/median variants will actually drop
(`Classement.cpp:1144-1154`):

* `DEP_BUCHOLTZ_CUT2` / `DEP_BUCHOLTZ_MED2`: `Delete = min((LastRoundWithResult - 1) / 4, 2)`
* `DEP_BUCHOLTZ_CUT1` / `DEP_BUCHOLTZ_MED1`: `Delete = min((LastRoundWithResult - 1) / 4, 1)`

With `LastRoundWithResult` = rounds played so far, integer division gives:

| Rounds played | Cut-1 / Median-1 drops | Cut-2 / Median-2 drops |
|---|---|---|
| 1-4 | **0** | **0** |
| 5-8 | 1 | **1** |
| 9+ | 1 | 2 |

`Delete == 0` makes the whole drop loop (`Classement.cpp:1276-1282`) a no-op, so
a tournament configured for **Buchholz Cut-1 shows plain Buchholz for its first
four rounds, and forever if it is a four-round event**. A **seven-round event
configured for Cut-2 never cuts more than one**, in the final standings.

### This is deliberate, not a bug

`Classement.cpp:1121-1125` attributes the scheme to "Luc" (Luc Cornet, the
KBSB's tie-break authority — `DocLocal/` carries two PDFs under his name) and
dates it to v3.93. SWAR's arbiter manual documents it to users, under footnote
`(**)` attached to all four variants in the tie-break table:

> `(**) Bucholtz Cut1 Cut2 Median1 Median2 Pour les rondes 1-4 : on enlève pas
> de résultats ni plus haut ni plus bas. Pour les rondes 5-8 : on enlève un
> résultat […] Pour les rondes à partir de la 9 : on enlève 2 résultats (BM2 et
> CUT2)`

and the table rows themselves say `On déduit 1 ou 2 résultats les plus bas
suivant le nombre de parties jouées` for Cut-2. Belgian arbiters using SWAR
have been told this is how it works.

### What OpenPairings does

`tiebreak("BHC1", …)` / `("BHC2", …)` / `("MBH", …)`
(`lib/pairings_engine/standings.ex:1117-1119`) call `cut/3` with a fixed
`n_lowest` of 1, 2, 1 and no round-count term anywhere; `cut/3`
(`:1356-1364`) and `drop_lowest_with_vur_priority/2` (`:1369-1381`) always
perform exactly that many drops.

### Which the rules support

**OpenPairings.** C.07's Cut modifiers (Art. 14.1.x) define Cut-1 as cutting
one and Cut-2 as cutting two. Nothing in the regulation makes the count a
function of the round number. SWAR is implementing a national convention on top
of a FIDE tie-break while keeping FIDE's name for it.

### Why this matters more than the absence-suppression finding pass one filed

The absence suppression (F3, pass one, and §4 below) only moves the number for
players who have an absence. **This one moves the number for every single
player in any event of eight rounds or fewer that uses Cut-2, and for every
player in any event of four rounds or fewer that uses Cut-1 or a median.** It
also moves the mid-tournament number in every longer event: a nine-round Swiss
on Cut-2 prints plain Buchholz after rounds 1-4, Cut-1 after rounds 5-8, and
Cut-2 only at the end. Belgian club and weekend events in the 5-7 round range
are exactly the population OpenPairings imports.

**Recommendation.** Do not change the calculation. Do write it down where an
arbiter will find it — `docs/swar-import.md` alongside the other
"your numbers will not match SWAR" notes — because "OpenPairings' Cut-1 column
disagrees with SWAR" is now a *predictable* report with a one-line answer, and
because the population it affects is far larger than the absentee population.
If a "Belgian tie-break" compatibility mode is ever wanted, this is its content
and it is a per-tournament display switch, not a change to the FIDE codes.

---

## 2. F10 — Five importable SWAR tie-breaks are silently dropped, and the drop promotes a different tie-break to primary (real defect)

**VERIFIED both sides.**

`swar_import.ex:1348-1355`:

```
# Only the six methods explicitly requested map to our codes; everything
# else (Koya, ARO, performance, black-piece stats, ...) is skipped.
@tiebreak_codes %{1 => "BH", 4 => "BHC1", 6 => "SB", 8 => "DE", 10 => "WIN", 7 => "PS"}
defp map_tiebreaks(codes) do
  codes |> Enum.map(&Map.get(@tiebreak_codes, &1)) |> Enum.reject(&is_nil/1)
end
```

The six existing mappings are all **correct** against `DEPARTAGES`
(`Swar.h:73-78`); I checked each ordinal. The comment is what is stale: five of
the "skipped" methods now have exact counterparts in
`PairingsEngine.Tiebreaks`' catalogue, all of them `available: true`
(`tiebreaks.ex:77-119`, `unavailable_codes/0` at `:169` holds only the three
team codes):

| SWAR ordinal | SWAR tie-break | OpenPairings code | Status |
|---|---|---|---|
| 2 | `DEP_BUCHOLTZ_MED1` | `MBH` (drop 1 high + 1 low) | unmapped — same definition |
| 5 | `DEP_BUCHOLTZ_CUT2` | `BHC2` | unmapped — **exact** |
| 9 | `DEP_KOYA` | `KS` | unmapped — **exact** |
| 12 | `DEP_ARO` | `ARO` | unmapped — **exact** |
| 13 | `DEP_ARO_CUT` | `AROC1` | unmapped — **exact** |
| 14 | `DEP_BLACK_PLAYED` | `BPG` | unmapped — near-exact (see below) |

Correctly unmapped, with no counterpart: `DEP_BUCHOLTZ_MED2` (3),
`DEP_PERFORMANCE` (11), `DEP_BLACK_WINNED` (15 — OpenPairings' `WON` is *games
won over the board*, not *games won with Black*).

### Why this is a defect and not a missing feature

`Enum.reject(&is_nil/1)` does not leave a hole, it **closes the gap**. A
tournament SWAR ranked on

    1. Buchholz Cut-2   2. Buchholz   3. Sonneborn-Berger   4. Koya

imports as

    1. Buchholz   2. Sonneborn-Berger

— a different primary tie-break, on a tournament whose prize list may already
have been decided on the first one. The player list, the results and the score
column all import faithfully; only the ranking rule quietly changes. Nothing on
screen says a tie-break was dropped: `dropped_tiebreaks_with_reasons/2`
(`standings.ex:127-141`) reports codes the tournament *stores* and this app
cannot compute, which is the opposite situation — these codes never reach
`tournament.tiebreaks` at all.

### FIDE

Not a FIDE question. This is purely "does the import agree with the file". It
does not.

**Fix shape** (not written — read-only pass): five entries in `@tiebreak_codes`
and a refreshed comment. Two caveats to fold into that comment rather than into
code:

* **`BPG` vs `DEP_BLACK_PLAYED`.** `TieBlackPlayed` (`Classement.cpp:415-425`)
  counts every round whose colour is Black once the player was actually paired,
  and its `v4.13` comment records that the "was it played" test was deliberately
  *removed*. OpenPairings' `BPG` requires `&1.played`
  (`standings.ex:1171-1173`). They differ for a forfeited Black game. C.07 Art.
  7.4 speaks of games played with Black; OpenPairings' reading is the literal
  one. Map it and note the difference.
* **The existing `10 => "WIN"` mapping is already inexact.** `TieVictoires`
  (`Classement.cpp:699-707`) counts `WIN` and `WIN_FF` and nothing else — a
  full-point bye is not a win. OpenPairings' `WIN` is C.07 Art. 7.1, which says
  "with or without playing" in the regulation's own words, so a bye worth a
  win's points counts (`standings.ex:1157-1160`, and the long comment above it).
  **OpenPairings is right and SWAR is narrower**; worth one line in
  `docs/swar-import.md` so it is not re-derived when someone compares columns.

---

## 3. F11 — SWAR forces a round-robin bye to a FULL POINT at load; pass one's F8 concluded the opposite

**VERIFIED both sides. This corrects pass one.**

Pass one's F8 said: "the forcing lives in the Options dialog's display path
only … nothing forces it at load or pairing time", and concluded that SWAR and
OpenPairings agree on a zero-point round-robin bye, fragilely.

Something does force it at load, and it forces the other value.
`TournoiReadStream` (`TournoiReadWrite.cpp:451-452`) runs unconditionally for
every round-robin file, immediately after reading `ByeValue`:

```
if (IsRobin(Tournoi.Type))
    Tournoi.ByeValue = (USE_POINTS)PTS_1;
```

`IsRobin` is `ROBIN || ROBIN_DBL || ROBIN_AR` (`Utils.cpp:538-540`). `PTS_1` is
a full point (`Swar.h:96`), and `ConvertPoint` (`Utils.cpp:1184-1195`) scores
any `RESULTATS_BYE` by `Tournoi.ByeValue`, returning 4 (= 1.0) for `PTS_1`.
`PairingRobin.cpp:236,295` writes `WIN_BYE` for the odd player. Net: **a
round-robin bye scores a full point in SWAR, from the moment the file is
opened.**

What `TOptions.cpp:569-583` does is different from what pass one read into it:
it sets `pTOptions->mTO_ByeValue = PTS_0` — a *dialog member*, not
`Tournoi.ByeValue`. That only reaches the tournament if the arbiter opens the
Options tab and the dialog writes back. So SWAR contains two contradictory
forcings, and **the load-path one is the one that always runs**.

### OpenPairings

`scoring_attrs/1` (`swar_import.ex:1300`) is
`%{bye_value: map_bye_value(t.bye_value)}` with no tournament-type branch, and
`map_bye_value/1` (`:1344-1347`) mirrors `USE_POINTS` faithfully. So a
round-robin `.swar` whose stored `ByeValue` is `PTS_0` imports as `0.0` while
SWAR itself shows `1.0` for the same file.

Separately and correctly, OpenPairings' *own* round robin writes a
`"requested-zero"` bye row (`round_robin.ex:61-67`) regardless of `bye_value` —
that is a deliberate documented choice and FIDE does not award a point for an
odd-player round-robin bye, so it stays right.

### Which the rules support

FIDE does not award a point for a round-robin bye, so OpenPairings' native
behaviour is the defensible one and should not change. But **the importer's job
is to reproduce the file's tournament, and for a round robin the file's stored
`ByeValue` is not what SWAR uses.** Either mirror the forcing in
`scoring_attrs/1` for `map_tournament_type(type) == "roundrobin"`, or warn.
Doing nothing means an imported round-robin's crosstable can differ from
SWAR's by one point per bye.

**Practical weight:** low frequency (odd-sized round robins imported from SWAR),
high visibility when it happens (a whole point).

---

## 4. F12 — The cut-suppression map, completed

Pass one asked for the full extent. It is:

### 4.1 Buchholz cut/median variants — suppressed by a *declared absence* only

`TieBucholtz`, two places:

* `Classement.cpp:1175-1178` — while accumulating the player's own
  unplayed-round correction, the **first** round with `r->Table == TABLE_ABSENT`
  is skipped entirely (contributes nothing instead of the player's own score),
  and `nbAbsent` counts every such round.
* `Classement.cpp:1275` — `if (Dep > DEP_BUCHOLTZ && nbAbsent == 0)` gates the
  whole drop-lowest / drop-highest block.

Extent, all VERIFIED:

* **Which tie-breaks.** Inside `TieBucholtz`, `Dep` can only be one of the five
  Buchholz ordinals, because `ComputeTieBreak` (`:1304-1309`) is the only
  caller and reaches it only through the `DEP_BUCHOLTZ*` cases. So
  `Dep > DEP_BUCHOLTZ` is exactly `{MED1, MED2, CUT1, CUT2}`. **Plain Buchholz
  is never affected** (it has no drop), and Sonneborn-Berger is a different
  function entirely and is not affected.
* **Which condition.** Only `r->Table == TABLE_ABSENT`. `Table` in SWAR is a
  *status for a player who was not paired at all this round*
  (`PairingSwiss.cpp:797`: `ABS_ABSENT → TABLE_ABSENT`, `ABS_FORFAIT →
  TABLE_FORFAIT`; `PairingSwiss.cpp:392`, `PairingRobin.cpp:306`,
  `PairingManual.cpp:404`: `TABLE_BYE`; `Joueur.cpp:593` initialises new round
  records to `TABLE_ABSENT`). So **a pairing-allocated bye does not suppress the
  cut, a withdrawal/forfeit-out does not suppress the cut, and a forfeited game
  at a real board does not suppress the cut.** Only a declared absence does.
* **Which players.** Per player, per tie-break evaluation. Everyone else in the
  same tournament still gets their cuts.
* **Interaction with F9.** In an event of four rounds or fewer nothing is cut
  for anybody, so the suppression is invisible there. It only bites from round 5.

### 4.2 ARO-Cut1 — suppressed too, by a much wider trigger (new)

This is the part pass one did not have. `TieAro(j, Cut1)`
(`Classement.cpp:335-382`) sets a flag `absOuBye = 1` in **four** situations
and then, at `:373`, performs the cut only `if (Cut1 == TRUE && absOuBye == 0)`:

1. `TestTableAbsentOrForfait(r)` — an unpaired round (absence or withdrawal);
2. `r->Advers <= 0` — no opponent;
3. `!(r->Result & RESULTATS_JOUES)` — a bye or **any forfeit result**, including
   one at a real board;
4. **`elo == 0`** — the opponent is unrated.

SWAR's own comment at `:329` states the rationale: a bye or absence is
"considered as cut1 already removed". So **for ARO-Cut1 the suppression is
triggered by byes and forfeits as well as absences, and additionally by having
faced a single unrated opponent.**

OpenPairings' `aro/3` (`standings.ex:1256-1270`) filters to `&1.played`, drops
`nil` opponents, sorts, and `Enum.drop(cut_lowest)` unconditionally. It has no
unrated special case *here* because C.07 Art. 10 is applied one level up:
`effective_tiebreaks/2` (`:95-97`) **drops ARO and AROC1 from the whole
tournament** when any unrated player is entered, and
`dropped_tiebreaks_with_reasons/2` reports why. That is a materially different
and better-documented answer to the same problem, and the moduledoc at
`:54-84` argues it at length.

**Which the rules support: OpenPairings, on both halves.** C.07 Art. 16 names
its own scope in its opening sentence — Buchholz, Sonneborn-Berger and their
variants — and ARO is not in it, so Art. 16.5.1's cut exception does not reach
ARO-Cut1 and there is no licence to skip the cut. And Art. 10's answer to an
unrated player is to drop the tie-break for the event, not to quietly exclude
that opponent from one player's average.

### 4.3 Nothing else suppresses

`TieSonneborn`, `TieKoya`, `TieCumulate`, `TieBetween`, `TieVictoires`,
`TieBlackPlayed`, `TieBlackWinned` and `TiePerf` have no cut and no
suppression. The map is complete.

---

## 5. Findings on the OpenPairings side

### 5.1 Pass one's F1 is FIXED — recorded so it is not re-reported

`category_name/2` (`swar_import.ex:1538-1549`) now reads
`div(cat_index, 100) - 1` with a `slot >= 0` guard and a second clause for an
index that carries only a second-axis component, under a twenty-line comment
that states the encoding and why the bug survived. `parse_categories/2`
(`:386-393`) also already carries the v6.50 `MAX_CATEGO` 12→16 layout change,
which is a genuine file-layout fork and would have shifted every field after
`[CATEGORIES]` in a pre-v6.50 file. Both correct. Nothing to do.

### 5.2 The legacy `CatIndex < 100` normalisation is missing (small, real)

**VERIFIED both sides.** `TournoiReadStream` normalises on the way in
(`TournoiReadWrite.cpp:623-624`): a stored `CatIndex` below 100 is multiplied
by 100. Old SWAR files stored the category as a small ordinal; current ones
store it scaled. `category_name/2` has no such step, so a legacy file's
`cat_index: 2` yields `div(2, 100) - 1 = -1` and falls into the
`_only_a_second_axis_component` clause, returning `""` — the player loses their
category, where SWAR shows `Value1[1]`.

Reachability is INFERRED: `TournoiReadStream:355` refuses files older than
`s_VersionCompatible`, so the window is bounded, and I could not date the
encoding change from the source. SWAR carries the normalisation because such
files circulate. Two lines to mirror it; worth doing at the same time as
anything else in that function.

The neighbouring self-validation (`TournoiReadWrite.cpp:626-630`: if
`GetCategorieValue(CatIndex)` renders empty, zero the player's category) is
already matched in effect — `Enum.at(…, "")` gives the same empty label — with
one difference: with `pair_by_category` on, OpenPairings would put every such
player in a `""` pool together, where SWAR puts them in no category. Worth a
line in the multi-category work rather than a change here.

### 5.3 `ExtraPts` is zeroed on load for round robin and 3-2-1 in SWAR, imported as-is here

**VERIFIED both sides.** `TournoiReadWrite.cpp:666-667` zeroes `p.ExtraPts` on
load whenever `IsRobin(Type) || IsSwiss321(Type)`; `EnvoiJAVAFO.cpp:642`'s own
comment says the same ("Les Swiss321 ne peuvent pas avoir d'eXtraPoints").
`swar_import.ex:1677` imports `extra_points: p.extra_pts / 4.0` unconditionally.

An imported 3-2-1 club league or round robin whose file still carries stale
`ExtraPts` — reachable if the tournament type was changed after extra points
were assigned, and not since re-saved — shows an XtPts column SWAR never
shows. With `count_extra_points` off (the default) the ranking does not move,
so this is display-only until someone turns the toggle on. Low probability,
one-line fix, and not a FIDE question.

### 5.4 F13 — SWAR's XtraPoints reach the pairing engine; OpenPairings' `extra_points` never can

**VERIFIED both sides. This is the largest of the extra-points findings.**

In SWAR, `ExtraPts` are an **acceleration** — `Swar.h:295` calls them "Extra
Points pour systèmes accélérés ou Swiss321" — and they act in two places:

* **Ranking.** `CalculLeClassement` sorts on
  `Joueur.Points + Joueur.ExtraPts + Joueur.SpecialPts` (`Classement.cpp:1425`),
  unconditionally. There is no opt-in.
* **Pairing.** `AssignExtraPointsNextRound` copies each player's `ExtraPts`
  into the round record (`XtraPoints.cpp:268-288`) and
  `EcrireXXA_AccelereManuel` (`EnvoiJAVAFO.cpp:601-634`) writes them as `XXA`
  lines in the `.trn`, so JaVaFo brackets by score-plus-acceleration. SWAR is
  explicit at `EnvoiJAVAFO.cpp:235-239` that this is *why* the extra points must
  not also go in the TRF points field — otherwise JaVaFo would count them twice.

In OpenPairings, `players.extra_points` is a **handicap bonus**:
`docs/extra-points.md` states "Pairing never counts extra points, regardless of
the toggle", and `tournament.acceleration` is `~w(none baku)`
(`tournaments/tournament.ex:6`) — Baku only, computed by
`Pairing.accelerations/3` from the roster, never from `extra_points`. The
importer parses SWAR's `[XTRA_POINTS]` band table into `data.xtra_points`
(`swar_import.ex:74,397-405`) and then never uses it.

So **a SWAR tournament that used manual acceleration will be paired differently
by OpenPairings than by SWAR**, silently: the acceleration disappears at the
import boundary, and the only trace is a per-player XtPts number that by default
does not even show.

FIDE does not decide this — C.04.5 permits accelerated methods, it does not
mandate any one. But the divergence is a pairing divergence, not a display one,
and there is currently nothing that tells the arbiter. **Minimum action: warn on
import when any player has non-zero `extra_pts` or the band table is populated.**
`category_warnings/1` (`swar_import.ex:1478-1500`) is the existing precedent for
exactly this shape of "we imported it, we cannot act on it" notice.

### 5.5 F14 — The Elo-band rule runs the opposite way in the two programs

**VERIFIED both sides.** Same shape, `threshold : bonus`; opposite comparison.

* **SWAR** (`AssignExtraPoints`, `XtraPoints.cpp:247-259`): a band matches when
  `EloUsed >= XtraPoints.Elo[i]` — rating **at or above** the threshold. Bands
  are sorted Elo-descending by `SortXtraPoints` (`:154-169`) and the first match
  wins, so the **strongest** players get the largest bonus. That is acceleration.
* **OpenPairings** (`Tournament.band_extra_points/2`, described in
  `docs/extra-points.md`): a band matches when the rating is **strictly below**
  the threshold, lowest matching threshold wins, so the **weakest** players get
  the bonus. That is a handicap.

Both are legitimate; they are not the same feature, and `docs/extra-points.md`
opens by calling the feature "SWAR parity #12". Nothing is wrong in the code —
but if anyone ever maps SWAR's `[XTRA_POINTS]` table onto `extra_points_bands`
(the obvious next step after §5.4), copying the numbers across would hand the
bonus to precisely the wrong half of the field. **Write the inversion down in
`docs/extra-points.md` now, while it is cheap.**

Two further SWAR facts about the model, for the same doc, both VERIFIED:

* `XtraPoints.Pts[i] = (int)(atof(txt) * 4.0)` (`XtraPoints.cpp:182`) — the
  band table is on the same ×4 scale as everything else, which is what
  `extra_pts / 4.0` at `swar_import.ex:1677` already assumes.
* SWAR assigns **once**, before any result exists (`AssignExtraPoints` returns
  immediately if `NbResult` is non-zero, `:230-234`), and after that the dialog
  swaps the Assign button for a Remove one (`:116-132`) that takes half a point
  at a time off players inside an Elo window (`:319-349`, `HALF_POINT` is 2 in
  the ×4 scale, `XtraPoints.h:33`). OpenPairings' "Apply bands to players"
  overwrites at any time, which is the more useful behaviour and is documented.
  Not a finding, but it is the reason SWAR's model has no "re-apply".

---

## 6. SWAR-side defects worth knowing (do not implement any of them)

These change SWAR's own numbers. They are recorded so a "your figure disagrees
with SWAR" report can be diagnosed in one step, and so nobody "fixes"
OpenPairings towards them.

### 6.1 F15 — SWAR's tie-breaks other than Buchholz/SB are on the wrong point scale in 3-2-1 tournaments

**VERIFIED (SWAR side).** In a 3-2-1 tournament a player's `Points` come from
`ConvertPoint321` (`Utils.cpp:1206-1223`), which returns `Tournoi.SW321_Win` etc.
— themselves stored ×4 of the arbiter's value (pass one, `TOptions.cpp:701-705`).
So under the Belgian Win 2 / Draw 1 / Loss 0 scheme a win is stored as **8**, not
the 4 that `ConvertPoint` (`Utils.cpp:1184-1195`) returns. Three tie-breaks
ignore that:

* **Koya.** `TieKoya` (`Classement.cpp:745-760`) sets the 50% threshold to
  `LastRoundWithResult * 2` — correct only when a win is 4 — and sums
  `ConvertPoint(r->Result)`, the classic scale, against `j2.Points`, the 3-2-1
  scale. In a 2-point-win event the bar sits at 25% of the achievable score and
  the sum is in a different currency from the threshold. **Both sides wrong.**
* **Cumulative/progressive.** `TieCumulate` (`:676-693`) also sums
  `ConvertPoint`, so the progressive column is computed on 1/½/0 while the score
  column is on 2/1/0. Internally consistent, but it is not the progressive score
  of the tournament that was played.
* **Buchholz cut/median.** The "lowest so far" sentinel is initialised to
  `ConvertPoint(WIN) * LastRoundWithResult` (`:1160`) — 4·R. In a 3-2-1 event
  contributions can exceed that, in which case no contribution is ever recorded
  as low and the subtraction at `:1277` removes 4·R, a value nobody contributed.
* **The adjusted-points increment.** `GetAdjustedPts` (`:1099-1109`) and
  `getBuchNonJouer` add `2` per trailing unplayed round — half a point on the
  classic scale, not half of `SW321_Nul`.

OpenPairings computes all of these in the tournament's own currency, and
`win_points/1` (`standings.ex:1033`) exists specifically so Art. 7.1 and Art.
9.2 compare like with like — see the long comments at `:1134-1156` and
`:1208-1232`, which already worked this out from first principles. **Where a
3-2-1 import's Koya, progressive or cut column disagrees with SWAR, SWAR is the
one that is wrong.**

One genuine open divergence inside that agreement, and it is a house choice
rather than a defect: SWAR's Koya threshold and comparison both exclude the
presence point (`Joueur.Points` never contains `SpecialPts`), while
OpenPairings includes it on both sides via `win_points/1`. Under a scheme where
turning up scores a point, "50% of the maximum possible tournament score" (Art.
9.2) plainly includes that point, so OpenPairings' reading is the literal one;
but the two bars land in different places and neither program is misreading its
own intent.

### 6.2 F16 — the opponent-exclusion rule compares a registration number against a seeding rank (settles pass one's F4 caveat)

**VERIFIED.** `TieBucholtz:1212-1223` drops an opponent from the Buchholz sum
entirely if any of that opponent's rounds is a forfeit result whose adversary is
this player. The test is `r->Advers == j1.Rank`.

`Advers` holds a player's `Ni` — that is what `FindJoueurNumber` matches on
(`Utils.cpp:836-845`, `if (Joueur.Ni == Ni)`). `Ni` and `Rank` are separate
fields of `JOUEUR` with different meanings: `Swar.h:272-273` labels them
"Numero inscription du joueur" and "Ranking calculé". Pass one flagged this as
"either a latent bug or they coincide often enough", INFERRED. It is now
VERIFIED as a genuine field mix-up: the two numbering spaces are only equal by
coincidence, and `Rank` is recomputed while `Ni` is not.

Consequence, INFERRED because it needs a run: when the comparison misses, the
forfeited game is counted **twice** in Buchholz — once as the player's own
unplayed-round correction (`:1181-1184` fires on `RESULTATS_NON_JOUES`, which
includes a forfeit at a real board) and once as the opponent's adjusted score
(`:1244`), because the skip at `:1195` only fires for rounds where the player
was not paired at all. When it hits, only the correction is counted.

OpenPairings has no such exclusion: `buchholz_contributions/3`
(`standings.ex:1281-1288`) contributes for every game record. I could not verify
a C.07 article that supports striking an opponent from the sum. **No change
recommended.** Pass one's recommendation stands, now on firmer ground.

### 6.3 F19 — Sonneborn-Berger: a full-point absence is credited at half

**VERIFIED (SWAR side).** `TieSonneborn` (`Classement.cpp:865-873`) handles an
absent round by taking a share of the player's *own* score. The draw branch
takes half. The win branch — reached when `GetSpecialAbsValue` returns `WIN`,
i.e. the absence is worth a full point — is written with the comment
`// on prend les points entièrement` ("we take the points in full") above an
expression that takes half. Comment and code disagree, and the code is the
wrong one.

Also in that function: `getSonnebornNonJouer` (`:773-790`) returns **0** for an
opponent with exactly one trailing absence and `nb * 2` (half a point per round,
classic scale) for two or more. So an opponent's single trailing unplayed round
gets no adjustment at all, where two get a full point between them.
OpenPairings' `adjusted_score/2` (`:1296-1318`) adds `points_draw` for every
trailing voluntarily-unplayed round with no special case at one — which is
Art. 16.3 as written.

Note also that SWAR uses **two different adjustment functions** for the two
families: `getBuchNonJouer` (`:1074-1091`, forward-scanning, returns 0/1) feeds
Buchholz via `GetAdjustedPts`, and `getSonnebornNonJouer` (backward-counting,
returns 0 or `nb*2`) feeds SB. They do not agree with each other. OpenPairings
uses one `adjusted_score/2` for both, which is what Art. 16.3 describes.

### 6.4 F20 — `TieBetween` groups on a different score from the one the standings sort on

**VERIFIED (SWAR side).** `TestJoueursEgaux` (`Classement.cpp:560-564`) puts two
players in the same direct-encounter group when `j1.Points == j2.Points` — raw
game points. `CmpCla` (`:1337`) ranks on `Points + ExtraPts + SpecialPts`
(`:1425`). In any tournament with acceleration or 3-2-1 presence points those
are different quantities, so SWAR can compute a "result between tied players"
for a set that is not tied in its own standings, and skip it for a set that is.

OpenPairings' `add_direct_encounter/2` (`standings.ex:1403-1431`) groups on
`rank_score/2` — the same number the sort uses, by construction. Not a FIDE
question (Art. 6 says "participants tied", and being tied is defined by the
ranking score); OpenPairings is self-consistent and SWAR is not.

The rest of `TieBetween` matches OpenPairings closely: both require every member
of the group to have met every other member before the tie-break is decisive
(SWAR checks it twice, `:618-624` by opponent count and `:630-644` by the
combinatorial count `Comb(n) = n(n-1)/2`; OpenPairings once, by
`MapSet.subset?`), and both fall through to the next tie-break otherwise. SWAR
additionally refuses the calculation for a player on zero points (`:578-579`),
which is unreachable in practice — two players cannot both have lost to each
other.

### 6.5 F21 — the *working* global-nationality exclusion exists and is dead code (sharpens pass one's F2)

**VERIFIED.** Pass one reported that `BuildAllNat` (`EnvoiJAVAFO.cpp:890-892`)
has an empty body, so selecting "global exclusion by nationality" produces no
`XXP` lines. That is right, and there is more to it: a correct implementation is
present in the same file. `EcrireExclusionGloNat` (`:784-788`) builds the
nationality list itself via `CreationCStringArrayGLO(saClu, 0)` and hands it to
`BuildXXPforCluOuNat`. So does its club twin, `EcrireExclusionGloClu`
(`:775-779`). **Neither is called from anywhere** — a repository-wide grep finds
only their definitions. The dispatch at `:964-974` instead uses the
`BuildAllClub` / `BuildAllNat` pair, of which only the club half was ever
written.

So the club exclusion works by accident of which of two parallel implementations
got wired up, and the nationality one silently does nothing. Unchanged
recommendation: do not calibrate any future OpenPairings club/federation
exclusion against SWAR's observed behaviour on the nationality axis. FIDE C.04
does not require same-federation separation in a domestic Swiss; OpenPairings
not having it is a gap, not a defect (`docs/forbidden-pairings.md`).

### 6.6 F22 — SWAR's manual describes a Virtual Opponent its code no longer uses

**VERIFIED.** `VirtualOpponent(MesPts, k)` is defined at `Classement.cpp:722-729`
and, per a repository-wide grep, **called from nowhere**. Since v6.49 SWAR uses
the dummy-opponent rule instead: `TieBucholtz:1183` adds the player's own score
for each unplayed round, with SWAR's own comment citing `(16.4)`.

The arbiter manual still describes the old model, under footnote `(*)`:

> `(*) V-O Depuis le 1er janvier 2016, certains départages pour les parties
> non-jouées sont calculés en générant un résultat d'un joueur virtuel (Virtual
> Opponent)`

and tags every Buchholz row and the Swiss SB row `V-O`. Anyone reasoning about
SWAR's numbers from its manual will reason about a model the program dropped.
Also stale in the same table: Buchholz is described as
`Somme des scores des adversaires ayant un classement ELO` ("…opponents who have
an Elo rating") — `TieBucholtz` performs no rating test at all. Relevant only as
a caution: **for these questions the source is authoritative and the manual is
not**, which is the opposite of the situation in §1, where the manual settled it.

OpenPairings arrived at the dummy-opponent rule independently and records the
same regulation text at `standings.ex:1320-1341`, including having *removed* a
virtual-opponent-style reconstruction that appeared nowhere in the regulation.
Both programs are now on Art. 16.4; only SWAR's documentation lags.

---

## 7. Checked and found equivalent (deliberately not findings)

Recorded so pass three does not re-derive them.

* **The TRF is renumbered into standings order in both programs, and this is
  already known and matched.** `EcrireClassementJAVAFO` (`EnvoiJAVAFO.cpp:204-260`)
  writes a sequential `Classement` counter into the starting-rank field and the
  seeding `Joueur.Rank` into the rank field, and opponent references use
  `j2.Class` (`:184`). `javafo_input/5`'s comment (`pairing.ex:2149-2167`)
  records that this was discovered against a real tournament and reproduced
  deliberately. Verified agreement; the TRF16 column offsets SWAR writes
  (5-8 / 10 / 11-13 / 15-47 / 49-52 / 54-56 / 58-68 / 70-79 / 81-84 / 86-89,
  rounds from 92) are spec-correct.
* **Presence points go in the TRF points field, extra points do not.**
  `EnvoiJAVAFO.cpp:250` writes `(Points + SpecialPts) / 4.0`; `:235-239` says in
  capitals why `ExtraPts` must be excluded. `standings.ex:945-950` already cites
  both lines. Exact agreement.
* **`XXP` semantics.** Confirmed again: `EcrireXXP` (`:691-703`) writes
  `j1.Class`/`j2.Class`, the standings number, and `:834` says so in capitals.
  Matches pass one's F7 and `docs/forbidden-pairings.md`.
* **The absence caps are off-by-one-correct on both sides.** `AbsentIsLoss`
  (`Utils.cpp` after `ConvertResult2TRN`) tests `ronde > (AbsJusque - 1)` on a
  **0-based** round; `round_capped?/2` (`standings.ex:570-571`) tests
  `round > cap` on a **1-based** round. Identical. `GetNbAbsence` counts
  `RoundIndex <= RndNi` — inclusive of the round being scored — and
  `absent_count_through_round/2` (`:699-707`) uses `b.round <= ^bye.round`.
  Identical. This is precisely the class of bug pass one asked me to hunt for,
  and here both sides are right.
* **The `= for a bye` quirk cannot reach OpenPairings.** `GetJavafoChar`
  (`EnvoiJAVAFO.cpp:164-174`) emits `0000 - =` for a half-point bye or a
  half-point absence, which is not a TRF non-playing code (`=` is a *played*
  draw, and `Ainalrami.Trf`'s `@playing_codes` at `trf.ex:506` agrees). But this
  is confined to the JaVaFo `.trn`, which OpenPairings never reads. SWAR's FIDE
  report writes the canonical codes — `0000 - U`, `0000 - H`, `0000 - Z`
  (`EnvoiFIDE.cpp:456-481`) — so a TRF exported from SWAR and imported here is
  safe. Not a finding.
* **Progressive score.** `TieCumulate`'s weight-by-remaining-rounds formulation
  is algebraically the sum of running totals, which is what `tiebreak("PS", …)`
  computes directly. Same number (modulo §6.1's scale issue in 3-2-1). SWAR
  additionally returns 0 for round robin by choice (`:678-679`); OpenPairings
  computes it. FIDE does not forbid either.
* **Koya reads the opponent's raw score in both programs.** SWAR compares
  `j2.Points`, never `PointsAdjusted`; OpenPairings reads `opp.points` and its
  comment at `standings.ex:1223-1232` explains that Art. 16's scope sentence
  excludes Koya. Independent agreement on a point a sweep once filed as a
  suspected bug.
* **`AbsentThisRound`** (`Utils.cpp:2267-2277`) — an `ABS_ABSENT` player with a
  non-empty `AbsentRondes` list is PRESENT for any round not in the list. Already
  reproduced and commented at `swar_import.ex:1562-1569`. Exact match.
* **`@tiebreak_codes`' six existing entries are all correct** against
  `DEPARTAGES` (`Swar.h:73-78`). Only the omissions are wrong — §2.
* **`MAX_CATEGO` 12→16 at v6.50** is handled (`swar_import.ex:389`), and so is
  `PointsAdjusted`'s v6.49 arrival (`:55-56`, `:444-448`).

### One divergence I looked at hard and am NOT calling a defect

`dummy_score/2` (`standings.ex:1339-1341`) is only ever reached for a round with
no opponent, so a **forfeit win against a scheduled opponent** contributes that
opponent's adjusted score rather than the participant's own. C.07 Art. 16.4.1
caps a forfeit-win dummy at the scheduled opponent's adjusted score, which reads
as a *minimum* of the two rather than the opponent's value outright. SWAR takes
the player's own score, uncapped (`Classement.cpp:1183`).

I could not read C.07's actual text this pass — `DocLocal/20240801 TieBreak
FIDE.pdf` is image-only and has no extractable text — so I will not call a
defect on a regulation I have not read, especially against a module whose
comments show the text was read carefully at the time. **Flagging it as the one
thing in `standings.ex` I would want a second reading of, with the regulation
open**: the case where it bites is a low scorer forfeit-winning against a high
scorer, which is rare but is exactly the shape that produces a surprising
Buchholz.

---

## 8. What is left in tier A

Pass one estimated tier A at ~2.5 focused sessions and prescribed five items.
Items 1, 2, 3 (partly), 4 and 5 are now done. Revised remainder:

| Item | State | Estimate |
|---|---|---|
| `Classement.cpp` | **Done, read in full.** Every tie-break, `CmpCla`, `VirtualOpponent`, the adjusted-points machinery. | — |
| `EnvoiJAVAFO.cpp` | **Done, read in full.** `EcrireClassementJAVAFO`, `EcrireRondesJAVAFO`, `EcrireLesAbsents`/`XXZ`, all three `XXA` writers, the exclusion dispatch. | — |
| `XtraPoints.cpp` | **Done, read in full.** | — |
| `TournoiReadWrite.cpp` | **Done for the parts that matter** — both the write and the read of `[TOURNOI]`/`[DATES]`/`[TIE_BREAK]`/`[EXCLUSION]`/`[CATEGORIES]`/`[XTRA_POINTS]`/`[JOUEURS]`/`[RONDE]`, and the load-time forcings. The `ReadStr`/`ReadInt` primitives themselves were not read. | ~0.1 session if anyone ever wants the primitives |
| `Utils.cpp` | **~60% done.** Read: `FindJoueurNumber`, `GetElo` ×3, `ConvertPoint`, `ConvertPoint321`, `GetPoints`, `GetSpecialAbsValue`, `GetNbAbsence`, `AbsentIsLoss`, `AbsentThisRound`, `Format1Decimale`, `ConvertResult2TRN`, the type predicates. **Not read:** the `ConvertResult2*_TRNfile` family (three per-destination result encoders), `GetSpecialByeValue`, `GetLastRoundWithResult`/`GetFirstRoundOnlyPairing`, the `Format*`/`Write*` display helpers, the ~900 lines of description/CSV writers. | **~0.4 session**, and the only part with real yield is the `ConvertResult2*` family plus the two round-horizon functions |

**Remaining tier A: roughly half a session**, all of it in `Utils.cpp`, and of
that only two pockets are likely to return anything arbiter-visible:

1. **`ConvertResult2FIDE_TRFfile` / `ConvertResult2FRBE_TRNfile` /
   `ConvertResult2JAVAFO_TRNfile`.** Three encoders for the same result set,
   against `Ainalrami.Trf`'s code table and `PairingsEngine.Results`. This is
   exactly where the historical `AbsValue` mis-scale and the handicap-table
   board bug both lived, and §7's `=`-for-bye discrepancy shows the three
   encoders already disagree with each other.
2. **`GetLastRoundWithResult` and `GetFirstRoundOnlyPairing`.** Every tie-break
   in `Classement.cpp` is bounded by the first of these, and OpenPairings'
   `completed_rounds/2` (`standings.ex:482-492`) is a deliberately-chosen third
   horizon with a documented history of being wrong. Whether SWAR's horizon is
   "rounds with at least one result" or "rounds with all results" decides
   whether the two programs' mid-tournament Buchholz can agree at all. Half an
   hour, and it is the highest-value unread function in the tier.

Then tier A is closed. Tier B remains not worth a scheduled pass, for the
reasons pass one gave.

---

## 9. Documentation the maintainer may want to update

Not done here — this pass wrote nothing into the repository.

**Filing note, 2026-09-10.** Three of the six are now done, in the same pass
that filed this document:

* `docs/swar-import.md` has a section on **F9 and the absence/ARO cut
  suppression** — the two divergences an arbiter will actually see, written for
  someone answering a support question rather than for a reader of this audit.
  The other three items in that bullet (F11, the `WIN` bye difference, the
  3-2-1 Koya threshold) are named there in a closing paragraph but not written
  up; they are still owed a paragraph each if anyone reports them.
* `docs/swar-source-audit-2026-09-09.md` carries a forward pointer at its head
  naming the four findings that moved, rather than an errata block at its foot.
  Same intent, seen sooner.
* `TODO.md`'s audit entry is cut down to §8's remainder, and the duplicate
  scoping entry in the backlog is retired.

**Still owed:** `swar_import.ex`'s stale `@tiebreak_codes` comment,
`docs/extra-points.md`, `docs/acceleration.md`.

* **`docs/swar-import.md`** — F9 (the round-count cut degradation) belongs
  beside the existing "numbers will not match SWAR" notes, and is more
  important than the absence-suppression note already planned from pass one's
  F3. Also: F11 (round-robin bye forced to a full point), the `DEP_NB_VICTOIRES`
  vs `WIN` bye difference (§2), and the 3-2-1 Koya-threshold divergence (§6.1).
* **`swar_import.ex:1348`** — the `@tiebreak_codes` comment is stale; five of
  the six methods it calls "skipped" now exist. §2.
* **`docs/extra-points.md`** — the band comparison is inverted relative to
  SWAR's (§5.5), and SWAR's extra points reach the pairing engine while
  OpenPairings' cannot (§5.4). Both are one paragraph.
* **`docs/acceleration.md`** — record that SWAR's manual acceleration has no
  OpenPairings counterpart and is dropped on import.
* **`docs/swar-source-audit-2026-09-09.md`** — F1 is fixed (§5.1), F2 is
  sharper (§6.5), F4's caveat is settled (§6.2), and **F8's conclusion is
  wrong** (§3). Worth a short errata block rather than editing the findings in
  place, so the reasoning that produced the wrong inference stays readable.
* **`TODO.md:1022`** — the `Classement.cpp` / `Utils.cpp` audit line can be cut
  down to the §8 remainder.
