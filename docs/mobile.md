# Mobile / responsive layout

OpenPairings' own CSS (`assets/css/app.css`) is hand-written, not Tailwind
components - the responsive rules follow the same approach: plain CSS added
in `@media` blocks at the **end** of the file, after the desktop design
system. Nothing above those blocks was touched, so desktop rendering (which
is deliberately full-width - an arbiter wants the players/pairings grid to
use the whole monitor) is unchanged.

## Breakpoints

- `@media (max-width: 768px)` - the main mobile/tablet breakpoint. Covers
  phones in both orientations and tablets in portrait.
- `@media (max-width: 480px)` - a few refinements for narrow phones (360-430px)
  nested inside the 768px behaviour: modals go closer to full-width, the
  top bar drops the user's e-mail to make room, card padding shrinks a
  little.

Both are strictly additive (`max-width`), so nothing here ever fires on a
desktop-width viewport.

## What each rule does

**Top bar (`.topbar`)** - `flex-wrap: wrap` lets it break into two rows: the
brand and the auth links (`order: 1` / `order: 2`, `margin-left: auto` on
`.topbar-auth`) share the first row, and the tab strip
(`.topbar > nav:not(.topbar-auth)`) is pushed onto its own full-width row
(`order: 3; flex-basis: 100%`) with `overflow-x: auto` and
`-webkit-overflow-scrolling: touch` - the tabs (Tournaments, Players,
Pairings, Standings, Print, Norms, Settings, FIDE) become a horizontally
swipeable strip instead of clipping or wrapping into a wall of buttons.
`.topbar nav a { min-height: 44px }` keeps tap targets comfortable. At
480px the user's e-mail address is hidden to leave room for the Settings /
Log out links next to the brand.

**Wide tables** - the players grid, pairings, standings, tournaments list,
player cards, print index and norms tables already live inside a
`.table-card` or `.card-table-wrap` wrapper `<div>`. The mobile rule just
flips `.table-card`'s desktop `overflow: hidden` (there for rounded-corner
clipping) to `overflow-x: auto` so the *wrapper* scrolls horizontally while
the surrounding page never does. `html, body { overflow-x: hidden }` is a
belt-and-suspenders safety net in case something else overflows.
`.card-table-wrap` already had `overflow-x: auto` on desktop (used for the
player card and IT4 candidate tables), so it needed no change - the
Settings → Share/Team collaborators table was the one loose `<table>` with
no scrolling wrapper, so `lib/pairings_engine_web/live/settings_live.ex`
was given one (reusing the existing `.card-table-wrap` class, no new CSS).

**Players page `.split` layout** - the grid + right-hand Display column
switches from `flex-direction: row` to `column` with `align-items: stretch`
so both the table card and the Display panel become full width instead of
sitting side by side; `.display-panel`'s fixed `width: 170px` is overridden
to `100%`.

**Page headers / action rows** - `.page-header` and `.actions` both get
`flex-wrap: wrap` so title/status blocks and button rows (print, export,
live view, "Pair round…", etc.) wrap onto additional lines instead of
overflowing. The TRF "Export rounds…" form on the Pairings page has a
hard-coded `style="width: 150px"` input; `#trf-rounds-export-form
input[name="rounds"] { width: 100% !important }` overrides it (the
`!important` is needed only because it's fighting an inline style, and it's
scoped to the mobile media query so desktop is untouched).

**Modals** (`player_edit_modal`, `player_card_modal`, `norm_edit_modal`,
`delete_tournament_modal`) - these already render at `width: 100%` of the
padded overlay on desktop, so they were already close to responsive; the
media query just shrinks the overlay/card padding, and at 480px pins
`width: 95vw; max-height: 90vh` explicitly so they read as "near-full-width
sheet" rather than a shrunk desktop dialog.

**Round picker** - already used `flex-wrap: wrap` in the base (desktop)
CSS, so the round-number buttons already wrap on narrow screens; nothing
to add.

**Forms** - `.form-grid` already uses
`grid-template-columns: repeat(auto-fill, minmax(220px, 1fr))`, which
collapses to a single column automatically once the container is narrower
than ~460px (two 220px columns + gap) - no override was needed. Checkbox
and radio rows already used `flex-wrap: wrap` on desktop.

**Viewport meta tag** - already present in
`lib/pairings_engine_web/components/layouts/root.html.heex`:
`<meta name="viewport" content="width=device-width, initial-scale=1" />`
(Phoenix's default). Verified, no change needed.

## The rule for future components

1. **Never introduce a `max-width` container for desktop.** Grids and
   tables should keep using the full monitor width on desktop; all
   narrowing/stacking behaviour belongs inside a `@media (max-width: ...)`
   block.
2. **Wrap wide tables**, don't let the page scroll. Any new `<table
   class="pe-table">` should sit inside something with `overflow-x: auto`
   on mobile - reuse `.table-card` (if the table already sits directly in a
   card) or `.card-table-wrap` (a plain wrapper `<div>`) rather than
   inventing a new class. The page/body should never need to scroll
   sideways to see a table; the table's own wrapper should.
3. **Avoid fixed pixel widths** (`style="width: 150px"`, `width: 170px` on
   a flex sidebar, etc.) on anything that also needs to work at ~360-430px.
   If a fixed width is unavoidable on desktop (e.g. to line up a narrow
   input next to a button), add a mobile override in the media query at
   the end of `app.css`.
4. **Put mobile rules in the media-query block at the end of
   `assets/css/app.css`**, not scattered inline or mixed into the desktop
   rules above. Keep them additive so desktop CSS is never touched.
5. Prefer CSS-only fixes. Only touch a `.heex` template when there's no
   existing element to attach a wrapper/behaviour to (as with the
   collaborators table above) - and even then, reuse an existing CSS class
   rather than adding a new one where possible.
