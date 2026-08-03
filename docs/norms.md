# Norms & FIDE reports

OpenPairings can generate four official FIDE report/norm forms straight from
a tournament's data, as real `.xlsx` downloads that keep the original
template's formatting, formulas, merges and validation intact:

| Form | What it's for | Scope |
|---|---|---|
| **IT3** | Tournament Report Form | Whole tournament — always available |
| **FA1** | FIDE Arbiter norm report | One arbiter norm candidate, chosen per download |
| **IA1** | International Arbiter norm report | Same shape as FA1 |
| **IT4** | Title/Norm report (crosstable) | Up to 40 player title-norm candidates |

The read-only template files live in `priv/norm_templates/` (Belgian-
federation copies of the official FIDE forms). Everything else lives in:

- `PairingsEngine.Norms.XlsxFill` — generic in-place `.xlsx` cell filler
  (knows nothing about any specific form).
- `PairingsEngine.Norms.Forms` — the four form-specific mappers, pure
  functions from tournament/player/standings data to `XlsxFill` fill maps.
- `PairingsEngineWeb.NormsController` — `GET` routes that generate and
  stream the filled workbook as a download.
- `PairingsEngineWeb.NormsLive` (`/t/:id/norms`) — the "Norms" tab: download
  links/buttons, the FA1/IA1 candidate form, and the per-player title-norm
  editor that feeds IT4.

## Where the data comes from

Most of what these forms need is already on the tournament/player records
(name, dates, venue, rounds, federation, ratings, titles). Three additional
places hold FIDE-report-specific data:

1. **`Tournament.event_code`** and **`Tournament.fide_tournament_id`** —
   plain string columns. `event_code` is FIDE's "Code of event" (FA1/IA1 B6,
   IT4 S4); `fide_tournament_id` is IT3's own numeric "ID of Tournament"
   (IT3 B2). They're often the same value in practice but the templates
   label them differently, so they're kept as separate fields.

2. **`Tournament.officials`** — a `:map` column (JSON under the hood, via
   ecto_sqlite3, the same mechanism already used for the `tiebreaks` and
   `round_dates` array columns) holding officials/pairing-system/FIDE-report
   metadata that didn't warrant a flat column each. Recognised string keys
   (all optional): `organizer_id`, `organizer_email`,
   `chief_arbiter_fide_id`, `chief_arbiter_email`, `deputyN_name` /
   `deputyN_fide_id` / `deputyN_email` for `N` in `1..2` (FIDE only ever
   ranks 2 deputies by name — see "Arbiters beyond chief + 2 deputies"
   below), `extra_arbiters_count` plus `arbiterN_name` / `arbiterN_fide_id`
   for `N` in `1..extra_arbiters_count`, `pairing_mode`
   (`"computerized"` or `"manual"`), `pairing_program`, `swiss_variant`
   (`"Dutch"` / `"Lim"` / `"Dubov"` / `"Burstein"`),
   `person_responsible_pairings`, `remark1`..`remark4`, `it4_event_type`,
   `pairings_web_link`. Edited on the **Settings** page, under "Officials &
   FIDE report data" — the organizer's/chief arbiter's *names* stay on the
   existing General card fields (`tournament.organizer`,
   `tournament.chief_arbiter`); the map only holds the extra IDs/emails/etc.
   that didn't already exist.

3. **`Player.norm_data`** — a `:map` column, per player, for IT4 title-norm
   judgment: `title_claimed`, `norm_description`, `medal_percent`,
   `event_group`, `fed_participating`, `fed_members`, `remarks`. A player is
   only included on an IT4 download once `title_claimed` is non-blank;
   editing this is the "Edit norm data" button on the Norms page's player
   table.

The FA1/IA1 **arbiter** norm candidate (last name, first name, FIDE ID,
federation) is deliberately *not* persisted anywhere — an arbiter earning a
norm needn't be a registered tournament player, and it's a one-off value
needed only at download time. The Norms page collects it with a plain `GET`
form submitted straight to the controller (no LiveView round-trip, nothing
saved).

