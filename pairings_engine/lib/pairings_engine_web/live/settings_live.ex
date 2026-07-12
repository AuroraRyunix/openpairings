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
    {"organizer_club_number", "Organizer club nr / logo", "text"},
    {"chief_arbiter", "Chief arbiter", "text"},
    {"deputy_arbiter", "Deputy arbiter(s)", "text"},
    {"time_control", "Time control", "text"}
  ]

  # SWAR TournoiStd (§5.13): Standard / Rapid / Blitz.
  @standard_options [
    {"standard", "Standard"},
    {"rapid", "Rapid"},
    {"blitz", "Blitz"}
  ]

  # SWAR "Cadence" presets from the Tournament tab, plus free text.
  @rate_of_play_options [
    "",
    "105 min/40 moves + 15 min. QPF",
    "90 min/40 moves + 30 min + 30 sec/move",
    "90 min + 30 sec/move",
    "60 min QPF",
    "25 min + 10 sec/move",
    "15 min + 5 sec/move",
    "5 min + 3 sec/move",
    "3 min + 2 sec/move"
  ]

  # Officials & FIDE report fields not on the Tournament schema directly —
  # nested under tournament[officials][KEY] and stored in the :officials map
  # (see PairingsEngine.Tournaments.Tournament for the recognised keys).
  @officials_fields [
    {"organizer_id", "Organizer FIDE ID", "text"},
    {"organizer_email", "Organizer e-mail", "text"},
    {"chief_arbiter_fide_id", "Chief arbiter FIDE ID", "text"},
    {"chief_arbiter_email", "Chief arbiter e-mail", "text"}
  ]

  @deputy_fields [
    {1, "1st deputy arbiter"},
    {2, "2nd deputy arbiter"},
    {3, "3rd deputy arbiter"},
    {4, "4th deputy arbiter"}
  ]

  @swiss_variants ["", "Dutch", "Lim", "Dubov", "Burstein"]

  # SWAR §5.22 Tie-break Presets (TB_PERSONEL). The manual only names the
  # enum members (TB_FIDE_RR, TB_DIS_SW, TB_REG_SW, TB_OLD_SW) without
  # publishing the exact method sequence SWAR assigns to each one, so the
  # sequences below are a best-effort mapping onto our own catalogue codes
  # (see Tiebreaks.catalogue/0) rather than a verbatim transcription —
  # flagged for review.
  @tb_presets [
    {"fide_rr", "FIDE Round Robin", ~w(DE WIN SB KS)},
    {"disparate_sw", "Disparate Swiss (wide rating range)", ~w(BHC1 BH SB)},
    {"regular_sw", "Regular Swiss", ~w(BHC1 BH PS)},
    {"old_sw", "Old Swiss (classic)", ~w(PS BH SB)}
  ]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)
    owner? = Tournaments.owner?(tournament, socket.assigns.current_scope)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    socket =
      # Unlike the other tournament views, this whole page IS one big
      # always-open form with no explicit "editing" flag — so we can't just
      # blindly reassign `@tournament` on every broadcast: since form
      # fields render their default `value` straight from `@tournament`,
      # doing so could reset text the user is mid-typing. This hook flips
      # `dirty` true the moment *any* event fires (typing, reordering
      # tiebreaks, calculating round dates, ...); the tournament_changed
      # handler below only reloads while the socket isn't dirty. A
      # successful "save" clears it again, since local edits were just
      # committed.
      attach_hook(socket, :settings_dirty_tracker, :handle_event, fn _event, _params, socket ->
        {:cont, assign(socket, dirty: true)}
      end)

    {:ok,
     socket
     |> assign(
       tournament: tournament,
       owner?: owner?,
       page_title: "#{tournament.name} · Settings",
       tiebreaks: tournament.tiebreaks,
       round_dates: pad_dates(tournament.round_dates, tournament.rounds_count),
       note: nil,
       error: nil,
       dirty: false,
       stale: false,
       collaborator_error: nil,
       collaborator_note: nil
     )
     |> assign_collaborators()}
  end

  defp assign_collaborators(socket) do
    if socket.assigns.owner? do
      assign(socket, :collaborators, Tournaments.list_collaborators(socket.assigns.tournament))
    else
      assign(socket, :collaborators, [])
    end
  end

  # Another user (or tab) changed this tournament. If the local form is
  # untouched, it's safe to reload everything from the database. If the
  # user has started editing (typed a field, reordered tiebreaks, etc.),
  # reloading would clobber that in-progress work, so we skip the reload
  # and just flag the page as stale — their next "Save" will overwrite
  # whatever changed elsewhere, which is the expected last-write-wins
  # behaviour for a settings form.
  @impl true
  def handle_info({:tournament_changed, _tournament_id, _hint}, %{assigns: %{dirty: true}} = socket) do
    {:noreply, assign(socket, stale: true)}
  end

  def handle_info({:tournament_changed, _tournament_id, _hint}, socket) do
    case Tournaments.get_authorized_tournament(socket.assigns.current_scope, socket.assigns.tournament.id) do
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
           tiebreaks: tournament.tiebreaks,
           round_dates: pad_dates(tournament.round_dates, tournament.rounds_count),
           stale: false
         )
         |> assign_collaborators()}
    end
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

  def handle_event("tb_preset", %{"key" => "personel"}, socket), do: {:noreply, socket}

  def handle_event("tb_preset", %{"key" => key}, socket) do
    case Enum.find(@tb_presets, fn {k, _label, _methods} -> k == key end) do
      nil -> {:noreply, socket}
      {_key, _label, methods} -> {:noreply, assign(socket, tiebreaks: methods, note: nil)}
    end
  end

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
        {:noreply, assign(socket, error: "Start date must be a valid date before calculating round dates.")}

      _ ->
        {:noreply, assign(socket, error: "Set a start date (in General) before calculating round dates.")}
    end
  end

  def handle_event("rd_clear", _params, socket) do
    {:noreply,
     assign(socket, round_dates: List.duplicate("", socket.assigns.tournament.rounds_count))}
  end

  def handle_event("save", %{"tournament" => params}, socket) do
    params =
      params
      |> Map.put("tiebreaks", socket.assigns.tiebreaks)
      |> apply_rate_of_play_override()
      |> normalize_round_dates()

    case Tournaments.update_tournament(socket.assigns.tournament, params) do
      {:ok, tournament} ->
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

  ## ---------- Share / Team (collaborators) — owner-only ----------

  def handle_event("add_collaborator", %{"email" => email}, socket) do
    case Tournaments.add_collaborator(socket.assigns.current_scope, socket.assigns.tournament, email) do
      {:ok, collaborator} ->
        note =
          if collaborator.mail_status == :failed do
            "Invite saved, but the email could not be sent — share this link manually: " <>
              "/invites/#{collaborator.invite_token}"
          end

        {:noreply,
         socket
         |> assign(collaborator_error: nil, collaborator_note: note)
         |> assign_collaborators()}

      {:error, :blank_email} ->
        {:noreply, assign(socket, collaborator_error: "Enter an email address", collaborator_note: nil)}

      {:error, :cannot_add_owner} ->
        {:noreply, assign(socket, collaborator_error: "You already own this tournament", collaborator_note: nil)}

      {:error, :already_added} ->
        {:noreply, assign(socket, collaborator_error: "That email already has access", collaborator_note: nil)}

      {:error, :not_owner} ->
        {:noreply,
         assign(socket, collaborator_error: "Only the owner can manage collaborators", collaborator_note: nil)}

      {:error, changeset} ->
        {:noreply, assign(socket, collaborator_error: error_text(changeset), collaborator_note: nil)}
    end
  end

  def handle_event("remove_collaborator", %{"id" => id}, socket) do
    case Tournaments.remove_collaborator(socket.assigns.current_scope, socket.assigns.tournament, id) do
      {:ok, _collaborator} -> {:noreply, assign_collaborators(socket)}
      {:error, _reason} -> {:noreply, socket}
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
  defp standard_options, do: @standard_options
  defp rate_of_play_options, do: @rate_of_play_options
  defp tb_presets, do: @tb_presets
  defp officials_fields, do: @officials_fields
  defp deputy_fields, do: @deputy_fields
  defp swiss_variants, do: @swiss_variants

  defp o_get(tournament, key), do: Map.get(tournament.officials || %{}, key, "")

  defp available_tiebreaks(selected) do
    Enum.reject(Tiebreaks.catalogue(), &(&1.code in selected))
  end

  defp tb_preset_match(tiebreaks) do
    Enum.find_value(@tb_presets, "personel", fn {key, _label, methods} ->
      if tiebreaks == methods, do: key
    end)
  end

  defp pad_dates(dates, count) do
    dates = dates || []
    dates = Enum.take(dates, count)
    dates ++ List.duplicate("", max(count - length(dates), 0))
  end

  defp apply_rate_of_play_override(params) do
    case String.trim(Map.get(params, "rate_of_play_other", "")) do
      "" -> params
      other -> Map.put(params, "rate_of_play", other)
    end
  end

  defp normalize_round_dates(params) do
    count =
      case Integer.parse(to_string(Map.get(params, "rounds_count", ""))) do
        {n, _} -> n
        :error -> length(List.wrap(Map.get(params, "round_dates", [])))
      end

    dates = params |> Map.get("round_dates", []) |> List.wrap()
    Map.put(params, "round_dates", pad_dates(dates, count))
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

      <p :if={@stale} class="error-note">
        This tournament was updated elsewhere while you were editing. Saving will overwrite that
        change with what's on this page — reload the page first if you want to see it instead.
      </p>

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
            <div class="field">
              <span>Standard</span>
              <div style="display: flex; gap: 1rem; flex-wrap: wrap; align-items: center">
                <label :for={{val, label} <- standard_options()} style="display: flex; gap: .35rem; align-items: center; font-weight: 400">
                  <input type="radio" name="tournament[standard]" value={val} checked={@tournament.standard == val} /> {label}
                </label>
              </div>
            </div>
            <label class="field">
              <span>Rate of play</span>
              <select name="tournament[rate_of_play]">
                <option
                  :for={opt <- rate_of_play_options()}
                  value={opt}
                  selected={@tournament.rate_of_play == opt}
                >
                  {if opt == "", do: "— none —", else: opt}
                </option>
                <option
                  :if={@tournament.rate_of_play not in rate_of_play_options()}
                  value={@tournament.rate_of_play}
                  selected
                >
                  {@tournament.rate_of_play}
                </option>
              </select>
            </label>
            <label class="field">
              <span>Other rate of play (overrides the select above)</span>
              <input type="text" name="tournament[rate_of_play_other]" value="" placeholder="e.g. 40 min + 10 sec/move" />
            </label>
          </div>
        </div>

        <div class="card">
          <h2>Officials &amp; FIDE report data</h2>
          <p class="hint" style="margin-top: 0">
            Feeds the IT3 / FA1 / IA1 / IT4 FIDE report forms on the
            <.link navigate={~p"/t/#{@tournament.id}/norms"}>Norms</.link>
            tab. Organizer name, chief arbiter name, and time control are set in General above.
          </p>
          <div class="form-grid">
            <label class="field">
              <span>FIDE tournament ID</span>
              <input name="tournament[fide_tournament_id]" value={@tournament.fide_tournament_id} />
            </label>
            <label class="field">
              <span>FIDE event code</span>
              <input name="tournament[event_code]" value={@tournament.event_code} />
            </label>
            <label :for={{key, label, type} <- officials_fields()} class="field">
              <span>{label}</span>
              <input type={type} name={"tournament[officials][#{key}]"} value={o_get(@tournament, key)} />
            </label>
            <label class="field">
              <span>Person responsible for pairings</span>
              <input
                name="tournament[officials][person_responsible_pairings]"
                value={o_get(@tournament, "person_responsible_pairings")}
              />
            </label>
            <label class="field">
              <span>Pairing mode</span>
              <select name="tournament[officials][pairing_mode]">
                <option value="computerized" selected={o_get(@tournament, "pairing_mode") != "manual"}>
                  Computerized
                </option>
                <option value="manual" selected={o_get(@tournament, "pairing_mode") == "manual"}>
                  Manual
                </option>
              </select>
            </label>
            <label class="field">
              <span>Pairing program</span>
              <input
                name="tournament[officials][pairing_program]"
                value={o_get(@tournament, "pairing_program")}
                placeholder="OpenPairings"
              />
            </label>
            <label class="field">
              <span>Swiss variant</span>
              <select name="tournament[officials][swiss_variant]">
                <option
                  :for={v <- swiss_variants()}
                  value={v}
                  selected={o_get(@tournament, "swiss_variant") == v}
                >
                  {if v == "", do: "— none —", else: v}
                </option>
              </select>
            </label>
            <label class="field">
              <span>IT4 event type</span>
              <input name="tournament[officials][it4_event_type]" value={o_get(@tournament, "it4_event_type")} />
            </label>
            <label class="field" style="grid-column: 1 / -1">
              <span>Link to pairings web (IT4)</span>
              <input
                name="tournament[officials][pairings_web_link]"
                value={o_get(@tournament, "pairings_web_link")}
              />
            </label>
          </div>

          <h3 style="margin: 18px 0 8px; font-size: 14px">Deputy arbiters</h3>
          <div class="form-grid">
            <div :for={{n, label} <- deputy_fields()} style="display: contents">
              <label class="field">
                <span>{label} — name</span>
                <input
                  name={"tournament[officials][deputy#{n}_name]"}
                  value={o_get(@tournament, "deputy#{n}_name")}
                />
              </label>
              <label class="field">
                <span>{label} — FIDE ID</span>
                <input
                  name={"tournament[officials][deputy#{n}_fide_id]"}
                  value={o_get(@tournament, "deputy#{n}_fide_id")}
                />
              </label>
              <label class="field">
                <span>{label} — e-mail</span>
                <input
                  name={"tournament[officials][deputy#{n}_email]"}
                  value={o_get(@tournament, "deputy#{n}_email")}
                />
              </label>
            </div>
          </div>

          <h3 style="margin: 18px 0 8px; font-size: 14px">Special remarks (IT3)</h3>
          <div class="form-grid">
            <label :for={n <- 1..4} class="field">
              <span>Remark {n}</span>
              <input name={"tournament[officials][remark#{n}]"} value={o_get(@tournament, "remark#{n}")} />
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
          <h2>Round dates</h2>
          <p class="hint" style="margin-top: 0">
            One date per round (SWAR Dates tab).
          </p>
          <div class="form-grid">
            <label :for={{date, i} <- Enum.with_index(@round_dates)} class="field">
              <span>Round {i + 1}</span>
              <input type="date" name="tournament[round_dates][]" value={date} />
            </label>
          </div>
          <div class="actions" style="flex-wrap: wrap">
            <button type="button" class="pe-btn" phx-click="rd_calc">
              Calculate from start date
            </button>
            <button type="button" class="pe-btn" phx-click="rd_clear">Clear all</button>
          </div>
        </div>

        <div class="card">
          <h2>Tiebreaks</h2>
          <p class="hint" style="margin-top: 0">
            Applied in order, following the FIDE Tie-Break Regulations. Higher in the list = decided first.
          </p>
          <div class="field" style="margin-bottom: 1rem">
            <span>Preset</span>
            <div style="display: flex; flex-wrap: wrap; gap: 1rem">
              <label style="display: flex; gap: .35rem; align-items: center; font-weight: 400">
                <input
                  type="radio"
                  name="tb_preset_display"
                  phx-click="tb_preset"
                  phx-value-key="personel"
                  checked={tb_preset_match(@tiebreaks) == "personel"}
                /> Personel
              </label>
              <label :for={{key, label, _methods} <- tb_presets()} style="display: flex; gap: .35rem; align-items: center; font-weight: 400">
                <input
                  type="radio"
                  name="tb_preset_display"
                  phx-click="tb_preset"
                  phx-value-key={key}
                  checked={tb_preset_match(@tiebreaks) == key}
                /> {label}
              </label>
            </div>
          </div>
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

      <div :if={@owner?} class="card">
        <h2>Share / Team</h2>
        <p class="hint" style="margin-top: 0">
          Invite other people to this tournament by email — they can open, edit, pair, enter
          results, print and export it, exactly like you, except they can't manage collaborators or
          delete the tournament. They only get access once they explicitly accept the emailed
          invitation while signed in with their own email
          (<.link navigate={~p"/users/log-in"}>magic link</.link>) — no shared password needed.
        </p>
        <form id="add-collaborator-form" phx-submit="add_collaborator">
          <div class="form-grid">
            <label class="field">
              <span>Email address</span>
              <input type="email" name="email" placeholder="teammate@example.com" />
            </label>
          </div>
          <p :if={@collaborator_error} class="error-note">{@collaborator_error}</p>
          <p :if={@collaborator_note} class="hint">{@collaborator_note}</p>
          <div class="actions">
            <button type="submit" class="pe-btn primary">Add collaborator</button>
          </div>
        </form>

        <div :if={@collaborators != []} class="card-table-wrap" style="margin-top: 16px">
          <table class="pe-table">
            <thead>
              <tr>
                <th>Email</th>
                <th>Status</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={c <- @collaborators}>
                <td>{c.email}</td>
                <td>
                  <span class={["badge", c.status != "accepted" && "muted"]}>
                    {if c.status == "accepted", do: "active", else: "invited (waiting for accept)"}
                  </span>
                </td>
                <td style="text-align: right">
                  <button class="pe-btn danger-link" phx-click="remove_collaborator" phx-value-id={c.id}>
                    Remove
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <p :if={@collaborators == []} class="hint" style="margin-bottom: 0">
          Nobody else has access to this tournament yet.
        </p>
      </div>

      <div class="card">
        <h2>Export / backup</h2>
        <p class="hint" style="margin-top: 0">
          A full JSON backup of this tournament — settings, officials, every player (including norm
          data), rounds, pairings/results, byes and forbidden pairings. Re-importing it (from the
          <.link navigate={~p"/"}>Tournaments</.link>
          page) always creates a brand-new tournament, never overwrites this one. For a FIDE-report-shaped
          TRF16 file instead, see <.link navigate={~p"/t/#{@tournament.id}/pairings"}>Pairings</.link>.
        </p>
        <div class="actions">
          <a class="pe-btn" href={~p"/t/#{@tournament.id}/export/json"} target="_blank">
            Export full backup (JSON)
          </a>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp tb_name(code), do: (Tiebreaks.get(code) || %{name: code}).name
  defp tb_desc(code), do: (Tiebreaks.get(code) || %{description: ""}).description
end
