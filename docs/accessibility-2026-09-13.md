# Accessibility pass - 2026-09-13

First look at this dimension: the whole-codebase audit of 2026-09-05 listed
accessibility under "what this audit never looked at". Target: **WCAG 2.2,
level AA**. The readers here are arbiters - often under time pressure, in a
noisy hall, some on a keyboard, some with a screen reader, some reading a
laptop across a bright room - and helpers entering results on a phone.

Scope: every LiveView the router serves (static and connected render), the
sign-in and registration pages, the phone's enrolment and result-entry pages,
the thirteen dialogs and the menus behind a right-click, the root layout's
banners, `assets/js/app.js` and the seven colocated hooks, all **seven themes
and nine accents** (the brief said light and dark; the app has grown five more
themes and an accent picker since), and - lower priority - the print pages.
The public results site has its own report:
`openresults/docs/accessibility-2026-09-13.md`.

## How it was checked

- **A test walks every page.** `test/support/a11y.ex` holds the decidable
  invariants; `test/pairings_engine_web/accessibility_test.exs` renders every
  LiveView GET route from the router - a route added later with no entry fails
  the walk and names itself - in both its static render (the whole document)
  and its connected render, plus the signed-out pages, the phone pages, and
  the states that exist only after a click: the Players Card, the registration
  dialog, the rating refresh, the pairing context menu, the hand-edit
  confirmation, the norm judgment, the hand-off and delete dialogs and the
  clear-result confirmation.
- **Contrast is computed, not judged.** `test/pairings_engine_web/contrast_test.exs`
  reads the tokens out of `assets/css/app.css` and applies the WCAG formula to
  all 63 theme-and-accent palettes: the design system's own pairings, and every
  rule in the stylesheet that sets a text colour and a background together,
  with `color-mix()` and translucent fills laid over their ground. The
  scripts used to find the minimal token changes are described under
  "Contrast".
- **Scripts were syntax-checked**: `app.js` and every colocated hook extracted
  by the compiler, through `node --check`.
- **No browser was driven**, headless or otherwise: axe-core is not available
  on this machine without downloading it. What only a browser and a person
  can confirm - focus actually landing, NVDA actually speaking - is the manual
  checklist at the end.

## Findings, worst first

### 1. Entering results from the keyboard wrote results nobody chose · FIXED

`lib/pairings_engine_web/live/pairings_live.ex`, the `.BlindResultEntry` hook.

On Windows and Linux a closed `<select>` changes its value - and fires
`change` - on every arrow press. The result select is a `phx-change` form, so
an arbiter walking from 1-0 to 0-1 with the arrow keys **recorded 1/2-1/2 on
the way**, with a broadcast and an audit row each; passing the blank option
staged the "clear the recorded result?" box, which replaced the select under
the keyboard mid-walk. The same box, opened on purpose, replaced the focused
select and left focus on nothing, so the next Tab started from the top of the
page, mid-round. The select itself had no name: a screen reader tabbing from
board to board heard "combo box, 1-0" and nothing about which game it was.

Now:

