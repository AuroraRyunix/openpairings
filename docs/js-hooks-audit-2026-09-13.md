# Browser-side JavaScript and LiveView hooks - audit of 2026-09-13

The 2026-09-05 audit listed this area under "What this audit never looked at".
This is that look: every line of `assets/js/app.js` and `assets/js/grid_keys.js`,
every `phx-hook`, every colocated and inline `<script>` under
`lib/pairings_engine_web/`, every `JS.dispatch`, and the server half of each
hook's events - the `handle_event` clauses its `pushEvent`s reach and the
`push_event`s it listens for. OpenResults and Ainalrami were out of scope.

Line numbers in the findings are at `344842c`, the commit the audit started
from, unless a commit is named.

## How it was checked

- **Read**, all of it, with the LiveView 1.2.9 client source
  (`deps/phoenix_live_view/assets/js/phoenix_live_view/view.ts`,
  `view_hook.ts`) open beside it for what the lifecycle actually does.
- **Server side**, with LiveView tests that push what the scripts push, and
  what anybody holding the socket could push instead:
  `test/pairings_engine_web/live/hook_events_test.exs` (8 tests).
- **Browser side**, in Node, because the repository has no JS test runner and
  this audit adds no JS dependency (`assets/package.json` does not exist). A
  reproduction script drove the real hooks - `app.js` objects sliced out of the
  file, the colocated hooks as the compiler extracted them to
  `_build/test/phoenix-colocated/` - through the lifecycle LiveView gives them,
  against the smallest stand-in objects they touch. 18 checks; 9 failed before
  the fixes and all 18 pass after. Kept out of the repository for the same
  reason the accessibility pass kept its harness out; what each check does is
  described under its finding.
- **In a real browser**, once, for the finding the rest depends on (F2): the dev
  server in local mode, the Players page, a column hidden, the LiveView crashed
  with a malformed event so that it rejoined in place. With the fix the hidden
  column stayed hidden and the server log shows `MOUNT` followed by
  `columns_loaded` and no new page `GET`; with the hook's `reconnected`
  switched off on the live instance, the same rejoin brought the column back.
- `esbuild` bundles `app.js` cleanly after the changes.

## Hook inventory

Thirteen hooks, five in `app.js` and eight colocated.

| Hook | Where | What it does |
|---|---|---|
| `ColumnPrefs` | `app.js`; `players_live.ex` `#players-grid`, `standings_live.ex` `#standings-table` | Sends the Display panel's column choice from `localStorage` (`columns_loaded`) and stores it again when the server says (`store_columns`). |
| `PlayerGrid` | `app.js`; `players_live.ex` `#players-table` | The Players grid: double-click edits (`edit_player`), right-click opens the Players Card (`show_card`), the Pr./Paid/Cat. cell and header menus (`set_absent_flag`, `set_all_absent_flag`, `set_paid`, `set_all_paid`, `toggle_category`, `set_all_category`, `sort`, `filter_category`), and the roving tabindex, with the decisions in `grid_keys.js`. |
| `AddPlayerShortcut` | `app.js`; `players_live.ex` page header | Ctrl+I (Cmd+I) pushes `add`, unless a modal is open. |
| `Flash` | `app.js`; `core_components.ex` `flash/1` | Says a flash through `#announcer` when it appears or its words change. |
| `DialogFocus` | `app.js`; 15 dialogs in `players_live`, `pairings_live`, `tournaments_live`, `categories_live`, `history_live`, `norms_live`, `settings_options_live`, `public_consent` | Focus into the dialog, Tab kept inside, focus back to the opener (or its id) when it closes. |
| `.BoardFit` | `live_round_live.ex` `#hall-boards` | Measures how many board rows the projector screen holds and pushes `rows_fit`. |
| `.KeepFocus` | `mobile_results_live.ex`, each phone board | Hands focus to the next board when the focused one leaves the list. |
| `.BlindResultEntry` | `pairings_live.ex`, each result `<select>` | 1/2/3 enter a result and move on; arrow-key walks held back and sent once; resyncs the value from `data-result` on every patch. |
| `.SwapArrows` | `pairings_live.ex` confirm modal | Draws an SVG arrow per player shown on both sides of a hand-edit confirmation. |
| `.PairingMenu` | `pairings_live.ex` pairings table and pool | Right-click, the context-menu key, Shift+F10, Enter or Space on a seat pushes `open_menu`; listens for `hand_edit_applied` to put focus on the edited board. |
| `.HandEditMenu` | `pairings_live.ex` `#hand-edit-menu` | Arrow keys through the menu, Tab pushes `close_menu`, focus back to the seat. |
| `.PrintMenu` | `pairings_live.ex`, three print links | A right-click (or keyboard) menu of the print variants, built by cloning the hidden links. |
| `.BracketMinimap` | `pairing_explain_live.ex` `#pe-minimap` | Keeps the overview strip's viewport in step with the bracket map's scroll, and seeks on click and drag. |

