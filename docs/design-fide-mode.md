# FIDE Mode: what it is, what we have, and what it would cost

Design study, 2026-09-09. Read-only investigation against OpenPairings
0.51.0 (`ee85a57`) and Ainalrami v0.24.0 (`d90fd3a`). No code was changed.

FIDE Mode is the first of the five hard failures in
[TODO.md](../TODO.md)'s "The 2026 Acceptance Cycle" section - the ones that
stop verification on the spot rather than adding to a percentage. It is
also the one nobody has scoped, and the one the other four report through.
This document exists to make it costable.

---

## 0. Provenance, and where this document is weak

Everything below about **current behaviour** was read out of the source on
2026-09-09 and is cited by file and line. Everything about **what FIDE
requires** is on a much weaker footing, and the difference matters enough
to state first.

**The VCL4THP v13 draft is not in this repository, and could not be
retrieved.** `find . -iname "*vcl*"` returns nothing outside the sweep
documents' prose. `spp.fide.com/verification-checklist/` served a
maintenance page on 2026-09-09; `tec.fide.com/official-documents/` lists
six documents and the checklist is not among them;
`tec.fide.com/fide-technical-manual/` is a navigation stub with no
download. Every claim in this repository about **Q40-46** therefore traces
back to one person reading one draft PDF once, in four places that all say
the same four things:

- `TODO.md:347-352` - the roadmap entry.
- `docs/fide-endorsement.md:198-208` - the block quote at the head of
  Section A.
- `docs/sweep-2026-08-26.md:2350-2366` - the sweep's own scoping note.
- `docs/tec-feedback-2026-09.md:191-193, 233-239` - two places where the
  letter argues *from* the mechanism.

Those four agree because they have one author and one source, not because
they corroborate each other. Treat the requirement text below as
second-hand throughout.

**Two primary sources were recovered and are genuinely useful**, and they
are about the *previous* checklist rather than v13:

- **VCL19** (`spp.fide.com/wp-content/uploads/2020/04/C04Annex4_VCL19.pdf`,
  authored by Roberto Ricca), the checklist
  `docs/fide-endorsement.md` is built on. Its Section A carries six items,
  VCL.01-VCL.06, and they are the ancestor of Q40-46.
- **The Vega 7.6.0 endorsement report**
  (`tec.fide.com/wp-content/uploads/2024/05/VegaReport.pdf`, Ricca,
  2017-07-03), a completed verification against that checklist. It shows
  what a verifier actually does with "FIDE Mode", which is worth more than
  the checklist text on its own.

Where this document says **not established**, it means exactly that.

---

## 0b. Phase 0, attempted 2026-09-10: the documents are not obtainable

The build plan's phase 0 is "get the VCL4THP v13 text and the TEC Manual's
Level 1-5 definitions into `docs/` before phase 2 starts". That was
attempted. **They cannot be got from any public source**, and the search
was thorough enough to be worth writing down so nobody repeats it:

| where | result, 2026-09-10 |
| --- | --- |
| `spp.fide.com/verification-checklist/` | still a WordPress maintenance page - unchanged from 09-09 |
| `tec.fide.com/official-documents/` | six documents, none of them a checklist |
| `tec.fide.com/fide-technical-manual/` | navigation stub, no download |
| `tec.fide.com/spp-documents-archive/` | four papers, all about pairing theory |
| `tec.fide.com/endorsement/` | names the six endorsed programs; points at "Appendix A of section C.04" for the procedure |
| `handbook.fide.com/chapter/C04` | **has no annex or appendix at all** - C.04.1 through C.04.7 and nothing else |

That last row is the finding. The endorsement page sends a reader to a
handbook appendix **that the current handbook does not contain**. The
checklist used to live there: `old.fide.com/FIDE/handbook/C04Annex4_VCL17.pdf`
still resolves, and is the newest version anybody outside the process can
read.

**What the 2017 checklist tells us, and it is not nothing.** It is eighteen
items in four groups - FIDE Mode, Pairing, Import/Export, Tournament -
numbered `VCL.01` to `VCL.18`. Its FIDE Mode group is six flat
requirements about what the mode must be and must inhibit.

**There are no warning levels in it at all.** No levels, no level
thresholds, no exit, no re-entry rule, no TRF comment recording an exit.
So the Level 1-5 machinery in v13 is not a refinement of something with
prior art that could be reasoned from - it is new, and section 1 of this
document is reasoning about a mechanism no public text describes.

It is deliberately not reproduced here. It is FIDE's copyrighted handbook
material and the URL above is stable; a paraphrase plus a link is the right
amount to hold in this repository.

**A vocabulary gap, found the same way.** Public TEC material uses two
terms this repository does not: **TAPC** (Technical Acceptance of Product
Compliance - handbook C.02.01, effective 1 March 2026) is what a compliant
program is issued, and endorsement is a *separate*, later step requiring a
commercial agreement approved by the FIDE Council. The draft we read
described an **Acceptance Cycle** of at least three years beginning six
months before a New Rules Date (**NRD**); the published regulations use
neither term, and instead revoke a TAPC automatically when a rule change
affecting compliance takes effect, or when a major version ships. See
tec-call-questions.md section 0. This document and TODO.md
both talk about "endorsement" where the thing actually being pursued first
is a TAPC. Worth straightening out before anything is written to FIDE,
because using a body's own terms incorrectly in a submission is a poor
first impression.

**So phase 0 is now a request, not a search**, and there is a channel for
it: the feedback letter of 2026-09-08 opened a correspondence with TEC.
The draft is [request-tec-vcl4thp.md](request-tec-vcl4thp.md). Until it is
answered, phase 2 of the build plan below should not start - not because
the code is hard, but because the Level definitions decide what the code
is supposed to do, and a wrong choice there is invisible until FIDE
verifies.

## 0c. Answered 2026-09-10, and it changes the shape

Three of the questions came back - **informally, not as an official
Commission position.** That was pinned down on 2026-09-11, and it is the
distinction this document's section 0 exists to keep: none of the three may
be cited to the Commission as the Commission's answer. The second and third,
per tournament by default and no toggle, are adopted below as this project's
own design decisions, and they stand on their own reasoning either way.

**There is no reference corpus.** Verification does not run a candidate
against a set of tournaments with known-correct answers. That is worth more
than it first sounds: it means nobody hands us a target, and it means the
evidence we bring is our own. See "What to build instead" below.

**FIDE Mode is per tournament, and it is the default.**

**And there is no toggle.** This is the part that changes the design. The
mode is not a switch an arbiter turns on - *the defaults are compliant, and
changing settings can make a tournament less so*. Compliance is a state the
tournament is in, computed from its settings, not a flag somebody sets.

That reading is the one the 2017 checklist already had. `VCL.01` says the
FIDE mode must be the DEFAULT OPERATING MODE, and `VCL.02` that it must be
reachable by a standard installation and a standard invocation. Neither
describes a control. A program that ships compliant and warns you on your
way out satisfies both without ever drawing a checkbox.

