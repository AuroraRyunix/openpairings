# Feedback on the draft VCL4THP v13 and TEC Manual (30HdT)

**From:** OpenPairings (THP) / Ainalrami (pairing and tie-break engine)
**Date:** 2026-08-25
**Consultation deadline:** 2026-09-07

Thank you for circulating the drafts. We are a new entrant with no
existing endorsement, so we have no position to defend in the coming
Acceptance Cycle. What we do have is an unusually large body of
cross-implementation measurement, and most of the comments below are
things that measurement taught us rather than opinions about the text.

Everything we cite can be reproduced. Sources, harnesses and the full
per-axis figures are public at
<https://github.com/AuroraRyunix/Ainalrami>.

---

## Part A - Discrepancy reports (VCL Q37 and Q39)

Two reports are attached. They are submitted here because the draft VCL
requires it, and we would rather send them during consultation than hold
them until an application.

**A.1 - Error in another engine (Q37).** bbpPairings 6.0.0 allocates a
pairing-allocated bye to a player who already holds one, which C.04.3 art.
2.1.2 [C2] forbids absolutely. Three independent positions are attached;
in two of them the round has exactly one legal shape, reached by pure
elimination, so there is no scoring argument available. A third
implementation (the FIDE Tie-Break Server) pairs all three the way we do.
See `bbppairings-c2-bug-report.md`.

> **This section is out of date and needs a decision before the letter is
> sent.** It was written on 2026-08-25 as an open discrepancy. The SPP
> answered the question on **2026-08-28**, against us, and the engine
> conforms as of Ainalrami v0.14.0 - which is the version this app pins.
> There is no divergence left to report. Keep it as a closed-item note,
> or cut it; what it must not do is ask TEC to rule on something already
> ruled on. Flagged 2026-08-30.

**A.2 - Interpretation divergence (Q39) - RESOLVED, reported for
completeness.** Article 5.2.5 says to give the initial colour when "the
higher ranked player has an odd TPN". C.04.3 does not define TPN; it
delegates to C.04.2 art. 2, which defines it as a tournament-level number
fixed at the initial ranking. Both reference implementations instead take
the parity of a numbering that skips players who have never been paired.
We had followed the text as written and differed from both.

We put the question to the SPP on 2026-08-21. The answer, on 2026-08-28,
was that the reference implementations are right:

> The correct behaviour is (b). Why? Because of C.04.2:2.4 ... LATE
> ENTRIES ... ARE GIVEN AN APPROPRIATE TPN AND PAIRED ONLY WHEN THEY
> ACTUALLY ARRIVE. ... players who have yet to arrive don't have a TPN.

Both sides argued from that one sentence. Our case was that the TPN exists
before the arrival and it is the pairing that waits; the SPP reads the same
clause as no TPN until arrival. We conform as of Ainalrami v0.14.0.

We record it because the mechanism is worth the Commission's attention even
though the answer is settled: it decided the colour on **every board that
reaches 5.2.5 in any tournament where a player has sat a round out**, and
three programs were each confident while two agreed by coincidence of
implementation rather than by reading. C.04.3 delegating "TPN" to a
definition that the ruling then reads differently is a gap in the text, not
in any of the three programs. See `dispute-initial-colour.md`.

---

## Part B - Comments on the VCL

### B.1 - Q33: 50,000 tournaments measures the wrong thing

We think the volume threshold is the weakest requirement in the document,
and we say that as someone who has comfortably exceeded it. Our engine has
been compared against bbpPairings 6.0.0 over **2,536,328,265 individual
pairings across 217,470,056 rounds**.

Volume alone did not find our defects. **Held-constant parameters did.**

Every corpus we ran before 2026-08-17 fixed the round count at 9. That one
constant hid a real defect - the final-round topscorer threshold compares
against half the *played* round count, which is indistinguishable from
half the *expected* count whenever the latter is even. It survived 2.55
million tournaments. Two thousand tournaments at eight rounds surfaced it
immediately.

A vendor can pass Q33 with 50,000 tournaments that vary nothing, and learn
less than one that runs 2,000 across a second axis. **We suggest the
requirement name the axes rather than the volume**: round count, field
size, byes, forfeits, prohibited pairings, acceleration, initial colour,
rating distribution (including all-unrated fields), mid-event withdrawals,
and the scoring system.

### B.2 - The scoring system belongs in the cross-test

Q70-88 make the scoring system, and the PAB value in particular,
extensively configurable. Q33 does not require the cross-test to exercise
any of it.

We added scoring configuration as a test axis on 2026-08-24. It
immediately exposed a defect in **our own** engine that 2.5 billion
standard-scored pairings had not: we classified an unplayed round as a
downfloat when it scored more than *zero*, where C.04.3 art. 1.4.3 says
more than *a loss*, and bbpPairings' `getFloat` correctly reads
`> pointsForLoss`. Under the standard system a loss is worth zero, so the
two expressions are literally identical and the defect was unreachable. It
appeared the moment a loss was worth anything.

We would not have found it under this VCL as drafted. We suggest Q33
require at least one non-default point configuration - valuing the PAB at
half a point would be the realistic choice, since FIDE already permits it.

### B.3 - Q21: must one PTC check both pairings and tie-breaks?

