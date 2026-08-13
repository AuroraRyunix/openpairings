defmodule PairingsEngineWeb.AuditLive do
  @moduledoc """
  The per-tournament audit trail (see `PairingsEngine.Audit`): a paginated,
  newest-first list of every state-changing action, each rendered into a
  human-readable sentence by `describe/1`, filterable by action category.

  Access control is the same as every other tournament page —
  `Tournaments.get_authorized_tournament!/2` (owner or accepted
  collaborator); a non-collaborator 404s exactly like anywhere else.
  """
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{Audit, Tournaments}
  alias PairingsEngine.Pairing, as: Engine

  @per_page 50

  # Action-code buckets for the category filter. `:all` means "no filter";
  # every other bucket passes its explicit list of codes to
  # `Audit.list_for_tournament/2`. Novel codes not listed here still appear
  # under "All".
  @categories [
    {"all", "All", :all},
    {"players", "Players",
     ~w(player.created player.updated player.deleted player.ratings_refreshed)},
    {"pairings", "Pairings", ~w(pairing.round_paired pairing.result_entered pairing.result_changed
        pairing.round_deleted pairing.results_imported)},
    {"settings", "Settings", ~w(tournament.settings_updated logo.uploaded logo.cleared
        forbidden_pairing.added forbidden_pairing.removed
        category.created category.removed)},
    {"standings", "Standings", ~w(standings.manual_reorder standings.manual_ranking_enabled
        standings.manual_ranking_disabled standings.manual_reseeded
        standings.extra_points_applied)},
    {"imports", "Imports", ~w(import.swar import.trf import.json)},
    {"collaborators", "Collaborators",
     ~w(collaborator.invited collaborator.accepted collaborator.declined
        collaborator.removed)},
    {"tournament", "Tournament",
     ~w(tournament.created tournament.deleted tournament.restored tournament.purged)}
  ]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    socket =
      assign(socket,
        tournament: tournament,
        page_title: page_title(socket.assigns.live_action, tournament),
        category: "all",
        page: 0
      )

    socket =
      case socket.assigns.live_action do
        :explain -> assign(socket, paired_rounds: Engine.paired_rounds_count(tournament.id))
        _ -> load_entries(socket)
      end

    {:ok, socket}
  end

  defp page_title(:explain, tournament), do: "#{tournament.name} · Pairing rationale"
  defp page_title(_, tournament), do: "#{tournament.name} · Audit trail"

  @impl true
  def handle_event("filter", %{"category" => category}, socket) do
    {:noreply, socket |> assign(category: category, page: 0) |> load_entries()}
  end

  def handle_event("page", %{"delta" => delta}, socket) do
    page = max(socket.assigns.page + String.to_integer(delta), 0)
    {:noreply, socket |> assign(page: page) |> load_entries()}
  end

  defp load_entries(socket) do
    %{tournament: t, category: category, page: page} = socket.assigns
    actions = category_actions(category)

    opts =
      [limit: @per_page, offset: page * @per_page]
      |> maybe_actions(actions)

    entries = Audit.list_for_tournament(t.id, opts)
    total = Audit.count_for_tournament(t.id, count_opts(actions))

    assign(socket, entries: entries, total: total)
  end

  defp maybe_actions(opts, :all), do: opts
  defp maybe_actions(opts, actions), do: Keyword.put(opts, :actions, actions)

  defp count_opts(:all), do: []
  defp count_opts(actions), do: [actions: actions]

  defp category_actions(key) do
    case Enum.find(@categories, fn {k, _label, _codes} -> k == key end) do
      {_k, _label, :all} -> :all
      {_k, _label, codes} -> codes
      nil -> :all
    end
  end

  defp categories, do: @categories

  ## ---------- rendering the log ----------

  @doc """
  Renders one audit row's `action` + `details` into a readable sentence.
  `details` maps come back from the JSON column with string keys.
  """
  def describe(%{action: action, details: details}), do: describe(action, details || %{})

  def describe("player.created", d),
    do: "Registered player #{name(d, "player_name")}#{rating_suffix(d)}."

  def describe("player.updated", d),
    do: "Updated player #{name(d, "player_name")}: #{changed_fields(d)}."

  def describe("player.deleted", d), do: "Deleted player #{name(d, "player_name")}."

  def describe("player.ratings_refreshed", d),
    do: "Refreshed ratings for #{count(d, "players_updated")} player(s)."

  def describe("pairing.round_paired", d), do: describe_round_paired(d)

  def describe("pairing.result_entered", d),
    do:
      "Entered result #{value(d, "to")} on board #{value(d, "board")} (round #{value(d, "round")}): #{board_players(d)}.#{mobile_suffix(d)}"

  def describe("pairing.result_changed", d),
    do:
      "Changed result on board #{value(d, "board")} (round #{value(d, "round")}) from #{blank_dash(d["from"])} to #{value(d, "to")}: #{board_players(d)}.#{mobile_suffix(d)}"

  def describe("pairing.result_cleared", d),
    do:
      "Cleared the result on board #{value(d, "board")} (round #{value(d, "round")}) (was #{blank_dash(d["from"])}): #{board_players(d)}.#{mobile_suffix(d)}"

  def describe("pairing.round_deleted", d), do: "Unpaired round #{value(d, "round")}."

  def describe("pairing.results_imported", d),
    do: "Imported #{count(d, "results_set")} result(s) for round #{value(d, "round")} (CSV)."

  def describe("tournament.settings_updated", d),
    do: "Updated tournament settings: #{changed_fields(d)}."

  def describe("tournament.created", d),
    do: "Created tournament #{name(d, "name")} (#{value(d, "pairing_system")})."

  def describe("tournament.deleted", d),
    do: "Moved tournament #{name(d, "name")} to the recycle bin."

  def describe("tournament.restored", d),
    do: "Restored tournament #{name(d, "name")} from the recycle bin."

  def describe("tournament.purged", d), do: "Permanently deleted tournament #{name(d, "name")}."

  def describe("import.swar", d), do: "Imported tournament #{name(d, "name")} from a SWAR file."
  def describe("import.trf", d), do: "Imported tournament #{name(d, "name")} from a TRF file."
  def describe("import.json", d), do: "Imported tournament #{name(d, "name")} from a JSON backup."

  def describe("collaborator.invited", d), do: "Invited #{value(d, "email")} as a collaborator."

  def describe("collaborator.accepted", d),
    do: "Accepted the collaboration invite (#{value(d, "email")})."

  def describe("collaborator.declined", d),
    do: "Declined the collaboration invite (#{value(d, "email")})."

  def describe("collaborator.removed", d), do: "Removed collaborator #{value(d, "email")}."

  def describe("forbidden_pairing.added", d),
    do:
      "Added a forbidden pairing (players ##{value(d, "player_a_id")} and ##{value(d, "player_b_id")})."

  def describe("forbidden_pairing.removed", d),
    do:
      "Removed a forbidden pairing (players ##{value(d, "player_a_id")} and ##{value(d, "player_b_id")})."

  def describe("category.created", d), do: "Added category #{name(d, "name")}."
  def describe("category.removed", d), do: "Removed category #{name(d, "name")}."

  def describe("logo.uploaded", _d), do: "Uploaded a tournament logo."
  def describe("logo.cleared", _d), do: "Removed the tournament logo."

  def describe("standings.manual_reorder", d),
    do: "Moved #{name(d, "player_name")} #{value(d, "direction")} in the manual standings order."

  def describe("standings.manual_ranking_enabled", _d), do: "Enabled manual standings ordering."
  def describe("standings.manual_ranking_disabled", _d), do: "Disabled manual standings ordering."

  def describe("standings.manual_reseeded", _d),
    do: "Re-seeded the manual standings order from the computed ranking."

  def describe("standings.extra_points_applied", d),
    do: "Applied extra-points bands to #{value(d, "matched")} of #{value(d, "total")} players."

  # Fallback for any code not explicitly handled — still readable.
  def describe(action, _details), do: "#{action}"

  defp describe_round_paired(d) do
    round = value(d, "round")
    boards = d["board_count"] || 0
    byes = d["bye_count"] || 0
    floaters = d["floater_count"] || 0

    parts =
      [
        "#{plural(boards, "board")}",
        byes > 0 && "#{plural(byes, "bye")}",
        floaters > 0 && "#{plural(floaters, "floater")}"
      ]
      |> Enum.filter(& &1)
      |> Enum.join(", ")

    bye_note =
      case d["allocated_bye"] do
        %{"player" => player} when is_binary(player) -> " Bye awarded to #{player}."
        _ -> ""
      end

    "Paired round #{round}: #{parts}.#{bye_note}"
  end

  ## ---------- detail helpers (details use string keys after JSON round-trip) ----------

  defp changed_fields(d) do
    case d["changed_fields"] do
      map when is_map(map) and map_size(map) > 0 ->
        map
        |> Enum.map(fn {field, pair} -> "#{field} #{format_pair(pair)}" end)
        |> Enum.join("; ")

      _ ->
        "(no tracked field changed)"
    end
  end

  defp format_pair([before, after_value]),
    do: "#{blank_dash(before)} → #{blank_dash(after_value)}"

  defp format_pair(other), do: inspect(other)

  defp board_players(d) do
    white = d["white"] || "?"
    black = d["black"]
    if black, do: "#{white} vs #{black}", else: "#{white} (bye)"
  end

  defp rating_suffix(d) do
    case d["rating"] do
      r when is_integer(r) and r > 0 -> " (rating #{r})"
      _ -> ""
    end
  end

  # Mobile result entry has no user account to attribute to (`Audit.log/4`'s
  # `nil` case, rendered as "System" elsewhere on this page) — this is the
  # one place that still says WHICH phone, using whatever label the arbiter
  # gave the enrollment (see `MobileResultsLive.log_mobile_result/4`).
  defp mobile_suffix(%{"via" => "mobile"} = d) do
    label = d["enrollment_label"]

    device =
      if label not in [nil, ""], do: "\"#{label}\"", else: "enrollment ##{d["enrollment_id"]}"

    " (via phone, #{device})"
  end

  defp mobile_suffix(_d), do: ""

  defp name(d, key), do: bold_text(d[key] || "(unnamed)")
  defp value(d, key), do: d[key] || "?"
  defp count(d, key), do: d[key] || 0
  defp bold_text(v), do: v

  defp blank_dash(v) when v in [nil, ""], do: "—"
  defp blank_dash(v), do: to_string(v)

  defp plural(1, word), do: "1 #{word}"
  defp plural(n, word), do: "#{n} #{word}s"

  defp actor(%{user: %{email: email}}), do: email
  defp actor(_), do: "System"

  defp format_time(%NaiveDateTime{} = ndt), do: Calendar.strftime(ndt, "%Y-%m-%d %H:%M")
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_time(other), do: to_string(other)

  @doc """
  Sub-nav across the three views of the same underlying history: the visual
  timeline (`PairingsEngineWeb.HistoryLive`), this dense audit table, and the
  explain-a-round picker/page. `active` is `:history`, `:index` or
  `:explain`.
  """
  attr :tournament, :map, required: true
  attr :active, :atom, required: true

  def subnav(assigns) do
    ~H"""
    <div class="round-picker" style="flex-wrap: wrap; margin-bottom: 12px">
      <.link
        navigate={~p"/t/#{@tournament.id}/history"}
        class={["pe-btn", "filter-picker", @active == :history && "active"]}
      >
        History
      </.link>
      <.link
        navigate={~p"/t/#{@tournament.id}/audit"}
        class={["pe-btn", "filter-picker", @active == :index && "active"]}
      >
        Audit trail
      </.link>
      <.link
        navigate={~p"/t/#{@tournament.id}/audit/explain"}
        class={["pe-btn", "filter-picker", @active == :explain && "active"]}
      >
        Pairing rationale
      </.link>
    </div>
    """
  end

  @impl true
  def render(%{live_action: :explain} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} tournament={@tournament} active="audit">
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">
            Pick a paired round to see its pairing rationale
          </p>
        </div>
      </div>

      <.subnav tournament={@tournament} active={:explain} />

      <div :if={@paired_rounds == 0} class="card error-note" style="display: block; margin: 12px 0">
        No rounds have been paired yet, so there is nothing to explain.
      </div>

      <div :if={@paired_rounds > 0} class="round-picker">
        <.link
          :for={n <- 1..@paired_rounds}
          navigate={~p"/t/#{@tournament.id}/pairings/#{n}/explain"}
          class="pe-btn"
        >
          {n}
        </.link>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, per_page: @per_page)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} tournament={@tournament} active="audit">
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">Audit trail - every change, who made it, and when</p>
        </div>
      </div>

      <.subnav tournament={@tournament} active={:index} />

      <div class="round-picker" style="flex-wrap: wrap">
        <button
          :for={{key, label, _codes} <- categories()}
          class={["pe-btn", "filter-picker", key == @category && "active"]}
          phx-click="filter"
          phx-value-category={key}
        >
          {label}
        </button>
      </div>

      <p class="hint" style="margin: 8px 0">
        {@total} event{if @total != 1, do: "s"} total{if @category != "all", do: " in this category"}.
      </p>

      <div class="card table-card">
        <table class="pe-table">
          <thead>
            <tr>
              <th style="width: 150px">When</th>
              <th style="width: 220px">Who</th>
              <th>What</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@entries == []}>
              <td colspan="3">
                <div class="empty">
                  <p class="hint">No audit events recorded yet.</p>
                </div>
              </td>
            </tr>

            <tr :for={entry <- @entries}>
              <td style="white-space: nowrap">{format_time(entry.inserted_at)}</td>
              <td>{actor(entry)}</td>
              <td>{describe(entry)}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="actions" style="margin-top: 12px; justify-content: space-between">
        <button
          class="pe-btn"
          phx-click="page"
          phx-value-delta="-1"
          disabled={@page == 0}
        >
          ← Newer
        </button>

        <span class="hint">Page {@page + 1}</span>

        <button
          class="pe-btn"
          phx-click="page"
          phx-value-delta="1"
          disabled={(@page + 1) * @per_page >= @total}
        >
          Older →
        </button>
      </div>
    </Layouts.app>
    """
  end
end
