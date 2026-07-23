defmodule PairingsEngineWeb.CategoriesLive do
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport

  alias PairingsEngine.{Audit, Tournaments}

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
       category_error: nil
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
  def handle_event("add_category", %{"name" => name}, socket) do
    trimmed = String.trim(name)
    categories = socket.assigns.tournament.categories || []

    cond do
      trimmed == "" ->
        {:noreply, assign(socket, category_error: "Enter a category name")}

      trimmed in categories ->
        {:noreply, assign(socket, category_error: "That category already exists")}

      true ->
        case Tournaments.update_tournament(socket.assigns.tournament, %{
               "categories" => categories ++ [trimmed]
             }) do
          {:ok, tournament} ->
            Audit.log(tournament.id, socket.assigns.current_scope, "category.created", %{
              name: trimmed
            })

            {:noreply, assign(socket, tournament: tournament, category_error: nil)}

          {:error, changeset} ->
            {:noreply, assign(socket, category_error: error_text(changeset))}
        end
    end
  end

  def handle_event("remove_category", %{"name" => name}, socket) do
    categories = List.delete(socket.assigns.tournament.categories || [], name)

    case Tournaments.update_tournament(socket.assigns.tournament, %{"categories" => categories}) do
      {:ok, tournament} ->
        Audit.log(tournament.id, socket.assigns.current_scope, "category.removed", %{name: name})
        {:noreply, assign(socket, tournament: tournament, category_error: nil)}

      {:error, _changeset} ->
        {:noreply, socket}
    end
  end

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
            page.
          </p>
          <form id="add-category-form" phx-submit="add_category">
            <.setting_field label="New category name" class="solo">
              <input type="text" name="name" value="" placeholder="e.g. U18" />
            </.setting_field>
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
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={c <- @tournament.categories}>
                  <td>{c}</td>
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
        </div>
      </div>
    </Layouts.app>
    """
  end
end
