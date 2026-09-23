// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/pairings_engine"
import topbar from "../vendor/topbar"
import {isMenuKey, gridKeyAction, movePosition, restorePosition, fillTemplate} from "./grid_keys"

// Persists the player-grid column selection (the "Display" panel) in localStorage.
//
// Both calls are guarded the same way the theme bootstrap and the version
// toast (below) already are: localStorage.getItem/setItem THROW rather than
// returning null when a browser blocks or partitions storage (Safari's
// default for a cross-origin frame, or any browser with site data disabled).
// Unguarded, that throw would happen inside `mounted()` and take the whole
// hook down with it - on the Players grid and the Standings page, whichever
// mounts this - rather than just silently skipping the remembered columns.
//
// Sent again on `reconnected`: a reconnect (a deploy's restart, a dropped
// network, a laptop waking from sleep) mounts the LiveView afresh with the
// default columns, but LiveView patches this element in place and does not
// call `mounted` a second time - so without it the grid quietly went back to
// the defaults until the next page change.
const ColumnPrefs = {
  mounted() {
    this.sendStored()
    this.handleEvent("store_columns", ({columns}) => {
      try { localStorage.setItem("pairingsengine.playerColumns", JSON.stringify(columns)) } catch (_) {}
    })
  },
  reconnected() { this.sendStored() },
  sendStored() {
    let stored = null
    try { stored = localStorage.getItem("pairingsengine.playerColumns") } catch (_) {}
    if (stored) {
      try { this.pushEvent("columns_loaded", {columns: JSON.parse(stored)}) } catch {}
    }
  },
}

// Double-click a player row to edit it, right-click for the Players Card.
// One listener on the table (event delegation) rather than one per row.
//
// Two columns opt out of the Players Card and get their own little menu
// instead, on the cell for one player and on the column header for every
// player at once. They are described once here and driven by the same
// code below, so a third one is a table entry rather than another copy of
// the popup, the outside-click handling and the teardown.
const CELL_MENUS = {
  // Whole-tournament presence only -- per-round marks stay a job for the
  // edit dialog. See the `cell(entry, "pr")` doc comment in
  // players_live.ex.
  pr: {
    event: "set_absent_flag",
    bulkEvent: "set_all_absent_flag",
    items: [["Absent", "true"], ["Present", "false"]],
    bulkItems: [["All Absent", "true"], ["All Present", "false"]],
  },
  // Registration fee, SWAR 5.20. Three states, no per-round dimension.
  paid: {
    event: "set_paid",
    bulkEvent: "set_all_paid",
    items: [["Paid", "paid"], ["Not paid", "nopaid"], ["Gratis", "gratis"]],
    bulkItems: [["All Paid", "paid"], ["All Not paid", "nopaid"], ["All Gratis", "gratis"]],
  },
  // Prize categories. The first of these three whose items cannot be a
  // literal: the categories belong to the tournament, so the list has to be
  // read out of the DOM at open time. `data-categories` on the grid is the
  // vocabulary, `data-tags` on the cell is that one player's set.
  //
  // A player is in SEVERAL, so every item is a toggle of ONE name and the
  // rest of the set is left alone -- a menu that replaced the whole set
  // would be the multi-value column pretending to be single-valued again.
  //
  // The header menu carries the two things a multi-valued column can be
  // ordered by honestly, and neither is "sort by categories": grouping on
  // whether a player carries one (a boolean, so a real order) and filtering
  // to one (not a sort at all -- it changes which rows exist). Left click on
  // the header still sorts, by the single pairing category.
  cat: {
    event: "toggle_category",
    bulkEvent: "set_all_category",
    dynamic: true,
    // Several names per player, so the menu survives a pick - see the item
    // click handler in openCellMenu.
    multi: true,
    items: (categories, tags) =>
      categories.map((c) =>
        tags.includes(c)
          ? [`Remove ${c}`, {name: c, value: "false"}]
          : [`Add ${c}`, {name: c, value: "true"}]
      ),
    bulkItems: (categories) => [
      ...categories.flatMap((c) => [
        [`Group by ${c}`, {sort: "cat:" + c}],
        [`Show only ${c}`, {filter: c}],
        [`Add ${c} to everyone`, {name: c, value: "true"}],
        [`Remove ${c} from everyone`, {name: c, value: "false"}],
      ]),
      ["Show all rows", {filter: ""}],
      ["Sort by pairing category", {sort: "cat"}],
    ],
  },
}

// A dynamic menu entry that only changes what the page SHOWS - a sort or a
// filter - rather than writing to the player. Those close the menu like any
// other one-shot pick; only the writes on a multi-valued column keep it open.
const isViewChange = (value) =>
  typeof value === "object" && value !== null && ("sort" in value || "filter" in value)

function readJsonAttr(el, name) {
  if (!el) return []
  try {
    const parsed = JSON.parse(el.dataset[name] || "[]")
    return Array.isArray(parsed) ? parsed : []
  } catch {
    return []
  }
}

const CELL_MENU_COLS = Object.keys(CELL_MENUS)
const cellMenuSelector = (tag) => CELL_MENU_COLS.map((c) => tag + "[data-col=\"" + c + "\"]").join(", ")

// The grid is one stop in the Tab order - an ARIA grid with a roving tabindex.
// Every cell (or the one control inside it: a header's sort button, a name, a
// Remove button) is rendered `tabindex="-1"` except the first header cell's
// button; the hook moves the single `tabindex="0"` with the arrow keys, Home
// and End (Ctrl for the whole grid) and Page Up/Down. Enter or Space on one
// player's Pr., Paid or Cat. cell opens that cell's menu - the context-menu key
// and Shift+F10 already did, through the `contextmenu` listener below.
//
// A LiveView patch re-renders rows under the keyboard (a result entered in
// another tab re-ranks everyone), so the active cell is remembered as {player
// id, column}, not as a DOM node, and put back after every patch. The
// decisions live in grid_keys.js as pure functions.
const gridFocusTarget = (cell) => cell.querySelector(".th-sort, [data-edit-player], button") || cell