- an arrow-key walk is held back in the hook (the intermediate `input` and
  `change` events stop at the select, before LiveView's listener further up)
  and sent once, on Enter or when focus leaves; Escape puts the recorded
  result back. The 1/2/3 keys, a mouse pick and an opened list's own choice
  still send at once;
- each select is named "Result, board 4: Anna Peeters against Bram Claes";
- the clear confirmation takes focus on **Cancel** as it appears (one
  Shift+Tab from "Yes, clear it"), both buttons carry the question as their
  description, and closing it either way puts focus back on that board's
  select (`refocus_result`);
- on the last board, entering a result keeps focus there instead of dropping
  it.

### 2. Dialogs were dialogs to the eye only · FIXED

Thirteen dialogs: the Players Card, player registration, rating refresh and
club update (Players); the hand-edit confirmation (Pairings); the category
assignment preview (Categories); the JaVaFo switch (Options); the norm
judgment (Norms); the restore point (History); hand-off, delete and delete
permanently (Tournaments); and the publishing consent in its three states.

Only the consent dialog had `role="dialog"`, and it had no name; none moved
focus: a dialog opened with focus still on the button behind it, Tab walked
into the page behind, and closing left the keyboard at the top of the page.

Now each is `role="dialog" aria-modal="true"`, named by its heading, and
carries the `DialogFocus` hook (`assets/js/app.js`): focus moves in (to the
first field of a form dialog, otherwise to the dialog itself, read out as its
title - not to its first button, which in a confirmation is as often "Apply"
as "Cancel"), Tab and Shift+Tab stay inside, and on the way out focus returns
to the control that opened it - or to whatever carries its id after the
re-render. Escape already closed them (`phx-window-keydown`); it still does.

### 3. Nothing the app said out loud was heard · FIXED

- Flashes were `role="alert"` inside the LiveView, so a live navigation
  replaced the region along with the page: "You now have access to ...",
  carried by the navigation after accepting an invitation, arrived in a
  brand-new alert and was not read; the ones that were
  read interrupted whatever the screen reader was saying.
- The deploy banner, the site notice and the version toast were live regions
  rendered `hidden`, which is a region not in the accessibility tree when its
  text arrives - they said nothing. Had they worked, the deploy banner rewrites
  its countdown every second.
- Every settings page confirms a save and refuses a bad one with a note beside
  the button - some sixty of them, none a live region. After pressing Save, a
  screen reader heard nothing either way.

Now one persistent polite region, `#announcer`, sits in the root layout
outside every LiveView, and everything speaks through it: each flash once when
it appears (the `Flash` hook; the two connection flashes by an event dispatched
as they are shown), each "Saved." or refusal note as it appears or changes
(one observer, not sixty edits), the deploy banner when it appears and each
time it escalates - not every second - the site notice and the version toast.
The banners are no longer live regions themselves. The phone's result entry
has its own status line ("Board 3: 1-0 saved", "Board 3: result cleared").

### 4. The right-click menus had no keyboard way in · PARTLY FIXED

The player grid, the print buttons and the pairing table are right-click
driven.

- **Player grid headers.** The sortable headers were `<th phx-click>`: not
  reachable, not operable, no sort state. Each now holds a real button (the
  header looks exactly as before), with `aria-sort` on the header. The
  context-menu key or Shift+F10 on a focused Pr., Paid or Cat. header opens its
  bulk menu under the header with focus in it; Up and Down walk the items,
  Escape and Tab close it and return focus to the header.
- **Player registration.** It opened on a double-click on the row. The name is
  now focusable (`role="button"`, `aria-haspopup="dialog"`): Enter or Space
  opens the registration dialog, and the context-menu key opens the Players
  Card, as a right-click on the row does. A single click still does nothing.
- **Print variants.** The absentee section, the test print, stack-cut order
  and the PGN exports lived only behind a right-click on a print link. The
  context-menu key on the focused link now opens the same menu, under the
  link, with focus in it (`role="menu"`, arrow keys, Escape and Tab return).
- **Not fixed:** the per-player cell menus in the grid (the cells are not
  focusable) and the pairing table's hand-edit menu (the seats are spans).
  Both need a real keyboard model, not an attribute - recommendations R1 and
  R2.

### 5. Secondary text was 2.0-3.1:1 in Slate, and other themes fell short in places · FIXED (token changes)

Slate's `--text-soft` - the colour of every hint, table heading, meta line
and field edge in that theme - was 2.80:1 on a card and 1.97:1 on the accent
tint. Mocha's secondary text and its accent on its own tint (the current tab,
every badge) were 3.9-4.3:1, and six of its alternative accents were
3.2-3.8:1. Light's warning colour was 3.3-4.4:1 (the "archived" badge, warning
tags). Board's success and secondary text, and the blue and teal accents in
the four light themes, sat just under. The daisyUI colours behind the
account-settings button and the flash messages had near-white text at
2.75-4.14:1. Every value moved only as far as 4.5:1 needs, hue kept - the
tables are under "Contrast".

Beside the tokens, five rules drew their own low-contrast text: the version
number in the top bar was faded to 65% (2.0-3.9:1), a swap-selected pool
chip's tag was 75% white on the light accents of Dark, Slate and Mocha
(1.7-1.9:1), an old value struck through in the History page's change rows was
secondary text on a red tint (2.1-4.2:1), two lines of the sign-in page's green
hero were too faint (3.6 and 4.1:1), and field errors on the account pages used
daisyUI's one red for every theme (3.1:1 on the dark ones). All fixed.

### 6. Text boxes and dropdowns had no visible edge · FIXED

Every field was edged in `--border`, 1.2-1.8:1 against the card or page in every
theme but High Contrast (WCAG 1.4.11 asks 3:1 for the boundary that shows where a
control is); on a white card an empty white box had nothing else to find it
by. Fields, daisyUI inputs and the phone's code box are edged in `--text-soft`
now (4.76:1 or more everywhere), and a focused field doubles its edge in the
accent inside the soft halo. A field with an error is edged in `--danger`,
which it never was: the unlayered field rule outranked daisyUI's
`input-error`.

### 7. Focus was the browser's own ring, and four rules removed even that · FIXED

No rule drew focus, and `.pe-legend-item`, `.pe-band-row`, `.pe-disc` and
`.pe-board-wrap` removed the outline, leaving a hover tint (about 1.2:1) as the
only sign of focus on the bracket map. One `:focus-visible { outline: 2px solid
var(--accent) }` now covers everything, at 4.5:1 or more against the page in
every theme and accent. The outline is removed only where focus is moved to
rather than operated (`#main-content`, the dialogs themselves) and on fields,
which draw their own accent edge - the contrast test holds that list.

### 8. No way past the top bar, and the tabs said which page by colour · FIXED

A keyboard user tabbed through the brand, the tabs, two menus and the pickers
on every page before reaching it; there was nothing to skip to.
Now "Skip to content" is the first thing on every page (visible on focus) and
moves focus to `<main id="main-content">`; the phone pages have their own
`<main>`. The top bar's two `<nav>`s are named ("Main navigation", "Account
and display") so a landmark list can tell them apart, the current tab says
`aria-current="page"`, and the language picker marks the current language and
gives each its own `lang`. The phone's result page had no `<h1>` (the
tournament name is one now) and the invitation page had none either.

