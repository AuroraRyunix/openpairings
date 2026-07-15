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

  # Nothing here is user-editable except the manual-ranking controls below
  # — standings are otherwise read-only — so any broadcast can just refresh
  # everything, including the tournament (its tiebreak configuration drives
  # which columns are shown, and `manual_ranking` drives the banner/order).
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
        {:noreply, socket |> assign(tournament: tournament) |> reload_standings()}
    end
  end

  # SWAR parity #23 (manual standings override) — see docs/manual-standings.md
  # and PairingsEngine.Tournaments' "Manual standings override" section for
  # the seeding/staleness design. Not offered for Keizer tournaments (see
  # `reload_standings/1` below) so these handlers are unreachable from the
  # Keizer half of the page — nothing here needs to re-check `keizer?`.
  @impl true
  def handle_event("enable_manual_ranking", _params, socket) do
    {:ok, tournament} = Tournaments.enable_manual_ranking(socket.assigns.tournament)
    {:noreply, socket |> assign(tournament: tournament) |> reload_standings()}
  end

  @impl true
  def handle_event("disable_manual_ranking", _params, socket) do
    {:ok, tournament} = Tournaments.disable_manual_ranking(socket.assigns.tournament)
    {:noreply, socket |> assign(tournament: tournament) |> reload_standings()}
  end

  @impl true
  def handle_event("reseed_manual_ranking", _params, socket) do
    {:ok, tournament} = Tournaments.reseed_manual_ranking(socket.assigns.tournament)
    {:noreply, socket |> assign(tournament: tournament) |> reload_standings()}
  end

  @impl true
  def handle_event("manual_move", %{"player_id" => player_id, "direction" => direction}, socket) do
    player = Tournaments.get_player!(player_id)
    direction = String.to_existing_atom(direction)

    tournament = socket.assigns.tournament

    socket =
      case Tournaments.move_manual_rank(tournament, player, direction) do
        {:ok, _} -> assign(socket, tournament: %{tournament | manual_ranking_stale: false})
        {:error, _} -> socket
      end

    {:noreply, reload_standings(socket)}
  end

  # Keizer tournaments show their own ladder (rank/value/Keizer points)
  # instead of the FIDE-tiebreak table — see PairingsEngine.Keizer.standings/1
  # and docs/pairing-systems.md. Everything else on this page (PubSub
  # refresh, the print/public links) is unaffected either way.
  #
  # Manual ranking (SWAR parity #23) is deliberately not offered for Keizer
  # — its ladder is recomputed on the fly every render and stored nowhere
  # (see docs/manual-standings.md for the reasoning), so `entries` only
  # ever gets `Standings.apply_manual_ranking/2` applied on the non-Keizer
  # branch, and the manual-ranking assigns below are simply `false`/`[]`
  # for a Keizer tournament — the template never shows the banner/controls.
  defp reload_standings(socket) do
    tournament = socket.assigns.tournament
    keizer? = tournament.pairing_system == "keizer"

    entries =
      if keizer? do
        Keizer.standings(tournament)
      else
        tournament
        |> Standings.standings()
        |> with_expected_score()
        |> Standings.apply_manual_ranking(tournament)
      end

    assign(socket,
      keizer?: keizer?,
      entries: entries,
      rounds_paired: Standings.rounds_paired(tournament.id),
      manual_stale?:
        !keizer? and tournament.manual_ranking and Standings.manual_ranking_stale?(tournament),
      manual_incomplete?:
        !keizer? and tournament.manual_ranking and Standings.manual_ranking_incomplete?(entries)
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

      opponent_ratings =
        Enum.map(rated_games, &Player.rating(Map.get(players_by_id, &1.opponent_id)))

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
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      tournament={@tournament}
      active="standings"
    >
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

      <div :if={!@keizer?} class="card manual-ranking-card" style="margin-bottom: 12px">
        <div
          :if={@tournament.manual_ranking}
          class="manual-ranking-banner"
          style="margin-bottom: 8px; padding: 8px 12px; border: 2px solid var(--color-warning, #b45309); border-radius: 6px;"
        >
          <strong>Manual ranking is ON.</strong>
          The rank column below reflects the arbiter's
          hand-set order, not the computed tiebreak order — this also applies on the public
          standings page, printed standings, and the TRF export.
          <span :if={@manual_incomplete?}>
            A player was added after this was turned on and hasn't been placed yet — new players
            sort last until you re-seed.
          </span>

          <span :if={@manual_stale?}>
            <strong>A result changed since this order was last set — it may no longer match the
            real standings.</strong>
          </span>
        </div>

        <div class="actions" style="margin: 0">
          <button
            :if={!@tournament.manual_ranking}
            class="pe-btn"
            phx-click="enable_manual_ranking"
            data-confirm="Switch to manual ranking? The current computed order will be used as the starting point."
          >
            Enable manual ranking
          </button>

          <button :if={@tournament.manual_ranking} class="pe-btn" phx-click="disable_manual_ranking">
            Disable manual ranking
          </button>

          <button
            :if={@tournament.manual_ranking and (@manual_stale? or @manual_incomplete?)}
            class="pe-btn"
            phx-click="reseed_manual_ranking"
          >
            Re-seed from current order
          </button>
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

              <th
                :if={@tournament.count_extra_points}
                class="num"
                title="Administrative bonus points (SWAR XtPts)"
              >
                XtPts
              </th>

              <th
                :if={@tournament.count_extra_points}
                class="num"
                title="Points + extra points — this is what ranking sorts by"
              >
                Total
              </th>

              <th class="num" title="FIDE expected score (Table 8.1.2)">We</th>

              <th class="num" title="Actual score minus expected score">W-We</th>

              <th :for={code <- @tournament.tiebreaks} class="num" title={tb_name(code)}>
                {code}
              </th>

              <th :if={@tournament.manual_ranking}>Reorder</th>
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

              <td :if={@tournament.manual_ranking}>
                <button
                  class="pe-btn"
                  style="padding: 2px 9px; font-size: 13px;"
                  phx-click="manual_move"
                  phx-value-player_id={entry.player.id}
                  phx-value-direction="up"
                  aria-label={"Move #{entry.player.name} up"}
                >
                  ↑
                </button>

                <button
                  class="pe-btn"
                  style="padding: 2px 9px; font-size: 13px;"
                  phx-click="manual_move"
                  phx-value-player_id={entry.player.id}
                  phx-value-direction="down"
                  aria-label={"Move #{entry.player.name} down"}
                >
                  ↓
                </button>
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
