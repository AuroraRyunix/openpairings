defmodule PairingsEngineWeb.SettingsChangelogLive do
  @moduledoc """
  The tournament-scoped "Changelog" settings page
  (`/t/:id/settings/changelog`) - kept as a redirect to the global
  `/changelog` page (`PairingsEngineWeb.ChangelogLive`), which shows
  exactly the same content without needing a specific tournament in
  context. Old links (bookmarks, the Settings subnav before it was
  updated) still resolve instead of 404ing.
  """
  use PairingsEngineWeb, :live_view

  @impl true
  def mount(%{"id" => _id}, _session, socket) do
    {:ok, push_navigate(socket, to: ~p"/changelog")}
  end
end
