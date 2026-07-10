defmodule PairingsEngineWeb.StandingsLive do
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{Tournaments, Tiebreaks, Standings}
  alias PairingsEngine.Tournaments.Player

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_user_tournament!(socket.assigns.current_scope, id)

    {:ok,
     assign(socket,
       tournament: tournament,
       page_title: "#{tournament.name} · Standings",
       entries: Standings.standings(tournament),
       rounds_paired: Standings.rounds_paired(tournament.id)
     )}
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
      </div>

      <div :if={@entries == []} class="card empty">
        <p><strong>No players registered yet.</strong></p>
      </div>

      <div :if={@entries != []} class="card table-card">
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

      <p :if={@rounds_paired == 0} class="hint">
        Tiebreak columns fill in as results are entered, following the FIDE Tie-Break
        Regulations in the order set under Settings.
      </p>
    </Layouts.app>
    """
  end

  defp tb_name(code), do: (Tiebreaks.get(code) || %{name: code}).name
end