**What this settles, and what it does not:**

- Section 3's design below is now wrong in its first move. It proposed a
  stored mode with an explicit `FideMode.leave/3`. What is wanted instead is
  a DERIVED state - a function over the tournament's settings answering "is
  this still compliant, and if not, which setting stopped it" - plus a
  record of the round it stopped, which is what the `###` comment needs.
- `fide_homologated` (question 7.4) is answered by implication: a second
  FIDE-ish tickbox is exactly the toggle this says not to have.
- The Level 1-5 machinery is still unknown, and still blocks phase 2. But
  it is now clearly a LABELLING on top of a mechanism we can build without
  it: which settings are compliant, what warns, and what gets recorded.

## What to build instead, given there is no corpus

Nobody will hand us a set of tournaments and their correct answers. So the
only evidence that this software pairs correctly is evidence we produce -
and unusually, that already exists: two independent ~488-million-pairing
corpora comparing Ainalrami against bbpPairings and Gacrux, with the
disagreements adjudicated one at a time and written up.

That is worth assembling into something a verifier can read, rather than
leaving as engineering notes. It is also the reason the Gacrux Article 5.2.5
finding matters beyond the bug itself: a candidate that can demonstrate a
defect in the commission's own tool, with a reproducible position, is making
a different kind of argument about its own testing than a candidate that
says "we tested it thoroughly".

## 1. What FIDE Mode actually is

### 1.1 The concept, as it has stood since before v13

FIDE Mode is **an operating mode of the program**, not an attribute of a
tournament. C.04.A article A.2 - reproduced in the Vega report's opening
pages - puts it plainly: a program seeking endorsement must provide, either
explicitly or implicitly, a FIDE mode offering everything FIDE requires of
an endorsable tournament manager, and *the program is endorsed in that
mode*. The mode may offer extra services, provided they are not prohibited
and cannot cause pairing mishaps for users in that mode.

VCL19's Section A then says six things about it. Paraphrased:

1. **VCL.01** - FIDE mode must be the software's default operating mode.
2. **VCL.02** - it must be reachable by a standard installation and by a
   standard invocation of the program.
3. **VCL.03** - the pairing system a standard invocation activates must be
   one the program is endorsed for, and must be clearly identified.
4. **VCL.04** - every pairing-related service available in FIDE mode must
   behave correctly.
5. **VCL.05** - FIDE mode must inhibit anything FIDE explicitly prohibits.
6. **VCL.06** - the word FIDE may not be attached to a pairing-related
   service that is not endorsed.

Read those six together and the shape is unmistakable: a mode is a *state
the program is in*, in which some things are guaranteed correct and other
things are absent. It is not a tickbox on a tournament, and it was never
meant to be. `fide_homologated` is not a weak version of this - it is a
different kind of thing.

The Vega report is the more instructive half. Vega, like OpenPairings on a
JaVaFo tournament, delegates pairing to JaVaFo; the verifier records that
Vega enters FIDE mode automatically after a standard installation, that
this is documented in the manual rather than announced in the program, and
that VCL.05 could only be judged by testing, not by reading. And then, in
the report's closing observations, this, about controls left visible in
FIDE mode:

> "Those controls are misleading, because they have no effect in FIDE mode"
> - Vega 7.6.0 endorsement report, R. Ricca, 2017

That sentence should govern the whole UI half of this work. A verifier
treated a live-looking control that FIDE mode had quietly neutered as a
**defect**, not as a cosmetic issue. Anything FIDE Mode inhibits has to
look inhibited.

### 1.2 What v13 adds, per this repository's own reading

Four things, none of which exist in VCL19:

- **Warning Levels 1 to 5.** A graded severity scale for actions that are
  permitted but non-conforming.
- **A Level-4 double warning when the mode is exited.**
- **No re-entry once exited.**
- **A `###` TRF comment recording the round in which the mode was left.**

The fourth is the one that reveals the design tension, and it is worth
being explicit about it because everything downstream turns on it. VCL19's
mode is a property of the *installation*. A `###` line recording *the
round* a mode was left is a fact about *one tournament*. v13 therefore
either (a) moves the mode into the tournament, or (b) keeps it at
installation level and asks the report to record when the running
installation stopped being in it - which for a hosted server serving many
arbiters would be incoherent. This is not a detail; it is the first
decision, and section 3.1 argues it.

### 1.3 Where the requirement is genuinely ambiguous

Six readings that cannot be settled from anything in this repository.

**A. Scope: installation or tournament?**
For the installation: VCL.01 says *default operating mode of the software*,
VCL.02 speaks of a standard installation and a standard invocation.
Against it: a `###` line naming a round, and the fact that "no re-entry"
applied to an installation would mean a hosted box that could never serve a
FIDE-mode tournament again after one arbiter left the mode on one event.
That asymmetry is the strongest argument in the file for the per-tournament
reading, and it is an argument from consequence rather than from text.

**B. What causes an exit.**
Three readings. (i) An explicit arbiter act - "leave FIDE mode" is a button.
(ii) An automatic consequence of doing something the mode forbids - the
mode falls away when you add a prohibited pairing in round 5. (iii) Both:
some acts warn, some eject. `TODO.md:348` phrases it as *"a Level-4 double
warning on exit"*, which reads like (i): you are warned about a thing you
are deliberately doing. But `docs/tec-feedback-2026-09.md:191-193` argues
that adding a prohibited pairing late should be *"a Level-4 warning plus a
`###` TRF comment"* - the same two artefacts the exit produces. Either the
letter is proposing that this act *is* an exit, or Level-4 warnings and
exits are separate things that happen to share machinery. The letter does
not say, and neither does anything else here.

**C. What Levels 1-5 mean.**
The definitions are in the TEC Manual.
`docs/tec-feedback-2026-09.md:233-239` confirms the maintainer read them
("The Level 1-5 definitions are clear in themselves") and then asks TEC a
question about them - but **they are not reproduced anywhere in this
repository**. This is the single most important missing input in the whole
piece of work: a five-level warning system cannot be built correctly
without the five definitions, and guessing them produces a mechanism whose
call sites are all subtly wrong in a way no test can catch. Section 6 puts
obtaining them ahead of Phase 1.

**D. "Double warning".**
(i) Two consecutive confirmations, the second demanding more than a click.
(ii) One warning delivered twice over - on screen and into the report.
(iii) A warning shown to the arbiter and to the reader of the file. These
are not exclusive; section 3.6 recommends satisfying all three, because
doing so costs one dialog and one comment line we are building anyway.

**E. The scope of "no re-entry".**
Per tournament, or per installation? Follows directly from A.

**F. The `###` line's own format.**
Whether TEC specifies content, position or a machine-readable shape is not
established. Section 4 proposes one and says which parts are ours.

### 1.4 What would be our choice, not FIDE's

