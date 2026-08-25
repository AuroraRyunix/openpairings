# FIDE pairing-program endorsement: readiness checklist

Source documents (FIDE C.04, Systems of Pairings and Programs Commission):

- [Annex 4 - Verification Check List (VCL)](https://spp.fide.com/wp-content/uploads/2020/04/C04Annex4_VCL19.pdf)
  - 19 numbered requirements an endorsed program must meet.
- [Annex 1 - Endorsement application form (FE1)](https://www.fide.com/FIDE/handbook/C04Annex1_FE1.pdf)
  - what an applicant declares, including the auto-test report.
- [Annex 3 - Endorsed Tournament Managers](https://www.fide.com/FIDE/handbook/C04Annex3_EPLIST.pdf)
  - the actual list of currently-endorsed programs, with per-program
  Internal Pairing Engine / FPC / RTG details - the real precedent for how
  a no-internal-engine program (Vega, Swiss Manager, TournamentService, all
  "uses JaVaFo") answers FE1.
- [Endorsement procedure page](https://spp.fide.com/c-04-a-appendix-endorsement-of-a-software-program/)
  - submission timeline, subcommittee/Congress process, the 5000-tournament
  auto-test scale, renewal cycles.

This doc exists to (1) work out which VCL items even apply to OpenPairings
given its architecture, (2) record current status against the ones that do,
and (3) turn FE1's testing requirement into a concrete build plan. It is a
readiness assessment, not a completed audit - see "Needs verification" items
below for what still wants a real look at the code before it's marked done.

## The framing that changes everything: OpenPairings doesn't pair

FE1 asks applicants to declare **"Internal engine: YES / NO"** - FIDE's own
form anticipates that a Tournament Handler Program (THP) might *not*
implement Dutch-system pairing itself and instead call an already-endorsed
engine. That's exactly OpenPairings' situation: `PairingsEngine.Pairing`
builds a TRF16 file and hands it to `javafo.jar` (Roberto Ricca's JaVaFo,
already FIDE-endorsed) via `-p`, then reads the result back - see
`docs/AGENTS.md`.

That reframes the whole checklist. **Section A (FIDE Mode) and most of
Section B (Pairing) describe JaVaFo's obligations, already discharged by its
own endorsement - not OpenPairings'.** What *is* squarely OpenPairings'
responsibility is everything in between: constructing correct input for
JaVaFo, correctly interpreting its output, and everything downstream that
OpenPairings computes itself rather than delegating (tiebreaks, byes, result
validation, TRF import/export). That's not a hunch - it's also exactly where
the two real bugs found and fixed earlier this session lived (the Article
16.4 tiebreak formula, and TRF-input ordering) - both integration-layer bugs
in OpenPairings' own code, with JaVaFo itself never at fault.

**Confirmed against real precedent, not just inferred from a checkbox.**
[Annex 3 - Endorsed Tournament Managers](https://www.fide.com/FIDE/handbook/C04Annex3_EPLIST.pdf)
(the actual list of currently-endorsed programs) shows three with
OpenPairings' exact architecture:

| Program | Internal Pairing Engine | FPC availability | RTG availability |
|---|---|---|---|
| Vega | NO *(uses JaVaFo)* | thru JaVaFo | thru JaVaFo |
| Swiss Manager | NO *(uses JaVaFo)* | thru JaVaFo | thru JaVaFo |
| TournamentService | NO *(uses JaVaFo)* | thru JaVaFo | thru JaVaFo |

versus the ones with their own engine (Dubov, JavaPairing, Swiss Master,
Swiss-Chess), whose FPC is their own binary (e.g. `swiss.exe /trf
tournament_TRF`). A program with `Internal Pairing Engine: NO` answers
FE1's FPC/RTG fields **"thru JaVaFo"** - pointing at JaVaFo's own `-c`/`-g`
modes - instead of building and running its own 5000-tournament auto-test.
JaVaFo's own endorsement already covers VCL.07 (pairing legality) for
every program built this way; that's the actual, demonstrated reason
Vega/Swiss Manager/TournamentService never had to clear that bar
themselves. This is no longer a hunch about what an unstated checkbox
might mean - it's the documented behavior of three real, currently-listed
endorsements.

### "But OpenPairings can now select Ainalrami" - and since 2026-08-25 it does by default

A tournament carries a `pairing_engine` setting and can be pointed at
[Ainalrami](https://github.com/AuroraRyunix/Ainalrami), a from-scratch
Dutch engine that genuinely does pair. **It is now the default**, and the
only thing still guaranteed about it is that it cannot change mid-event:
the setting joins `Tournaments.locked_fields/1`, so whichever engine paired
round 1 pairs the rest.

Read this section as history in two steps, because both steps matter to
anyone filing.

**2026-08-21.** `pairing_engine: "ainalrami"` used to be REFUSED by
`Tournament.changeset/2` on any `fide_homologated` tournament, in both
directions - the engine could not be set on a homologated event, and
homologation could not be ticked on an event already running Ainalrami.
That block is what made "every FIDE-rated round this program ever produces
is a JaVaFo round" literally true. It became a warning instead: the
arbiter may choose Ainalrami for a rated event, and the UI says plainly
what it costs.

**2026-08-25.** The default flipped. JaVaFo 2.2 implements C.04.3 as it
stood in 2022 and has not been updated for the edition effective
1 February 2026, so leaving it as the default meant handing arbiters
superseded pairings by default. Ainalrami implements the current text.

The reason for allowing it is that refusing asserted a quality judgement
the measurements do not support - Ainalrami agrees with bbpPairings across
2,536,328,265 individual pairings (217,470,056 rounds, 6 corpora, 82
distinct axes, as of 2026-08-24), with two disagreements that are both
defects in
bbpPairings rather than in Ainalrami. Where it differs from JaVaFo it is on
Article 5.2.5's TPN parity, where it follows the handbook text and JaVaFo
carries pre-2026 behaviour.

The consequence for THIS document is unavoidable and must not be papered
over: **"Internal engine: NO - thru JaVaFo" is no longer true of what
OpenPairings normally does.** It was never unconditionally true after
2026-08-21; since 2026-08-25 the ordinary case is the other way round, and
a JaVaFo round is the one that takes a deliberate override.

That is a decision, not an oversight - see the changelog entry for the
flip. But it means the framing this whole document is built on has expired
as a description of the shipped default. Anyone filing FE1 has to either
declare `Internal engine: YES` and apply for Ainalrami on its own merits,
or restore JaVaFo as the default for the duration of the application.
Filing the old sentence unchanged is not one of the options. If Ainalrami is ever *intended* to
be declared to FIDE, that is a separate application with `Internal Pairing
Engine: YES`, its own FPC/RTG statements, and the full 5000-tournament
auto-test described below - and it would be applied for by Ainalrami, not
smuggled in under this answer. See `docs/pairing-systems.md`.

Worth noting for that eventual conversation: Ainalrami already implements
both of FE1's calling statements itself (`-c` pairings checker, `-g` random
tournament generator, deliberately mirroring JaVaFo's own CLI shape), which
is exactly the pair of things an `Internal engine: YES` applicant has to
supply.

## What FIDE actually requires you to submit (confirmed from the primary sources)

Read directly, not summarized from memory - [FE1](https://www.fide.com/FIDE/handbook/C04Annex1_FE1.pdf)
and the [endorsement-procedure page](https://spp.fide.com/c-04-a-appendix-endorsement-of-a-software-program/):

**The application (FE1) itself** - program identity, author contact,
download details, whether it's free software, and two yes/no
specifications: **"Internal engine: YES/NO"** and, if either exists, the
program's own **FPC** (pairing checker) and **RTG** (random tournament
generator) calling statements. Then an **auto-test report** with two
distinct blocks the applicant fills in themselves before ever submitting:

1. **Internal FPC vs. a reference RTG** - an independent/reference Random
   Tournament Generator produces the test tournaments; the applicant's own
   pairing checker verifies the applicant's own engine's pairings against
   them. Reported: number of test tournaments, rounds per tournament
   (min/max/avg), and number of rounds with a pairing difference.
2. **Internal RTG vs. a reference checker** - the reverse: the applicant's
   own RTG generates the test tournaments, and an independent/reference
   checker verifies the applicant's pairings. Same reported fields.

**The hard bar, FE1's own words**: *"an Endorsement Request can be received
only if the error ratio is not worse than 1 difference every 500 test
tournaments."* The procedure page gives the concrete production-scale
version of the same ratio: **5000 random tournaments, at most 10
discrepancies** (5000/10 = the same 1-per-500). Each discrepancy gets
triaged three ways: an input-file/RTG-provider error, a genuine
candidate-program error (must be fixed "in a reasonable time-frame"), or a
rules-interpretation dispute escalated to the SPPC itself.

**This is a slow, human, discretionary process, not a test suite you run
once.** For a brand-new pairing system, "a subcommittee of four people must
be named by the SPPC at the first Congress that follows the application"
and reports back at the *next* Congress - i.e., potentially a full year.
Applications for an already-endorsed system move faster (automated testing
first, then Congress approval), but FE1 still has to reach the SPPC
secretariat "at least four months before the Congress." Endorsements run on
**four-year cycles starting January 1 of leap years** (2028, 2032, ...); at
each cycle's transition, even already-endorsed programs must re-pass or be
delisted, with an "interim certificate" possible mid-transition. Post-
endorsement, a discovered error must be fixed within **two weeks (major)**
or **two months (minor)**, or the endorsement is automatically suspended.
Meeting every technical requirement doesn't guarantee endorsement either -
**the Commission retains discretionary approval authority** on top of the
checklist.

**What this means concretely for "when can we test a shitload of
tournaments"**: per the Annex 3 precedent above, OpenPairings likely
doesn't need to build or run its own 5000-tournament FPC/RTG auto-test at
all for FE1 itself - "thru JaVaFo" is the expected answer, same as
Vega/Swiss Manager/TournamentService, since JaVaFo's own endorsement
already covers pairing legality. The fuzz harness (below) is still
genuinely valuable, just for a different reason than satisfying FE1's
auto-test fields: it's due diligence on the actual bug class that bit this
project twice - OpenPairings feeding JaVaFo *wrong* input that still comes
back looking legal - which is squarely OpenPairings' own responsibility
regardless of which engine box gets ticked. `cross_program_test.exs`
against `bbpPairings`, run at real scale (`PAIRING_FUZZ_COUNT=5000`,
matching FIDE's own number), is evidence of integration-layer correctness
worth having on hand for its own sake, not because FE1 requires it.

## Checklist against that framing

### A - FIDE Mode Requirements (VCL.01-06)

Inherited from JaVaFo's own endorsement - not applicable to audit on
OpenPairings' side, with one exception:

- ~~**VCL.06**~~ ("the word FIDE cannot be used for any pairing-related
  service that is currently not endorsed") - **verified, one real fix
  made**. Grepped every user-facing "FIDE" mention across `lib/` - nearly
  all are factual (FIDE's own rating list/data source, a tournament's own
  FIDE-homologation status, FIDE's own system/tiebreak names) or internal
  developer docs correctly describing JaVaFo (the actually-endorsed
  component) as endorsed. One real issue: the login page's hero copy read
  "FIDE-compliant pairings, tie-breaks and norm reports" - an unqualified
  claim about OpenPairings itself, which isn't endorsed. Reworded to credit
  JaVaFo by name and describe FIDE's rules/formats rather than claiming
  OpenPairings' own compliance; softened the same phrasing in
  `README.md`/`docs/README.md` for consistency.

### B - Pairing Requirements (VCL.07-10)

- **VCL.07** (pairings strictly adhere to the rules) - the algorithm itself
  is JaVaFo's job, already discharged by its own endorsement; a pairing
  *checker* only verifies "is this pairing legal given this input," so it
  can't distinguish a correct pairing from a correct-but-garbage-input one
  - see "why a plain checker isn't the right tool" below. What actually
  needs an ongoing, automated answer is narrower: **did OpenPairings
  correctly build the input it hands JaVaFo, and correctly record what
  comes back** - ordinary data-transformation correctness, not pairing
  legality.
- **VCL.08** (pairing by pairing number, not rating) - OpenPairings' TRF
  input keys everything off `pairing_number`; ratings only affect the
  Dutch-system algorithm inside JaVaFo itself, per spec. **Satisfied.**
- ~~**VCL.09**~~ (pairing numbers frozen after round 4 is paired) -
  **shipped**: `Tournaments.update_player/2` rejects changing an
  already-assigned `pairing_number` once 4 rounds are paired (FIDE
  C.04.2.B.3); a first-ever assignment (late entry) always works.
- ~~**VCL.10**~~ (FIDE handbook acceleration systems) - **verified,
  Satisfied**. The chapter itself moved: acceleration is no longer C.04.5
  (that number is now "Double-Swiss Pairing System") - it's
  [**C.04.7, "FIDE-approved Accelerated Systems"**](https://handbook.fide.com/chapter/C0407202602)
  as of the 1 February 2026 revision (current now). Despite the plural
  title, Baku remains the *only* system actually described - the chapter
  closes by noting additional methods "may exist" once "statistically
  proven," i.e. a placeholder for the future, not a second currently-
  approved system today. `docs/acceleration.md`'s Baku implementation
  needs no second variant. Worth a standing reminder: cite the *current*
  chapter number (C.04.7, not C.04.5) anywhere this comes up again - FIDE
  renumbers these under revision.

### C - Import/Export Requirements (VCL.11-12)

- ~~**VCL.11**~~ (TRF16 import mandatory, TRF06 recommended) - **both
  shipped**. TRF16: `PairingsEngine.TrfImport`, `docs/trf-import.md`. TRF06:
  read FIDE's actual archived specs directly - [Annexure-B (2006)](https://tec.fide.com/wp-content/uploads/2025/10/Annexure-B-TRF06-%E2%80%93-Version-2006.pdf)
  and [Annexure-C (2016)](https://tec.fide.com/wp-content/uploads/2025/10/Annexure-C-TRF06-%E2%80%93-Version-2016.pdf)
  - rather than guessing; the player/round/tournament column positions are
  byte-identical between TRF06 and TRF16, so no separate importer was
  needed. The one real difference: TRF06 predates the F/H/U/Z bye codes
  (a bye is a dangling playing code against opponent `0000`, no dedicated
  code at all) and represents a "not paired" round as fully blank rather
  than any code. Verifying this surfaced two real bugs in `Trf`, both
  fixed: (1) `Trf.parse/1` shared its strict "opponent 0000 needs a bye
  code" validation with `serialize/1` - correct for OpenPairings' own
  JaVaFo-input construction (a genuine past crash, see VCL.07 below), wrong
  for reading someone else's TRF06 file - now an `allow_dangling_playing_code`
  option `parse/1` alone sets; (2) `parse_games/1` stopped at the *first*
  fully-blank round rather than the line's actual end, silently discarding
  every real game after it (a late entrant's blank round 1 followed by real
  round-2+ games) - now scans to where the line's real content ends.
- ~~**VCL.12** (TRF16 export analyzable by a pairing-checker, even under a
  non-default scoring system; UTF-8 recommended)~~ - **verified**. The
  recent Swiss-Manager parity work (`docs/import-export.md`) already aimed
  the export format at exactly this. UTF-8: confirmed both ways -
  `Plug.Conn.put_resp_content_type/2`'s `charset` argument defaults to
  `"utf-8"` (read the actual dependency source, not assumed), so
  `ExportController.trf/2`'s `put_resp_content_type("text/plain")` already
  sends `Content-Type: text/plain; charset=utf-8` - plus Elixir strings are
  UTF-8 natively with no encoding-conversion step in between. Locked in
  with an explicit test asserting the header (`export_controller_test.exs`)
  rather than just trusting the bytes happen to be right.

### D - Tournament Requirements (VCL.13-19)

All of this is OpenPairings' own responsibility (JaVaFo never sees results,
only pairings) - the highest-value section to actually verify:

- ~~**VCL.13** (½-0 / 0-½ / unforfeited 0-0 must be supported; 1-½ / 1-1 must
  be rejected)~~ - **shipped**. Read the actual FIDE TRF16 spec
  (C04Annex2_TRF16) directly: it has no dedicated code for the asymmetric
  case at all, and - critically - states no cross-validation rule between
  the two sides' result codes; the "opponent code must mirror mine" check
  was `Trf`'s own invention, not a FIDE requirement. So ½-0/0-½ is just `=`
  for the ½ side and `0` for the 0 side, the one legal pair that doesn't
  mirror. `Trf.@legal_result_pairs` now allows `"=" ↔ "0"`; wired through
  `Tournaments.Pairing`'s result whitelist (`"1/2-0"`/`"0-1/2"`), the
  result-entry UI, `Standings` (scored like a draw/loss respectively),
  `Pairing.trf_game/3`'s TRF-code mapping, `Keizer`'s own scoring (new
  `:half_win`/`:half_loss` classes), and both import paths (`TrfImport`,
  and `SwarImport` - whose SWAR binary format already had bitfield codes
  for exactly this, `DRAW_ZERO`/`ZERO_DRAW`, previously dropped as
  unmappable). Deliberately not added to the simplified mobile result-entry
  screen (arbiter-discretion-only call, matches that screen's existing
  narrower scope) or PGN export (no PGN equivalent exists; falls back to
  `"*"`, same as the existing double-loss "0-0" case already does).
- **VCL.14** (forfeit results limited to `1F-0F` / `0F-1F` / `0F-0F`, no
  forfeit draws) - implemented exactly as `1-0FF` / `0-1FF` / `0-0FF` in
  `pairings_live.ex` and `Trf`'s result codes; no forfeit-draw option exists
  in the UI at all. **Satisfied.**
- **VCL.15** (adjourned/postponed games, if supported, managed properly) -
  OpenPairings doesn't support adjournment as a distinct state at all (a
  result is either entered or blank). **N/A** - nothing to verify since the
  feature doesn't exist; only relevant if adjournment support is ever added.
- **VCL.16** (pairing-allocated bye value configurable) - `bye_value` is a
  per-tournament setting (`docs/pairing-systems.md` / extra-points config).
  **Satisfied.**
- **VCL.17** (half-point byes assignable; full-point byes must carry a
  deprecation warning if offered at all) - OpenPairings offers
  `requested-half` (H) and `requested-zero` (Z) as arbiter-assignable bye
  types; there is no arbiter-facing "assign a full-point bye" option at all
  (`F` only appears internally, derived from a forfeit-win result, never as
  a direct assignment). **Satisfied - and more conservative than the
  requirement**, since not offering the deprecated option at all sidesteps
  needing the warning.
- **VCL.18** (official FIDE rating list readily available, or adequate
  arbiter facilities) - `PairingsEngine.Fide.Sync` keeps a local synced copy
  with autofill on player entry (`docs/rating-refresh.md`). **Satisfied.**
- **VCL.19** (every included tiebreak tested against the FIDE Handbook's own
  rules) - `PairingsEngine.Standings` implements BH, BHC1, BHC2, MBH, SB, DE,
  WIN/WON, BPG, PS, KS, ARO, AROC1 per C.07, with `standings_test.exs`
  covering them - including the real Article 16.4 bug fixed this session,
  found only by testing against the literal handbook text and a real
  tournament rather than trusting the existing formula. **Substantially
  satisfied, but this is exactly the category where the previous bug lived**
  - worth treating "add a test against the handbook's literal wording" as a
  standing habit for every tiebreak, not a one-time pass. **Needs
  verification**: confirm every one of the twelve codes above has at least
  one test asserting against a hand-worked example from the Handbook itself
  (not just against the app's own prior output), the way the 16.4 fix's new
  test does.

  **FIDE reissued C.07 effective 1 March 2026** (currently in force -
  [handbook.fide.com/chapter/TieBreakRegulations032026](https://handbook.fide.com/chapter/TieBreakRegulations032026)),
  substantially rewriting Article 16 (unplayed-round handling for
  Buchholz/SB). Auditing `standings.ex` against the new text turned up:

  - **Fixed this session**: `pairing_records/3` marked every pairing-allocated
    bye (`Pairing.result == "bye"`, JaVaFo's own odd-player-count assignment)
    as `voluntary: true`. The separate `byes`-table path
    (`add_bye_records/3`) already correctly excluded `"pairing-allocated"`
    from its own `voluntary` set - this was a same-file inconsistency
    between two code paths modeling the identical concept, not a
    speculative reading of the new rule text. Under the new Art.
    16.2.1/16.3, a pairing-allocated bye must always count at its full
    awarded value for an opponent's tiebreak purposes, never downgraded to
    a draw when it happens to be trailing (the common case - an odd number
    of players always produces exactly one last-round bye somewhere).
    Before the fix, `adjusted_score/3` silently substituted a draw's worth
    of points for that bye whenever it landed in the trailing/voluntary
    window, understating every opponent-who-played-them's Buchholz/SB.
    Fixed by adding `and pairing.result != "bye"` to the `voluntary` check,
    with a regression test.
  - **Shipped**: Art. 16.5.1's new **"Cut-1 Exception"** - when a
    BHC1/BHC2/MBH cut removes the least significant value(s), a
    contribution coming from one of the participant's own voluntary
    unplayed rounds (VUR) is now cut in preference to an ordinary
    played-game contribution. Scope decision: only a bye round with no
    scheduled opponent (`dummy_score/3`) can ever be a VUR contribution -
    a forfeit always has a real scheduled opponent, so it routes through
    `adjusted_score/3` instead and never reaches this path - and the
    existing `g.voluntary` flag (already excluding pairing-allocated byes
    and forfeits, matching Art. 16.1's own concept) is reused as the VUR
    tag rather than inventing a second classification. `buchholz_contributions/3`
    now tags each contribution `{value, vur?}`; `cut/3`'s lowest-value
    drop picks the minimum VUR-tagged contribution when one exists (its
    minimum can never be below the overall minimum, satisfying the
    regulation's own proviso by construction), reapplied per additional
    cut for BHC2. Highest-value cuts (MBH) are untouched - 16.5.1 only
    concerns the least significant value. See `standings_test.exs`'s
    "Article 16.5.1 Cut-1 Exception" describe block for a worked example.
  - **Resolved**: SWAR's own `"absent"` bye type (no FIDE-native concept)
    is no longer unconditionally grouped into `voluntary`. New
    `Tournament.absent_counts_as_vur` field, **off by default** - an
    absence always counts at its configured award value (the forfeit-loss
    treatment, the strict/FIDE-safe reading) unless an arbiter explicitly
    opts in from Settings for the more lenient requested-bye-style
    treatment (trailing occurrences downgraded to a draw). Matches the
    project's general posture on extras beyond FIDE's own basics:
    available, never the default.

## The FE1 auto-test requirement - and why a plain checker isn't actually the right tool here

FE1's auto-test report is built from two roles: an **RTG** (Random
Tournament Generator, generates rosters + simulates results) and an **FPC**
(Pairing Checker, given a completed round's TRF, judges whether the pairing
made is legal Dutch-system). FIDE's own bar - an endorsement request can't
even be submitted if the error ratio is worse than **1 difference every 500
test tournaments** - is a real, useful number, and confirms the instinct
that running a large pile of synthetic tournaments and watching for
breakage is a legitimate way to build trust. It's also worth knowing that
**neither tool needs to be built from scratch**: JaVaFo itself ships both a
Random Tournament Generator and a Pairings Checker (`-g` and `-c` modes -
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
real tournament - it only checks that the pairing *follows from* whatever
it was handed. That's a meaningful test of the pairing *algorithm* - but
OpenPairings doesn't have a pairing algorithm to test. It calls JaVaFo,
already FIDE-endorsed; running JaVaFo's output back through a checker
(JaVaFo's own, or even an independent one) mostly re-proves something
already proven, and would burn a lot of compute doing it.

Concretely, neither of this session's two real bugs would have been caught
by an FPC at all:

- The **Article 16.4 tiebreak bug** has nothing to do with pairing -
  tiebreak computation and pairing legality are unrelated code paths. No
  checker touches it.
- The **pairing-order bug** (feeding JaVaFo rows in the wrong sequence)
  produced a pairing a checker would call *perfectly legal* - because it
  genuinely was legal, given the (wrong) order it was handed. A checker
  can't distinguish "correct pairing from correct input" from "correct
  pairing from garbage input" - that distinction is exactly the boundary
  between JaVaFo's responsibility (given, trusted) and OpenPairings' own
  (the actual risk surface).

So the real question - the one FIDE would actually care about for a
wrapper program ("Internal engine: NO") - is **"did the frontend correctly
represent the true tournament state to the engine, and correctly record
what came back?"** That's a data-transformation correctness question, not
a pairing-legality one, and it's better answered by two more targeted
approaches:

1. **Property tests directly on the TRF-builder.** Generate random
   rosters/result-histories (`StreamData` is a natural fit), independently
   hand-compute the expected TRF fields (points, physical order, opponent
   cross-references - the same arithmetic a human checking the file by eye
   would do), and assert `Pairing.javafo_input`/`TrfExport` produce exactly
   that. No pairing engine, checker, or external binary involved - this is
   the test type that would have directly caught both real bugs, since it
   checks OpenPairings' own transformation logic against ground truth
   rather than checking a pairing's legality.
2. **Cross-program agreement at scale** - automating what already worked
   twice this session by hand (SWAR vs. OpenPairings, Swiss-Manager vs.
   OpenPairings on the same real tournament, each time surfacing a real
   bug). Generate synthetic rosters and result histories, run them through
   OpenPairings' *full* pipeline, and separately through an independent
   *full* pipeline on identical input - bbpPairings can run entirely
   standalone (no JaVaFo involved at all), so it's a genuinely independent
   second implementation, not just a second invocation of the engine
   OpenPairings already trusts. Diff the actual round-by-round pairings.
   Agreement across many random tournaments is a much stronger signal for
   *OpenPairings'* correctness than any checker verdict on JaVaFo's output,
   because it compares two independently-written pipelines' final answers
   rather than checking one engine's self-consistency.

Standings/tiebreak correctness (the other real bug's category) is already
on the right track and doesn't need any of the above - `standings_test.exs`
already tests against hand-worked FIDE Handbook examples (see VCL.19), which
is precisely the pattern that caught the 16.4 bug; more of that is the fix,
not a pairing harness.

### The harness - shipped

Both halves described above are now built:

- **`test/pairings_engine/trf_property_test.exs`** - `StreamData` property
  tests directly against `Trf.serialize/1`: random-but-legal rosters and
  round histories (contiguous ranks, mutually consistent result codes),
  checked against ground truth by round-tripping through `Trf.parse/1`
  rather than re-deriving `Trf`'s own private column positions. Also covers
  illegal-result-pair rejection and control-character handling. No external
  process, runs as part of every normal `mix test`.
- **`test/pairings_engine/cross_program_test.exs`** - cross-program
  agreement: runs OpenPairings' real `Pairing.pair_next_round/1` (JaVaFo)
  against `bbpPairings` (vendored in `priv/bbppairings/`, Apache-2.0 - see
  `PairingsEngine.Test.BbpPairings`'s moduledoc for the vendoring/invocation
  details, including the one real interface divergence between the two
  engines: bbpPairings refuses to guess an unhistoried round's initial
  color, unlike JaVaFo) on byte-identical TRF16 input (captured via the
  existing `[:pairings_engine, :pairing, :trf_built]` telemetry event,
  `pairing_test.exs`'s own established pattern for this), diffing the
  actual pairing every round. `PAIRING_FUZZ_COUNT` (env var, default 8)
  controls how many synthetic tournaments run - set it much higher for a
  deliberate "throw a pile of random tournaments at it" pass, e.g.
  `PAIRING_FUZZ_COUNT=500 mix test --only javafo --only bbppairings
  test/pairings_engine/cross_program_test.exs`. Both test files are tagged
  `:javafo`/`:bbppairings` and gated in `test_helper.exs` exactly like the
  existing `:swar_fixture` pattern, so a normal `mix test` on a checkout
  without both binaries simply skips them rather than failing.

Not yet covered from the original plan: the generator doesn't specifically
target acceleration-on, per-category pairing, forbidden-pairings, or
round-specific-absence configurations - the current roster generator is a
plain flat Swiss field. Worth extending if those specific paths need their
own confidence pass; they're exactly where the two real bugs that motivated
this harness lived.

**First real finding, researched, still not conclusively resolved**: a
`PAIRING_FUZZ_COUNT=200` run found 6 disagreements (~1.2% of paired rounds)
- always small rosters (5-13 players), always a same-score-group-splitting
choice in an otherwise fully legal situation (no repeat-opponent conflicts
on either side). Verified against JaVaFo run standalone (bypassing
OpenPairings' own pipeline entirely) on the exact captured TRF to rule out
an OpenPairings-side input bug - the disagreement is genuinely between
JaVaFo and bbpPairings themselves.

Traced through the actual current C.04.3 criteria (1 Feb 2026 revision) for
the seed-12 case (5 players; round 2 score groups after round 1: {P1, P5}
both 1.0 pts and never played each other; {P2, P3} both 0.5 pts and
*already* played each other round 1; {P4} 0.0 pts alone): the absolute
criteria are ordered **[C1]** no repeat opponents, **[C2]** no second
pairing-allocated bye for the same player, **[C3]** non-topscorer colour
clash, **[C5]** minimise the score of the bye assignee - quality criteria
(**[C6]** minimise downfloaters, **[C7]** minimise their scores, ...) only
apply once C1-C5 are satisfied. ([C4] doesn't appear to exist in the
current handbook text - possibly retired in a revision, not confirmed.)

- **JaVaFo's answer**: pair the top bracket {P1,P5} together (0
  downfloaters, satisfies [C6] locally), cascade {P2,P3} down (can't pair
  each other, [C1]), merge with P4 - the only two legal single-pair options
  left are P2-P4 or P3-P4, so the bye lands on whichever of P2/P3 isn't
  chosen (P3, 0.5 pts).
- **bbpPairings' answer**: {P1-P2, P5-P3}, giving P4 (0.0 pts, the tournament-wide
  minimum) the bye instead - fully legal, and strictly better on [C5] (0.0
  < 0.5).

Since [C5] is absolute and outranks [C6], a configuration achieving a
strictly lower bye-assignee score should, by the stated priority order, be
preferred over a configuration that's merely locally tidy per bracket -
which would make bbpPairings' answer the more literally-compliant one, and
JaVaFo's greedy top-bracket-first pairing a possible edge-case deviation
from its own governing rule text.

**This is a hypothesis, not a verdict.** It's built on AI-summarized
fetches of the handbook, not primary text independently double-checked
line by line, and JaVaFo is FIDE's own actively-maintained reference
implementation (Roberto Ricca, who also sits on the SPP Commission) - real
Dutch-system pairing is a constrained search with documented subtleties
this reading may not fully capture. Concretely narrower than "engines
disagree, not sure why" was two passes ago, but still short of a confirmed
answer. What would actually resolve it: reproducing the exact seed-12 TRF
against JaVaFo's own detailed algorithm description (the AUM), or asking
the SPP Commission directly - not further inference from handbook
fetches.