### 9. Controls with no name, or a name that was only a placeholder · FIXED

- The arbiter picker (Norms, and the norm tool at `/tools/norms`): two boxes under one label, told apart
  only by placeholders - "%{role}: name" and "%{role}: FIDE ID" now, the name
  box `aria-required` where the star is, and its hint tied to it.
- The RESTORE confirmation box (History), the TRF export's rounds box
  (Pairings), the "Add a tiebreak..." select (Settings).
- The eight upload boxes (SWAR, TRF and backup imports, both hand-off files,
  the logo, CSV results, the norm tool's files): each file input is named by
  its visible "Choose a .swar file" text.
- The tiebreak list's up, down and remove buttons were glyphs named "up
  arrow" once per row; each now names its tiebreak ("Move <tiebreak> up").
- The account pages' fields (`core_components.ex`): an error sat under the box
  tied to nothing. The field is `aria-invalid` and described by its error now.
  The phone enrolment's wrong-code message likewise.
- The publishing pill's `aria-label` replaced its visible word ("Offline") with
  a sentence, so speech input had nothing to match (WCAG 2.5.3); it is named by
  the word, with the sentence kept as its `title`.
- Thirteen empty header cells over action columns now say "Actions", the
  player grid's says "Remove", and the archived-tournaments table's unlabelled
  status column says "Status".
- The two QR codes (phone enrolment, public standings) were raw SVGs of a few
  hundred unnamed shapes; each is one named image.

### 10. Colour was the only signal in six places · FIXED

- **The publishing pill below 860px wide** dropped its word with
  `display: none` - gone for a screen reader too - leaving a green or red dot.
  The word is visually hidden instead, and each state keeps a shape of its own
  (ring for sending, diamond for refused, square for offline, bar for off).
- **The round picker** (Pairings) and the phone's round and result buttons
  marked the current one by colour; they say `aria-pressed` now.
- **Prize places** in category standings were a highlight; they read ", prize
  place" too.
- **The colour-history squares** on the rationale page were empty spans with a
  tooltip; each carries "Round 3: White" as words.
- **A locked publish switch** gave its reason only as a tooltip on a disabled
  button, which a keyboard can neither focus nor hover; the reason is in the
  button's text for a screen reader now. (The switches themselves already say
  "Public" or "Not public" in words - checked, clean.)
- **The theme and accent pickers** highlighted the current option in CSS only;
  each option says `aria-pressed`, kept by the script across LiveView patches.

### 11. The phone lost its place when a finished board left the list · FIXED

`lib/pairings_engine_web/live/mobile_results_live.ex`. A board leaves the list
1.6 seconds after its result is entered, taking the focused button with it; a
keyboard or screen reader was sent back to the top. The boards were also
matched by position, so the buttons of the board below were reused for the one
that left. Boards are keyed by id now, and the board that had focus hands it,
as it goes, to the board that moves into its place (`.KeepFocus`). Each row of
result buttons is a group named for its board and players.

### 12. The live display could not be paused without touching it · FIXED

`/t/:id/live?display=1` pages through the boards on its own; only a tap on the
boards paused it (WCAG 2.2.2). A "Pause cycling" / "Resume cycling" button,
`aria-pressed`, does it from the keyboard.

### 13. Headings and tables · FIXED

