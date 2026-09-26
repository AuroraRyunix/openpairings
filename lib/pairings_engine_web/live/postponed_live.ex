defmodule PairingsEngineWeb.PostponedLive do
  @moduledoc """
  The old Postponed games page (`/t/:id/postponed`). Everything it showed -
  every postponed game and its state, the dates played, and the
  postponed-games TRF - now lives with the other TRF files on Settings,
  Export (`PairingsEngineWeb.SettingsExportLive`), so this only sends a
  bookmarked link there.
  """
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.Tournaments

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)
    {:ok, push_navigate(socket, to: ~p"/t/#{tournament.id}/settings/export#postponed-part")}
  end

  @impl true
  def render(assigns), do: ~H""
end