const PlayerGrid = {
  mounted() {
    // Double-clicking must not text-select the player name; e.detail > 1
    // means this mousedown is part of a double/triple click. Plain drags
    // still select text normally.
    this.el.addEventListener("mousedown", (e) => {
      if (e.detail > 1) e.preventDefault()
    })

    this.active = null
    this.keyMenuAt = 0
    this.spaceOn = null

    // Focus arriving anywhere in the grid - a click, a Tab, a script - makes
    // that cell the active one, so the mouse and the keyboard never disagree
    // about where the user is.
    this.el.addEventListener("focusin", (e) => {
      const cell = e.target.closest("th, td")
      if (cell && this.el.contains(cell)) this.remember(cell)
    })

    this.el.addEventListener("keydown", (e) => {
      if (isMenuKey(e)) { this.keyMenuAt = Date.now(); return }
      // An open cell menu owns the arrow keys (see onCellMenuDocKeydown).
      if (this.cellPopup) return

      const cell = e.target.closest("th, td")
      if (!cell || !this.el.contains(cell)) return

      const action = gridKeyAction(e, {hasMenu: this.cellHasMenu(cell)})
      if (!action) return
      e.preventDefault()

      if (action.move) {
        const at = this.position(cell)
        const to = movePosition(at, action.move, this.widths())
        this.activate(this.cellAt(to), true)
      } else if (action.open === "now") {
        this.openFromKeyboard(cell)
      } else {
        this.spaceOn = cell
      }
    })

    this.el.addEventListener("keyup", (e) => {
      if (e.key !== " " || !this.spaceOn) return
      const cell = this.spaceOn
      this.spaceOn = null
      if (e.target.closest("th, td") === cell) this.openFromKeyboard(cell)
    })
    this.el.addEventListener("dblclick", (e) => {
      const tr = e.target.closest("tr[data-player-id]")
      if (!tr) return
      // On a cell that has one, the first of the two clicks opened its
      // menu; leaving it up would float it over the edit dialog.
      this.closeCellMenu()
      this.pushEvent("edit_player", {id: tr.dataset.playerId})
    })
    // The keyboard's double-click: Enter or Space on a player's name, which
    // is focusable for exactly this (see the grid in players_live.ex).
    this.el.addEventListener("keydown", (e) => {
      const name = e.target.closest("[data-edit-player]")
      if (!name || (e.key !== "Enter" && e.key !== " ")) return
      e.preventDefault()
      this.pushEvent("edit_player", {id: name.dataset.editPlayer})
    })
    this.el.addEventListener("contextmenu", (e) => {
      // A menu opened from the keyboard - the context-menu key or Shift+F10
      // on a focused header button or cell - has no pointer to open at, and
      // has to take focus, or nobody without a mouse can use it. The keydown
      // just before says so most reliably; the event's own shape is the
      // fallback for a browser that sends it without one.
      const fromKeyboard =
        Date.now() - this.keyMenuAt < 1000 || e.pointerType === "" || (e.clientX === 0 && e.clientY === 0)
      this.keyMenuAt = 0
      const at = (el) => {
        if (!fromKeyboard) return [e.clientX, e.clientY]
        const box = el.getBoundingClientRect()
        return [box.left, box.bottom]
      }

      // A COLUMN HEADER in CELL_MENUS gets the bulk version - every player
      // in the tournament at once; left click on the same header still
      // sorts. Checked before the row lookup below, since a header cell
      // sits in <thead> with no tr[data-player-id] ancestor.
      const header = e.target.closest(cellMenuSelector("th"))
      if (header) {
        e.preventDefault()
        const [x, y] = at(header)
        this.openCellMenu(x, y, header.dataset.col, null, fromKeyboard)
        return
      }

      const tr = e.target.closest("tr[data-player-id]")
      if (!tr) return
      e.preventDefault()

      // Those columns' cells get their own tiny menu instead of the
      // Players Card. Every other cell on the row keeps the existing
      // Players Card behaviour.
      const cell = e.target.closest(cellMenuSelector("td"))
      if (cell) {
        const [x, y] = at(cell)
        this.openCellMenu(x, y, cell.dataset.col, tr.dataset.playerId, fromKeyboard)
        return
      }

      this.pushEvent("show_card", {id: tr.dataset.playerId})
    })

    // Left-click on one of those cells opens the same little menu -
    // right-click isn't discoverable (no visible affordance, doesn't exist
    // at all on touch), so a plain click gets it too. Left-click elsewhere
    // on the row is unclaimed today, so this can't collide with anything.
    this.el.addEventListener("click", (e) => {
      const skip = this.skipOpenFor
      this.skipOpenFor = null

      const cell = e.target.closest(cellMenuSelector("td"))
      if (!cell) return
      const tr = e.target.closest("tr[data-player-id]")
      if (!tr) return

      // The second click of a double-click, which is the gesture for
      // opening the edit dialog - not a request for this menu.
      if (e.detail > 1) return

      // This click already closed the menu on its way down (see
      // onCellMenuDocMousedown). Clicking the cell a menu came from means
      // "put it away", so re-opening here would make it blink instead.
      if (skip && skip.col === cell.dataset.col && skip.playerId === tr.dataset.playerId) return

      this.openCellMenu(e.clientX, e.clientY, cell.dataset.col, tr.dataset.playerId)
    })

    this.onCellMenuDocMousedown = (e) => {
      if (!this.cellPopup || this.cellPopup.contains(e.target)) return

      // Remember whether this press landed on the very cell the menu came
      // from, so the `click` that follows can tell "close it" apart from
      // "open a different one".
      const el = e.target instanceof Element ? e.target : null
      const cell = el?.closest(cellMenuSelector("td"))
      const tr = el?.closest("tr[data-player-id]")
      this.skipOpenFor =
        cell && tr && this.cellMenuAt && this.cellMenuAt.playerId === tr.dataset.playerId &&
          this.cellMenuAt.col === cell.dataset.col
          ? {col: cell.dataset.col, playerId: tr.dataset.playerId}
          : null

      this.closeCellMenu()
    }
    this.onCellMenuDocKeydown = (e) => {
      if (!this.cellPopup) return

      if (e.key === "Escape") {
        this.closeCellMenu(true)
        return
      }

      // Up and Down walk the items, Tab leaves the menu the way it came.
      const items = Array.from(this.cellPopup.querySelectorAll("button"))
      const index = items.indexOf(document.activeElement)
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        if (!items.length) return
        e.preventDefault()
        const step = e.key === "ArrowDown" ? 1 : -1
        items[(index + step + items.length) % items.length].focus()
      } else if (e.key === "Tab" && index >= 0) {
        e.preventDefault()
        this.closeCellMenu(true)
      }
    }
    document.addEventListener("mousedown", this.onCellMenuDocMousedown)
    document.addEventListener("keydown", this.onCellMenuDocKeydown)
  },

  // ---- the roving tabindex ----

  rows() { return Array.from(this.el.rows) },

  widths() { return this.rows().map((row) => row.cells.length) },

  position(cell) {
    const row = cell.parentElement
    return {r: this.rows().indexOf(row), c: Array.prototype.indexOf.call(row.cells, cell)}
  },

  cellAt({r, c}) {
    const row = this.rows()[r]
    return row && row.cells[c]
  },

  cellHasMenu(cell) {
    return cell.tagName === "TD" && cell.dataset.col in CELL_MENUS && !!cell.closest("tr[data-player-id]")
  },

  // The active cell, as keys that survive a re-render: the row by its player
  // id ("head" for the header row), the column by `data-grid-col`, and the
  // indexes it had, for when either is gone. The name is kept for saying so.
  remember(cell) {
    const row = cell.parentElement
    const {r, c} = this.position(cell)
    this.active = {
      row: row.dataset.playerId || "head",
      col: cell.dataset.gridCol,
      r,
      c,
      name: row.querySelector("[data-edit-player]")?.textContent.trim() || null,
    }
    this.syncTabStop(cell)
  },

  activate(cell, focus) {
    if (!cell) return
    this.remember(cell)
    if (focus) {
      const target = gridFocusTarget(cell)
      target.focus()
      target.scrollIntoView?.({block: "nearest", inline: "nearest"})
    }
  },

  // Exactly one `tabindex="0"` in the grid, on `cell`'s focus target.
  syncTabStop(cell) {
    const target = gridFocusTarget(cell)
    this.el.querySelectorAll('[tabindex="0"]').forEach((el) => { if (el !== target) el.tabIndex = -1 })
    target.tabIndex = 0
  },

  rowKeys() {
    return this.rows().map((row) => ({
      key: row.dataset.playerId || "head",
      cols: Array.from(row.cells, (cell) => cell.dataset.gridCol),
    }))
  },

  openFromKeyboard(cell) {
    const box = cell.getBoundingClientRect()
    this.openCellMenu(box.left, box.bottom, cell.dataset.col, cell.parentElement.dataset.playerId, true)
  },

  // A patch may have re-ordered, re-used or removed the row under the
  // keyboard - LiveView patches rows in place, so the focused <td> can come
  // back holding somebody else. The server's render also puts every
  // `tabindex` back as it drew them. So: find the remembered player and
  // column again, make that the tab stop, and - only when focus was in the
  // grid - put focus there. When that player's row is gone, focus goes to the
  // row that took its place and the announcer says whose row went.
  beforeUpdate() {
    this.hadFocus = this.el.contains(document.activeElement)
  },

  updated() {
    // A menu left open over the row that just changed (a category toggle)
    // is re-drawn from the patched cell, so its labels are never stale.
    if (this.cellMenuRedraw) {
      this.cellMenuRedraw = false
      this.redrawCellMenu()
    }

    if (!this.active) {
      return
    }

    const at = restorePosition(this.active, this.rowKeys())
    const cell = at && this.cellAt(at)
    if (!cell) {
      return
    }

    const goneName = at.lost && this.active.row !== "head" ? this.active.name : null
    this.remember(cell)

    if (!this.hadFocus) {
      return
    }

    const target = gridFocusTarget(cell)
    if (document.activeElement !== target) {
      target.focus({preventScroll: true})
    }
    if (goneName) {
      announce(fillTemplate(this.el.dataset.rowGone, {name: goneName}))
    }
  },

  // `playerId` is null for the column-header (bulk, every player) menu, a
  // player id string for one row's cell - the two push different server
  // events but share the same little popup. `col` picks the entry in
  // CELL_MENUS, which is the only place the labels and event names live.
  //
  // The bulk menu keeps its "All ..." wording - it genuinely means
  // everyone. The per-row menu is about the one player whose cell was
  // clicked, so the plain wording reads right there instead of implying it
  // touches every player too.
  //
  // `refresh` re-draws a menu that is already open, in place, after the
  // server has patched the row under it - see the `multi` note on the item
  // click below. It keeps the opener and the highlighted item, so a refresh
  // is not a close followed by an open.
  openCellMenu(x, y, col, playerId, takeFocus = false, refresh = false) {
    const menu = CELL_MENUS[col]
    if (!menu) return

    const bulk = playerId === null
    const items = menu.dynamic
      ? this.dynamicCellMenuItems(menu, col, bulk, playerId)
      : bulk
        ? menu.bulkItems
        : menu.items

    // Nothing to offer - a tournament with no categories defined yet. An
    // empty popup is a bare box that appears and goes again on the next
    // click, which reads as a glitch rather than as "there is nothing here".
    if (!items.length) {
      this.closeCellMenu()
      return
    }

    const opener = refresh ? this.cellMenuOpener : null
    const keptIndex =
      refresh && this.cellPopup?.contains(document.activeElement)
        ? Array.from(this.cellPopup.querySelectorAll("button")).indexOf(document.activeElement)
        : -1

    this.refreshingCellMenu = refresh
    this.closeCellMenu()
    this.refreshingCellMenu = false

    // Where focus goes back to when the menu closes from the keyboard.
    this.cellMenuOpener = refresh ? opener : document.activeElement

    // Which cell this menu belongs to, so a second click on that same cell
    // closes it instead of re-opening it, and so a patch can redraw it.
    this.cellMenuAt = {x, y, col, playerId}

    const popup = document.createElement("div")
    popup.className = "print-menu-popup"
    popup.setAttribute("role", "menu")
    popup.style.left = `${x}px`
    popup.style.top = `${y}px`

    for (const [label, value] of items) {
      const btn = document.createElement("button")
      btn.type = "button"
      btn.className = "print-menu-item"
      btn.setAttribute("role", "menuitem")
      btn.textContent = label
      btn.addEventListener("click", () => {
        // A dynamic entry's value is already the whole payload (it names
        // which category, and whether this is a sort, a filter or a write);
        // a static one is a bare value the server reads as `value`.
        if (typeof value === "object") {
          if ("sort" in value) this.pushEvent("sort", {key: value.sort})
          else if ("filter" in value) this.pushEvent("filter_category", {name: value.filter})
          else this.pushEvent(bulk ? menu.bulkEvent : menu.event, bulk ? value : {id: playerId, ...value})
        } else if (bulk) {
          this.pushEvent(menu.bulkEvent, {value})
        } else {
          this.pushEvent(menu.event, {id: playerId, value})
        }

        // A single-valued column is done in one pick, so its menu closes.
        // A `multi` one (categories) is not: a player is usually in more
        // than one, and closing after every single toggle means re-opening
        // the menu for each name. It stays open and `updated()` re-draws it
        // from the patched row, so "Add Junior" becomes "Remove Junior"
        // where it stands.
        if (menu.multi && !bulk && !isViewChange(value)) this.cellMenuRedraw = true
        else this.closeCellMenu()
      })
      popup.appendChild(btn)
    }

    document.body.appendChild(popup)
    this.cellPopup = popup
    this.keepCellMenuOnScreen(popup, x, y)

    if (keptIndex >= 0) {
      popup.querySelectorAll("button")[Math.min(keptIndex, items.length - 1)]?.focus()
    } else if (takeFocus) {
      popup.querySelector("button")?.focus()
    }
  },

  // Re-draw an open row menu after the server patched the grid under it.
  redrawCellMenu() {
    if (!this.cellPopup || !this.cellMenuAt) return
    const {x, y, col, playerId} = this.cellMenuAt
    this.openCellMenu(x, y, col, playerId, false, true)
  },

  // Measured once it is in the page rather than assumed, because its size
  // depends on what it holds - a category menu grows with the tournament's
  // categories. Opened near the right or bottom edge it opens leftward or
  // upward from the pointer instead of spilling past the window, and a menu
  // taller than the window scrolls inside itself. PairingMenu can use fixed
  // numbers only because its menu is always the same size.
  keepCellMenuOnScreen(popup, x, y) {
    const margin = 8
    const maxHeight = window.innerHeight - 2 * margin
    if (popup.getBoundingClientRect().height > maxHeight) {
      popup.style.maxHeight = `${maxHeight}px`
      popup.style.overflowY = "auto"
    }

    const {width, height} = popup.getBoundingClientRect()
    let left = x + width + margin > window.innerWidth ? x - width : x
    let top = y + height + margin > window.innerHeight ? y - height : y
    left = Math.max(margin, Math.min(left, window.innerWidth - width - margin))
    top = Math.max(margin, Math.min(top, window.innerHeight - height - margin))

    popup.style.left = `${left}px`
    popup.style.top = `${top}px`
  },

  // The tournament's own category names, and (for a row menu) that one
  // player's set, read off the DOM the server rendered. Both are JSON
  // attributes; a missing or malformed one degrades to an empty menu rather
  // than throwing inside a contextmenu handler.
  dynamicCellMenuItems(menu, col, bulk, playerId) {
    const categories = readJsonAttr(this.el, "categories")
    if (!categories.length) return []
    if (bulk) return menu.bulkItems(categories)

    const cell = this.el.querySelector(
      `tr[data-player-id="${playerId}"] td[data-col="${col}"]`
    )
    return menu.items(categories, readJsonAttr(cell, "tags"))
  },

  // `refocus` when the keyboard closed it: back to the header that opened it,
  // rather than onto the page itself.
  closeCellMenu(refocus = false) {
    if (this.cellPopup) {
      const hadFocus = this.cellPopup.contains(document.activeElement)
      this.cellPopup.remove()
      this.cellPopup = null
      // A redraw puts focus back inside the new popup itself, so it must not
      // bounce out to the opener on the way through here.
      if (!this.refreshingCellMenu && (refocus || hadFocus) && this.cellMenuOpener?.isConnected) {
        this.cellMenuOpener.focus()
      }
    }
    if (!this.refreshingCellMenu) {
      this.cellMenuAt = null
      this.cellMenuRedraw = false
    }
  },

  destroyed() {
    this.closeCellMenu()
    document.removeEventListener("mousedown", this.onCellMenuDocMousedown)
    document.removeEventListener("keydown", this.onCellMenuDocKeydown)
  },
}

