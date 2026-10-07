
    // Measures how many board rows this screen can actually hold and tells
    // the server, so a hall screen fits itself to whatever it is plugged
    // into rather than to a number somebody guessed. The server owns which
    // page is showing; this only reports the shape of the glass.
    export default {
      mounted() {
        this.report = () => {
          if (!this.el.classList.contains("hall-screen")) return;

          const row = this.el.querySelector("tbody tr");
          const head = this.el.querySelector("thead");
          if (!row) return;

          const rowHeight = row.getBoundingClientRect().height;
          if (rowHeight <= 0) return;

          // Measure from the table's own top to the bottom of the window,
          // so page furniture above it is accounted for without having to
          // know what any of it is.
          const top = this.el.getBoundingClientRect().top;
          const headHeight = head ? head.getBoundingClientRect().height : 0;
          // Room for the footer and a little breathing space, so the last
          // row is never half-clipped at the bottom edge.
          const chrome = headHeight + 96;
          const usable = window.innerHeight - top - chrome;

          const rows = Math.max(Math.floor(usable / rowHeight), 1);
          if (rows !== this.lastRows) {
            this.lastRows = rows;
            this.pushEvent("rows_fit", { rows: rows });
          }
        };

        // Re-measure when the window changes: a screen gets rotated, a
        // window is dragged to another monitor, the browser chrome appears.
        this.onResize = () => window.requestAnimationFrame(this.report);
        window.addEventListener("resize", this.onResize);
        this.report();
      },

      updated() {
        this.report();
      },

      // A reconnect - a deploy's restart, a dropped network, a laptop
      // waking - mounts the LiveView afresh, back on its default page
      // size, while this hook stays mounted and still remembers the
      // number it last sent. Forget it, so the screen is measured and
      // told again rather than left paging twelve boards at a time.
      reconnected() {
        this.lastRows = null;
        this.report();
      },

      destroyed() {
        window.removeEventListener("resize", this.onResize);
      }
    }
  