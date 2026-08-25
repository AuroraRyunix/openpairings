defmodule PairingsEngineWeb.CategoriesLive do
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport

  alias PairingsEngine.{Audit, Pairing, Tournaments}

  @rule_kinds [
    {"", "None - assign by hand"},
    {"elo_below", "Below this Elo"},
    {"elo_above", "Above this Elo"},
    {"age_below", "Below this age"},
    {"age_above", "Above this age"}
  ]

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
       page_title: "#{tournament.name} · Categories",
       category_error: nil,
       rule_kinds: @rule_kinds,
       assign_note: nil,
       toggle_error: nil,
       category_confirm: nil
     )
     |> assign_pair_by_category_lock()}
  end

  # Same rationale as the other pairing-shape controls on the Options page
  # (pairing_system/rr_cycles/match format): once round 1 is paired, the
  # per-category split is baked into every board number and bye that
  # round produced, so changing it later would corrupt what's already on
  # the board - locked, not just discouraged.
  defp assign_pair_by_category_lock(socket) do
    paired = Pairing.paired_rounds_count(socket.assigns.tournament.id)
    assign(socket, pair_by_category_locked?: paired > 0)
  end

  @impl true
  def handle_info({:tournament_changed, _tournament_id, _hint}, socket) do
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
         |> assign(tournament: tournament)
         |> assign_pair_by_category_lock()}
    end
  end

  ## ---------- On/off switches - instant, no separate "Save" step ----------

  # Turning categories off also forces `pair_by_category` off in the same
  # write: `Tournament.changeset/2`'s own
  # `validate_pair_by_category_requires_categories/1` would otherwise
  # reject this exact toggle whenever pair-by-category was already on,
  # since as far as the changeset can tell both fields would be changing
  # at once and pair_by_category can't outlive the categories switch it
  # depends on.
  def handle_event("toggle_categories_enabled", _params, socket) do
    tournament = socket.assigns.tournament
    enabled? = !tournament.categories_enabled

    params =
      if enabled?,
        do: %{"categories_enabled" => "true"},
        else: %{"categories_enabled" => "false", "pair_by_category" => "false"}

    case Tournaments.update_tournament(tournament, params) do
      {:ok, updated} ->
        Audit.log(updated.id, socket.assigns.current_scope, "categories.toggled", %{
          enabled: enabled?
        })

        {:noreply, assign(socket, tournament: updated, toggle_error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, toggle_error: error_text(reason))}
    end
  end

  def handle_event("toggle_pair_by_category", _params, socket) do
    if socket.assigns.pair_by_category_locked? do
      {:noreply, socket}
    else
      tournament = socket.assigns.tournament
      enabled? = !tournament.pair_by_category

      case Tournaments.update_tournament(tournament, %{"pair_by_category" => to_string(enabled?)}) do
        {:ok, updated} ->
          Audit.log(updated.id, socket.assigns.current_scope, "pair_by_category.toggled", %{
            enabled: enabled?
          })

          {:noreply, assign(socket, tournament: updated, toggle_error: nil)}

        {:error, changeset} ->
          {:noreply, assign(socket, toggle_error: error_text(changeset))}
      end
    end
  end

  ## ---------- Categories (SWAR CATEGORIES) - any authorized user ----------

  @impl true
  def handle_event("add_category", %{"name" => name} = params, socket) do
    trimmed = String.trim(name)
    categories = socket.assigns.tournament.categories || []

    with {:ok, rule} <- parse_rule(params) do
      cond do
        trimmed == "" ->
          {:noreply, assign(socket, category_error: "Enter a category name")}

        trimmed in categories ->
          {:noreply, assign(socket, category_error: "That category already exists")}

        true ->
          category_rules =
            case rule do
              nil -> socket.assigns.tournament.category_rules
              rule -> Map.put(socket.assigns.tournament.category_rules, trimmed, rule)
            end

          case Tournaments.update_tournament(socket.assigns.tournament, %{
                 "categories" => categories ++ [trimmed],
                 "category_rules" => category_rules
               }) do
            {:ok, tournament} ->
              Audit.log(tournament.id, socket.assigns.current_scope, "category.created", %{
                name: trimmed,
                rule: rule
              })

              {:noreply, assign(socket, tournament: tournament, category_error: nil)}

            {:error, changeset} ->
              {:noreply, assign(socket, category_error: error_text(changeset))}
          end
      end
    else
      {:error, message} -> {:noreply, assign(socket, category_error: message)}
    end
  end

  def handle_event("remove_category", %{"name" => name}, socket) do
    categories = List.delete(socket.assigns.tournament.categories || [], name)
    category_rules = Map.delete(socket.assigns.tournament.category_rules, name)

    case Tournaments.update_tournament(socket.assigns.tournament, %{
           "categories" => categories,
           "category_rules" => category_rules
         }) do
      {:ok, tournament} ->
        Audit.log(tournament.id, socket.assigns.current_scope, "category.removed", %{name: name})
        {:noreply, assign(socket, tournament: tournament, category_error: nil, assign_note: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, category_error: error_text(reason))}
    end
  end

  # "Assign categories" - SWAR-style bulk rule application, same pattern as
  # the extra-points bands button: overwrites every player's category from
  # `tournament.category_rules`. Step 1 is a dry run: compute the same
  # decisions `auto_assign_categories/1` would make (via
  # `preview_auto_assign_categories/1`, so preview and apply can never
  # disagree) without writing anything, and show the arbiter a before/after
  # diff to confirm. Nothing is persisted until `apply_category_confirm`.
  def handle_event("assign_categories", _params, socket) do
    preview = Tournaments.preview_auto_assign_categories(socket.assigns.tournament)
    changes = Enum.filter(preview, fn %{from: from, to: to} -> from != to end)

    if changes == [] do
      {:noreply,
       assign(socket,
         category_confirm: nil,
         category_error: nil,
         assign_note: "No changes needed - every player already matches the rules."
       )}
    else
      {:noreply,
       assign(socket,
         category_confirm: %{changes: changes, total: length(preview)},
         category_error: nil,
         assign_note: nil
       )}
    end
  end

  def handle_event("cancel_category_confirm", _params, socket) do
    {:noreply, assign(socket, category_confirm: nil)}
  end

  # The explicit second click. Re-runs the real write path (not just the
  # staged preview) so the write always reflects the current DB state at
  # confirm time - same "read again at apply time" caution as
  # `PairingsLive`'s own `apply_confirm/2`.
  def handle_event("apply_category_confirm", _params, socket) do
    case Tournaments.auto_assign_categories(socket.assigns.tournament) do
      {:ok, %{matched: matched, total: total}} ->
        Audit.log(
          socket.assigns.tournament.id,
          socket.assigns.current_scope,
          "category.auto_assigned",
          %{matched: matched, total: total}
        )

        {:noreply,
         assign(socket,
           category_confirm: nil,
           assign_note: "Assigned #{matched} of #{total} players."
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           category_confirm: nil,
           assign_note: nil,
           category_error: error_text(reason)
         )}
    end
  end

  # No kind picked ("") means a plain hand-assigned category, same as
  # before threshold rules existed - `nil` rather than an error.
  defp parse_rule(%{"kind" => ""}), do: {:ok, nil}

  defp parse_rule(%{"kind" => kind, "value" => value})
       when kind in ~w(elo_below elo_above age_below age_above) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> {:ok, %{"kind" => kind, "value" => n}}
      _ -> {:error, "Enter a positive whole number for the threshold"}
    end
  end

  defp parse_rule(_params), do: {:ok, nil}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      tournament={@tournament}
      active="categories"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">Categories</p>
        </div>
      </div>

      <.settings_subnav tournament={@tournament} active={:categories} />

      <div class="card">
        <h2>Categories</h2>

        <p class="hint" style="margin-top: 0">
          {gettext(
            "Tournament-defined groups (SWAR CATEGORIES) - e.g. age or rating brackets - players can be assigned to. Off by default; turn on to start adding them below."
          )}
        </p>

        <div class="set-field solo">
          <span class="set-label">Status</span>
          <div class="actions" style="margin-top: 6px; align-items: center; gap: 10px">
            <span>{if @tournament.categories_enabled, do: "On", else: "Off"}</span>
            <button type="button" class="pe-btn" phx-click="toggle_categories_enabled">
              {if @tournament.categories_enabled, do: "Turn off", else: "Turn on"}
            </button>
          </div>
        </div>

        <div
          :if={@tournament.categories_enabled}
          class="set-field solo"
          style="margin-top: 10px"
        >
          <span class="set-label">{gettext("Pair each category independently (beta)")}</span>
          <p class="hint" style="margin: 2px 0 6px">
            {gettext(
              "Swiss only - each category gets its own independent pairings and byes within one combined round."
            )}
          </p>
          <div class="actions" style="align-items: center; gap: 10px">
            <span>{if @tournament.pair_by_category, do: "On", else: "Off"}</span>
            <button
              type="button"
              class="pe-btn"
              phx-click="toggle_pair_by_category"
              disabled={@pair_by_category_locked?}
            >
              {if @tournament.pair_by_category, do: "Turn off", else: "Turn on"}
            </button>
          </div>
          <p :if={@pair_by_category_locked?} class="hint" style="margin: 6px 0 0">
            {gettext("Locked - cannot be changed after round 1 has been paired.")}
          </p>
        </div>

        <p :if={@toggle_error} class="error-note" style="margin-top: 10px">{@toggle_error}</p>
      </div>

      <div :if={@tournament.categories_enabled}>
        <div class="card">
          <h2>{gettext("Category list")}</h2>
          <p class="hint" style="margin-top: 0">
            <.rich_text text={
              gettext(
                ~s(Players are assigned a category on the %{players} page. Give one a threshold instead of picking "None" and it can be filled in for every player automatically, below.)
              )
            }>
              <:part name="players">
                <.link navigate={~p"/t/#{@tournament.id}/players"}>{gettext("Players")}</.link>
              </:part>
            </.rich_text>
          </p>
          <form id="add-category-form" phx-submit="add_category">
            <.setting_group>
              <.setting_field label={gettext("New category name")}>
                <input type="text" name="name" value="" placeholder={gettext("e.g. -1100 or U18")} />
              </.setting_field>
              <.setting_field label="Rule">
                <select name="kind">
                  <option :for={{value, label} <- @rule_kinds} value={value}>{label}</option>
                </select>
              </.setting_field>
              <.setting_field label="Threshold" hint={gettext("Ignored when Rule is None")}>
                <input type="number" name="value" value="" min="1" placeholder="e.g. 1100" />
              </.setting_field>
            </.setting_group>
            <p :if={@category_error} class="error-note">{@category_error}</p>
            <div class="actions">
              <button type="submit" class="pe-btn primary">Add</button>
            </div>
          </form>

          <div :if={@tournament.categories != []} class="card-table-wrap" style="margin-top: 16px">
            <table class="pe-table">
              <thead>
                <tr>
                  <th>Category</th>
                  <th>Rule</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={c <- @tournament.categories}>
                  <td>{c}</td>
                  <td>{rule_description(Map.get(@tournament.category_rules, c))}</td>
                  <td style="text-align: right">
                    <button class="pe-btn danger-link" phx-click="remove_category" phx-value-name={c}>
                      Remove
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <p :if={@tournament.categories == []} class="hint" style="margin-bottom: 0">
            {gettext("No categories yet.")}
          </p>

          <div
            :if={@tournament.categories != [] and @tournament.category_rules != %{}}
            class="actions"
            style="margin-top: 16px"
          >
            <button type="button" class="pe-btn primary" phx-click="assign_categories">
              {gettext("Assign categories")}
            </button>
            <span :if={@assign_note} class="ok-note" style="align-self: center">{@assign_note}</span>
          </div>
          <p :if={@category_error} class="error-note" style="margin-top: 10px">
            {@category_error}
          </p>
        </div>
      </div>

      <div
        :if={@category_confirm}
        class="pe-modal"
        phx-window-keydown="cancel_category_confirm"
        phx-key="escape"
      >
        <div class="pe-modal-card pe-modal-wide" phx-click-away="cancel_category_confirm">
          <div class="pe-modal-head">
            <h2>{gettext("Assign categories?")}</h2>
            <p>
              {gettext(
                "Applying the threshold rules would move %{changed} of %{total} players to a different category. Players with no change are omitted below.",
                changed: length(@category_confirm.changes),
                total: @category_confirm.total
              )}
            </p>
          </div>
          <div class="pe-modal-body">
            <div class="card-table-wrap">
              <table class="pe-table">
                <thead>
                  <tr>
                    <th>Player</th>
                    <th>From</th>
                    <th>To</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={change <- @category_confirm.changes}>
                    <td>{change.player.name}</td>
                    <td>{empty_dash(change.from)}</td>
                    <td>{empty_dash(change.to)}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
          <div class="pe-modal-foot">
            <button type="button" class="pe-btn" phx-click="cancel_category_confirm">
              Cancel
            </button>
            <button
              type="button"
              class="pe-btn primary pe-modal-go"
              phx-click="apply_category_confirm"
            >
              {gettext("Assign categories")}
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp empty_dash(""), do: "-"
  defp empty_dash(value), do: value

  defp rule_description(nil), do: "-"
  defp rule_description(%{"kind" => "elo_below", "value" => v}), do: "below #{v} Elo"
  defp rule_description(%{"kind" => "elo_above", "value" => v}), do: "above #{v} Elo"
  defp rule_description(%{"kind" => "age_below", "value" => v}), do: "below age #{v}"
  defp rule_description(%{"kind" => "age_above", "value" => v}), do: "above age #{v}"
  defp rule_description(_rule), do: "-"
end
