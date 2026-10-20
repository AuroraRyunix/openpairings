defmodule PairingsEngineWeb.IncidentsLive do
  @moduledoc """
  The tournament's incidents (`/t/:id/incidents`): what the phones -
  Manubrium, docs/manubrium.md - logged at the boards, newest first,
  optionally one round at a time (`?round=N`).

  Read-only in phase 1, and live: a helper's "arbiter call" is no use to an
  arbiter who reads it at the end of the round, so a new one appears here as
  it arrives. Printing, editing and the desk's own entries are phase 2; the
  rows already carry what those need.
  """
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.Incidents
  alias PairingsEngine.Tournaments
  alias PairingsEngineWeb.Components.Manubrium

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Incidents.topic(tournament.id))
    end

    {:ok,
     assign(socket,
       tournament: tournament,
       page_title: gettext("Incidents"),
       round: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    round =
      case Integer.parse(to_string(params["round"] || "")) do
        {n, ""} when n > 0 -> n
        _ -> nil
      end

    {:noreply, socket |> assign(round: round) |> load()}
  end

  @impl true
  def handle_info({:incident_logged, _tournament_id, _round}, socket),
    do: {:noreply, load(socket)}

  defp load(socket) do
    %{tournament: t, round: round} = socket.assigns

    assign(socket,
      incidents: Incidents.list(t.id, round_number: round),
      counts: Incidents.counts_by_round(t.id)
    )
  end

  # The player as they are now, or as the board showed them if the row has
  # gone (a snapshot restore recreates players).
  defp player_name(nil, ""), do: "-"
  defp player_name(nil, snapshot), do: snapshot
  defp player_name(player, _snapshot), do: player.name

  defp at(%DateTime{} = dt), do: Calendar.strftime(dt, "%d %b %H:%M")

  defp source(%{enrollment_label: label}) when label not in [nil, ""],
    do: gettext("Phone \"%{label}\"", label: label)

  defp source(_incident), do: gettext("Phone")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      update_notice={assigns[:update_notice]}
      fide_notice={assigns[:fide_notice]}
      flash={@flash}
      current_path={assigns[:current_path]}
      current_scope={@current_scope}
      tournament={@tournament}
      active="pairings"
    >
      <div class="page-header">
        <div>
          <h1>{gettext("Incidents")}</h1>
          <p class="subtitle" style="margin: 0">
            {gettext(
              "Logged at the boards from phones (Manubrium). Times are the phone's clock when it was plausible."
            )}
          </p>
        </div>
      </div>

      <nav :if={map_size(@counts) > 0} id="incident-rounds" class="incident-rounds">
        <.link
          patch={~p"/t/#{@tournament.id}/incidents"}
          class={["pe-btn", is_nil(@round) && "primary"]}
        >
          {gettext("All rounds")}
        </.link>
        <.link
          :for={{n, count} <- Enum.sort(@counts)}
          id={"incident-round-#{n}"}
          patch={~p"/t/#{@tournament.id}/incidents?round=#{n}"}
          class={["pe-btn", @round == n && "primary"]}
        >
          {gettext("Round %{n}", n: n)} ({count})
        </.link>
      </nav>

      <p :if={@incidents == []} id="incidents-empty" class="hint">
        {gettext(
          "Nothing logged. A deputy phone logs an incident from its board; a helper phone can call the arbiter to a board."
        )}
      </p>

      <table :if={@incidents != []} id="incidents" class="pe-table">
        <thead>
          <tr>
            <th>{gettext("Time")}</th>
            <th class="num">{gettext("Round")}</th>
            <th class="num">{gettext("Board")}</th>
            <th>{gettext("What")}</th>
            <th>{gettext("Players")}</th>
            <th>{gettext("Note")}</th>
            <th>{gettext("From")}</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={i <- @incidents}
            id={"incident-#{i.id}"}
            class={[i.kind == "arbiter_call" && "incident-call"]}
          >
            <td>{at(i.occurred_at)}</td>
            <td class="num">{i.round_number}</td>
            <td class="num">{i.board}</td>
            <td><strong>{Manubrium.kind_label(i.kind)}</strong></td>
            <td>
              {player_name(i.white_player, i.white_name)} - {player_name(
                i.black_player,
                i.black_name
              )}
            </td>
            <td>{i.note}</td>
            <td class="hint">{source(i)}</td>
          </tr>
        </tbody>
      </table>
    </Layouts.app>
    """
  end
end
