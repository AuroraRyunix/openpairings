defmodule PairingsEngineWeb.SettingsGroupLive do
  @moduledoc """
  The "Group" settings page (`/t/:id/settings/group`): several tournaments of
  one event - the Open, a youth section, a rapid on the side - put in a group
  (`PairingsEngine.TournamentGroups`), so the layout can offer a switcher and
  the results site can show them as one event.

  It used to be a card at the bottom of the Tournament page, where most
  tournaments never need it and everyone scrolled past it.
  """
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport

  alias PairingsEngine.{TournamentGroups, Tournaments}
  alias PairingsEngine.TournamentGroups.{Group, Member}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     socket
     |> assign(tournament: tournament, page_title: "#{tournament.name} · Settings · Group")
     |> assign_group(nil)}
  end

  # The Group card's state, and the switcher in the layout with it - this
  # page hands the layout its own copy so a change shows at the top at once.
  defp assign_group(socket, error) do
    %{current_scope: scope, tournament: tournament} = socket.assigns
    switcher = TournamentGroups.switcher(scope, tournament)
    current = switcher && Enum.find(switcher.members, & &1.current?)

    assign(socket,
      group_switcher: switcher,
      group_event_url: switcher && PairingsEngineWeb.PublicLink.event_url(tournament),
      group_error: error,
      joinable_groups:
        if(switcher, do: [], else: TournamentGroups.joinable_groups(scope, tournament)),
      group_create_form: to_form(%{"name" => ""}, as: :group),
      group_join_form: to_form(%{"group_id" => ""}, as: :join),
      group_rename_form: to_form(%{"name" => switcher && switcher.group.name}, as: :group_rename),
      group_label_form: to_form(%{"label" => current && current.own_label}, as: :member)
    )
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
         |> put_flash(:error, gettext("This tournament was deleted."))
         |> push_navigate(to: ~p"/")}

      tournament ->
        {:noreply,
         socket |> assign(tournament: tournament) |> assign_group(socket.assigns.group_error)}
    end
  end

  @impl true
  def handle_event("group_create", %{"group" => %{"name" => name}}, socket) do
    socket.assigns.current_scope
    |> TournamentGroups.create_group(socket.assigns.tournament, name)
    |> group_result(socket, gettext("Group created."))
  end

  def handle_event("group_join", %{"join" => %{"group_id" => group_id}}, socket) do
    socket.assigns.current_scope
    |> TournamentGroups.join_group(socket.assigns.tournament, group_id)
    |> group_result(socket, gettext("Added to the group."))
  end

  def handle_event("group_rename", %{"group_rename" => %{"name" => name}}, socket) do
    socket.assigns.current_scope
    |> TournamentGroups.rename_group(socket.assigns.tournament, name)
    |> group_result(socket, gettext("Group renamed."))
  end

  def handle_event("group_label", %{"member" => %{"label" => label}}, socket) do
    socket.assigns.current_scope
    |> TournamentGroups.set_label(socket.assigns.tournament, label)
    |> group_result(socket, gettext("Label saved."))
  end

  def handle_event("group_move", %{"id" => id, "dir" => dir}, socket)
      when dir in ["up", "down"] do
    case Integer.parse(id) do
      {member_id, ""} ->
        direction = if dir == "up", do: :up, else: :down

        socket.assigns.current_scope
        |> TournamentGroups.move(socket.assigns.tournament, member_id, direction)
        |> group_result(socket, nil)

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("group_leave", _params, socket) do
    socket.assigns.current_scope
    |> TournamentGroups.leave_group(socket.assigns.tournament)
    |> group_result(socket, gettext("Taken out of the group."))
  end

  # "Spring Open 2026 (Open, U20)": the group by its name and the members
  # this user can see, so two groups with the same name can be told apart.
  defp joinable_options(groups) do
    Enum.map(groups, fn %{group: g, labels: labels} ->
      {"#{g.name} (#{Enum.join(labels, ", ")})", g.id}
    end)
  end

  defp group_result({:ok, _}, socket, nil), do: {:noreply, assign_group(socket, nil)}

  defp group_result({:ok, _}, socket, message),
    do: {:noreply, socket |> assign_group(nil) |> put_flash(:info, message)}

  defp group_result({:error, reason}, socket, _message),
    do: {:noreply, assign_group(socket, group_error_text(reason))}

  defp group_error_text(:already_grouped),
    do: gettext("This tournament is already in a group. Take it out of that one first.")

  defp group_error_text(:not_grouped), do: gettext("This tournament is not in a group.")

  defp group_error_text(:not_found),
    do: gettext("That group is not one you can add this tournament to.")

  defp group_error_text(:not_authorized),
    do: gettext("You are not allowed to change this tournament.")

  defp group_error_text(%Ecto.Changeset{data: %Group{}}),
    do: gettext("Give the group a name of at most %{count} characters.", count: Group.max_name())

  defp group_error_text(%Ecto.Changeset{data: %Member{}}),
    do: gettext("A label can be at most %{count} characters.", count: Member.max_label())

  defp group_error_text(reason) when reason in [:archived, :handed_off], do: error_text(reason)
  defp group_error_text(_), do: gettext("That did not work. Reload the page and try again.")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      update_notice={assigns[:update_notice]}
      fide_notice={assigns[:fide_notice]}
      flash={@flash}
      current_path={assigns[:current_path]}
      current_scope={@current_scope}
      tournament={@tournament}
      group_switcher={@group_switcher}
      active="settings"
    >
      <.settings_page
        tournament={@tournament}
        current_scope={@current_scope}
        active={:group}
        subtitle={gettext("Settings - Group")}
      >
        <%!-- Tournament groups (`PairingsEngine.TournamentGroups`). The list
            shows only the members this user can open - the switcher's rule,
            for the switcher's reason. --%>
        <div class="card" id="group-card">
          <h2>{gettext("Group")}</h2>

          <p class="hint" style="margin-top: 0">
            {gettext(
              "Several tournaments of one event - the Open, a youth section, a rapid on the side - can be put in a group. Each keeps its own players, rounds and pairings; the group adds a switcher at the top of every page that opens the same page of another one."
            )}
          </p>

          <p :if={@group_error} id="group-error" class="error-note" role="alert">{@group_error}</p>

          <%= if @group_switcher do %>
            <.form
              for={@group_rename_form}
              id="group-rename-form"
              phx-submit="group_rename"
              class="group-inline-form"
            >
              <.input
                field={@group_rename_form[:name]}
                type="text"
                label={gettext("Group name")}
                maxlength={Group.max_name()}
                required
              /> <button type="submit" class="pe-btn">{gettext("Rename")}</button>
            </.form>

            <.form
              for={@group_label_form}
              id="group-label-form"
              phx-submit="group_label"
              class="group-inline-form"
            >
              <.input
                field={@group_label_form[:label]}
                type="text"
                label={gettext("This tournament's label in the switcher")}
                placeholder={@tournament.name}
                maxlength={Member.max_label()}
              /> <button type="submit" class="pe-btn">{gettext("Save label")}</button>
            </.form>

            <p class="hint" style="margin-top: 0">
              {gettext("Leave the label empty to show the tournament's own name.")}
            </p>

            <%!-- What the group means off this machine. The link exists only
                when this tournament's published page really is shown as part
                of the event - see `TournamentGroups.published_block/1`. --%>
            <p class="hint" id="group-published" style="margin-top: 0">
              {gettext(
                "On the results site, the published tournaments of a group are one event: tabs at the top of each to switch between them, and an event page that lists them. Only tournaments that are published are named there, and one that is not listed on the front page is named only on the others that are not listed either. The group's name is shown as the event's name."
              )}
              <a
                :if={@group_event_url}
                id="group-event-link"
                href={@group_event_url}
                target="_blank"
                rel="noopener"
              >
                {gettext("Open the event page")}
              </a>
            </p>

            <ol class="tb-list" id="group-order">
              <li
                :for={{m, i} <- Enum.with_index(@group_switcher.members)}
                id={"group-member-#{m.id}"}
              >
                <span class="tb-order">{i + 1}.</span>
                <div>
                  <div class="tb-name">
                    {m.label}
                    <span :if={m.current?} class="badge muted">{gettext("this tournament")}</span>
                  </div>

                  <div :if={m.label != m.name} class="tb-desc">{m.name}</div>
                </div>

                <div class="tb-buttons">
                  <button
                    type="button"
                    class="pe-btn"
                    id={"group-up-#{m.id}"}
                    title={gettext("Move up")}
                    aria-label={gettext("Move %{tournament} up", tournament: m.label)}
                    disabled={i == 0}
                    phx-click="group_move"
                    phx-value-id={m.id}
                    phx-value-dir="up"
                  >
                    ↑
                  </button>

                  <button
                    type="button"
                    class="pe-btn"
                    id={"group-down-#{m.id}"}
                    title={gettext("Move down")}
                    aria-label={gettext("Move %{tournament} down", tournament: m.label)}
                    disabled={i == length(@group_switcher.members) - 1}
                    phx-click="group_move"
                    phx-value-id={m.id}
                    phx-value-dir="down"
                  >
                    ↓
                  </button>
                </div>
              </li>
            </ol>

            <div class="actions">
              <button
                type="button"
                id="group-leave"
                class="pe-btn danger-link"
                phx-click="group_leave"
                data-confirm={
                  gettext(
                    "Take this tournament out of the group %{name}? Nothing in the tournament itself changes. A group left empty is removed.",
                    name: @group_switcher.group.name
                  )
                }
              >
                {gettext("Take out of the group")}
              </button>
            </div>
          <% else %>
            <.form
              for={@group_create_form}
              id="group-create-form"
              phx-submit="group_create"
              class="group-inline-form"
            >
              <.input
                field={@group_create_form[:name]}
                type="text"
                label={gettext("New group")}
                placeholder={gettext("e.g. Spring Open 2026")}
                maxlength={Group.max_name()}
                required
              /> <button type="submit" class="pe-btn primary">{gettext("Create group")}</button>
            </.form>

            <.form
              :if={@joinable_groups != []}
              for={@group_join_form}
              id="group-join-form"
              phx-submit="group_join"
              class="group-inline-form"
            >
              <.input
                field={@group_join_form[:group_id]}
                type="select"
                label={gettext("Or add it to an existing group")}
                options={joinable_options(@joinable_groups)}
              /> <button type="submit" class="pe-btn">{gettext("Add to group")}</button>
            </.form>
          <% end %>
        </div>
      </.settings_page>
    </Layouts.app>
    """
  end
end
