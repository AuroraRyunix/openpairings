defmodule PairingsEngineWeb.BadgePrintSheet do
  @moduledoc """
  The A4 print layout: two badges per portrait sheet, each printed as front
  and back side by side (210 x 148.5 mm), with a dashed fold line between the
  two halves of a badge and a dashed cut line between the two badges. Cut
  across, fold each piece in half and it is an A6 badge with its back on the
  reverse.

  Ported from the stand-alone badge maker's A4 mode; its single-badge A5 mode
  was dropped (a single badge prints on the top half of an A4 sheet).
  """
  use Phoenix.Component
  use Gettext, backend: PairingsEngineWeb.Gettext

  import PairingsEngineWeb.BadgeCard

  @doc "Every sheet for `pages`, a list of one- or two-card lists."
  attr :pages, :list, required: true
  attr :qr_svg, :string, default: ""
  attr :show_guides, :boolean, default: true

  def print_sheets(assigns) do
    ~H"""
    <div id="badge-print-sheets">
      <section
        :for={{cards, index} <- Enum.with_index(@pages)}
        id={"badge-sheet-#{index + 1}"}
        class="badge-print-page"
      >
        <%= for {card, slot} <- Enum.with_index(cards) do %>
          <div
            :if={slot == 1 and @show_guides}
            class="badge-cut-guide"
            aria-hidden="true"
          >
            <span>✂ {gettext("cut here")} ✂</span>
          </div>
          <div class="badge-print-pair" data-badge-id={card.id}>
            <div class="badge-print-face">
              <.badge_front badge={card} qr_svg={@qr_svg} />
            </div>
            <div :if={@show_guides} class="badge-fold-guide" aria-hidden="true">
              <span>{gettext("fold here")}</span>
            </div>
            <div class="badge-print-face">
              <.badge_back badge={card} qr_svg={@qr_svg} />
            </div>
          </div>
        <% end %>
      </section>
    </div>
    """
  end
end
