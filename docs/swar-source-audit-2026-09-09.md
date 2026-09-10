# OpenPairings vs SWAR v6.65 FRBE — audit pass one

Date: 2026-09-09. Read-only. Nothing in any repository was modified.

**Pass two is
[swar-source-audit-pass2-2026-09-09.md](swar-source-audit-pass2-2026-09-09.md)**,
and it carries out §7's programme apart from item 3 (a fixture with a non-zero
category type), which is repository work rather than reading. Read it before
acting on anything below, because four findings here have moved:

* **F1 is FIXED** in 0.53.0 — pass two §5.1.
* **F2 is sharpened.** The nationality exclusion is dead code, and a *working*
  implementation sits unwired beside it — pass two §6.5.
* **F4's caveat is settled.** The `Advers`/`Rank` comparison is a genuine field
  mix-up, not a coincidence — pass two §6.2.
* **F8's conclusion is WRONG.** SWAR forces a round-robin bye to a full point at
  file-load time, which is the opposite of what F8 inferred from the Options
  dialog — pass two §3.

Nothing below has been edited to match. A finding that was reasoned carefully to
a wrong answer is worth more intact than corrected in place, because the failure
was in the method (a dialog path read as if it were the only one), and that is
only visible if the reasoning stays.

Sources:

* SWAR: `C:/Users/jorian/Downloads/Swar - 20250906 v6.65 FRBE/` (135 `.cpp`/`.h`, 74,234 lines).
* OpenPairings: `C:/Users/jorian/Desktop/02cloud/VPS projects/openpairings` (branch `main`, 0.51.0).

**Licensing constraint observed.** SWAR is proprietary. Nothing below transcribes
its implementation. Quotations are single identifiers, single expressions, or
SWAR's own French comments, used only to establish a specific factual claim about
behaviour. No SWAR function is translated into Elixir anywhere in this document,
and no recommendation here amounts to copying one. Every recommendation is of the
form "SWAR behaves like X; OpenPairings behaves like Y; here is which the rules
support" — which is comparison, not derivation.

**VERIFIED** below means: read on both sides, in the cited files, at the cited
lines. **INFERRED** means: read on one side and reasoned about, or dependent on a
runtime path that cannot be exercised without running SWAR. SWAR was never run.

---

## 1. What a complete file-by-file audit would cost

`TODO.md:957-976` already carries a scoping estimate (~14 files / ~15,600 lines /
~490 functions, "genuinely multiple days"). Having now read a representative
slice, that estimate is **roughly right on line count and materially wrong on
shape**: the comparable surface is smaller than 15,600 lines, and the cost is
dominated by a handful of dense files rather than spread evenly.

Measured audit surface (`wc -l`, SWAR side):

| Tier | Files | Lines | Why |
|---|---|---|---|
| **A — dense, genuinely comparable** | `Classement.cpp` (1,455), `Utils.cpp` (2,474), `Categories.cpp` (1,192), `EnvoiJAVAFO.cpp` (1,025), `TournoiReadWrite.cpp` (702), `XtraPoints.cpp` (348) | **7,196** | Scoring, tie-breaks, shared edge-case predicates, SWAR's own TRF builder, the file format, acceleration. Every finding in this document came from tier A. |
| **B — comparable but mostly plumbing** | `Pairing.cpp` (848), `PairingSwiss.cpp` (1,109), `PairingRobin.cpp` (750), `PairingManual.cpp` (452), `ImportTrfFile.cpp` (899), `ImportCsv.cpp` (1,474), `Tournoi.cpp` (1,116), `TOptions.cpp` (998), `Joueur.cpp` (1,601) | **9,247** | Real logic exists here, but 60-80% of each file is MFC dialog wiring (`DoDataExchange`, `DDX_*`, message maps, `EnableWindow` cascades) with no OpenPairings counterpart. |
| **C — excluded, verified as no-logic** | `RoundRobinInfo.cpp` (69), `ExcludePairing.cpp` (~150), `RankingMethode.cpp` (79) | 298 | Read in full this pass. `RoundRobinInfo.cpp` is a static-text dialog. `ExcludePairing.cpp` is a read-only list view — it renders `TOptions`' exclusion text, it does not implement exclusions. Both are on the TODO's implied list and should come off it. |
| **D — out of scope** | `PairingAmericain.cpp` (295), the ~50 UI/vendored files, `Curl/`, `Html/`, `PRINTsrc/` | ~44,000 | American system dropped from the roadmap; the rest is UI and vendored libraries. |

**Cost estimate for a complete pass**, calibrated against this one (this pass read
~3,500 lines of SWAR closely plus targeted greps across the rest, and ~1,200 lines
of OpenPairings, in roughly one working session, and produced 8 findings):

