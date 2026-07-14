defmodule PairingsEngineWeb.PublicStandingsLive do
  @moduledoc """
  Public (no login required) read-only view of a tournament's current
  standings — reachable at `/p/:slug/standings` where `:slug` is the
  tournament's unguessable `public_slug` (see docs/public-pages.md), not
  its numeric id. Anyone holding the link can view it; nothing here is
  editable. Subscribes to the tournament's PubSub topic and reloads live
  when results are entered elsewhere, same as the authenticated pages.
  """

  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{Tournaments, Tiebreaks, Standings, Keizer}
  alias PairingsEngine.Tournaments.Player

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    tournament = Tournaments.get_tournament_by_public_slug(slug) || raise Ecto.NoResultsError, queryable: Tournaments.Tournament

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     socket
     |> assign(tournament: tournament, slug: slug, page_title: "#{tournament.name} · Standings", gone: false)
     |> reload_standings()}
  end

  @impl true
  def handle_info({:tournament_changed, _tournament_id, _hint}, socket) do
    case Tournaments.get_tournament_by_public_slug(socket.assigns.slug) do
      nil -> {:noreply, assign(socket, gone: true)}
      tournament -> {:noreply, socket |> assign(tournament: tournament) |> reload_standings()}
    end
  end

  # Keizer tournaments show their own ladder (rank/value/Keizer points)
  # instead of the FIDE-tiebreak table — see PairingsEngine.Keizer.standings/1
  # and docs/pairing-systems.md, and StandingsLive (the authenticated
  # equivalent of this page), which does the same.
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

  defp tb_name(code), do: (Tiebreaks.get(code) || %{name: code}).name

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div :if={@gone} class="card empty">
        <p><strong>This tournament is no longer available.</strong></p>
      </div>

      <div :if={!@gone}>
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
          results, byes and absences every time.
        </p>
      </div>
    </Layouts.app>
    """
  end
end
