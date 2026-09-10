# OpenPairings vs SWAR v6.65 FRBE — audit pass three

Date: 2026-09-10. Read-only against both source trees — nothing in SWAR or in
OpenPairings' code was changed to produce this document. Two documentation
files in this repository were updated afterward, per §5 below:
`docs/swar-import.md` and `TODO.md`.

**Pass one is
[swar-source-audit-2026-09-09.md](swar-source-audit-2026-09-09.md)**, **pass
two is
[swar-source-audit-pass2-2026-09-09.md](swar-source-audit-pass2-2026-09-09.md)**.
This is pass three, and — per the scope that commissioned it — the last one:
tier A is fully read after this document (§4), and both earlier passes already
argued tier B is not worth a scheduled pass. Nothing below revises a finding
from either earlier pass; this document is purely additive, covering the
~0.4-session remainder pass two's §8 left open.

Sources:

* SWAR: `C:/Users/jorian/Downloads/Swar - 20250906 v6.65 FRBE/` (proprietary).
* OpenPairings: `C:/Users/jorian/Desktop/02cloud/VPS projects/openpairings`
  (branch `main`, 0.56.0).
* `Ainalrami.Trf`, pinned at v0.25.0
  (`deps/ainalrami/lib/ainalrami/trf.ex`), for the TRF result-code table §2
  compares against.

Scope: the two pockets pass two's §8 named as the only parts of `Utils.cpp`
likely to return anything arbiter-visible — `GetLastRoundWithResult`/
`GetFirstRoundOnlyPairing` (§1) and the three `ConvertResult2*_TRNfile`
encoders (§2) — plus, with room left over, `TournoiReadWrite.cpp`'s
`ReadStr`/`ReadInt` primitives (§3), the one item pass two deferred behind
both. The ~900 lines of `Format*`/`Write*` display and CSV-writer helpers in
`Utils.cpp` were **not** read, on pass two's own recommendation: description
and formatting code with no OpenPairings counterpart to diverge from, never
expected to return a finding.

**Licensing constraint observed.** Nothing below transcribes SWAR's
implementation. Quotations are single identifiers, single expressions, or
SWAR's own French comments, used only to establish a specific factual claim
about behaviour. No SWAR function is translated into Elixir anywhere in this
document and no recommendation amounts to copying one.

**VERIFIED** means read on both sides, at the cited lines. **INFERRED** means
read on one side and reasoned about, or dependent on a runtime path that
cannot be exercised without running SWAR. SWAR was never run.

---

## 0. Headline

Three things came out of the two pockets, all of them on SWAR's side, none of
them fixable here:

| # | What | Class |
|---|---|---|
| F23 | SWAR's tiebreak round-horizon is "at least one result reported", not "all of them" — and it is the live loop bound of every tiebreak, not a display number | SWAR-side defect; `completed_rounds/2` is the fix for exactly this bug shape |
| F24 | SWAR's own TRF importer collapses the three standard bye codes (`H`/`F`/`Z`) into ordinary rated results, discarding "not played" | SWAR-side defect; reachable through a TRF file OpenPairings itself writes |
| F25 | SWAR's FIDE-mode result encoder writes the bye-only code `H` on a row naming a real opponent, for a forfeit ruled a draw | SWAR-side inconsistency; low probability, no live OpenPairings counterpart |

Nothing here is a defect on OpenPairings' side, and no code in this repository
needed changing. F23 and F24 are written up in `docs/swar-import.md` for
arbiters (§5); F25 is recorded here only, since it is small enough not to earn
its own arbiter-facing paragraph until someone actually reports it.

---

## 1. F23 — SWAR's tiebreak horizon moves the instant one board reports

**VERIFIED both sides.**

This is pass two's highest-priority unread question, asked precisely: is
SWAR's round horizon "rounds with at least one result", or "rounds with all
results"? It is the former, without qualification — and it is not a display
nicety, it is the literal loop bound inside every tiebreak in `Classement.cpp`.

### 1.1 `TestIfResultsThisRound` and what it actually counts

`GetLastRoundWithResult` (`Utils.cpp:652-662`) scans rounds backward from the
most recent and returns the first one for which `NbResult > 0`. Its own header
comment settles the question before the code does: "recherche de la dernière
ronde possédant **au moins un** résultat" — search for the last round
possessing *at least one* result (`Utils.cpp:644-645`).

