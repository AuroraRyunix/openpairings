
    // Opens the hand-editing menu where the pointer is. There's no
    // native phx-contextmenu binding, so this half needs JS; the
    // left-click half (completing an armed swap) is a plain phx-click
    // in the markup. One delegated listener per panel rather than one
    // per name.
    //
    // A right-click NEVER completes anything - it only ever opens the
    // menu. Every write is behind a menu item plus the confirm modal,
    // so no two-right-clicks-in-a-row can change a pairing by accident.
    //
    // The keyboard (R2 of docs/accessibility-2026-09-13.md): every seat
    // with something to act on is a `[data-seat]` button. The
    // context-menu key and Shift+F10 open the menu through the same
    // `contextmenu` event, placed under the seat instead of at a pointer;
    // Enter or Space opens it too - except on a seat the server marked
    // `data-armed` (a swap or a pool pairing is waiting for its second
    // player), where Enter or Space is the left-click that completes it, sent as
    // that very click so both paths push the same event. Either way the
    // payload is the one a right-click sends, plus `keyboard: true` so
    // the menu takes focus.

    // What a keydown on a seat asks for: "menu-key" (a contextmenu event
    // follows), "complete", "menu" (Enter: open it now), "menu-keyup"
    // (Space: open it when the key comes back up), or null. Pure, so it
    // can be checked on its own.
    //
    // Space waits for its keyup, as it does on the Players grid: the menu
    // takes focus on its first item as soon as the server has drawn it,
    // which on a local copy is well inside one key press, and the keyup
    // then landed on that item - in a browser that activates a button on
    // Space's keyup, choosing "Swap with..." or "Hide this board" unasked.
    export const seatKeyAction = (e, armed) => {
      if (e.key === "ContextMenu" || (e.shiftKey && e.key === "F10")) return "menu-key";
      if (e.altKey || e.ctrlKey || e.metaKey || e.shiftKey) return null;
      if (e.key !== "Enter" && e.key !== " ") return null;
      if (armed) return "complete";
      return e.key === " " ? "menu-keyup" : "menu";
    };

    // Where a menu opens: at the pointer, or under the seat from the
    // keyboard, kept on screen either way (it's ~280x150).
    export const menuPosition = (x, y, width, height) => ({
      x: Math.max(8, Math.min(x, width - 300)),
      y: Math.max(8, Math.min(y, height - 170))
    });

    export default {
      mounted() {
        this.keyMenuAt = 0;

        this.openMenu = (target, x, y, keyboard) => {
          const at = menuPosition(x, y, window.innerWidth, window.innerHeight);
          this.pushEvent("open_menu", {
            x: at.x,
            y: at.y,
            scope: target.dataset.scope,
            "player-id": target.dataset.playerId || null,
            "pairing-id": target.dataset.pairingId || null,
            keyboard
          });
        };

        this.onContextMenu = (e) => {
          const target = e.target.closest("[data-scope]");
          if (!target) return;
          e.preventDefault();

          const keyboard =
            Date.now() - this.keyMenuAt < 1000 ||
            e.pointerType === "" ||
            (e.clientX === 0 && e.clientY === 0);
          this.keyMenuAt = 0;

          if (keyboard) {
            const box = (e.target.closest("[data-seat], select, button") || target).getBoundingClientRect();
            this.openMenu(target, box.left, box.bottom, true);
          } else {
            this.openMenu(target, e.clientX, e.clientY, false);
          }
        };

        this.onKeydown = (e) => {
          const seat = e.target.closest("[data-seat]");
          if (!seat) return;

          const action = seatKeyAction(e, seat.hasAttribute("data-armed"));
          if (action === "menu-key") { this.keyMenuAt = Date.now(); return; }
          if (!action) return;
          e.preventDefault();

          if (action === "complete") {
            seat.click();
          } else if (action === "menu-keyup") {
            this.spaceOn = seat;
          } else {
            this.openFromKeys(seat);
          }
        };

        this.onKeyup = (e) => {
          if (e.key !== " " || !this.spaceOn) return;
          const seat = this.spaceOn;
          this.spaceOn = null;
          if (e.target.closest("[data-seat]") === seat) this.openFromKeys(seat);
        };

        this.openFromKeys = (seat) => {
          const box = seat.getBoundingClientRect();
          this.openMenu(seat.closest("[data-scope]"), box.left, box.bottom, true);
        };

        // A finger has no right button, and iOS sends no `contextmenu`
        // for a long press - so on a touch screen a tap on a seat that is
        // not armed opens its menu, at the tap. An armed seat's tap is
        // still the click that completes the swap (its `phx-click`), and
        // a mouse click is unchanged everywhere.
        this.touchAt = 0;
        this.onPointerDown = (e) => {
          this.touchAt = e.pointerType === "touch" || e.pointerType === "pen" ? Date.now() : 0;
        };
        this.onClick = (e) => {
          if (Date.now() - this.touchAt > 800) return;
          this.touchAt = 0;
          const seat = e.target.closest("[data-seat]");
          if (!seat || seat.hasAttribute("data-armed") || !this.el.contains(seat)) return;
          const target = seat.closest("[data-scope]");
          if (target) this.openMenu(target, e.clientX, e.clientY, false);
        };

        this.el.addEventListener("contextmenu", this.onContextMenu);
        this.el.addEventListener("keydown", this.onKeydown);
        this.el.addEventListener("keyup", this.onKeyup);
        this.el.addEventListener("pointerdown", this.onPointerDown);
        this.el.addEventListener("click", this.onClick);

        // After an applied hand edit the confirmation closes and
        // `DialogFocus` puts focus back where the edit started - a frame
        // later. Two frames later still, focus moves onto the edited
        // board if it is not on it already: the seat it was on, when that
        // seat is on the board, else the board's first seat or result.
        // Only the table's copy of this hook listens; the pool's has no
        // boards.
        if (this.el.tagName === "TABLE") {
          this.handleEvent("hand_edit_applied", ({pairing_id}) => {
            if (!pairing_id) return;
            requestAnimationFrame(() => requestAnimationFrame(() => {
              const row = document.getElementById(`pairing-row-${pairing_id}`);
              if (!row || row.contains(document.activeElement)) return;
              const target = row.querySelector("[data-seat], select, button");
              if (target) target.focus();
            }));
          });
        }
      },

      destroyed() {
        this.el.removeEventListener("contextmenu", this.onContextMenu);
        this.el.removeEventListener("keydown", this.onKeydown);
        this.el.removeEventListener("keyup", this.onKeyup);
        this.el.removeEventListener("pointerdown", this.onPointerDown);
        this.el.removeEventListener("click", this.onClick);
      }
    }
  