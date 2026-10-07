
    // A board leaves the list a moment after its result is entered, and
    // takes with it the button that entered it - the one with focus. Left
    // there, focus falls to the page itself and a screen reader or a
    // keyboard starts again from the top. So the board that had focus
    // hands it on as it goes: to the board that moves up into its place,
    // the last one if it was last, or the page's main region if none are
    // left ("All results in").
    export default {
      mounted() {
        this.onFocus = () => {
          const boards = Array.from(document.querySelectorAll(".mobile-board"));
          window.peBoardFocus = { id: this.el.id, index: boards.indexOf(this.el) };
        };
        this.el.addEventListener("focusin", this.onFocus);

        // Focus that LEFT the board - to another board, the header, or the
        // page itself after a tap on empty space - is no longer this
        // board's to hand on. Checked a tick later, because a board being
        // removed can report focus leaving too: then it is no longer in the
        // page, the record stays, and `destroyed` hands focus on as meant.
        // Without this, a board entered by another phone could pull focus
        // back from wherever the arbiter had since put it.
        this.onBlur = () => {
          setTimeout(() => {
            if (!this.el.isConnected || this.el.contains(document.activeElement)) return;
            if (window.peBoardFocus && window.peBoardFocus.id === this.el.id) {
              window.peBoardFocus = null;
            }
          }, 0);
        };
        this.el.addEventListener("focusout", this.onBlur);
      },

      destroyed() {
        const last = window.peBoardFocus;
        if (!last || last.id !== this.el.id) return;
        window.peBoardFocus = null;

        requestAnimationFrame(() => {
          const active = document.activeElement;
          if (active && active !== document.body) return;
          // Gone with the whole page (a navigation), not just this board.
          if (!document.querySelector(".mobile-shell")) return;

          const boards = Array.from(document.querySelectorAll(".mobile-board"));
          const board = boards[Math.min(last.index, boards.length - 1)];
          const target =
            (board && board.querySelector("button:not([disabled])")) ||
            document.getElementById("main-content");

          if (target) target.focus();
        });
      }
    };
  