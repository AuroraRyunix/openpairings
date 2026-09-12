# Browser-side code review, 2026-09-12

First-ever review of everything that runs in a browser on this app: the
module script (`assets/js/app.js`), the nine LiveView hooks (three plain
hooks registered there, six colocated `Phoenix.LiveView.ColocatedHook`
blocks inlined in their LiveViews), the inline theme-bootstrap script in
`root.html.heex`, and the one hand-built print page
(`print_controller.ex`). The September whole-codebase audit
(`docs/audit-2026-09-05.md`) explicitly recorded this ground as never
looked at; everything below is a first pass, not a re-check of prior
findings.

**Result: this code is in unusually good shape.** It is heavily
self-documented with the *reasoning* behind each defensive check, and
almost every failure mode this review was asked to hunt for turns out to
already be handled - deliberately, per the comments. One real bug was
found and fixed. No injection paths were found. No leaks were found: every
hook that adds a `window`/`document` listener or a timer removes it in
`destroyed()`.

## Findings, worst first

### 1. [Fixed] `ColumnPrefs` hook's `localStorage` access was the one place in the app not guarded against a throw

**File:** `assets/js/app.js`, lines 28-39 (before fix). **Used by:**
`players_live.ex:1787` (Players grid, "Display" panel) and
`standings_live.ex:754` (Standings page).

Every *other* `localStorage` touch in this codebase - the theme bootstrap
in `root.html.heex` (lines 22-32) and the `versionStore` in `app.js`
(lines 654-660) - wraps `getItem`/`setItem` in `try/catch`, with a comment
explaining why: those calls **throw**, rather than returning `null`, when
a browser blocks or partitions storage (a private window in older Safari,
a cross-origin iframe, "block all cookies" settings). `ColumnPrefs` was
the sole exception:

```js
const ColumnPrefs = {
  mounted() {
    const stored = localStorage.getItem("pairingsengine.playerColumns")   // <- throws, unguarded
    if (stored) {
      try { this.pushEvent("columns_loaded", {columns: JSON.parse(stored)}) } catch {}
    }
    this.handleEvent("store_columns", ({columns}) => {
      localStorage.setItem("pairingsengine.playerColumns", JSON.stringify(columns))  // <- throws, unguarded
    })
  },
}
```

