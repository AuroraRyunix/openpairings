defmodule PairingsEngineWeb.SettingsAboutLive do
  @moduledoc """
  The "About" settings page (`/t/:id/settings/about`) - what OpenPairings is,
  which pairing engine this tournament uses (via
  `PairingsEngine.Tournaments.Tournament.pairing_system_label/1`, the same
  wording `PairingsEngineWeb.PrintController`'s footer credit uses), and the
  same credit line that also appears at the bottom of every printed
  document.
  """
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport

  alias PairingsEngine.Tournaments
  alias PairingsEngine.Tournaments.Tournament

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     assign(socket,
       tournament: tournament,
       page_title: "#{tournament.name} · Settings · About"
     )}
  end

  @impl true
  def handle_info({:tournament_changed, _tournament_id, _hint}, socket) do
    case Tournaments.get_authorized_tournament(
           socket.assigns.current_scope,
           socket.assigns.tournament.id
         ) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "This tournament was deleted.")
         |> push_navigate(to: ~p"/")}

      tournament ->
        {:noreply, assign(socket, tournament: tournament)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      tournament={@tournament}
      active="settings"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">{gettext("Settings - About")}</p>
        </div>
      </div>

      <.settings_subnav tournament={@tournament} active={:about} />

      <div class="card">
        <h2>OpenPairings</h2>
        <p>
          {gettext(
            "A FIDE Swiss / round-robin / Keizer tournament manager - pairing, results, standings, tiebreaks and FIDE reporting in one place."
          )}
        </p>

        <p class="hint" style="margin-bottom: 0">
          <.rich_text text={
            gettext("Version %{version} - %[whats_new]",
              version: Application.spec(:pairings_engine, :vsn)
            )
          }>
            <:part name="whats_new">
              <.link navigate={~p"/t/#{@tournament.id}/settings/changelog"}>
                {gettext("What's new")}
              </.link>
            </:part>
          </.rich_text>
        </p>
      </div>

      <div class="card">
        <h2>{gettext("Pairing engine")}</h2>
        <p>
          <.rich_text text={gettext("This tournament is paired using %[engine].")}>
            <:part name="engine">
              <strong>{engine_line(@tournament)}</strong>
            </:part>
          </.rich_text>
        </p>
      </div>

      <div class="card">
        <h2>{gettext("Credits")}</h2>
        <p>
          <.rich_text text={
            gettext("Many thanks to %[who] for his valuable feedback in the making of OpenPairings.")
          }>
            <:part name="who"><strong>Tom Wuyts</strong></:part>
          </.rich_text>
        </p>
      </div>
    </Layouts.app>
    """
  end
  # Round robin and Keizer name their engine inside the system label
  # already ("Round robin (Berger)"). Swiss does not, because there the
  # engine is a choice - so say which one this tournament is actually on.
  defp engine_line(%{pairing_system: "swiss"} = tournament) do
    Tournament.pairing_system_label("swiss") <>
      " (" <> Tournament.engine_name(tournament) <> ")"
  end

  defp engine_line(tournament),
    do: Tournament.pairing_system_label(tournament.pairing_system)
end