// Ctrl+I opens the "Add player" modal on the Players page. Mounted on the
// page header (always present, unlike the player table/grid which only
// renders once there's at least one player) so the shortcut works even on
// an empty roster.
const AddPlayerShortcut = {
  mounted() {
    this.handler = (e) => {
      const key = e.key && e.key.toLowerCase()
      if (!(e.ctrlKey || e.metaKey) || e.altKey || key !== "i") return
      // Don't hijack Ctrl+I while a modal (edit/card/etc.) is already open.
      if (document.querySelector(".modal-overlay")) return
      e.preventDefault()
      this.pushEvent("add", {})
    }
    window.addEventListener("keydown", this.handler)
  },
  destroyed() {
    window.removeEventListener("keydown", this.handler)
  },
}

// Legend items and score-band gutter labels on the bracket map are both
// `[data-filter]` buttons sharing one `data-active-filter` state (a
// space-separated SET of facets) on the nearest .pe-bracket-map -
// multi-select: clicking a button toggles its own facet in the set (any
// number can be active at once), and an element dims only when the active
// set is non-empty AND none of its own facets intersect it (OR across
// active facets, so e.g. "down" + "against-due" both active keeps anything
// matching EITHER one lit). Zero active facets shows everything at full
// opacity, same as no filter. Matching against each SVG element's
// `data-facets` (set by dot_facets/1 / link_facets/1 in
// pairing_explain_live.ex) happens here in JS rather than via static
// per-facet CSS, since the set of possible "band-N" values is unbounded and
// only known at render time - see the comment above .pe-filterable/.pe-dim
// in assets/css/app.css.
function applyBracketFilter(map, filter) {
  const active = new Set((map.dataset.activeFilter || "").split(" ").filter(Boolean))
  if (active.has(filter)) active.delete(filter)
  else active.add(filter)
  map.dataset.activeFilter = Array.from(active).join(" ")

  map.querySelectorAll("[data-filter]").forEach((btn) => {
    btn.classList.toggle("is-active-filter", active.has(btn.dataset.filter))
  })

  map.querySelectorAll(".pe-filterable").forEach((el) => {
    const facets = (el.dataset.facets || "").split(" ")
    const dim = active.size > 0 && !facets.some((f) => active.has(f))
    el.classList.toggle("pe-dim", dim)
  })
}