`NbResult` comes from `TestIfResultsThisRound` (`Utils.cpp:612-641`), which
classifies every player's record for that round into exactly one of three
buckets: `NbBye` for `TABLE_ABSENT`/`TABLE_FORFAIT`/a bye result, `NoResult`
for a blank (`NO_RESULT`) game that was paired, and `NbResult` for anything
else — an actual entered result. This is a per-*player* count, not per-board,
but the practical effect is the same: the moment one board's result is typed
in, both of that board's players move from `NoResult` to `NbResult`, `NbResult`
becomes positive, and `GetLastRoundWithResult` returns that round — no matter
how many of the round's other boards are still blank.

### 1.2 The horizon is not cosmetic — it is `Classement.cpp`'s loop bound, everywhere

`LastRoundWithResult` is a global (`Classement.cpp:29`), recomputed at the top
of `CalculLeClassement` (`:1368-1369`) — the master standings routine, which
runs every time the standings screen is shown or refreshed, live,
mid-tournament. From there it is the upper bound of the round loop in
essentially every tiebreak function in the file — a grep for the identifier
turns up more than twenty `for`-loops built on it, including a player's own
raw score (`GetAllPoints`/`GetPointsUntilRound`, `Classement.cpp:95-133`),
`GetNbPlayedParties` (`:75-88`), and the loops inside `TieBucholtz`
(`:1131-1286`, already read in full by pass two), `TieSonneborn`, `TieKoya`
and `TieCumulate` (pass two's §4.1/§6.1 citations), and `TieAro` (pass two's
§4.2 citation, `:335-382`).

Crucially, none of these test whether the *specific game* being folded in was
decided. `TieBucholtz`'s opponent loop asks only whether `j1` was paired that
round at all (`r->Table & TABLE_NON_JOUEE`, `Classement.cpp:1195`) before
pulling the opponent's current score into the sum unconditionally
(`Pts = j2.PointsAdjusted`, `:1228`; `PtsTot += Pts`, `:1244`). So the instant
round 5 has one result in it, `LastRoundWithResult` becomes 5, and *every*
player who was paired in round 5 — not just the two on the reported board —
has that round folded into their Buchholz, their Koya threshold, and their own
raw point total, using opponents whose own round-5 games are, in the same
instant, just as unresolved.

### 1.3 What OpenPairings does, and the history behind it

`completed_rounds/2` (`standings.ex:482-492`) requires every pairing in a
round to carry a non-empty result before the round counts, with one added
condition: a round with nothing in it at all — no pairings, no byes — does not
count either, so that creating a future round shell doesn't retroactively hand
everyone a phantom missing-round contribution the instant it exists. Its own
comment records why this exists: an earlier implementation,
`rounds_played_count/1`, counted *game records* rather than testing round
completeness, and "the count moved the moment ONE board reported: every player
without a record for that round suddenly looked like they had missed a round,
and their opponents' Buchholz gained a phantom draw."

That is, point for point, the bug shape §1.1-1.2 just verified live in SWAR's
`Classement.cpp` today. OpenPairings hit this failure mode, named it, and
specifically engineered `completed_rounds/2` to close it. SWAR's own comments
disagree with each other about which behaviour was intended: the function's
own header at `Utils.cpp:644-645` says "at least one" and the code matches it,
but the extern declaration in `Tournoi.cpp:35` describes the same global as
"Dernière ronde avec **TOUS** les résultats" — the last round with *all* the
results. A comment at the point of use describing behaviour the implementation
does not have is the same signature pass two's F19 found in `TieSonneborn`
("comment and code disagree, and the code is the wrong one"): this reads as an
unintentional bug, not a documented house convention the way F9's Cut-count
reduction is — SWAR's manual defends that one in print; nothing defends this
one.

### 1.4 Verdict

**A defect on SWAR's side.** Not fixable here — SWAR is proprietary — and
there is nothing to change in OpenPairings: `completed_rounds/2` already is
the corrected version of this exact bug. What it does mean, honestly: **the
two programs' mid-tournament tiebreaks cannot be expected to agree while a
round is only partly reported**, for any player who was paired in that round,
in either direction. They converge again the moment the round finishes — once
every board has a result, SWAR's `NbResult`-based horizon and OpenPairings'
all-resolved horizon land on the same round number, because at that point "at
least one" and "all of them" describe the same set. The divergence is real,
mechanical, and entirely transient; it is not present in a finished
tournament's final standings, only in a snapshot taken mid-round. Worth a
paragraph in `docs/swar-import.md`'s tiebreak section, because "why doesn't
live Buchholz match between the two programs during a round" is exactly the
kind of report that section exists to pre-empt.

