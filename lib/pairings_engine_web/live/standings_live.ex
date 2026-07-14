defmodule PairingsEngineWeb.StandingsLive do
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{Tournaments, Tiebreaks, Standings, Keizer}
  alias PairingsEngine.Tournaments.Player

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     socket
     |> assign(tournament: tournament, page_title: "#{tournament.name} · Standings")
     |> reload_standings()}
  end

  # Nothing here is user-editable — standings are read-only — so any
  # broadcast can just refresh everything, including the tournament (its
  # tiebreak configuration drives which columns are shown).
  @impl true
  def handle_info({:tournament_changed, _tournament_id, _hint}, socket) do
    case Tournaments.get_authorized_tournament(socket.assigns.current_scope, socket.assigns.tournament.id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "This tournament was deleted.")
         |> push_navigate(to: ~p"/")}

      tournament ->
        {:noreply, socket |> assign(tournament: tournament) |> reload_standings()}
    end
  end

  # Keizer tournaments show their own ladder (rank/value/Keizer points)
  # instead of the FIDE-tiebreak table — see PairingsEngine.Keizer.standings/1
  # and docs/pairing-systems.md. Everything else on this page (PubSub
  # refresh, the print/public links) is unaffected either way.
  defp reload_standings(socket) do
    tournament = socket.assigns.tournament
    keizer? = tournament.pairing_system == "keizer"

    assign(socket,
      keizer?: keizer?,
      entries: if(keizer?, do: Keizer.standings(tournament), else: Standings.standings(tournament)),
      rounds_paired: Standings.rounds_paired(tournament.id)
    )
  end

  defp format_tb(value) when is_float(value) do
    if value == Float.round(value, 0), do: trunc(value), else: value
  end

  defp format_tb(value), do: value

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} tournament={@tournament} active="standings">
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">
            Standings{if @rounds_paired > 0, do: " after round #{@rounds_paired}"}
          </p>
        </div>
        <div class="actions" style="margin: 0">
          <a
            class="pe-btn"
            href={~p"/p/#{@tournament.public_slug}/standings"}
            target="_blank"
            title="No login needed — share this link"
          >
            Public standings link
          </a>
          <a class="pe-btn" href={~p"/t/#{@tournament.id}/print/standings"} target="_blank">
            Print
          </a>
        </div>
      </div>

      <div :if={@entries == []} class="card empty">
        <p><strong>No players registered yet.</strong></p>
      </div>

      <div :if={@entries != [] and !@keizer?} class="card table-card">
        <table class="pe-table">
          <thead>
            <tr>
              <th class="num">Rank</th>
              <th>Name</th>
              <th class="num">Elo</th>
              <th class="num">Pts</th>
              <th :for={code <- @tournament.tiebreaks} class="num" title={tb_name(code)}>
                {code}
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={entry <- @entries}>
              <td class="num">{entry.rank}</td>
              <td>
                <strong>
                  {if entry.player.title != "", do: "#{entry.player.title} "}{entry.player.name}
                </strong>
              </td>
              <td class="num">
                {if Player.rating(entry.player) > 0, do: Player.rating(entry.player), else: "—"}
              </td>
              <td class="num"><strong>{entry.points}</strong></td>
              <td :for={code <- @tournament.tiebreaks} class="num">
                {format_tb(Map.get(entry.tiebreaks, code, 0.0))}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <p :if={@rounds_paired == 0 and !@keizer?} class="hint">
        Tiebreak columns fill in as results are entered, following the FIDE Tie-Break
        Regulations in the order set under Settings.
      </p>

      <div :if={@entries != [] and @keizer?} class="card table-card">
        <table class="pe-table">
          <thead>
            <tr>
              <th class="num">Rank</th>
              <th>Name</th>
              <th class="num">Elo</th>
              <th class="num">Value</th>
              <th class="num">Keizer pts</th>
              <th class="num">Score</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={entry <- @entries}>
              <td class="num">{entry.rank}</td>
              <td>
                <strong>
                  {if entry.player.title != "", do: "#{entry.player.title} "}{entry.player.name}
                </strong>
              </td>
              <td class="num">
                {if Player.rating(entry.player) > 0, do: Player.rating(entry.player), else: "—"}
              </td>
              <td class="num">{entry.value}</td>
              <td class="num"><strong>{entry.points}</strong></td>
              <td class="num">{entry.raw_points}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <p :if={@keizer?} class="hint">
        Keizer points, not FIDE tiebreaks — the whole ladder is recalculated from
        results, byes and absences every time (see docs/pairing-systems.md).
      </p>
    </Layouts.app>
    """
  end

  defp tb_name(code), do: (Tiebreaks.get(code) || %{name: code}).name
end
