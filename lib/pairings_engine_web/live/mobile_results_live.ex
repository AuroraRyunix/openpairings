defmodule PairingsEngineWeb.MobileResultsLive do
  @moduledoc """
  The no-account mobile result-entry screen. Reached only via an active
  enrollment (see `PairingsEngineWeb.MobileAuth`), scoped to that one
  tournament. A helper taps a board and picks the result - nothing else is
  reachable from here.
  """
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.{Mobile, Standings, Tournaments}
  alias PairingsEngine.Tournaments.{Pairing, Player}

  @results [{"1-0", "1-0"}, {"1/2-1/2", "½-½"}, {"0-1", "0-1"}]

  @impl true
  def mount(_params, _session, socket) do
    tournament = socket.assigns.tournament

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    paired = Engine.paired_rounds_count(tournament.id)

    {:ok,
     socket
     |> assign(page_title: "Enter results", results: @results, paired: paired, locked: false)
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

  # A "hand the phone to someone else / put it down for a second" guard, not
  # a security boundary — off by default (per-session, resets on reload), and
  # purely to stop an accidental tap from overwriting a result. The buttons
  # are also `disabled` client-side, but this is the actual enforcement.
  def handle_event("toggle_lock", _params, socket) do
    {:noreply, assign(socket, locked: !socket.assigns.locked)}
  end

  def handle_event("set_result", _params, socket) when socket.assigns.locked,
    do: {:noreply, socket}

  # Only pairings belonging to the loaded round (which is loaded from the
  # enrollment's own tournament) can be set - a crafted pairing id from
  # another tournament simply isn't in the set and is ignored.
  def handle_event("set_result", %{"id" => id, "result" => result}, socket)
      when result in ["1-0", "1/2-1/2", "0-1", ""] do
    # Re-validate the enrollment on every write so a revoked or expired phone
    # is kicked out immediately, not only on its next page load.
    if Mobile.get_active(socket.assigns.mobile_enrollment.id) do
      round = socket.assigns.round

      case round && Enum.find(round.pairings, &(to_string(&1.id) == id)) do
        %Pairing{} = pairing ->
          Tournaments.update_pairing_result(pairing, result)
          {:noreply, load_round(socket, socket.assigns.round_number)}

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "This phone's access was ended by the arbiter.")
       |> redirect(to: ~p"/m")}
    end
  end

  def handle_event("set_result", _params, socket), do: {:noreply, socket}

  defp load_round(socket, number) do
    tournament = socket.assigns.tournament
    round = Tournaments.get_round(tournament.id, number)

    boards =
      case round do
        nil -> []
        r -> r.pairings |> Enum.reject(&(&1.black_player_id == nil)) |> Enum.sort_by(& &1.board)
      end

    # Score shown alongside each name is the player's total entering this
    # round (same convention as a printed pairing sheet) - not their live
    # score once this round's own results start coming in.
    scores =
      tournament
      |> Standings.standings(through_round: number - 1)
      |> Map.new(&{&1.player.id, &1.points})

    assign(socket, round_number: number, round: round, boards: boards, scores: scores)
  end

  defp player_meta(nil, _scores), do: ""

  defp player_meta(player, scores) do
    rating = Player.rating(player)
    points = format_score(Map.get(scores, player.id, 0.0))

    [if(rating > 0, do: "#{rating}"), "#{points} pts"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp format_score(v) when is_float(v) do
    if v == Float.round(v, 0), do: trunc(v), else: v
  end

  defp format_score(v), do: v

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mobile-shell">
      <header class="mobile-header">
        <div>
          <div class="mobile-brand">Open<strong>Pairings</strong></div>
          <div class="mobile-tname">{@tournament.name}</div>
        </div>
        <div class="mobile-header-actions">
          <button
            type="button"
            class={["mobile-lock-btn", @locked && "active"]}
            phx-click="toggle_lock"
            title={if @locked, do: "Unlock result entry", else: "Lock result entry"}
            aria-label={if @locked, do: "Unlock result entry", else: "Lock result entry"}
          >
            {if @locked, do: "🔒", else: "🔓"}
          </button>
          <Layouts.theme_switch />
          <.link href={~p"/m/leave"} class="mobile-leave">Leave</.link>
        </div>
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

      <p class="mobile-hint">
        Round {@round_number} ·
        <%= if @locked do %>
          🔒 locked - tap the lock to enter results
        <% else %>
          tap a result for each board
        <% end %>
      </p>

      <div :if={@boards == []} class="mobile-empty">No boards paired for this round yet.</div>

      <div :for={p <- @boards} class="mobile-board">
        <div class="mobile-board-head">
          <span class="mobile-board-no">Board {p.board}</span>
        </div>
        <div class="mobile-players">
          <div class="mobile-side">
            <span class="mobile-white">{p.white_player && p.white_player.name}</span>
            <span class="mobile-meta">{player_meta(p.white_player, @scores)}</span>
          </div>
          <span class="mobile-vs">vs</span>
          <div class="mobile-side mobile-side--black">
            <span class="mobile-black">{p.black_player && p.black_player.name}</span>
            <span class="mobile-meta">{player_meta(p.black_player, @scores)}</span>
          </div>
        </div>
        <div class="mobile-results">
          <button
            :for={{value, label} <- @results}
            type="button"
            disabled={@locked}
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
            disabled={@locked}
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
