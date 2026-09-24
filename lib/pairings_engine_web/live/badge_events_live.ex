defmodule PairingsEngineWeb.BadgeEventsLive do
  @moduledoc """
  `/badges` - the signed-in user's badge events, and the form that starts a
  new one, optionally linked to one of their tournaments. See docs/badges.md.
  `/badges?new=1&tournament_id=ID` (where a tournament's "Badges" menu entry
  lands when it has no event yet) opens with that tournament picked.
  """
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.Badges
  alias PairingsEngine.Badges.Event

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    events = Badges.list_events(scope)

    {:ok,
     socket
     |> assign(:page_title, gettext("Accreditation badges"))
     |> assign(:tournaments, Badges.linkable_tournaments(scope))
     |> assign(:events_empty?, events == [])
     |> stream(:events, events)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tournament_id = params["tournament_id"]
    name = tournament_name(socket.assigns.tournaments, tournament_id)

    form =
      %Event{}
      |> Badges.change_event(%{"name" => name || ""})
      |> Map.put(:action, nil)
      |> to_form()

    {:noreply,
     socket
     |> assign(:form, form)
     |> assign(:tournament_id, if(name, do: tournament_id, else: ""))
     |> assign(:show_form?, params["new"] == "1" or socket.assigns.events_empty?)}
  end

  defp tournament_name(tournaments, id) do
    Enum.find_value(tournaments, fn t -> if to_string(t.id) == to_string(id), do: t.name end)
  end

  @impl true
  def handle_event("toggle_form", _params, socket) do
    {:noreply, assign(socket, :show_form?, !socket.assigns.show_form?)}
  end

  def handle_event("validate", %{"event" => params}, socket) do
    form =
      %Event{}
      |> Badges.change_event(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply,
     socket |> assign(:form, form) |> assign(:tournament_id, params["tournament_id"] || "")}
  end

  def handle_event("create", %{"event" => params}, socket) do
    case Badges.create_event(socket.assigns.current_scope, params) do
      {:ok, event} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Badge event created."))
         |> push_navigate(to: ~p"/badges/#{event.id}")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("You cannot link to that tournament."))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(Map.put(changeset, :action, :insert)))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      update_notice={assigns[:update_notice]}
      flash={@flash}
      current_path={assigns[:current_path]}
      current_scope={@current_scope}
      active="tools"
    >
      <div class="page-header">
        <div>
          <h1>{gettext("Accreditation badges")}</h1>
          <p class="subtitle" style="margin: 0">
            {gettext(
              "A6 badges for players, officials, press and guests, printed two to an A4 sheet."
            )}
          </p>
        </div>
        <button
          :if={!@show_form?}
          id="new-badge-event-button"
          type="button"
          class="pe-btn primary"
          phx-click="toggle_form"
        >
          <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New badge event")}
        </button>
      </div>

      <section :if={@show_form?} class="card mb-6" aria-labelledby="new-badge-event-heading">
        <h2 id="new-badge-event-heading">{gettext("New badge event")}</h2>
        <.form
          for={@form}
          id="badge-event-form"
          phx-change="validate"
          phx-submit="create"
          class="grid gap-4 md:grid-cols-2"
        >
          <.input field={@form[:name]} type="text" label={gettext("Event name")} required />
          <.input
            name="event[tournament_id]"
            id="badge-event-tournament"
            type="select"
            label={gettext("Import from tournament (optional)")}
            value={@tournament_id}
            prompt={gettext("No tournament - a stand-alone event")}
            options={Enum.map(@tournaments, &{&1.name, &1.id})}
          />
          <p class="hint md:col-span-2">
            {gettext(
              "A linked event can import the tournament's players and officials; press, VIP and staff badges are added by hand either way."
            )}
          </p>
          <div class="flex gap-2 md:col-span-2">
            <button type="submit" id="create-badge-event" class="pe-btn primary">
              {gettext("Create event")}
            </button>
            <button
              :if={!@events_empty?}
              type="button"
              class="pe-btn"
              phx-click="toggle_form"
            >
              {gettext("Cancel")}
            </button>
          </div>
        </.form>
      </section>

      <div class="card table-card">
        <table class="pe-table">
          <thead>
            <tr>
              <th>{gettext("Event")}</th>
              <th>{gettext("Tournament")}</th>
              <th class="num">{gettext("Badges")}</th>
              <th><span class="sr-only">{gettext("Actions")}</span></th>
            </tr>
          </thead>
          <tbody id="badge-events" phx-update="stream">
            <tr id="badge-events-empty" class="hidden only:table-row">
              <td colspan="4" class="hint">{gettext("No badge events yet.")}</td>
            </tr>
            <tr :for={{dom_id, event} <- @streams.events} id={dom_id}>
              <td>
                <.link navigate={~p"/badges/#{event.id}"} class="font-semibold">{event.name}</.link>
                <div :if={event.city not in [nil, ""] or event.year not in [nil, ""]} class="hint">
                  {[event.city, event.year] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")}
                </div>
              </td>
              <td>
                <span :if={event.tournament}>{event.tournament.name}</span>
                <span :if={!event.tournament} class="hint">{gettext("Stand-alone")}</span>
              </td>
              <td class="num">{event.badge_count}</td>
              <td style="text-align: right">
                <.link navigate={~p"/badges/#{event.id}"} class="pe-btn">{gettext("Open")}</.link>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end
end