Not hooks, but in scope and read the same way:

- **Global listeners in `app.js`**: the bracket map's delegated click handler
  (pins, duo panels, facet filters); `announce()` and its two events
  (`pe:announce` from the connection flashes' `JS.dispatch`, `phx:announce`
  from `pairings_live.ex`); the MutationObserver that says `.ok-note` and
  `.error-note`; the dialog focus tracker; the deploy countdown
  (`phx:deploy-notice`), site notice (`phx:site-notice`) and version toast
  (`phx:app-version`), all pushed by `deploy_notice.ex`; top-bar popover
  click-away and Escape; `markPickers` and the `onBeforeElUpdated` that keeps
  the pickers' `aria-pressed`; the topbar progress bar; the dev-only live
  reload helpers.
- **Inline scripts**: the theme bootstrap in `root.html.heex` and the print
  pages' `window.print()` in `print_controller.ex`, both carrying the
  per-response CSP nonce.
- **`JS.dispatch`**: `pe:announce` (twice, `layouts.ex`), `phx:set-accent`,
  `phx:set-theme` (twice), each read by `app.js` or the theme bootstrap.

## Findings, worst first

| # | Severity | Where (at `344842c`) | Fixed in |
|---|---|---|---|
| F1 | Medium | `pairings_live.ex:2877`, `.BlindResultEntry` keydown | `714143a` |
| F2 | Medium | `app.js:38-49`, `ColumnPrefs` | `714143a` |
| F3 | Medium | `live_round_live.ex:843-886`, `.BoardFit` | `714143a` |
| F4 | Low | `players_live.ex:520,756,789,1103` and more; `pairings_live.ex:345-362,1873` | `2dab1da` |
| F5 | Low | `pairings_live.ex:723`, `coord/1` | `2dab1da` |
| F6 | Low | `pairings_live.ex:3267,3316`, `.PairingMenu` | `714143a` |
| F7 | Low | `app.js:967-972`, `deployBanner.show` | `714143a` |
| F8 | Low | `pairings_live.ex:3447-3457`, `.PrintMenu` | not fixed |
| F9 | Low | `mobile_results_live.ex:667-686`, `.KeepFocus` | not fixed |
| F10 | Info | `app.js` `CELL_MENUS`, deploy banner, version toast | not fixed |

### F1 - Ctrl+1/2/3 enters a result (Medium)

`.BlindResultEntry` maps the quick-entry keys by physical key (`e.code`), so
AZERTY's Shift-less top row works - and never looked at the modifiers. With a
board's result box focused, Ctrl+2 (switch to the second browser tab) recorded
1/2-1/2 on that board, wrote the audit row, moved focus to the next board and
`preventDefault`ed the shortcut so the tab did not switch. Alt+digit, Cmd+digit
and AltGr+2/3 on AZERTY (`~`, `#`, sent as Ctrl+Alt) did the same. A result
written by a keystroke the arbiter meant for the browser is the worst thing on
this list, because nothing on screen says it happened unless they look at that
board.