A **"Pick an arbiter"** select above that form prefills all four fields from
the event's own officials, since the candidate is nearly always one of them and
retyping a FIDE ID is a chance to put the right id on the wrong person. When
the official has an id, the split comes from the *FIDE* record — "De Vet,
Sylvin" keeps its surname intact, where a positional guess at SWAR's "Sylvin De
Vet" would have said "Vet". The fields stay editable afterwards and the edited
values are what get submitted: they're bound to an assign updated on every
keystroke, so a re-render (a PubSub tournament change, a second pick) can't
silently revert typing that the form would then submit.

## Name style on the generated forms

FIDE's house style on these forms is the given name in normal case and the
surname in capitals — **"Jorian BURSSENS"**. `Norms.Forms.fide_display_name/1`
does the conversion, splitting on the comma in our stored "Last, First" rather
than by word position, so multi-word surnames survive ("De Vet, Sylvin" →
"Sylvin DE VET"). A name with no comma is left alone rather than guessed at.

Applied everywhere a person's name is written to a form:

| Form | Cells |
|---|---|
| IT3 | `B60` chief arbiter, `B63`/`B65`/`B67`/`B69` deputies |
| FA1/IA1 | `B1` candidate surname (capitalised on its own, since first/last are separate cells) |
| IT4 | `C` player name column |

IT4 is the only form that lists players by name; IT3 carries counts only.

The conversion needs the stored "Last, First" form to know which part is the
surname, which the FIDE lookup always produces. A name typed by hand with no
comma is left exactly as entered rather than guessed at — another reason the
officials flow pushes every arbiter through the FIDE combobox rather than a
free-text name field.

**CM and WCM are not counted as titles** in the FA1/IA1 titled-player count
(B16): they're federation-awarded, not FIDE titles under the title
regulations that count refers to, and including them made the report disagree
with FIDE's own view of the same event.

The Belgian authenticating official pre-printed in the FA1/IA1 templates reads
`IA CORNET, Luc (205494)` — it lives as a shared string inside the `.xlsx`
files, not in code, so changing it means editing `xl/sharedStrings.xml` in
`priv/norm_templates/` (it read `IA/IO CORNET, ...` until 2026-08-02, when he
stopped holding the IO title).

## Dates are always dd/mm/yyyy, never the system locale's short date

