defmodule PairingsEngineWeb.SettingsOptionsLive do
  @moduledoc """
  The "Options" settings page (`/t/:id/settings/options`) — everything about
  *how* the tournament is paired and scored: the pairing engine and its
  variants (RR cycles, RR/Swiss match format, pair-by-category — each locked
  once round 1 has been paired), the rating used for pairing, acceleration,
  the rate of play, custom scoring (points per win/draw/loss and the
  pairing-allocated bye value), and the forbidden-pairing / club-federation
  exclusion rules.
  """
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport

  alias PairingsEngine.{Audit, Tournaments, Pairing, Exclusions}
  alias PairingsEngine.Tournaments.Tournament

  # SWAR TournoiStd (§5.13): Standard / Rapid / Blitz.
  @standard_options [
    {"standard", "Standard"},
    {"rapid", "Rapid"},
    {"blitz", "Blitz"}
  ]

  @rate_of_play_standard [
    "100min/end+30sec/move from move 1",
    "100min/40moves+50min/20moves+15min/end+30sec/move from move 1",
    "105min/40moves+15min/end",
    "120min/40moves+15min/end+30sec/move from move 40",
    "120min/40moves+30min/end",
    "120min/10moves+30min/end+30sec/move from move 40",
    "120min/end",
    "120min/end+10sec/move from move 40",
    "120min/end+30sec/move from move 1",
    "120min/end+30sec/move from move 40",
    "150min/end",
    "30min/end+30sec/move from move 1",
    "40min/end+30sec/move from move 1",
    "60min/end",
    "60min/end+30sec/move from move 1",
    "65min/end",
    "75min/end+30sec/move from move 1",
    "90min/40moves+15min/end+30sec/move from move 1",
    "90min/end+10sec/move from move 1",
    "90min/end+30sec DELAY /move from move 1",
    "90min/end",
    "90min/end+30sec/move from move 1",
    "90min/40moves+30min/end+30sec/move from move 1"
  ]

  @rate_of_play_rapid [
    "10min/end+10sec/move from move 1",
    "10min/end+15sec/move from move 1",
    "10min/end+2sec/move from move 1",
    "10min/end+5sec DELAY /move from move 1",
    "10min/end+5sec/move from move 1",
    "11min/end",
    "12min/end",
    "12min/end+10sec/move from move 1",
    "12min/end+3sec/move from move 1",
    "12min/end+5sec/move from move 1",
    "13min/end+3sec/move from move 1",
    "13min/end+5sec/move from move 1",
    "15min/end",
    "15min/end+10sec/move from move 1",
    "15min/end+15sec/move from move 1",
    "15min/end+5sec/move from move 1",
    "20min/end",
    "20min/end+10sec/move from move 1",
    "20min/end+15sec/move from move 1",
    "20min/end+5sec/move from move 1",
    "25min/end+10sec/move from move 1",
    "25min/end+15sec/move from move 1",
    "25min/end+5sec/move from move 1",
    "25min/end",
    "30min/end",
    "30min/end+10sec/move from move 1",
    "30min/end+20sec/move from move 1",
    "40min/end+10sec/move from move 1",
    "45min/end",
    "59min/end",
    "8min/end+4sec/move from move 1"
  ]

  @rate_of_play_blitz [
    "10min/end",
    "3min/end+2sec/move from move 1",
    "3min/end+3sec/move from move 1",
    "4min/end+2sec/move from move 1",
    "4min/end+3sec/move from move 1",
    "5min/end",
    "5min/end+2sec/move from move 1",
    "5min/end+3sec DELAY /move from move 1",
    "5min/end+3sec/move from move 1",
    "6min/end+2sec/move from move 1",
    "6min/end+3sec/move from move 1",
    "7min/end+2sec/move from move 1",
    "7min/end+3sec/move from move 1",
    "8min/end+2sec/move from move 1",
    "8min/end+3sec/move from move 1"
  ]

  @pairing_system_options for ps <- Tournament.pairing_systems(),
                              do: {ps, Tournament.pairing_system_label(ps)}
  @rr_cycles_options for c <- Tournament.rr_cycles_values(),
                         do: {c, Tournament.rr_cycles_label(c)}

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
       standard: tournament.standard,
       rate_of_play: tournament.rate_of_play,
       note: nil,
       error: nil,
       dirty: false,
       stale: false,
       # Which locked pairing-shape control (if any) the user just tried to
       # interact with — one of `:pairing_system`, `:rr_cycles`,
       # `:rr_match_format`, `:swiss_match_format`, `:pair_by_category`, or nil.
       locked_hint: nil,
       forbidden_pairing_error: nil,
       club_exclusion_mode: tournament.club_exclusion,
       fed_exclusion_mode: tournament.fed_exclusion,
       exclusion_error: nil
     )
     |> assign_pairing_locks()
     |> assign_forbidden_pairings()}
  end

  # `pairing_system` locks once the tournament has paired its first round;
  # `rr_cycles` locks once the number of already-paired rounds reaches what
  # the current cycles setting implies a round robin needs. See the original
  # SettingsLive for the full rationale.
  defp assign_pairing_locks(socket) do
    tournament = socket.assigns.tournament
    paired = Pairing.paired_rounds_count(tournament.id)
    players = Tournaments.count_players(tournament.id)
    rr_base = max(players - 1, 1)
    rr_implied_limit = rr_base * tournament.rr_cycles

    assign(socket,
      paired_rounds: paired,
      pairing_system_locked?: paired > 0,
      rr_cycles_locked?: paired >= rr_implied_limit,
      rr_match_format_locked?: paired > 0,
      swiss_match_format_locked?: paired > 0,
      pair_by_category_locked?: paired > 0
    )
  end

  defp assign_forbidden_pairings(socket) do
    tournament = socket.assigns.tournament
    players = Tournaments.list_players(tournament.id) |> Enum.sort_by(& &1.name)

    assign(socket,
      forbidden_pairings: Tournaments.list_forbidden_pairings(tournament.id),
      forbidden_pairing_players: players,
      excluded_pair_count: Exclusions.excluded_pairs(tournament, players) |> MapSet.size()
    )
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
         socket
         |> assign(
           tournament: tournament,
           standard: tournament.standard,
           rate_of_play: tournament.rate_of_play,
           club_exclusion_mode: tournament.club_exclusion,
           fed_exclusion_mode: tournament.fed_exclusion,
           stale: false
         )
         |> assign_pairing_locks()
         |> assign_forbidden_pairings()}
    end
  end

  # Self-clearing timer for the "locked" hint set by the "locked_hint" event —
  # only clears if it's still showing the same field's message.
  def handle_info({:clear_locked_hint, field}, socket) do
    if socket.assigns.locked_hint == field do
      {:noreply, assign(socket, locked_hint: nil)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("locked_hint", %{"field" => field}, socket) do
    field = String.to_existing_atom(field)
    Process.send_after(self(), {:clear_locked_hint, field}, 3000)
    {:noreply, assign(socket, locked_hint: field)}
  end

  # `standard` and `rate_of_play` are tracked as their own assigns because the
  # "Rate of play" select's option list depends on which "Type" is picked.
  def handle_event("standard_change", %{"tournament" => %{"standard" => new_standard}}, socket) do
    list = rate_of_play_list(new_standard)
    current = socket.assigns.rate_of_play
    new_rate = if current in list, do: current, else: ""

    {:noreply, assign(socket, standard: new_standard, rate_of_play: new_rate)}
  end

  def handle_event("save", %{"tournament" => params}, socket) do
    params =
      params
      |> apply_rate_of_play_override()
      |> strip_locked_pairing_fields(socket.assigns)

    base = Tournaments.get_tournament!(socket.assigns.tournament.id)

    case Tournaments.update_tournament(base, params) do
      {:ok, tournament} ->
        log_settings_change(socket, base, tournament)

        {:noreply,
         socket
         |> assign(
           tournament: tournament,
           standard: tournament.standard,
           rate_of_play: tournament.rate_of_play,
           note: "Saved.",
           error: nil,
           dirty: false,
           stale: false
         )
         |> assign_pairing_locks()}

      {:error, changeset} ->
        {:noreply, assign(socket, error: error_text(changeset), note: nil)}
    end
  end

  ## ---------- Forbidden pairings ----------

  def handle_event("add_forbidden_pairing", %{"player_a_id" => a, "player_b_id" => b}, socket) do
    with {a_id, ""} <- Integer.parse(a),
         {b_id, ""} <- Integer.parse(b) do
      case Tournaments.add_forbidden_pairing(socket.assigns.tournament, a_id, b_id) do
        {:ok, forbidden_pairing} ->
          Audit.log(
            socket.assigns.tournament.id,
            socket.assigns.current_scope,
            "forbidden_pairing.added",
            %{player_a_id: forbidden_pairing.player_a_id, player_b_id: forbidden_pairing.player_b_id}
          )

          {:noreply,
           socket
           |> assign(forbidden_pairing_error: nil)
           |> assign_forbidden_pairings()}

        {:error, :same_player} ->
          {:noreply, assign(socket, forbidden_pairing_error: "Choose two different players")}

        {:error, :invalid_player} ->
          {:noreply,
           assign(socket, forbidden_pairing_error: "Choose two players from this tournament")}

        {:error, :already_forbidden} ->
          {:noreply, assign(socket, forbidden_pairing_error: "That pair is already forbidden")}

        {:error, _reason} ->
          {:noreply, assign(socket, forbidden_pairing_error: "Could not add that forbidden pairing")}
      end
    else
      _ -> {:noreply, assign(socket, forbidden_pairing_error: "Choose two players")}
    end
  end

  def handle_event("remove_forbidden_pairing", %{"id" => id}, socket) do
    case Tournaments.remove_forbidden_pairing(socket.assigns.tournament, id) do
      {:ok, forbidden_pairing} ->
        Audit.log(
          socket.assigns.tournament.id,
          socket.assigns.current_scope,
          "forbidden_pairing.removed",
          %{player_a_id: forbidden_pairing.player_a_id, player_b_id: forbidden_pairing.player_b_id}
        )

        {:noreply, assign_forbidden_pairings(socket)}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  ## ---------- Club/federation exclusions ----------

  def handle_event(
        "club_exclusion_mode_change",
        %{"tournament" => %{"club_exclusion" => mode}},
        socket
      ) do
    {:noreply, assign(socket, club_exclusion_mode: mode)}
  end

  def handle_event(
        "fed_exclusion_mode_change",
        %{"tournament" => %{"fed_exclusion" => mode}},
        socket
      ) do
    {:noreply, assign(socket, fed_exclusion_mode: mode)}
  end

  def handle_event("save_exclusions", %{"tournament" => params}, socket) do
    params =
      Map.take(params, [
        "club_exclusion",
        "club_exclusion_list",
        "fed_exclusion",
        "fed_exclusion_list"
      ])

    base = socket.assigns.tournament

    case Tournaments.update_tournament(base, params) do
      {:ok, tournament} ->
        log_settings_change(socket, base, tournament)

        {:noreply,
         socket
         |> assign(
           tournament: tournament,
           club_exclusion_mode: tournament.club_exclusion,
           fed_exclusion_mode: tournament.fed_exclusion,
           exclusion_error: nil
         )
         |> assign_forbidden_pairings()}

      {:error, changeset} ->
        {:noreply, assign(socket, exclusion_error: error_text(changeset))}
    end
  end

  ## ---------- helpers ----------

  # Server-side enforcement of the locks: drop any submitted value for a
  # locked field regardless of the HTML `disabled` attribute.
  defp strip_locked_pairing_fields(params, assigns) do
    params
    |> maybe_drop_locked("pairing_system", assigns.pairing_system_locked?)
    |> maybe_drop_locked("rr_cycles", assigns.rr_cycles_locked?)
    |> maybe_drop_locked("rr_match_format", assigns.rr_match_format_locked?)
    |> maybe_drop_locked("swiss_match_format", assigns.swiss_match_format_locked?)
    |> maybe_drop_locked("pair_by_category", assigns.pair_by_category_locked?)
  end

  defp maybe_drop_locked(params, _key, false), do: params
  defp maybe_drop_locked(params, key, true), do: Map.delete(params, key)

  defp apply_rate_of_play_override(params) do
    case String.trim(Map.get(params, "rate_of_play_other", "")) do
      "" -> params
      other -> Map.put(params, "rate_of_play", other)
    end
  end

  defp rate_of_play_list("rapid"), do: @rate_of_play_rapid
  defp rate_of_play_list("blitz"), do: @rate_of_play_blitz
  defp rate_of_play_list(_standard), do: @rate_of_play_standard

  defp rate_of_play_select_options(standard, current) do
    list = rate_of_play_list(standard)

    if current not in [nil, ""] and current not in list do
      [current, ""] ++ list
    else
      [""] ++ list
    end
  end

  defp standard_options, do: @standard_options
  defp pairing_system_options, do: @pairing_system_options
  defp rr_cycles_options, do: @rr_cycles_options

  # Shared by all 5 "locked after first pairing" controls: a transparent div
  # laid over the disabled control so a click still reaches something
  # clickable and reports it via the "locked_hint" event. Renders nothing
  # once unlocked.
  attr :field, :atom, required: true
  attr :locked?, :boolean, required: true

  defp locked_overlay(assigns) do
    ~H"""
    <div :if={@locked?} class="locked-overlay" phx-click="locked_hint" phx-value-field={@field}></div>
    """
  end

  attr :field, :atom, required: true
  attr :locked_hint, :atom, default: nil

  defp locked_hint_message(assigns) do
    ~H"""
    <span :if={@locked_hint == @field} class="hint locked-hint-msg">
      Locked — cannot be changed after round 1 has been paired.
    </span>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} tournament={@tournament} active="settings">
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">Settings — Options</p>
        </div>
        <span class={["badge", @tournament.status == "setup" && "muted"]}>{@tournament.status}</span>
      </div>

      <.settings_subnav tournament={@tournament} active={:options} />

      <.stale_banner stale={@stale} />

      <form phx-submit="save">
        <div class="card">
          <h2>Options</h2>

          <div class="form-grid">
            <label class="field">
              <span>Pairing system</span>
              <div class="locked-wrap">
                <select name="tournament[pairing_system]" disabled={@pairing_system_locked?}>
                  <option
                    :for={{val, label} <- pairing_system_options()}
                    value={val}
                    selected={@tournament.pairing_system == val}
                  >
                    {label}
                  </option>
                </select>
                <.locked_overlay field={:pairing_system} locked?={@pairing_system_locked?} />
              </div>
              <.locked_hint_message field={:pairing_system} locked_hint={@locked_hint} />
            </label>

            <label class="field">
              <span>Cycles</span>
              <div class="locked-wrap">
                <select name="tournament[rr_cycles]" disabled={@rr_cycles_locked?}>
                  <option
                    :for={{val, label} <- rr_cycles_options()}
                    value={val}
                    selected={@tournament.rr_cycles == val}
                  >
                    {label}
                  </option>
                </select>
                <.locked_overlay field={:rr_cycles} locked?={@rr_cycles_locked?} />
              </div>
              <.locked_hint_message field={:rr_cycles} locked_hint={@locked_hint} />
            </label>

            <label
              class="field"
              style="display: flex; flex-direction: row; align-items: center; gap: .5rem"
            >
              <input type="hidden" name="tournament[rr_match_format]" value="false" />
              <span class="locked-wrap locked-wrap-inline">
                <input
                  type="checkbox"
                  name="tournament[rr_match_format]"
                  value="true"
                  checked={@tournament.rr_match_format}
                  disabled={@rr_match_format_locked?}
                />
                <.locked_overlay field={:rr_match_format} locked?={@rr_match_format_locked?} />
              </span>
              <span>Match format (immediate 2-game rematch, reversed colours)</span>
              <.locked_hint_message field={:rr_match_format} locked_hint={@locked_hint} />
            </label>

            <label class="field">
              <span>Keizer top value (blank = automatic)</span>
              <input
                type="number"
                name="tournament[keizer_top_value]"
                value={@tournament.keizer_top_value}
                min="1"
              />
            </label>

            <label class="field">
              <span>Pair by</span>
              <select name="tournament[rating_type]">
                <option value="fide" selected={@tournament.rating_type == "fide"}>FIDE rating</option>
                <option value="national" selected={@tournament.rating_type == "national"}>
                  National rating
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
              <span class="hint">Swiss only — round robin and Keizer ignore this setting</span>
            </label>

            <label
              class="field"
              style="display: flex; flex-direction: row; align-items: center; gap: .5rem"
            >
              <input type="hidden" name="tournament[swiss_match_format]" value="false" />
              <span class="locked-wrap locked-wrap-inline">
                <input
                  type="checkbox"
                  name="tournament[swiss_match_format]"
                  value="true"
                  checked={@tournament.swiss_match_format}
                  disabled={@swiss_match_format_locked?}
                />
                <.locked_overlay field={:swiss_match_format} locked?={@swiss_match_format_locked?} />
              </span>
              <span>Match format (immediate 2-game rematch, reversed colours)</span>
              <.locked_hint_message field={:swiss_match_format} locked_hint={@locked_hint} />
            </label>
            <p class="hint" style="margin-top: -8px">
              Swiss only — requires an even number of rounds (each match is 2 rounds)
            </p>

            <label
              class="field"
              style="display: flex; flex-direction: row; align-items: center; gap: .5rem"
            >
              <input type="hidden" name="tournament[pair_by_category]" value="false" />
              <span class="locked-wrap locked-wrap-inline">
                <input
                  type="checkbox"
                  name="tournament[pair_by_category]"
                  value="true"
                  checked={@tournament.pair_by_category}
                  disabled={@pair_by_category_locked? or not @tournament.categories_enabled}
                />
                <.locked_overlay field={:pair_by_category} locked?={@pair_by_category_locked?} />
              </span>
              <span>Pair each category independently</span>
              <.locked_hint_message field={:pair_by_category} locked_hint={@locked_hint} />
              <span
                :if={not @tournament.categories_enabled and not @pair_by_category_locked?}
                class="hint"
              >
                enable categories first
              </span>
            </label>
            <p class="hint" style="margin-top: -8px">
              Swiss only — each category gets its own independent pairings and byes within one combined round
            </p>

            <label class="field">
              <span>Type</span>
              <select name="tournament[standard]" phx-change="standard_change">
                <option
                  :for={{val, label} <- standard_options()}
                  value={val}
                  selected={@standard == val}
                >
                  {label}
                </option>
              </select>
            </label>

            <label class="field">
              <span style="font-weight: 700">
                Rate of play <span style="color: var(--danger)">*</span>
              </span>
              <select name="tournament[rate_of_play]">
                <option
                  :for={opt <- rate_of_play_select_options(@standard, @rate_of_play)}
                  value={opt}
                  selected={opt == @rate_of_play}
                >
                  {if opt == "", do: "— none —", else: opt}
                </option>
              </select>
            </label>

            <label class="field">
              <span>Other rate of play (overrides the select above)</span>
              <input
                type="text"
                name="tournament[rate_of_play_other]"
                value=""
                placeholder="e.g. 40 min + 10 sec/move"
              />
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
          <h2>Categories</h2>

          <label
            class="field"
            style="display: flex; flex-direction: row; align-items: center; gap: .5rem"
          >
            <input type="hidden" name="tournament[categories_enabled]" value="false" />
            <input
              type="checkbox"
              name="tournament[categories_enabled]"
              value="true"
              checked={@tournament.categories_enabled}
            /> <span>Enable the Categories tab (category groups + extra points)</span>
          </label>
        </div>

        <div class="actions">
          <button type="submit" class="pe-btn primary">Save settings</button>
          <span :if={@note} class="ok-note" style="align-self: center">{@note}</span>
          <span :if={@error} class="error-note" style="align-self: center">{@error}</span>
        </div>
      </form>

      <div class="card">
        <h2>Forbidden pairings</h2>

        <p class="hint" style="margin-top: 0">
          Two players who must never be paired against each other. Applies to Swiss pairing
          (a JaVaFo "XXP" rule) and to Keizer; a round robin's fixed schedule ignores this by design.
        </p>

        <form id="add-forbidden-pairing-form" phx-submit="add_forbidden_pairing">
          <div class="form-grid">
            <label class="field">
              <span>Player A</span>
              <select name="player_a_id" class="pe-select">
                <option :for={p <- @forbidden_pairing_players} value={p.id}>{p.name}</option>
              </select>
            </label>

            <label class="field">
              <span>Player B</span>
              <select name="player_b_id" class="pe-select">
                <option :for={p <- @forbidden_pairing_players} value={p.id}>{p.name}</option>
              </select>
            </label>
          </div>

          <p :if={@forbidden_pairing_error} class="error-note">{@forbidden_pairing_error}</p>

          <div class="actions">
            <button type="submit" class="pe-btn primary" disabled={length(@forbidden_pairing_players) < 2}>
              Add
            </button>
          </div>
        </form>

        <div :if={@forbidden_pairings != []} class="card-table-wrap" style="margin-top: 16px">
          <table class="pe-table">
            <thead>
              <tr>
                <th>Pair</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={fp <- @forbidden_pairings}>
                <td>{fp.player_a.name} — {fp.player_b.name}</td>
                <td style="text-align: right">
                  <button
                    class="pe-btn danger-link"
                    phx-click="remove_forbidden_pairing"
                    phx-value-id={fp.id}
                  >
                    Remove
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <p :if={@forbidden_pairings == []} class="hint" style="margin-bottom: 0">
          No forbidden pairings yet.
        </p>

        <h3 style="margin-top: 24px">Club / federation exclusions</h3>

        <p class="hint" style="margin-top: 0">
          Automatically forbid pairing any two players who share a club or federation, instead of
          listing every pair by hand. Applies to Swiss (JaVaFo "XXP" rules, same as above) and to
          Keizer; a round robin's fixed schedule ignores this by design.
        </p>

        <form id="exclusion-rules-form" phx-submit="save_exclusions">
          <div class="form-grid">
            <label class="field">
              <span>Clubs</span>
              <select name="tournament[club_exclusion]" class="pe-select" phx-change="club_exclusion_mode_change">
                <option
                  :for={m <- Tournament.exclusion_modes()}
                  value={m}
                  selected={m == @club_exclusion_mode}
                >
                  {Tournament.exclusion_mode_label(m)}
                </option>
              </select>
            </label>

            <label :if={@club_exclusion_mode == "listed"} class="field">
              <span>Clubs (comma-separated)</span>
              <input
                type="text"
                name="tournament[club_exclusion_list]"
                value={@tournament.club_exclusion_list}
                placeholder="e.g. Chess Club A, Chess Club B"
              />
            </label>

            <label class="field">
              <span>Federations</span>
              <select name="tournament[fed_exclusion]" class="pe-select" phx-change="fed_exclusion_mode_change">
                <option
                  :for={m <- Tournament.exclusion_modes()}
                  value={m}
                  selected={m == @fed_exclusion_mode}
                >
                  {Tournament.exclusion_mode_label(m)}
                </option>
              </select>
            </label>

            <label :if={@fed_exclusion_mode == "listed"} class="field">
              <span>Federations (comma-separated)</span>
              <input
                type="text"
                name="tournament[fed_exclusion_list]"
                value={@tournament.fed_exclusion_list}
                placeholder="e.g. BEL, NED"
              />
            </label>
          </div>

          <p class="hint" style="margin-bottom: 0">
            {@excluded_pair_count} pair(s) currently excluded by these rules.
          </p>

          <p :if={@exclusion_error} class="error-note">{@exclusion_error}</p>

          <div class="actions">
            <button type="submit" class="pe-btn primary">Save exclusion rules</button>
          </div>
        </form>
      </div>
    </Layouts.app>
    """
  end
end
