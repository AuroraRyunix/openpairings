defmodule PairingsEngineWeb.PublicPairingsLive do
  @moduledoc """
  Public (no login required) read-only view of a tournament's latest paired
  round — reachable at `/p/:slug/pairings` where `:slug` is the
  tournament's unguessable `public_slug` (see docs/public-pages.md), not
  its numeric id. Anyone holding the link can view it; nothing here is
  editable. Subscribes to the tournament's PubSub topic and reloads live
  when results are entered elsewhere, same as the authenticated pages.
  """

  use PairingsEngineWeb, :live_view

  alias PairingsEngine.Tournaments
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
  def mount(%{"slug" => slug}, _session, socket) do
    tournament = Tournaments.get_tournament_by_public_slug(slug) || raise Ecto.NoResultsError, queryable: Tournaments.Tournament

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     socket
     |> assign(tournament: tournament, slug: slug, page_title: "#{tournament.name} · Pairings", gone: false)
     |> reload()}
  end

  @impl true
  def handle_info({:tournament_changed, _tournament_id, _hint}, socket) do
    case Tournaments.get_tournament_by_public_slug(socket.assigns.slug) do
      nil -> {:noreply, assign(socket, gone: true)}
      tournament -> {:noreply, socket |> assign(tournament: tournament) |> reload()}
    end
  end

  defp reload(socket) do
    tournament = socket.assigns.tournament
    paired = Engine.paired_rounds_count(tournament.id)

    assign(socket,
      round_number: paired,
      round: paired > 0 && Tournaments.get_round(tournament.id, paired)
    )
  end

  defp player_label(nil), do: ""

  defp player_label(player) do
    rating = PairingsEngine.Tournaments.Player.rating(player)

    "#{if player.title != "", do: "#{player.title} "}#{player.name}" <>
      if(rating > 0, do: " (#{rating})", else: "")
  end

  defp result_label(result), do: Map.get(@result_labels, result, result)

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
              <%= if @round_number > 0 do %>
                Pairings &middot; Round {@round_number}
              <% else %>
                Pairings &middot; no rounds paired yet
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
      </div>
    </Layouts.app>
    """
  end
end