Stated separately so the two never get confused in review:

- Making the mode per-tournament (given A is unresolved).
- Defaulting it **on** for every new tournament (VCL.01 requires the
  default; it does not require the default to be per-tournament).
- Recording *who* left and *why*, alongside *when* - FIDE asks for the
  round.
- Emitting the `###` line in the arbiter-facing TRF26 export and not in the
  engine-input file.
- Warning more loudly than the minimum anywhere we choose to. The letter's
  C.3 asks TEC whether this is permitted and **has not been answered**, so
  every promotion above the Manual's level must be individually marked in
  the code as ours.

---

## 2. The gap

### 2.1 What `fide_homologated` is

`lib/pairings_engine/tournaments/tournament.ex:211`

```
field :fide_homologated, :boolean, default: false
```

Its own schema comment (`tournament.ex:206-210`) describes it as *an
informational tickbox*, and that is exactly what it is. It appears on
**seventeen lines across eight files** in `lib/`. Four of those are
comments or moduledoc prose. One is the declaration, one the cast entry,
one the write path, two the form markup, one a backup field list. That
leaves **seven reads that do something**, and not one of the seven changes
what the application permits:

| # | site | what it does |
|---|---|---|
| 1 | `tournament.ex:1324` | gates whether `fide_tournament_id` appears in `missing_recommended_fields/1` - a soft, explicitly non-blocking nudge (`tournament.ex:1273-1279`) |
| 2 | `settings_options_live.ex:645` | renders one advisory `.error-note` sentence beside the engine picker |
| 3 | `settings_options_live.ex:1012` | renders a second one in the JaVaFo confirm panel |
| 4 | `print_controller.ex:1580` | adds a "FIDE ID:" item to the printed tournament-info line |
| 5 | `snapshot.ex:153` | publishes `"fide_rated" => t.fide_homologated` to OpenResults |
| 6 | `swar_export.ex:220` | writes it as an `i32` into the SWAR binary |
| 7 | `swar_publish.ex:415` | selects `"FIDE"` or `"KBSB"` as the federation label |

Two labels, two serialisations, one print line, one soft nudge, one
advisory sentence rendered twice. Nothing refuses. Nothing warns. Nothing
is inhibited.

### 2.2 What it does not do, item by item

**It is not a mode.** No code path anywhere in `lib/` behaves differently
because it is set, in the sense VCL.04 and VCL.05 mean. The one place that
ever did was removed deliberately: `docs/fide-endorsement.md:83-90` records
that `pairing_engine: "ainalrami"` used to be *refused* on a homologated
tournament in both directions, and that the block became a warning on
2026-08-21. That was the app's only inhibition, and it is gone.

**It has no round.** There is nowhere to put one. `docs/sweep-2026-08-26.md:2357`
already noticed this and proposed `fide_mode_left_round`.

**It has no history and no direction.** It is freely settable both ways at
any point in a tournament's life. `Tournaments.locked_fields/1`
(`tournaments.ex:716-770`) does not list it, so `update_tournament/3`'s
`ensure_unlocked/3` guard (`tournaments.ex:677-678`) never looks at it.
`SettingsFideLive.handle_event("save", ...)` (`settings_fide_live.ex:86-92`)
takes it straight from the form params and writes it. Toggling it off in
round 7 leaves exactly one trace: a row in the generic settings diff
(`settings_support.ex:414-425`), rendered as one field among however many
else that save touched.

**Nothing adjacent exists either.** Verified on 2026-09-09:

```
grep -rn "fide_mode\|warning_level\|adjourn" lib/    # no matches
grep -n '###' deps/ainalrami/lib/ainalrami/trf.ex    # no matches
```

### 2.3 The three structural mismatches

Worth naming, because each one decides part of the design.

1. **It is a claim, not a constraint.** `fide_homologated` says "this event
   will be submitted for rating". FIDE Mode says "this program's behaviour
   on this event was constrained". A tournament can be homologated and
   handled badly, or unrated and handled to the letter. **These are two
   independent facts and both must survive** - which is why the design
   below adds fields rather than repurposing this one, and why
   `swar_export.ex:220` and `swar_publish.ex:415` should keep reading
   `fide_homologated` and not the mode.

2. **It lives on the wrong object for VCL.01/02 and the right one for the
   `###` line.** See 1.2. Unavoidable; section 3.1 picks a side and says
   what it costs.

3. **A boolean cannot express a one-way door.** Anything expressible as
   "true again" is not the requirement. This is the whole of section 3.3.

---

## 3. What was built, 2026-09-10

**This section replaces the design that stood here before.** That design
proposed a stored mode with an explicit `FideMode.leave/3` and a one-way
door; section 0c settled that there is no toggle, and the shape changed
accordingly. What follows describes the code as it exists in **0.56.0**, not
a proposal. Where the earlier design's reasoning was tested against the real
code and found wrong, that is marked and kept rather than deleted - the
mistakes are the useful part.

**The subsection numbers were reused, and the earlier sections still point at
the old ones.** Sections 1, 2 and 5 cite "section 3.1", "3.3", "3.6" and so
on; those numbers now name different things. Read any such reference as
naming *the design that was proposed*, not what is here - and the field they
call `fide_mode_left_round` is the column called
`fide_compliance_lost_round`, renamed because there is no mode to leave.

### 3.1 The shape: derived, plus one recorded fact

Two pieces, and the split is the whole design:

- **`PairingsEngine.Compliance`** (`lib/pairings_engine/compliance.ex`) -
  pure, no Repo, no gettext. `check/1` takes a `%Tournament{}` and returns
  the list of settings that have taken it out of FIDE handling, each with
  the value it holds now and the values that would bring it back.
  `compliant?/1`, `settings/0` and `introduced/2` sit on top of it. Nothing
  about "is this tournament compliant" is stored, because nothing needs to
  be: it is a fact about the settings, and the settings are already stored.
- **`tournaments.fide_compliance_lost_round`** (one nullable integer
  column) - the round in which compliance was first lost. `nil` means never;
  `0` means "before round 1 was paired", which is a real state a Keizer
  tournament is in from creation. It is the one half that cannot be
  recomputed: put the setting back and `compliant?/1` is true again, and
  nothing left in the data could say which round it stopped. VCL4THP asks
  for that round by name.

There is no `fide_mode` boolean, and there is no `enter`/`leave` pair. The
"no re-entry" rule is not a guard anybody can forget - there is no code path
that clears the column, because nothing was written that could.

### 3.2 The inventory, and why it is short

The full reasoning per setting is in `Compliance`'s moduledoc, which is where
it belongs (the next person to touch this reads the module, not this file).
The summary:

**Three departures.** All three change *who plays whom*, away from what a
FIDE pairing system produces, and that turned out to be the only line that
survives contact with the regulations:

| setting | code | why |
|---|---|---|
| `pairing_system == "keizer"` | `:non_fide_pairing_system` | FIDE defines the Dutch Swiss (C.04.3) and the round-robin Berger tables (C.05 Annex 1). It does not define a Keizer ladder, which is also why this app's own tie-break code says the C.07 breaks do not apply to one. `VCL.03` wants a system the program is endorsed for, and no program can be endorsed for a system FIDE has not written down. |
| `pair_by_category == true` (Swiss only) | `:categories_paired_separately` | Each category gets its own engine run and its own pairing-allocated bye, merged into one Round. Two players on the same score never meet if they are in different categories - not a pairing C.04.3 can produce for one field. Running the sections as separate tournaments is the compliant way to do the same thing. |
| `swiss_match_format == true` (Swiss only) | `:mirrored_second_leg` | The second leg is inserted as an exact colour-reversed mirror with no pairing decision behind it. Half the tournament's rounds were not paired by C.04.3 at all. |

Both booleans are gated on `pairing_system == "swiss"`, because their own
schema comments say they are never read otherwise. **This gating is
load-bearing, not tidiness.** A compliance check that reports a setting no
round will ever act on teaches arbiters that one of its lines is noise, and
an arbiter who has learned that stops reading the other lines.

**Everything else was examined and left out.** Briefly, with the reason each
one failed to qualify - the point of writing these down is that they will be
proposed again:

- **Scoring values** - `points_win`/`draw`/`loss`, `bye_value`, `abs_value`
  and its two caps, `presence_value`. `VCL.16` requires the
  pairing-allocated bye value to be *configurable*; `VCL.17` requires
  half-point byes to be assignable; `VCL.12` requires the TRF16 export to
  stay analyzable **"even under a non-default scoring system"**. That is the
  checklist we are measured against assuming non-default scoring exists. A
  rule firing here would contradict it.
- **`count_extra_points`** - TRF26 has a dedicated `299` record for "points
  assigned outside the scoring system - a bonus or a penalty an arbiter
  added by hand", and FIDE's own wording allows a negative value.
  `TrfExport.free_point_records/2` already writes it. FIDE does not merely
  permit administrative points, it asks to be told about them. They also
  never reach pairing or the C.07 tie-breaks (`docs/extra-points.md`).
- **`manual_ranking`** - C.07 ends in mechanisms whose outcome an arbiter has
  to be able to record: a play-off, drawing of lots. Recording one is the
  feature's first documented use (`docs/manual-standings.md`). A permanent
  non-conformance mark for doing the right thing is the definition of crying
  wolf. The case that *would* be a departure - a hand-set order contradicting
  the score order - is a fact about the players, and no pure function over a
  `%Tournament{}` can see it.
- **`tiebreaks`** - C.07 lists systems and the tournament's own regulations
  choose among them. FIDE mandates no selection. An empty list already blocks
  pairing via `missing_setup_fields/1`.
- **`acceleration`** - Baku is FIDE's own (C.04.7). Both values are FIDE's.
- **`pairing_engine`** - and this is the interesting one. `VCL.03` wants a
  system *the program is endorsed for*, which today points at **JaVaFo**;
  rules currency points at **Ainalrami**, which implements the edition in
  force since 1 February 2026 where JaVaFo implements the 2017 one. The
  regulations point in opposite directions, so the module does not pretend
  to settle it. The advisory note on the Options page is the right treatment
  and stays. Flagging JaVaFo would also have unilaterally reversed a decision
  the maintainer made on 2026-08-21.
- **Forbidden pairings, club/federation exclusions, soft rules** - `XXP` is
  FIDE's own TRF extension and the endorsed engine implements it. Q196 *does*
  make adding a prohibited pairing after round 1 a hard failure, citing
  C.05:5.2 - but that is an act at a round, not a setting, and
  `docs/tec-feedback-2026-09.md:179-193` is a live disagreement with TEC
  about whether the reading is right at all. Encoding one side of an open
  argument as a permanent mark on somebody's tournament was not this change's
  call. When Q196 settles, `Tournaments.add_forbidden_pairing/4` is where it
  lands.
- **`rr_match_format`** - reorders a fixed Berger schedule. Everybody still
  meets everybody with the same colours; it changes the order of rounds, not
  who meets whom.
- **`absent_counts_as_vur`** - FIDE has no "absent" concept at all
  (`docs/fide-endorsement.md:403-418`), so there is no regulation for either
  setting of it to violate.
- **`allow_swiss321`** - listed in the brief as a candidate, but it is not a
  tournament setting: it is an option on
  `Federations.BEL.SwarImport.parse/2`, and the import is refused without it
  for data-fidelity reasons unrelated to FIDE.

### 3.3 Where the round is written

`Tournaments.create_tournament/1,2` and `update_tournament/3`, through one
private `stamp_compliance_loss/2` that puts the change **into the same
changeset as the save that causes it**. Not a second `Repo.update`
afterwards: the settings change and the record of it either both land or
neither does, and a follow-up write that failed on its own would leave a
tournament that is non-compliant with nothing saying when - precisely the
fact that cannot be reconstructed later. A refused save records nothing,
which is tested.

The round is `Pairing.paired_rounds_count/1` - how many rounds *exist*, not
how many are complete. The question the `###` line asks is which round was
under way, and the round under way is the highest one that exists. On the
create path it is literally `0` with no query.

`SwarImport` and `TrfImport` build their own changesets and insert directly,
bypassing `Tournaments`. Neither can mint a non-compliant tournament today -
neither writes either boolean, and both leave `pairing_system` at "swiss" -
so neither has anything to stamp. If either learns to set one, it has to
stamp too; `compliance_test.exs` is where to say so.

`manual_ranking` has its own writer (`do_set_manual_ranking_flag/2`) that
does not go through `update_tournament/3`. That would have been a hole if
`manual_ranking` were a compliance setting. It is not, per 3.2 - but if it
ever becomes one, that writer is the second place to stamp.

### 3.4 Surviving a restore and a hand-off - and where 3.3b was wrong

The old section 3.3b called `restore_into!/2` "the sharpest hole in the whole
design" and prescribed re-asserting the three fields **from the live row**.
Tested against the real code, **both halves of that are wrong**, and the
second half would have introduced the bug it was trying to prevent:

1. **A restore cannot clear an uncast field on its own.**
   `restore_into!/2` builds its changeset on `tournament` - the live row -
   so a field outside the cast list simply keeps the value it already had.
   The danger only appears if somebody later adds the column to `cast`. That
   combination is what `compliance_test.exs` fails on, and it was watched
   failing.
2. **The direction that really is broken points the other way.**
   `Handoff.release/3` returns a tournament through the same
   `restore_into!/2`, and the returning payload is the only record of what
   happened on the other machine. This copy was locked for the whole trip and
   knows nothing. Re-asserting the live value would have thrown away a
   compliance loss that really happened, on the copy where the rounds were
   actually played.