* **Tier A alone: ~2.5 focused sessions.** ~7,200 lines, but every line needs the
  OpenPairings counterpart open beside it. This is where the yield is — 8 of 8
  findings this pass, and both historical real bugs (`docs/swar-import.md`'s
  `AbsValue` mis-scale, `TODO.md:930`'s handicap-table boards) also came from tier
  A files.
* **Tier B: ~2 further sessions, low expected yield.** Skimmable at maybe 4x the
  rate of tier A because the dialog wiring is recognisable at a glance, but the
  logic islands are scattered and easy to miss precisely because they are
  surrounded by noise.
* **Total: 4-5 focused sessions** for the item as written, of which the last two
  are likely to return nothing arbiter-visible.

**Recommendation: do not buy the whole item.** Buy tier A, and inside tier A buy
it in this order, which is the order of *expected findings per line* as this pass
actually measured it, not the order the TODO gives:

1. `Categories.cpp` + the category half of `Utils.cpp` — **done, this document**.
   Yield: two blocked questions settled, one real import bug.
2. `Classement.cpp` — partly done here (Buchholz, presence, adjusted points).
   Sonneborn-Berger, Koya, ARO, Aro-Cut, `TieBetween`, `CmpCla`'s sort and
   `VirtualOpponent` are **not** covered and are the single largest remaining
   pocket. Estimate: half a session.
3. `EnvoiJAVAFO.cpp` — partly done here (`XXP` exclusions). `XXA`/`XXZ`/`XXC`
   emission and `EcrireClassementJAVAFO`'s result-code mapping are not.
   Estimate: half a session.
4. `Utils.cpp`'s remaining shared predicates (`AbsentThisRound`, `GetElo`,
   `ConvertResult*`, the `Format*` family). Estimate: half a session.
5. `XtraPoints.cpp` against `docs/acceleration.md`. Estimate: quarter session.

Stop after 5. Tier B is not worth a scheduled pass; keep leaning on the
symptom-driven pattern `TODO.md:974-976` already recommends.

---

## 2. Priority 1 — Categories

### 2.1 SWAR's category model, as it actually is

`Swar.h:316-327` defines the whole thing:

```
enum C_CATEGO { NO_CATEGO, CATEGO_ELO, CATEGO_AGE, CATEGO_AGE_ELO, CATEGO_ELO_AGE, CATEGO_LIBRE };
#define MAX_CATEGO 16
```

and a `CATEGORIE` struct holding the type plus `Value1[17]` and `Value2[17]`, with
SWAR's own comment on slot zero: `// !!! Val[0] = PLUS_DE` ("more than").

`Categories.h:53-55` names the two arrays in the UI: `mC_Choix_1` is
`"Titre de la colonne 1"`, `mC_Choix_2` is `"Titre de la colonne 2"` — **two
columns of one dialog**, not one list and a spare.

The five types, with what each column then holds
(`Categories.cpp:191-224`, `CategorieExplain`):

| `Categorie` | Column 1 (`Value1`) | Column 2 (`Value2`) |
|---|---|---|
| 0 `NO_CATEGO` | — | — |
| 1 `CATEGO_ELO` | rating bounds | blank |
| 2 `CATEGO_AGE` | age bounds | blank |
| 3 `CATEGO_AGE_ELO` | age bounds | rating bounds |
| 4 `CATEGO_ELO_AGE` | rating bounds | age bounds |
| 5 `CATEGO_LIBRE` | free-text names | blank |

Three structural facts that follow, all VERIFIED:

**(a) For the four derived types the stored strings are numeric BOUNDS, not
names.** `CategoriesGetValues` (`Categories.cpp:588-643`) writes each cell as
`abs(atoi(text))` formatted `%04d` for a rating and `%02d` for an age — a typed
"2000" is stored as the *upper* bound of a bucket, and SWAR's own comment on both
branches is `// MOINS DE` ("less than"). Only `CATEGO_LIBRE` stores the arbiter's
text verbatim.

**(b) Slot 0 is a real category the arbiter never types.** After sorting
descending, `CategoriesSortLeft` (`Categories.cpp:488-501`) writes
`Value1[0] = "+" <> Value1[1]` — the implicit "above the highest bound" bucket.
The dialog numbers the first *editable* row 200, not 100
(`CategorieNumberLeftAndRight`, `Categories.cpp:350-358`, `(i+2)*100`), precisely
because index 100 is already taken by slot 0. `CATEGO_LIBRE` has no such bucket
and numbers its first row 100 (`CategorieNumberLeftLibre`, `:340-347`,
`(i+1)*100`) — the one type where the arrays are 0-based.

**(c) A player carries ONE integer that packs BOTH axes.** SWAR's own comment
block at `Categories.cpp:719-726` states the encoding: category 1 is stored times
100, category 2 added raw, `idx / 100` and `idx % 100` recover them. Assignment is
`AssignCatToPlayer` (`Categories.cpp:1142-1156`): one `SetCat*` call for a
single-axis type, two calls (`value=1` then `value=2`) for the two-axis types.
Display is `GetCategorieValue` (`Utils.cpp:1513-1560`), which renders a single-axis
category as `"+2000"` or `"-1800"` and a two-axis one as a **single joined string**,
`"-2000 # -14"`.

So: **SWAR has one category per player, always. It has never had several.** What it
has is one category that may be the product of two axes, rendered as one label.
Independent confirmation from SWAR's own JSON export, which writes exactly
`CatIndex`, `CategoryValue_1`, `CategoryValue_2` per player (`Json.cpp:725-729`)
and two category lists (`Json.cpp:696-702`).