// Closes any open head-to-head duo panel and clears both dots' rings.
function closeBracketDuo() {
  document.querySelectorAll(".pe-duo.is-open").forEach((el) => el.classList.remove("is-open"))
  document.querySelectorAll(".pe-board-wrap.is-duo").forEach((el) => el.classList.remove("is-duo"))
}

// The wraps are focusable (tabindex=0 for keyboard users), and the popover
// CSS shows on :focus as well as :hover/.is-pinned. A mouse click leaves
// the wrap focused, so after UNPINNING (or closing a duo) the "small"
// hover-size popover stayed open even after the mouse left - user-reported.
// Dropping focus after a mouse-driven close keeps hover/keyboard behaviour
// intact while letting the panel actually disappear on mouse-away.
function blurBracketWrap(wrap) {
  if (wrap.contains(document.activeElement)) document.activeElement.blur()
}

// Programmatic scrolls glide, unless the viewer asked the system for less
// motion - then they jump, like every other scroll the page does.
const scrollMotion = () =>
  window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth"

// Pairing-rationale bracket map: clicking a dot directly on the graph
// toggles its pin (ring + popover stay open until clicked again); with a
// dot pinned, clicking that player's EXACT opponent opens the board's
// head-to-head duo panel under the chart (clicking either of the two, or
// the panel's ✕, closes it); clicking a board card's colour disc always
// pins that dot and scrolls it into view; clicking a legend item or band
// label highlights just that facet. One delegated listener on document -
// not the scroll container, which LiveView can replace on round navigation
// - so no re-binding needed (and round navigation naturally resets any
// active filter along with it).
document.addEventListener("click", (e) => {
  // A click inside an open popover (e.g. selecting the player's name)
  // must not bubble into the wrap-toggle branch below and close it.
  if (e.target.closest(".pe-dot-popover")) return

  if (e.target.closest(".pe-duo-close")) {
    closeBracketDuo()
    return
  }

  const wrap = e.target.closest(".pe-board-wrap")
  if (wrap) {
    const openDuo = document.querySelector(".pe-duo.is-open")
    if (openDuo) {
      const duoDots = (openDuo.dataset.dots || "").split(" ")
      closeBracketDuo()

      // Clicking either of the duo's own two dots just dismisses the panel;
      // any other dot falls through to the normal pin behaviour below.
      if (duoDots.includes(wrap.id)) {
        blurBracketWrap(wrap)
        return
      }
    }

    const pinned = document.querySelector(".pe-board-wrap.is-pinned")
    if (pinned && pinned !== wrap && pinned.dataset.opponent === wrap.id) {
      // Pinned player + their exact opponent clicked → head-to-head panel.
      pinned.classList.remove("is-pinned")
      const duo = document.getElementById(`pe-duo-${wrap.dataset.board}`)
      if (duo) {
        duo.classList.add("is-open")
        wrap.classList.add("is-duo")
        pinned.classList.add("is-duo")
        duo.scrollIntoView({behavior: scrollMotion(), block: "nearest"})
      }
      blurBracketWrap(wrap)
      return
    }

    document.querySelectorAll(".pe-board-wrap.is-pinned").forEach((el) => {
      if (el !== wrap) el.classList.remove("is-pinned")
    })
    const nowPinned = wrap.classList.toggle("is-pinned")
    if (!nowPinned) blurBracketWrap(wrap)
    return
  }

  const filterBtn = e.target.closest("[data-filter]")
  if (filterBtn) {
    const map = filterBtn.closest(".pe-bracket-map")
    if (map) applyBracketFilter(map, filterBtn.dataset.filter)
    return
  }

  const disc = e.target.closest("[data-dot-target]")
  if (!disc) return
  const target = document.getElementById(disc.dataset.dotTarget)
  if (!target) return
  closeBracketDuo()
  document.querySelectorAll(".pe-board-wrap.is-pinned").forEach((el) => el.classList.remove("is-pinned"))
  target.classList.add("is-pinned")
  target.scrollIntoView({behavior: scrollMotion(), block: "nearest", inline: "center"})
})

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