Fix: Ctrl, Alt and Meta leave the key alone; Shift is still allowed, which
AZERTY needs. Reproduction: the hook's keydown with `code: "Digit2"` and each
modifier records nothing and does not `preventDefault`; plain `2` and Shift+`1`
still record.

### F2 - The column choice is lost on every reconnect (Medium)

`ColumnPrefs` sent the stored columns in `mounted` only. A reconnect - a
deploy's restart, a dropped network, a laptop waking, a LiveView crash - makes
the server mount afresh, so `visible` is back to the defaults (`nil`, all
columns, on Standings). But on a rejoin LiveView patches the hooked element in
place and calls only `disconnected` and `reconnected` on its hook
(`view.ts` `applyJoinPatch` → `triggerReconnected`; `displayError` →
`showLoader()` → `__disconnected`), never `mounted` again. The Players grid
silently went back to the default columns, and the standings to all of them,
until the next page change.

Fix: `reconnected()` sends the stored columns again. Reproduction: in Node, a
second `columns_loaded` after `disconnected`/`reconnected`, and still nothing
thrown with storage blocked; in the browser, as described above.

The desktop copy reconnects after every sleep, so this is the common case there,
not the rare one.

### F3 - The projector view falls back to twelve boards a page after a reconnect (Medium)

`.BoardFit` caches the row count it last pushed (`lastRows`) and only pushes a
different one. After a reconnect the server is back on
`@default_rows_per_page` (12), the hook still holds the measured number, and
`updated()` re-measures the same number and sends nothing. A hall screen left
running through a server update showed twelve boards a page - too many or too
few for the glass - until someone resized the window. Same lifecycle as F2.

Fix: `reconnected()` forgets `lastRows` and reports. Reproduction: in Node, no
second `rows_fit` on an ordinary patch, one after `reconnected`.

### F4 - Hook payloads crash their LiveView (Low)

A `pushEvent` payload is written by whoever holds the socket. These crashed the
page on a value no script of ours sends, which drops whatever the arbiter had
open there and is a self-inflicted outage for anyone holding their own session:

- `sort` with a key no column has: stored, then `sort_value/2` had no clause
  (`FunctionClauseError` in `assign_players/1`).
- `toggle_category` and `set_all_category` with a name that is not a string:
  `Tournaments.toggle_player_category/4` and `set_all_players_category/3` guard
  `is_binary(name)` and raise rather than refuse.
- `show_card` with an id that is not a whole number: `String.to_integer/1`.
- Every Players grid menu event with a key missing: no matching clause.
- `open_menu` without `x`/`y` (`MatchError`), with a `player-id` or
  `pairing-id` that is not a number (`String.to_integer/1`), or with a `scope`
  `pairing_menu/1` has no branch for (`CaseClauseError` in the render).

`rows_fit`, `columns_loaded` (both pages), `edit_player`, `set_absent_flag`,
`set_paid`, `set_all_paid`, `set_all_absent_flag`, `filter_category` with a
present key and `close_menu` already refused or tolerated bad values: ids go
through `Tournaments.get_player/2`, which is scoped to the tournament and
returns nil for anything unparseable, paid statuses and category names are
checked against the allowed set in `Tournaments`.

Fix: the sort key is checked against the columns `sort_value/2` knows (plus
`cat:<name>`); category names must be strings; `show_card` parses its id;
missing keys fall to no-op clauses; `open_menu` accepts only the four scopes
and whole-number ids, and opens nothing otherwise. Tests:
`hook_events_test.exs` - its seven crash tests all failed before the fix (the
eighth, for F5, came with that fix).

### F5 - A keyboard-opened hand-edit menu opens in the corner (Low)

`open_menu`'s position went through `coord/1`, which took integers and strings
and sent everything else to 0. The keyboard path places the menu at the seat's
`getBoundingClientRect()`, which is fractional under display scaling or zoom -
the normal case on a Windows laptop at 125% - so the menu opened at the top-left
of the window instead of under the seat. It still took focus, so it was usable,
just far from where the eye was. Only the keyboard path, which is unreleased, is
affected; a mouse `clientX` is whole.

