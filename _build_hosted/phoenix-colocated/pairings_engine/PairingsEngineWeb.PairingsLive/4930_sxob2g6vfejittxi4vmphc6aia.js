
    // The round's "Spectators see:" radio group (`publish_level/1`). One tab stop
    // - the chosen level - and the arrow keys, Home and End move focus
    // between the four stops without choosing one: every stop publishes
    // or withdraws something, so choosing stays a deliberate Space or
    // Enter (the stops are buttons), confirm included. Disabled stops
    // stay reachable so their reason is read out.
    //
    // The arrow keys stop here: inside the round's right-click menu the
    // menu's own Up/Down walk would otherwise move focus a second time.

    // The stop a key moves to, from `index` among `count`. Pure.
    export const stopStep = (key, index, count) => {
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
          const next = stopStep(e.key, index, stops.length);
          if (next === null) return;
          e.preventDefault();
          e.stopPropagation();
          stops.forEach((stop, i) => { stop.tabIndex = i === next ? 0 : -1; });
          stops[next].focus();
        };
        this.el.addEventListener("keydown", this.onKeydown);
      },
      destroyed() {
        this.el.removeEventListener("keydown", this.onKeydown);
      }
    }
  