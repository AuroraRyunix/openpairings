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

## 3. The design

### 3.1 Scope: per tournament, defaulting on

**Recommendation: model the mode on the tournament, default it on, and
satisfy VCL.01/VCL.02 by the default rather than by an installation
switch.**

Reasons, in order of weight:

- **"No re-entry" is only survivable per tournament.** OpenPairings runs
  one BEAM node against one SQLite database serving many accounts and many
  tournaments (`docs/architecture.md:8-46`). An installation-level one-way
  door means one arbiter's decision on one club event permanently disables
  FIDE mode for every other tournament on the box, with no way back short
  of a reinstall. No reading of the requirement produces that on purpose.
- **The `###` line needs a round, and rounds belong to tournaments.**
- **VCL.01 is satisfied.** A tournament created by a standard installation
  and a standard invocation is in FIDE mode, because the field defaults to
  it and nothing has to be configured. That is what "default operating
  mode" asks for.
- **It matches how every other constraint in this app is scoped.**
  `locked_fields/1`, `ensure_writable/1`, `absent_counts_as_vur`,
  `pairing_engine` - the whole regulation-shaped surface is per tournament.

What it costs: if TEC's reading turns out to be installation-level, we have
a per-tournament mechanism and would need an installation-level default on
top of it (one `Application.get_env` read feeding the schema default). That
is an addition, not a rewrite. The reverse mistake is not recoverable.

### 3.2 Schema

Three new columns on `tournaments`, and deliberately **no boolean**:

```elixir
# Whether this tournament is still being handled in FIDE Mode is not
# stored: it is `is_nil(fide_mode_left_round)`. See PairingsEngine.FideMode.
field :fide_mode_left_round, :integer            # nil while never left
field :fide_mode_left_at, :utc_datetime          # nil while never left
field :fide_mode_left_reason, :string, default: ""
```

**Why no `fide_mode` boolean.** `docs/sweep-2026-08-26.md:2357` proposed
`fide_mode` *and* `fide_mode_left_round`, and then noticed in the same
sentence that the rule is `fide_mode_left_round != nil`. Two columns that
must always agree are one rule spelled in two places - the exact shape
`TODO.md:146-152` names as this codebase's recurring bug class, and the
shape that produced the `absent_counts_as_vur` polarity error and the
`voluntary` inconsistency between two paths in one file. One column, one
predicate, no possible disagreement.

**Why a nullable round rather than a sentinel.** `0` is a legitimate value:
a mode left before round 1 was paired. `nil` has to mean "never left" and
nothing else.

**Why `left_at` and `left_reason` at all.** Neither is required by anything
we know of. `left_at` is cheap and answers "was this before or after the
incident"; `left_reason` is what makes the audit row and the banner say
something useful instead of "it was left". Both are ours (1.4).

**Migration.** One `ALTER TABLE` per column, SQLite-friendly, no table
rebuild - the same shape as
`priv/repo/migrations/20260906120000_add_soft_pairing_rules.exs`. Backfill
is an open question (7.3): `nil` for every existing row means every
historical tournament claims to have been handled in FIDE mode, which is
neither provable nor disprovable from the data.

### 3.3 The state machine, and why it is one function short

Two states, one transition:

```
    IN MODE                                    LEFT
  left_round == nil   ──── leave/3 ────▶   left_round == n
       ▲                                        │
       └────────────── (nothing) ◀──────────────┘
```

**The no-re-entry rule is not a check. It is the absence of a function.**

`PairingsEngine.FideMode` exposes `leave/3` and does not expose `enter/1`.
There is no code path that sets `fide_mode_left_round` back to `nil`, so
there is no guard that can be forgotten, no `:unlock` option that can be
passed, and no admin escape hatch that will be added "just for support" in
six months. A caller cannot get it wrong because there is nothing to call.

That only holds if nothing else can write the column. Three mechanisms in
this app write tournament fields, and all three have to be handled:

**(a) `Tournament.changeset/2` (`tournament.ex:~640-700`).** The three new
fields are **not added to the cast list.** This is the codebase's own
established answer for a field no ordinary save may touch, and there are
three precedents: `openresults_key` (reasoning at `snapshots.ex:27-35`),
`manual_ranking_stale` (`tournament_import.ex:242-246`), and
`logo_data`/`logo_content_type` (`tournaments.ex:860-913`). Following the
existing pattern also means the existing tests that assert the cast list
keep their meaning.

