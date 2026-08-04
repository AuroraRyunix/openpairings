# FIDE pairing-program endorsement: readiness checklist

Source documents (FIDE C.04, Systems of Pairings and Programs Commission):

- [Annex 4 — Verification Check List (VCL)](https://spp.fide.com/wp-content/uploads/2020/04/C04Annex4_VCL19.pdf)
  — 19 numbered requirements an endorsed program must meet.
- [Annex 1 — Endorsement application form (FE1)](https://www.fide.com/FIDE/handbook/C04Annex1_FE1.pdf)
  — what an applicant declares, including the auto-test report.

This doc exists to (1) work out which VCL items even apply to OpenPairings
given its architecture, (2) record current status against the ones that do,
and (3) turn FE1's testing requirement into a concrete build plan. It is a
readiness assessment, not a completed audit — see "Needs verification" items
below for what still wants a real look at the code before it's marked done.

## The framing that changes everything: OpenPairings doesn't pair

FE1 asks applicants to declare **"Internal engine: YES / NO"** — FIDE's own
form anticipates that a Tournament Handler Program (THP) might *not*
implement Dutch-system pairing itself and instead call an already-endorsed
engine. That's exactly OpenPairings' situation: `PairingsEngine.Pairing`
builds a TRF16 file and hands it to `javafo.jar` (Roberto Ricca's JaVaFo,
already FIDE-endorsed) via `-p`, then reads the result back — see
`docs/AGENTS.md`.

That reframes the whole checklist. **Section A (FIDE Mode) and most of
Section B (Pairing) describe JaVaFo's obligations, already discharged by its
own endorsement — not OpenPairings'.** What *is* squarely OpenPairings'
responsibility is everything in between: constructing correct input for
JaVaFo, correctly interpreting its output, and everything downstream that
OpenPairings computes itself rather than delegating (tiebreaks, byes, result
validation, TRF import/export). That's not a hunch — it's also exactly where
the two real bugs found and fixed earlier this session lived (the Article
16.4 tiebreak formula, and TRF-input ordering) — both integration-layer bugs
in OpenPairings' own code, with JaVaFo itself never at fault.

## Checklist against that framing

### A — FIDE Mode Requirements (VCL.01–06)

Inherited from JaVaFo's own endorsement — not applicable to audit on
OpenPairings' side, with one exception:

- **VCL.06** ("the word FIDE cannot be used for any pairing-related service
  that is currently not endorsed") — worth a pass over the UI copy to make
  sure nothing implies OpenPairings itself holds an endorsement it doesn't
  (it correctly calls an endorsed engine, but should never *say* "FIDE
  pairing" in a way that reads as a claim about OpenPairings itself). **Needs
  verification** — grep the UI strings.

### B — Pairing Requirements (VCL.07–10)

- **VCL.07** (pairings strictly adhere to the rules) — the algorithm itself
  is JaVaFo's job, already discharged by its own endorsement; a pairing
  *checker* only verifies "is this pairing legal given this input," so it
  can't distinguish a correct pairing from a correct-but-garbage-input one
  — see "why a plain checker isn't the right tool" below. What actually
  needs an ongoing, automated answer is narrower: **did OpenPairings
  correctly build the input it hands JaVaFo, and correctly record what
  comes back** — ordinary data-transformation correctness, not pairing
  legality.
- **VCL.08** (pairing by pairing number, not rating) — OpenPairings' TRF
  input keys everything off `pairing_number`; ratings only affect the
  Dutch-system algorithm inside JaVaFo itself, per spec. **Satisfied.**
- **VCL.09** (pairing numbers frozen after round 4 is paired) — grepped for
  an enforcement point in `players_live.ex`/`tournaments.ex` and found none.
  **Gap** — nothing currently stops editing/reordering `pairing_number`
  (e.g. via a player edit, or a re-import) after round 4. Worth its own
  backlog item regardless of endorsement plans, since SWAR/Swiss-Manager
  both enforce this and an accidental mid-event renumber would be a real
  footgun for an arbiter using OpenPairings live.
- **VCL.10** (FIDE handbook C.04.5 acceleration systems) — Baku acceleration
  is implemented (`docs/acceleration.md`); C.04.5 as currently in force
  specifies Baku as the standard method. **Satisfied**, but worth confirming
  the current handbook doesn't list a second acceleration variant alongside
  Baku that would also need coverage — **needs verification** (re-read
  C.04.5 in full, not just the acceleration article referenced when Baku was
  built).

### C — Import/Export Requirements (VCL.11–12)

- **VCL.11** (TRF16 import mandatory, TRF06 recommended) — TRF16 import
  exists (`PairingsEngine.TrfImport`, `docs/trf-import.md`). Grepped for
  TRF06 support and found none. **Gap (non-blocking — "recommended" not
  "mandatory")** — a TRF06 importer would mean supporting the older,
  narrower column layout FIDE retired in favor of TRF16; low priority unless
  a real TRF06 file surfaces that needs importing.
- **VCL.12** (TRF16 export analyzable by a pairing-checker, even under a
  non-default scoring system; UTF-8 recommended) — the recent Swiss-Manager
  parity work (`docs/import-export.md`) already aimed the export format at
  exactly this ("analyzable by a pairing-checker" is a good description of
  what the RTG/FPC harness below would exercise directly). Elixir strings
  are UTF-8 natively and the export has no encoding conversion step, so this
  should already hold — **needs verification**: confirm the actual HTTP
  response headers declare UTF-8 explicitly (`ExportController.trf/2`),
  since a missing/wrong `charset` on the response can still cause a
  downstream tool to misread accented names even when the bytes themselves
  are correct.

### D — Tournament Requirements (VCL.13–19)

All of this is OpenPairings' own responsibility (JaVaFo never sees results,
only pairings) — the highest-value section to actually verify:

- **VCL.13** (½-0 / 0-½ / unforfeited 0-0 must be supported; 1-½ / 1-1 must
  be rejected) — `Trf.@legal_result_pairs` and the result-entry UI
  (`pairings_live.ex`'s `@results`) support symmetric `1-0` / `½-½` / `0-1`
  and played `0-0`, and `Trf.validate_games!/1` already rejects illegal
  pairs. Grepped for an asymmetric `½-0` / `0-½` result code specifically
  and found nothing. **Gap** — there's currently no way to record a
  administratively-decided asymmetric score (one side ½, the other 0) for a
  single game, only the symmetric draw. Needs research first: FIDE's own
  TRF16 result-code table doesn't have an obvious single-code slot for this
  (unlike win/draw/loss/the two forfeit codes) — work out how FIDE itself
  expects this encoded in a TRF row pair before designing the fix.
- **VCL.14** (forfeit results limited to `1F-0F` / `0F-1F` / `0F-0F`, no
  forfeit draws) — implemented exactly as `1-0FF` / `0-1FF` / `0-0FF` in
  `pairings_live.ex` and `Trf`'s result codes; no forfeit-draw option exists
  in the UI at all. **Satisfied.**
- **VCL.15** (adjourned/postponed games, if supported, managed properly) —
  OpenPairings doesn't support adjournment as a distinct state at all (a
  result is either entered or blank). **N/A** — nothing to verify since the
  feature doesn't exist; only relevant if adjournment support is ever added.
- **VCL.16** (pairing-allocated bye value configurable) — `bye_value` is a
  per-tournament setting (`docs/pairing-systems.md` / extra-points config).
  **Satisfied.**
- **VCL.17** (half-point byes assignable; full-point byes must carry a
  deprecation warning if offered at all) — OpenPairings offers
  `requested-half` (H) and `requested-zero` (Z) as arbiter-assignable bye
  types; there is no arbiter-facing "assign a full-point bye" option at all
  (`F` only appears internally, derived from a forfeit-win result, never as
  a direct assignment). **Satisfied — and more conservative than the
  requirement**, since not offering the deprecated option at all sidesteps
  needing the warning.
- **VCL.18** (official FIDE rating list readily available, or adequate
  arbiter facilities) — `PairingsEngine.Fide.Sync` keeps a local synced copy
  with autofill on player entry (`docs/rating-refresh.md`). **Satisfied.**
- **VCL.19** (every included tiebreak tested against the FIDE Handbook's own
  rules) — `PairingsEngine.Standings` implements BH, BHC1, BHC2, MBH, SB, DE,
  WIN/WON, BPG, PS, KS, ARO, AROC1 per C.07, with `standings_test.exs`
  covering them — including the real Article 16.4 bug fixed this session,
  found only by testing against the literal handbook text and a real
  tournament rather than trusting the existing formula. **Substantially
  satisfied, but this is exactly the category where the previous bug lived**
  — worth treating "add a test against the handbook's literal wording" as a
  standing habit for every tiebreak, not a one-time pass. **Needs
  verification**: confirm every one of the twelve codes above has at least
  one test asserting against a hand-worked example from the Handbook itself
  (not just against the app's own prior output), the way the 16.4 fix's new
  test does.

## The FE1 auto-test requirement — and why a plain checker isn't actually the right tool here

FE1's auto-test report is built from two roles: an **RTG** (Random
Tournament Generator, generates rosters + simulates results) and an **FPC**
(Pairing Checker, given a completed round's TRF, judges whether the pairing
made is legal Dutch-system). FIDE's own bar — an endorsement request can't
even be submitted if the error ratio is worse than **1 difference every 500
test tournaments** — is a real, useful number, and confirms the instinct
that running a large pile of synthetic tournaments and watching for
breakage is a legitimate way to build trust. It's also worth knowing that
**neither tool needs to be built from scratch**: JaVaFo itself ships both a
Random Tournament Generator and a Pairings Checker (`-g` and `-c` modes —
see [JaVaFo's Advanced User Manual](https://www.rrweb.org/javafo/aum/JaVaFo_AUM.html)),
already sitting in `priv/javafo/javafo.jar`; several FIDE-endorsed programs
(Vega, Swiss Master, Swiss Manager) cite JaVaFo's own RTG/FPC for their own
endorsement testing rather than writing their own. bbpPairings (Miguel
Ballicora's independent, also-endorsed engine) offers the same two roles
standalone (`-g`/`-c`), and is what Swiss Sys cites for *its* testing.

**But a pairing checker answers a narrower question than it sounds like,
and it's the wrong tool for OpenPairings' actual risk.** An FPC checks one
thing: *given this exact TRF as input, is the resulting pairing legal
Dutch-system?* It has no way to know whether the TRF's own contents (each
player's recorded points, order, opponent history) correctly reflect the
real tournament — it only checks that the pairing *follows from* whatever
it was handed. That's a meaningful test of the pairing *algorithm* — but
OpenPairings doesn't have a pairing algorithm to test. It calls JaVaFo,
already FIDE-endorsed; running JaVaFo's output back through a checker
(JaVaFo's own, or even an independent one) mostly re-proves something
already proven, and would burn a lot of compute doing it.

Concretely, neither of this session's two real bugs would have been caught
by an FPC at all:

- The **Article 16.4 tiebreak bug** has nothing to do with pairing —
  tiebreak computation and pairing legality are unrelated code paths. No
  checker touches it.
- The **pairing-order bug** (feeding JaVaFo rows in the wrong sequence)
  produced a pairing a checker would call *perfectly legal* — because it
  genuinely was legal, given the (wrong) order it was handed. A checker
  can't distinguish "correct pairing from correct input" from "correct
  pairing from garbage input" — that distinction is exactly the boundary
  between JaVaFo's responsibility (given, trusted) and OpenPairings' own
  (the actual risk surface).

So the real question — the one FIDE would actually care about for a
wrapper program ("Internal engine: NO") — is **"did the frontend correctly
represent the true tournament state to the engine, and correctly record
what came back?"** That's a data-transformation correctness question, not
a pairing-legality one, and it's better answered by two more targeted
approaches:

1. **Property tests directly on the TRF-builder.** Generate random
   rosters/result-histories (`StreamData` is a natural fit), independently
   hand-compute the expected TRF fields (points, physical order, opponent
   cross-references — the same arithmetic a human checking the file by eye
   would do), and assert `Pairing.javafo_input`/`TrfExport` produce exactly
   that. No pairing engine, checker, or external binary involved — this is
   the test type that would have directly caught both real bugs, since it
   checks OpenPairings' own transformation logic against ground truth
   rather than checking a pairing's legality.
2. **Cross-program agreement at scale** — automating what already worked
   twice this session by hand (SWAR vs. OpenPairings, Swiss-Manager vs.
   OpenPairings on the same real tournament, each time surfacing a real
   bug). Generate synthetic rosters and result histories, run them through
   OpenPairings' *full* pipeline, and separately through an independent
   *full* pipeline on identical input — bbpPairings can run entirely
   standalone (no JaVaFo involved at all), so it's a genuinely independent
   second implementation, not just a second invocation of the engine
   OpenPairings already trusts. Diff the actual round-by-round pairings.
   Agreement across many random tournaments is a much stronger signal for
   *OpenPairings'* correctness than any checker verdict on JaVaFo's output,
   because it compares two independently-written pipelines' final answers
   rather than checking one engine's self-consistency.

Standings/tiebreak correctness (the other real bug's category) is already
on the right track and doesn't need any of the above — `standings_test.exs`
already tests against hand-worked FIDE Handbook examples (see VCL.19), which
is precisely the pattern that caught the 16.4 bug; more of that is the fix,
not a pairing harness.

### Proposed shape of the harness (not yet built)

1. A generator (property-based test or a `mix` task) that produces a random
   but legal tournament configuration and simulates N rounds — deliberately
   including the edge cases that have actually caused bugs so far: gaps in
   `pairing_number` (a withdrawn player), acceleration on, per-category
   pairing, forbidden pairings, round-specific absences.
2. **Data-transformation properties** (item 1 above) run directly against
   `Pairing.javafo_input`/`TrfExport` — fast, no external process, and the
   most direct test for the actual bug class already found.
3. **Cross-program agreement** (item 2 above) runs OpenPairings' real
   pairing code path (`PairingsEngine.Pairing.pair_next_round/1`) against
   bbpPairings standalone on identical synthetic input, diffing actual
   pairings round by round. Needs bbpPairings vendored as a companion
   binary (same general shape as `priv/javafo/javafo.jar` already is).
4. Log any disagreement with enough detail to reproduce exactly (the random
   seed, the roster, the round number) — a flagged round is either a real
   bug or a legitimate arbiter-discretion case (forbidden pairings,
   categories) bbpPairings doesn't model, and telling those apart is the
   actual output of running this.
5. Keep both runnable on demand (CI nightly, or a local `mix` task) rather
   than a one-off script — this is a standing confidence check, not a
   single audit. FIDE's 1-per-500 ratio remains a reasonable target for the
   cross-program-agreement half specifically, even though it's not the
   metric this project would submit to FIDE for anything.

This is deliberately scoped as a plan, not code — see the Backlog below for
the concrete next steps once building starts.
