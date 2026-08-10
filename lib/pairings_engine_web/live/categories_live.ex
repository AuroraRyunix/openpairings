defmodule PairingsEngineWeb.CategoriesLive do
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport

  alias PairingsEngine.{Audit, Tournaments}

  @rule_kinds [
    {"", "None — assign by hand"},
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
     assign(socket,
       tournament: tournament,
       page_title: "#{tournament.name} · Categories",
       category_error: nil,
       rule_kinds: @rule_kinds,
       assign_note: nil
     )}
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
        {:noreply, assign(socket, tournament: tournament)}
    end
  end

  ## ---------- Categories (SWAR CATEGORIES) — any authorized user ----------

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

      {:error, _changeset} ->
        {:noreply, socket}
    end
  end

  # "Assign categories" — SWAR-style bulk rule application, same pattern as
  # the extra-points bands button: overwrites every player's category from
  # `tournament.category_rules`, right then, not kept in sync afterward.
  def handle_event("assign_categories", _params, socket) do
    case Tournaments.auto_assign_categories(socket.assigns.tournament) do
      {:ok, %{matched: matched, total: total}} ->
        Audit.log(
          socket.assigns.tournament.id,
          socket.assigns.current_scope,
          "category.auto_assigned",
          %{matched: matched, total: total}
        )

        {:noreply, assign(socket, assign_note: "Assigned #{matched} of #{total} players.")}

      {:error, _reason} ->
        {:noreply,
         assign(socket, assign_note: nil, category_error: "Could not assign categories")}
    end
  end

  # No kind picked ("") means a plain hand-assigned category, same as
  # before threshold rules existed — `nil` rather than an error.
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

      <div :if={!@tournament.categories_enabled} class="card">
        <p class="hint" style="margin: 0">
          Categories are turned off for this tournament. Enable them on the
          <.link navigate={~p"/t/#{@tournament.id}/settings/options"}>Options</.link>
          settings page first.
        </p>
      </div>

      <div :if={@tournament.categories_enabled}>
        <div class="card">
          <h2>Categories</h2>
          <p class="hint" style="margin-top: 0">
            Tournament-defined groups (SWAR CATEGORIES) - e.g. age or rating brackets - that players
            can be assigned to on the
            <.link navigate={~p"/t/#{@tournament.id}/players"}>Players</.link>
            page. Give one a threshold instead of picking "None" and it can be filled in for
            every player automatically, below.
          </p>
          <form id="add-category-form" phx-submit="add_category">
            <.setting_group>
              <.setting_field label="New category name">
                <input type="text" name="name" value="" placeholder="e.g. -1100 or U18" />
              </.setting_field>
              <.setting_field label="Rule">
                <select name="kind">
                  <option :for={{value, label} <- @rule_kinds} value={value}>{label}</option>
                </select>
              </.setting_field>
              <.setting_field label="Threshold" hint="Ignored when Rule is None">
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
            No categories yet.
          </p>

          <div
            :if={@tournament.categories != [] and @tournament.category_rules != %{}}
            class="actions"
            style="margin-top: 16px"
          >
            <button
              type="button"
              class="pe-btn primary"
              phx-click="assign_categories"
              data-confirm="Set every player's category from the threshold rules above? This overwrites any category currently set by hand."
            >
              Assign categories
            </button>
            <span :if={@assign_note} class="ok-note" style="align-self: center">{@assign_note}</span>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp rule_description(nil), do: "—"
  defp rule_description(%{"kind" => "elo_below", "value" => v}), do: "below #{v} Elo"
  defp rule_description(%{"kind" => "elo_above", "value" => v}), do: "above #{v} Elo"
  defp rule_description(%{"kind" => "age_below", "value" => v}), do: "below age #{v}"
  defp rule_description(%{"kind" => "age_above", "value" => v}), do: "above age #{v}"
  defp rule_description(_rule), do: "—"
end
