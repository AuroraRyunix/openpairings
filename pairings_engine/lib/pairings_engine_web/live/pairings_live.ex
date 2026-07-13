defmodule PairingsEngineWeb.PairingsLive do
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.Tournaments
  alias PairingsEngine.Pairing, as: Engine

  @results [
    {"", "…"},
    {"1-0", "1-0"},
    {"1/2-1/2", "½-½"},
    {"0-1", "0-1"},
    {"1-0FF", "1-0 FF (White wins by forfeit)"},
    {"0-1FF", "0-1 FF (Black wins by forfeit)"},
    {"0-0FF", "0-0 FF (double forfeit)"},
    {"0-0", "0-0 (both lose, game played)"}
  ]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)
    paired = Engine.paired_rounds_count(tournament.id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

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

  # Results are entered inline (each select saves immediately on change, no
  # draft state to protect), so a broadcast can just reload everything —
  # including the tournament itself, since rounds_count/status can change
  # from the Settings page.
  @impl true
  def handle_info({:tournament_changed, _tournament_id, _hint}, socket) do
    case Tournaments.get_authorized_tournament(socket.assigns.current_scope, socket.assigns.tournament.id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "This tournament was deleted.")
         |> push_navigate(to: ~p"/")}

      tournament ->
        {:noreply, socket |> assign(tournament: tournament) |> refresh()}
    end
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

  # Long JaVaFo failures come through as multi-line output — show a short
  # first-line preview as the collapsed summary, never a truncated message
  # (the full text is always available by expanding the block).
  defp error_summary(text) do
    text |> String.split("\n", parts: 2) |> hd()
  end

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
        <div class="actions" style="margin: 0">
          <a class="pe-btn" href={~p"/t/#{@tournament.id}/live"} target="_blank">
            Open live view
          </a>
          <a
            class="pe-btn"
            href={~p"/p/#{@tournament.public_slug}/pairings"}
            target="_blank"
            title="No login needed — share this link"
          >
            Public pairings link
          </a>
          <a class="pe-btn" href={~p"/t/#{@tournament.id}/export/trf"} target="_blank">
            Export TRF (all rounds)
          </a>
          <form
            id="trf-rounds-export-form"
            method="get"
            action={~p"/t/#{@tournament.id}/export/trf"}
            target="_blank"
            style="display: flex; gap: 6px; align-items: center; margin: 0"
          >
            <input
              type="text"
              name="rounds"
              placeholder="e.g. 1-5 or 1,3,5"
              class="pe-select"
              style="width: 150px"
            />
            <button type="submit" class="pe-btn" title="Export only the rounds listed here">
              Export rounds…
            </button>
          </form>
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
          <a
            :if={@round != nil}
            class="pe-btn"
            href={~p"/t/#{@tournament.id}/print/standings?round=#{@round_number}"}
            target="_blank"
          >
            Print standings
          </a>
          <a
            :if={@round != nil}
            class="pe-btn"
            href={~p"/t/#{@tournament.id}/print/results?round=#{@round_number}"}
            target="_blank"
          >
            Print result cards
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

      <div :if={@error} class="error-note" style="display: block">
        <details open={String.length(@error) <= 160}>
          <summary style="cursor: pointer">{error_summary(@error)}</summary>
          <pre style="max-height: 320px; overflow: auto; white-space: pre-wrap; word-break: break-word; margin: 6px 0 0">{@error}</pre>
        </details>
      </div>

      <p class="hint" style="margin: 8px 0">
        Tip: click a result box and type 1 / 2 / 3 to enter results rapidly (white win / draw / black win) — focus jumps to the next board automatically.
      </p>

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
                  <form phx-change="result" id={"result-form-#{pairing.id}"}>
                    <input type="hidden" name="pairing-id" value={pairing.id} />
                    <select
                      name="result"
                      class="pe-select"
                      id={"result-select-#{pairing.id}"}
                      phx-hook=".BlindResultEntry"
                      data-board-select
                    >
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

      <script :type={Phoenix.LiveView.ColocatedHook} name=".BlindResultEntry">
        // SWAR-style "blind" result entry: with a board's result <select>
        // focused, typing 1 / 2 / 3 sets that board's result (white win /
        // draw / black win) and moves focus to the next board's result
        // select, so a sequence like "131312" fills in six boards in a row
        // without touching the mouse.
        const KEY_TO_VALUE = {"1": "1-0", "2": "1/2-1/2", "3": "0-1"};

        export default {
          mounted() {
            this.onKeydown = (e) => {
              const value = KEY_TO_VALUE[e.key];
              if (!value) return; // let every other key behave natively

              const hasOption = Array.from(this.el.options).some((o) => o.value === value);
              if (!hasOption) return;

              // Stop the browser's native "jump to option starting with
              // this character" select behavior — we're fully driving the
              // value ourselves.
              e.preventDefault();

              this.el.value = value;
              // LiveView's phx-change listens for a real "change" event
              // bubbling up from the form.
              this.el.dispatchEvent(new Event("change", {bubbles: true}));

              this.focusNextBoard();
            };

            this.el.addEventListener("keydown", this.onKeydown);
          },

          focusNextBoard() {
            const selects = Array.from(document.querySelectorAll("select[data-board-select]"));
            const index = selects.indexOf(this.el);
            if (index >= 0 && index < selects.length - 1) {
              selects[index + 1].focus();
            }
          },

          destroyed() {
            this.el.removeEventListener("keydown", this.onKeydown);
          }
        }
      </script>
    </Layouts.app>
    """
  end
end
