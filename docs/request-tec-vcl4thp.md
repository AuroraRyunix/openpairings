# Request to FIDE TEC: the VCL4THP text and the Level definitions

**From:** OpenPairings (THP) / Ainalrami (pairing and tie-break engine)
**To:** FIDE Technical Commission
**Drafted:** 2026-09-10
**Status:** NOT SENT - the maintainer sends this

> Why this exists: phase 0 of [design-fide-mode.md](design-fide-mode.md) is
> "get the text before writing the code". It turns out the text cannot be
> got from any public source - see section 0b there for where was searched.
> So phase 0 becomes a request, and this is it. It follows the feedback
> letter of 2026-09-08, which opened the correspondence.
>
> Keep it short when sending. This is a request for two documents, not a
> position paper, and the case for answering it is that we are trying to
> build to the rules rather than around them.

---

Dear Technical Commission,

Following our feedback of 8 September on the draft VCL4THP v13 and the
revised TEC Manual, I would like to ask for the current text of both.

We are building FIDE Mode into OpenPairings now, and we would rather build
it from your text than from our notes. Two things in particular decide the
implementation and we cannot resolve them from anything published:

1. **The warning Levels 1 to 5.** Are they a severity scale applied to
   individual warnings, or states the tournament itself occupies and moves
   between? The two produce different software: the first is a property of
   each message, the second is a state machine with transitions an arbiter
   can see and a history that has to be stored. We would rather not guess
   and be told later that we guessed wrong.

2. **Leaving FIDE Mode.** We understand there is a Level-4 double warning
   on exit, no re-entry afterwards, and a `###` comment in the TRF
   recording the round in which the mode was left. We would like the exact
   wording required in that comment, and confirmation of whether "no
   re-entry" is scoped to the tournament or to the installation.

A related question, which may be the more important one: **is FIDE Mode a
property of a tournament, or of the installation?** The 2017 checklist
(C.04 Annex 4, VCL.01-VCL.02) reads as the latter - the mode is the
program's default operating mode, entered by a standard installation. If
that is still the intent, then a per-tournament switch would be the wrong
shape entirely, and we would like to know that before we build one.

Two smaller points while I am writing:

- The endorsement page at `tec.fide.com/endorsement/` refers to "Appendix A
  of section C.04" for the endorsement procedure. The current handbook's
  C.04 runs C.04.1 to C.04.7 with no appendix; the checklist we can find is
  the 2017 version on `old.fide.com`. If the appendix has moved, a pointer
  would help more vendors than us.

- We would like to confirm we have the sequence right: a Tournament
  Acceptance and Play Certificate is what a compliant program is issued,
  and endorsement is a separate later step requiring a commercial agreement
  approved by the FIDE Council. We are pursuing the former.

We have no existing endorsement to protect and no position to defend in the
coming Acceptance Cycle. Everything we have built so far is checked against
reference implementations and published as reproducible measurement; we are
happy to share any of it if it is useful to the Commission.

With thanks,

Jorian Burssens
OpenPairings

---

## Notes for the sender, not part of the letter

- **Ask for the TEC Manual too, not only the checklist.** The Level
  definitions are described as living in the Manual rather than in
  VCL4THP; asking only for the checklist may get you a document that
  references definitions you still do not have.
- **The per-tournament-or-per-installation question is the expensive one.**
  It is the first open question in the design document and it decides the
  schema. If only one question gets answered, that is the one worth
  pressing.
- Contact route: `tec.fide.com/contact/`, or whichever address the
  2026-08-25 consultation was circulated from - that thread is the better
  one to reply into, since it already has context.