Q19 and Q21 describe a single "Pairing and Tie-Break Checker". In our
architecture the pairing checker lives in the engine and tie-breaks live in
the THP, because tie-breaks need tournament data the engine never sees.
Both are ours and both are free, but they are two entry points.

Please clarify whether a PTC split across two components satisfies Q21, or
whether one executable must accept a TRF-26 file and report on both.

Relatedly, Q31 requires RTG-produced tournaments to have standings
determined by the reported tie-break list. Read strictly, that requires the
RTG to compute tie-breaks. Is that intended?

### B.4 - Q30 should not be read as prohibiting a seed

Q30 fails a THP whose RTG produces the same file for the same parameters.
We agree with the intent, but reproducibility from an explicit seed is
essential for debugging: we write the seed into the generated tournament's
name so that a file always reproduces itself, and every dumped disagreement
in our documentation is reproducible on that basis.

We read Q30 as being about *unspecified* parameters, not about a seed the
user deliberately supplies. A sentence confirming that a seed is a
permitted configurable parameter would remove the ambiguity.

### B.5 - The reference engines are not uniformly reliable oracles

Q33-Q39 assume the other engine is a usable oracle and ask the candidate to
classify discrepancies. In practice a candidate can be penalised for
disagreements that are neither its fault nor a rules question.

Measuring against the FIDE Tie-Break Server (Gacrux) this week, we found:

- **It does not apply `XXA` acceleration.** Demonstrated on a round-1
  position: bbpPairings and our engine both pair inside the accelerated
  groups, while Gacrux produces the textbook unaccelerated top-half against
  bottom-half pairing. Across an accelerated corpus this put
  bbpPairings-vs-Gacrux agreement at **42.2%** over 98,323 rounds, against
  100.00% on every axis without acceleration.
- **It crashes on some bye histories.** An unhandled `KeyError` in
  `crosstabledutch.py`, affecting **1.78%** of rounds in a mixed corpus. It
  reports this as `### Error 510 / Program error` written into its *output
  file* while exiting with status 0, so a naive harness reads a crash as a
  verdict.

Both were diagnosed only because we looked at individual positions. A
vendor taking the aggregate at face value would report tens of thousands of
"rules disagreements" that are nothing of the kind.

**Suggestion:** TEC publishes, for each reference PTC/RTG it expects
candidates to test against, a statement of which TRF-26 features that
implementation actually supports. This costs TEC little and prevents a
whole category of false reports arriving under Q39.

### B.6 - Q196: prohibited pairings after round 1

Q196 is a hard failure if a THP lets the user add a prohibited pairing once
a round has been played, citing C.05:5.2.

C.05:5.2 requires restrictions to be *communicated to the players* by the
start of round 1. That is a duty on the organiser, not obviously a
capability the software should refuse. Arbiters do learn things late - a
family relationship not declared at entry, a federation transfer, a
safeguarding matter raised mid-event.

We would rather the THP record what the arbiter actually decided than force
them outside the software. **Suggestion:** make this a Level-4 warning plus
a `###` TRF comment, as the draft already does for other
non-compliant-but-real actions, rather than a hard prohibition.

### B.7 - Q10: what counts as a non-English "relevant element"

Q10 carries a 10% penalty if the English interface shows relevant elements
in another language, giving messages, dialog titles and help as examples.
Tournament *data* is full of non-English proper nouns - player names, club
names, venue names, federation names. We assume these are out of scope, but
the wording does not say so. One clarifying clause would settle it.

---

## Part C - Comments on the TEC Manual

### C.1 - Is the TRF-26 specification published?

The VCL requires the PTC to accept TRF-26 (Q21), requires the final report
to omit no event defined by TRF-26 (Q217, 30% penalty), and the Manual's
"TRF-26 Clarifications" section documents Record-162, Record-172, Record-299
and the ITDX conventions in detail - but as clarifications *of* a
specification, not as the specification.

If TRF-26 is not yet published, no vendor can implement against it, and the
Acceptance Cycle cannot start in earnest. If it is published, a direct link
in the Manual would help. We currently implement TRF16 and are ready to
move.

### C.2 - ITDX unknown results: we support the recommendation

We agree with the second interpretation and with `?` as the conventional
unknown-result symbol. The alternative - treating any invalid code as
unknown - silently converts a corrupt file into a plausible one, which is
the failure mode hardest to notice. We will implement `?`.

<!-- Sent as written. The commitment in that last sentence is tracked in
     TODO.md ("ITDX `?` unknown-result code"), parked on 2026-08-30 rather
     than dropped: nothing can produce a `?` until TRF-26 publishes, and an
     unknown symbol is refused loudly by the parser meanwhile, so no
     tournament is affected by the gap. -->

### C.3 - Warning levels: please state where the boundary sits

The Level 1-5 definitions are clear in themselves. What is not stated is
whether a THP may promote an action to a higher level than the Manual
requires. We would prefer to warn more loudly than the minimum in a few
places, and would like confirmation that doing so is not itself a
deviation.

---

## Closing

We are aware that our position is unusual: we are proposing a stricter
cross-testing requirement than the draft contains, in a document that will
be used to assess us. We think that is the right trade. The defects we
found in our own engine were found by testing beyond the bar, and a bar
that any vendor can clear without varying anything protects nobody.

We are happy to share our harnesses, our corpora, or the per-axis figures
behind any number above, and to run any comparison TEC would find useful.

Contact details are held with our vendor registration.
