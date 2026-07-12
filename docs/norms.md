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
   `deputyN_fide_id` / `deputyN_email` for `N` in `1..4`, `pairing_mode`
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