### 2.2 Answers to `docs/design-player-tags.md` §8, as SWAR answers them

These are SWAR's answers, offered because SWAR is what these arbiters use daily —
not because SWAR is right. Where FIDE has nothing to say I say so.

**Q1 — per-tournament, or a durable property of the player? SWAR says
per-tournament, and derived rather than stored.**
`CATEGORIE Categorie` is a single global belonging to the open tournament and
serialized into the `.swar` file (`TournoiReadWrite.cpp` writes it in the
`[CATEGORIES]` block); `CatIndex` is a field of `JOUEUR` (`Swar.h:275`), which is a
per-tournament record. The club/FIDE player database carries **no** category at
all: when a player is drafted from it, `Base.cpp:534-547` *computes* their category
on the spot from rating and birth date. There is no durable category anywhere in
SWAR. This is the design doc's own recommendation
(`docs/design-player-tags.md:82-137`), and it matches what arbiters will expect.
Not a FIDE question — house choice, and both houses have made the same one.

**Q3 — what should auto-assign do to hand-set values? SWAR has two entry points
and they answer differently, and the split is the interesting part.**

* The visible **"Assign categories" button** is destructive.
  `OnBnClickedCAssign` (`Categories.cpp:875-899`) calls `AssignCatToPlayer`, whose
  very first statement is `CategoriesResetAllPlayer()` (`Categories.cpp:765-775`),
  zeroing every player's `CatIndex` before recomputing. A hand-set value does not
  survive. This is exactly OpenPairings' current behaviour
  (`tournaments.ex:2240-2254`, and its own doc note at `:2202-2210`).
* A separate, quieter path `AssignCatToSomePlayer` (`Categories.cpp:1166-1189`)
  skips any player who already has a category (`if (p.CatIndex) continue;`) —
  fill-blanks-only, used when players arrive after the categories were set up.

* **And the collision mostly cannot arise, because SWAR forbids mixing.** For
  `CATEGO_LIBRE` — the only type whose categories are hand-typed names —
  `OnBnClickedCRadioLibre` (`Categories.cpp:861-872`) does
  `GetDlgItem(IDC_C_ASSIGN)->EnableWindow(FALSE)`: **the Assign button is greyed
  out.** Free categories are always assigned by hand and never by rule; derived
  categories are always assigned by rule and never by hand. They are mutually
  exclusive modes.

  That is the answer worth taking. Of the three behaviours the design doc lists,
  SWAR effectively picks the first (replace everything) and then makes it safe by
  never letting a rule and a hand-set value describe the same vocabulary. The
  design doc's option two ("replace only tags that have rules, leave hand-set
  ones") is the *most work* and is unnecessary if the vocabulary itself is split
  the way SWAR splits it. Not a FIDE question.

**Q5 — is there an upper bound? SWAR: 16 per column, 32 characters each, one
category per player.** `MAX_CATEGO 16` and `MAX_CATEGO_LEN 32` (`Swar.h:319-321`);
arrays are `MAX_CATEGO + 1` because of slot 0. A two-axis tournament therefore has
at most 16 × 16 = 256 reachable combinations, but still exactly one per player.
`swar_export.ex:141`'s `Enum.take(16)` is the right number for one column.
Not a FIDE question.

**Q6 — should removing a category strip it from players? SWAR: effectively yes,
and it goes further than the design doc proposes.**

* Clearing the list clears the players. `OnBnClickedCReset`
  (`Categories.cpp:781-799`) blanks both columns and then — since v6.63 — calls
  `OnBnClickedCAssign()` itself, which resets every player's `CatIndex` to 0.
* Switching category type blanks both columns (`CategorieBothToBlank`,
  `Categories.cpp:238-252`), so the arbiter must re-assign.
* **Deleting one row in the middle silently renumbers everything below it.**
  `CategoriesPack` (`Categories.cpp:413-428`) closes gaps by pulling later entries
  up, and the index is positional. Between the delete and the next Assign, every
  surviving player below the deleted row points at the wrong category. SWAR gets
  away with this because Assign is a single button the arbiter presses right there;
  OpenPairings, where the vocabulary is edited on one page and players on another,
  does not have that protection. If `categories_live.ex` grows a reorder or a
  delete, **this is the failure mode to design against** — it is the strongest
  argument in this document for the design doc's phase-5 "strip on removal".

**Q2 / Q4 — the pairing-pool control and reordering. SWAR's precedent:**

* The "pair separate categories" checkbox (`Tournoi.CatSepares`) is shown only when
  it can mean something. It is force-unchecked and disabled for both two-axis types
  (`Categories.cpp:836-837`, `:853-854`); `CategoriesSetCheckboxes`
  (`Categories.cpp:552-576`) hides the category filter entirely when there are no
  categories or the tournament is a round robin; and `OnBnClickedCAssign`
  (`:889-892`) refuses to proceed with one category and separate pairing on
  (`_PAS_ASSEZ_DE_CATEGORIES`). That is a direct answer to Q2: **show it only when
  it applies** — SWAR does not hide it, but it never offers it where it is
  meaningless.
