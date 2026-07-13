defmodule PairingsEngineWeb.LiveRoundLive do
  @moduledoc """
  Read-only "projector" view of a tournament's latest paired round: the
  pairing list with live results, and current standings below it. Meant to
  be popped into its own tab/window (see the "Open live view" link on
  PairingsLive) and left open — it subscribes to the same tournament topic
  as every other tournament-scoped view and updates the instant a result is
  entered elsewhere, no polling.
  """

  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{Tournaments, Standings, Tiebreaks, Keizer}
  alias PairingsEngine.Pairing, as: Engine

  @result_labels %{
    "1-0" => "1-0",
    "1/2-1/2" => "½-½",
    "0-1" => "0-1",
    "1-0FF" => "1-0 FF",
    "0-1FF" => "0-1 FF",
    "0-0FF" => "0-0 FF",
    "0-0" => "0-0"
  }

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     socket
     |> assign(tournament: tournament, page_title: "#{tournament.name} · Live")
     |> reload()}
  end

  # Purely a display page — nothing here is user-editable, so every
  # broadcast just reloads everything.
  @impl true
  def handle_info({:tournament_changed, _tournament_id, _hint}, socket) do
    case Tournaments.get_authorized_tournament(socket.assigns.current_scope, socket.assigns.tournament.id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "This tournament was deleted.")
         |> push_navigate(to: ~p"/")}

      tournament ->
        {:noreply, socket |> assign(tournament: tournament) |> reload()}
    end
  end

  # Keizer tournaments show their own ladder (rank/value/Keizer points)
  # instead of the FIDE-tiebreak table — see PairingsEngine.Keizer.standings/1
  # and docs/pairing-systems.md, same as StandingsLive/PublicStandingsLive.
  defp reload(socket) do
    tournament = socket.assigns.tournament
    paired = Engine.paired_rounds_count(tournament.id)
    keizer? = tournament.pairing_system == "keizer"

    assign(socket,
      round_number: paired,
      round: paired > 0 && Tournaments.get_round(tournament.id, paired),
      keizer?: keizer?,
      entries: if(keizer?, do: Keizer.standings(tournament), else: Standings.standings(tournament))
    )
  end

  defp player_label(nil), do: ""

  defp player_label(player) do
    rating = PairingsEngine.Tournaments.Player.rating(player)

    "#{if player.title != "", do: "#{player.title} "}#{player.name}" <>
      if(rating > 0, do: " (#{rating})", else: "")
  end

  defp result_label(result), do: Map.get(@result_labels, result, result)

  defp format_tb(value) when is_float(value) do
    if value == Float.round(value, 0), do: trunc(value), else: value
  end

  defp format_tb(value), do: value

  defp tb_name(code), do: (Tiebreaks.get(code) || %{name: code}).name

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} tournament={@tournament} active="live">
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">
            <%= if @round_number > 0 do %>
              Live &middot; Round {@round_number}
            <% else %>
              Live &middot; no rounds paired yet
            <% end %>
          </p>
        </div>
      </div>

      <div :if={@round == nil} class="card empty">
        <p><strong>No round has been paired yet.</strong></p>
      </div>

      <div :if={@round} class="card table-card">
        <table class="pe-table">
          <thead>
            <tr>
              <th class="num">Board</th>
              <th>White</th>
              <th style="text-align: center; width: 160px">Result</th>
              <th>Black</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={pairing <- @round.pairings}>
              <td class="num">{pairing.board}</td>
              <td><strong>{player_label(pairing.white_player)}</strong></td>
              <td style="text-align: center">
                <%= cond do %>
                  <% pairing.result == "bye" -> %>
                    <span class="badge">bye ({@tournament.bye_value} pt)</span>
                  <% pairing.result == "" -> %>
                    <span class="badge muted">in progress</span>
                  <% true -> %>
                    <span class="badge">{result_label(pairing.result)}</span>
                <% end %>
              </td>
              <td>{player_label(pairing.black_player)}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <h2 style="margin-top: 32px">Standings</h2>

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
                {if PairingsEngine.Tournaments.Player.rating(entry.player) > 0,
                  do: PairingsEngine.Tournaments.Player.rating(entry.player),
                  else: "—"}
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
                {if PairingsEngine.Tournaments.Player.rating(entry.player) > 0,
                  do: PairingsEngine.Tournaments.Player.rating(entry.player),
                  else: "—"}
              </td>
              <td class="num">{entry.value}</td>
              <td class="num"><strong>{entry.points}</strong></td>
              <td class="num">{entry.raw_points}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end
end
