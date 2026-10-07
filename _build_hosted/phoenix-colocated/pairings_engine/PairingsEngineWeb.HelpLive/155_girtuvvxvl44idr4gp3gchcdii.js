
    export default {
      mounted() {
        this.reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches
        this.onKey = (e) => this.key(e)
        this.onScroll = () => {
          if (this.ticking) return
          this.ticking = true
          requestAnimationFrame(() => { this.ticking = false; this.spy() })
        }
        this.onClick = (e) => this.click(e)
        window.addEventListener("keydown", this.onKey)
        window.addEventListener("scroll", this.onScroll, {passive: true})
        this.el.addEventListener("click", this.onClick)
        this.scrollToHash()
        this.spy()
      },
      updated() { this.spy() },
      destroyed() {
        window.removeEventListener("keydown", this.onKey)
        window.removeEventListener("scroll", this.onScroll)
      },
      behavior() { return this.reduced ? "auto" : "smooth" },
      scrollToHash() {
        const id = decodeURIComponent(window.location.hash.slice(1))
        if (!id) return
        const target = document.getElementById(id)
        if (target) requestAnimationFrame(() => target.scrollIntoView({block: "start"}))
      },
      // The outline entry of the last heading above the top fifth of
      // the window is the one being read.
      spy() {
        const links = this.el.querySelectorAll("[data-outline]")
        if (!links.length) return
        const line = window.innerHeight * 0.2
        let current = null
        this.el.querySelectorAll("#manual-chapter-body h2[id], #manual-chapter-body h3[id]").forEach(h => {
          if (h.getBoundingClientRect().top <= line) current = h.id
        })
        // At the very bottom the last headings can never reach the line:
        // the last one on screen is the one being read.
        if (window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 2) {
          this.el.querySelectorAll("#manual-chapter-body h2[id], #manual-chapter-body h3[id]").forEach(h => {
            if (h.getBoundingClientRect().top < window.innerHeight) current = h.id
          })
        }
        if (!current && links[0]) current = links[0].dataset.outline
        links.forEach(a => {
          const on = a.dataset.outline === current
          a.classList.toggle("is-active", on)
          if (on) a.setAttribute("aria-current", "location")
          else a.removeAttribute("aria-current")
        })
      },
      key(e) {
        const input = document.getElementById("manual-search-input")
        if (!input) return
        const t = e.target
        const typing = t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName))
        if ((e.key === "k" || e.key === "K") && (e.ctrlKey || e.metaKey)) {
          e.preventDefault(); input.focus(); input.select(); return
        }
        if (e.key === "/" && !typing && !e.altKey && !e.ctrlKey && !e.metaKey) {
          e.preventDefault(); input.focus(); input.select(); return
        }
        if (e.key === "Escape" && t === input) input.blur()
      },
      click(e) {
        const anchor = e.target.closest("a.manual-anchor")
        if (anchor) return this.copyLink(e, anchor)
        const frame = e.target.closest("[data-enlarge]")
        if (frame) return this.enlarge(frame)
        const box = document.getElementById("manual-lightbox")
        if (box && box.open && (e.target === box || e.target.closest("[data-close]"))) box.close()
      },
      copyLink(e, anchor) {
        e.preventDefault()
        const id = anchor.getAttribute("href").slice(1)
        const url = window.location.origin + window.location.pathname + "#" + id
        history.replaceState(history.state, "", "#" + id)
        const heading = document.getElementById(id)
        if (heading) heading.scrollIntoView({behavior: this.behavior(), block: "start"})
        const toast = document.getElementById("manual-copied")
        const done = () => {
          if (!toast) return
          toast.textContent = this.el.dataset.copied
          toast.classList.add("is-shown")
          clearTimeout(this.toastTimer)
          this.toastTimer = setTimeout(() => toast.classList.remove("is-shown"), 1800)
        }
        if (navigator.clipboard && window.isSecureContext) {
          navigator.clipboard.writeText(url).then(done, () => {})
        }
      },
      enlarge(frame) {
        const img = frame.querySelector("img")
        const box = document.getElementById("manual-lightbox")
        if (!img || !box || !box.showModal) return
        box.querySelector("img").src = img.currentSrc || img.src
        box.querySelector("img").alt = img.alt
        const caption = frame.closest("figure")?.querySelector("figcaption")
        box.querySelector(".manual-lightbox-caption").textContent = caption ? caption.textContent : ""
        box.showModal()
      }
    }
  