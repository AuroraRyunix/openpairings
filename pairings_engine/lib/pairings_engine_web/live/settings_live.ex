defmodule PairingsEngineWeb.SettingsLive do
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{Tournaments, Tiebreaks}
  alias PairingsEngine.Tournaments.Tournament

  @general_fields [
    {"name", "Tournament name", "text"},
    {"venue", "Venue", "text"},
    {"city", "City", "text"},
    {"federation", "Federation", "text"},
    {"start_date", "Start date", "date"},
    {"end_date", "End date", "date"},
    {"organizer", "Organizer", "text"},
    {"chief_arbiter", "Chief arbiter", "text"},
    {"deputy_arbiter", "Deputy arbiter(s)", "text"},
    {"time_control", "Time control", "text"}
  ]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_user_tournament!(socket.assigns.current_scope, id)

    {:ok,
     assign(socket,
       tournament: tournament,
       page_title: "#{tournament.name} · Settings",
       tiebreaks: tournament.tiebreaks,
       note: nil,
       error: nil
     )}
  end

  @impl true
  def handle_event("tb_up", %{"index" => index}, socket) do
    {:noreply, assign(socket, tiebreaks: swap(socket.assigns.tiebreaks, String.to_integer(index), -1), note: nil)}
  end

  def handle_event("tb_down", %{"index" => index}, socket) do
    {:noreply, assign(socket, tiebreaks: swap(socket.assigns.tiebreaks, String.to_integer(index), 1), note: nil)}
  end

  def handle_event("tb_remove", %{"code" => code}, socket) do
    {:noreply, assign(socket, tiebreaks: List.delete(socket.assigns.tiebreaks, code), note: nil)}
  end

  def handle_event("tb_add", %{"code" => ""}, socket), do: {:noreply, socket}

  def handle_event("tb_add", %{"code" => code}, socket) do
    {:noreply, assign(socket, tiebreaks: socket.assigns.tiebreaks ++ [code], note: nil)}
  end

  def handle_event("tb_reset", _params, socket) do
    {:noreply,
     assign(socket, tiebreaks: Tiebreaks.fide_defaults(socket.assigns.tournament.type), note: nil)}
  end

  def handle_event("save", %{"tournament" => params}, socket) do
    params = Map.put(params, "tiebreaks", socket.assigns.tiebreaks)

    case Tournaments.update_tournament(socket.assigns.tournament, params) do
      {:ok, tournament} ->
        {:noreply, assign(socket, tournament: tournament, note: "Saved.", error: nil)}

      {:error, changeset} ->
        {:noreply, assign(socket, error: error_text(changeset), note: nil)}
    end
  end

  defp swap(list, index, delta) do
    target = index + delta

    if target < 0 or target >= length(list) do
      list
    else
      a = Enum.at(list, index)
      b = Enum.at(list, target)
      list |> List.replace_at(index, b) |> List.replace_at(target, a)
    end
  end

  defp error_text(changeset) do
    Enum.map_join(changeset.errors, ", ", fn {field, {msg, _}} -> "#{field} #{msg}" end)
  end

  defp general_fields, do: @general_fields

  defp available_tiebreaks(selected) do
    Enum.reject(Tiebreaks.catalogue(), &(&1.code in selected))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} tournament={@tournament} active="settings">
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">Settings</p>
        </div>
        <span class={["badge", @tournament.status == "setup" && "muted"]}>{@tournament.status}</span>
      </div>

      <form phx-submit="save">
        <div class="card">
          <h2>General</h2>
          <div class="form-grid">
            <label :for={{field, label, type} <- general_fields()} class="field">
              <span>{label}</span>
              <input type={type} name={"tournament[#{field}]"} value={Map.get(@tournament, String.to_existing_atom(field))} />
            </label>
          </div>
        </div>

        <div class="card">
          <h2>Format</h2>
          <div class="form-grid">
            <label class="field">
              <span>Pairing system</span>
              <select name="tournament[type]">
                <option
                  :for={type <- Tournament.types()}
                  value={type}
                  selected={@tournament.type == type}
                >
                  {Tournament.type_label(type)}
                </option>
              </select>
            </label>
            <label class="field">
              <span>Number of rounds</span>
              <input
                type="number"
                name="tournament[rounds_count]"
                value={@tournament.rounds_count}
                min="1"
                max="30"
              />
            </label>
            <label class="field">
              <span>Pair by</span>
              <select name="tournament[rating_type]">
                <option value="fide" selected={@tournament.rating_type == "fide"}>FIDE rating</option>
                <option value="national" selected={@tournament.rating_type == "national"}>
                  National rating
                </option>
                <option value="none" selected={@tournament.rating_type == "none"}>
                  No rating (random order)
                </option>
              </select>
            </label>
            <label class="field">
              <span>Acceleration</span>
              <select name="tournament[acceleration]">
                <option value="none" selected={@tournament.acceleration == "none"}>None</option>
                <option value="baku" selected={@tournament.acceleration == "baku"}>
                  Baku acceleration (FIDE C.04.5)
                </option>
              </select>
            </label>
          </div>
        </div>

        <div class="card">
          <h2>Scoring</h2>
          <div class="form-grid">
            <label class="field">
              <span>Points for a win</span>
              <input type="number" step="0.5" name="tournament[points_win]" value={@tournament.points_win} />
            </label>
            <label class="field">
              <span>Points for a draw</span>
              <input type="number" step="0.5" name="tournament[points_draw]" value={@tournament.points_draw} />
            </label>
            <label class="field">
              <span>Points for a loss</span>
              <input type="number" step="0.5" name="tournament[points_loss]" value={@tournament.points_loss} />
            </label>
            <label class="field">
              <span>Pairing-allocated bye worth</span>
              <input type="number" step="0.5" name="tournament[bye_value]" value={@tournament.bye_value} />
            </label>
          </div>
        </div>

        <div class="card">
          <h2>Tiebreaks</h2>
          <p class="hint" style="margin-top: 0">
            Applied in order, following the FIDE Tie-Break Regulations. Higher in the list = decided first.
          </p>
          <ol class="tb-list">
            <li :for={{code, i} <- Enum.with_index(@tiebreaks)}>
              <span class="tb-order">{i + 1}.</span>
              <div>
                <div class="tb-name">{tb_name(code)}</div>
                <div class="tb-desc">{tb_desc(code)}</div>
              </div>
              <div class="tb-buttons">
                <button
                  type="button"
                  class="pe-btn"
                  title="Move up"
                  disabled={i == 0}
                  phx-click="tb_up"
                  phx-value-index={i}
                >
                  ↑
                </button>
                <button
                  type="button"
                  class="pe-btn"
                  title="Move down"
                  disabled={i == length(@tiebreaks) - 1}
                  phx-click="tb_down"
                  phx-value-index={i}
                >
                  ↓
                </button>
                <button
                  type="button"
                  class="pe-btn"
                  title="Remove"
                  phx-click="tb_remove"
                  phx-value-code={code}
                >
                  ✕
                </button>
              </div>
            </li>
          </ol>
          <p :if={@tiebreaks == []} class="hint">
            No tiebreaks selected — tied players will share a rank.
          </p>

          <div class="actions" style="flex-wrap: wrap">
            <select phx-change="tb_add" name="code" style="width: auto" class="pe-select">
              <option value="">Add a tiebreak…</option>
              <option :for={tb <- available_tiebreaks(@tiebreaks)} value={tb.code}>{tb.name}</option>
            </select>
            <button type="button" class="pe-btn" phx-click="tb_reset">Reset to FIDE default</button>
          </div>
        </div>

        <div class="actions">
          <button type="submit" class="pe-btn primary">Save settings</button>
          <span :if={@note} class="ok-note" style="align-self: center">{@note}</span>
          <span :if={@error} class="error-note" style="align-self: center">{@error}</span>
        </div>
      </form>
    </Layouts.app>
    """
  end

  defp tb_name(code), do: (Tiebreaks.get(code) || %{name: code}).name
  defp tb_desc(code), do: (Tiebreaks.get(code) || %{description: ""}).description
end
