defmodule PairingsEngineWeb.StandingsLive do
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{Tournaments, Tiebreaks, Standings, Keizer, PlayerStats}
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

    entries =
      if keizer? do
        Keizer.standings(tournament)
      else
        tournament |> Standings.standings() |> with_expected_score()
      end

    assign(socket,
      keizer?: keizer?,
      entries: entries,
      rounds_paired: Standings.rounds_paired(tournament.id)
    )
  end

  # Attaches `:we` / `:wmwe` (FIDE expected score / W−We, Table 8.1.2) to
  # every entry — same computation as the Players page grid
  # (`PairingsEngineWeb.PlayersLive.build_grid/2`): only played games
  # against a rated opponent count, own rating unrated or zero counted
  # games renders blank. Not offered for Keizer standings — Keizer scoring
  # isn't rating-based, so an "expected score" has no meaning there.
  defp with_expected_score(entries) do
    players_by_id = Map.new(entries, &{&1.player.id, &1.player})

    Enum.map(entries, fn entry ->
      played_games = Enum.filter(entry.games, & &1.played)

      rated_games =
        Enum.filter(played_games, fn g ->
          case Map.get(players_by_id, g.opponent_id) do
            nil -> false
            opp -> Player.rating(opp) > 0
          end
        end)

      own_rating = Player.rating(entry.player)
      opponent_ratings = Enum.map(rated_games, &Player.rating(Map.get(players_by_id, &1.opponent_id)))
      we = PlayerStats.we(own_rating, opponent_ratings)
      w_counted = rated_games |> Enum.map(& &1.points) |> Enum.sum()

      Map.merge(entry, %{we: we, wmwe: PlayerStats.w_minus_we(w_counted, we)})
    end)
  end

  defp format_tb(value) when is_float(value) do
    if value == Float.round(value, 0), do: trunc(value), else: value
  end

  defp format_tb(value), do: value

  defp format_we(nil), do: "—"
  defp format_we(n), do: :erlang.float_to_binary(n / 1, decimals: 2)

  defp format_wmwe(nil), do: "—"

  defp format_wmwe(n) do
    sign = if n >= 0, do: "+", else: ""
    sign <> :erlang.float_to_binary(n / 1, decimals: 2)
  end

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
              <th :if={@tournament.count_extra_points} class="num" title="Administrative bonus points (SWAR XtPts)">
                XtPts
              </th>
              <th :if={@tournament.count_extra_points} class="num" title="Points + extra points — this is what ranking sorts by">
                Total
              </th>
              <th class="num" title="FIDE expected score (Table 8.1.2)">We</th>
              <th class="num" title="Actual score minus expected score">W-We</th>
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
              <td :if={@tournament.count_extra_points} class="num">{entry.extra_points}</td>
              <td :if={@tournament.count_extra_points} class="num"><strong>{entry.total}</strong></td>
              <td class="num">{format_we(entry.we)}</td>
              <td class="num">{format_wmwe(entry.wmwe)}</td>
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