// `reconnectAfterMs` is overridden with a slower schedule than Phoenix's
// own default, whose first retry after a drop is 10ms later.
//
// It was added for the embeddable public pages, where a cross-origin
// iframe's own visibility throttling could trigger reconnect storms. Those
// pages were removed on 2026-08-29, so the case it was written for no
// longer exists. It is kept because the effect it was reasoned about was
// never actually measured (see the git history for that admission), and a
// reconnect schedule that is merely conservative costs a user nothing: the
// slowest first retry here is 250ms, imperceptible on a real drop.

// Pending-restart countdown, driven by the `deploy-notice` event the
// DeployNotice on_mount hook pushes. The banner itself is rendered empty in
// the root layout on every page, so there is no per-page plumbing to forget.
//
// Ticks here rather than server-side: a per-second assign would mean one
// message per second to every open socket, which is real load for a
// cosmetic number. The tier switches here too, so escalation is free.
//
// Three tiers, because one flat banner sitting there for ten minutes becomes
// furniture and stops being read:
//   > 2 min   a restart is coming, save as you go
//   <= 2 min  do not START anything; finish and save what is open
//   <= 30 s   imminent
//
// The wording is deliberately narrow, because the obvious warnings are both
// false here:
//
//   "you will be logged out" - no. The deploy reuses SECRET_KEY_BASE, so
//   sessions survive a restart.
//
//   "you may lose unsaved changes" - not for the person most likely to be
//   reading this. Result entry is phx-change and writes straight through
//   (see handle_event("result", ...) in pairings_live.ex), so every result
//   is already in the database the moment it is picked. An earlier version
//   of this banner told arbiters to stop entering results, which was
//   advising against the safest thing on the page.
//
// What a reconnect actually costs is server-side state rebuilt by mount: an
// open dialog, a half-filled registration form, a settings page with edits
// not yet saved. All of those re-render from stored state and lose what was
// typed.
//
// The two-minute tier says "finish anything you are halfway through" rather
// than "save your work", because on most pages there is nothing to save -
// results, presence and pairings all write straight through, and only the
// settings pages have a Save button at all. Telling an arbiter on the
// pairings screen to save points at a control that is not there.
// Roughly how long the service is actually down. Named rather than inlined
// because it is an EXPECTATION, not a measurement the app can make - the
// restart happens after this process is gone. If restarts start taking
// visibly longer than this, change it here rather than letting the banner
// keep promising something it does not deliver.
const DOWNTIME_HINT = "about 30 seconds"