**(b) `TournamentImport.restore_into!/2` (`tournament_import.ex:201-219`).**
This is the sharpest hole in the whole design and it is invisible unless
you go looking. `Tournaments`' own comment
(`tournaments.ex:702-705`) says restore *deliberately* bypasses
`update_tournament/3` "because restoring a snapshot legitimately sets every
field back at once, locks included." A restore point taken before the exit
would therefore un-leave FIDE mode, silently, through a button on the
History page - and `Handoff` returns a tournament through the same function
(`handoff.ex:688`), so the same hole exists on the round trip to another
machine.

The fix is two lines and it already has a template directly above it:
`restore_into!/2` currently carries `manual_ranking_stale` across
explicitly with `Ecto.Changeset.change/2` (`tournament_import.ex:206-209`)
because it is outside the cast. The three FIDE-mode fields do the opposite
- they are re-asserted from the **live row**, not from the snapshot:

```elixir
|> Ecto.Changeset.change(
     manual_ranking_stale: truthy(Map.get(t_attrs, "manual_ranking_stale")),
     fide_mode_left_round: tournament.fide_mode_left_round,
     fide_mode_left_at: tournament.fide_mode_left_at,
     fide_mode_left_reason: tournament.fide_mode_left_reason)
```

The reasoning is identical to `openresults_key`'s, and `snapshots.ex:27-35`
already writes it out for that field: rolling back past an event that has
already been reported must not un-report it.

**(c) `TournamentImport.import_tournament!/2` (`tournament_import.ex:237-270`).**
A *new* tournament minted from a file - a JSON backup, and also the
"Duplicate" action, which round-trips through export and import
(`tournaments_live.ex:688-705`). Here the file's values **should** be
carried, so a backup of a tournament that left FIDE mode restores as one
that left. Same `Ecto.Changeset.change/2` call, opposite source. The
duplicate case is an open question (7.5).

So: one writer, one cast exclusion, one line in each of two import
functions. That is the entire no-re-entry rule, and every part of it is
mechanical.

### 3.4 Where `leave/3` is triggered

```elixir
@spec leave(Tournament.t(), Scope.t() | nil, String.t()) ::
        {:ok, Tournament.t()} | {:error, :already_left | :archived | :handed_off}
def leave(%Tournament{fide_mode_left_round: r}, _actor, _reason) when not is_nil(r),
  do: {:error, :already_left}

def leave(%Tournament{} = t, actor, reason) do
  with :ok <- Tournaments.ensure_writable(t) do
    round = PairingsEngine.Pairing.paired_rounds_count(t.id)
    # ... one Repo.update, then Audit.log + broadcast_tournament_change
  end
end
```

**Which round.** `Pairing.paired_rounds_count/1` (`pairing.ex:266-268`)
counts `Round` rows - "how many rounds exist", not "how many are complete".
That is the right number here and it is worth saying why, because this
codebase has been bitten by the wrong one: `TODO.md:705-716` records
`adjusted_score/3` mixing a record count with a round number and putting a
wrong figure on an arbiter's screen. Here the question is "which round was
under way when this happened", and the round under way is the highest one
that exists. `0` before any round is paired, and the `###` line has to be
readable as "before the tournament started".

**Callers.** Exactly one in Phase 1: the confirmed "Leave FIDE Mode" action
on Settings → FIDE. Under reading B(ii) of section 1.3, some enforcement
sites would call it too - `add_forbidden_pairing/4` (`tournaments.ex:2503`)
being the first candidate, per the letter's B.6. **Do not wire those until
B is settled.** An automatic exit that turns out not to be required is a
tournament wrongly marked non-conforming in a file submitted to FIDE, and
it is not correctable afterwards.

### 3.5 The warning funnel

There is no warning funnel today. `settings_options_live.ex:645` and
`:1012` render `.error-note` spans inline, per page, hand-written, and that
is the whole of the app's vocabulary for "this is allowed but you should
know".

Recommended shape - one new module, `PairingsEngine.FideMode`:

```elixir
@spec check(Tournament.t(), atom(), map()) :: :ok | {:warn, 1..5, atom(), map()}
```

Four properties, each with a reason:

- **Levels live in one table, and their provenance is marked.** A single
  module attribute maps `{action, condition} -> level`, with each entry
  tagged as taken from the TEC Manual or chosen by us pending it. That
  localises the unknown from section 1.3.C to one literal instead of
  scattering integers through call sites, and it is what makes the letter's
  C.3 answer (may we warn louder than the minimum?) a one-file change when
  it arrives.
