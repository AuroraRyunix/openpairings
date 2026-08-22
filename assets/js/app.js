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

// Persists the player-grid column selection (the "Display" panel) in localStorage.
const ColumnPrefs = {
  mounted() {
    const stored = localStorage.getItem("pairingsengine.playerColumns")
    if (stored) {
      try { this.pushEvent("columns_loaded", {columns: JSON.parse(stored)}) } catch {}
    }
    this.handleEvent("store_columns", ({columns}) => {
      localStorage.setItem("pairingsengine.playerColumns", JSON.stringify(columns))
    })
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
}

const CELL_MENU_COLS = Object.keys(CELL_MENUS)
const cellMenuSelector = (tag) => CELL_MENU_COLS.map((c) => tag + "[data-col=\"" + c + "\"]").join(", ")

const PlayerGrid = {
  mounted() {
    // Double-clicking must not text-select the player name; e.detail > 1
    // means this mousedown is part of a double/triple click. Plain drags
    // still select text normally.
    this.el.addEventListener("mousedown", (e) => {
      if (e.detail > 1) e.preventDefault()
    })
    this.el.addEventListener("dblclick", (e) => {
      const tr = e.target.closest("tr[data-player-id]")
      if (!tr) return
      this.pushEvent("edit_player", {id: tr.dataset.playerId})
    })
    this.el.addEventListener("contextmenu", (e) => {
      // A COLUMN HEADER in CELL_MENUS gets the bulk version - every player
      // in the tournament at once; left click on the same header still
      // sorts. Checked before the row lookup below, since a header cell
      // sits in <thead> with no tr[data-player-id] ancestor.
      const header = e.target.closest(cellMenuSelector("th"))
      if (header) {
        e.preventDefault()
        this.openCellMenu(e.clientX, e.clientY, header.dataset.col, null)
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
        this.openCellMenu(e.clientX, e.clientY, cell.dataset.col, tr.dataset.playerId)
        return
      }

      this.pushEvent("show_card", {id: tr.dataset.playerId})
    })

    // Left-click on one of those cells opens the same little menu -
    // right-click isn't discoverable (no visible affordance, doesn't exist
    // at all on touch), so a plain click gets it too. Left-click elsewhere
    // on the row is unclaimed today, so this can't collide with anything.
    this.el.addEventListener("click", (e) => {
      const cell = e.target.closest(cellMenuSelector("td"))
      if (!cell) return
      const tr = e.target.closest("tr[data-player-id]")
      if (!tr) return
      this.openCellMenu(e.clientX, e.clientY, cell.dataset.col, tr.dataset.playerId)
    })

    this.onCellMenuDocMousedown = (e) => {
      if (this.cellPopup && !this.cellPopup.contains(e.target)) this.closeCellMenu()
    }
    this.onCellMenuDocKeydown = (e) => {
      if (e.key === "Escape") this.closeCellMenu()
    }
    document.addEventListener("mousedown", this.onCellMenuDocMousedown)
    document.addEventListener("keydown", this.onCellMenuDocKeydown)
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
  openCellMenu(x, y, col, playerId) {
    this.closeCellMenu()

    const menu = CELL_MENUS[col]
    if (!menu) return

    const bulk = playerId === null
    const popup = document.createElement("div")
    popup.className = "print-menu-popup"
    popup.style.left = `${x}px`
    popup.style.top = `${y}px`

    for (const [label, value] of bulk ? menu.bulkItems : menu.items) {
      const btn = document.createElement("button")
      btn.type = "button"
      btn.className = "print-menu-item"
      btn.textContent = label
      btn.addEventListener("click", () => {
        if (bulk) {
          this.pushEvent(menu.bulkEvent, {value})
        } else {
          this.pushEvent(menu.event, {id: playerId, value})
        }
        this.closeCellMenu()
      })
      popup.appendChild(btn)
    }

    document.body.appendChild(popup)
    this.cellPopup = popup
  },

  closeCellMenu() {
    if (this.cellPopup) {
      this.cellPopup.remove()
      this.cellPopup = null
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
        duo.scrollIntoView({behavior: "smooth", block: "nearest"})
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
  target.scrollIntoView({behavior: "smooth", block: "nearest", inline: "center"})
})

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

// `reconnectAfterMs` is overridden with a slower schedule than Phoenix's
// own default ([10, 50, 100, 150, 200, 250, 500, 1000, 2000], i.e. the
// FIRST retry after a drop is 10ms later). That default is fine for a
// normal tab, but `phoenix.js`'s base Socket also force-reconnects on
// every `visibilitychange` where the connection isn't already open
// (`!isConnected() && !closeWasClean`) - and a cross-origin iframe (the
// embeddable public pages, see docs/public-pages.md) gets its own
// visibility/throttling treatment from the browser, distinct from its
// parent tab's, which can flip more often than a normal backgrounded
// tab does. Each flip that finds the socket not cleanly connected tears
// it down and reconnects; at a 10ms first retry, a run of those produces
// exactly the browser console spam this was written to fix: repeated
// "WebSocket is closed before the connection is established", visible as
// the topbar flashing on nothing in particular. A slower floor does not
// stop a visibility flip from asking for a reconnect, but it stops one
// flip's own retry attempts from racing each other, and gives
// `longPollFallbackMs` below an actual unbroken window to fire in rather
// than being reset by the next 10ms retry before it can.
//
// This has not been measured against a real embed, only reasoned from
// `deps/phoenix/priv/static/phoenix.js`'s Socket constructor - if the
// flicker persists after this, the next step is confirming whether
// visibility events are really what is firing (a temporary debug log
// on `visibilitychange` inside the embedded frame would settle it) rather
// than tuning this further blind.
// The embeddable public pages (`/p/:slug/pairings`, `/p/:slug/standings`,
// `/p/:slug/register`) use a cookie-free socket - see the "/embed/live"
// socket in endpoint.ex for why. Chosen by path so a normal, non-embedded
// visit to those same URLs uses it too: the socket works identically either
// way (these pages have no session state to lose), and picking by
// `window.self !== window.top` instead would mean the embedded and
// non-embedded cases exercised different code paths, so a bug in one would
// not show up in the other.
//
// `register` must stay on this list for as long as it is in the router's
// `:embeddable` pipeline. Framed on the "/live" socket it would hand
// LiveView a session token it cannot verify (the Lax cookie is not sent
// cross-site), and the page would appear to reload forever.

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

const deployBanner = {
  timer: null,

  clock(sec) {
    const m = Math.floor(sec / 60)
    const s = String(sec % 60).padStart(2, "0")
    return `${m}:${s}`
  },

  render(el, at) {
    const left = Math.max(0, Math.round((at - Date.now()) / 1000))
    const text = el.querySelector(".deploy-banner-text")

    let tier = "soon"
    let message
    if (left <= 0) {
      tier = "now"
      message = "back shortly - this page comes back on its own, no need to touch anything"
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
  },

  show(iso) {
    const el = document.getElementById("deploy-banner")
    if (!el) { return }
    clearInterval(this.timer)
    clearInterval(this.watchdog)

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

      const socketUp = typeof liveSocket !== "undefined" && liveSocket.isConnected()
      if (socketUp) { clearInterval(this.watchdog); return }

      clearInterval(this.watchdog)
      clearInterval(this.timer)
      window.location.reload()
    }, 3000)
  },
}

window.addEventListener("phx:deploy-notice", (e) => deployBanner.show(e.detail.restart_at))

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

// localStorage THROWS rather than returning null in a partitioned third-party
// frame - Safari's default. Unguarded that would break the socket setup on
// exactly the embedded pages this app supports.
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

  const hide = () => { el.hidden = true }
  el.querySelector(".version-toast-close")?.addEventListener("click", hide, {once: true})
  setTimeout(hide, 12000)
})