// A note on "you stay logged in", which the calm tier promises: that is only
// true because the deploy reuses SECRET_KEY_BASE. That reuse was BROKEN
// until 2026-08-22 - the systemd unit is written quoted and was read back
// unquoted, so the regex never matched the file the deploy script itself had
// written, and every deploy minted a fresh key. Updates logged everyone out
// for exactly that reason. If sessions start dropping again, suspect that
// first, and fix it rather than softening this line.

// ---- saying things to a screen reader ----
//
// One persistent polite region (#announcer, in the root layout) for every
// script on the page. Cleared and then filled a beat later, so the same
// sentence twice in a row is spoken twice rather than swallowed as no change.
const announce = (text) => {
  const region = document.getElementById("announcer")
  if (!region || !text) { return }
  region.textContent = ""
  setTimeout(() => { region.textContent = text }, 100)
}

// A flash, said once when it appears and again only if its words change.
// Its title and message, not the close button's label.
const flashText = (el) =>
  Array.from(el.querySelectorAll("p")).map((p) => p.textContent.trim()).filter(Boolean).join(". ")

const Flash = {
  mounted() {
    this.said = null
    this.say()
  },
  updated() { this.say() },
  say() {
    if (this.el.hidden) { return }
    const text = flashText(this.el)
    if (text && text !== this.said) {
      this.said = text
      announce(text)
    }
  },
}

// The connection flashes are shown by a JS command, not rendered, so they
// dispatch this as they appear (see `flash_group/1`).
window.addEventListener("pe:announce", (e) => announce(flashText(e.target)))

// A sentence the server wants said - already in the reader's language, since
// gettext chose the words (`announce/2` in pairings_live.ex: a swap armed or
// cancelled).
window.addEventListener("phx:announce", (e) => announce(e.detail && e.detail.text))

// ---- the "Saved." and "could not save" notes ----
//
// Every settings page confirms a save, and refuses a bad one, with an
// `.ok-note` or `.error-note` that the server renders beside the button - some
// sixty of them, none a live region, so a screen reader heard nothing after
// pressing Save. Rather than wrap each, this watches for one to appear (or its
// words to change) and says it. Not while a page is loading: a note that is
// simply part of the page arriving - "finish the tournament setup first" - is
// read in the ordinary way, not announced over the top of it.
let pageLoading = true
window.addEventListener("phx:page-loading-start", () => { pageLoading = true })
window.addEventListener("phx:page-loading-stop", () => { setTimeout(() => { pageLoading = false }, 0) })

let lastNote = {text: null, at: 0}
const sayNote = (el) => {
  const text = el.textContent.replace(/\s+/g, " ").trim()
  if (!text || (text === lastNote.text && Date.now() - lastNote.at < 1500)) { return }
  lastNote = {text, at: Date.now()}
  announce(text)
}

new MutationObserver((mutations) => {
  if (pageLoading) { return }

  for (const m of mutations) {
    if (m.type === "characterData") {
      const note = m.target.parentElement?.closest(".ok-note, .error-note")
      if (note) { sayNote(note) }
      continue
    }

    for (const node of m.addedNodes) {
      if (!(node instanceof HTMLElement)) { continue }
      if (node.matches(".ok-note, .error-note")) { sayNote(node) }
      node.querySelectorAll(".ok-note, .error-note").forEach(sayNote)
    }
  }
}).observe(document.body, {childList: true, subtree: true, characterData: true})

// ---- modal dialogs: focus goes in, stays in, and comes back out ----
//
// Every modal here is rendered by the server behind an `:if`, and closed by
// the server too (Escape via phx-window-keydown, a Cancel button, a click
// outside). None of that moved focus: a dialog opened with focus still on the
// button behind it, Tab walked out into the page `aria-modal` hides from a
// screen reader, and closing it left the keyboard at the top of the page.
//
// The hook sits on the dialog element itself (`role="dialog"`, `data-dialog`).
// It remembers where focus was when it mounted - the button that opened it,
// or, when that button was inside a menu that closed in the same render, the
// last thing focused outside any dialog - moves focus in (to a field the
// dialog focuses itself with phx-mounted, else its first control, else the
// dialog), keeps Tab inside, and on the way out puts focus back on that
// element, or on whatever carries its id after the re-render.
let lastFocusedOutsideDialog = null

// Not an item of a menu that closes in the same render as the dialog opens
// (`data-transient-menu`, the Pairings page's hand-edit menu): the dialog
// should return to the seat the menu was opened from, not to an item that no
// longer exists.
document.addEventListener("focusin", (e) => {
  if (!e.target.closest("[data-dialog], [data-transient-menu]")) { lastFocusedOutsideDialog = e.target }
})

const TABBABLE =
  'a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), ' +
  'select:not([disabled]), textarea:not([disabled]), summary, [tabindex]:not([tabindex="-1"])'

const DialogFocus = {
  mounted() {
    const at = document.activeElement
    const opener = at && at !== document.body && !this.el.contains(at) ? at : lastFocusedOutsideDialog
    this.returnTo = opener
    this.returnId = opener && opener.id

    this.onKeydown = (e) => {
      this.touched = true
      if (e.key === "Tab") { this.trap(e) }
    }
    this.el.addEventListener("keydown", this.onKeydown)

    // Once the user has clicked or typed inside, focus sitting on the dialog
    // itself is theirs, not a default nobody has moved yet - see updated().
    this.onPointerdown = () => { this.touched = true }
    this.el.addEventListener("pointerdown", this.onPointerdown)

    // A frame later, so a field the dialog focuses itself (phx-mounted
    // JS.focus()) has had its turn and is left alone.
    requestAnimationFrame(() => this.enter())
  },

  // The consent dialog changes its content in place (loading, then the
  // question): focus that was parked on the dialog itself moves in.
  //
  // Only while it is still parked - before the user has touched the dialog.
  // Safari (and Firefox on macOS) do not focus a checkbox or radio when it
  // is clicked, so focus lands on the nearest focusable ancestor: this
  // `tabindex="-1"` dialog. Ticking a category in the player dialog then
  // re-rendered it, this saw "focus on the dialog", and moved focus to the
  // first text field - scrolling a long form back to the top mid-edit.
  updated() {
    if (!this.touched && document.activeElement === this.el) { this.enter() }
  },

  // Into the first field to fill in, when the dialog is a form. Otherwise
  // onto the dialog itself - read out as its title - rather than onto its
  // first button, which in a confirmation is as often "Apply" as "Cancel".
  enter() {
    if (this.el.contains(document.activeElement) && document.activeElement !== this.el) { return }
    const field = this.tabbable().find((el) =>
      el.matches('input:not([type="checkbox"]):not([type="radio"]):not([type="file"]), select, textarea'))
    ;(field || this.el).focus()
  },

  tabbable() {
    return Array.from(this.el.querySelectorAll(TABBABLE))
      .filter((el) => !el.closest("[hidden]") && el.getClientRects().length > 0)
  },

  trap(e) {
    const items = this.tabbable()
    if (!items.length) { e.preventDefault(); return }

    const first = items[0]
    const last = items[items.length - 1]
    const at = document.activeElement

    if (e.shiftKey && (at === first || at === this.el || !this.el.contains(at))) {
      e.preventDefault()
      last.focus()
    } else if (!e.shiftKey && (at === last || !this.el.contains(at))) {
      e.preventDefault()
      first.focus()
    }
  },

  destroyed() {
    this.el.removeEventListener("keydown", this.onKeydown)
    this.el.removeEventListener("pointerdown", this.onPointerdown)

    const back =
      (this.returnTo && this.returnTo.isConnected && this.returnTo) ||
      (this.returnId && document.getElementById(this.returnId))

    if (back) { requestAnimationFrame(() => back.focus({preventScroll: true})) }
  },
}

