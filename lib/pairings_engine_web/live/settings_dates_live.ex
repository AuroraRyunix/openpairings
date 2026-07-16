defmodule PairingsEngineWeb.SettingsDatesLive do
  @moduledoc """
  The "Dates" settings page (`/t/:id/settings/dates`) — one date per round
  (SWAR Dates tab), with helpers to fill them weekly or sequentially from the
  tournament's start date. The round count itself is set on the Tournament
  page; this page pads/truncates to match it.
  """
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport

  alias PairingsEngine.Tournaments

  @weekday_names {"Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     socket
     |> attach_dirty_tracker()
     |> assign(
       tournament: tournament,
       page_title: "#{tournament.name} · Settings",
       round_dates: pad_dates(tournament.round_dates, tournament.rounds_count),
       note: nil,
       error: nil,
       dirty: false,
       stale: false
     )}
  end

  @impl true
  def handle_info({:tournament_changed, _id, _hint}, %{assigns: %{dirty: true}} = socket) do
    handle_stale_check(socket)
  end

  def handle_info({:tournament_changed, _id, _hint}, socket) do
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
        {:noreply,
         assign(socket,
           tournament: tournament,
           round_dates: pad_dates(tournament.round_dates, tournament.rounds_count),
           stale: false
         )}
    end
  end

  @impl true
  def handle_event("rd_calc", _params, socket) do
    tournament = socket.assigns.tournament

    with start when start not in [nil, ""] <- tournament.start_date,
         {:ok, date} <- Date.from_iso8601(start) do
      dates =
        for i <- 0..(tournament.rounds_count - 1) do
          date |> Date.add(i * 7) |> Date.to_iso8601()
        end

      {:noreply, assign(socket, round_dates: dates, error: nil)}
    else
      {:error, _} ->
        {:noreply,
         assign(socket, error: "Start date must be a valid date before calculating round dates.")}

      _ ->
        {:noreply,
         assign(socket, error: "Set a start date (on the Tournament page) before calculating round dates.")}
    end
  end

  def handle_event("rd_clear", _params, socket) do
    {:noreply,
     assign(socket, round_dates: List.duplicate("", socket.assigns.tournament.rounds_count))}
  end

  # Bonus convenience per spec: round 1 = start date, then +1 day per round.
  def handle_event("rd_fill_sequential", _params, socket) do
    tournament = socket.assigns.tournament

    with start when start not in [nil, ""] <- tournament.start_date,
         {:ok, date} <- Date.from_iso8601(start) do
      dates =
        for i <- 0..(tournament.rounds_count - 1) do
          date |> Date.add(i) |> Date.to_iso8601()
        end

      {:noreply, assign(socket, round_dates: dates, error: nil)}
    else
      {:error, _} ->
        {:noreply,
         assign(socket, error: "Start date must be a valid date before filling round dates.")}

      _ ->
        {:noreply,
         assign(socket, error: "Set a start date (on the Tournament page) before filling round dates.")}
    end
  end

  def handle_event("save", %{"tournament" => params}, socket) do
    dates =
      params
      |> Map.get("round_dates", [])
      |> List.wrap()
      |> pad_dates(socket.assigns.tournament.rounds_count)

    base = Tournaments.get_tournament!(socket.assigns.tournament.id)

    case Tournaments.update_tournament(base, %{"round_dates" => dates}) do
      {:ok, tournament} ->
        log_settings_change(socket, base, tournament)

        {:noreply,
         assign(socket,
           tournament: tournament,
           round_dates: pad_dates(tournament.round_dates, tournament.rounds_count),
           note: "Saved.",
           error: nil,
           dirty: false,
           stale: false
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, error: error_text(changeset), note: nil)}
    end
  end

  ## ---------- helpers ----------

  defp pad_dates(dates, count) do
    dates = dates || []
    dates = Enum.take(dates, count)
    dates ++ List.duplicate("", max(count - length(dates), 0))
  end

  defp weekday_label(date) when date in [nil, ""], do: nil

  defp weekday_label(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> elem(@weekday_names, Date.day_of_week(parsed) - 1)
      {:error, _} -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} tournament={@tournament} active="settings">
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">Settings — Dates</p>
        </div>
        <span class={["badge", @tournament.status == "setup" && "muted"]}>{@tournament.status}</span>
      </div>

      <.settings_subnav tournament={@tournament} active={:dates} />

      <.stale_banner stale={@stale} />

      <form phx-submit="save">
        <div class="card">
          <h2>Round dates</h2>

          <p class="hint" style="margin-top: 0">
            One date per round (SWAR Dates tab). Leave blank if unknown; two or more rounds can
            share the same date (e.g. a Saturday double round).
          </p>

          <div class="form-grid">
            <label
              :for={{date, i} <- Enum.with_index(@round_dates)}
              class="field"
              style="display: flex; flex-direction: column; justify-content: flex-end"
            >
              <span>
                Round {i + 1}
                <span :if={weekday_label(date)} class="hint">({weekday_label(date)})</span>
              </span>
              <input type="date" name="tournament[round_dates][]" value={date} />
            </label>
          </div>

          <div class="actions" style="flex-wrap: wrap">
            <button type="button" class="pe-btn" phx-click="rd_fill_sequential">
              Fill sequentially from start date
            </button>
            <button type="button" class="pe-btn" phx-click="rd_calc">
              Calculate weekly from start date
            </button>
            <button type="button" class="pe-btn" phx-click="rd_clear">Clear all</button>
          </div>
        </div>

        <div class="actions">
          <button type="submit" class="pe-btn primary">Save round dates</button>
          <span :if={@note} class="ok-note" style="align-self: center">{@note}</span>
          <span :if={@error} class="error-note" style="align-self: center">{@error}</span>
        </div>
      </form>
    </Layouts.app>
    """
  end
end
