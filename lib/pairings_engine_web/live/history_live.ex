defmodule PairingsEngineWeb.HistoryLive do
  @moduledoc """
  The tournament history page (`/t/:id/history`) — the tree of RESTORE POINTS,
  and the only page that can act on one.

  It shows `PairingsEngine.Snapshots` rows: the points saved automatically
  before each irreversible action, plus any the arbiter saved deliberately.
  Branching is first-class — going back and carrying on differently leaves the
  abandoned line visible on its own lane, still switchable.

  `PairingsEngine.Audit` rows are NOT peers of those points. Each one is
  folded under the point it followed, collapsed until asked for. That is a
  deliberate change from the merged stream this page used to render, made for
  two reasons that both showed up in use:

    * a hand-saved point writes both a snapshot and an audit row, so it
      appeared on screen twice;
    * audit rows carry no branch information at all, so after switching to a
      branch a result change still rendered at the top of the trunk — which is
      not where the tournament was. A point knows its lane; hanging the rows
      off a point is what gives them the context they cannot hold themselves.

  Distinct from `PairingsEngineWeb.AuditLive`, which is the dense, paginated,
  filterable *table* of those same audit rows and remains the place to search
  them. This page deliberately has no kind filter: filtering by "players" or
  "settings" is a question about changes, and changes are that page's subject,
  not this one's. The two share `AuditLive.describe/1` so an action's prose is
  written once.

  "Go back to here" / "Switch to this branch" run `Snapshots.restore/3` behind
  a type-to-confirm modal, and "Save restore point" captures one
  (`"snapshot.manual"`) — the only capture in the app that isn't a side effect
  of some other action, and the only way to mark a state reached by
  hand-editing players, settings or results.
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
       # Branches start OPEN and collapse on request; it is the CHANGES under
       # each point that are folded by default. A branch is a path you might
       # go back to, so hiding it by default hides the reason to be here.
       collapsed_branches: MapSet.new(),
       expanded_changes: MapSet.new(),
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
  def handle_event("toggle_changes", %{"id" => id}, socket) do
    expanded = socket.assigns.expanded_changes

    expanded =
      if MapSet.member?(expanded, id),
        do: MapSet.delete(expanded, id),
        else: MapSet.put(expanded, id)

    {:noreply, assign(socket, expanded_changes: expanded)}
  end

  def handle_event("toggle_branch", %{"lane" => lane}, socket) do
    lane = String.to_integer(lane)
    collapsed = socket.assigns.collapsed_branches

    collapsed =
      if MapSet.member?(collapsed, lane),
        do: MapSet.delete(collapsed, lane),
        else: MapSet.put(collapsed, lane)

    {:noreply, socket |> assign(collapsed_branches: collapsed) |> assign_rows()}
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
      # A hand-saved point writes BOTH a snapshot and an audit row, so it used
      # to appear twice on this page -- once as "Saved a restore point." and
      # once as the point itself. The point IS the event here; the audit row
      # stays in the audit trail where the duplication does not arise.
      |> Enum.reject(&(&1.action == @manual_trigger))
      |> Enum.map(&audit_event/1)
      |> Enum.sort_by(&DateTime.to_unix(&1.at), :desc)

    # The branch tree carries lane/HEAD info the flat list doesn't, so the
    # timeline's rows come from here rather than Snapshots.list/2.
    tree = Snapshots.branch_tree(tournament)
    {points, older_changes} = tree |> Enum.map(&snapshot_event/1) |> attach_changes(events)

    lanes = Enum.map(points, & &1.lane)

    socket
    |> assign(
      points: points,
      older_changes: older_changes,
      snapshot_count: length(points),
      # How many restore points can actually be RESTORED TO, which is not the
      # same as how many exist: the newest one is where the tournament already
      # is, and offering "go back" to the state you are in would be a no-op.
      # With exactly one restore point that count is zero, so the page showed a
      # save button and nothing else with no word about why.
      restorable_count: Enum.count(points, &(&1.snapshot_id && !&1.is_head)),
      event_count: length(events),
      max_lane: Enum.max(lanes, fn -> 0 end),
      branched?: Enum.any?(lanes, &(&1 > 0))
    )
    |> assign_rows()
  end

  # Every change that happened AFTER a restore point and before the next one,
  # hung off that point instead of being a timeline row in its own right.
  #
  # Audit rows used to be merged into the timeline as peers of the restore
  # points. Two things were wrong with that, both reported. Saving a point by
  # hand wrote an audit row AND a snapshot, so it appeared twice. And audit
  # rows carry no branch information at all — after switching to a branch, a
  # result change still rendered on the trunk at the top of the page, which is
  # not where the tournament was. Attaching them to the point they follow
  # gives them the branch context they lack, because the point has it.
  #
  # `points` is newest-first and `events` is sorted the same way, so each
  # point takes everything left that is not older than it. What survives the
  # fold predates the oldest restore point.
  defp attach_changes(points, events) do
    {reversed, older} =
      Enum.reduce(points, {[], events}, fn point, {acc, remaining} ->
        {mine, rest} =
          Enum.split_with(remaining, &(DateTime.compare(&1.at, point.at) != :lt))

        {[Map.put(point, :changes, mine) | acc], rest}
      end)

    {Enum.reverse(reversed), older}
  end

  # Flattens the points into what actually renders: either a point, or -- for
  # the newest point of a collapsed branch -- one summary row standing in for
  # the whole branch. Rebuilt on every toggle rather than decided in the
  # template, so the template stays a straight `:for` over `@rows`.
  defp assign_rows(socket) do
    %{points: points, collapsed_branches: collapsed} = socket.assigns
    sizes = Enum.frequencies_by(points, & &1.lane)

    {rows, _seen} =
      Enum.reduce(points, {[], MapSet.new()}, fn point, {acc, seen} ->
        cond do
          not MapSet.member?(collapsed, point.lane) ->
            {[{:point, point} | acc], seen}

          MapSet.member?(seen, point.lane) ->
            {acc, seen}

          true ->
            {[{:branch, point.lane, Map.fetch!(sizes, point.lane)} | acc],
             MapSet.put(seen, point.lane)}
        end
      end)

    assign(socket, rows: Enum.reverse(rows))
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

  defp time_label(at), do: Calendar.strftime(at, "%H:%M")

  # A restore point's own stamp. Day headings used to carry the date and each
  # row only the time; that could not survive branch collapse, since one
  # collapsed branch stands in for points which may span several days. So the
  # date moved onto the row. "Today"/"Yesterday" stay because they are what an
  # arbiter actually reads mid-event.
  defp stamp(at) do
    date = DateTime.to_date(at)

    prefix =
      case Date.diff(Date.utc_today(), date) do
        0 -> "Today"
        1 -> "Yesterday"
        _ -> Calendar.strftime(date, "%-d %B %Y")
      end

    prefix <> " " <> time_label(at)
  end

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
        <h2>Restore points</h2>

        <p class="hint" style="margin-top: 0">
          The states you can put this tournament back into, newest first. One is
          saved automatically before anything irreversible, and you can save one
          whenever you like. Everything that changed in between is folded under
          the point it followed — open a point to read it, or use
          <.link navigate={~p"/t/#{@tournament.id}/audit"}>Audit trail</.link>
          for the full searchable log.
        </p>

        <p :if={@branched?} class="hint hist-branched">
          This history has <strong>branched</strong>
          — you went back and carried on differently. The leftmost line is where the
          tournament is now; the others are the paths you left, still there to return to.
        </p>

        <%!-- The only capture in the app the arbiter drives themselves. Not
              behind a confirm: taking one is additive, unlike the restore
              below. Hidden (but still refused server-side) once archived. --%>
        <form
          :if={!@tournament.archived_at}
          id="tl-save"
          class="hist-save"
          phx-change="snapshot_label"
          phx-submit="snapshot_save"
        >
          <div class="hist-save-field">
            <label for="hist-save-label">Name this point</label>
            <input
              id="hist-save-label"
              type="text"
              name="label"
              value={@snapshot_label}
              maxlength={label_max()}
              autocomplete="off"
              placeholder="End of day 1"
              aria-describedby="hist-save-hint"
            />
            <span id="hist-save-hint" class="hint">
              Optional — it is how you will recognise this point later. "Before the
              appeal", "all round 3 results in".
            </span>
          </div>
          <button type="submit" class="pe-btn primary">Save restore point</button>
        </form>

        <p :if={@snapshot_count == 0} class="hint hist-note">
          <strong>No restore points yet.</strong>
          One is saved automatically before anything irreversible — pairing or
          unpairing a round, or importing results from a file. Editing players,
          adjusting settings and typing results in by hand don't take one<span :if={
            !@tournament.archived_at
          }>, so save one yourself whenever you reach a state worth coming back to</span>.
        </p>

        <%!-- Having exactly one restore point is the state that looked broken:
              it is the one the tournament is already on, so it gets no "go
              back" button and the page showed a save box and nothing else. --%>
        <p :if={@snapshot_count > 0 and @restorable_count == 0} class="hint hist-note">
          <strong>One restore point, and you are on it.</strong>
          There is nowhere to go back to yet — the option to go back appears on a point
          once the tournament has moved past it. Carry on working, and save another
          when you reach the next state worth keeping.
        </p>

        <ol class="hist" style={"--hist-lanes: #{@max_lane}"}>
          <li
            :for={row <- @rows}
            class={["hist-row", row_lane(row) > 0 && "off-trunk"]}
            style={"--hist-lane: #{row_lane(row)}"}
          >
            <%= case row do %>
              <% {:branch, lane, count} -> %>
                <button
                  type="button"
                  class="hist-stub"
                  phx-click="toggle_branch"
                  phx-value-lane={lane}
                >
                  <span class="hist-dot hist-dot-stub"></span>
                  <span class="hist-chevron" aria-hidden="true">▸</span>
                  <span>
                    Abandoned branch — {count} restore point{if count == 1, do: "", else: "s"}
                  </span>
                </button>
              <% {:point, point} -> %>
                <.point_row
                  point={point}
                  tournament={@tournament}
                  expanded={MapSet.member?(@expanded_changes, point.id)}
                />
            <% end %>
          </li>
        </ol>

        <p :if={@older_changes != []} class="hint hist-note">
          {length(@older_changes)} change(s) predate the oldest restore point — they
          are in the <.link navigate={~p"/t/#{@tournament.id}/audit"}>Audit trail</.link>.
        </p>
      </div>

      <.restore_modal
        :if={@restore_target}
        snapshot={@restore_target}
        confirm={@restore_confirm}
      />
    </Layouts.app>
    """
  end

  attr :point, :map, required: true
  attr :tournament, :map, required: true
  attr :expanded, :boolean, required: true

  defp point_row(assigns) do
    ~H"""
    <span class="hist-dot"></span>
    <div class="hist-body">
      <div class="hist-head">
        <span class="hist-title">{@point.text}</span>
        <span :if={@point.is_head} class="hist-badge is-here">the tournament is here</span>
        <span :if={@point.manual} class="hist-badge">saved by hand</span>
        <span :if={@point.forks} class="hist-badge">branch point</span>
      </div>

      <div class="hist-meta">
        <span>{stamp(@point.at)}</span> <span class="hist-sep">·</span> <span>{@point.who}</span>
      </div>

      <div class="hist-actions">
        <button
          :if={@point.snapshot_id && !@tournament.archived_at && !@point.is_head}
          type="button"
          class="pe-btn"
          phx-click="restore_start"
          phx-value-id={@point.snapshot_id}
        >
          {if @point.on_head_line, do: "Go back to here", else: "Switch to this branch"}
        </button>

        <button
          :if={@point.lane > 0}
          type="button"
          class="pe-btn hist-quiet"
          phx-click="toggle_branch"
          phx-value-lane={@point.lane}
        >
          Collapse branch
        </button>
      </div>

      <%!-- The changes that followed this point. Collapsed by default: on a
            real tournament this is dozens of single-field edits, and the
            reason to be on this page is the points, not the edits. --%>
      <button
        :if={@point.changes != []}
        type="button"
        class="hist-changes-toggle"
        aria-expanded={to_string(@expanded)}
        phx-click="toggle_changes"
        phx-value-id={@point.id}
      >
        <span class={["hist-chevron", @expanded && "is-open"]} aria-hidden="true">▸</span> {length(
          @point.changes
        )} change{if length(@point.changes) == 1, do: "", else: "s"} after this point
      </button>

      <ol :if={@expanded and @point.changes != []} class="hist-changes">
        <li :for={change <- @point.changes} class="hist-change" data-kind={change.kind}>
          <div class="hist-change-head">
            <span class="hist-change-time">{time_label(change.at)}</span>
            <span class="hist-change-tag">{change.kind}</span>
            <span class="hist-change-who">{change.who}</span>
          </div>

          <div class="hist-change-text">{change.text}</div>

          <div :if={change.diff != []} class="tl-diff">
            <div :for={row <- change.diff} class="tl-diff-row">
              <span class="tl-diff-field">{field_label(row.field)}</span>
              <.diff_value value={row.before} side="before" />
              <span class="tl-arrow" aria-label="changed to">→</span>
              <.diff_value value={row.after} side="after" />
            </div>
          </div>
        </li>
      </ol>
    </div>
    """
  end

  defp row_lane({:point, point}), do: point.lane
  defp row_lane({:branch, lane, _count}), do: lane

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