// The lead word ("Server update", "Notice") and the sentence, as one
// announcement - read from the banner itself, so it is whatever the eye sees.
const bannerSentence = (el, textSelector) => {
  const lead = el.querySelector("strong")?.textContent?.trim()
  const text = el.querySelector(textSelector)?.textContent?.trim()
  return [lead, text].filter(Boolean).join(": ")
}

const deployBanner = {
  timer: null,
  watchdog: null,
  // The tier last announced. The countdown rewrites the sentence every
  // second, which is fine to look at and unbearable to listen to, so a
  // screen reader hears it when the banner appears and each time it
  // escalates - at two minutes and at thirty seconds - and not in between.
  announcedTier: null,

  // How long after the deadline the banner gives up and hides itself. Longer
  // than the watchdog's reload window, so a page that CAN recover reloads
  // first and a page that cannot at least stops lying about it.
  STALE_AFTER_MS: 180000,

  clock(sec) {
    const m = Math.floor(sec / 60)
    const s = String(sec % 60).padStart(2, "0")
    return `${m}:${s}`
  },

  render(el, at) {
    const left = Math.max(0, Math.round((at - Date.now()) / 1000))
    const text = el.querySelector(".deploy-banner-text")

    // Give up on our own, well past the deadline.
    //
    // The banner is cleared by a server push, which is fine until the thing
    // it is warning about is exactly what stops those pushes arriving. If
    // the socket does not come back, the client never hears the expiry and
    // sits on "back shortly" indefinitely - reported after thirty minutes of
    // it. A warning about a restart that finished long ago is just wrong, so
    // it times out here too, with no server involved.
    if (Date.now() > at + this.STALE_AFTER_MS) {
      clearInterval(this.timer)
      clearInterval(this.watchdog)
      el.hidden = true
      return
    }

    let tier = "soon"
    let message
    if (left <= 0) {
      tier = "now"
      message = "back shortly - reload this page if it has not come back in a minute"
    } else if (left <= 30) {
      tier = "now"
      message = `in ${left}s - go and grab a coffee, we will be back in ${DOWNTIME_HINT}`
    } else if (left <= 120) {
      tier = "close"
      message = `in ${this.clock(left)} - good moment to finish anything you are halfway through`
    } else {
      message = `in ${this.clock(left)} - we will be away for ${DOWNTIME_HINT}. Results save as you enter them, and you stay logged in`
    }

    if (text) { text.textContent = message }
    el.dataset.tier = tier

    if (tier !== this.announcedTier) {
      this.announcedTier = tier
      announce(bannerSentence(el, ".deploy-banner-text"))
    }
  },

  // The deadline on show, so the same one pushed again is recognised.
  shownFor: null,

  show(iso) {
    const el = document.getElementById("deploy-banner")
    if (!el) { return }
    clearInterval(this.timer)
    clearInterval(this.watchdog)

    // Every LiveView that mounts pushes the current deadline, so a live
    // navigation to another page during a countdown sends the one already
    // on screen. That is not the banner appearing: keep the tier already
    // said, or a screen reader hears the whole sentence again on every page.
    if (!(iso && iso === this.shownFor && !el.hidden)) { this.announcedTier = null }
    this.shownFor = iso || null

    if (!iso) { el.hidden = true; return }

    const at = Date.parse(iso)
    if (isNaN(at)) { el.hidden = true; return }

    el.hidden = false
    this.render(el, at)
    this.timer = setInterval(() => this.render(el, at), 1000)
    this.watch(at)
  },

  // "This page reconnects on its own" has to be true, and it is not always.
  // LiveView retries the rejoin every 5s forever (see reconnectAfterMs), so
  // anything that makes the rejoin fail PERMANENTLY leaves the page sitting
  // there looking alive and doing nothing until somebody hits reload.
  //
  // The known cause was the deploy minting a fresh SECRET_KEY_BASE on every
  // run, which invalidates the signed session token baked into the page:
  // every retry then fails for the same reason the last one did. That is
  // fixed in the deploy script, but a retry loop that can never succeed is a
  // bad enough failure mode to guard against on its own terms, whatever
  // causes it next.
  //
  // So: once the restart is well past due and the socket is still down,
  // reload. A reload always works - it fetches a fresh page with fresh
  // tokens - and it is what the person would do themselves a minute later.
  //
  // Only ever armed by an ANNOUNCED restart. Reloading on any long
  // disconnection would catch people on flaky mobile connections in a
  // tournament hall, which is a much easier way to lose someone's work than
  // the problem it fixes.
  watch(at) {
    const RELOAD_AFTER_MS = 45000

    this.watchdog = setInterval(() => {
      if (Date.now() < at + RELOAD_AFTER_MS) { return }

      // Ask whether the VIEW is alive, not merely the socket.
      //
      // The first version tested `liveSocket.isConnected()` alone, which is
      // transport-level: the websocket can be perfectly connected while the
      // LiveView on the page has failed to rejoin and is dead. That is the
      // exact state a restart produces when the page's session token no
      // longer verifies - so the check reported "connected", cleared itself,
      // and the reload it existed to perform never happened.
      //
      // LiveView marks the main view `phx-connected` only while it is
      // genuinely joined, and swaps in phx-loading / phx-error /
      // phx-client-error / phx-server-error otherwise.
      const main = document.querySelector("[data-phx-main]")
      const viewUp =
        typeof liveSocket !== "undefined" &&
        liveSocket.isConnected() &&
        main &&
        main.classList.contains("phx-connected")

      if (viewUp) { clearInterval(this.watchdog); return }

      clearInterval(this.watchdog)
      clearInterval(this.timer)
      window.location.reload()
    }, 3000)
  },
}

