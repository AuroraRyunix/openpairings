
    // Draws one curved arrow per player SHOWN in the confirm modal, not
    // only the ones who moved: from where they sit in the "before" card
    // to where they sit in the "after" one. A two-board player swap
    // shows 4 people - the 2 who traded boards (a real, crossing
    // journey) plus whoever they left in place on each board (a short
    // arrow back to their own seat) - so every name shown has one,
    // rather than 2 obviously-moved arrows next to 2 unmarked names
    // that look forgotten. A same-board colour swap only ever shows the
    // 2 who moved, since there's nobody else on that one board to draw.
    //
    // Which seats to join is decided by NAME MATCHING, not by a flag
    // from the server: a curve exists exactly when one name appears on
    // both sides. That's 4 curves for a player swap, 2 for a colour
    // swap, and ZERO for mark-absent / award-bye / fill-seat /
    // pool-pair / substitute-from-pool, where nobody shown keeps the
    // same identity on both sides of an empty seat - no new server
    // state to keep in sync, and it cannot mislabel a non-swap as one.
    //
    // The curves route through the middle grid column (normally just the
    // static "→", hidden while arrows are up and widened into a real
    // channel). Straight-line arrows would tunnel under the opaque
    // board cards; routing through the empty channel keeps every name
    // readable.
    //
    // Pure enhancement: no JS, a failed measurement or an ambiguous
    // name match all leave the plain "→" layout exactly as it is.
    const REDUCED_MOTION = "(prefers-reduced-motion: reduce)";
    const SVG_NS = "http://www.w3.org/2000/svg";
    // Straight run at each end of a curve, and how far short of the
    // destination card the arrowhead stops.
    const STUB = 12;
    const HEAD_GAP = 4;
    // `seat_text("")`'s own placeholder, verbatim - an empty seat never
    // gets an arrow drawn to/from it (see `matchTravellers/1`).
    const EMPTY_SEAT_TEXT = "- empty -";

    export default {
      mounted() {
        this.onResize = () => this.schedule();
        window.addEventListener("resize", this.onResize);
        this.schedule();
      },

      // LiveView re-renders this modal for reasons unrelated to the
      // diff (the frozen-round checkbox, a remote broadcast that now
      // keeps the confirm open) and its patch drops both the class and
      // the generated SVG, so redraw rather than assume they survived.
      updated() {
        this.schedule();
      },

      destroyed() {
        window.removeEventListener("resize", this.onResize);
        clearTimeout(this.timer);
      },

      // Deliberately setTimeout, not requestAnimationFrame: rAF never
      // fires while the tab isn't compositing (backgrounded, or a
      // hidden panel), which would leave the arrows silently missing
      // until something forced a repaint.
      schedule() {
        clearTimeout(this.timer);
        this.timer = setTimeout(() => this.draw(), 0);
      },

      draw() {
        const layer = this.el.querySelector(".swap-arrows-layer");
        if (!layer) return;

        layer.replaceChildren();
        this.el.classList.remove("has-swap-arrows");

        const pairs = this.matchTravellers();
        if (pairs.length === 0) return;

        // Widening the channel reflows the grid, so the new column
        // widths have to land BEFORE anything is measured - reading a
        // layout property forces that synchronously, rather than
        // waiting on a frame that may never come.
        this.el.classList.add("has-swap-arrows");
        void this.el.offsetHeight;

        this.render(layer, pairs);
      },

      // [beforeSeatEl, afterSeatEl] for every name shown on BOTH sides -
      // not only the ones already flagged "changed". A two-board player
      // swap shows 4 people (the 2 who traded boards, plus whoever they
      // left in place on each board); a same-board colour swap shows
      // only the 2 who moved, since there's nobody else on that board to
      // draw. Either way every name gets an arrow: the 2 (or 4) who
      // actually moved get a real journey: the ones who didn't get a
      // short one back to their own seat, same colour, so nobody shown
      // reads as "forgotten" next to the ones who visibly moved.
      //
      // A name appearing twice on either side is ambiguous (two players
      // sharing a display name) - skipped rather than guessed at, since
      // a wrong arrow is worse than none. The empty-seat placeholder
      // text is excluded outright: two different blank seats matching
      // each other by that shared placeholder would be a false pair,
      // not a real name.
      matchTravellers() {
        const nameOf = (el) =>
          (el.querySelector(".board-seat-name")?.textContent || "").trim();
        const isRealName = (name) => name && name !== EMPTY_SEAT_TEXT;

        const before = Array.from(this.el.querySelectorAll(".board-card-before .board-seat"));
        const after = Array.from(this.el.querySelectorAll(".board-card-after .board-seat"));

        const tally = (els) => {
          const counts = new Map();
          els.forEach((el) => {
            const n = nameOf(el);
            if (isRealName(n)) counts.set(n, (counts.get(n) || 0) + 1);
          });
          return counts;
        };

        const beforeCounts = tally(before);
        const afterCounts = tally(after);
        const pairs = [];

        before.forEach((from) => {
          const name = nameOf(from);
          if (!isRealName(name)) return;
          if (beforeCounts.get(name) !== 1 || afterCounts.get(name) !== 1) return;

          const to = after.find((el) => nameOf(el) === name);
          if (to) pairs.push([from, to]);
        });

        return pairs;
      },

      render(layer, pairs) {
        const group = this.el.getBoundingClientRect();
        const box = (el) => {
          const r = el.getBoundingClientRect();
          return { x: r.left - group.left, y: r.top - group.top, w: r.width, h: r.height };
        };
        // A seat's arrow attaches to its CARD's edge, at the seat row's
        // own height - so the curve leaves the card beside the right
        // name rather than from the card's middle.
        const exit = (seat) => {
          const card = box(seat.closest(".board-card"));
          const row = box(seat);
          return { x: card.x + card.w, y: row.y + row.h / 2 };
        };
        const entry = (seat) => {
          const card = box(seat.closest(".board-card"));
          const row = box(seat);
          return { x: card.x, y: row.y + row.h / 2 };
        };

        const svg = document.createElementNS(SVG_NS, "svg");
        svg.setAttribute("class", "swap-arrows");
        svg.setAttribute("width", group.width);
        svg.setAttribute("height", group.height);
        svg.setAttribute("aria-hidden", "true");

        const defs = document.createElementNS(SVG_NS, "defs");
        svg.append(defs);

        const animate = !window.matchMedia(REDUCED_MOTION).matches;

        pairs.forEach(([from, to], i) => {
          const start = exit(from);
          const end = entry(to);

          // Each traveller's OWN colour, read straight off the seat
          // element `board_card/1` already set it on (`identity_colors/1`
          // assigned it server-side) - so the arrow always matches the
          // name/highlight it belongs to, with no colour list of our
          // own to keep in sync. `from` and `to` are the same person by
          // construction (matchTravellers/1 paired them by name), so
          // either would do; `from` is just as good as `to`.
          const color = getComputedStyle(from).getPropertyValue("--swap-color").trim();
          const markerId = `swap-arrow-head-${i}`;
          defs.append(this.arrowHeadDef(markerId, color));

          // A straight stub at each end: the curve is done bending
          // before the arrowhead, so the head sits on a level run
          // instead of still turning as it lands. Same at the dot.
          const tip = end.x - HEAD_GAP;
          const stub = Math.min(STUB, Math.max(0, (tip - start.x) / 4));
          const from_x = start.x + stub;
          const to_x = tip - stub;

          // Symmetric control points - `+k` out of the start, `−k`
          // into the end. Both curves of a swap then pass through the
          // exact centre of the channel at their own half-way point,
          // so they cross dead centre. (Giving each curve a single
          // shared control x instead - one "lane" per arrow - is what
          // made the crossing drift below the middle.)
          const k = Math.max((to_x - from_x) / 2, 14);

          const path = document.createElementNS(SVG_NS, "path");
          path.setAttribute("class", "swap-arrow-path");
          path.setAttribute(
            "d",
            `M ${start.x} ${start.y} L ${from_x} ${start.y}` +
              ` C ${from_x + k} ${start.y}, ${to_x - k} ${end.y}, ${to_x} ${end.y}` +
              ` L ${tip} ${end.y}`
          );
          path.setAttribute("marker-end", `url(#${markerId})`);
          if (color) path.style.stroke = color;

          const dot = document.createElementNS(SVG_NS, "circle");
          dot.setAttribute("class", "swap-arrow-dot");
          dot.setAttribute("cx", start.x);
          dot.setAttribute("cy", start.y);
          dot.setAttribute("r", 3);
          if (color) dot.style.fill = color;

          svg.append(path, dot);

          if (animate) {
            const length = path.getTotalLength();
            path.style.strokeDasharray = length;
            path.style.strokeDashoffset = length;
            // Read back a layout value so the browser commits the
            // pre-animation state instead of collapsing both writes.
            void path.getBoundingClientRect();
            path.style.transition = "stroke-dashoffset .45s ease-out";
            path.style.strokeDashoffset = "0";
          }
        });

        layer.append(svg);
      },

      // One `<marker>` per arrow, not one shared by all of them - an
      // SVG marker has exactly one fill, so two differently-coloured
      // arrowheads need two markers. `id` just needs to be unique
      // within this one SVG.
      arrowHeadDef(id, color) {
        const marker = document.createElementNS(SVG_NS, "marker");
        marker.setAttribute("id", id);
        marker.setAttribute("viewBox", "0 0 8 8");
        marker.setAttribute("refX", "7");
        marker.setAttribute("refY", "4");
        marker.setAttribute("markerWidth", "5");
        marker.setAttribute("markerHeight", "5");
        marker.setAttribute("orient", "auto");

        const head = document.createElementNS(SVG_NS, "path");
        head.setAttribute("class", "swap-arrow-head");
        head.setAttribute("d", "M 0 0 L 8 4 L 0 8 z");
        if (color) head.style.fill = color;

        marker.append(head);
        return marker;
      }
    }
  