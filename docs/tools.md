# Arbiter tools (no login required)

`/tools/norms` is a public page for an arbiter who doesn't have (and doesn't
want) an OpenPairings account: drop one or more `.swar`/`.trf` files and
download the IT3/FA1/IA1 FIDE report forms straight from them. `/tools`
redirects to it — it's the only tool there is right now.

Unlike everything else in this app, nothing on this page ever creates a
`Tournament` row or touches `PairingsEngine.Repo` at all. See "Ephemeral by
design" below.

## What it does

1. Upload up to 10 files (5 MB each) — `.swar` or `.trf`. Neither format has
   a reliable browser MIME type, so the upload accepts anything and
   `PairingsEngine.Tools.Parser` dispatches on the filename's extension
   instead (`.swar` → `PairingsEngine.SwarImport.build_structs/1`, `.trf` →
   `PairingsEngine.TrfImport.build_structs/1`, anything else tries SWAR then
   TRF). Both builders are pure — no database access, same as the
   authenticated app's own SWAR/TRF import flows can already use for
   FIDE-report-only purposes.
2. Each file that parses lists as a row: tournament name, player count,
   round count, with a "Remove" button. A file that fails to parse (wrong
   format, corrupt, empty) lists too, with a friendly per-file error instead
   — one bad file never blocks the others.
3. With two or more parsed files, a "Master" radio picker appears, and the
   files combine into one **Festival** report via
   `PairingsEngine.Norms.Combine.combine/2` — same multi-category-event
   combining the authenticated Norms page would use for a real multi-group
   tournament, just fed from uploaded files instead of `Tournament` rows
   already in the database. See docs/norms.md for the combining rules
   (master supplies header/schedule fields, players are pooled, the same
   player can't appear in more than one file).
4. Fields for what a SWAR/TRF file typically doesn't carry — chief arbiter
   (name + FIDE ID, e-mail), organizer (name, e-mail), FIDE event code, 2
   ranked deputy arbiters, and — via "+ Add arbiter" — as many further
   arbiters as the event actually has (FIDE only ranks 2 deputies by name;
   see docs/norms.md's "Arbiters beyond chief + 2 deputies"), plus the
   FA1/IA1 arbiter norm candidate's name/FIDE ID/federation. These are
   merged onto the (virtual, unpersisted) combined tournament by
   `PairingsEngine.Tools.Overlay.apply/2` at download time — the same
   `officials` map shape the Settings page's "Officials & FIDE report data"
   card writes onto a real tournament (docs/norms.md), just never saved
   anywhere here. A blank field never overwrites a value the file already
   supplied (e.g. a TRF's own chief-arbiter line).
5. Download IT3 / FA1 / IA1 — generated the same way
   `PairingsEngineWeb.NormsController` generates them for a real tournament
   (`PairingsEngine.Norms.Forms.it3_result/3` for IT3 — expanding the
   template first if there are arbiters beyond chief + the 2 ranked
   deputies — plain `Forms` + `XlsxFill.fill/2` for FA1/IA1), just fed the in-memory
   combined tournament/players instead of ones loaded from `Repo`. IT3's
   "Program used" (`B22`) reads "Swar (With JaVaFo)" by default here, not
   "OpenPairings" — this page only ever generates a report from an
   already-paired upload, so crediting OpenPairings would be false.

IT4 isn't offered here — it's keyed off `Player.norm_data` (the per-player
title-norm judgment set on the authenticated Norms page's player table),
which doesn't exist for a player these tools only just parsed out of a file.

## Officials: FIDE lookup and the norm-candidate picker

The officials fields use the exact same combobox as the signed-in Norms page
(`PairingsEngineWeb.Components.ArbiterCombo`, shared verbatim — see
[`norms.md`](norms.md)), so an arbiter working from this page doesn't have to
hand-type FIDE IDs (which is where the wrong person ends up on a report):

- Each official has a name box and a FIDE-ID box side by side. Typing in
  **either** one, debounced, searches and opens a dropdown attached to that
  box — no separate lookup button on either page anymore. Result rows show
  federation, birth year, rating and FIDE ID — federation alone can't
  separate namesakes, and BEL really does have two `Van Dyck, Marc`. Picking
  a row fills **both** the name and the ID; the ID box itself is a pure
  search field, never the thing a download reads.
- **"Pick an arbiter"** above the FA1/IA1 candidate fields fills all four from
  whichever official you choose. When that official has a FIDE ID, the record
  drives the first/last split, so a multi-word surname ("De Vet, Sylvin") stays
  intact where a positional guess would say "Vet".

There is no behavioral difference from the signed-in page anymore — both
pages debounce every keystroke 300ms before searching, which is what keeps a
per-keystroke query against ~1.9M FIDE rows from being an easy thing to point
a script at.

Downloads are blocked (red bar, naming the official) while any *named* arbiter
has no FIDE ID — same rule as the signed-in page, for the same reason: FIDE
identifies officials by id and bounces a report missing one. Leaving an
official blank is fine; half-filling one is not.

The chief arbiter's and organizer's e-mail addresses are blocked the same
way if left empty — the IT3 template's own printed privacy notice states
FIDE requires both, so a download missing them would be rejected anyway.

Both need the local FIDE database to be populated (see
[`rating-refresh.md`](rating-refresh.md)); with an empty table a search
simply returns no results, and every field stays hand-editable (though still
gated on a FIDE ID, which then has to come from a populated table eventually).

## Ephemeral by design

Every piece of state this page collects — parsed tournaments/players, the
officials overlay, the arbiter-norm candidate, which file is the master —
lives only in `PairingsEngine.Tools.Session`: a `GenServer`-owned, `:public`
ETS table, supervised alongside the rest of the app in
`PairingsEngine.Application`. Nothing is ever written to
`PairingsEngine.Repo` or to disk (uploaded file bytes are read via
`consume_uploaded_entries/3` straight into memory and discarded once
parsed — only the resulting structs are kept).

`PairingsEngineWeb.ToolsNormsLive` (the upload page) and
`PairingsEngineWeb.ToolsController` (`GET /tools/download/:token/:form`,
the plain download route — a different process, hence the shared store)
communicate purely through a random token generated when the page mounts,
embedded in each download link. Every session entry is stamped with a
sliding one-hour expiry — updating it (adding a file, editing a field)
pushes the expiry another hour out — enforced two ways: lazily on every
lookup (an expired entry reads back as "not found" the moment anything asks
for it) and by a periodic sweep every 5 minutes that clears anything already
past expiry, so an abandoned session doesn't linger in memory just because
nobody ever asked for it again.

An unknown or expired token, a download with no successfully-parsed files,
or a `Combine` duplicate-player conflict all render a small friendly HTML
page (`ToolsController`'s `error_page/2`) instead of a 500 or a crash —
hostile or merely stale input to the download route is always handled.

## Where to find it

- The topbar's "Tools" link (next to "Rating lists", only shown outside a
  tournament's own tabs).
- A line on the login page: "Just need a norm report? Try the free arbiter
  tools — no account needed."
- The page's own footer links back to `/` (the full, account-based
  OpenPairings app) for anyone who lands here first.
