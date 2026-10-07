
      // Overview minimap for the (often wider-than-viewport) bracket
      // scroll strip. The strip's `scroll` event doesn't bubble to
      // document, so the delegated-listener pattern the rest of this page
      // uses can't see it - this is a real hook bound directly to the
      // strip, cleaned up on destroy so round navigation doesn't leave a
      // second listener behind.
      export default {
        mounted() {
          this.strip = this.el.closest(".pe-bracket-map")?.querySelector(".pe-bracket-scroll");
          this.viewport = this.el.querySelector(".pe-minimap-viewport");
          if (!this.strip || !this.viewport) return;

          this.ticking = false;
          this.onScroll = () => {
            if (this.ticking) return;
            this.ticking = true;
            requestAnimationFrame(() => { this.ticking = false; this.sync(); });
          };
          this.onResize = () => this.sync();
          this.onDown = (e) => { this.dragging = true; this.seek(e); };
          this.onMove = (e) => { if (this.dragging) this.seek(e, true); };
          this.onUp = () => { this.dragging = false; };

          this.strip.addEventListener("scroll", this.onScroll, { passive: true });
          window.addEventListener("resize", this.onResize);
          this.el.addEventListener("pointerdown", this.onDown);
          window.addEventListener("pointermove", this.onMove);
          window.addEventListener("pointerup", this.onUp);

          this.sync();
        },

        updated() { this.sync(); },

        // Position the viewport rect from the strip's scroll geometry, and
        // hide the whole minimap when there's nothing to scroll.
        sync() {
          if (!this.strip || !this.viewport) return;
          const { scrollWidth, clientWidth, scrollLeft } = this.strip;
          const overflow = scrollWidth > clientWidth + 1;
          // Must be an explicit "block": the stylesheet default is
          // display:none (no flash before this hook runs), so clearing
          // the inline style ("") would fall back to hidden forever.
          this.el.style.display = overflow ? "block" : "none";
          if (!overflow) return;

          const w = this.el.clientWidth;
          this.viewport.style.left = (scrollLeft / scrollWidth * w) + "px";
          this.viewport.style.width = (clientWidth / scrollWidth * w) + "px";
        },

        // Scroll the strip so the clicked/dragged minimap point is centred.
        // A click keeps the strip's CSS smooth glide; during a DRAG each
        // pointermove must track instantly (`instant` true) - the strip
        // has `scroll-behavior: smooth`, and re-triggering a smooth
        // animation on every move would rubber-band behind the pointer.
        seek(e, instant) {
          if (!this.strip) return;
          const rect = this.el.getBoundingClientRect();
          const frac = Math.min(Math.max((e.clientX - rect.left) / rect.width, 0), 1);
          const target = frac * this.strip.scrollWidth - this.strip.clientWidth / 2;
          const calm = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
          this.strip.scrollTo({left: Math.max(0, target), behavior: instant || calm ? "instant" : "smooth"});
        },

        destroyed() {
          if (this.strip) this.strip.removeEventListener("scroll", this.onScroll);
          window.removeEventListener("resize", this.onResize);
          if (this.el) this.el.removeEventListener("pointerdown", this.onDown);
          window.removeEventListener("pointermove", this.onMove);
          window.removeEventListener("pointerup", this.onUp);
        }
      }
    