* It also **locks once results exist**. `CategorieDisableCatSepare`
  (`Categories.cpp:148-186`) disables every radio, both columns, Reset and Assign
  as soon as `Tournoi.CatSepares && NbResult`. This is the same instinct as
  OpenPairings' "locks once round 1 has been paired" on
  `SettingsOptionsLive` (`docs/swar-import.md:425-429`) — good precedent for
  extending that lock to the categories page.
* On Q4 (reordering): SWAR **sorts derived categories itself**, descending
  (`CategoriesSortStructures`, `Categories.cpp:573-580`) and explicitly **skips
  sorting for `CATEGO_LIBRE`** (`if (Categorie.Categorie == CATEGO_LIBRE) return;`),
  where the arbiter's typed order is the order. That is a clean rule OpenPairings
  could adopt: **rule-derived categories order themselves; free ones keep insertion
  order and are reorderable.** Not a FIDE question.

**Q7 / Q8** (the `categories != []` vs `categories_enabled` gate, and the CSV
column name) have no SWAR counterpart. SWAR has no equivalent of
`categories_enabled` — `GetNbCategorieStructureLeft() == 0` *is* the switch
(`Categories.cpp:559-561`), which is the `categories != []` reading, for whatever
that is worth as a precedent.

### 2.3 The two-axis label, if it is ever imported

If OpenPairings ever imports a two-axis SWAR file, the label an arbiter expects is
SWAR's own: axis-1 label, `" # "`, axis-2 label, each rendered `+bound` for slot 0
and `-bound` otherwise (`Utils.cpp:1513-1560`). Worth writing down now, because a
guess here would be visible on every printed crosstable.

---

## 3. The two blocked questions

### 3.1 `value1` / `value2` — SETTLED

**`value2` is the second axis of a two-dimensional category system.** It is
candidate one of the three tabulated in `docs/swar-import.md:471-475` ("a second
dimension (age beside rating)"), with a wrinkle the table did not anticipate:
**for every type except `CATEGO_LIBRE`, both lists hold numeric bounds, not
names.** So candidate two ("boundaries, not categories at all") is half right about
the *content* and wrong about the *relationship* — `value2` is not `value1`'s
boundaries, it is a second axis's boundaries. Candidate three (other national
language) is excluded outright.

Evidence, all VERIFIED, four independent strands:

1. `Categories.h:53-55` — the two arrays are the dialog's two columns.
2. `Categories.cpp:207-218` — for `CATEGO_AGE_ELO` the columns are captioned
   AGE / ELO; for `CATEGO_ELO_AGE`, ELO / AGE. For the single-axis types column 2
   is captioned `""`.
3. `Categories.cpp:1142-1156` — `AssignCatToPlayer` calls one `SetCat*` per axis,
   `value=1` reading `Value1`, `value=2` reading `Value2`
   (`GetEloMinMax`/`GetAgeMinMax`, `Categories.cpp:964-996`, branch on that
   argument).
4. `Json.cpp:725-729` — SWAR's own JSON export emits `CategoryValue_1` and
   `CategoryValue_2` as separate per-player fields.

**What this means for the importer.** `map_categories/1`
(`swar_import.ex:1503-1507`) flattening `value1 ++ value2` is wrong for a two-axis
file: it produces a flat name list mixing an age scale and a rating scale, and no
`CatIndex` can point into the `value2` half through
`category_name/2` (`:1509-1519`). The existing warning
(`category_warnings/1`, `:1478-1495`) is the right behaviour and should stay until
someone decides how a two-axis category should land in a single-valued
`players.category` — the honest options being "join with SWAR's own `#`" or
"import axis 1 and warn about axis 2". **That is now a design decision, not a
mystery.** Recommend updating `docs/swar-import.md:448-485` and
`TODO.md:237-244`/`:550-558` to record it as settled.

### 3.2 `SW321_PreBye` — SETTLED

**It is a plain boolean checkbox, and it adds `SW321_Pre` on top of the bye's own
value.** VERIFIED:

* `TOptionsGetValues` (`TOptions.cpp:679-712`) reads it as
  `GetCheck() == BST_CHECKED ? 1 : 0` — a raw 0/1, exactly like `AbsValue`. Its
  label is `_SW321_STA_BYEPRE` (`TOptions.cpp:103`).
* Its effect is `GetPresentPtsUntilRound` (`Classement.cpp:137-153`): a round whose
  result is in `RESULTATS_BYE` adds `SW321_Pre` **when and only when** the flag is
  set. Same code duplicated in `Fiche.cpp:192-194` for the player card.
* Default: the dialog's own defaults set it CHECKED (`TOptions.cpp:249`), but a
  brand-new tournament zeroes it (`SwarView.cpp:1843`, marked v6.61).
  `Tournament.presence_on_allocated_bye`'s false default matches the
  new-tournament path.

This is exactly what `Standings.bye_points/4`'s `"pairing-allocated"` branch and
`allocated_bye_presence_bonus/1` (`standings.ex:534-552`, `:713-720`) already do.
**The model is confirmed correct.** Recommend closing `TODO.md:609-613` and
`:237-239`.