const EMBEDDABLE_PATH = /^\/p\/[^/]+\/(pairings|standings|register)$/
const socketPath = EMBEDDABLE_PATH.test(window.location.pathname) ? "/embed/live" : "/live"

const liveSocket = new LiveSocket(socketPath, Socket, {
  longPollFallbackMs: 2500,
  reconnectAfterMs: (tries) => [250, 500, 1000, 2000, 3000][tries - 1] || 5000,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ColumnPrefs, PlayerGrid, AddPlayerShortcut},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// When this page is embedded, tell the parent how tall its content
// actually is, so the host page can size the <iframe> to fit instead of
// guessing a fixed pixel height. A guessed height is wrong in both
// directions: too small and the standings scroll inside a little box, too
// large and there is a slab of dead space under the table (which is what
// prompted this - a `height:3000px` embed of a short tournament).
//
// The message is `{type: "openpairings:height", height: <px>}`, posted to
// `"*"` because the whole point is that we do not know or control which
// site is embedding us - there is nothing secret in the payload, it is one
// integer describing our own layout. Receivers should check
// `event.data.type` before trusting it (the snippet in docs/public-pages.md
// does).
//
// Height is reported on load, on every ResizeObserver tick, and after
// LiveView patches the DOM - results coming in mid-round genuinely change
// the table's height, and an embed that only sized itself once would drift
// out of true as soon as that happened. `Math.ceil` + a last-value guard
// keeps it from posting a message on every sub-pixel reflow.
if (window.self !== window.top) {
  // Opt-in reconnect diagnostics, kept from the flicker investigation. The
  // reconnect spam ("WebSocket is closed before the connection is
  // established") appeared to settle after `reconnectAfterMs` was slowed,
  // but the mechanism was never actually confirmed - see that option's
  // comment. Rather than delete the instrumentation and have nothing to
  // reach for if it returns, it now only logs when explicitly asked:
  // append `?embeddebug=1` to the embedded URL.
  if (new URLSearchParams(window.location.search).has("embeddebug")) {
    let lastLog = 0
    const logThrottled = (label) => {
      const now = Date.now()
      console.log(`[embed-debug] ${label} at +${now - lastLog}ms since last, visibilityState=${document.visibilityState}`)
      lastLog = now
    }
    document.addEventListener("visibilitychange", () => logThrottled("visibilitychange"))
    window.addEventListener("pagehide", () => logThrottled("pagehide"))
    window.addEventListener("pageshow", () => logThrottled("pageshow"))
    window.addEventListener("phx:page-loading-start", () => logThrottled("phx:page-loading-start"))
    console.log("[embed-debug] active - watching for visibility/reconnect churn")
  }

  let lastHeight = 0

  const reportHeight = () => {
    // `documentElement.scrollHeight` rather than body's: the public layout's
    // <main> is the scrolling element and body can report short.
    const height = Math.ceil(document.documentElement.scrollHeight)
    if (height === lastHeight || height <= 0) return
    lastHeight = height
    window.parent.postMessage({type: "openpairings:height", height}, "*")
  }

  if (typeof ResizeObserver !== "undefined") {
    new ResizeObserver(reportHeight).observe(document.documentElement)
  }
  window.addEventListener("load", reportHeight)
  window.addEventListener("phx:page-loading-stop", reportHeight)
  document.addEventListener("phx:update", reportHeight)
  reportHeight()
}

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