- The changelog page had two `<h1>` (`CHANGELOG.md`'s own title under the
  page's); `PairingsEngine.Changelog` drops the file's.
- The rationale page went from `<h1>` straight to `<h3>` for its card titles;
  they are `<h2>`s with the look they had. The audit now enforces heading
  order everywhere.
- The float cascade's rows are headed by their bracket's score, and each
  criteria ladder table has a caption; the "Active phones" list, laid out as a
  table with no header row, is `role="presentation"`.

### 14. Motion and obscured focus · FIXED

The bracket map's glide, the head-to-head panel and the result entry's
board-to-board scroll ignored `prefers-reduced-motion`; they jump when it is
set. A dot the keyboard tabbed to could scroll under the map's sticky score
gutter, and anything could scroll under a deploy banner or site notice while
one is up (WCAG 2.4.11); both are cleared with `scroll-padding` now.

### 15. English in a Dutch interface · FIXED

The theme and accent names were each button's only name and were not
translated, so a Dutch screen reader read "Green" in Dutch. All sixteen go
through gettext now. Every string this pass added is translated.

## Contrast

Computed with the WCAG 2.2 relative-luminance formula. A translucent token
(`--accent-soft` on the dark themes) is laid over the ground it sits on. "Worst
ground" is the lowest ratio of that colour across the page, a card, a striped
row, a hovered row and the accent tint. Before is `main` as of this pass; a
cross marks a failure.

Each changed value was found by holding the colour's HSL hue and saturation
and walking its lightness 0.1% at a time from the original, until every
pairing in the contrast test passed for every accent on that theme. Every
value below is that first passing step, or one step past it where the browser's
8-bit compositing needs it (Mocha's `--text-soft` and `--accent`, the blue and
fuchsia Mocha accents, violet on Dark and Slate).

### Tokens changed

| Theme | Token | Before | After | Binding pairing | Before | After |
|---|---|---|---|---|---|---|
| Light | `--warn` | `#a76a25` | `#86551e` | "archived" badge: warn on its own tint, on the page | 3.31 | 4.52 |
| Slate | `--text-soft` | `#5a6675` | `#98a3b0` | secondary text on the accent tint (sign-in notice, band meta) | 1.97 | 4.51 |
| Paper | `--warn` | `#8a5a1e` | `#88591e` | "archived" badge on the page | 4.43 | 4.50 |
| Board | `--text-soft` | `#5f6d61` | `#5e6b60` | secondary text in a hovered row | 4.43 | 4.55 |
| Board | `--success` | `#2f7d4f` | `#2c744a` | "on" state pill on its tint | 4.04 | 4.51 |
| Board | `--warn` | `#8a5f14` | `#795312` | "archived" badge on the page | 3.80 | 4.52 |
| Mocha | `--text-soft` | `#a6adc8` | `#b4bad1` | secondary text on the accent tint | 3.94 | 4.54 |
| Mocha | `--accent` | `#cba6f7` | `#ceacf8` | the accent on its own tint (current tab, badges) | 4.31 | 4.54 |
| Mocha | `--danger` | `#f38ba8` | `#f38fab` | the phone's error line on its tint | 4.42 | 4.52 |
| Light, Paper, Board, High Contrast | blue `--accent` | `#2563eb` | `#2160eb` | the accent on Board's page | 4.39 | 4.53 |
| Light, Paper, Board, High Contrast | teal `--accent` | `#0d7d74` | `#0d7870` | the accent on Board's page | 4.25 | 4.53 |
| Light, Paper, Board, High Contrast | rose `--accent-soft` | `#fce4ea` | `#fce6eb` | secondary text on the tint | 4.46 | 4.52 |
| Light, Paper, Board, High Contrast | indigo `--accent-soft` | `#e9e8fc` | `#ebeafc` | secondary text on the tint | 4.46 | 4.53 |
| Dark, Slate | violet `--accent` | `#a78bfa` | `#a98dfa` | the accent on its tint (Slate) | 4.45 | 4.55 |
| Dark, Slate | indigo `--accent` | `#818cf8` | `#8a94f8` | the accent on its tint (Slate) | 4.14 | 4.51 |
| Mocha (own set, new) | blue `--accent` | `#5b9bff` | `#80b2ff` | the accent on its tint | 3.54 | 4.55 |
| Mocha | violet `--accent` | `#a78bfa` | `#bca7fb` | the accent on its tint | 3.46 | 4.51 |
| Mocha | rose `--accent` | `#fb7185` | `#fc8f9f` | the accent on its tint | 3.69 | 4.53 |
| Mocha | slate `--accent` | `#94a3b8` | `#aab6c6` | the accent on its tint | 3.61 | 4.51 |
| Mocha | indigo `--accent` | `#818cf8` | `#a4acfa` | the accent on its tint | 3.22 | 4.52 |
| Mocha | fuchsia `--accent` | `#e879f9` | `#ed94fa` | the accent on its tint | 3.79 | 4.54 |

Mocha's accents used to share the Dark and Slate set; its surfaces are
lighter, so it has its own set now, each with a hover a step lighter again.
Teal and cyan cleared on Mocha and still come from the shared set. The accent
swatches in the picker show the new blue and teal. High Contrast and Dark
needed no theme token changed.

The daisyUI colours (the account pages' primary button, the flash messages)
are `oklch()`; lightness lowered, chroma and hue kept:

| daisyUI theme | Token | Before | After | Text on it, before | After |
|---|---|---|---|---|---|
| light | `--color-primary` | `oklch(70% 0.213 47.604)` | `oklch(57% ...)` | 2.75 | 4.54 |
| light | `--color-info` | `oklch(62% 0.214 259.815)` | `oklch(55% ...)` | 3.49 | 4.63 |
| light, dark | `--color-error` | `oklch(58% 0.253 17.585)` | `oklch(54% ...)` | 4.06 | 4.58 |
| dark | `--color-primary` | `oklch(58% 0.233 277.117)` | `oklch(56% ...)` | 4.14 | 4.51 |
| dark | `--color-info` | `oklch(58% 0.158 241.966)` | `oklch(53% ...)` | 3.81 | 4.64 |

Rules, not tokens (default accent):

| What | Change | Light | Dark | Slate | Mocha | Paper | Board | High Contrast |
|---|---|---|---|---|---|---|---|---|
| Edge of a field, on a card | `--border` → `--text-soft` | 1.31 → 5.38 | 1.30 → 6.62 | 1.32 → 6.39 | 1.38 → 6.52 | 1.38 → 5.42 | 1.54 → 5.24 | 4.54 → 10.86 |
| Version number in the top bar | 65% opacity removed | 2.56 → 4.97 | 3.68 → 7.17 | 2.02 → 7.09 | 3.92 → 8.50 | 2.63 → 5.23 | 2.48 → 4.76 | 3.90 → 10.86 |
| Swap-selected pool chip's tag | 75% white → `--accent-ink` | 5.05 → 7.50 | 1.89 → 8.23 | 1.86 → 8.30 | 1.72 → 8.50 | 6.01 → 8.73 | 5.10 → 7.12 | 5.11 → 7.78 |
| Old value in a timeline | `--text-soft` → `--text` | 4.20 → 12.53 | 5.16 → 11.31 | 2.07 → 9.54 | 4.03 → 6.16 | 4.06 → 12.91 | 3.96 → 10.77 | 7.61 → 14.72 |

The sign-in hero is a fixed green gradient in every theme; its lines are
measured where they sit on it: the subtitle 4.05 → 4.63 (opacity 0.82 → 0.92),
"Coming soon" 3.64 → 5.12 (0.6 → 0.8); the feature list (5.10), the call to
action (5.96) and the large title (4.65, needing 3) were already clear.

### Per theme, after

Default accent unless the row says otherwise. The last two rows are the worst
case over the eight other accents and over every rule in the stylesheet that
sets its own text and background.

#### Light

| Pairing (worst ground) | Needs | Before | After |
|---|---|---|---|
| Body text | 4.5 | 13.82 | 13.82 |
| Secondary text | 4.5 | 4.63 | 4.63 |
| Accent text: links, current tab, badges | 4.5 | 6.46 | 6.46 |
| Primary button (and hovered) | 4.5 | 7.50 | 7.50 |
| Danger text | 4.5 | 5.99 | 5.99 |
| Danger button (and hovered) | 4.5 | 6.48 | 6.48 |
| Success text (and on its tint) | 4.5 | 4.65 | 4.65 |
| Warning text (and on its tint) | 4.5 | 3.74 ✗ | 5.31 |
| Information (and on its tint) | 4.5 | 5.58 | 5.58 |
| Focus ring | 3 | 6.94 | 6.94 |
| Edge of a field | 3 | 1.21 ✗ | 4.97 |
| Worst of the other eight accents | 4.5 | 4.39 ✗ (teal) | 4.52 (rose) |
| Worst rule with its own text and background | 4.5 | 3.31 ✗ (`.badge.archived`) | 4.52 (`.auth-notice`, rose) |

#### Dark

| Pairing (worst ground) | Needs | Before | After |
|---|---|---|---|
| Body text | 4.5 | 10.87 | 10.87 |
| Secondary text | 4.5 | 4.96 | 4.96 |
| Accent text | 4.5 | 5.69 | 5.69 |
| Primary button (and hovered) | 4.5 | 8.23 | 8.23 |
| Danger text | 4.5 | 5.92 | 5.92 |
| Danger button (and hovered) | 4.5 | 6.41 | 6.41 |
| Success text (and on its tint) | 4.5 | 7.10 | 7.10 |
| Warning text (and on its tint) | 4.5 | 6.09 | 6.09 |
| Information (and on its tint) | 4.5 | 6.07 | 6.07 |
| Focus ring | 3 | 7.60 | 7.60 |
| Edge of a field | 3 | 1.30 ✗ | 6.62 |
| Worst of the other eight accents | 4.5 | 4.45 ✗ (indigo) | 4.76 (cyan) |
| Worst rule with its own text and background | 4.5 | 4.45 ✗ (`.badge`, indigo) | 4.76 (`.auth-notice`, cyan) |

#### Slate

| Pairing (worst ground) | Needs | Before | After |
|---|---|---|---|
| Body text | 4.5 | 9.08 | 9.08 |
| Secondary text | 4.5 | 1.97 ✗ | 4.51 |
| Accent text | 4.5 | 5.17 | 5.17 |
| Primary button (and hovered) | 4.5 | 8.30 | 8.30 |
| Danger text | 4.5 | 6.55 | 6.55 |
| Danger button (and hovered) | 4.5 | 7.41 | 7.41 |
| Success text (and on its tint) | 4.5 | 6.26 | 6.26 |
| Warning text (and on its tint) | 4.5 | 6.31 | 6.31 |
| Information (and on its tint) | 4.5 | 5.17 | 5.17 |
| Focus ring | 3 | 7.33 | 7.33 |
| Edge of a field | 3 | 1.32 ✗ | 6.39 |
| Worst of the other eight accents | 4.5 | 1.99 ✗ (cyan, secondary text) | 4.51 (indigo) |
| Worst rule with its own text and background | 4.5 | 1.97 ✗ (`.auth-notice`) | 4.51 (`.auth-notice`) |

#### Mocha

| Pairing (worst ground) | Needs | Before | After |
|---|---|---|---|
| Body text | 4.5 | 6.06 | 6.06 |
| Secondary text | 4.5 | 3.94 ✗ | 4.54 |
| Accent text | 4.5 | 4.31 ✗ | 4.54 |
| Primary button (and hovered) | 4.5 | 8.07 | 8.50 |
| Danger text | 4.5 | 5.43 | 5.58 |
| Danger button (and hovered) | 4.5 | 7.08 | 7.29 |
| Success text (and on its tint) | 4.5 | 5.44 | 5.44 |
| Warning text (and on its tint) | 4.5 | 4.82 | 4.82 |
| Information (and on its tint) | 4.5 | 4.57 | 4.57 |
| Focus ring | 3 | 6.19 | 6.51 |
| Edge of a field | 3 | 1.38 ✗ | 6.52 |
| Worst of the other eight accents | 4.5 | 3.22 ✗ (indigo) | 4.51 (slate) |
| Worst rule with its own text and background | 4.5 | 3.22 ✗ (`.badge`, indigo) | 4.51 (`.badge`, slate) |

#### Paper

| Pairing (worst ground) | Needs | Before | After |
|---|---|---|---|
| Body text | 4.5 | 14.59 | 14.59 |
| Secondary text | 4.5 | 4.59 | 4.59 |
| Accent text | 4.5 | 7.94 | 7.94 |
| Primary button (and hovered) | 4.5 | 8.73 | 8.73 |
| Danger text | 4.5 | 7.27 | 7.27 |
| Danger button (and hovered) | 4.5 | 6.87 | 6.87 |
| Success text (and on its tint) | 4.5 | 6.49 | 6.49 |
| Warning text (and on its tint) | 4.5 | 5.03 | 5.13 |
| Information (and on its tint) | 4.5 | 6.04 | 6.04 |
| Focus ring | 3 | 9.07 | 9.07 |
| Edge of a field | 3 | 1.33 ✗ | 5.23 |
| Worst of the other eight accents | 4.5 | 4.39 ✗ (teal) | 4.56 (rose) |
| Worst rule with its own text and background | 4.5 | 4.39 ✗ (`.badge`, teal) | 4.50 (`.badge.archived`, blue) |

#### Board

| Pairing (worst ground) | Needs | Before | After |
|---|---|---|---|
| Body text | 4.5 | 12.07 | 12.07 |
| Secondary text | 4.5 | 4.43 ✗ | 4.55 |
| Accent text | 4.5 | 6.29 | 6.29 |
| Primary button (and hovered) | 4.5 | 7.12 | 7.12 |
| Danger text | 4.5 | 6.33 | 6.33 |
| Danger button (and hovered) | 4.5 | 6.88 | 6.88 |
| Success text (and on its tint) | 4.5 | 4.23 ✗ | 4.76 |
| Warning text (and on its tint) | 4.5 | 4.67 | 5.69 |
| Information (and on its tint) | 4.5 | 5.52 | 5.52 |
| Focus ring | 3 | 6.45 | 6.45 |
| Edge of a field | 3 | 1.40 ✗ | 4.76 |
| Worst of the other eight accents | 4.5 | 4.25 ✗ (teal) | 4.53 (teal) |
| Worst rule with its own text and background | 4.5 | 3.80 ✗ (`.badge.archived`) | 4.52 (`.badge.archived`, blue) |

#### High Contrast

| Pairing (worst ground) | Needs | Before | After |
|---|---|---|---|
| Body text | 4.5 | 16.66 | 16.66 |
| Secondary text | 4.5 | 8.62 | 8.62 |
| Accent text | 4.5 | 6.18 | 6.18 |
| Primary button (and hovered) | 4.5 | 7.78 | 7.78 |
| Danger text | 4.5 | 7.18 | 7.18 |
| Danger button (and hovered) | 4.5 | 7.18 | 7.18 |
| Success text (and on its tint) | 4.5 | 5.40 | 5.40 |
| Warning text (and on its tint) | 4.5 | 6.00 | 6.00 |
| Information (and on its tint) | 4.5 | 6.18 | 6.18 |
| Focus ring | 3 | 7.78 | 7.78 |
| Edge of a field | 3 | 4.54 | 10.86 |
| Worst of the other eight accents | 4.5 | 4.39 ✗ (teal) | 4.62 (blue) |
| Worst rule with its own text and background | 4.5 | 4.39 ✗ (`.badge`, teal) | 4.62 (`.badge`, blue) |

"Edge of a field" before is the `--border` the fields were edged in; after,
the `--text-soft` they are edged in now.

## Recommended, not built

### R1. Full keyboard navigation of the player grid

The grid's per-player cell menus (presence, paid, categories) open on a
right-click on a cell, and the cells are not focusable: a keyboard user can
sort, open the bulk menus and edit a player through the registration dialog,
but not change one player's cell in place.

Plan: make the grid an ARIA grid with a roving tabindex - one cell in the tab
order, the arrow keys move between cells, Home/End and Ctrl+Home/End jump - in
the `PlayerGrid` hook, which already owns the menus. The context-menu key or
Shift+F10 on a cell calls the existing `openCellMenu(x, y, col, playerId,
true)` at the cell; Enter on a name opens registration as now. The hard part
is that LiveView re-renders rows on every change from any tab: keep the active
cell as `{player id, column}` in the hook and restore focus and tabindex in
`updated()`. Announce the column name when moving between columns only if NVDA
testing shows the table headers are not enough. **Size: medium** - two to
three days, most of it NVDA and Firefox testing against live updates from a
second tab.

### R2. Hand-editing pairings without a mouse

Swap, vacate, award a bye, fill a seat and substitute all start from a
right-click on a seat (`.PairingMenu`); the seats are spans. Plan:

1. Seats become `<button type="button">`s carrying the same `data-scope`
   attributes, styled as the spans are; an armed swap completes on Enter as it
   does on a left-click (the `phx-click` is already there).
2. The context-menu key or Shift+F10 on a seat pushes `open_menu` with the
   seat's position instead of the pointer's (the same trick the print menu now
   uses) and the menu takes focus: `role="menu"`, `menuitem`s, Up/Down,
   Escape back to the seat.
3. "Swap with..." armed says so through `#announcer` ("Pick the player to swap
   with"), and after the confirmation dialog closes focus returns to the seat
   by id - `DialogFocus` already does that part.

**Size: medium** - about two days, half of it walking the five gestures by
keyboard in a real round.

### R3. A keyboard way to pan the bracket map

The minimap's drag already has a non-drag alternative: a single click centres
the map on that point (WCAG 2.5.7 is met). Keyboard users can reach every dot
with Tab, which scrolls the map, but cannot pan it freely - the strip's
scrollbar is hidden in favour of the minimap, and the minimap is
`aria-hidden`. Plan: give `.pe-bracket-scroll` `tabindex="0"`, `role="region"`
and a name ("Score-bracket map"), so the arrow keys scroll it natively, and
show the native scrollbar while it has `:focus-visible`. **Size: small** - an
hour or two plus a check that the dots' own focus order is unchanged.

### R4. Header scopes and table names across the app

Simple tables - one header row, no merged cells - which browsers already
associate, so this is robustness rather than a failure: 150-odd `<th>` without
`scope` and about twenty tables with no caption or name. The walk counts them
and does not enforce them (`@not_enforced` in the test). Plan: `scope="col"` on
every column header, and a name on each table - `aria-labelledby` the card's
existing heading where there is one, a visually hidden caption where there is
not - then remove both rules from `@not_enforced`. **Size: small to medium** -
a day, mechanical, across about twenty-five templates and their tests.

### R5. Language gaps a screen reader will say in the wrong accent

Seen in passing, not a WCAG failure in themselves: English literals outside
gettext on the phone pages ("Board 3", "vs", "Leave", the enrolment page), the
OpenResults settings card's state pills ("Published", "Unlisted", "Open"), the
rematch tags on the rationale page, the "Leave" confirmation on the tournament
list, and the player grid's cell-menu items ("All Absent", "Add U16"), which
are built in `app.js` and never reach gettext. **Size: small** - a gettext
sweep of those files with Dutch; the menu items need their words rendered into
the grid as data attributes, the way its category names already are.

### R6. The publishing consent dialog while it loads

For the moment it takes to ask the results site who runs it, the dialog has no
Escape and no button: a keyboard user waits. Plan: a Cancel button and
Escape in the loading state, pushing the same decline event. **Size: tiny.**

## Checked and clean

- `<html lang>` follows the locale on every page, one `<title>` each, and every
  page walked has exactly one `<h1>` and no skipped heading level.
- No `tabindex` above 0, no duplicate ids, every `for`, `aria-describedby` and
  `aria-labelledby` resolves, nothing focusable inside `aria-hidden`, no live
  region rendered `hidden` - enforced on every page by the walk.
- The publish switches say "Public" or "Not public" in words beside the
  colour; the connection indicator says its state in a word at every width.
- Status badges and tags ("done", "archived", "paired down", "bye") are words.
- Escape closes every dialog that has something to cancel.
- `prefers-reduced-motion` was already respected by every CSS animation (the
  connection and publishing dots, the swap banner, the hall display's bar).
- Zoom: the viewport does not restrict scaling.
- Print pages (lower priority): each is a standalone document with `lang`,
  a `<title>` and one `<h1>`; the logos are `alt=""` beside the title they
  repeat. The blank scoresheet's move-number column has an empty header -
  acceptable on a form made to be filled in by hand.

## Tests added

- `test/support/a11y.ex` - `PairingsEngineWeb.A11y.audit/2`: `lang` (and that
  it matches the locale), a `<title>`, one `<h1>`, heading order, one `<main>`,
  a skip link first, a name for every form control, link, button and
  `<summary>`, `alt` on every `<img>`, SVGs hidden or named, header cells in
  every data table, `scope` on header cells and a name on every data table
  (both reported, not yet enforced - R4), no positive `tabindex`, no dangling
  id references, no duplicate ids, dialogs named and modal, nothing focusable
  under `aria-hidden`, no live region rendered `hidden`. `explain/1` prints
  every violation on a page at once.
- `test/pairings_engine_web/accessibility_test.exs` (7 tests) - every LiveView
  walked from the router, static and connected; the signed-out pages; the
  phone's enrolment and result entry; the dialogs, context menu and clear
  confirmation opened with the events a click sends, each a named, modal
  dialog carrying `DialogFocus`; the skip link, `#main-content`, the announcer
  and the banners not being live regions; every result select named for its
  board and players.
- `test/pairings_engine_web/contrast_test.exs` (8 tests) - every theme and
  accent defined, and the picker's swatches match the accents they apply;
  every token pairing at its AA ratio in all 63 palettes; every rule that sets
  its own text and background at 4.5:1 in all 63; daisyUI's filled colours;
  the sign-in hero's lines on its gradient; no field edged in `--border`; the
  focus ring exists and is removed only where something else is drawn or
  focus is only moved to; the formula against WCAG's reference values.
- Existing tests updated where the markup deliberately changed: the Players
  Card heading carries an id, the grid's names are focusable `<strong>`s, and
  the phone's settled board is looked for by its element, since the status line
  still says "Board 1: 1-0 saved".

## Manual checklist

What only a person, a browser and a screen reader can confirm. Chrome or Edge
plus Firefox, NVDA 2024 or later on Windows.

### Keyboard only (no mouse at all)

1. **Sign in.** Load `/users/log-in`. The first Tab shows "Skip to content";
   Enter moves focus into the page. On `/users/register` type a malformed
   email and Tab away: the field's edge turns red and its error is read with
   the field.
2. **Tournament list.** Tab to a tournament's Delete and press Enter: the
   dialog opens with focus on it, Tab cycles Cancel and Delete without leaving it, Escape closes
   it and focus is back on Delete.
3. **Players.** On `/t/:id/players`, Tab to the "Name" header and press Enter:
   the grid sorts, again reverses. Tab to the "Pr." header and press the
   context-menu key (or Shift+F10): the bulk menu opens under the header with
   its first item focused; Down and Up move, Escape closes it with focus back
   on the header. Tab to a player's name and press Enter: the registration
   dialog opens with focus in its first field; Tab stays inside; Escape
   returns focus to the name. Press the context-menu key on a name: the
   Players Card opens, and closes back to the name.
4. **Pairings - result entry.** On a playing round, Tab to board 1's result.
   Press 1: 1-0 is recorded and focus moves to board 2. On board 2 press Down
   three times, then Enter: exactly one result is recorded (check the audit
   trail - no half points on the way). On board 2 again press Down to the
   blank option and Enter: the clear confirmation appears with focus on
   Cancel; Enter on Cancel puts focus back on board 2's select with its result
   unchanged. Do it again and choose "Yes, clear it": focus is back on board
   2's select, now empty. On the last board enter a result: focus stays there.
5. **Print variants.** Tab to "Pairings" under Print, press the context-menu
   key: the variants menu opens under the link, Down walks it, Enter opens
   one, Escape closes it back to the link.
6. **Settings.** Change the tournament name and press Save: "Saved." appears
   (and is announced - see NVDA 6). Tab through the tiebreak list: each arrow
   button's name says its tiebreak.
7. **Pickers.** Tab to the theme picker, Enter opens it, choose Slate; Escape
   closes it with focus on the trigger. Every focused control, in every theme,
   shows the accent ring; on the bracket map (`/t/:id/pairings/2/explain`)
   tab through the dots - none is hidden under the score gutter.
8. **Live display.** Open `/t/:id/live?display=1` on a round with more boards
   than fit: Tab to "Pause cycling", Enter pauses, the button reads "Resume
   cycling".
9. **Phone.** Enrol a phone (or a narrow window) at `/m`. Enter a wrong code:
   the error is read with the box. On `/m/results`, Tab to board 1's "1-0" and
   press Enter: about two seconds later board 1 leaves the list and focus is
   on the first result button of the board that took its place.

### NVDA - the arbiter's result entry

Browse mode unless stated. Once in English, once in Dutch.

1. Load `/t/:id/pairings`. `D` lists landmarks: banner, navigation "Main
   navigation", navigation "Account and display", main. `H` finds the page's
   one level-1 heading. The Pairings tab reads "current page".
2. `F` to the first result select (or Tab in focus mode): NVDA says "Result,
   board 1: <white> against <black>, combo box, <result>".
3. Press 1: NVDA says the new value; focus moves to board 2 and its name is
   read. Nothing else is announced over it.
4. On a board with a result, choose the blank option and Enter: NVDA reads
   "Cancel, button, Clear the recorded result (1-0) for this board?". Tab to
   "Yes, clear it" and hear the same question. Choose Cancel: focus returns to
   the select and NVDA reads its name again.
5. The round picker: the current round's button reads "toggle button,
   pressed", the others "not pressed".
6. Save something on a settings page: "Saved." is spoken once. Enter a bad
   value: the refusal is spoken.
7. Open a hand-edit confirmation (right-click a seat, choose an item - by mouse,
   see R2): NVDA says the dialog's title and "dialog"; Tab does not leave it;
   Escape returns to the page.
8. Accept an invitation from a second account: "You now have access to ..."
   is spoken once, politely, after the tournament's page loads.
9. On a phone with TalkBack or iOS VoiceOver (or NVDA on `/m/results`): enter
   a result; "Board 1: 1-0 saved" is spoken.
10. Note anything read in the wrong language, anything read twice, and any
    moment focus lands on the page itself.

### Look

- Every theme with every accent: secondary text, badges, the current tab and
  warning tags are legible; fields have an edge; the History page's old values
  still read as struck-through old values.
- The sign-in page: the subtitle and "Coming soon" line on the green panel.
- 860px wide and below: the publishing pill shows a distinct shape per state.
- `prefers-reduced-motion` on (Windows: Settings, Accessibility, Visual
  effects, Animation effects off): clicking a board's colour disc on the
  bracket map jumps rather than glides; entering a result jumps to the next
  board.
