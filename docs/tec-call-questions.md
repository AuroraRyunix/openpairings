# Questions for TEC, for a phone call

**Drafted:** 2026-09-10
**Context:** the feedback letter of 2026-09-08 and the document request of
2026-09-10 ([request-tec-vcl4thp.md](request-tec-vcl4thp.md)) are both sent.
This is for a conversation with somebody inside the commission, which can
settle in ten minutes what correspondence takes weeks to.

Ordered by what it costs us to guess wrong. **The first four decide code
that cannot be written until they are answered**; the rest change how much
we build, or are things worth handing over while you have their attention.

---

## 1. Blocks the build. Ask these first.

**1.1 The warning Levels 1 to 5 - a severity scale, or states?**

Is a Level a property of each individual warning ("this one is a Level 3"),
or a state the tournament itself occupies and moves between?

*Why it decides everything:* the first is a field on a message. The second
is a state machine with transitions, a stored history, and something an
arbiter can see. They are different software, and the wrong one is
invisible until FIDE verifies. This is the single most valuable answer on
the page.

**1.2 What raises a warning, and what moves a level?**

Is there a list, or is it left to the program? If a list exists, we want it
verbatim - this is exactly where two vendors implement the same rule
differently and both think they are right.

**1.3 ~~Is FIDE Mode a property of a tournament, or of the installation?~~ ANSWERED 2026-09-10, informally - not an official Commission position: per tournament, and the default - with NO toggle. See design-fide-mode.md section 0c.**

The 2017 checklist (C.04 Annex 4, VCL.01-02) reads as the installation: the
mode is the program's default operating mode, entered by a standard
installation. If that is still the intent, a per-tournament switch is the
wrong shape and we would rather know before building one.

*This decides the database schema.* It is the expensive one.

**1.4 Leaving the mode - the exact `###` comment, and the scope of "no
re-entry".**

We understand there is a Level-4 double warning on exit, no re-entry
afterwards, and a `###` TRF comment recording the round it was left in. We
would like the required wording of that comment exactly as it must appear,
and whether "no re-entry" binds the tournament or the installation.

---

## 2. Changes how much we build

**2.1 How is a program actually verified? ~~And is there a corpus?~~ ANSWERED 2026-09-10, informally - not an official Commission position: there is NO reference corpus.**

Checklist walkthrough, live demonstration, or submitted files? And is there
a set of reference tournaments a candidate is expected to reproduce?

*Why this is the best question after 1.1:* if verification is "these files,
these expected pairings", then having them turns the whole exercise from
interpretation into a test suite. We already run two ~488-million-pairing
comparison corpora against reference implementations; pointing that machine
at TEC's own cases would be a day's work.

**2.2 TAPC first, endorsement second - have we got that right?**

Our reading: a Tournament Acceptance and Play Certificate is what a
compliant program is issued, and endorsement is a separate later step
requiring a commercial agreement approved by the FIDE Council. Is a TAPC on
its own enough to be listed publicly, or does only endorsement get you on
the page?

**2.3 When does the Acceptance Cycle actually open, and what is the New
Rules Date?**

We understand the cycle begins six months before NRD and runs at least
three years, and that existing endorsements are revoked when it opens. A
date changes what we build first.

**2.4 Are the other hard failures really hard failures?**

Our read of v13 has adjourned games (Q157-169), prohibited pairings
mid-tournament (Q196) and editing a past round's results (Q189-191) as
stopping verification. Confirming which of those genuinely stop it, rather
than accumulating a penalty, decides our next quarter.

---

## 3. Things to hand them, not ask

**3.1 The endorsement page's pointer is broken, for everybody.**
`tec.fide.com/endorsement/` sends a reader to "Appendix A of section C.04"
for the procedure. The current handbook's C.04 runs C.04.1 to C.04.7 with
no appendix; the only checklist we can find is the 2017 annex still
resolving on `old.fide.com`. Every vendor hits this, not just us.

**3.2 We have a confirmed, reproducible Article 5.2.5 violation in Gacrux.**
That is FIDE's own Tie Break Server. Seed 32007296, round 2: two boards in
the same round imply opposite initial colours. Found by a consistency
checker over ~1,065,000 rounds, seventeen firings, all on Gacrux, all in
round 2, with bbpPairings and Ainalrami silent - then adjudicated by hand
because an instrument firing is not yet a finding. Written up with the
board table and a fixture. **Offer it; do not lead with it.**

**3.3 Two more discrepancy reports are written and unsent** - one on
bbpPairings' C2 handling, one on a separate Gacrux 5.2.4 issue. Ask who
they should go to and in what form.

---

## 4. Cheap confirmations, if the call is still going

- **Is TRF26 final, or still draft?** We read and write it in both
  directions already; if the published text will differ we would rather
  adjust a writer we have than discover it at verification.
- **`?` as the ITDX unknown-result code** - is the spelling settled? Our
  feedback letter commits us to implementing it and the engine reads it as
  of v0.25.0. We deliberately do not *write* it, on the grounds that a code
  you can type becomes a placeholder for "not entered yet". Is that the
  intended reading?

---

## Afterwards

Write down what was said, in this file, the same day - including anything
that was "probably" or "I think". A remembered phone call is exactly the
kind of single unverifiable source that section 0 of
[design-fide-mode.md](design-fide-mode.md) exists to warn about, and it
would be ironic to replace one with another.