One rule covers both, and it is the rule the fact itself implies: **the
record is a watermark on the first loss, so it only ever moves earlier -
never later, and never back to `nil`.** `earliest_compliance_loss/2` in
`TournamentImport`. `import_tournament!/2` (a brand-new row from a file)
takes the file's value outright, since there is no live value to weigh
against.

The column is exported (`@tournament_fields`), which the export test forces a
decision on. It is the one entry there whose reason is not "it is a setting":
a backup carries the rounds that were played after the loss, and one that
carried the rounds and dropped the record would restore a tournament claiming
it was handled compliantly throughout.

### 3.5 What the arbiter sees

`SettingsSupport.compliance_notice/1`, modelled on the setup checklist
(`missing_setup_fields/1`) deliberately: a card, a sentence, one line per
item, each linking to the page that item lives on. That is the vocabulary
this app already uses for "here is what is not right yet".

Rendered on **Settings → Options** and **Categories** (the pages that host
the three settings, so the notice appears the moment one is changed) and on
**Settings → FIDE** with `show_compliant`, which is where somebody goes to
ask the question. Not in the layout: FIDE handling is the default, and a
banner announcing it on every page is noise that teaches people to skip
banners.

**It does not argue and it does not block.** No confirmation, no "fix it"
button, no refusal. An arbiter running a club evening that will never be
rated has every right to any of the three, and the software's job is to say
what it means, once, and get out of the way.

`Compliance` returns codes and never sentences - the domain layer does not
use gettext, and a warning that cannot be translated is a warning half this
app's users cannot read. `compliance_message/1` in the web layer is the only
place codes become words, and `compliance_notice_test.exs` fails if a code is
added without one.

### 3.6 The audit row

`tournament.fide_compliance_lost`, one per departure a save actually
introduced, carrying the setting, the code and the round. Its own action
rather than folded into the bulk settings diff, for the same reason
`tournament.locked_field_changed` is: the round is the fact FIDE asks for by
name, and it must not go unnoticed inside whatever else that save touched.
`fide_compliance_lost_round` is in `@settings_diff_ignore` for the mirror
reason - in the bulk diff it would read as one more changed field with no
cause attached.

### 3.7 What was deliberately not built

- **A FIDE Mode toggle.** Section 0c.
- **Levels 1-5.** Still unknown, still blocked on TEC. When the definitions
  arrive, a level is one more key on each entry in `Compliance`'s
  `@departures` table; the mechanism underneath does not change. A guessed
  level is worse than none, because the levels are what verification reads.
- **The `###` TRF emitter.** Belongs in `Ainalrami.Trf`, and is a separate
  change. `fide_compliance_lost_round` is what it will read.
- **Any change to pairing behaviour.** This is observation and reporting.
- **Anything touching `fide_homologated`.** See 7.4, which now has an answer.

---

## 4. The `###` TRF comment

### 4.1 What exists today

**Nothing.** Verified against Ainalrami v0.24.0 (`d90fd3a`), which is what
`mix.exs:159` pins:

- `grep -n '###' deps/ainalrami/lib/ainalrami/trf.ex` returns no matches.
  There is no comment record in the writer and no comment concept in the
  parser.
- `serialize/2` (`trf.ex:545-572`) builds a flat list of line strings
  through eight `Kernel.++` steps and joins them with CRLF at `:571`. There
  is **no hook for caller-supplied lines**. The nearest thing is
  `legend_lines/2` (`trf.ex:1046-1052`), which emits a blank line and three
  ruler/legend lines under `opts[:column_legend]` - proof that
  non-record lines are acceptable in the file, not a mechanism for adding
  more.
- `parse/1` (`trf.ex:1648-1727`) splits on all three line endings, drops
  blank lines, and dispatches on `String.slice(line, 0, 3)`. `"###"`
  matches no clause and falls through to `parse_header_line/3`
  (`trf.ex:2485-2491`), which looks the code up in `@header_codes`
  (`trf.ex:117`) and **returns the accumulator unchanged** when it finds
  nothing.

So the current behaviour of a `###` line is: **silently ignored on read,
and lost on any re-write.** Ignored is safe. Lost is a real limitation and
section 4.5 is about it.

### 4.2 Which module writes it

**Ainalrami, not OpenPairings.** Add `tournament[:comments]` (a list of
strings) to `serialize/2` and emit one `###` line per entry.

The alternative - having OpenPairings post-process the serialized string -
is worse for two reasons. First, this app has three TRF producers:
`TrfExport.build/3` (`trf_export.ex:168-246`, which calls `Trf.serialize`
at `:186`), `Pairing.build_category_trf/5` (`pairing.ex:776-845`, calling
it at `:818`), and the engine-input path. Post-processing means deciding
the same question three times or centralising it in a fourth place.
Second, and more important, **line order is the writer's business**.
`serialize/2`'s eight-step pipeline is where the file's structure is
decided; putting one line's position in a string concatenation somewhere
else means two modules own the layout of one file.

The Ainalrami change is small - one option, one emit step in the pipeline,
one round-trip test - and it moves the pin, which is a known-costly
operation (`TODO.md:449-457` documents the dirty-checkout failure mode that
took the site down on 2026-08-28). Phase 3 accounts for it.

### 4.3 Where in the file

**Recommendation: immediately after the header block (the `0NN` records)
and before the first `001` player row.**

- A reader scanning the head of a file finds it. A comment at the end of a
  400-player file is a comment nobody reads.
- It survives truncation, which is how TRFs get damaged in practice.
- It cannot disturb the column-position machinery, which only concerns
  `001`/`013` lines.
- It sits after `legend_lines/2`'s ruler block would, or before it -
  either is defensible; put it before, so the legend stays adjacent to the
  rows it describes.

**This position is our choice.** Whether TEC specifies one is not
established.

### 4.4 What it must contain

The one thing the requirement is reported to demand is **the round in which
the mode was left**. Everything else is ours.

Proposed line, with a stable machine-readable prefix so a future reader can
find it without prose matching:

```
### FIDE-MODE-LEFT round=4 at=2026-09-09T14:22:07Z reason=prohibited-pairing-added
```

- `round=0` means "left before round 1 was paired" and must be documented
  as such, because `0` otherwise reads as missing data.
- The reason is a **code**, not a sentence: sentences get translated,
  translated report lines are unreadable to the recipient, and Q10 already
  penalises non-English elements.
- No player names, no free text. A comment line in a file submitted to FIDE
  is not the place for anything an arbiter typed.

**Risk, stated plainly:** if TEC specifies a format we do not have, ours
will be wrong. The mitigation is structural rather than clever - a `###`
line is a comment by construction, so a wrongly-formatted one is not a
parse failure for anybody. Getting the format wrong costs a re-export;
omitting the line costs the hard failure.

### 4.5 Reading one back

