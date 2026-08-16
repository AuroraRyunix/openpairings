defmodule PairingsEngineWeb.HistoryLive do
  @moduledoc """
  The tournament history page (`/t/:id/history`) — a visual, chronological
  view of everything that has happened to a tournament, built from two
  sources merged into one stream:

    * `PairingsEngine.Audit` rows — every state-changing action, with the
      before/after payload rich enough to render a real field-level diff.
    * `PairingsEngine.Snapshots` rows — the restore points, taken
      automatically before each irreversible action and, from this page,
      on demand.

  Distinct from `PairingsEngineWeb.AuditLive`, which is the dense, paginated,
  filterable *table* of the same audit rows. This page is the narrative view:
  fewer entries, more context per entry, and the restore points shown inline
  where they sit in time. The two share `AuditLive.describe/1` so an action's
  prose is written once.

  Not read-only: this is the only page that can *act* on a restore point.
  "Go back to here" / "Switch to this branch" run `Snapshots.restore/3`
  behind a type-to-confirm modal, and "Save a restore point" captures one
  deliberately (`"snapshot.manual"`) — the only capture in the app that
  isn't a side effect of some other action, and the only way to mark a state
  reached by hand-editing players, settings or results.
  """
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{Audit, Snapshots, Tournaments}
  alias PairingsEngineWeb.{AuditLive, SettingsSupport}

  # How many audit rows to pull. The stream is merged with snapshots and
  # rendered in full (no pagination) — this is the "recent narrative" view,
  # with AuditLive remaining the exhaustive paginated one.
  @audit_limit 120

  # The trigger code a hand-saved restore point carries. Deliberately its own
  # code rather than reusing one of the four automatic ones
  # (`pairing.round_paired`, `pairing.round_deleted`,
  # `pairing.results_imported`, `snapshot.restored`) so the timeline, the
  # audit table and anyone reading the raw table can tell "the arbiter chose
  # this moment" apart from "the app protected an irreversible action".
  @manual_trigger "snapshot.manual"

  # What a hand-saved point is called when the arbiter doesn't type a label.
  # Reads correctly both on the timeline and inside `Snapshots.restore/3`'s
  # "Before restoring to ..." summary.
  @manual_summary "Manual restore point"

  # A label is a timeline caption, not a document — long enough for "end of
  # day 1, before the appeal", short enough that it can't wreck the row.
  @label_max 120

  # Maps an action code onto the timeline category that colours its dot.
  # Anything unmatched falls back to "tournament" (neutral slate) rather
  # than being hidden, so a new action code is still visible here.
  @kinds %{
    "player" => "players",
    "pairing" => "pairings",
    "tournament" => "tournament",
    "logo" => "settings",
    "forbidden_pairing" => "settings",
    "category" => "settings",
    "categories" => "settings",
    "pair_by_category" => "settings",
    "standings" => "standings",
    "import" => "imports",
    "collaborator" => "collaborators",
    "registration" => "settings",
    "public_pages" => "settings"
  }

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     socket
     |> assign(
       tournament: tournament,
       page_title: "#{tournament.name} · History",
       filter: "all",
       restore_target: nil,
       restore_confirm: "",
       snapshot_label: ""
     )
     |> load_stream()}
  end

  @impl true
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
        {:noreply, socket |> assign(tournament: tournament) |> load_stream()}
    end
  end

  @impl true
  def handle_event("filter", %{"kind" => kind}, socket) do
    {:noreply, socket |> assign(filter: kind) |> load_stream()}
  end

  ## ---------- saving a restore point by hand ----------
  #
  # Until this existed, `Snapshots.capture/4` was only ever reached from four
  # handlers in `PairingsLive` (pairing a round, unpairing one, pairing a
  # whole round-robin schedule, importing results by CSV). A tournament run
  # entirely by hand — players edited, settings tuned, results typed in one
  # by one — therefore had *no* restore points at all, so every restore
  # button on this page was hidden and the whole thing read as a list you
  # could only look at. This is the deliberate capture that fixes that.
  #
  # No confirm step: taking a snapshot is additive and cheap to undo (it is
  # pruned like any other), the opposite of the restore below.

  def handle_event("snapshot_label", %{"label" => label}, socket) do
    {:noreply, assign(socket, snapshot_label: label)}
  end

  def handle_event("snapshot_save", params, socket) do
    tournament = socket.assigns.tournament
    label = params |> Map.get("label", socket.assigns.snapshot_label) |> clean_label()

    # A snapshot is a write, so it obeys the same archive guard as everything
    # else — the button is hidden on an archived tournament, but the event is
    # client-supplied and the handler can't rely on that.
    with :ok <- Tournaments.ensure_writable(tournament),
         {:ok, snapshot} <-
           Snapshots.capture(tournament, @manual_trigger, socket.assigns.current_scope,
             summary: label || @manual_summary
           ) do
      Audit.log(tournament.id, socket.assigns.current_scope, @manual_trigger, %{
        snapshot_id: snapshot.id,
        label: label || ""
      })

      {:noreply,
       socket
       |> assign(tournament: reload_tournament(socket), snapshot_label: "")
       |> put_flash(:info, "Restore point saved — you can come back to this exact state.")
       |> load_stream()}
    else
      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Could not save a restore point: #{SettingsSupport.error_text(reason)}"
         )}
    end
  end

  ## ---------- restoring ----------
  #
  # Gated behind a type-to-confirm modal rather than a data-confirm, matching
  # the "Delete permanently" flow on the Tournaments page: this overwrites
  # live scoring data, and a misclick must not be enough.

  def handle_event("restore_start", %{"id" => id}, socket) do
    case Snapshots.get(socket.assigns.tournament.id, id) do
      nil -> {:noreply, socket}
      snapshot -> {:noreply, assign(socket, restore_target: snapshot, restore_confirm: "")}
    end
  end

  def handle_event("restore_cancel", _params, socket) do
    {:noreply, assign(socket, restore_target: nil, restore_confirm: "")}
  end

  def handle_event("restore_confirm_input", %{"confirm" => value}, socket) do
    {:noreply, assign(socket, restore_confirm: value)}
  end

  def handle_event("restore_confirmed", _params, socket) do
    case socket.assigns do
      %{restore_target: %{} = snapshot, restore_confirm: "RESTORE"} ->
        do_restore(socket, snapshot)

      _ ->
        {:noreply, socket}
    end
  end

  # (Helpers for "snapshot_save" above. They live down here only because
  # every `handle_event/3` clause has to stay in one uninterrupted run.)

  defp clean_label(label) do
    case label |> to_string() |> String.trim() |> String.slice(0, @label_max) do
      "" -> nil
      text -> text
    end
  end

  # `capture/4` moves the tournament's `head_snapshot_id` straight through
  # `Repo.update_all` (see `Snapshots.set_head/2` — deliberately not a
  # broadcasting write), so the struct in assigns is stale the moment it
  # returns. Re-read it, or `branch_tree/1` marks the *previous* point as
  # "the tournament is here" and offers a restore button on the one just
  # saved.
  defp reload_tournament(socket) do
    Tournaments.get_authorized_tournament(
      socket.assigns.current_scope,
      socket.assigns.tournament.id
    ) || socket.assigns.tournament
  end

  defp do_restore(socket, snapshot) do
    tournament = socket.assigns.tournament

    case Snapshots.restore(tournament, snapshot.id, socket.assigns.current_scope) do
      {:ok, restored} ->
        Audit.log(restored.id, socket.assigns.current_scope, "snapshot.restored", %{
          snapshot_id: snapshot.id,
          restored_to: snapshot.summary || "",
          taken_at: DateTime.to_iso8601(snapshot.inserted_at)
        })

        {:noreply,
         socket
         |> assign(tournament: restored, restore_target: nil, restore_confirm: "")
         |> put_flash(:info, "Restored. The state you left is saved as a new restore point.")
         |> load_stream()}

      {:error, :archived} ->
        {:noreply,
         socket
         |> assign(restore_target: nil, restore_confirm: "")
         |> put_flash(:error, "This tournament is archived — unarchive it to restore.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(restore_target: nil, restore_confirm: "")
         |> put_flash(:error, "Could not restore: #{inspect(reason)}")}
    end
  end

  ## ---------- building the merged stream ----------

  defp load_stream(socket) do
    tournament = socket.assigns.tournament

    events =
      tournament.id
      |> Audit.list_for_tournament(limit: @audit_limit)
      |> Enum.map(&audit_event/1)

    # The branch tree carries lane/HEAD info the flat list doesn't, so the
    # timeline's snapshot rows come from here rather than Snapshots.list/2.
    tree = Snapshots.branch_tree(tournament)
    snapshots = Enum.map(tree, &snapshot_event/1)

    entries =
      (events ++ snapshots)
      |> Enum.sort_by(&sort_key/1, :desc)
      |> filter_entries(socket.assigns.filter)

    assign(socket,
      entries: entries,
      days: group_by_day(entries),
      snapshot_count: length(snapshots),
      event_count: length(events),
      # Widest lane in use — drives how much gutter the rail needs, and
      # whether to explain branching at all (a never-restored tournament is
      # a single line and needs no explanation).
      max_lane: tree |> Enum.map(& &1.lane) |> Enum.max(fn -> 0 end),
      branched?: Enum.any?(tree, &(&1.lane > 0))
    )
  end

  # The two sources timestamp differently: `audit_logs` uses Ecto's default
  # `:naive_datetime`, `tournament_snapshots` uses `:utc_datetime`. Both store
  # UTC, but mixing the two struct types blows up the merged sort, so both are
  # normalised to `DateTime` here. Done at read time rather than by migrating
  # the audit table, which the existing audit page also reads.
  defp to_utc(%DateTime{} = at), do: at
  defp to_utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  # Both tables store whole seconds, so a snapshot and the action it protects
  # routinely share a timestamp and their true order isn't recoverable from
  # it. Break the tie by meaning rather than arbitrarily: a snapshot is always
  # captured *before* the action it guards, so at equal times it sorts older
  # (and, since the stream is newest-first, renders below the action). The
  # `id` third makes the order fully deterministic within a source, so the
  # list can't reshuffle between renders.
  defp sort_key(%{at: at, kind: "snapshot", id: id}), do: {DateTime.to_unix(at), 0, id}
  defp sort_key(%{at: at, id: id}), do: {DateTime.to_unix(at), 1, id}

  defp audit_event(row) do
    diff = diff_rows(row.details)

    %{
      id: "audit-#{row.id}",
      at: to_utc(row.inserted_at),
      kind: kind_for(row.action),
      action: row.action,
      who: who(row.user),
      text: headline(row, diff),
      diff: diff,
      snapshot_id: nil,
      # An audit row isn't part of the snapshot tree; it always sits on the
      # trunk so the rail reads continuously between restore points.
      lane: 0,
      parent_lane: nil,
      on_head_line: true,
      is_head: false,
      forks: false,
      manual: false
    }
  end

  # `AuditLive.describe/1` inlines the changed fields into its sentence, which
  # is right for the dense audit table but duplicates the diff block here —
  # and its list formatting is cruder than the diff rows'. When there IS a
  # diff to render, use a short headline and let the diff carry the detail.
  defp headline(row, []), do: AuditLive.describe(row)

  defp headline(%{action: action, details: details}, diff),
    do: short_headline(action, details || %{}, length(diff))

  defp short_headline("tournament.settings_updated", _details, n),
    do: "Updated tournament settings — #{field_count(n)} changed."

  defp short_headline("player.updated", details, n) do
    case details["player_name"] do
      name when is_binary(name) and name != "" ->
        "Updated #{name} — #{field_count(n)} changed."

      _ ->
        "Updated a player — #{field_count(n)} changed."
    end
  end

  defp short_headline(action, _details, n), do: "#{action} — #{field_count(n)} changed."

  defp field_count(1), do: "1 field"
  defp field_count(n), do: "#{n} fields"

  defp snapshot_event(%{snapshot: snapshot} = entry) do
    manual? = snapshot.trigger == @manual_trigger

    %{
      id: "snapshot-#{snapshot.id}",
      at: to_utc(snapshot.inserted_at),
      kind: "snapshot",
      action: snapshot.trigger,
      who: who(snapshot.user),
      text: snapshot.summary || default_snapshot_text(manual?),
      diff: [],
      snapshot_id: snapshot.id,
      lane: entry.lane,
      parent_lane: entry.parent_lane,
      on_head_line: entry.on_head_line,
      is_head: entry.is_head,
      forks: entry.children > 1,
      # Drives the "saved by hand" badge and the accented dot — a point
      # somebody chose to keep reads differently from one the app took on
      # its own before something irreversible.
      manual: manual?
    }
  end

  defp default_snapshot_text(true), do: @manual_summary
  defp default_snapshot_text(false), do: "Restore point saved."

  # `details["changed_fields"]` is `%{"field" => [before, after]}` — written
  # by `SettingsSupport.log_settings_change/3` and the player-update handler.
  # Anything else (an action whose details aren't a field diff) renders as
  # prose only, via `describe/1`.
  defp diff_rows(%{"changed_fields" => map}) when is_map(map) and map_size(map) > 0 do
    map
    |> Enum.map(fn
      {field, [before, after_value]} -> %{field: field, before: before, after: after_value}
      {field, other} -> %{field: field, before: nil, after: other}
    end)
    |> Enum.sort_by(& &1.field)
  end

  defp diff_rows(_details), do: []

  defp kind_for(action) do
    prefix = action |> to_string() |> String.split(".") |> hd()
    Map.get(@kinds, prefix, "tournament")
  end

  defp who(%{email: email}) when is_binary(email), do: email
  defp who(_), do: "System"

  defp filter_entries(entries, "all"), do: entries

  defp filter_entries(entries, kind),
    do: Enum.filter(entries, &(&1.kind == kind))

  # Groups the already-sorted stream into `{date, entries}` pairs, preserving
  # order. `Enum.chunk_by/2` rather than `group_by` precisely because the
  # latter loses ordering.
  defp group_by_day(entries) do
    entries
    |> Enum.chunk_by(&DateTime.to_date(&1.at))
    |> Enum.map(fn [first | _] = chunk -> {DateTime.to_date(first.at), chunk} end)
  end

  ## ---------- formatting ----------

  defp day_label(date) do
    today = Date.utc_today()

    case Date.diff(today, date) do
      0 -> "Today"
      1 -> "Yesterday"
      _ -> Calendar.strftime(date, "%A %-d %B %Y")
    end
  end

  defp time_label(at), do: Calendar.strftime(at, "%H:%M")

  # Field names come straight from the schema; humanise them rather than
  # showing `points_win` to an arbiter.
  defp field_label(field) do
    field |> to_string() |> String.replace("_", " ")
  end

  defp value_label(nil), do: {:empty, "not set"}
  defp value_label(""), do: {:empty, "blank"}
  defp value_label(true), do: {:value, "on"}
  defp value_label(false), do: {:value, "off"}
  defp value_label(v) when is_list(v), do: {:value, Enum.join(v, ", ")}
  defp value_label(v) when is_map(v), do: {:value, inspect(v)}
  defp value_label(v), do: {:value, to_string(v)}

  @filters [
    {"all", "Everything"},
    {"pairings", "Pairings"},
    {"players", "Players"},
    {"settings", "Settings"},
    {"standings", "Standings"},
    {"snapshot", "Restore points"}
  ]

  defp filters, do: @filters

  defp label_max, do: @label_max

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      tournament={@tournament}
      active="audit"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">History</p>
        </div>
      </div>

      <AuditLive.subnav tournament={@tournament} active={:history} />

      <div class="card">
        <h2>What happened</h2>

        <p class="hint" style="margin-top: 0">
          Every change to this tournament, newest first, with the restore points
          <span class="tl-inline-diamond"></span>
          saved before anything irreversible — plus any you save yourself. {@event_count} change(s) and {@snapshot_count} restore point(s).
        </p>

        <p :if={@branched?} class="hint" style="margin-top: -4px">
          This history has <strong>branched</strong> — you went back and carried on differently.
          The leftmost line is where the tournament is now; the others are the paths you left,
          still there to go back to.
        </p>

        <%!-- The only capture in the app the arbiter drives themselves. Not
              behind a confirm: taking one is additive, unlike the restore
              below. Hidden (but still refused server-side) once archived. --%>
        <form
          :if={!@tournament.archived_at}
          id="tl-save"
          class="tl-save"
          phx-change="snapshot_label"
          phx-submit="snapshot_save"
        >
          <input
            type="text"
            name="label"
            value={@snapshot_label}
            maxlength={label_max()}
            autocomplete="off"
            placeholder="What is this point? (optional)"
            aria-label="Label for this restore point"
          />
          <button type="submit" class="pe-btn">Save a restore point</button>
        </form>

        <p :if={@snapshot_count == 0} class="hint tl-nopoints">
          <strong>No restore points yet.</strong>
          One is saved automatically before anything irreversible — pairing or unpairing a round,
          or importing results from a file. Editing players, adjusting settings and typing results
          in by hand don't take one<span :if={!@tournament.archived_at}>, so save one yourself
            whenever you reach a state worth being able to come back to</span>.
        </p>

        <div class="round-picker" style="flex-wrap: wrap; margin-bottom: 4px">
          <button
            :for={{key, label} <- filters()}
            type="button"
            class={["pe-btn", "filter-picker", @filter == key && "active"]}
            phx-click="filter"
            phx-value-kind={key}
          >
            {label}
          </button>
        </div>

        <p :if={@entries == []} class="tl-empty">
          Nothing here yet<%= if @filter != "all" do %>
            for this filter
          <% end %>.
        </p>

        <div :for={{date, day_entries} <- @days}>
          <div class="tl-day">{day_label(date)}</div>

          <ul class="tl" style={"--tl-lanes: #{@max_lane}"}>
            <li
              :for={entry <- day_entries}
              class={[
                "tl-item",
                entry.lane > 0 && "off-trunk",
                entry.is_head && "is-head",
                entry.forks && "forks",
                entry.manual && "manual"
              ]}
              data-kind={entry.kind}
              style={"--tl-lane: #{entry.lane}"}
              id={entry.id}
            >
              <%!-- The connector back to this entry's parent. Only drawn when
                    the parent sits in a different lane — within a lane the
                    continuous rail already does the job. --%>
              <span
                :if={entry.parent_lane && entry.parent_lane != entry.lane}
                class="tl-fork"
                style={"--tl-parent-lane: #{entry.parent_lane}"}
                aria-hidden="true"
              ></span>

              <span class="tl-dot"></span>

              <div class="tl-meta">
                <span class="tl-time">{time_label(entry.at)}</span>
                <span class="tl-who">{entry.who}</span>
                <span class="tl-tag">{entry.kind}</span>
                <span :if={entry.manual} class="tl-manual">saved by hand</span>
                <span :if={entry.is_head} class="tl-here">the tournament is here</span>
                <span :if={entry.forks} class="tl-forked">branch point</span>
              </div>

              <div class="tl-text">{entry.text}</div>

              <div :if={entry.diff != []} class="tl-diff">
                <div :for={row <- entry.diff} class="tl-diff-row">
                  <span class="tl-diff-field">{field_label(row.field)}</span>
                  <.diff_value value={row.before} side="before" />
                  <span class="tl-arrow" aria-label="changed to">→</span>
                  <.diff_value value={row.after} side="after" />
                </div>
              </div>

              <div
                :if={entry.snapshot_id && !@tournament.archived_at && !entry.is_head}
                class="tl-actions"
              >
                <button
                  type="button"
                  class="pe-btn"
                  phx-click="restore_start"
                  phx-value-id={entry.snapshot_id}
                >
                  {if entry.on_head_line, do: "Go back to here", else: "Switch to this branch"}
                </button>
              </div>
            </li>
          </ul>
        </div>
      </div>

      <.restore_modal
        :if={@restore_target}
        snapshot={@restore_target}
        confirm={@restore_confirm}
      />
    </Layouts.app>
    """
  end

  attr :snapshot, :map, required: true
  attr :confirm, :string, required: true

  defp restore_modal(assigns) do
    ~H"""
    <div class="modal-overlay" phx-window-keydown="restore_cancel" phx-key="escape">
      <div class="modal-card" phx-click-away="restore_cancel" style="max-width: 500px">
        <h2>Go back to this point</h2>

        <p>
          This replaces the players, rounds, results and settings with how they were at <strong>{Calendar.strftime(@snapshot.inserted_at, "%Y-%m-%d %H:%M UTC")}</strong>{if @snapshot.summary,
            do: " (#{@snapshot.summary})"}. Anything entered since then is replaced.
        </p>

        <div class="setting-warning">
          <strong>⚠ This overwrites live results.</strong>
          Every result, pairing and player change made after that point goes away.
        </div>

        <p class="hint">
          It is reversible: the state you're leaving is saved as its own restore point first, so
          you can come straight back to it. Your audit trail, collaborators and public link are
          not affected.
        </p>

        <p>Type <strong>RESTORE</strong> to confirm.</p>

        <form phx-change="restore_confirm_input" phx-submit="restore_confirmed">
          <input
            type="text"
            name="confirm"
            value={@confirm}
            autocomplete="off"
            placeholder="RESTORE"
          />

          <div class="actions">
            <button type="submit" class="pe-btn danger" disabled={@confirm != "RESTORE"}>
              Go back to this point
            </button>
            <button type="button" class="pe-btn" phx-click="restore_cancel">Cancel</button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  attr :value, :any, required: true
  attr :side, :string, required: true

  defp diff_value(assigns) do
    {tone, text} = value_label(assigns.value)
    assigns = assign(assigns, tone: tone, text: text)

    ~H"""
    <span class={["tl-val", @side, @tone == :empty && "empty"]}>{@text}</span>
    """
  end
end