**What breaks:** in a storage-blocked context, `mounted()` throws before
`handleEvent` is even registered - the arbiter's saved column selection
never loads, `store_columns` never gets wired up, and (since a throwing
lifecycle callback is not something this hook's own code controls) the
hook fails in a way this app has already gone out of its way to design
against everywhere else it touches `localStorage`.

**Fix applied:** wrapped both calls in `try/catch`, matching the existing
pattern exactly. No behaviour change for the ordinary case (storage
available); in the blocked case, columns now silently fall back to
defaults instead of the hook potentially failing. Covered failure modes:
**state assumptions** (this is exactly the "check the rest" the task
description flagged), **re-render survival** (unaffected - fix is inside
the existing `mounted()`, no change to lifecycle wiring). CHANGELOG entry
added under `[Unreleased]`.

### 2. [Recommendation, not fixed] `PlayerGrid`'s cell-menu popup isn't clamped to the viewport

**File:** `assets/js/app.js`, `PlayerGrid.openCellMenu` (~lines 188-198).

Right-clicking a `pr`/`paid`/`cat` cell or column header opens a small
popup positioned at `popup.style.left = x; popup.style.top = y` with no
bounds checking. The sibling hook `PairingMenu` (colocated in
`pairings_live.ex`, ~line 2931) explicitly clamps its own popup to stay
on-screen, with a comment recording its assumed ~280×150px size. On a wide
Players grid, right-clicking a cell near the right or bottom edge of the
viewport can open a menu that's partly or fully off-screen.

**Why not fixed:** low severity (dismiss with Escape or click elsewhere,
then reopen further from the edge), and the menu's height is genuinely
variable here (the `cat` column's menu has one row per tournament
category, so a tournament with many categories has a taller popup than
`PairingMenu`'s fixed ~150px assumption) - a correct fix needs to measure
the actual popup after building it and reposition rather than copy
`PairingMenu`'s hardcoded numbers. That's a small behavioural change I'd
rather have the maintainer confirm than guess at.

### 3. Checked, no finding: injection via hand-built DOM strings

Every popup/menu built in JS (`PlayerGrid.openCellMenu`, `PairingMenu`,
`PrintMenu`) uses `document.createElement` + `textContent`/`cloneNode`,
never `innerHTML`, `insertAdjacentHTML`, or a template string. A
repo-wide search for `innerHTML`, `insertAdjacentHTML` and
`document.write` across `.js`/`.ex`/`.heex` returned **zero** matches.
Player names reach the DOM only through server-rendered HEEx (which
escapes) or through `textContent`/`cloneNode` of already-escaped markup
(never through a hand-built string). `PrintMenu.openAt` clones existing
`<a>` elements out of a hidden, server-rendered sibling rather than
rebuilding them from data - so it inherits HEEx's escaping for free.

The one place tournament data reaches a raw-HTML string outside of HEEx is
`print_controller.ex` (the print pages), which builds full HTML documents
as Elixir string interpolation rather than through HEEx. Every
interpolation of player/tournament text there (`.name`, `.title`, `.club`,
`.federation`, `.national_id`, `.fide_id`, `.status`, category lists, and
the two-step name-composition helpers `result_card_name/1` and
`name_with_score/2`) is wrapped in the module's own `esc/1`
(`Phoenix.HTML.html_escape` + `safe_to_string`) at the point the composed
string is embedded - spot-checked across the pairing list, alphabetical
list, absentee section, place cards, player cards, the results-card
printer, and the standings/crosstable printers. No unescaped path was
found. This is server-side Elixir rather than browser JS, and per the
audit note it looks like prior sweeps already had this file in scope
(unlike the hooks) - noted here as verified rather than claimed as new
ground.

### 4. Checked, no finding: leaks

Every hook that registers a `window`/`document` listener or a timer tears
it down in `destroyed()`:

- `PlayerGrid` - `document` `mousedown`/`keydown` removed.
- `AddPlayerShortcut` - `window` `keydown` removed.
- `.BoardFit` (live-round/projector page) - `window` `resize` removed.
  This one matters most: it's the hook on the hall-screen table left open
  all day in a tournament hall, and it's clean.
- `.BracketMinimap` - `strip` `scroll`, `window` `resize`/`pointermove`/
  `pointerup`, and `this.el` `pointerdown` all removed; also guards
  `this.strip`/`this.el` being null at teardown time.
- `.SwapArrows` - `window` `resize` removed, and its own `setTimeout`
  handle cleared.
- `.PairingMenu` / `.PrintMenu` - `contextmenu`/`mousedown`/`keydown`
  listeners removed, and `PrintMenu` also closes any open popup.
- `app.js`'s top-level `deployBanner`/`siteNotice` timers (`setInterval`)
  are each cleared before being reset, and `deployBanner`'s own watchdog
  self-clears once the view is confirmed alive or the reload fires - the
  only two timers in the app that outlive a single hook are these two
  page-global banners, and both cap their own lifetime (`STALE_AFTER_MS`,
  the 45s reload watchdog).
- The document-level delegated listeners (bracket-map clicks, topbar
  popover close-on-click-away, Escape-to-close) are bound exactly once at
  module load, by design (their own comments say so, e.g.
  `pairing_explain_live.ex` ~2300: "One delegated listener on document...
  so no re-binding needed") - not a leak since there is exactly one, ever.

### 5. Checked, no finding: re-render survival / double-binding

Every hook that could plausibly be destroyed and remounted across a
LiveView patch is keyed on an id that changes with the data it depends on
(`result-select-#{pairing.id}`, `print-pairings-menu-#{@round_number}`,
`round-pool-#{@round_number}`), so a genuinely new element gets a genuinely
new hook instance rather than a stale one. None of the hooks re-run
`addEventListener` inside `updated()` - `updated()` only re-measures/redraws
(`.BoardFit.report()`, `.SwapArrows.draw()`, `.BracketMinimap.sync()`) or
resyncs a value (`.BlindResultEntry` mirroring `data-result` back into
`.value` to work around LiveView's own "don't clobber a focused form
control" protection - a real bug that was hit and fixed previously,
per the comment at `pairings_live.ex` ~2600). No double-bind risk found.

### 6. Checked, no finding: dead selectors / console noise

A repo-wide search for `console.log`/`console.debug`/`console.warn`/
`console.info` in `.js`/`.ex`/`.heex` returned zero matches - no leftover
debug logging. Cross-checked every CSS-class/data-attribute selector the
delegated bracket-map click handler and the three colocated hooks depend
on (`.pe-board-wrap`, `.pe-duo`, `.pe-dot-popover`, `[data-filter]`,
`[data-dot-target]`, `.pe-bracket-scroll`, `.pe-minimap-viewport`,
`.modal-overlay`, `--swap-color`, etc.) against the templates that render
them - all present, none orphaned.

### 7. N/A: progressive degradation

OpenPairings is an authenticated, LiveView-only arbiter tool - there is no
no-JS path (no `<noscript>`, no `has-js`-style gating), and none is
expected: the whole app requires a live socket to do anything. This
failure mode is specific to OpenResults' public site and doesn't apply
here.

### 8. Checked, no finding: standings/pairings sort or filter logic in JS

Unlike OpenResults' public standings page, OpenPairings computes and
orders standings/pairings entirely server-side; there is no client-side
sort/filter script to review for numeric-vs-text or tie-handling bugs.

### 9. Note: "clipboard copies" (named in the task brief) not found

A repo-wide, case-insensitive search for `clipboard`, `navigator.clipboard`
and `execCommand("copy")` across the whole tree found nothing. Share
links and enrollment codes (`live_round_live.ex`, `settings_results_live.ex`)
are presented as plain selectable text/links with no copy-to-clipboard
button in the current codebase - either this was removed at some point or
never shipped under that name. Nothing to review or fix here; flagging so
this doesn't read as a gap.

## Manual check list

No JS test harness exists in this repo and none was added, per the task
brief. A few minutes in a browser to confirm the one behavioural fix and
spot-check the "no finding" areas:

1. **ColumnPrefs fix.** Open dev tools → Application → Storage, and block
   site data for the app's origin (or open the Players grid inside an
   iframe on a different origin, which triggers Safari's partitioning
   naturally). Load the Players grid and the Standings page: both should
   render normally with no thrown error in the console, and toggling
   columns in the Display panel should not crash the hook (it just won't
   persist the choice, which is expected without storage). Then unblock
   storage, pick a custom column set, reload, and confirm it's restored -
   confirms the guard didn't break the working path.
2. **BoardFit / projector view.** Open the live-round page in display mode
   on a screen, resize the browser window a few times, and leave it open
   for a while - board rows should keep re-fitting to the window with no
   console errors and no growing memory use (Performance Monitor's "JS
   heap size" flat-lining is enough to sanity-check no leak).
3. **PrintMenu / PairingMenu / PlayerGrid popups.** Right-click a print
   button, a pairing name, and a Players-grid cell in the `pr`/`paid`/
   category columns near the edge of the window. All should open a small
   menu; the two page-level ones should stay on-screen, the grid one may
   not near an edge (finding #2 above) - confirm that's merely cosmetic
   (menu still works, Escape/click-away still closes it).
4. **BracketMinimap.** Open the pairing-rationale page for a round with
   enough boards to make the bracket map scroll horizontally; drag the
   minimap strip and confirm the main chart scrolls in sync, then shrink
   the window until the chart no longer overflows and confirm the minimap
   disappears.
5. **Theme bootstrap.** Toggle the theme switcher through a few themes,
   reload, and confirm the choice persists; then open the app in a private
   window with storage entirely blocked and confirm it still renders (no
   blank/unstyled flash), defaulting sensibly.

## Files changed

- `assets/js/app.js` - `ColumnPrefs` hook, `localStorage` guard (finding 1)
- `CHANGELOG.md` - `[Unreleased]` entry for the same fix

No Elixir source changed, so no new ExUnit test was added - the one fix
is pure client-side defensive code with no server-observable surface
(HEEx output, rendered classes/attributes are all unchanged).
