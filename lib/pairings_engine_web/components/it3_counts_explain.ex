defmodule PairingsEngineWeb.Components.It3CountsExplain do
  @moduledoc """
  A collapsed-by-default breakdown of IT3's rated/titled/federation counts —
  same visual language as the pairing-rationale screens (`.pe-stat`,
  `.pe-tag`, `.pe-ladder`-style proportional bars, see
  `PairingsEngineWeb.PairingExplainLive`) so an arbiter checking "why does
  this say 14 rated players" gets the same quality of answer they'd get
  checking why a pairing was made, not a bare number to take on faith.

  A plain `<details>`/`<summary>` (native, no JS) rather than a LiveView
  toggle: this is read-only, static once the page has the player list, and
  `<details>` already gives closed-by-default, keyboard-accessible
  disclosure for free.
  """

  use Phoenix.Component

  alias PairingsEngine.Norms.CountsBreakdown

  attr :players, :list, required: true
  attr :host_federation, :string, default: nil

  def it3_counts_explain(assigns) do
    breakdown = CountsBreakdown.breakdown(assigns.players, assigns.host_federation)
    assigns = assign(assigns, :breakdown, breakdown)

    ~H"""
    <details class="it3-explain">
      <summary class="it3-explain-summary">
        How the IT3 rated / titled / federation counts were calculated
      </summary>

      <p class="hint" style="margin: 6px 0 12px">
        Same grouping the report itself uses (see
        <span class="it3-explain-code">Norms.Forms.it3_fills/3</span>
        and <span class="it3-explain-code">Norms.Forms.titled?/1</span>
        — CM/WCM don't count as
        titled). <strong>feds</strong>
        is the number of distinct federations in that group; <strong>host</strong>
        is how many of them are {host_label(assigns.host_federation)}.
      </p>

      <div class="it3-explain-grid">
        <.category_card
          :for={{key, label, explanation} <- CountsBreakdown.categories()}
          label={label}
          explanation={explanation}
          category={Map.fetch!(@breakdown, key)}
          host_federation={@host_federation}
        />
      </div>
    </details>
    """
  end

  attr :label, :string, required: true
  attr :explanation, :string, required: true
  attr :category, :map, required: true
  attr :host_federation, :string, default: nil

  defp category_card(assigns) do
    ~H"""
    <details class="it3-explain-card">
      <summary>
        <span class="it3-explain-card-label">{@label}</span>
        <span class="pe-stat">
          <span class="pe-stat-n">{@category.total}</span>
        </span>
        <span class="it3-explain-card-sub">
          {@category.feds} fed{if @category.feds != 1, do: "s"} · {@category.host} host
        </span>
      </summary>

      <p class="hint" style="margin: 4px 0 8px">{@explanation}</p>

      <div
        :if={@category.total > 0}
        class="pe-ladder it3-explain-bar"
        title={host_bar_title(@category, @host_federation)}
      >
        <div
          class="pe-ladder-fill"
          style={"width: #{host_pct(@category)}%"}
        >
        </div>
        <span class="pe-ladder-num">
          {@category.host} host · {@category.total - @category.host} other feds
        </span>
      </div>

      <ul :if={@category.total > 0} class="it3-explain-players">
        <li :for={p <- @category.players} class="it3-explain-player">
          <span class="it3-explain-player-name">{p.name}</span>
          <span class="pe-tag pe-tag-muted">{blank_dash(p.federation)}</span>
          <span :if={p.title not in [nil, ""]} class="pe-tag pe-tag-ok">{p.title}</span>
          <span :if={(p.fide_rating || 0) > 0} class="it3-explain-player-rating">
            {p.fide_rating}
          </span>
        </li>
      </ul>

      <p :if={@category.total == 0} class="hint" style="margin: 0">No players in this group.</p>
    </details>
    """
  end

  defp host_pct(%{total: 0}), do: 0
  defp host_pct(%{total: total, host: host}), do: Float.round(host / total * 100, 1)

  defp host_label(nil), do: "the host federation"
  defp host_label(""), do: "the host federation"
  defp host_label(fed), do: fed

  defp host_bar_title(%{host: host, total: total}, host_federation) do
    "#{host} of #{total} from #{host_label(host_federation)}"
  end

  defp blank_dash(nil), do: "—"
  defp blank_dash(""), do: "—"
  defp blank_dash(fed), do: fed
end
