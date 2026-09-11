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

## 0. What the public sources already answer (checked 2026-09-11)

Searched before asking anyone. All of this is from published sources, read
on 2026-09-11:

- **2.2 - answered.** TAPC stands for **Technical Acceptance of Product
  Compliance** (handbook C.02.01, General Regulations, effective 1 March
  2026) - not "Tournament Acceptance and Play Certificate", as this sheet
  used to say. The regulations cover software explicitly, naming "Tournament
  Handler Programs (historically called Pairing Programs)". A TAPC does get
  a program listed: C.02.04's table of Tournament Handler Programs has
  separate TAPC and Endorsed columns. Endorsement ("FIDE Endorsement of
  Accepted Product") is a TAPC plus a commercial agreement approved by the
  FIDE Council. The route to a TAPC is a self-declaration, the online
  verification checklist, testing by at least three TEC testers, then
  Council approval; fees are in the TEC Manual's Annexure A.
- **2.3 - answered in substance, and differently from the draft.** The
  published regulations have no "Acceptance Cycle" and no "New Rules Date".
  A TAPC has no fixed expiry. It is revoked automatically on the effective
  date of a rule change that affects compliance, or when the manufacturer
  ships a major version ("incompatible changes"; minor and patch versions do
  not revoke it). Every one of the eleven programs in C.02.04's table shows
  an expiry of 2026-02-01, the day the 2026 Dutch rules took effect.
- **TRF26 (section 4) - still not formally approved.** The published
  TRF-2026 PDF's own cover reads "Approved by ???", dated "??/??/????".
- **`###` - only the comment prefix.** TRF-2026, Remark 1: any line whose
  first three characters are `###` is a comment. It prescribes no wording
  for leaving FIDE mode; that belongs to the checklist, not the format.
- **The unknown-result code (section 4) - the published spec has no `?`.**
  TRF-2026's only "unknown result" is the symbol `X` in record 162, the
  points table: "unknown result (like for instance in an adjourned game)",
  scored like a draw by default. Ainalrami currently refuses a 162 line that
  uses `X`.
- **Not public anywhere: 1.1, 1.2, the 1.4 wording, 2.4.** The Verification
  Checklist page on spp.fide.com is a maintenance page. The TEC Manual page
  on tec.fide.com is a navigation stub: the Manual was announced on fide.com
  on 2026-04-02 with no download. The regulations point to the checklist as
  an online form that cannot be read without starting a submission. The
  2017 checklist (VCL17) is public but has no warning levels. The draft
  circulated for the consultation would answer all four.

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

**2.2 ~~TAPC first, endorsement second - have we got that right?~~ ANSWERED from public sources 2026-09-11 - see section 0.**

Our reading was: a TAPC is what a
compliant program is issued, and endorsement is a separate later step
requiring a commercial agreement approved by the FIDE Council. Is a TAPC on
its own enough to be listed publicly, or does only endorsement get you on
the page?

**2.3 ~~When does the Acceptance Cycle actually open, and what is the New
Rules Date?~~ ANSWERED in substance from public sources - see section 0.**

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

**3.3 ~~Two more discrepancy reports are written and unsent~~ DONE,
confirmed 2026-09-11: both reported upstream** - one on bbpPairings' C2
handling, one on a separate Gacrux 5.2.4 issue.

---

## 4. Cheap confirmations, if the call is still going

- **Is TRF26 final, or still draft?** *(Section 0: its cover still reads "Approved by ???" - so the question is whether, and when, it will be approved.)* We read and write it in both
  directions already; if the published text will differ we would rather
  adjust a writer we have than discover it at verification.
- **`?` as the ITDX unknown-result code** - is the spelling settled? *(Section 0: the published TRF-2026 has no `?` at all; its only unknown result is `X`, in record 162.)* Our
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