Three further facts about 3-2-1 that fall out of the same reading, all VERIFIED,
each of which upgrades an inference in `docs/swar-import.md` to a fact:

* **The ÷4 scale is proven, not inferred.** `TOptions.cpp:701-705` literally stores
  `4 * <UI value>` for `SW321_Win/Nul/Los/Bye/Pre`, and `Html.cpp:730-734` divides
  by 4 to display them. `docs/swar-import.md:499-544`'s careful non-circular
  derivation was right; it can now cite the source instead.
* **`SW321_Bye`'s role is confirmed.** In a 3-2-1 tournament `TOptions.cpp:562-566`
  disables the bye-value radios and forces `ByeValue = PTS_0`, so
  `GetResultByeValue` (`PairingSwiss.cpp:73-79`) can only return `LOST_BYE` — which
  is why `ConvertPoint321` (`Utils.cpp:1206-1223`) handles `LOST_BYE` and nothing
  else, and why its own comment says the bye is *always* `LOST_BYE`. The doc's
  caveat at `swar-import.md:541-544` ("`SW321_Bye`'s role is inferred… no
  `WIN_BYE`/`DRAW_BYE` occurs in the fixture") can be closed: none can occur.
* **`AbsValue`/`AbsJusque`/`AbsNbFois` are inert in a 3-2-1 tournament.** The same
  block (`TOptions.cpp:554-559`) disables the whole "Pt ABSENT" group and forces
  `AbsValue = 0` — and does the same for round robin and American
  (`TOptions.cpp:569-583`). See finding 6.

---

## 4. Findings

Ordered by how likely an arbiter is to see the difference.

### F1 — `category_name/2` is off by one against a real SWAR file (real bug)

**VERIFIED both sides.**

SWAR resolves a player's category index as `idx/100`, then **decrements**, then
indexes `Value1` (`GetCategorieValue`, `Utils.cpp:1516-1531`). Index 100 is
`Value1[0]`, the "+bound" bucket; index 200 is `Value1[1]`.

OpenPairings does `Enum.at(value1, div(cat_index, 100))` with no decrement
(`swar_import.ex:1515-1518`). Index 100 resolves to `value1[1]`.

Worked example. An arbiter types 2000 / 1800 / 1600 into an ELO category
tournament. SWAR ends up with four categories — `+2000`, `-2000`, `-1800`, `-1600`
— stored as `Value1 = ["+2000","2000","1800","1600", …]` and indices
100/200/300/400 (`GetEloMinMax`, `Categories.cpp:964-978`, and the
`(i+1)*100` assignment at `Categories.cpp:1036-1071`). Importing that file today:

| Player is in | SWAR shows | OpenPairings shows |
|---|---|---|
| `+2000` (idx 100) | `+2000` | `2000` |
| `-2000` (idx 200) | `-2000` | `1800` |
| `-1800` (idx 300) | `-1800` | `1600` |
| `-1600` (idx 400) | `-1600` | *(empty)* |

Every player is labelled one category too strong, and the bottom category loses its
players entirely. With `pair_by_category` on, that is not a label problem — it is a
pairing pool problem.

**Why it has never bitten:** all three `.swar` fixtures carry `type = 0`, and
`SwarExport.reverse_categories/1` (`swar_export.ex:379-389`) writes
`["" | categories]` with a deliberate leading blank plus
`reverse_cat_index/2`'s `(index + 1) * 100` (`:601-609`) — so OpenPairings'
own export/import round-trips perfectly and every existing test passes. The bug is
only reachable from a genuine SWAR file with categories configured.

FIDE has nothing to say here; this is purely "does the import agree with the file".
It does not.

**Note also:** the labels themselves differ. SWAR renders the sign (`+2000`,
`-1800`); the raw stored string is the bare bound. `GetCategorieIndex`'s own
comment (`Utils.cpp:1443-1447`) spells out that `-1500` and `1500` mean the same
thing and `+1500` is different. An import that keeps the bare number will print
`2000` where the arbiter's own program prints `-2000`, which reads as "at least
2000" rather than "under 2000".

**Fix shape** (not written, since another agent is in these files): decrement, and
render the sign. One line plus a formatter, and a fixture with `type != 0`.

### F2 — `EXCLU_GLOB_NAT` does nothing in SWAR (SWAR bug; matters as a warning)

**VERIFIED (SWAR side only; OpenPairings has no counterpart).**

SWAR's five exclusion modes (`Swar.h:98-100`) include two "global" ones: never pair
two players of the same club, never pair two of the same federation. The club one
works: `BuildAllClub` (`EnvoiJAVAFO.cpp:860-888`) collects every distinct club
number and `BuildXXPforCluOuNat` (`:710-737`) emits the `XXP` lines.

**`BuildAllNat` (`EnvoiJAVAFO.cpp:890-892`) has an empty body.** The
`EXCLU_GLOB_NAT` case (`:970-974`) calls it, then calls `EcrireExclusionNat` on an
`Exclusion.Values` nothing populated, then clears it. No `XXP` line is written. An
arbiter who selects "global exclusion by nationality" gets no exclusion at all,
silently.

Why this belongs in an OpenPairings audit: if a Belgian arbiter ever says "SWAR
doesn't separate federations either, so this must be optional", **that is not a
rule, it is an unimplemented feature.** And if OpenPairings ever builds
club/federation exclusion (it currently has only explicit player pairs —
`docs/forbidden-pairings.md`), do not calibrate it against SWAR's observed
behaviour on the nationality axis. FIDE C.04 does not require same-federation
separation in a domestic Swiss; this is an organiser's choice, and OpenPairings not
having it is a gap, not a defect.

### F3 — Buchholz cut variants: SWAR suppresses the cut entirely for any absentee

**VERIFIED both sides.**

`TieBucholtz` (`Classement.cpp:1131-1287`) applies the Cut/Median drops only when
the player had **no** absences at all:

* while summing the player's own unplayed rounds it skips the *first*
  `TABLE_ABSENT` round from the self-correction and counts absences in `nbAbsent`
  (`:1177-1183`);
* at the end, `if (Dep > DEP_BUCHOLTZ && nbAbsent == 0)` guards the entire
  drop-lowest / drop-highest block (`:1273-1283`).

So for a player with one or more absences, SWAR reports **plain Buchholz** where the
tournament was configured for Buchholz Cut-1, Cut-2, Median-1 or Median-2. The
citation in its own comment is an internal analysis document, not a FIDE article.

OpenPairings implements FIDE 07 Art. 16.5.1 as written: `cut/3` and
`drop_lowest_with_vur_priority/2` (`standings.ex:1355-1382`) always perform the
configured number of cuts, preferring a voluntary-unplayed-round contribution for
the lowest cut.

**Which the rules support: OpenPairings.** 16.5.1 is a *preference* rule about
*which* contribution to cut, not a licence to skip the cut. For the single common
case — one absence, Cut-1 — the two produce the same number by coincidence
(skipping the contribution ≈ cutting it). They diverge for Cut-2 with one absence
(SWAR performs one effective cut, OpenPairings two) and for any player with two or
more absences under any cut variant.

Practical consequence: **an imported tournament's Cut-1 column will not always match
the numbers printed from SWAR.** Worth knowing before an arbiter reports it as a
bug in OpenPairings.

### F4 — Buchholz drops an opponent who forfeited against you

**VERIFIED (SWAR side); no OpenPairings counterpart.**

`TieBucholtz` (`Classement.cpp:1206-1224`) scans each opponent's whole round history
and, if any of the opponent's rounds is a forfeit result whose adversary is this
player, **excludes that opponent from the Buchholz sum entirely** rather than
counting an adjusted score for them. SWAR's comment cites its own
`Tiebreak-exercises.pdf` by page and player name.

OpenPairings has no such exclusion. `buchholz_contributions/3`
(`standings.ex:1281-1289`) contributes for every game record, taking the opponent's
`adjusted_score` when there is an opponent and a `dummy_score` when there is not.

Two caveats before treating this as actionable, both honest:

* SWAR's own condition compares `r->Advers` (a player's `Ni` — that is what
  `FindJoueurNumber` matches on, `Utils.cpp:836-845`) against `j1.Rank` (the seeding
  number). Those are different numbering spaces. Either this is a latent bug in SWAR
  that makes the exclusion misfire, or `Rank` and `Ni` coincide often enough in
  practice that nobody noticed. **INFERRED, cannot be settled without running SWAR.**
