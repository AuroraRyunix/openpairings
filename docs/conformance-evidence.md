# Conformance evidence

**For:** FIDE Technical Commission
**About:** OpenPairings (tournament handling program) and Ainalrami (its
pairing and tie-break engine)
**Drafted:** 2026-09-10

This is a front door, not the evidence. It exists because the Commission
confirmed on 2026-09-10 that **there is no reference corpus** - no set of
tournaments with known-correct answers a candidate is expected to
reproduce. So the only account of whether this software pairs correctly is
the one its authors produce, and an account of that kind is worth exactly
what its method is worth.

Everything below is reproducible from public sources. Nothing here asks to
be taken on trust.

---

## 1. What is claimed

That Ainalrami implements the FIDE (Dutch) system of C.04.3 as published
for 2026, and that where it differs from another implementation, the
difference has been found, read by hand, and attributed.

Not claimed: that it is correct. Nothing measured against other programs
can establish that. What is claimed is narrower and checkable - that it
agrees with the implementations FIDE's own ecosystem uses, across a range
of tournament shapes large enough that silent divergence is implausible,
and that the exceptions are enumerated rather than absent.

## 2. What was measured

Six differential corpora between 2026-08-20 and 2026-08-24, plus a seventh
on 2026-08-26 re-measuring after a code sweep:

| | |
|---|---|
| axes | 99 |
| rounds paired | 217,470,056 |
| individual pairings compared | 2,536,328,265 |
| disagreements | **2** |

Both disagreements were adjudicated by hand rather than counted. The full
per-axis figures, the seeds, and the method are in
[`validation.md`](https://github.com/AuroraRyunix/Ainalrami/blob/main/docs/validation.md).

**The references, and why these ones.** bbpPairings 6.0.0 and Gacrux (the
FIDE Tie Break Server) are the primary oracles because both implement the
2026 edition. JaVaFo is run as a **control rather than a target**: it
implements the superseded 2022 rules, so an engine agreeing with all three
at once would prove the harness was measuring nothing. Over 3,352 rounds
bbpPairings and Gacrux agreed with each other on every one, which is what
makes them usable as a ruler at all.

None of the three is vendored. Each is located at runtime from a path the
operator supplies, so the comparison runs against the reader's own copy,
not ours.

## 3. What the measurement could not see

`validation.md` carries a section titled "What the corpus could not see",
and it is the section its authors would point a sceptical reader at first.
It records, among other things, that 2.5 million tournaments held rating
shape constant at a uniform distribution - close to the opposite of real
chess, where a junior event is entirely unrated and a club field sits on a
handful of rounded numbers - and that no corpus before 2026-08-23 ever
generated a withdrawal, so the TRF construct expressing one had never been
read back by bbpPairings from a file this project produced.

Both are now closed and the document says when and how. It is quoted here
because a conformance claim that lists only its strengths is not evidence,
and because the Commission can check whether the gaps named there are the
gaps a verifier would have asked about.

## 4. Findings produced in other implementations

The strongest available statement about a test apparatus is not what it
says about its own subject. It is whether it finds things in software
written by other people.

- **Gacrux breaks FIDE Article 5.2.5** - confirmed and reproducible.
  Seed 32007296, round 2: two boards in the same round imply opposite
  initial colours. Found by a consistency checker over ~1,065,000 rounds
  which fired seventeen times, every firing on Gacrux and every one in
  round 2, with bbpPairings and Ainalrami silent - then adjudicated by
  hand, because an instrument firing is not yet a finding. Two earlier
  candidates from the same instrument dissolved on inspection and were
  discarded. Written up with the board table and a fixture in
  [`finding-gacrux-5-2-5.md`](https://github.com/AuroraRyunix/Ainalrami/blob/main/docs/finding-gacrux-5-2-5.md).
  **Gacrux is the Commission's own tie-break server.**
- A separate Gacrux issue at Article 5.2.4, and a bbpPairings issue in its
  C.2 handling, are written up and not yet filed upstream.

That document's closing section is also worth the Commission's attention,
for the opposite reason: it records that a reading of Gacrux's source had
concluded the checker *could not* detect this, and that the reading was
wrong. A prediction from source is not an observation, and the finding says
so about its own author.

## 5. Where the detail is

Everything on the engine's side lives in its own public repository. The
paths are given as links rather than as `deps/ainalrami/...`, because that
directory is a build artifact and does not exist in a fresh checkout.

| | |
|---|---|
| method, corpora, per-axis figures, known gaps | [validation.md](https://github.com/AuroraRyunix/Ainalrami/blob/main/docs/validation.md) |
| C.04.3 clause-by-clause conformance | [conformance-c0403-2026.md](https://github.com/AuroraRyunix/Ainalrami/blob/main/docs/conformance-c0403-2026.md) |
| the Article 5.2.5 finding | [finding-gacrux-5-2-5.md](https://github.com/AuroraRyunix/Ainalrami/blob/main/docs/finding-gacrux-5-2-5.md) |
| the Article 5.2.4 finding | [finding-gacrux-5-2-4.md](https://github.com/AuroraRyunix/Ainalrami/blob/main/docs/finding-gacrux-5-2-4.md) |
| the bbpPairings C.2 report | [bbppairings-c2-bug-report.md](https://github.com/AuroraRyunix/Ainalrami/blob/main/docs/bbppairings-c2-bug-report.md) |
| an initial-colour question put to the SPP, and its answer | [dispute-initial-colour.md](https://github.com/AuroraRyunix/Ainalrami/blob/main/docs/dispute-initial-colour.md) |
| what this program does today | [features.md](features.md) |
| where it does not yet meet the checklist | [TODO.md](../TODO.md) |

The engine is Apache-2.0 and public at
<https://github.com/AuroraRyunix/Ainalrami>. The application is
source-available under the Elastic License 2.0.

## 6. What this does not cover

Team pairing (C.04.6) is not implemented; the regulation is read up and
written down, and no reference implementation pairs teams, so there is
nothing to differential-test against. Adjourned games are not implemented.
The gaps against the checklist are listed in TODO.md rather than omitted
here - a document that names its own shortfalls is cheaper to check than
one that does not.

---

## A note on how to read section 2

A large number is a weak argument on its own. 2.5 billion pairings is one
generator's idea of what a tournament looks like, repeated - and section 3
exists because the authors found that out the hard way, twice. The figure
is offered as a bound on undetected divergence from two independent 2026
implementations, and nothing more than that.