One further, smaller wrinkle from the same reading: a round consisting
*entirely* of byes (every player sitting out, reachable only in a nearly-empty
or heavily-withdrawn field) has `NbResult == 0` forever, so
`GetLastRoundWithResult` never advances into it — SWAR's horizon simply stalls
one round short. `completed_rounds/2` has no such gap: its bye branch
(`r.pairings != [] or MapSet.member?(bye_rounds, r.number)`) counts an
all-bye round as complete immediately. Rare enough not to be the headline, but
the same root cause, so it belongs in the same note rather than a separate one.

### 1.5 `GetFirstRoundOnlyPairing` has no scoring role

Pass two named both functions because they sit next to each other and share a
subject. Having now read it, `GetFirstRoundOnlyPairing`
(`Utils.cpp:680-701`) does not appear in any tiebreak loop bound in
`Classement.cpp` at all — only in its own assignment at `:1369`. Every other
use is in `Html.cpp` (`:807`, `:1590`, `:1728`, `:3094`), deciding which round
tab the standings/pairing pages jump to by default. It answers "which round is
only paired, not yet resulted" for navigation, not "how many rounds count for
scoring". OpenPairings has no equivalent navigation need bound to a scoring
calculation, so there is nothing to compare here beyond noting it — this
closes that half of pass two's question with nothing further to say.

---

## 2. The three `ConvertResult2*_TRNfile` encoders

**VERIFIED both sides.**

### 2.1 The three tables, side by side

All three live in `Utils.cpp` next to each other
(`ConvertResult2FIDE_TRFfile` `:1019-1038`, `ConvertResult2JAVAFO_TRNfile`
`:1041-1063`, `ConvertResult2FRBE_TRNfile` `:1065-1085`) and share a switch
over the same `RESULT` enum:

| Result | → FIDE | → JAVAFO | → FRBE |
|---|---|---|---|
| `WIN` / `DRAW` / `LOST` | `1` / `=` / `0` | `1` / `=` / `0` | `1` / `=` / `0` |
| `DRAW_ZERO` | `=` | `=` | `=` |
| `ZERO_DRAW` | `0` | `0` | `-` |
| `WIN_BYE` / `DRAW_BYE` / `LOST_BYE` | *(cases commented out — falls to default)* | `+` / `=` / `-` | `+` / `=` / `-` |
| `WIN_FF` | `+` | `+` | `+` |
| `DRAW_FF` | **`H`** | `=` | `=` |
| `LOST_FF` | `-` | `-` | `-` |
| `ZERO_ZEROFF` / `ZERO_ZERO` | `-` / `-` | `-` / `0` | `-` / `-` |
| default | ` ` (space) | ` ` (space) | ` ` (space) |

Pass two was right that the three disagree over a bye, and the table above
shows it plainly: the FIDE encoder's `WIN_BYE`/`DRAW_BYE`/`LOST_BYE` cases are
literally commented out in the source (`Utils.cpp:1027-1029`, each preceded by
`//`), so a bye reaching this switch falls through to `default: return " ";` —
a blank — where the other two encoders return `+`/`=`/`-`.

### 2.2 Which encoder is used where

All three are reached only through one dispatcher, `ConvertResult2TRN`
(`Utils.cpp:1087-1097`), which switches on a shared global,
`EnvoiDesResultats`. That global is set to `SEND_JAVAFO` right before
`EcrireRondesJAVAFO` writes JaVaFo's `.trn` (`EnvoiJAVAFO.cpp:179`), and to
`SEND_FIDE`/`SEND_FRBE` from two menu handlers in `SwarView.cpp` (`:3349`,
`:3371`) before the arbiter's chosen "send results" report runs. A
repository-wide search finds exactly three call sites for
`ConvertResult2TRN`, one per destination: `EcrireRondesFIDE`
(`EnvoiFIDE.cpp:452-494`), the FRBE round writer (`EnvoiFRBE.cpp:282-366`),
and `EcrireRondesJAVAFO` (`EnvoiJAVAFO.cpp:176-197`). So the three-way
disagreement in §2.1 is real in the source and is reached by three genuinely
different features — the periodic FIDE rating submission, the Belgian
federation's own Elo submission, and the pairing request sent to JaVaFo — not
by one function calling another in some redundant way.

