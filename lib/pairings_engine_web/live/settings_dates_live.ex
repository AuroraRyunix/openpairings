defmodule PairingsEngineWeb.SettingsDatesLive do
  @moduledoc """
  The "Dates" settings page (`/t/:id/settings/dates`) - one date per round
  (SWAR Dates tab), with helpers to fill them weekly or sequentially from
  round 1's own date. The round count itself is set on the Tournament page;
  this page pads/truncates to match it.

  The ONLY place a tournament's dates get entered at all - `start_date`/
  `end_date` used to be separate fields on the Tournament page, editable
  independently of these per-round dates (two sources of truth for what's
  really one piece of information, which could drift out of sync with each
  other). They're derived now (`Tournament.changeset/2`'s
  `derive_dates_from_round_dates/1`: the earliest/latest non-blank entry
  here), and shown below read-only as a preview of what that derives to -
  not entered directly anywhere.
  """
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport

  alias PairingsEngine.Tournaments
  alias PairingsEngine.Tournaments.Tournament

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

  # Keeps `round_dates` reflecting whatever's actually in the form as the
  # arbiter types, unsaved changes included - the two fill helpers below
  # read round 1's date OUT of this assign, so without this they'd only
  # ever see whatever was last saved, not what's just been typed into
  # round 1's own box a moment ago.
  @impl true
  def handle_event("rd_update", %{"tournament" => params}, socket) do
    dates =
      params
      |> Map.get("round_dates", [])
      |> List.wrap()
      |> pad_dates(socket.assigns.tournament.rounds_count)

    {:noreply, assign(socket, round_dates: dates)}
  end

  def handle_event("rd_calc", _params, socket) do
    with start when start not in [nil, ""] <- List.first(socket.assigns.round_dates),
         {:ok, date} <- Date.from_iso8601(start) do
      dates =
        for i <- 0..(socket.assigns.tournament.rounds_count - 1) do
          date |> Date.add(i * 7) |> Date.to_iso8601()
        end

      {:noreply, assign(socket, round_dates: dates, error: nil)}
    else
      {:error, _} ->
        {:noreply,
         assign(socket, error: "Round 1's date must be a valid date before calculating the rest.")}

      _ ->
        {:noreply, assign(socket, error: "Set round 1's date first, then calculate the rest.")}
    end
  end

  def handle_event("rd_clear", _params, socket) do
    {:noreply,
     assign(socket, round_dates: List.duplicate("", socket.assigns.tournament.rounds_count))}
  end

  # Bonus convenience per spec: round 1 keeps its own date, then +1 day per
  # round after it.
  def handle_event("rd_fill_sequential", _params, socket) do
    with start when start not in [nil, ""] <- List.first(socket.assigns.round_dates),
         {:ok, date} <- Date.from_iso8601(start) do
      dates =
        for i <- 0..(socket.assigns.tournament.rounds_count - 1) do
          date |> Date.add(i) |> Date.to_iso8601()
        end

      {:noreply, assign(socket, round_dates: dates, error: nil)}
    else
      {:error, _} ->
        {:noreply,
         assign(socket, error: "Round 1's date must be a valid date before filling the rest.")}

      _ ->
        {:noreply, assign(socket, error: "Set round 1's date first, then fill in the rest.")}
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

  # Delegates to `Tournament.pad_round_dates/2` - the same pad/truncate
  # logic the Tournament changeset now applies on every save. Kept here too
  # because this page's live form state needs the padded shape mid-edit,
  # before anything is actually saved.
  defp pad_dates(dates, count), do: Tournament.pad_round_dates(dates, count)

  # Live preview of what `Tournament.changeset/2`'s own
  # `derive_dates_from_round_dates/1` would compute from the CURRENT
  # (possibly unsaved) form state - same "earliest/latest non-blank
  # entry" logic, so what's shown here always matches what Save would
  # actually produce, not just what's already on disk.
  defp derived_range(round_dates) do
    dates = round_dates |> Enum.reject(&(&1 in [nil, ""])) |> Enum.sort()

    case dates do
      [] -> "No dates set yet"
      [only] -> only
      dates -> "#{List.first(dates)} → #{List.last(dates)}"
    end
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
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      tournament={@tournament}
      active="settings"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">Settings - Dates</p>
        </div>
        <span class={["badge", @tournament.status == "setup" && "muted"]}>{@tournament.status}</span>
      </div>

      <.settings_subnav tournament={@tournament} active={:dates} />

      <.stale_banner stale={@stale} />

      <form phx-submit="save" phx-change="rd_update">
        <div class="card">
          <h2>Round dates</h2>

          <p class="hint" style="margin-top: 0">
            One date per round (SWAR Dates tab). Leave blank if unknown; two or more rounds can
            share the same date (e.g. a Saturday double round). The tournament's own start/end
            date is no longer entered separately - it's just the earliest and latest date set
            here:
          </p>

          <p class="hint" style="margin-top: 0">
            <strong>{derived_range(@round_dates)}</strong>
          </p>

          <div class="set-rows">
            <label :for={{date, i} <- Enum.with_index(@round_dates)} class="set-row">
              <span class="set-row-label">
                Round {i + 1}
                <span :if={weekday_label(date)} class="hint">({weekday_label(date)})</span>
              </span>
              <input type="date" name="tournament[round_dates][]" value={date} />
            </label>
          </div>

          <div class="actions" style="flex-wrap: wrap">
            <button type="button" class="pe-btn" phx-click="rd_fill_sequential">
              Fill sequentially from round 1
            </button>
            <button type="button" class="pe-btn" phx-click="rd_calc">
              Calculate weekly from round 1
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
