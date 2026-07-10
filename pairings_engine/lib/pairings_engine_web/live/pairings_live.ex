defmodule PairingsEngineWeb.PairingsLive do
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.Tournaments
  alias PairingsEngine.Pairing, as: Engine

  @results [
    {"", "…"},
    {"1-0", "1-0"},
    {"1/2-1/2", "½-½"},
    {"0-1", "0-1"},
    {"+--", "+/- (Black forfeits)"},
    {"--+", "-/+ (White forfeits)"},
    {"0-0", "0-0 (double forfeit)"}
  ]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_user_tournament!(socket.assigns.current_scope, id)
    paired = Engine.paired_rounds_count(tournament.id)

    {:ok,
     socket
     |> assign(
       tournament: tournament,
       page_title: "#{tournament.name} · Pairings",
       round_number: max(paired, 1),
       error: nil
     )
     |> refresh()}
  end

  defp refresh(socket) do
    %{tournament: t, round_number: n} = socket.assigns
    paired = Engine.paired_rounds_count(t.id)

    assign(socket,
      round: Tournaments.get_round(t.id, n),
      paired_rounds: paired,
      next_pairable: paired + 1,
      can_pair: paired < t.rounds_count and Engine.round_complete?(t.id, paired)
    )
  end

  @impl true
  def handle_event("select_round", %{"number" => number}, socket) do
    {:noreply, socket |> assign(round_number: String.to_integer(number), error: nil) |> refresh()}
  end

  def handle_event("pair", _params, socket) do
    case Engine.pair_next_round(socket.assigns.tournament) do
      {:ok, round} ->
        {:noreply, socket |> assign(round_number: round.number, error: nil) |> refresh()}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, assign(socket, error: "Could not save the round")}

      {:error, reason} ->
        {:noreply, assign(socket, error: to_string(reason))}
    end
  end

  def handle_event("unpair", _params, socket) do
    case Engine.delete_round(socket.assigns.tournament.id, socket.assigns.round_number) do
      :ok -> {:noreply, socket |> assign(error: nil) |> refresh()}
      {:error, reason} -> {:noreply, assign(socket, error: reason)}
    end
  end

  def handle_event("result", %{"pairing-id" => id, "result" => result}, socket) do
    socket.assigns.round.pairings
    |> Enum.find(&(&1.id == String.to_integer(id)))
    |> case do
      nil -> :ok
      pairing -> Tournaments.update_pairing_result(pairing, result)
    end

    {:noreply, refresh(socket)}
  end

  defp results, do: @results

  defp player_label(nil), do: ""

  defp player_label(player) do
    rating = PairingsEngine.Tournaments.Player.rating(player)
    "#{if player.title != "", do: "#{player.title} "}#{player.name}" <>
      if(rating > 0, do: " (#{rating})", else: "")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} tournament={@tournament} active="pairings">
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">Pairings &amp; results</p>
        </div>
      </div>

      <div class="round-picker">
        <button
          :for={n <- 1..@tournament.rounds_count}
          class={["pe-btn", n == @round_number && "active"]}
          phx-click="select_round"
          phx-value-number={n}
        >
          {n}
        </button>
      </div>

      <div class="page-header" style="margin-top: 16px">
        <div>
          <h2 style="margin: 0">Round {@round_number}</h2>
          <p class="subtitle" style="margin: 0">
            <span class={["badge", @round == nil && "muted"]}>
              {cond do
                @round == nil -> "not paired"
                Enum.any?(@round.pairings, &(&1.result == "")) -> "playing"
                true -> "finished"
              end}
            </span>
          </p>
        </div>
        <div class="actions" style="margin: 0">
          <button
            :if={@round == nil && @round_number == @next_pairable}
            class="pe-btn primary"
            phx-click="pair"
            disabled={!@can_pair}
            title={if !@can_pair, do: "Previous round still has missing results"}
          >
            Pair round {@round_number} (JaVaFo)
          </button>
          <a
            :if={@round != nil}
            class="pe-btn"
            href={~p"/t/#{@tournament.id}/print/pairings?round=#{@round_number}"}
            target="_blank"
          >
            Print pairings
          </a>
          <button
            :if={@round != nil && @round_number == @paired_rounds}
            class="pe-btn danger-link"
            phx-click="unpair"
            data-confirm={"Unpair round #{@round_number}? All its results will be deleted."}
          >
            Unpair round
          </button>
        </div>
      </div>

      <p :if={@error} class="error-note">{@error}</p>

      <div class="card table-card">
        <table class="pe-table">
          <thead>
            <tr>
              <th class="num">Board</th>
              <th>White</th>
              <th style="text-align: center; width: 220px">Result</th>
              <th>Black</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@round == nil}>
              <td colspan="4">
                <div class="empty">
                  <p><strong>This round has not been paired yet.</strong></p>
                  <p class="hint">
                    <%= if @round_number == @next_pairable do %>
                      Press "Pair round {@round_number}" to run the FIDE Dutch pairing (JaVaFo).
                    <% else %>
                      Rounds are paired in order — round {@next_pairable} is next.
                    <% end %>
                  </p>
                </div>
              </td>
            </tr>
            <tr :for={pairing <- (@round && @round.pairings) || []}>
              <td class="num">{pairing.board}</td>
              <td><strong>{player_label(pairing.white_player)}</strong></td>
              <td style="text-align: center">
                <%= if pairing.result == "bye" do %>
                  <span class="badge">bye ({@tournament.bye_value} pt)</span>
                <% else %>
                  <form phx-change="result">
                    <input type="hidden" name="pairing-id" value={pairing.id} />
                    <select name="result" class="pe-select">
                      <option
                        :for={{value, label} <- results()}
                        value={value}
                        selected={pairing.result == value}
                      >
                        {label}
                      </option>
                    </select>
                  </form>
                <% end %>
              </td>
              <td>{player_label(pairing.black_player)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end
end