### 2.3 The bye disagreement itself: real in the switch, dead at every call site

None of the three writers actually lets a bye reach `ConvertResult2TRN`.
Each one tests `r->Table` for the bye/absence/forfeit sentinels **before**
falling through to the generic encoder, and returns early:

* `EcrireRondesFIDE` checks `TABLE_BYE` (`EnvoiFIDE.cpp:458`), `TABLE_ABSENT`
  (`:469`) and `TABLE_FORFAIT` (`:480`) in turn, writing a literal
  `"0000 - U"`/`"H"`/`"Z"`/`"Z"` row for each and returning; only then does it
  fall into "cas normaux" and call `ConvertResult2TRN` (`:491`).
* The FRBE writer does the same three checks, in the same order
  (`EnvoiFRBE.cpp:325`, `:338`, `:345`), before its own two calls to
  `ConvertResult2TRN` (`:357`, `:364`).
* `EcrireRondesJAVAFO` branches differently but reaches the same result: a
  bye has no opponent (`r->Advers < 1`), and any round with `r->Advers < 1`
  goes to `GetJavafoChar` (`EnvoiJAVAFO.cpp:192`, already read by pass two),
  never to `ConvertResult2TRN`, which is reserved for `r->Advers > 0`
  (`:182-186`).

`PairingSwiss.cpp`/`PairingRobin.cpp`/`PairingManual.cpp` set `Table` and
`Result` together whenever a bye is assigned (pass two's §4.1), so this
pre-filtering is not fragile in the way some SWAR forcing paths are — a bye
result without the matching `Table` sentinel is not a state the pairing code
produces. **Verdict: the disagreement is real, but it is dead code.** No file
either program writes or reads is affected by it. Worth recording so a future
change to any of the three writers — adding a fourth call site, say — does not
wake up a silent three-way inconsistency that has sat there unexercised.

### 2.4 F24 — chasing the question into SWAR's own TRF importer

The task this pocket was actually set was "does any of this reach a file
OpenPairings reads or writes". §2.3 answers "no" for the specific
three-way disagreement pass two flagged — but tracing that question the rest
of the way, into SWAR's *importer*, turns up something that reaches exactly
such a file, and matters more.

**VERIFIED.** `GetResult` (`ImportTrfFile.cpp:597-616`), the function SWAR's
TRF-file reader uses to turn a result letter back into its internal `RESULT`
enum, maps:

| TRF letter | SWAR's own comment | → internal `RESULT` |
|---|---|---|
| `U` | "VRAI Bye" (true bye) | `WIN_BYE` |
| `H` | "Absent donc non jouées" (absent, so not played) | **`DRAW`** |
| `F` | *(uncommented)* | **`WIN`** |
| `Z` | *(uncommented)* | **`LOST`** |

`H`, `F` and `Z` are exactly FIDE's three arbiter-decided bye codes —
Ainalrami's own `@result_codes` names them `half_point_bye`, `full_point_bye`
and `zero_point_bye` (`deps/ainalrami/lib/ainalrami/trf.ex:250-253`), and
excludes all three from `game_was_played?/1`
(`trf.ex:430-431`, `~w(+ - H F U Z)`). SWAR's own importer instead folds them
into plain `DRAW`/`WIN`/`LOST` — results that carry **no** "this was not
played" tag at all: `DRAW = 0x2000`, `WIN = 0x4000` and `LOST = 0x1000` are
all members of `RESULTATS_NORMAUX` (`Swar.h:239`), and none is a member of
`RESULTATS_NON_JOUES` (`Swar.h:244`, `RESULTATS_BYE | RESULTATS_FORFAITS`).

It gets worse in the same function. The caller, `GetResultats`
(`ImportTrfFile.cpp:665-687`), sets `r->Table = 0` unconditionally for **every**
imported round — its own comment explains why: "pas de n° de table mais -1 ==
non jouée, donc on y met 0" (no table number, but -1 means "not played", so we
put 0 here) (`:681`). So the *other* channel SWAR normally uses to detect an
unplayed round — `r->Table & TABLE_NON_JOUEE`, the same test §1.2 just showed
gating every tiebreak's correction logic — is also unavailable after a TRF
import: `0 & 0x7000` is always `0`. The only surviving signal for "was this
round actually played" is `r->Result`'s bitmask, and for `H`/`F`/`Z` that
signal has just been erased.