Fix: floats are rounded. Test: `open_menu` at `x: 120.5, y: 340.25` renders
`left: 121px; top: 340px`.

### F6 - Space on a seat could choose the menu's first item (Low)

`.PairingMenu` opened the hand-edit menu on Space's keydown, and
`.HandEditMenu` focuses the first item as soon as the server has drawn it -
well inside one key press on a local copy. Space's keyup then lands on that
item. The Players grid already waits for the keyup for exactly this reason
(`grid_keys.js`, `{open: "keyup"}`). In a browser that activates a focused
button on Space's keyup, that chose "Swap with..." (arms a swap) or, on a fully
vacant board, "Hide this board" (an immediate, reversible write). Which
browser engines activate a button on a keyup whose keydown went elsewhere was
not verified in any of them; the fix removes the question.

Fix: `seatKeyAction` returns `"menu-keyup"` for Space and the hook opens on the
matching keyup, as the grid does; Enter still opens at once and Space on an
armed seat still completes. Reproduction: nothing pushed on keydown, `open_menu`
with `keyboard: true` on keyup.

### F7 - The deploy countdown is read out again on every page (Low)

Every LiveView mount pushes `deploy-notice` with the current deadline
(`deploy_notice.ex`), and `deployBanner.show` reset `announcedTier`, so a live
navigation during a countdown made a screen reader say "Server update: in 4:12
- ..." again on every page, against the banner's own stated intent (said when
it appears and when it escalates).

Fix: the same deadline arriving while the banner is up keeps the tier already
said; a new deadline or a banner that was hidden is said again. Reproduction:
three `show()`s of one deadline announce once, a new deadline announces.

### F8 - The print menu may not take focus from the keyboard in every browser (Low, not fixed)

`.PrintMenu` decides "opened from the keyboard" from the `contextmenu` event's
own shape (`pointerType === ""` or a (0, 0) position), without the keydown
record `PlayerGrid` and `.PairingMenu` use first. A browser whose keyboard
`contextmenu` has neither opens the menu at the link but leaves focus on the
link. It is still reachable - the document keydown handler moves into the menu
on Down - so this was left alone rather than changed without a browser to see
the difference in. Worth aligning with the other two if a person confirms it.

### F9 - `.KeepFocus` can move focus after a remote result (Low, not fixed)

The phone page remembers the last board that held focus. If focus later falls
to `<body>` (a tap on empty space) and that board then leaves the list because
another phone entered its result, `destroyed` moves focus to the next board's
first button, which scrolls it into view. A narrow case; telling "focus fell to
body because this board left" from "focus was already on body" needs state the
hook cannot see after the board is gone, and a wrong guess loses the handoff
the hook exists for.

### F10 - Script-built text is English only (Info, not fixed)

The Players grid cell and header menus (`CELL_MENUS`: "Absent", "Add U16",
"Group by ..."), the deploy banner's countdown sentences and "Updated to v..."
are written in `app.js`, so a Dutch page shows them in English. The grid's
column labels next to them are English in `players_live.ex` too, so this is
part of that page's translation state rather than a script defect. Moving the
words to gettext means rendering them into data attributes; left for whoever
next works on the page's translations.

## Checked and found sound

- **No HTML from data.** No `innerHTML`, `insertAdjacentHTML`, `outerHTML`,
  `document.write`, `eval` or `new Function` anywhere in `assets/js` or
  `lib/`. Every script-built label is `textContent` (cell menus, banners,
  announcer); `.PrintMenu` clones server-rendered links; `.SwapArrows` builds
  SVG with `createElementNS`/`setAttribute` and reads player names only to
  compare them. Player, club and tournament names reach scripts only through
  `textContent` and `JSON.parse` of server-encoded data attributes, both
  guarded.
