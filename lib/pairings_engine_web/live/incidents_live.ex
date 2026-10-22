defmodule PairingsEngineWeb.IncidentsLive do
  @moduledoc """
  The tournament's incidents (`/t/:id/incidents`): what the phones -
  Manubrium, docs/manubrium.md - logged at the boards, newest first,
  optionally one round at a time (`?round=N`).

  Live: a helper's "arbiter call" is no use to an arbiter who reads it at
  the end of the round, so a new one appears here as it arrives. Each can be
  marked handled - it stays, unhighlighted, because an arbiter call that is
  still lit up three rounds later is a fire alarm nobody can switch off - or
  removed behind a confirm. Both are audit-logged. A photo taken with the incident is shown small and opens full
  size, from `PairingsEngineWeb.IncidentPhotoController` - behind the same
  sign-in as this page, and nowhere else.
  """
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.Incidents
  alias PairingsEngine.Tournaments
  alias PairingsEngineWeb.Components.Manubrium
  alias PairingsEngineWeb.SettingsSupport

  import PairingsEngineWeb.Components.LocalTime, only: [local_time: 1]

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

  @impl true
  def handle_event("toggle_handled", %{"id" => id}, socket) do
    %{tournament: t, current_scope: scope} = socket.assigns
    handled? = not handled?(socket, id)

    case Incidents.set_handled(t.id, id, handled?, scope) do
      {:ok, incident} ->
        message =
          if handled?,
            do: gettext("Board %{board}: marked handled.", board: incident.board),
            else: gettext("Board %{board}: open again.", board: incident.board)

        {:noreply, socket |> put_flash(:info, message) |> load()}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, refusal(reason)) |> load()}
    end
  end

  def handle_event("delete_incident", %{"id" => id}, socket) do
    %{tournament: t, current_scope: scope} = socket.assigns

    case Incidents.delete(t.id, id, scope) do
      {:ok, incident} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("The incident on board %{board} (round %{round}) was removed.",
             board: incident.board,
             round: incident.round_number
           )
         )
         |> load()}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, refusal(reason)) |> load()}
    end
  end

  defp handled?(socket, id) do
    Enum.any?(socket.assigns.incidents, &(to_string(&1.id) == to_string(id) and &1.handled_at))
  end

  defp refusal(:not_found), do: gettext("That incident is no longer there.")
  defp refusal(reason), do: SettingsSupport.error_text(reason)

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

  defp source(%{user: %PairingsEngine.Accounts.User{} = user}),
    do: PairingsEngine.Accounts.User.display_label(user)

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

      <%!-- Eight columns: on a phone the card scrolls sideways, the page
            does not. The note is the one cell worth reading in full, so it
            wraps instead of stretching the table to the next county. --%>
      <div :if={@incidents != []} id="incidents-card" class="card table-card">
        <table id="incidents" class="pe-table">
          <thead>
            <tr>
              <th>{gettext("Time")}</th>

              <th class="num">{gettext("Round")}</th>

              <th class="num">{gettext("Board")}</th>

              <th>{gettext("What")}</th>

              <th>{gettext("Players")}</th>

              <th>{gettext("Note")}</th>

              <th>{gettext("Photo")}</th>

              <th>{gettext("From")}</th>

              <th><span class="sr-only">{gettext("Actions")}</span></th>
            </tr>
          </thead>

          <tbody>
            <tr
              :for={i <- @incidents}
              id={"incident-#{i.id}"}
              class={[
                i.handled_at && "incident-handled",
                i.kind == "arbiter_call" && is_nil(i.handled_at) && "incident-call"
              ]}
            >
              <td>
                <.local_time id={"incident-at-#{i.id}"} at={i.occurred_at} format="stamp" />
              </td>

              <td class="num">{i.round_number}</td>

              <td class="num">{i.board}</td>

              <td><strong>{Manubrium.kind_label(i.kind)}</strong></td>

              <td>
                {player_name(i.white_player, i.white_name)} - {player_name(
                  i.black_player,
                  i.black_name
                )}
              </td>

              <td style="white-space: normal; min-width: 12rem;">{i.note}</td>

              <td>
                <a
                  :if={i.has_photo}
                  href={~p"/t/#{@tournament.id}/incidents/#{i.id}/photo"}
                  target="_blank"
                  rel="noopener"
                  id={"incident-photo-#{i.id}"}
                  class="incident-photo"
                >
                  <img
                    src={~p"/t/#{@tournament.id}/incidents/#{i.id}/photo"}
                    alt={gettext("Photo of board %{board}", board: i.board)}
                    loading="lazy"
                    width="72"
                  />
                </a>
              </td>

              <td class="hint">{source(i)}</td>

              <td class="incident-actions">
                <button
                  type="button"
                  id={"incident-handled-#{i.id}"}
                  class={["pe-btn", i.handled_at && "is-on"]}
                  phx-click="toggle_handled"
                  phx-value-id={i.id}
                  aria-pressed={to_string(not is_nil(i.handled_at))}
                  disabled={not is_nil(@tournament.archived_at)}
                >
                  <.icon
                    name={if i.handled_at, do: "hero-check-circle-solid", else: "hero-check-circle"}
                    class="w-4 h-4"
                  /> {if i.handled_at, do: gettext("Handled"), else: gettext("Mark handled")}
                </button>

                <button
                  type="button"
                  id={"incident-delete-#{i.id}"}
                  class="pe-btn danger-link"
                  phx-click="delete_incident"
                  phx-value-id={i.id}
                  disabled={not is_nil(@tournament.archived_at)}
                  data-confirm={
                    gettext(
                      "Remove the incident on board %{board} (round %{round}), with its note and photo? The audit trail keeps a line saying it existed; the incident itself cannot be brought back.",
                      board: i.board,
                      round: i.round_number
                    )
                  }
                >
                  {gettext("Remove")}
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end
end