**Concretely:** a player who received a half-point bye (`H`), a full-point bye
(`F`) or a zero-point bye (`Z`) in an imported TRF file becomes, inside SWAR,
indistinguishable from a player who actually drew, won, or lost an
over-the-board game — against opponent `#0000` (`r->Advers = atoi(rnk)`,
`:683`, and the rank field of a bye row is `"0000"`). Every downstream
tiebreak this pass and pass two read — `GetLastRoundWithResult`'s own
`NbBye`/`NbResult` split (§1.1), `TieBucholtz`'s dummy-opponent correction
(`Classement.cpp:1181-1184`, gated on `RESULTATS_NON_JOUES`/
`TABLE_NON_JOUEE`), the presence-points logic, the round-played count — would
misread that round.

**This reaches a file OpenPairings writes today.** `bye_code/1`
(`pairing.ex:3062-3073`) and `future_bye_code/1`
(`trf_export.ex:406-407`) both emit `F`, `H` and `Z` for the corresponding bye
types, matching `Ainalrami.Trf.result_codes/0` exactly, which is the correct,
spec-conformant choice — Ainalrami's own importer preserves the "not played"
tag for all three (`@bye_codes`, `trf.ex:507`), so nothing is wrong on
OpenPairings' side of this exchange. The hazard is one-directional and lands
entirely on SWAR: **a TRF file OpenPairings exports, if opened in SWAR, will
have every bye silently reinterpreted as an ordinary rated game the moment
SWAR reads it.** `U` (pairing-allocated bye) is the one code that survives the
round trip correctly, because it is the only one `GetResult` maps back onto a
dedicated `RESULT` value (`WIN_BYE`) rather than folding into a normal one.

**Verdict: a defect on SWAR's side**, not fixable here, and there is nothing
to change in OpenPairings — its export already writes the standard codes
correctly, and reading is not affected since OpenPairings never reads a file
back through SWAR's importer. Worth a warning in `docs/swar-import.md`,
because the realistic way an arbiter hits this is exporting a TRF from
OpenPairings mid-tournament and opening it in SWAR for a second opinion or a
legacy step — exactly the kind of workflow this audit's scope exists to keep
predictable.

### 2.5 F25 — a smaller, live anomaly: `DRAW_FF` encodes as `H`

**VERIFIED, live, low practical weight.** Unlike the bye codes, `DRAW_FF` (a
forfeit result ruled a draw) genuinely does have a real opponent assigned —
it is set by `GetResult` on import (`'D' → DRAW_FF`, `ImportTrfFile.cpp:604`)
and displayed as `"½ff"` in the crosstable (`ConvertResult2Tableau`, read in
pass two). Because it carries a real opponent, `EcrireRondesFIDE`'s
`TABLE_BYE`/`TABLE_ABSENT`/`TABLE_FORFAIT` pre-filter (§2.3) does **not** catch
it — it falls into "cas normaux", finds the real opponent, and
`ConvertResult2FIDE_TRFfile` returns `H` for it (`Utils.cpp:1031`, the switch
in §2.1). The resulting row names a real opponent and a real colour, then
tags the game with `H` — the bye-only code — producing a row shaped like
`"  12 w H  "` that is not a well-formed TRF bye row (which should carry
`"0000"` and no colour) and not a well-formed played-game row either (`H` is
not a playing code).

SWAR's own importer does not even recover `DRAW_FF` from this: `GetResult`
maps `H → DRAW` (§2.4), so re-reading SWAR's own FIDE-mode export of a
`DRAW_FF` game turns it into a plain draw against that opponent, silently
dropping the forfeit tag — while `D` is the letter SWAR's own importer treats
as the natural inverse of `DRAW_FF` (`ImportTrfFile.cpp:604`). The encoder and
the importer disagree with each other inside the same program.

**Verdict: a defect on SWAR's side**, and a minor one — `DRAW_FF` requires an
arbiter to rule a forfeit a draw, which is an unusual, board-specific
decision, not a configuration any tournament runs by default. No OpenPairings
state maps onto it (a forfeit here is always a win or a loss, never a draw),
so there is nothing to compare and nothing to fix. Recorded here rather than
in `docs/swar-import.md`, in line with that file's own practice of holding
divergences until they're actually reported (see its closing "None of them is
worth an arbiter's attention until it is reported" note on a comparable
small finding).