- **Warnings are events; blockers are predicates.** A warning is logged and
  shown once, at the moment of the action - `Audit.log/4` with an action
  code, the level and the code in `details`. A state that must persist
  (adjourned games outstanding, mode left) is *derived* from the tournament
  on read, never stored as a warning row. Mixing the two is how a warnings
  table starts and then has to be reconciled with reality.
- **No new table in Phase 1.** The audit trail already carries the acting
  user, the timestamp, a structured payload and a rendering path
  (`AuditLive.describe/1`, `audit_live.ex:121-309`). A second table
  answering "what happened and who did it" would be a second answer to a
  question that already has one.
- **`check/3` returns codes, never sentences.** The domain layer does not
  use gettext - `lib/pairings_engine/features.ex:62` is the only module in
  `lib/pairings_engine/` that does. Message text belongs in a web-layer
  renderer. Getting this backwards produces warnings that cannot be
  translated, which is Q10's 10% penalty on exactly the elements Q10 names.

### 3.6 What the arbiter sees

**While in mode: almost nothing.** FIDE mode is the default (VCL.01), so a
banner announcing it on every page is noise that trains people to ignore
banners. One line on Settings → FIDE stating the mode and offering the exit.

**On leaving: the double warning, satisfying all three readings of 1.3.D at
once.** Two steps, the second demanding more than a click - the house
precedent is `force_unlock_panel/1` (`settings_support.ex:252, :290`), which
makes an arbiter type a word that names the act, on the stated reasoning
that a half-read dialog should still spell out what the typing is for. The
same warning then goes into the report as the `###` line (section 4), which
is the "delivered twice" and "shown to the reader as well" readings.

**After leaving: a layout banner.** In `Layouts.app/1` beside the archived
and handed-off banners (`layouts.ex:259` and `:285`), which carry the
argument in their own comment: rendered in the layout "so it cannot be
forgotten on one" page. Permanent and not dismissible - the tournament's
state changed and there is no way back, which is precisely the two
properties those banners already encode.

**Anywhere a control is inhibited: hide it or visibly disable it with a
reason.** This is the Vega finding from 1.1, and it is the requirement most
likely to be met by accident and then broken. A control that renders,
accepts a click and does nothing was written up by the verifier as
misleading.

**Not decided here:** whether printed documents carry the mode. See 7.7.

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

Sizes are rough and assume familiarity with the codebase. Each phase ends
somewhere shippable.

### Phase 0 - get the Level definitions. Not code. Blocking for Phase 2.

Obtain VCL4THP v13 and the TEC Manual's Level 1-5 definitions, and file
them in `docs/` so the next person is not reading one person's memory of
one PDF. `docs/tec-feedback-2026-09.md:233-239` proves they were read once.
Everything in Phase 1 can proceed without them; nothing in Phase 2 should.

**Also worth resolving here:** the letter's own unanswered question about
warning louder than the minimum (C.3), and reading B from section 1.3 -
whether a Level-4 warning and a mode exit are the same event.

### Phase 1 - state, the one-way door, audit, banner. ~1 day. Shippable.

Migration; three fields outside the cast; `PairingsEngine.FideMode` with
`in_mode?/1`, `left_round/1` and `leave/3` and no `enter/1`; the two
`Ecto.Changeset.change/2` lines in the import functions; the Settings →
FIDE card with the two-step confirm; the layout banner; audit action codes
and their `describe/1` clauses; the export field-list decision.

Ships as: *a tournament can leave FIDE Mode, it says so everywhere
afterwards, and nothing can put it back.* No behaviour changes for anyone
who does not press the button, which is what makes it safe to ship alone.

Tests that earn their place: leaving twice is refused; restoring a
pre-exit snapshot does not un-leave; a hand-off round trip does not
un-leave; a JSON backup of a left tournament imports as left; the round
recorded is the round that existed.

### Phase 2 - the warning funnel and its first two consumers. ~1-2 days. **This is the risky phase.**

`FideMode.check/3`, the level table with per-entry provenance, the
web-layer renderer, and then Q196 (`add_forbidden_pairing/4`) and Q189-191
(`update_pairing_result/2`) routed through it.

**Why it is the risky one, in three parts.**

*It is the only phase that changes what the app refuses during a live
round*, at the two functions arbiters touch most - one of which
(`update_pairing_result/2`) is described in its own code as the write made
"most often, under the most time pressure" and wrapped in `BusyWrite` for
exactly that reason (`tournaments.ex:2817-2823`). A wrong refusal here is
an arbiter who cannot enter a result in a hall.

