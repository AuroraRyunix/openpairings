
    // A <details> menu that closes like a menu: on a tap or click outside it
    // (pointerdown: iOS sends no mouse events for a tap on plain page),
    // on Escape (focus back to its button), and once an item is chosen.
    export default {
      mounted() {
        this.close = (refocus) => {
          if (!this.el.open) return;
          this.el.open = false;
          if (refocus) this.el.querySelector("summary").focus();
        };
        this.onDocPointerdown = (e) => {
          if (!this.el.contains(e.target)) this.close(false);
        };
        this.onKeydown = (e) => {
          if (e.key === "Escape") this.close(true);
        };
        this.onClick = (e) => {
          if (e.target.closest("[role=menuitem]")) this.close(false);
        };
        document.addEventListener("pointerdown", this.onDocPointerdown);
        this.el.addEventListener("keydown", this.onKeydown);
        this.el.addEventListener("click", this.onClick);
      },
      destroyed() {
        document.removeEventListener("pointerdown", this.onDocPointerdown)
        this.el.removeEventListener("keydown", this.onKeydown);
        this.el.removeEventListener("click", this.onClick);
      }
    }
  