window.addEventListener("phx:deploy-notice", (e) => deployBanner.show(e.detail.restart_at))

// The plain announcement bar. Everything the deploy banner does that makes it
// a countdown - the per-second tick, the three tiers, the escalation to red -
// is absent here on purpose. This says one sentence until somebody takes it
// down, which is what an announcement is.
//
// It still holds an `until`, and still hides itself when that passes, so a
// browser left open overnight does not keep showing yesterday's notice about
// this morning's maintenance. That is the only clock in it, and it is checked
// once a minute rather than once a second - nothing here changes faster.
const siteNotice = {
  timer: null,

  show(message, until, level) {
    const el = document.getElementById("site-notice")
    if (!el) { return }

    clearInterval(this.timer)
    this.timer = null

    if (!message) {
      el.hidden = true
      return
    }

    const text = el.querySelector(".site-notice-text")
    const news = el.hidden || (text && text.textContent !== message)
    if (text) { text.textContent = message }
    el.dataset.level = level === "urgent" ? "urgent" : "info"
    el.hidden = false
    if (news) { announce(bannerSentence(el, ".site-notice-text")) }

    if (until) {
      const deadline = new Date(until).getTime()
      const check = () => {
        if (Date.now() >= deadline) {
          el.hidden = true
          clearInterval(this.timer)
          this.timer = null
        }
      }
      check()
      this.timer = setInterval(check, 60000)
    }
  },
}

window.addEventListener("phx:site-notice", (e) =>
  siteNotice.show(e.detail.message, e.detail.until, e.detail.level))

// "Updated to v0.15.2", shown once after a restart that actually changed the
// version. The comparison has to be client-side: only the browser remembers
// what was running BEFORE the restart, because the server that knew has been
// replaced.
//
// Nothing is shown on a first visit (no stored version to compare against)
// or on a restart that did not change the version - a crash-restart or a
// config reload is not news, and a toast that appears for non-events is one
// people stop reading.
const VERSION_KEY = "pairingsengine.version"

// localStorage THROWS rather than returning null where a browser blocks site
// data outright, so both sides are guarded. Unguarded, a throw here would
// take the socket setup below down with it.
const versionStore = {
  get: () => { try { return localStorage.getItem(VERSION_KEY) } catch (_) { return null } },
  set: (v) => { try { localStorage.setItem(VERSION_KEY, v) } catch (_) {} },
}

window.addEventListener("phx:app-version", (e) => {
  const now = e.detail.version
  if (!now) { return }

  const before = versionStore.get()
  versionStore.set(now)

  if (!before || before === now) { return }

  const el = document.getElementById("version-toast")
  if (!el) { return }

  const text = el.querySelector(".version-toast-text")
  if (text) { text.textContent = `Updated to v${now}` }
  el.hidden = false
  announce(text?.textContent)

  const hide = () => { el.hidden = true }
  el.querySelector(".version-toast-close")?.addEventListener("click", hide, {once: true})
  setTimeout(hide, 12000)
})

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  reconnectAfterMs: (tries) => [250, 500, 1000, 2000, 3000][tries - 1] || 5000,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ColumnPrefs, PlayerGrid, AddPlayerShortcut, Flash, DialogFocus},
  dom: {
    // The pickers' `aria-pressed` is set here in the browser (`markPickers`
    // below - the server never knows the theme), so a patch that re-renders
    // the top bar must carry it over rather than strip it.
    onBeforeElUpdated(from, to) {
      if ((from.dataset.themeOpt || from.dataset.accentOpt) && from.hasAttribute("aria-pressed")) {
        to.setAttribute("aria-pressed", from.getAttribute("aria-pressed"))
      }
    },
  },
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}


// ---- top-bar popovers close when you click away from them ----
//
// `<details name="topbar-popover">` already makes the menus mutually
// exclusive - opening one closes the others - but HTML has no notion of
// "clicked somewhere else", so an opened menu stayed open over the page
// until it was clicked again. That is tolerable for a menu you opened to
// pick something from, and wrong for the publish indicator, which is a
// thing you open to READ and then want out of.
//
// Delegated at the document rather than bound per element: these live in a
// layout that LiveView re-renders, and a per-element listener would have to
// be re-attached every patch.
document.addEventListener("click", (e) => {
  document.querySelectorAll('details[name="topbar-popover"][open]').forEach((menu) => {
    // Not `menu.contains(e.target)` alone: a click on the summary is what
    // toggles it, and closing here as well would fight that and leave the
    // menu unopenable.
    if (!menu.contains(e.target)) { menu.open = false }
  })
})

// ---- which theme and accent are on ----
//
// The pickers highlight the current option from CSS alone, keyed off the
// attributes the root layout's inline script keeps on <html>. That says it
// to the eye only; `aria-pressed` says it to a screen reader, worked out from
// the same attributes so the two cannot disagree. Re-applied after every live
// navigation, which renders the top bar afresh.
const markPickers = () => {
  const root = document.documentElement
  const source = root.getAttribute("data-theme-source")
  const theme = source === "system" ? "system" : root.getAttribute("data-theme")
  const accent = root.getAttribute("data-accent") || "green"

  document.querySelectorAll("[data-theme-opt]").forEach((b) =>
    b.setAttribute("aria-pressed", String(b.dataset.themeOpt === theme)))
  document.querySelectorAll("[data-accent-opt]").forEach((b) =>
    b.setAttribute("aria-pressed", String(b.dataset.accentOpt === accent)))
}

markPickers()
window.addEventListener("phx:page-loading-stop", markPickers)
window.addEventListener("phx:set-theme", markPickers)
window.addEventListener("phx:set-accent", markPickers)

// Escape closes the open one, which is what every other dismissible thing
// on the web does and what a keyboard user will try first.
document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") { return }

  document.querySelectorAll('details[name="topbar-popover"][open]').forEach((menu) => {
    menu.open = false
    // Focus goes back to the control that opened it, or it lands on <body>
    // and the next Tab starts from the top of the page.
    menu.querySelector("summary")?.focus()
  })
})