* FIDE 07 Art. 16 governs how an *unplayed game* contributes, not whether an
  opponent is struck from the sum. I could not verify a FIDE article that supports
  wholesale exclusion.

**Recommendation: do not change OpenPairings on this.** Record it so that a
"Buchholz doesn't match SWAR" report can be diagnosed in one step instead of
re-derived.

### F5 — SWAR's opponent-score adjustment covers involuntary forfeits; OpenPairings' covers voluntary ones

**VERIFIED both sides.** Both programs converge on the *shape* — add half a point
for each **trailing** unplayed round of the opponent — which is a genuinely
reassuring agreement, since both arrived at "trailing only" independently:

* SWAR: `GetAdjustedPts` (`Classement.cpp:1099-1113`) adds `2` (half a point in
  SWAR's ×4 scale) per round for which `getBuchNonJouer` (`:1074-1091`) returns 1,
  and that helper returns 1 only when every *subsequent* round is also unplayed.
* OpenPairings: `adjusted_score/2` (`standings.ex:1296-1317`) takes
  `Enum.take_while` over the reversed game list — trailing only, by construction —
  plus the missing-tail fix for a withdrawn opponent with no records at all.

They differ on **which rounds qualify**. SWAR counts `LOST_FF` or `TABLE_ABSENT`.
OpenPairings requires `not played and voluntary`. So an opponent whose last two
rounds were involuntary forfeits gets +1.0 from SWAR and +0.0 from OpenPairings.

Article 16.3 as OpenPairings reads it (its own comment at `standings.ex:1291-1295`)
scopes the adjustment to *voluntarily* unplayed rounds, which supports
OpenPairings. I could not verify the article text directly, so: **OpenPairings'
reading is the better-documented one, SWAR's is broader, and the difference is
small and rare.** No change recommended; recorded for diagnosis.

### F6 — `abs_value` is settable on tournament types where SWAR forbids it

**VERIFIED both sides.** SWAR disables the entire "Pt ABSENT" group and forces
`AbsValue = 0` for three tournament families: 3-2-1 (`TOptions.cpp:554-559`), round
robin, and American (`:569-583`). It also forces `ByeValue = PTS_0` for all three.

OpenPairings' `absent_points/3` (`standings.ex:561-568`) reads `abs_value`
regardless of tournament type, and `SettingsOptionsLive`'s Scoring card offers all
three fields on any tournament (`docs/swar-import.md:419-429`).

Reachable two ways: a hand-configured OpenPairings 3-2-1-style tournament, or a
`.swar` file where the arbiter set the absence option *before* switching the type
(SWAR's forcing lives in the dialog's display path, `TOptionsSetValues`, not in the
file loader or the pairing path — **INFERRED**, since I cannot confirm the tab is
always visited).

FIDE does not decide this — absence points are not a FIDE concept at all; this is
entirely a club/house rule. **The finding is not "OpenPairings is wrong", it is
"OpenPairings is more permissive, deliberately or not, and nobody wrote down which".**
Worth one sentence in `docs/swar-import.md` either way.

### F7 — `XXP` shape differs; semantics identical

**VERIFIED both sides.** SWAR expands a forbidden group of *n* players into
*n(n−1)/2* two-player lines (`EcrireXXP`, `EnvoiJAVAFO.cpp:691-703`). OpenPairings
writes one line per group (`deps/ainalrami/lib/ainalrami/trf.ex:1210`,
`"XXP " <> Enum.join(...)`). Both are valid JaVaFo input and mean the same thing;
OpenPairings' is more compact.

Both correctly write the **standings/pairing number**, not the registration number —
SWAR's own comment at `EnvoiJAVAFO.cpp:834` says so in capitals, and
`docs/forbidden-pairings.md` documents the same choice on the OpenPairings side.
**Not a finding; recorded as a verified agreement**, since this is exactly the class
of bug that has bitten twice before.

### F8 — round-robin bye value: agreement that depends on a fragile SWAR path

**VERIFIED on the SWAR side, INFERRED on reachability.** SWAR's round-robin pairer
always writes `WIN_BYE` for the odd player (`PairingRobin.cpp:236`, `:295`), but
`ConvertPoint` (`Utils.cpp:1184-1195`) scores any bye by `Tournoi.ByeValue` — which
`TOptions.cpp:582` forces to `PTS_0` for round robin. Net: **zero points**, matching
OpenPairings' unconditional zero-point structural bye
(`round_robin.ex:61-67`, a `"requested-zero"` row).

The fragility: the forcing lives in the Options dialog's display path only. `ByeValue`
is initialised to `PTS_1` for a new tournament (`SwarView.cpp:1852`) and for legacy
files (`TournoiReadWrite.cpp:452`), and nothing forces it at load or pairing time. A
round-robin file whose Options tab was never opened would carry `PTS_1` and score
that bye a **full point**. Whether that is reachable in practice cannot be settled
without running SWAR.

OpenPairings imports whatever the file says (`map_bye_value/1`,
`swar_import.ex:1344-1347`, a correct mirror of `USE_POINTS`), which is the right
behaviour under either reading. FIDE does not award a point for a round-robin
bye, so OpenPairings' unconditional zero for its *native* round robins is the
defensible default and is already documented as deliberate. **No change; recorded.**

---

## 5. Checked and found equivalent (deliberately not findings)

Recording these so pass two does not re-derive them.

* **Presence points, which results earn them.** SWAR pays `SW321_Pre` for normal
  results, the "special" 0-0 / ½-0 / 0-½ family, and a forfeit **win** — never a
  forfeit loss or a double forfeit (`Classement.cpp:143-148`, via the
  `RESULTATS_NORMAUX | RESULTATS_WIN | RESULTATS_SPECIAUX` masks at `Swar.h:239-247`).
  `Standings.presence_earned/1` (`standings.ex:1064-1080`) reproduces exactly that
  set, and its own comment cites the same masks. Exact match.
* **The `WIN_BYE` double-presence hazard is unreachable.** `WIN_BYE` is a member of
  *both* `RESULTATS_WIN` and `RESULTATS_BYE` (`Swar.h:241`, `:245`), so a won bye
  would satisfy both `if`s in `GetPresentPtsUntilRound` and be paid twice. It cannot
  happen: presence points exist only in 3-2-1, and 3-2-1 forces every bye to
  `LOST_BYE` (§3.2). Not a bug, and specifically **not** something to defend against.
* **`TOURNOI_TYPE.SWISS_321 == 3`** — `Swar.h:69-71` confirms the ordinal the
  importer's guard depends on (`swar_import.ex:1229`).
* **`USE_POINTS { PTS_1, PTS_5, PTS_0 }`** — `Swar.h:96`; `map_bye_value/1`'s
  `0→1.0, 1→0.5, 2→0.0` is the correct mirror.
* **`AbsValue` is a 0/1 checkbox** — `TOptions.cpp:684`. Independently confirms the
  fix `docs/swar-import.md:380-396` documents.
* **The dead zeroing branch in `TieBucholtz`.** `Classement.cpp:1230-1236` compares
  a `Result` against `TABLE_ABSENT` (0x4000, which as a result *is* `WIN`), inside a
  branch only reached when the result is not a normal one — so it can never fire.
  Almost certainly a `->Result` / `->Table` slip. **Do not implement the apparent
  intent**; it is not live behaviour in SWAR and copying it would create a real
  divergence out of a dead one.
* **`RoundRobinInfo.cpp` and `ExcludePairing.cpp` contain no logic** — see §1 tier C.

---

## 6. Keizer (priority 4, second half): nothing to compare

**VERIFIED.** SWAR has no Keizer tournament type. `TOURNOI_TYPE`
(`Swar.h:69-71`) is `SWISS, SWISS_DBL, SWISS_ACC, SWISS_321, ROBIN, ROBIN_DBL,
ROBIN_AR, SW_AMERICAIN, SW_AMERICAIN_DBL` — no Keizer. The legacy Pairtwo importer
recognises a Keizer file only to reject it, with the comment
`// Non autorisé dans Swar` ("not allowed in SWAR", `Pairtwo.cpp:138-139`). The two
other hits for the word (`PairingSwiss.cpp:308`, `:410`) use "Keizer" loosely for an
adjacent-pairs fallback (1-2, 3-4, …) used when JaVaFo returns no pairing at all —
not the Keizer *system*.

`lib/pairings_engine/keizer.ex` has no SWAR counterpart and should be struck from
the audit item.

---

## 7. What pass two should do

In priority order, with the reason each is next:

1. **`Classement.cpp`, the rest of it** — Sonneborn-Berger (`:834`) and its unplayed
   handling (`getSonnebornNonJouer`, `:773`), `TieBetween` (`:567`) and the
   `GetNbrPlayed`/`Comb` machinery behind it, `TieKoya` (`:745`), `VirtualOpponent`
   (`:722`), `TieAro`/`TieAroCut` (`:335`, `:388`), and `CmpCla` (`:1326`) — the sort
   comparator that decides final order when tie-breaks are equal. Against
   `standings.ex:1108-1254` and `add_direct_encounter/2`. This is where the remaining
   arbiter-visible arithmetic lives.
2. **`EnvoiJAVAFO.cpp`'s `EcrireClassementJAVAFO` and `EcrireLesAbsents`/`EcrireXXA_*`**
   against `Pairing.javafo_input/2` and `Ainalrami.Trf`. Same class of bug found twice
   before; the `XXP` half is done, the result-code and `XXZ`/`XXA` halves are not.
3. **A fixture with `type != 0`.** F1 cannot get a regression test without one. A
   synthetic `.swar` built to §2.1's layout would do — it does not need to be a real
   club file any more, now that the layout is known.
4. **`Utils.cpp`'s shared predicates** — `AbsentThisRound`, `GetElo`, the
   `ConvertResult*` family. Historically where an edge-case bug hid.
5. **`XtraPoints.cpp`** against `docs/acceleration.md`.

Explicitly **not** worth a pass: `PairingAmericain.cpp` (dropped from the roadmap),
`ImportCsv.cpp` (SWAR's own club-CSV format, which OpenPairings does not read),
`Joueur.cpp`/`Tournoi.cpp`/`TOptions.cpp` beyond targeted lookups (dialog wiring),
and anything under `Html/`, `PRINTsrc/`, `Curl/`.

---

## 8. Documentation the maintainer may want to update

Not done here — this pass wrote nothing into the repository.

* `docs/swar-import.md:448-485` — `value2` is settled (§3.1). The three-candidate
  table can become a statement.
* `docs/swar-import.md:499-544` — the ÷4 scale and `SW321_Bye`'s role are now
  provable from `TOptions.cpp:701-705` and `Html.cpp:730-734`; the careful
  non-circular derivation can cite the source instead of standing alone.
* `docs/design-player-tags.md:824-871` — §2.2 answers Q1, Q3, Q5, Q6 as SWAR answers
  them, and gives precedent for Q2 and Q4.
* `TODO.md:237-244`, `:550-558`, `:609-613` — both "blocked on a real club file"
  items are unblocked.
* `TODO.md:957-976` — the cost estimate can be replaced with §1, and
  `RoundRobinInfo.cpp` / `ExcludePairing.cpp` removed from the implied surface.

---

## Orchestrator note, 2026-09-09

**F1 verified independently.** `category_name/2`
(`lib/pairings_engine/federations/bel/swar_import.ex` ~1515) reads

    Enum.at(categories.value1, div(cat_index, 100), "")

and its own comment claims the division yields "a 0-based slot index".
`div(100, 100)` is 1, which is the second entry. The comment and the code
disagree, and the code is the wrong one.

NOT YET FIXED. The multi-category feature was being built in this file's
neighbourhood at the time, and editing underneath a running agent loses
work. To be applied once that lands, with a fixture that actually has
categories configured - no existing `.swar` fixture does, which is half of
why this survived.