Out of scope for the first pass, but worth writing down while the shape is
in view. A TRF that says the exporting program left FIDE mode in round 4 is
a material fact about a file this app is importing, and it is exactly the
class of thing Q54 asks an importer to notice.
`PairingsEngine.TrfImport` already has the right channel: the
`verification_warnings/2` mechanism (`trf_import.ex:1212-1266`) reports
findings without ever blocking the import, and its own comment gives the
three rules that make such a warning worth having.

That needs Ainalrami's parser to keep comment lines rather than dropping
them (4.1), which is the same change viewed from the other end. Phase 5.

---

## 5. Blast radius

Every place that would have to be touched or consciously left alone. House
style follows `docs/audit-2026-09-05.md`: file, approximate line, then what
is actually there.

**Written before 0.56.0, and still the best map of the affected surface** -
every file and line below is real and was checked. Read it alongside section
3, which says what actually landed where. Three items read differently now:
item 1 became one column rather than three (3.1); item 4's reasoning about
`restore_into!/2` is wrong in a way worth reading (3.4, and 6b item 1); and
items 9-11 - the choke points in a live round - were deliberately **not**
touched, because 0.56.0 refuses nothing.

**Schema and persistence**

1. `lib/pairings_engine/tournaments/tournament.ex:211` - the schema block.
   Three fields added beside `fide_homologated`, and deliberately **not**
   added to the cast list at `:~640-700`.
2. `priv/repo/migrations/` - one new migration. Three `add` calls, no table
   rebuild.
3. `lib/pairings_engine/tournament_export.ex:72-90` - `@tournament_fields`.
   **This is enforced**: `test/pairings_engine/tournament_export_test.exs:52-54`
   and `:253-266` assert that every schema field is either in that list or
   in `@excluded_tournament_fields` with a reason, and `:337` fails the
   build otherwise. Adding a field forces the include/exclude decision;
   there is no way to forget it.
4. `lib/pairings_engine/tournament_import.ex:201-219` -
   `restore_into!/2`. The re-entry hole (3.3b). **The single highest-risk
   line in the whole change.**
5. `lib/pairings_engine/tournament_import.ex:237-270` - `import_tournament!/2`.
   The opposite decision, same mechanism.
6. `lib/pairings_engine/snapshots.ex:397` - restore goes through (4);
   nothing separate to do, but the moduledoc at `:29-35` should name the
   new fields alongside `openresults_key`, since it is now the second
   instance of that rule and the reasoning is shared.
7. `lib/pairings_engine/handoff.ex:688` - the return path, also through
   (4). Covered, but worth an explicit test: a tournament that left FIDE
   mode, was handed off, and came back must still have left it.
8. `lib/pairings_engine_web/live/tournaments_live.ex:688-705` -
   "Duplicate", which round-trips through (5). Inherits whatever (5)
   decides. See 7.5.

**The choke points other hard-failure items will use**

9. `lib/pairings_engine/tournaments.ex:2811` - `update_pairing_result/2`.
   The sole writer for every result path: `pairings_live.ex:469` and
   `:516`, `mobile_results_live.ex:235`, `results_import.ex:329`. Its guard
   today is `ensure_writable/1` and nothing about *which* round. This is
   where Q189-191 (past results) and Q157-169 (adjournment) both land, and
   both want to ask the mode whether to refuse or warn.
10. `lib/pairings_engine/tournaments.ex:2503` - `add_forbidden_pairing/4`.
    Guarded by `write_refused/1` only. Q196; the letter's B.6 argues for a
    Level-4 warning here rather than a prohibition. Note the arity:
    `TODO.md:356` calls it `/3`, and it takes an `opts` list.
11. `lib/pairings_engine/pairing.ex:105` - `pair_next_round/1`. Refuses via
    `Tournaments.refusal_message/2` (`tournaments.ex:1783-1795`), which is
    the existing vocabulary a mode-based refusal should join rather than
    invent a parallel one.
12. `lib/pairings_engine/tournaments.ex:2038-2079` - `update_player/2` and
    `guard_pairing_number_freeze/2`. Not a change site, but **the closest
    existing precedent**: a FIDE article cited in a comment, a
    round-conditional refusal, and an explicitly narrow scope. Copy its
    shape.
13. `lib/pairings_engine/tournaments.ex:716-810` - `locked_fields/1` and
    `ensure_unlocked/3`. **Deliberately not used**, and the reason is the
    finding: `ensure_unlocked/3`'s defining feature is the `:unlock`
    option, whose whole purpose (`settings_support.ex:213-249`) is letting
    an arbiter click past the lock after reading what it costs. A rule that
    must never be overridden cannot live in the mechanism built to be
    overridden. `docs/sweep-2026-08-26.md:2358` recommends
    the opposite; it is wrong, and this contradiction should be recorded
    wherever the work lands. Secondary reason: `locked_fields/1` returns
    `[]` until a round is paired (`:719-720`), and leaving the mode before
    round 1 is a real case.

**TRF**

14. `deps/ainalrami/lib/ainalrami/trf.ex:545-572` - `serialize/2`'s
    pipeline. One option, one emit step.
15. `deps/ainalrami/lib/ainalrami/trf.ex:2485-2491` - `parse_header_line/3`.
    Only for Phase 5 (reading a `###` back).
16. `lib/pairings_engine/trf_export.ex:186` - the arbiter-facing export;
    passes the comment through.
17. `lib/pairings_engine/pairing.ex:818` - the engine-input build.
    Deliberately does **not** pass it: the file exists to be handed to a
    pairing engine, and a comment about our own conformance is not
    information the engine needs. Say so in the code.
18. `mix.exs:159` / `mix.lock` - the Ainalrami pin moves. Read
    `TODO.md:449-457` before deploying that.

**Warnings, audit and UI**

19. `lib/pairings_engine_web/live/audit_live.ex:121-309` - `describe/1`
    needs clauses for the new action codes; the catch-all at `:309` renders
    a raw code, so a missing clause degrades visibly rather than crashing.
20. `lib/pairings_engine_web/live/audit_live.ex:29-49` - `@categories`.
    Novel codes appear under "All" but nowhere else; FIDE-mode rows want
    their own bucket or a home in "settings".
21. `lib/pairings_engine_web/live/settings_fide_live.ex:86-92` and
    `:164-172` - the save path and the toggle. The page grows a mode card;
    `fide_homologated` stays exactly as it is (2.3, item 1).
22. `lib/pairings_engine_web/live/settings_options_live.ex:645` and
    `:1012` - two advisory notes keyed on `fide_homologated`. Decide
    consciously whether they should key on the mode instead. The engine
    choice is a conformance question, so probably yes - but that turns two
    informational sentences into mode-driven behaviour and should be a
    decision, not a side effect.
23. `lib/pairings_engine_web/components/layouts.ex:259` and `:285` - the
    banner region. A third banner joins the two that are there.
24. `lib/pairings_engine_web/live/settings_support.ex:414-425` -
    `log_settings_change/3`. The three new fields are outside the cast, so
    they will not appear in the settings diff and must not: the exit has
    its own audit action, for the same reason `log_unlocked_field_changes/4`
    exists as a separate one (`:428-441`).

