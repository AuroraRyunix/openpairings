defmodule PairingsEngineWeb.CategoriesLive do
  use PairingsEngineWeb, :live_view

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
       category_error: nil,
       extra_points_error: nil,
       extra_points_note: nil
     )}
  end

  @impl true
  def handle_info({:tournament_changed, _tournament_id, _hint}, socket) do
    case Tournaments.get_authorized_tournament(socket.assigns.current_scope, socket.assigns.tournament.id) do
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
        case Tournaments.update_tournament(socket.assigns.tournament, %{"categories" => categories ++ [trimmed]}) do
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

  ## ---------- Extra points (SWAR parity #12 "XtPts") — any authorized user ----------

  def handle_event("save_extra_points", %{"tournament" => params}, socket) do
    params = Map.take(params, ["count_extra_points", "extra_points_bands"])

    base = socket.assigns.tournament

    case Tournaments.update_tournament(base, params) do
      {:ok, tournament} ->
        if base.count_extra_points != tournament.count_extra_points or
             base.extra_points_bands != tournament.extra_points_bands do
          Audit.log(
            tournament.id,
            socket.assigns.current_scope,
            "tournament.settings_updated",
            %{
              changed_fields:
                %{}
                |> maybe_change("count_extra_points", base.count_extra_points, tournament.count_extra_points)
                |> maybe_change("extra_points_bands", base.extra_points_bands, tournament.extra_points_bands)
            }
          )
        end

        {:noreply, assign(socket, tournament: tournament, extra_points_error: nil, extra_points_note: nil)}

      {:error, changeset} ->
        {:noreply, assign(socket, extra_points_error: error_text(changeset))}
    end
  end

  def handle_event("apply_extra_points_bands", _params, socket) do
    case Tournaments.apply_extra_points_bands(socket.assigns.tournament) do
      {:ok, %{matched: matched, total: total}} ->
        Audit.log(
          socket.assigns.tournament.id,
          socket.assigns.current_scope,
          "standings.extra_points_applied",
          %{matched: matched, total: total}
        )

        {:noreply,
         assign(socket,
           extra_points_note: "Set extra points for #{matched} of #{total} players.",
           extra_points_error: nil
         )}

      {:error, :invalid_bands} ->
        {:noreply,
         assign(socket,
           extra_points_error: "Fix the Elo bands field before applying it (e.g. \"1400:1, 1600:0.5\").",
           extra_points_note: nil
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, extra_points_error: error_text(changeset), extra_points_note: nil)}
    end
  end

  defp maybe_change(map, _key, same, same), do: map
  defp maybe_change(map, key, before, after_value), do: Map.put(map, key, [before, after_value])

  defp error_text(changeset) do
    Enum.map_join(changeset.errors, ", ", fn {field, {msg, _}} -> "#{field} #{msg}" end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} tournament={@tournament} active="categories">
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">Categories</p>
        </div>
      </div>

      <div :if={!@tournament.categories_enabled} class="card">
        <p class="hint" style="margin: 0">
          Categories are turned off for this tournament. Enable them in
          <.link navigate={~p"/t/#{@tournament.id}/settings"}>Settings</.link>
          first.
        </p>
      </div>

      <div :if={@tournament.categories_enabled}>
        <div class="card">
          <h2>Categories</h2>
          <p class="hint" style="margin-top: 0">
            Tournament-defined groups (SWAR CATEGORIES) — e.g. age or rating brackets — that players
            can be assigned to on the <.link navigate={~p"/t/#{@tournament.id}/players"}>Players</.link>
            page.
          </p>
          <form id="add-category-form" phx-submit="add_category">
            <div class="form-grid">
              <label class="field">
                <span>New category name</span>
                <input type="text" name="name" value="" placeholder="e.g. U18" />
              </label>
            </div>
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

        <div class="card">
          <h2>Extra points</h2>
          <p class="hint" style="margin-top: 0">
            Administrative bonus points (SWAR "XtPts") — e.g. a handicap head start for lower-rated
            players. Off by default: pairing (JaVaFo, TRF export) always uses game points only, and
            standings only add extra points to the ranking once you turn this on. See
            <.link navigate={~p"/t/#{@tournament.id}/players"}>Players</.link>
            to edit a single player's value, or auto-assign everyone from Elo bands below.
          </p>
          <form id="extra-points-form" phx-submit="save_extra_points">
            <div class="form-grid">
              <label class="field" style="display: flex; flex-direction: row; align-items: center; gap: .5rem">
                <input type="hidden" name="tournament[count_extra_points]" value="false" />
                <input
                  type="checkbox"
                  name="tournament[count_extra_points]"
                  value="true"
                  checked={@tournament.count_extra_points}
                />
                <span>Count extra points in standings</span>
              </label>
              <label class="field">
                <span>Elo bands (rating:bonus, comma-separated)</span>
                <input
                  type="text"
                  name="tournament[extra_points_bands]"
                  value={@tournament.extra_points_bands}
                  placeholder="e.g. 1400:1, 1600:0.5"
                />
                <span class="hint">
                  A player matches the lowest band whose threshold their rating is below (e.g.
                  "1400:1, 1600:0.5" gives 1.0 below 1400, 0.5 from 1400 up to 1599, nothing from
                  1600 up). Unrated players only match an explicit "0:bonus" band.
                </span>
              </label>
            </div>
            <p :if={@extra_points_error} class="error-note">{@extra_points_error}</p>
            <p :if={@extra_points_note} class="ok-note">{@extra_points_note}</p>
            <div class="actions">
              <button type="submit" class="pe-btn primary">Save extra points settings</button>
              <button type="button" class="pe-btn" phx-click="apply_extra_points_bands">
                Apply bands to players
              </button>
            </div>
          </form>
          <p class="hint" style="margin-bottom: 0">
            OpenPairings only supports extra points as an Elo-band bonus added to a player's
            standing, as configured above. SWAR's other use of extra points — "speed up pairings"
            (accelerating/seeding early-round pairings based on extra points) — is not supported.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
