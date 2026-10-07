
    // The hand-edit menu itself, rendered by the server. Opened from the
    // keyboard (`data-keyboard`) it takes focus on its first item; Up,
    // Down, Home and End walk the items; Tab closes it the way Escape
    // does (Escape is the backdrop's `phx-window-keydown`). However it
    // closes - an item chosen, Escape, a click away - focus goes back to
    // the seat that opened it, by id when a patch has replaced that seat,
    // unless something else (a confirmation dialog) has already taken it.

    // The item Up/Down/Home/End moves to, from `index` among `count`
    // (-1 when focus is not on an item yet). Pure.
    export const menuStep = (key, index, count) => {
      if (!count) return null;
      switch (key) {
        case "ArrowDown": return (index + 1 + count) % count;
        case "ArrowUp": return index < 0 ? count - 1 : (index - 1 + count) % count;
        case "Home": return 0;
        case "End": return count - 1;
        default: return null;
      }
    };

    export default {
      mounted() {
        const at = document.activeElement;
        this.opener = at && at !== document.body && !this.el.contains(at) ? at : null;
        this.openerId = this.opener && this.opener.id;

        this.items = () =>
          Array.from(this.el.querySelectorAll("button:not([disabled])"));

        this.onKeydown = (e) => {
          const items = this.items();
          if (e.key === "Tab") {
            e.preventDefault();
            this.pushEvent("close_menu", {});
            return;
          }
          const next = menuStep(e.key, items.indexOf(document.activeElement), items.length);
          if (next === null) return;
          e.preventDefault();
          items[next].focus();
        };
        this.el.addEventListener("keydown", this.onKeydown);

        // The round's menu opens on its level control, whose tab stop
        // is the chosen level rather than the first one.
        if (this.el.hasAttribute("data-keyboard")) {
          const first =
            this.el.querySelector("[role=radio][aria-checked=true]") || this.items()[0];
          if (first) first.focus();
        }
      },

      destroyed() {
        const at = document.activeElement;
        if (at && at !== document.body && at.isConnected) return;

        const back =
          (this.opener && this.opener.isConnected && this.opener) ||
          (this.openerId && document.getElementById(this.openerId));
        if (back) back.focus({preventScroll: true});
      }
    }
  