
    // SWAR-style "blind" result entry: with a board's result <select>
    // focused, typing 1 / 2 / 3 sets that board's result (white win /
    // draw / black win) and moves focus to the next board's result
    // select, so a sequence like "131312" fills in six boards in a row
    // without touching the mouse.
    // Mapped by PHYSICAL key (e.code) so the top-row/numpad 1/2/3 keys
    // work on any keyboard layout (e.g. AZERTY, where the top row
    // produces & é " without Shift). e.key is kept as a fallback.
    const CODE_TO_VALUE = {
      "Digit1": "1-0", "Numpad1": "1-0",
      "Digit2": "1/2-1/2", "Numpad2": "1/2-1/2",
      "Digit3": "0-1", "Numpad3": "0-1"
    };
    const KEY_TO_VALUE = {"1": "1-0", "2": "1/2-1/2", "3": "0-1"};

    export default {
      mounted() {
        // A native <select> opens its dropdown on the same click that
        // focuses it - and while that native popup is open, the browser
        // intercepts number keys for its own "jump to option" behavior
        // before our keydown listener below ever sees them (confirmed:
        // typing did nothing until a second click closed the popup,
        // leaving the element focused-but-closed). Clicking to open a
        // fresh select is the arbiter's actual entry point for the "1/2/3"
        // workflow, so it must land focused-and-CLOSED in one click.
        // Only intercept the click that's ABOUT to focus this element -
        // if it's already focused, let a second click open the dropdown
        // normally (still needed to pick a code with no 1/2/3 shortcut,
        // e.g. a forfeit result).
        this.onMousedown = (e) => {
          this.abandon();
          if (document.activeElement !== this.el) {
            e.preventDefault();
            this.el.focus();
          }
        };
        this.el.addEventListener("mousedown", this.onMousedown);

        // Walking the options with the arrow keys. On a CLOSED select,
        // Windows and Linux browsers change the value - and fire
        // "change" - on every arrow press, so going from 1-0 to 0-1 by
        // keyboard wrote 1/2-1/2 on the way (a result and an audit row),
        // and passing the blank option staged the "clear this result?"
        // box, which replaced the select under the keyboard mid-walk.
        // While `browsing`, those intermediate events are held back here,
        // before LiveView (listening further up) sees them; the choice
        // is sent once, on Enter or when focus leaves, and Escape puts
        // the recorded result back. A mouse pick, the 1/2/3 keys and an
        // opened dropdown's own Enter still send straight away.
        this.browsing = false;

        this.hold = (e) => {
          if (this.browsing && !this.committing) { e.stopPropagation(); }
        };
        this.el.addEventListener("input", this.hold);
        this.el.addEventListener("change", this.hold);

        this.onBlur = () => { if (this.browsing) { this.commit(); } };
        this.el.addEventListener("blur", this.onBlur);

        this.onKeydown = (e) => {
          // Opening the list (Alt+Down, F4, Space) abandons an arrow walk:
          // the pick is about to come from the list, whose own Enter the
          // page never sees, so nothing may still be held back by then.
          if ((e.altKey && ["ArrowUp", "ArrowDown"].includes(e.key)) || e.key === "F4" || e.key === " ") {
            this.abandon();
            return;
          }

          if (["ArrowUp", "ArrowDown", "PageUp", "PageDown", "Home", "End"].includes(e.key)) {
            this.browsing = true;
            return;
          }

          if (e.key === "Enter" && this.browsing) {
            e.preventDefault();
            this.commit();
            return;
          }

          if (e.key === "Escape" && this.browsing) {
            this.abandon();
            return;
          }

          // Ctrl, Alt or Cmd with a digit is somebody else's shortcut -
          // Ctrl+1..3 switches browser tabs, AltGr (Ctrl+Alt) types ~ and #
          // on AZERTY - not a result. Matched by physical key, these used
          // to record one on the focused board and swallow the shortcut.
          // Shift stays allowed: AZERTY needs it for the digits.
          if (e.ctrlKey || e.altKey || e.metaKey) return;

          const value = CODE_TO_VALUE[e.code] || KEY_TO_VALUE[e.key];
          if (!value) return; // let every other key behave natively

          const hasOption = Array.from(this.el.options).some((o) => o.value === value);
          if (!hasOption) return;

          // Stop the browser's native "jump to option starting with
          // this character" select behavior - we're fully driving the
          // value ourselves.
          e.preventDefault();

          this.browsing = false;
          this.el.value = value;
          // LiveView's phx-change listens for a real "change" event
          // bubbling up from the form.
          this.el.dispatchEvent(new Event("change", {bubbles: true}));

          // Close any open native dropdown before moving focus, or it
          // stays visibly open over the next board's select.
          this.el.blur();

          this.focusNextBoard();
        };

        this.el.addEventListener("keydown", this.onKeydown);
      },

      // Drops an arrow-key walk and shows the recorded result again.
      abandon() {
        if (!this.browsing) { return; }
        this.browsing = false;
        this.el.value = this.el.dataset.result || "";
      },

      // Sends the value an arrow-key walk ended on, if it differs from
      // what is recorded.
      commit() {
        this.browsing = false;
        if (this.el.value === (this.el.dataset.result || "")) { return; }

        this.committing = true;
        this.el.dispatchEvent(new Event("change", {bubbles: true}));
        this.committing = false;
      },

      // Real incident: an arbiter changed a result on one tab (e.g.
      // "0-0FF" -> "0-0"); a second arbiter viewing the same round, who
      // simply had that SAME board's select focused (nothing more --
      // no typing in progress), never saw the change. Root cause is a
      // genuine Phoenix LiveView behavior, not a bug in this app's own
      // code: once a form control has been interacted with, LiveView's
      // client won't overwrite its `value`/`selected` state on a
      // server-pushed diff, so as not to clobber someone's in-progress
      // typing - and confirmed by hand, that pin doesn't even clear on
      // blur; the element stays stuck on the stale value until it's
      // touched again or the page reloads. That protection makes sense
      // for a free-text field mid-keystroke; it's actively wrong for a
      // discrete-choice dropdown like this one, where "reflect the
      // truth immediately" matters far more than "don't disturb an
      // open dropdown" for the sliver of a second that's even at risk.
      //
      // Fix: the true value is ALSO mirrored into `data-result` (a
      // plain attribute, not `value`/`selected`, so it's exempt from
      // that protection and patches normally regardless of focus).
      // `updated()` fires on every server-pushed diff to this element,
      // focused or not - resync `value` from it whenever they drift.
      updated() {
        const truth = this.el.dataset.result;
        if (truth !== undefined && this.el.value !== truth) {
          this.el.value = truth;
        }
      },

      focusNextBoard() {
        const selects = Array.from(document.querySelectorAll("select[data-board-select]"));
        const index = selects.indexOf(this.el);
        if (index >= 0 && index < selects.length - 1) {
          const next = selects[index + 1];

          // Focusing normally makes the browser jump-scroll the next
          // select into view only once it's fully out of the viewport -
          // the screen sits still for several entries, then lurches
          // several rows at once. `preventScroll` stops that native
          // jump so we can drive a smooth, one-row-at-a-time scroll
          // ourselves below instead.
          next.focus({ preventScroll: true });

          const row = next.closest("tr") || next;
          const calm = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
          row.scrollIntoView({ behavior: calm ? "auto" : "smooth", block: "center" });
        } else {
          // The last board: stay on it. The blur above closed any open
          // dropdown, and leaving focus there dropped the keyboard onto
          // the page itself, somewhere above the table.
          this.el.focus({ preventScroll: true });
        }
      },

      destroyed() {
        this.el.removeEventListener("keydown", this.onKeydown);
        this.el.removeEventListener("mousedown", this.onMousedown);
        this.el.removeEventListener("input", this.hold);
        this.el.removeEventListener("change", this.hold);
        this.el.removeEventListener("blur", this.onBlur);
      }
    }
  