- **CSP.** `script-src 'self' 'nonce-...'` holds: the two inline scripts carry
  the nonce, colocated hooks are bundled, and LiveView's `JS` commands are data,
  not code. Nothing needs `'unsafe-inline'` for scripts. The scripts set styles
  through the CSSOM (`el.style.left = ...`), which `style-src` does not govern;
  the existing `style-src 'unsafe-inline'` is for the templates' `style`
  attributes, as `csp.ex` already says.
- **No `window.open`, `postMessage`, clipboard, `createObjectURL`, download or
  `beforeunload` code.** Print and export links are plain `target="_blank"`
  anchors, which browsers open with `noopener` implied.
- **The desktop build is not a webview.** `rel/windows/launcher.c` opens the
  local URL in the default browser with `ShellExecuteW`, so every script runs
  in an ordinary browser tab; the webview concerns in the brief do not apply.
  What does apply is reconnecting after sleep - F2 and F3.
- **Listener lifecycle.** Every document- and window-level listener a hook adds
  is removed in `destroyed` (`PlayerGrid`, `AddPlayerShortcut`, `.PrintMenu`,
  `.SwapArrows` and its timer, `.BoardFit`, `.BracketMinimap`); element-level
  listeners die with their element; `handleEvent` callbacks are removed by
  LiveView itself (`__cleanup__`). The module-level listeners in `app.js` are
  added once per page load and delegate, so patches cannot duplicate them. The
  deploy banner and site notice clear their intervals before setting new ones.
- **localStorage.** Every access in `app.js` and the theme bootstrap is inside
  `try`. The one unguarded touch is LiveView's own constructor
  (`window.localStorage` in `live_socket.ts`), which throws only where the
  browser blocks site data for the app's own origin - where the session cookie
  is blocked too and nothing could work anyway.
- **`JSON.parse`**: all three uses are guarded (`ColumnPrefs`, `readJsonAttr`).
- **The keyboard grid** (`grid_keys.js`, `PlayerGrid`): position is remembered
  by player id and column key, restored after every patch, and focus is only
  moved when it was in the grid before the patch; a vanished row is announced.
  Alt and Meta combinations pass through, Ctrl only where the grid defines it,
  Shift+F10 and the context-menu key are recorded rather than swallowed. No text
  is typed into the grid, so IME and dead-key composition never reach its
  handlers (dead keys arrive as `"Dead"`, which it ignores; AltGr arrives with
  `altKey` and is ignored by `AddPlayerShortcut`). Only one grid exists per
  page, but nothing in the hook assumes it: each instance owns its popup and its
  document listeners check their own popup. `keepCellMenuOnScreen` measures the
  popup after it is in the page, and an open popup owns the arrow keys so the
  grid and the menu never both act.
- **Timing.** The remaining timers are deliberate and documented where they
  are: `announce`'s 100 ms clear-then-fill, `.SwapArrows`' `setTimeout(0)`
  (not rAF, which a background tab never runs), `DialogFocus`' one frame and
  `hand_edit_applied`'s two, which LiveView queues in a fixed order.
- **Server pushes the scripts listen for** (`store_columns`, `announce`,
  `hand_edit_applied`, `deploy-notice`, `site-notice`, `app-version`) all send
  the shapes their listeners read.

## Outside this area, noticed on the way

Not hook events, so not changed here, but the same class as F4 - a
`phx-click`/`phx-value` payload is just as writable:
`players_live.ex` `toggle_column` with no `key` (no clause - it was the crash
used to force the rejoin in the browser check), `pick` with a non-numeric
`fide-id` when search results are showing (`String.to_integer/1`);
`pairings_live.ex` `arm_swap`, `pick_swap_target`, `stage_vacate`,
`stage_bye`, `stage_fill` (`String.to_integer/1`); `standings_live.ex`
`publish_standings` and `unpublish_standings` (`String.to_integer/1`). Each is
a crash of the sender's own LiveView, not a write.
