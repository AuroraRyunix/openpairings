defmodule PairingsEngineWeb.LateEntryNotice do
  @moduledoc """
  The one-time notice for a Swiss still numbering its late entrants at the
  end (`late_entry_numbering` "end", which a migration chose and no arbiter
  did): C.04.2 2.4 numbers them by rating. Asked on the Pairings page and
  on Settings, Options, with the same words and the same two answers, and
  not again once either is given (`Tournaments.late_entry_notice?/1`).

  Each page puts `notice/1` in its template and sends the two events here:

      def handle_event("late_entry_notice_" <> answer, _params, socket),
        do: {:noreply, LateEntryNotice.answer(socket, answer)}

  `answer/2` writes, audits, and leaves `:tournament` and
  `:late_entry_notice` on the socket as they now are.
  """
  use Phoenix.Component
  use Gettext, backend: PairingsEngineWeb.Gettext

  import Phoenix.LiveView, only: [put_flash: 3]
  import PairingsEngineWeb.CoreComponents, only: [icon: 1]

  alias PairingsEngine.{Audit, Tournaments}
  alias PairingsEngineWeb.SettingsSupport

  attr :show, :boolean, required: true

  def notice(assigns) do
    ~H"""
    <div :if={@show} id="late-entry-notice" class="tpn-order-warning" role="status">
      <p class="tpn-order-warning-head">
        <.icon name="hero-information-circle-micro" class="setup-line-icon" />
        <span>
          {gettext(
            "Late entrants are numbered at the end here; FIDE (C.04.2 2.4) numbers them by rating. Switch?"
          )}
        </span>
      </p>

      <p class="tpn-order-warning-more">
        {gettext(
          "This tournament was made before numbering by rating became the default. Switching renumbers nobody already numbered: it decides where the next late entrant goes."
        )}
      </p>

      <div class="tpn-order-warning-actions">
        <button
          type="button"
          id="late-entry-notice-switch"
          class="pe-btn primary"
          phx-click="late_entry_notice_switch"
        >
          {gettext("Switch to by rating")}
        </button>

        <button
          type="button"
          id="late-entry-notice-keep"
          class="pe-btn"
          phx-click="late_entry_notice_keep"
        >
          {gettext("Keep")}
        </button>
      </div>
    </div>
    """
  end

  @doc "Handles `late_entry_notice_switch` (`\"switch\"`) and `late_entry_notice_keep` (`\"keep\"`)."
  def answer(socket, answer) when answer in ~w(switch keep) do
    base = Tournaments.get_tournament!(socket.assigns.tournament.id)

    if Tournaments.late_entry_notice?(base) do
      base |> write(answer, socket) |> result(socket)
    else
      # Answered meanwhile in another tab, or round 4 got paired: nothing to do.
      Phoenix.Component.assign(socket, tournament: base, late_entry_notice: false)
    end
  end

  def answer(socket, _other), do: socket

  defp write(base, "switch", socket) do
    with {:ok, tournament} <- Tournaments.switch_late_entry_numbering(base) do
      SettingsSupport.log_settings_change(socket, base, tournament)
      {:ok, tournament, gettext("Late entrants are now numbered by rating.")}
    end
  end

  defp write(base, "keep", socket) do
    with {:ok, tournament} <- Tournaments.dismiss_late_entry_notice(base) do
      Audit.log(
        tournament.id,
        socket.assigns.current_scope,
        "tournament.late_entry_numbering_kept",
        %{}
      )

      {:ok, tournament, gettext("Late entrants stay numbered at the end.")}
    end
  end

  defp result({:ok, tournament, message}, socket) do
    socket
    |> Phoenix.Component.assign(tournament: tournament, late_entry_notice: false)
    |> put_flash(:info, message)
  end

  defp result({:error, reason}, socket),
    do: put_flash(socket, :error, SettingsSupport.error_text(reason))
end