**Downstream and elsewhere**

25. `lib/pairings_engine/snapshot.ex:153` - the OpenResults payload.
    Additive-only by contract, so a `fide_mode_left_round` key can be added
    safely. Whether it *should* be published is 7.6. `"fide_rated"` keeps
    reading `fide_homologated`.
26. `lib/pairings_engine/federations/bel/swar_export.ex:220` and
    `swar_publish.ex:415` - both read `fide_homologated` and both should
    keep doing so. SWAR's field is "is this rated and by whom", which is
    not the same question.
27. `lib/pairings_engine_web/controllers/print_controller.ex:1580` -
    printed tournament-info line. No change unless 7.7 says otherwise.
28. `priv/gettext/` - new strings, in the web layer only.
    `TODO.md:571-576` records Dutch as complete at 918/918 and
    test-enforced, so an untranslated addition fails the suite.
29. `docs/fide-endorsement.md:196-224` - Section A currently says FIDE Mode
    is "inherited from JaVaFo's own endorsement - not applicable to audit",
    with a block quote at `:198-208` saying that will not survive the next
    cycle. When this ships, that section is rewritten, not annotated.
30. `TODO.md:347-352`, `docs/features.md`, `CHANGELOG.md` - the changelog
    entry belongs in the same commit as the user-visible change, and
    `mix pairings.version_check` (wired into `mix precommit`) refuses when
    the version headers disagree.

---

## 6. Build plan

Re-phased on 2026-09-10 around what section 3 now describes. The first two
phases are **done**; what follows them changed shape, because the mechanism
they were waiting on exists and is not the one the old plan assumed.

### Phase 0 - get the Level definitions. Not code. Still blocking.

Obtain VCL4THP v13 and the TEC Manual's Level 1-5 definitions and file them
in `docs/`. Attempted 2026-09-10 and **they cannot be got from any public
source** - see section 0b for the search, which is worth not repeating. It is
now a request rather than a search: `request-tec-vcl4thp.md`, on the
correspondence the 2026-09-08 letter opened.

Three of the questions came back on 2026-09-10 and are section 0c. Two remain
open and both still block: the Level definitions themselves, and the letter's
C.3 (may we warn louder than the minimum?).

**No longer blocking anything that was going to be built anyway.** That is
the difference this re-phasing makes: the old plan put a five-level warning
funnel in phase 2 and everything downstream behind it. What exists instead is
a mechanism the Levels are a *labelling* on top of, and it shipped without
them.

### Phase 1 - the inventory. DONE, 0.56.0.

Not code, and the real work: deciding for each tournament setting whether it
has a FIDE-compliance dimension at all and whether its default is compliant.
Three settings qualified out of roughly two dozen examined; section 3.2 is
the result and `PairingsEngine.Compliance`'s moduledoc is the reasoning per
setting, including every case that was rejected.

Rejecting is most of the value here. Two of the rejections turned on
documents rather than opinion (`VCL.12`/`VCL.16`/`VCL.17` requiring the
scoring surface to be configurable; TRF26's `299` record existing for
administrative points), and one on a live disagreement with TEC that this
change had no business pre-empting (Q196).

### Phase 2 - the derived state, the record, and the notice. DONE, 0.56.0.

`PairingsEngine.Compliance`; `tournaments.fide_compliance_lost_round` and the
migration; the stamp inside `update_tournament/3` and both
`create_tournament` clauses; the watermark rule in both `TournamentImport`
paths; the export field-list decision; the shared notice component on three
pages; the audit action and its `describe/1` clause; the Dutch strings.

Ships as: *a tournament says when its settings stop describing a FIDE-handled
event, records the round, and nothing can rewrite that record.* No behaviour
changes for anybody who does not change one of the three settings.

Tests that earned their place, and each was watched failing: a Keizer
tournament records round 0 rather than nil; a mid-event save records the
round that exists; a second departure does not move the record; putting the
setting back leaves it standing; a refused save records nothing; a
pre-loss snapshot restore does not un-record it; a hand-off brings home a
loss that happened on the other machine; a hand-off does not un-record one
that happened here; a JSON backup round-trips it; a Swiss-only setting is not
reported on a tournament that never pairs Swiss.

### Phase 3 - the `###` comment. ~half a day in Ainalrami, ~half a day here.

`tournament[:comments]` in `Trf.serialize/2`, a round-trip test, a tagged
release, the pin move, then wiring it in `TrfExport.build/3` from
`fide_compliance_lost_round` and deliberately **not** in
`Pairing.build_category_trf/5`. Read `TODO.md:449-457` before the deploy that
carries the new pin.

Unblocked: the round it needs is now stored and survives everything. Section
4 below still describes the format, and the parts of it that are ours rather
than FIDE's are still marked.

### Phase 4 - the Levels, once they exist.

One extra key per entry in `Compliance`'s `@departures`, and a level shown
beside each line of the notice. That is the whole of it, provided nothing
guesses in the meantime.

**The open question this cannot answer for itself** is section 1.3.B: whether
some acts (adding a prohibited pairing in round 5, Q196) are *themselves*
exits, or merely high-level warnings. If they are exits, they call the same
stamp that `update_tournament/3` does, at `add_forbidden_pairing/4` and
`update_pairing_result/2`. **Do not wire those until B is settled** - getting
it wrong in the strict direction permanently marks tournaments as
non-conforming in files sent to FIDE, and that is not correctable.

### Phase 5 - adjournment (Q157-169). Days, not hours. Separate scope.

`docs/sweep-2026-08-26.md:2335-2348` has the three touch points worked out,
including the warning worth repeating: express "counts as a draw for pairing
purposes" in the single scoring function 0.17.1 consolidated on, not in a
second mapping.

### Phase 6 - read a `###` line back on import. ~half a day.

Ainalrami's parser keeps comment lines; `TrfImport`'s existing
`verification_warnings/2` channel reports them. Genuinely optional, and the
cheapest of the lot once Phase 3 exists.

### What the old plan had here, and why it is gone

The old Phase 2 was "the warning funnel and its first two consumers", called
"the risky phase" because it changed what the app refuses during a live
round, at `update_pairing_result/2` and `add_forbidden_pairing/4`. That
risk was real and the phase is gone: **nothing built in 0.56.0 refuses
anything.** Compliance is observation and reporting, the two hot write paths
were not touched, and the enforcement question is deferred to Phase 4 where
it now sits behind the answer it always needed.

---

## 6b. What the old sections got wrong against the real code

Kept because a design document that quietly corrects itself teaches nobody.

1. **Section 3.3b's premise.** It says a restore would un-leave the mode, and
   prescribes re-asserting from the live row. An uncast field survives
   `restore_into!/2` untouched, because the changeset is built on the live
   struct - so the hole is not there. And re-asserting the live value would
   have *created* a hole: `Handoff.release/3` returns through the same
   function, and the returning payload is the only record of a loss that
   happened on the other machine. See 3.4.
