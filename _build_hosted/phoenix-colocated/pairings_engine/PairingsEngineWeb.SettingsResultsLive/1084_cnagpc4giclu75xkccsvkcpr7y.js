
    // "On the results site" and "Automatically" (`setting_slider/1`) - the
    // Pairings page's ".PublishLevel" keyboard model: one tab stop, the
    // chosen one; the arrow keys, Home and End move focus between the
    // stops without choosing one, because every stop publishes or
    // withdraws something the moment it is chosen. Space or Enter
    // chooses (the stops are buttons), confirm included.
    const step = (key, index, count) => {
      switch (key) {
        case "ArrowRight":
        case "ArrowDown": return (index + 1) % count;
        case "ArrowLeft":
        case "ArrowUp": return (index - 1 + count) % count;
        case "Home": return 0;
        case "End": return count - 1;
        default: return null;
      }
    };

    export default {
      mounted() {
        this.onKeydown = (e) => {
          if (e.altKey || e.ctrlKey || e.metaKey) return;
          const stops = Array.from(this.el.querySelectorAll("[role=radio]"));
          const index = stops.indexOf(document.activeElement);
          if (index < 0) return;
          const next = step(e.key, index, stops.length);
          if (next === null) return;
          e.preventDefault();
          stops.forEach((stop, i) => { stop.tabIndex = i === next ? 0 : -1; });
          stops[next].focus();
        };
        this.el.addEventListener("keydown", this.onKeydown);
      },
      destroyed() {
        this.el.removeEventListener("keydown", this.onKeydown);
      }
    }
  