*Its correctness depends on the definitions Phase 0 fetches.* Choosing
level 3 where the Manual says 4 is not a cosmetic error - the levels are
what the verification reads.

*And a wrong choice is invisible.* A warning that should have been a
refusal looks exactly like working software until FIDE verifies. There is
no test that catches it and no user who reports it. This is the one place
in the plan where going slower is straightforwardly cheaper.

### Phase 3 - the `###` comment. ~half a day in Ainalrami, ~half a day here.

`tournament[:comments]` in `serialize/2`, a round-trip test, a tagged
release, the pin move, then wiring it in `TrfExport.build/3` and
deliberately not in `Pairing.build_category_trf/5`. Read `TODO.md:449-457`
before the deploy that carries the new pin.

Could ship before Phase 2. Cannot ship before Phase 1, because there is
nothing to write into the line.

### Phase 4 - adjournment (Q157-169). Days, not hours. Separate scope.

Rides the funnel rather than growing its own. `docs/sweep-2026-08-26.md:2335-2348`
has the three touch points already worked out, including the one warning
worth repeating: express "counts as a draw for pairing purposes" in the
single scoring function 0.17.1 consolidated on, not in a second mapping.

### Phase 5 - read a `###` line back on import. ~half a day.

Ainalrami's parser keeps comment lines; `TrfImport`'s existing
`verification_warnings/2` channel reports them. Genuinely optional, and the
cheapest of the lot once Phase 3 exists.

---

## 7. Open questions for the maintainer

**7.1 Is FIDE Mode per tournament or per installation?**
Section 3.1 recommends per tournament and argues it from the consequences
of "no re-entry" on a hosted box. If you read the requirement the other
way, most of section 3 still stands but the fields move and the default
becomes configuration.

**7.2 Does anything besides an explicit act cause an exit?**
Section 1.3.B. This decides whether Phase 2's enforcement sites call
`leave/3` or merely warn. Getting it wrong in the permissive direction
under-reports; getting it wrong in the strict direction permanently marks
tournaments as non-conforming in files sent to FIDE. **The strict direction
is not correctable, so the default answer should be "no" until TEC says
otherwise.**

**7.3 What happens to the ~existing tournaments at migration time?**
Backfilling `fide_mode_left_round: nil` says every historical tournament
was handled in FIDE mode, which is unprovable. Backfilling `0` says none of
them were, which is unfair and would put a `###` line in every re-export of
a past event. There is no third answer the data supports. Recommendation:
`nil`, on the grounds that the mode is a statement about how the software
behaves going forward rather than a verdict on rounds already paired - but
this is your call and it should be written into the migration's own
comment.

**7.4 Should `fide_homologated` stay, exactly as it is?**
This document says yes: homologation is "will this be rated", the mode is
"was this handled to the letter", and they are independent. But two
FIDE-ish tickboxes on one settings page will confuse arbiters, and the
copy on that page has to do real work to keep them apart.

**7.5 Does "Duplicate" inherit a mode exit?**
It copies rounds and results, so the exit is a true fact about the copied
history and inheriting it is defensible. But a duplicate is often the start
of a *new* event, where inheriting a permanent, unclearable mark would be
unwelcome and unfixable. Section 3.3c currently inherits it because that
falls out of the import path.

**7.6 Does the mode reach OpenResults?**
The snapshot is additive-only so it is safe to add. The question is whether
the public results page for a club tournament should say the software left
FIDE Mode in round 4 - which is meaningful to an arbiter and meaningless,
or worse, to a parent looking up their child's game.

**7.7 Do printed documents carry it?**
`print_controller.ex`'s `tournament_info_html/1` (`:1560-1590`) is shared
by every printed document. A pairing sheet is posted on a wall.

**7.8 Are the "Levels 1-5" a severity scale on warnings, or states the
tournament occupies?**
Section 3.5 assumes the former - a warning carries a level, the tournament
is only ever in or out of the mode. If they are states, the design changes
shape substantially, and the `###` line would presumably have to record the
level too.

**7.9 Do you want the sweep's contradiction recorded?**
`docs/sweep-2026-08-26.md:2358` and `:2366` recommend routing the exit
through `locked_fields/1` + `ensure_unlocked/3`. Section 5, item 13 argues that is
wrong because that mechanism exists to be overridden. Whoever builds this
will read the sweep, so the disagreement should be written down somewhere
rather than silently resolved in code.