2. **Three columns where one does.** The old 3.2 wanted `left_round`,
   `left_at` and `left_reason`. `left_at` duplicates the audit row's
   timestamp and `left_reason` duplicates the audit row's `details`. One
   column, one fact, and the trail already answers who and why.
3. **`allow_swiss321` is not a tournament setting.** It is an option on the
   SWAR parser, refused by default for reasons about bye values, not FIDE.
4. **The audit-diff assumption.** The old blast radius (item 24) says the new
   fields "are outside the cast, so they will not appear in the settings
   diff". `tournament_diff/2` walks `Tournament.__schema__(:fields)`, not the
   cast list, so an uncast field appears unless it is named in
   `@settings_diff_ignore`. It is.
5. **The gettext catalogue is 172 strings behind `lib/`** (measured
   2026-09-10 by running `mix gettext.extract --merge` and reverting it).
   `translations_test.exs` cannot see this, because it only checks entries
   that are already in the catalogue. Not a FIDE-mode problem, but anybody
   adding UI strings here will meet it: extracting pulls in a large
   untranslated backlog that is nothing to do with their change.

---


## 7. Open questions for the maintainer

Answers folded in on 2026-09-10 where 0.56.0 settled one. The question is
kept above the answer in each case, because the reasoning for the answer only
makes sense against the question that prompted it.

**7.1 Is FIDE Mode per tournament or per installation?**
**Answered by 0c: per tournament, and the default.** Built that way. If TEC
ever reads it the other way, what is here is still the right foundation - an
installation-level default would feed the per-tournament computation, which
is an addition rather than a rewrite.

**7.2 Does anything besides changing a setting cause a departure?**
**Still open**, and it is section 1.3.B. This decides whether Q196's
enforcement sites (`add_forbidden_pairing/4`, `update_pairing_result/2`) also
stamp `fide_compliance_lost_round`, or merely warn. Getting it wrong in the
permissive direction under-reports; getting it wrong in the strict direction
permanently marks tournaments as non-conforming in files sent to FIDE.
**The strict direction is not correctable, so the default answer stays "no"
until TEC says otherwise**, and 0.56.0 wired none of them.

**7.3 What happens to existing tournaments at migration time?**
**Answered: `nil` for every existing row**, and the migration says why in its
own comment. `nil` claims every tournament already in the database was
handled compliantly, which is unprovable - but the alternative (`0` for
everything) puts a `###` line in the re-export of every past event on the
grounds that this software was not watching at the time. The mode is a
statement about how the program behaves from here, not a verdict on rounds
already paired.

**7.4 Should `fide_homologated` stay, exactly as it is?**
**Answered: yes, unchanged in 0.56.0 - and a proposal for what to do next
sits alongside it.** The two facts really are independent (homologation is
"will this be rated"; compliance is "was this handled to the letter"), and
this change relied on that by leaving `swar_export.ex` and `swar_publish.ex`
reading `fide_homologated` exactly as before. The confusion risk is real and
it is now managed by copy rather than by structure: the FIDE settings page
carries a card that states the compliance state and one sentence saying in as
many words that it is **not** the same question as the tickbox below it.

The proposal, deliberately not executed - removing a user-visible field is a
migration and a decision, not a refactor:

  * **Keep the column.** All seven of its reads are load-bearing in ways
    compliance cannot replace: `swar_export.ex:220` and `swar_publish.ex:415`
    answer "is this rated and by whom", which is a federation question;
    `snapshot.ex:153` publishes `"fide_rated"`; `print_controller.ex:1580`
    prints the FIDE ID; `tournament.ex:1324` gates a soft nudge for the ID.
  * **Rename what the arbiter reads, not what the code reads.** The label is
    "This tournament is FIDE-homologated (rated/reportable)", which invites
    exactly the confusion. "This tournament will be submitted to FIDE for
    rating" says the same thing without using a word that sounds like a
    conformance claim. One gettext string, one Dutch string, no migration.
  * **Move the two advisory notes on the Options page** (`:645`, `:1012`,
    both keyed on `fide_homologated`) to key on nothing at all. They are
    about which edition of the rules an engine implements, which is true
    whether or not the event is being rated - and section 3.2 explains why
    the engine choice is deliberately *not* a compliance departure. Keying
    them on homologation makes an engine question look like a rating
    question.
  * **Do not delete it, and do not fold compliance into it.** A second
    FIDE-ish tickbox is what 0c warns against; one tickbox doing two jobs is
    worse, because the arbiter cannot then say "rated, and run my own way",
    which is a real and permitted thing to be.

**7.5 Does "Duplicate" inherit a compliance loss?**
**Still open, and now concrete.** "Duplicate" round-trips through
export/import (`tournaments_live.ex:688-705`), so it inherits the recorded
round because `import_tournament!/2` takes the file's value - which is right
for a backup and arguable for a copy. A duplicate is often the start of a
*new* event, where inheriting a permanent, unclearable mark is unwelcome. The
counter-argument is that a duplicate also inherits the settings that caused
it, so a fresh `nil` would immediately be re-stamped at round 0 anyway - the
two answers differ only for a duplicate whose settings were since put back.
Low stakes either way; worth a decision rather than an accident.

**7.6 Does compliance reach OpenResults?**
**Still open, and untouched by 0.56.0.** The snapshot is additive-only so a
`fide_compliance_lost_round` key is safe to add. The question is whether the
public results page for a club tournament should say the software stopped
matching the FIDE rules in round 4 - meaningful to an arbiter, and meaningless
or worse to a parent looking up their child's game.

**7.7 Do printed documents carry it?**
**Still open, and untouched.** `print_controller.ex`'s
`tournament_info_html/1` (`:1560-1590`) is shared by every printed document,
and a pairing sheet is posted on a wall.

**7.8 Are the "Levels 1-5" a severity scale on warnings, or states the
tournament occupies?**
**Still open, and it now costs less to be wrong about.** 0.56.0 assumes
neither: it reports departures with no level attached at all. If the Levels
are a severity scale, they are one key per entry in `@departures`. If they
are states, `Compliance` grows a second function and the `###` line records
the level too. Nothing built so far forecloses either.

**7.9 Do you want the sweep's contradiction recorded?**
**Recorded, and it is settled by what was built.**
`docs/sweep-2026-08-26.md:2358` and `:2366` recommend routing the exit
through `locked_fields/1` + `ensure_unlocked/3`. Section 5, item 13 argues
that is wrong because that mechanism exists to be overridden - and 0.56.0
follows section 5, not the sweep. But the disagreement mostly dissolved: the
three compliance settings are *already* in `locked_fields/1` for entirely
separate reasons (they reinterpret rounds that already exist), and compliance
neither refuses nor overrides. The two mechanisms sit side by side and answer
different questions, so there was never a choice to make.
