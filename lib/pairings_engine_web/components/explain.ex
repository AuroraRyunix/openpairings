defmodule PairingsEngineWeb.Components.Explain do
  @moduledoc """
  A small "?" beside a setting's label that explains it in a popover.

  Hover or keyboard focus shows it, a click or tap pins it open (so it works
  on a phone), Escape or a click anywhere else closes it. The text is the
  inner block; the button names it with `aria-describedby` and reports
  `aria-expanded`.

  The wrapper is `phx-update="ignore"`: the open state is the hook's own,
  and the explanation is static text. It is not a label, so put it next to
  a `setting_field`, not inside one (a click inside a label would also tick
  the box).
  """
  use Phoenix.Component
  use Gettext, backend: PairingsEngineWeb.Gettext

  import PairingsEngineWeb.CoreComponents, only: [icon: 1]

  attr :id, :string, required: true
  attr :label, :string, default: nil, doc: "the button's accessible name"
  slot :inner_block, required: true

  def explain(assigns) do
    ~H"""
    <span id={@id} class="explain" phx-hook=".Explain" phx-update="ignore">
      <button
        id={"#{@id}-button"}
        type="button"
        class="explain-btn"
        aria-expanded="false"
        aria-controls={"#{@id}-text"}
        aria-describedby={"#{@id}-text"}
        aria-label={@label || gettext("What is this?")}
        data-explain-button
      >
        <.icon name="hero-question-mark-circle" class="explain-icon" />
      </button>
      <span id={"#{@id}-text"} class="explain-pop" role="tooltip" data-explain-pop>
        {render_slot(@inner_block)}
      </span>
    </span>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Explain">
      export default {
        mounted() {
          const root = this.el
          const button = root.querySelector("[data-explain-button]")
          const pop = root.querySelector("[data-explain-pop]")
          let pinned = false

          const place = () => {
            pop.style.translate = "0px 0"
            const rect = pop.getBoundingClientRect()
            const over = rect.right - (window.innerWidth - 16)
            const under = 16 - rect.left
            if (over > 0) pop.style.translate = `${-over}px 0`
            else if (under > 0) pop.style.translate = `${under}px 0`
          }

          const show = (open) => {
            root.toggleAttribute("data-open", open)
            button.setAttribute("aria-expanded", open ? "true" : "false")
            if (open) place()
          }

          this.onEnter = () => show(true)
          this.onLeave = () => { if (!pinned) show(false) }
          this.onClick = () => { pinned = !pinned; show(pinned) }
          this.onFocusOut = (e) => {
            if (!pinned && !root.contains(e.relatedTarget)) show(false)
          }
          this.onKey = (e) => {
            if (e.key === "Escape" && root.hasAttribute("data-open")) {
              pinned = false
              show(false)
            }
          }
          this.onOutside = (e) => {
            if (!root.contains(e.target)) {
              pinned = false
              show(false)
            }
          }

          root.addEventListener("mouseenter", this.onEnter)
          root.addEventListener("mouseleave", this.onLeave)
          root.addEventListener("focusin", this.onEnter)
          root.addEventListener("focusout", this.onFocusOut)
          button.addEventListener("click", this.onClick)
          document.addEventListener("keydown", this.onKey)
          document.addEventListener("click", this.onOutside)
        },
        destroyed() {
          document.removeEventListener("keydown", this.onKey)
          document.removeEventListener("click", this.onOutside)
        }
      }
    </script>
    """
  end
end
