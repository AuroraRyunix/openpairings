// The Players grid's keyboard model, as pure functions: which key means what,
// where a move lands, and which cell a re-render puts the keyboard back on.
//
// No DOM in here on purpose. `PlayerGrid` in app.js reads the table, asks
// these, and writes the answer back; that split is what lets the decisions be
// exercised with plain Node (there is no JS test runner in this repo) while
// the DOM half stays a thin shell. See docs/accessibility-2026-09-13.md, R1.

// The keys that open a context menu from the keyboard. The browser follows
// both with a `contextmenu` event of its own; this only tells the handler of
// that event that no pointer was involved.
export const isMenuKey = (e) => e.key === "ContextMenu" || (!!e.shiftKey && e.key === "F10")

// What a keydown on a grid cell asks for:
//
//   {move: "left" | "right" | "up" | "down" | "rowStart" | "rowEnd" |
//          "gridStart" | "gridEnd" | "pageUp" | "pageDown"}
//   {open: "now"}     Enter on a cell with a menu - open it at once
//   {open: "keyup"}   Space on a cell with a menu - open it when the key comes
//                     back up, or the keyup would land on the menu's first
//                     item and choose it
//   null              not the grid's business: Enter on a header, a name or
//                     the Remove button does what it always did
//
// `cell.hasMenu` is whether the cell is one player's Pr./Paid/Cat. cell.
export function gridKeyAction(e, cell) {
  if (e.altKey || e.metaKey) return null

  const ctrl = e.ctrlKey

  switch (e.key) {
    case "ArrowLeft": return ctrl ? null : {move: "left"}
    case "ArrowRight": return ctrl ? null : {move: "right"}
    case "ArrowUp": return ctrl ? null : {move: "up"}
    case "ArrowDown": return ctrl ? null : {move: "down"}
    case "Home": return {move: ctrl ? "gridStart" : "rowStart"}
    case "End": return {move: ctrl ? "gridEnd" : "rowEnd"}
    case "PageUp": return ctrl ? null : {move: "pageUp"}
    case "PageDown": return ctrl ? null : {move: "pageDown"}
    case "Enter": return !ctrl && !e.shiftKey && cell.hasMenu ? {open: "now"} : null
    case " ": return !ctrl && !e.shiftKey && cell.hasMenu ? {open: "keyup"} : null
    default: return null
  }
}

export const PAGE_ROWS = 10

// Where a move from `{r, c}` lands. `widths[r]` is the number of cells in row
// r (the header row included, as row 0). Never leaves the grid: a move off an
// edge stays put, the way the ARIA grid pattern asks.
export function movePosition({r, c}, move, widths) {
  const last = widths.length - 1
  if (last < 0) return {r: 0, c: 0}

  const clampCol = (row, col) => Math.max(0, Math.min(col, widths[row] - 1))
  const clampRow = (row) => Math.max(0, Math.min(row, last))

  switch (move) {
    case "left": return {r, c: clampCol(r, c - 1)}
    case "right": return {r, c: clampCol(r, c + 1)}
    case "up": return {r: clampRow(r - 1), c: clampCol(clampRow(r - 1), c)}
    case "down": return {r: clampRow(r + 1), c: clampCol(clampRow(r + 1), c)}
    case "pageUp": return {r: clampRow(r - PAGE_ROWS), c: clampCol(clampRow(r - PAGE_ROWS), c)}
    case "pageDown": return {r: clampRow(r + PAGE_ROWS), c: clampCol(clampRow(r + PAGE_ROWS), c)}
    case "rowStart": return {r, c: 0}
    case "rowEnd": return {r, c: widths[r] - 1}
    case "gridStart": return {r: 0, c: 0}
    case "gridEnd": return {r: last, c: widths[last] - 1}
    default: return {r, c}
  }
}

// After a re-render: where the active cell is now.
//
// `active` is what the hook remembered - `{row, col, r, c}`, the row by its
// key (a player id, or "head" for the header row) and the column by its key,
// with the indexes it last had as the fallback. `rows` is the table as it is
// now, `[{key, cols: [colKey, ...]}]`.
//
// The row is found by its key wherever a sort or someone else's change moved
// it. When it is gone - filtered out, deleted - the keyboard goes to the row
// that took its place (or the new last row), and `lost` says so, so the hook
// can tell a screen reader. A column hidden from the Display panel falls back
// the same way, without `lost`: the player is still there.
export function restorePosition(active, rows) {
  if (!rows.length) return null

  let r = rows.findIndex((row) => row.key === active.row)
  const lost = r === -1
  if (lost) r = Math.max(0, Math.min(active.r, rows.length - 1))

  const cols = rows[r].cols
  let c = cols.indexOf(active.col)
  if (c === -1) c = Math.max(0, Math.min(active.c, cols.length - 1))

  return {r, c, lost}
}

// A sentence rendered by the server with `%[name]`-style holes (the same
// square brackets `rich_text` uses, so gettext leaves them alone), filled in.
export const fillTemplate = (template, values) =>
  Object.entries(values).reduce(
    (text, [key, value]) => text.split(`%[${key}]`).join(value),
    template || ""
  )