---

## 3. `TournoiReadWrite.cpp`'s `ReadStr`/`ReadInt` primitives

**VERIFIED both sides.** These are not defined in `TournoiReadWrite.cpp`
itself — they live in `Utils.cpp` (`ReadStr` `:2057-2067`, `ReadInt`
`:2082-2084`) and are called throughout `TournoiReadWrite.cpp`'s field-by-field
`[TOURNOI]`/`[JOUEURS]`/`[RONDE]` reads, which is why pass two filed them
under that file.

Both are plain binary I/O with no business logic: `ReadInt` reads a raw
4-byte int. `ReadStr` reads a 4-byte length prefix, then that many bytes into
a fixed 1025-byte buffer, null-terminating at whichever is smaller. There is
no length validation on the read itself — `f.Read(buf, i)` copies `i` bytes
into the 1025-byte `buf` regardless of `i`, so a corrupted or hand-edited
`.swar` file with an oversized string-length field would overflow SWAR's own
stack buffer. This is a memory-safety issue in proprietary C++, not a
behavioural one, and it is not reachable through normal use — SWAR itself
never writes a string anywhere close to 1024 bytes. OpenPairings' equivalent,
`read_str/1` (`swar_import.ex:31-34`), matches on an exact byte count with no
fixed-size buffer to overflow; an oversized length simply fails the binary
match and returns an error tuple, safely. Worth one sentence for contrast, not
a finding — there is no shared file-format behaviour here for the two programs
to disagree about, only a robustness difference that never surfaces in a file
either program actually produces.

**Verdict: nothing.** This closes the item with no new material — confirming,
as pass two suspected, that these primitives were the least likely part of
tier A to return anything, and they didn't.

---

## 4. Tier A, closed

| Item | State |
|---|---|
| `Categories.cpp` | Done — pass one. |
| `Classement.cpp` | Done — pass two, read in full. |
| `EnvoiJAVAFO.cpp` | Done — pass two, read in full. |
| `XtraPoints.cpp` | Done — pass two, read in full. |
| `TournoiReadWrite.cpp` | Done — pass two for the structural reads, this pass for `ReadStr`/`ReadInt` (§3). |
| `Utils.cpp` | Done — pass one/two for the shared predicates and category math, this pass for the round-horizon functions (§1) and the three result encoders (§2). The `Format*`/`Write*` display and CSV-writer helpers (~900 lines) were deliberately never read: no OpenPairings counterpart exists for description/formatting code to diverge from. |

That closes every item pass one's §1 and pass two's §8 scoped into tier A.
Three passes, 8 + 14 + 3 = 25 numbered findings across all three documents,
of which two here (F23, F24) are new SWAR-side defects worth an arbiter's
attention, one (F25) is a new SWAR-side defect too small to act on yet, and
the rest of this pass's reading (§1.5, §2.2-2.3, §3) closed out questions
with "nothing to report" — a real result, not a gap.

Tier B remains what pass one costed it at (~2 further sessions, low expected
yield, the logic scattered inside MFC dialog wiring) and what pass two's own
§8 left it as: not worth a scheduled pass. The symptom-driven pattern both
earlier passes recommend — read the specific file only when a real report
points at it — is the right way to spend any further time here.

---

## 5. Documentation updated in this pass

* **`docs/swar-import.md`**, "Tiebreaks: two places our numbers legitimately
  differ from SWAR's" section — retitled to three places and given a new §3
  (F23: the round-horizon divergence, arbiter-facing, with the same "what not
  to do about it" framing as the other two).
* **`docs/swar-import.md`** — a new section on re-opening an OpenPairings-
  exported TRF file in SWAR (F24): the concrete hazard, which bye types are
  affected, and that `U` (pairing-allocated bye) is the one that survives.
* **`TODO.md`** — the tier A entry closed out per §4 above: what was read,
  what was deliberately skipped and why, and that nothing new is actionable
  as an OpenPairings code change (both new findings are SWAR-side, documented,
  not fixed).
* **`CHANGELOG.md`** — not touched. No behaviour in this repository changed;
  an audit that finds SWAR-side defects and a closed reading list does not
  get a changelog entry.