Every date-bearing cell across IT3/FA1/IA1/IT4 (`B6`/`B7` on IT3, `B8`/`B9`/
`B22`/`B26` on FA1/IA1, `V6`/`Z6` on IT4) carries an explicit custom
`dd/mm/yyyy` number format (`numFmtId="164"` in each template's
`xl/styles.xml`), not Excel's built-in `numFmtId="14"`. The built-in id
renders using **the opening machine's own regional short-date setting** —
on an en-US-locale Windows box that's `m/d/yyyy`, silently swapping day and
month for any date where both are ≤ 12. IT3's `B6` (Starting date) had it
worse: the template never gave that cell a style at all, so a written date
serial rendered as a bare integer, not a date. Both are template-authoring
issues, invisible in the code (`Norms.Forms.parse_date/1` always produces a
correct `%Date{}`) and only fixable by editing each template's own
`xl/styles.xml`/`xl/worksheets/sheetN.xml` — see the fix for the exact
zip-editing approach (clone the cell's existing style with the numFmtId
swapped, so borders/fills survive; insert a fresh styled cell for one that
didn't exist yet).

## Reports are gated on complete officials

FIDE identifies every official by FIDE ID and bounces a report that's missing
one, so a download that would be rejected is worse than no download.
`NormsLive.report_blockers/1` blocks IT3/FA1/IA1 behind a red bar naming each
missing field until:

- the chief arbiter has a name **and** a FIDE ID, and
- every deputy (and every extra arbiter — see below) that has been *named*
  also has a FIDE ID, and
- the chief arbiter's and organizer's e-mail addresses are both filled in.

An empty deputy slot is fine — not every event has two. The half-filled state
(name, no id) is specifically what the SWAR import leaves behind whenever a
name is ambiguous, so this is the check that stops that reaching FIDE.

The two e-mail addresses are mandatory (not just recommended) because the
IT3 template itself prints a PRIVACY NOTICE stating FIDE requires both to
process the report — a downloaded file missing them would be sent back
anyway, so the same "don't produce a download FIDE will reject" logic that
gates the FIDE IDs above applies to these fields too.

## Arbiters beyond chief + 2 deputies

FIDE's own printed `Certificaat` sheet only ranks 2 deputies by name
("1st/2nd Deputy Chief Arbiter") — every arbiter after that prints as a
plain, unranked "Arbiter" row, no matter how many there are. Both UIs (this
page and the public Tools page) only offer 2 ranked "deputy" boxes for
exactly that reason.

An earlier version of this feature offered 4 "deputy" boxes, because the
raw `Invulformulier` data sheet happens to ship 4 numbered ID/Name
row-pairs (`B59`-`B69`: chief + 1st-4th deputy) — but FIDE itself never
distinguishes past the 2nd, so "deputy 3/4" just meant those two printed as
an unlabelled "Arbiter" row on `Certificaat`, no different from — and
confusingly separate from — a 5th arbiter added via "+ Add arbiter". One
real arbiter tried it and got confused when their "deputy 3/4" didn't look
like a ranked deputy on the output. Everything past chief + 2 ranked
deputies now goes through one mechanism:

Both pages have a "+ Add arbiter" button (and a matching "Remove last
arbiter" once at least one exists) below the 2 deputy slots, using the
exact same FIDE-lookup combobox as everything else. Each one is tracked as
a flat `officials["arbiterN_name"]` / `officials["arbiterN_fide_id"]` pair
(1-indexed, independent of the deputy numbering) plus a plain
`officials["extra_arbiters_count"]` integer — deliberately *not* a nested
list, so it round-trips through an ordinary HTML form submit exactly like
`deputy1_name` etc. already do, with no array-param parsing to get wrong.

Arbiters 1 and 2 land on the template's own spare rows for free — the same
`B66`-`B69` cells "deputy 3/4" used to write to, just renamed and no longer
presented as ranked. Arbiter 3 onward needs real surgery, since the
template has no more spare rows:
`PairingsEngine.Norms.ItThreeExpand` grows both sheets on demand — two new
rows in `Invulformulier` (an ID cell, a Name cell) right after row 69, and
two new rows in `Certificaat` (a label row reading "Arbiter", a formula row
mirroring the "arbiter 2" row exactly) right after row 38 — per extra
arbiter, renumbering every row/cell/formula reference that came after the
insertion point. `Forms.it3_result/3` is the one entry point that does this
(expand-then-fill) when needed; going through `Forms.it3_fills/3` +
`XlsxFill.fill/2` directly (the old pattern) silently drops any arbiter
3rd-and-beyond, since the template has no cells for them until expanded.
`extra_arbiters_count <= 2` — the common case — is a hard no-op:
`ItThreeExpand.expand/2` returns the template completely untouched, so no
tournament with 2 or fewer extra arbiters is affected by any of this.

## Explaining the rated/titled/federation counts

IT3's `B27`-`B58` block (rated/GM/IM/FM/unrated/WGM/WIM/WFM, each as
total/feds/host) is the one part of the report an arbiter can't sanity-check
by eye against the player list — "why does this say 14 rated players" was a
real support question. `PairingsEngine.Norms.CountsBreakdown.breakdown/2`
groups players exactly the way `Forms.it3_fills/3` counts them (same
`rated?/1`, same title membership, same CM/WCM exclusion via
`Forms.titled?/1`) but keeps the actual player list per category instead of
collapsing straight to a count.

`PairingsEngineWeb.Components.It3CountsExplain`'s `<.it3_counts_explain>`
renders that as a collapsed-by-default `<details>` panel (plain HTML, no
LiveView round-trip needed — the player list is already on the page), one
card per category with the same `.pe-stat`/`.pe-tag`/`.pe-ladder` visual
language the pairing-rationale screens use. Present on both the signed-in
Norms page (`@players`, real `Tournament.federation`) and the public Tools
page (the actual `Combine.combine/2`-pooled player list and the *combined*
tournament's federation — not a naive flat-map across uploaded files, so it
can never disagree with what a download would actually contain).

**Saving is refused too, not just downloading.** Every arbiter FIDE reports on
is registered with FIDE and therefore has an id — an official without one
doesn't exist — so `save_officials` rejects a named official with no id and
says which one is missing. Two things back this up structurally: the FIDE-ID
inputs are `hidden` and only written by picking a search result, so an id can
never be typed (or mistyped) by hand, and the same block applies on the public
`/tools/norms` page.

To resolve one, use the arbiter combobox in the Officials card: each official
has a name box and a FIDE-ID box side by side, and typing in **either** one
(debounced) searches and opens a dropdown attached to that box — retyping the
name already stored re-triggers the same search, no separate lookup step
needed. Result rows show federation, birth year, rating and FIDE ID, because
federation alone doesn't separate namesakes: BEL has two `Van Dyck, Marc`, and
a list showing both as "Van Dyck, Marc · BEL" is unpickable. Picking a result
fills both boxes; the ID box itself is a pure search field; a FIDE ID only
ever gets saved by picking a result, never by typing digits into that box.

The same combobox (`PairingsEngineWeb.Components.ArbiterCombo`, driven by
`PairingsEngineWeb.Live.ArbiterCombo`) is shared verbatim with the public
`/tools/norms` page — see [`tools.md`](tools.md) — so the two pages behave
identically for this field.

Note the Officials card has **no organizer name field** — that lives on the
General card (`tournament.organizer`), and SWAR supplies it. SWAR has no
organizer *FIDE ID* and no e-mail addresses at all, so those always start empty
(see [`swar-import.md`](swar-import.md)).

## How the in-place fill works, and why

`XlsxFill.fill/2` edits the workbook's XML members directly inside the
`.xlsx` zip archive (`:zip` + regex-based row/cell surgery — no new
dependency), instead of parsing the workbook into a generic in-memory model
and re-serializing it. That means every bit of the original file — cell
styles/number formats, the `Certificaat` sheets' formulas, merged ranges,
FA1's `B11` dropdown validation, IT4's sheet/workbook protection — survives
byte-for-byte untouched except for the specific cells being written. A
generic "read workbook, mutate cells, write workbook" library would have to
faithfully reproduce all of that on the way back out; round-tripping the
XML instead sidesteps the whole problem.

Each of the four templates uses the pattern *"fill a plain data-entry sheet,
a separate formula-only sheet renders it"*:

- IT3/FA1/IA1: fill only `Invulformulier`; `Certificaat` is 100% formulas
  reading from it and is never written to directly.
- IT4: single sheet (`"IT 4"`, note the space in the name) filled directly,
  except columns `Z` and `AF` (verdict formulas) which must never be
  written.

`XlsxFill.fill/2` refuses (`{:error, {:formula_cell, ref}}`) any fill that
targets a cell already holding a `<f>` formula, so a mapper bug that tries
to write a formula cell fails loudly instead of corrupting the workbook.

It also sets `fullCalcOnLoad="1"` on the workbook *and* strips the cached
`<v>` value out of every formula cell on every sheet (including
`Certificaat`, which is never a fill target itself). Both are needed: the
shipped template files bake in a stale cached value for their formula cells
from whenever they were last saved unfilled in Excel — e.g. `Certificaat`'s
label cells cache as an empty string, its rated/titled-count cells cache as
`0`. `fullCalcOnLoad` is only a *request* to recalculate; not every reader
honors it (Protected View, some headless converters/preview panes). Without
the cache also stripped, a reader that doesn't recalculate shows the
`Certificaat` sheet as blank/zeroed even though `Invulformulier` was filled
correctly — this was the root cause of a real bug report ("IT3 generation
is broken... page 2 filled some stuff, page 1 [Certificaat] looked empty").
Removing the cached `<v>` (and the now-meaningless cached-type `t="str"`
attribute alongside it) leaves the `<f>` element intact but gives the
reader nothing to fall back on, forcing recomputation on open regardless of
whether it honors `fullCalcOnLoad`. If a downloaded IT3/FA1/IA1/IT4 still
shows a blank/stale `Certificaat` in Excel specifically, it's almost always
because the file opened in **Protected View** (downloaded-from-the-internet
flag) — click "Enable Editing" and it recalculates immediately.

## Combined reports (festivals)

A Belgian-federation arbiter often runs several category groups (Open,
Youth, Women, ...) as one festival, but OpenPairings itself only ever
manages each group as its own separate `Tournament` — different rounds,
different players, sometimes different dates. The Norms page's "Combined
report (festival)" card generates one IT3/FA1/IA1 covering the whole
festival without merging the underlying tournaments in the database.

- **`PairingsEngine.Norms.Combine`** — the pure merge: given
  `[{tournament, players}, ...]` plus a 0-based `master_index`, it returns
  one virtual, unpersisted `{tournament, players}` pair. Every header/
  schedule field (name, dates, `round_dates`, `rounds_count`, rate of play,
  venue, officials, ...) comes from the designated **master** tournament
  verbatim, except `name`, which becomes `"<master name> Festival"` (FIDE's
  own term for a multi-category event). Players are simply concatenated —
  `PairingsEngine.Norms.Forms` already derives every rated/titled/
  federation count purely from the player list it's handed, so nothing
  else needs recomputing. The same player entered in two of the selected
  tournaments is rejected as `{:error, {:duplicate_players, names}}`
  (identity: `fide_id`, else `national_id`, else name + birth year) — see
  its moduledoc for the full identity rule.

- **`PairingsEngineWeb.NormsLive`** — the "Combined report (festival)" card
  (below the single-tournament FA1/IA1 card) lists every *other* tournament
  the current user can access (same owner-or-accepted-collaborator scoping
  as the tournament list, via `Tournaments.list_tournaments/1`) as
  checkboxes. The current tournament is always implicitly part of the
  combined set and can't be unchecked. Once at least one other tournament
  is picked, a master picker (defaulting to the current tournament)
  appears alongside combined IT3/FA1/IA1 download controls. Nothing here
  touches the database — the picker only builds query-string links/hidden
  form fields for `PairingsEngineWeb.NormsController`.

- **`PairingsEngineWeb.NormsController`** — `it3/2`, `fa1/2` and `ia1/2`
  accept two optional query params:

  - `combine` — a comma-separated list of tournament ids to merge, in
    order (e.g. `?combine=12,7,9`).
  - `master` — which of those ids supplies the header/schedule fields;
    resolved to an index into `combine`'s order for `Combine.combine/2`.

  Every id in `combine` is authorized individually through
  `Tournaments.get_authorized_tournament!/2`, exactly like the route's own
  `:id` — a forged id anywhere in `combine` 404s the same way the single-
  tournament path always has. When `combine` is absent or blank, behavior
  is byte-for-byte unchanged from before this feature existed. A
  `{:duplicate_players, _}` error redirects back to the Norms tab
  (`/t/:id/norms`) with `Combine.error_message/1` as an `:error` flash,
  instead of a 500. The download filename is derived from the virtual
  tournament's `"... Festival"` name, through the same
  `Forms.download_filename/2` slugification as any other download — no
  separate code path needed there.

  FA1/IA1's arbiter-candidate params (`candidate[last_name]` etc.) work
  identically in combined mode — they're independent of which/how many
  tournaments are being merged.

## Adding or adjusting a form mapping

If FIDE revises a template (new cell layout, new fields), the change is
localized to `PairingsEngine.Norms.Forms`:

1. Open the new template and find the fill-target cells (see the comments
   at the top of each `*_fills` function in `forms.ex` for the cell-by-cell
   reference this app currently relies on — cross-check against the new
   file before touching code).
2. Update the `fills` map literal in the relevant `*_fills/N` function.
   Every value is either a `String.t()`, a number, a `Date.t()`, or `nil`
   (skip that cell) — see the `@type value` in `XlsxFill`.
3. **Never** add a fill for a cell that holds a formula in the new
   template — `XlsxFill.fill/2` will return `{:error, {:formula_cell, ref}}`
   at runtime if you do, and the corresponding unit test
   (`test/pairings_engine/norms/forms_test.exs`, "never targets…" cases)
   should be extended to cover the new cell.
4. If a genuinely new piece of data is needed that isn't derivable from
   existing tournament/player/standings data, add it to
   `Tournament.officials` or `Player.norm_data` (both free-form maps —
   no migration needed for a new key) rather than a new column, unless it's
   something the rest of the app also wants to query/validate on, in which
   case a real column + migration is more appropriate.
5. Add/update a case in `forms_test.exs` asserting the new cell's value,
   and confirm `XlsxFill.fill(Forms.template_path(:kind), fills)` still
   returns `{:ok, _}` against the real template file (the "produced fills
   apply cleanly to the real template" tests do this already for a full
   fills map — extend rather than duplicate).
