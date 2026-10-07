defmodule PairingsEngineWeb.RatingNotice do
  @moduledoc """
  The automatic rating consistency check's notice, for the Players and
  Pairings pages.

  Opening either page compares the roster with the local FIDE list (without
  writing anything - `PairingsEngine.RatingRefresh.notice/1`), and so does a
  finished list update while the page is open. When the list this tournament
  uses differs from the ratings on file for some players, a quiet notice says
  so and offers the check. It never blocks anything: pairing goes on exactly
  as before.
  """
  use Phoenix.Component
  use Gettext, backend: PairingsEngineWeb.Gettext

  alias PairingsEngine.RatingRefresh

  @doc "The notice for `tournament`, or `nil` when there is nothing to say."
  def compute(tournament), do: RatingRefresh.notice(tournament)

  attr :notice, :map, default: nil
  attr :tournament_id, :integer, required: true
  attr :review, :string, default: nil, doc: "a phx-click event name that opens the check here"

  def notice(assigns) do
    ~H"""
    <div
      :if={@notice}
      id="rating-check-notice"
      class="card"
      style="display: flex; gap: 12px; align-items: center; justify-content: space-between"
      role="status"
    >
      <span>
        {ngettext(
          "The FIDE list (%{period}) gives a different rating or title for %{count} player.",
          "The FIDE list (%{period}) gives a different rating or title for %{count} players.",
          @notice.changed,
          period: @notice.local_period
        )}
      </span>
      <button
        :if={@review}
        id="rating-check-notice-review"
        type="button"
        class="pe-btn"
        phx-click={@review}
      >
        {gettext("Review")}
      </button>
      <.link
        :if={!@review}
        id="rating-check-notice-review"
        class="pe-btn"
        navigate={"/t/#{@tournament_id}/players"}
      >
        {gettext("Review")}
      </.link>
    </div>
    """
  end
end
