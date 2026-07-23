defmodule PairingsEngineWeb.MobileResultsLive do
  @moduledoc """
  The no-account mobile result-entry screen. Reached only via an active
  enrollment (see `PairingsEngineWeb.MobileAuth`), scoped to that one
  tournament. A helper taps a board and picks the result - nothing else is
  reachable from here.
  """
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments
  alias PairingsEngine.Tournaments.Pairing

  @results [{"1-0", "1–0"}, {"1/2-1/2", "½–½"}, {"0-1", "0–1"}]

  @impl true
  def mount(_params, _session, socket) do
    tournament = socket.assigns.tournament

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    paired = Engine.paired_rounds_count(tournament.id)

    {:ok,
     socket
     |> assign(page_title: "Enter results", results: @results, paired: paired)
     |> load_round(max(paired, 1))}
  end

  @impl true
  def handle_info({:tournament_changed, _id, _hint}, socket) do
    {:noreply, load_round(socket, socket.assigns.round_number)}
  end

  @impl true
  def handle_event("select_round", %{"number" => number}, socket) do
    {:noreply, load_round(socket, String.to_integer(number))}
  end

  # Only pairings belonging to the loaded round (which is loaded from the
  # enrollment's own tournament) can be set - a crafted pairing id from
  # another tournament simply isn't in the set and is ignored.
  def handle_event("set_result", %{"id" => id, "result" => result}, socket)
      when result in ["1-0", "1/2-1/2", "0-1", ""] do
    round = socket.assigns.round

    case round && Enum.find(round.pairings, &(to_string(&1.id) == id)) do
      %Pairing{} = pairing ->
        Tournaments.update_pairing_result(pairing, result)
        {:noreply, load_round(socket, socket.assigns.round_number)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("set_result", _params, socket), do: {:noreply, socket}

  defp load_round(socket, number) do
    round = Tournaments.get_round(socket.assigns.tournament.id, number)

    boards =
      case round do
        nil -> []
        r -> r.pairings |> Enum.reject(&(&1.black_player_id == nil)) |> Enum.sort_by(& &1.board)
      end

    assign(socket, round_number: number, round: round, boards: boards)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mobile-shell">
      <header class="mobile-header">
        <div>
          <div class="mobile-brand">Open<strong>Pairings</strong></div>
          <div class="mobile-tname">{@tournament.name}</div>
        </div>
        <.link href={~p"/m/leave"} class="mobile-leave">Leave</.link>
      </header>

      <div :if={@paired > 1} class="mobile-rounds">
        <button
          :for={n <- 1..@paired}
          type="button"
          class={["mobile-round-btn", n == @round_number && "active"]}
          phx-click="select_round"
          phx-value-number={n}
        >
          R{n}
        </button>
      </div>

      <p class="mobile-hint">Round {@round_number} · tap a result for each board</p>

      <div :if={@boards == []} class="mobile-empty">No boards paired for this round yet.</div>

      <div :for={p <- @boards} class="mobile-board">
        <div class="mobile-board-head">
          <span class="mobile-board-no">Board {p.board}</span>
        </div>
        <div class="mobile-players">
          <span class="mobile-white">{p.white_player && p.white_player.name}</span>
          <span class="mobile-vs">vs</span>
          <span class="mobile-black">{p.black_player && p.black_player.name}</span>
        </div>
        <div class="mobile-results">
          <button
            :for={{value, label} <- @results}
            type="button"
            class={["mobile-result-btn", p.result == value && "chosen"]}
            phx-click="set_result"
            phx-value-id={p.id}
            phx-value-result={value}
          >
            {label}
          </button>
          <button
            :if={p.result != ""}
            type="button"
            class="mobile-result-btn mobile-clear"
            phx-click="set_result"
            phx-value-id={p.id}
            phx-value-result=""
            title="Clear the result"
          >
            ⟲
          </button>
        </div>
      </div>
    </div>
    """
  end
end
