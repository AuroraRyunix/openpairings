defmodule PairingsEngineWeb.BadgeStudioLive do
  @moduledoc """
  One badge event's studio (docs/badges.md), in three views:

    * `/badges/:id` (`:index`) - the badge list, with the import buttons
      when the event is linked to a tournament.
    * `/badges/:id/badge/:badge_id` (`:edit`) - the editor: the badge's
      fields, role and room presets, photo upload and "Fetch from FIDE", with
      a live preview of both sides (side by side or as a card to flip, zoomable).
    * `/badges/:id/settings` (`:settings`) - what the whole event prints:
      header, conditions, rooms, role names and colours, logos, and the
      tournament link.

  Printing is a separate page (`PairingsEngineWeb.BadgeController.print/2`)
  opened in a new tab, so the print dialog sees nothing but the sheets.

  Rebuilt on `PairingsEngine.Badges` from the stand-alone badge maker's
  `BadgeLive`; see docs/badges.md for what was kept and what was cut.
  """
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.BadgeCard

  alias PairingsEngine.Badges
  alias PairingsEngine.Badges.{Badge, Defaults, Event, Image}
  alias PairingsEngine.Tournaments
  alias PairingsEngineWeb.BadgeController

  @image_accept ~w(.png .jpg .jpeg .gif .webp)
  @zooms [60, 80, 100, 115, 125]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    event = Badges.get_event!(scope, id)
    photo_limit = Image.limits(:photo).bytes
    logo_limit = Image.limits(:logo).bytes

    socket =
      socket
      |> assign_event(event)
      |> assign(:zoom, 100)
      |> assign(:preview, "sides")
      |> assign(:flipped?, false)
      |> assign(:fetching?, false)
      |> assign(:badge, nil)
      |> allow_upload(:photo,
        accept: @image_accept,
        max_entries: 1,
        max_file_size: photo_limit,
        auto_upload: true,
        progress: &handle_progress/3
      )

    socket =
      Enum.reduce(Event.logo_slots(), socket, fn slot, acc ->
        allow_upload(acc, slot,
          accept: @image_accept,
          max_entries: 1,
          max_file_size: logo_limit,
          auto_upload: true,
          progress: &handle_progress/3
        )
      end)

    {:ok, socket}
  end

  defp assign_event(socket, %Event{} = event) do
    scope = socket.assigns.current_scope

    # The link is shown only while the user can still open the tournament;
    # access can be withdrawn by its owner after the event was linked.
    linked =
      if event.tournament_id,
        do: Tournaments.get_authorized_tournament(scope, event.tournament_id)

    socket
    |> assign(:event, event)
    |> assign(:linked, linked)
    |> assign(:qr_svg, Badges.qr_svg(event))
    |> assign(:urls, BadgeController.image_urls(event))
    |> assign(:badge_count, Badges.count_badges(event))
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    badges = Badges.list_badges(socket.assigns.current_scope, socket.assigns.event)

    socket
    |> assign(:page_title, "#{socket.assigns.event.name} · #{gettext("Badges")}")
    |> assign(:badge, nil)
    |> stream(:badges, badges, reset: true)
  end

  defp apply_action(socket, :edit, %{"badge_id" => badge_id}) do
    scope = socket.assigns.current_scope
    event = socket.assigns.event
    badge = Badges.get_badge!(scope, event, badge_id)
    ids = scope |> Badges.list_badges(event) |> Enum.map(& &1.id)
    index = Enum.find_index(ids, &(&1 == badge.id)) || 0

    socket
    |> assign(:page_title, "#{Badge.display_name(badge)} · #{gettext("Badges")}")
    |> assign(:prev_id, if(index > 0, do: Enum.at(ids, index - 1)))
    |> assign(:next_id, Enum.at(ids, index + 1))
    |> assign(:position, {index + 1, length(ids)})
    |> assign_badge(badge)
  end

  defp apply_action(socket, :settings, _params) do
    scope = socket.assigns.current_scope
    event = socket.assigns.event

    socket
    |> assign(:page_title, "#{event.name} · #{gettext("Event settings")}")
    |> assign(:badge, nil)
    |> assign(:sample, List.first(Badges.list_badges(scope, event)))
    |> assign(:tournaments, Badges.linkable_tournaments(socket.assigns.current_scope))
    |> assign_event_form(
      Badges.change_event(socket.assigns.event),
      event_params(socket.assigns.event)
    )
  end

  defp assign_badge(socket, %Badge{} = badge) do
    socket
    |> assign(:badge, badge)
    |> assign(:badge_form, to_form(Badges.change_badge(badge)))
  end

  defp assign_event_form(socket, changeset, params) do
    socket
    |> assign(:event_params, params)
    |> assign(:event_form, to_form(changeset))
    |> assign(:preview_event, Ecto.Changeset.apply_changes(changeset))
  end

  # The settings form's own view of the event, so adding or removing a role
  # row can rebuild the form from what is typed without losing any of it.
  defp event_params(%Event{} = event) do
    %{
      "roles" =>
        event.roles
        |> Enum.with_index()
        |> Map.new(fn {role, i} -> {Integer.to_string(i), role} end)
    }
  end

  ## ---------- Badge list ----------

  @impl true
  def handle_event("add_badge", _params, socket) do
    case Badges.create_badge(socket.assigns.current_scope, socket.assigns.event, %{
           "first_name" => "",
           "last_name" => ""
         }) do
      {:ok, badge} ->
        {:noreply,
         push_patch(socket, to: ~p"/badges/#{socket.assigns.event.id}/badge/#{badge.id}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not add a badge."))}
    end
  end

  def handle_event("import_players", _params, socket) do
    socket.assigns.current_scope
    |> Badges.import_players(socket.assigns.event)
    |> import_result(socket, gettext("Players"))
  end

  def handle_event("import_officials", _params, socket) do
    socket.assigns.current_scope
    |> Badges.import_officials(socket.assigns.event)
    |> import_result(socket, gettext("Officials"))
  end

  def handle_event("duplicate_badge", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with %Badge{} = badge <- Badges.get_badge(scope, socket.assigns.event, id),
         {:ok, copy} <- Badges.duplicate_badge(scope, badge) do
      {:noreply,
       socket
       |> refresh_count()
       |> put_flash(:info, gettext("Badge duplicated."))
       |> maybe_stream_insert(Badges.get_badge!(scope, socket.assigns.event, copy.id))}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not duplicate that badge."))}
    end
  end

  def handle_event("delete_badge", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with %Badge{} = badge <- Badges.get_badge(scope, socket.assigns.event, id),
         {:ok, _} <- Badges.delete_badge(scope, badge) do
      socket = socket |> refresh_count() |> put_flash(:info, gettext("Badge deleted."))

      if socket.assigns.live_action == :index do
        {:noreply, stream_delete(socket, :badges, badge)}
      else
        {:noreply, push_patch(socket, to: ~p"/badges/#{socket.assigns.event.id}")}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not delete that badge."))}
    end
  end

  ## ---------- Badge editor ----------

  def handle_event("save_badge", %{"badge" => params}, socket) do
    case Badges.update_badge(socket.assigns.current_scope, socket.assigns.badge, params) do
      {:ok, badge} ->
        {:noreply, assign_badge(socket, badge)}

      {:error, changeset} ->
        {:noreply, assign(socket, :badge_form, to_form(Map.put(changeset, :action, :update)))}
    end
  end

  def handle_event("set_role", %{"key" => key}, socket) do
    %{current_scope: scope, event: event, badge: badge} = socket.assigns

    case Badges.set_role(scope, event, badge, key) do
      {:ok, badge} -> {:noreply, assign_badge(socket, badge)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("toggle_room", %{"room" => room}, socket) do
    %{current_scope: scope, event: event, badge: badge} = socket.assigns

    case Integer.parse(room) do
      {num, ""} ->
        {:ok, badge} = Badges.toggle_room(scope, event, badge, num)
        {:noreply, assign_badge(socket, badge)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("room_preset", %{"preset" => preset}, socket) do
    %{current_scope: scope, event: event, badge: badge} = socket.assigns
    count = event.room_count

    rooms =
      case preset do
        "all" -> Enum.to_list(1..count)
        "first_half" -> Enum.to_list(1..ceil(count / 2))
        _ -> []
      end

    {:ok, badge} = Badges.set_room_access(scope, event, badge, rooms)
    {:noreply, assign_badge(socket, badge)}
  end

  def handle_event("clear_photo", _params, socket) do
    {:ok, badge} = Badges.clear_photo(socket.assigns.current_scope, socket.assigns.badge)
    {:noreply, assign_badge(socket, badge)}
  end

  def handle_event("revert_badge", _params, socket) do
    case Badges.revert_to_source(socket.assigns.current_scope, socket.assigns.badge) do
      {:ok, badge} ->
        {:noreply,
         socket
         |> assign_badge(
           Badges.get_badge!(socket.assigns.current_scope, socket.assigns.event, badge.id)
         )
         |> put_flash(:info, gettext("The badge shows the tournament's data again."))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, import_error(reason))}
    end
  end

  def handle_event("fetch_fide", _params, %{assigns: %{fetching?: true}} = socket),
    do: {:noreply, socket}

  def handle_event("fetch_fide", _params, socket) do
    scope = socket.assigns.current_scope

    case Badges.claim_fide_fetch(scope, socket.assigns.badge) do
      {:ok, badge} ->
        {:noreply,
         socket
         |> assign(:fetching?, true)
         |> assign(:badge, badge)
         |> start_async(:fide_photo, fn -> Badges.fetch_fide_photo(scope, badge) end)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, fide_error(reason))}
    end
  end

  def handle_event("preview", %{"mode" => mode}, socket) when mode in ["sides", "flip"],
    do: {:noreply, assign(socket, preview: mode, flipped?: false)}

  def handle_event("flip", _params, socket),
    do: {:noreply, assign(socket, :flipped?, !socket.assigns.flipped?)}

  def handle_event("zoom", %{"zoom" => zoom}, socket) do
    zoom =
      case Integer.parse(zoom) do
        {z, ""} when z in @zooms -> z
        _ -> socket.assigns.zoom
      end

    {:noreply, assign(socket, :zoom, zoom)}
  end

  ## ---------- Event settings ----------

  def handle_event("validate_event", %{"event" => params}, socket) do
    changeset =
      socket.assigns.event
      |> Badges.change_event(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_event_form(socket, changeset, params)}
  end

  def handle_event("save_event", %{"event" => params}, socket) do
    case Badges.update_event(socket.assigns.current_scope, socket.assigns.event, params) do
      {:ok, event} ->
        {:noreply,
         socket
         |> assign_event(event)
         |> assign_event_form(Badges.change_event(event), event_params(event))
         |> put_flash(:info, gettext("Event settings saved."))}

      {:error, changeset} ->
        {:noreply, assign_event_form(socket, Map.put(changeset, :action, :update), params)}
    end
  end

  def handle_event("add_role", _params, socket) do
    params = socket.assigns.event_params
    roles = Map.get(params, "roles", %{})
    next = roles |> map_size() |> Integer.to_string()

    role = %{
      "key" => "custom_#{System.unique_integer([:positive])}",
      "label" => gettext("NEW ROLE"),
      "color" => "#374151"
    }

    params = Map.put(params, "roles", Map.put(roles, next, role))
    changeset = Badges.change_event(socket.assigns.event, params)
    {:noreply, assign_event_form(socket, changeset, params)}
  end

  def handle_event("remove_role", %{"key" => key}, socket) do
    if key in Defaults.import_role_keys() do
      {:noreply, socket}
    else
      params = socket.assigns.event_params

      roles =
        params
        |> Map.get("roles", %{})
        |> Enum.reject(fn {_i, role} -> role["key"] == key end)
        |> Enum.sort_by(fn {i, _} -> String.to_integer(i) end)
        |> Enum.with_index()
        |> Map.new(fn {{_i, role}, n} -> {Integer.to_string(n), role} end)

      params = Map.put(params, "roles", roles)
      changeset = Badges.change_event(socket.assigns.event, params)
      {:noreply, assign_event_form(socket, changeset, params)}
    end
  end

  def handle_event("reset_conditions", _params, socket) do
    {:ok, event} = Badges.reset_conditions(socket.assigns.current_scope, socket.assigns.event)

    {:noreply,
     socket
     |> assign_event(event)
     |> assign_event_form(Badges.change_event(event), event_params(event))
     |> put_flash(:info, gettext("The usage conditions are back to the default text."))}
  end

  def handle_event("link_tournament", %{"link" => %{"tournament_id" => id}}, socket) do
    case Badges.link_tournament(socket.assigns.current_scope, socket.assigns.event, id) do
      {:ok, event} ->
        message =
          if event.tournament_id,
            do: gettext("Linked to %{name}.", name: event.tournament.name),
            else: gettext("The event is no longer linked to a tournament.")

        {:noreply, socket |> assign_event(event) |> put_flash(:info, message)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("You cannot link to that tournament."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not change the link."))}
    end
  end

  def handle_event("clear_logo", %{"slot" => slot}, socket)
      when slot in ~w(emblem logo_left logo_right) do
    {:ok, _} =
      Badges.clear_logo(
        socket.assigns.current_scope,
        socket.assigns.event,
        String.to_existing_atom(slot)
      )

    {:noreply, reload_event(socket)}
  end

  def handle_event("delete_event", _params, socket) do
    {:ok, _} = Badges.delete_event(socket.assigns.current_scope, socket.assigns.event)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Badge event deleted."))
     |> push_navigate(to: ~p"/badges")}
  end

  # Uploads save on arrival (auto_upload), so there is nothing to validate
  # here beyond what `allow_upload/3` already enforces; errors render inline.
  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  ## ---------- Uploads and async ----------

  defp handle_progress(:photo, entry, socket) do
    if entry.done? do
      scope = socket.assigns.current_scope
      badge = socket.assigns.badge

      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, Badges.set_photo(scope, badge, File.read!(path), "upload")}
        end)

      case result do
        {:ok, badge} ->
          {:noreply, socket |> assign_badge(badge) |> put_flash(:info, gettext("Photo saved."))}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, image_error(reason, :photo))}
      end
    else
      {:noreply, socket}
    end
  end

  defp handle_progress(slot, entry, socket) when slot in [:emblem, :logo_left, :logo_right] do
    if entry.done? do
      scope = socket.assigns.current_scope
      event = socket.assigns.event

      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, Badges.set_logo(scope, event, slot, File.read!(path))}
        end)

      case result do
        {:ok, _event} ->
          {:noreply, socket |> reload_event() |> put_flash(:info, gettext("Logo saved."))}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, image_error(reason, :logo))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async(:fide_photo, {:ok, {:ok, badge}}, socket) do
    socket = assign(socket, :fetching?, false)

    if socket.assigns.badge && socket.assigns.badge.id == badge.id do
      {:noreply,
       socket
       |> assign_badge(
         Badges.get_badge!(socket.assigns.current_scope, socket.assigns.event, badge.id)
       )
       |> put_flash(:info, gettext("Photo fetched from FIDE and saved on the badge."))}
    else
      {:noreply,
       put_flash(socket, :info, gettext("Photo fetched from FIDE and saved on the badge."))}
    end
  end

  def handle_async(:fide_photo, {:ok, {:error, reason}}, socket) do
    {:noreply, socket |> assign(:fetching?, false) |> put_flash(:error, fide_error(reason))}
  end

  def handle_async(:fide_photo, {:exit, _reason}, socket) do
    {:noreply, socket |> assign(:fetching?, false) |> put_flash(:error, fide_error(:unreachable))}
  end

  defp reload_event(socket) do
    event = Badges.get_event!(socket.assigns.current_scope, socket.assigns.event.id)
    socket = assign_event(socket, event)

    if socket.assigns.live_action == :settings do
      assign(socket, :preview_event, event)
    else
      socket
    end
  end

  defp refresh_count(socket),
    do: assign(socket, :badge_count, Badges.count_badges(socket.assigns.event))

  defp maybe_stream_insert(socket, badge) do
    if socket.assigns.live_action == :index,
      do: stream_insert(socket, :badges, badge),
      else: socket
  end

  defp import_result({:ok, counts}, socket, what) do
    socket =
      socket
      |> refresh_count()
      |> put_flash(
        :info,
        gettext("%{what}: %{created} new, %{updated} updated, %{unchanged} unchanged.",
          what: what,
          created: counts.created,
          updated: counts.updated,
          unchanged: counts.unchanged
        )
      )

    if socket.assigns.live_action == :index do
      badges = Badges.list_badges(socket.assigns.current_scope, socket.assigns.event)
      {:noreply, stream(socket, :badges, badges, reset: true)}
    else
      {:noreply, socket}
    end
  end

  defp import_result({:error, reason}, socket, _what),
    do: {:noreply, put_flash(socket, :error, import_error(reason))}

  defp import_error(:no_tournament),
    do: gettext("Link the event to a tournament first (Event settings).")

  defp import_error(:unauthorized),
    do: gettext("The linked tournament is no longer available to you.")

  defp import_error(_), do: gettext("The import did not complete.")

  @doc false
  def fide_error(:no_fide_id), do: gettext("Enter the badge's FIDE ID first.")

  def fide_error(:already_fetched),
    do: gettext("This badge already has its FIDE photo. Remove the photo to fetch it again.")

  def fide_error(:cooldown),
    do: gettext("FIDE was asked for this photo less than a minute ago. Please wait a moment.")

  def fide_error(:rate_limited),
    do: gettext("Too many FIDE requests in a short time. Please wait a minute and try again.")

  def fide_error(:invalid_id), do: gettext("That is not a FIDE ID.")
  def fide_error(:not_found), do: gettext("FIDE has no player with this ID.")

  def fide_error(:unreachable),
    do:
      gettext(
        "ratings.fide.com did not answer this server. Open the FIDE profile, copy the photo and paste it here with Ctrl+V, or save it and upload it."
      )

  def fide_error(:http_error),
    do: gettext("ratings.fide.com answered with an error. Try again later, or upload the photo.")

  def fide_error(:page_changed),
    do:
      gettext(
        "FIDE's profile page has changed and the photo could not be found on it. Please upload the photo by hand."
      )

  def fide_error(:no_photo), do: gettext("FIDE has no photo for this player. Please upload one.")

  def fide_error(_),
    do: gettext("The photo FIDE sent is not an image a badge can use. Please upload one.")

  defp image_error(:too_large, kind),
    do:
      gettext("The image is larger than %{mb} MB.",
        mb: Float.round(Image.limits(kind).bytes / 1_000_000, 1)
      )

  defp image_error(:too_many_pixels, kind),
    do:
      gettext("The image is larger than %{px} x %{px} pixels. Please make it smaller first.",
        px: Image.limits(kind).pixels
      )

  defp image_error(_, _kind), do: gettext("Only PNG, JPEG, GIF or WebP images can be used.")

  defp upload_error(:too_large), do: gettext("The file is too large.")
  defp upload_error(:not_accepted), do: gettext("Only PNG, JPEG, GIF or WebP images can be used.")
  defp upload_error(:too_many_files), do: gettext("One file at a time.")
  defp upload_error(_), do: gettext("The upload failed.")

  defp source_label(%Badge{source: "player"}), do: gettext("Player")
  defp source_label(%Badge{source: "official"}), do: gettext("Official")
  defp source_label(%Badge{}), do: gettext("Manual")

  defp field_label("first_name"), do: gettext("First name")
  defp field_label("last_name"), do: gettext("Last name")
  defp field_label("title"), do: gettext("Title")
  defp field_label("federation"), do: gettext("Federation")
  defp field_label("fide_id"), do: gettext("FIDE ID")
  defp field_label("role"), do: gettext("Role")
  defp field_label("role_color"), do: gettext("Role colour")
  defp field_label(other), do: other

  defp logo_label(:emblem), do: gettext("Header emblem (top of both sides)")
  defp logo_label(:logo_left), do: gettext("Footer logo, left (default: FIDE)")
  defp logo_label(:logo_right), do: gettext("Footer logo, right")

  defp card(event, badge, urls), do: Badges.card(event, badge, urls)

  # A sample badge for the settings preview when the event has none yet.
  defp sample_badge(event) do
    role = Event.role(event, "player") || List.first(event.roles) || %{}

    %Badge{
      id: 0,
      first_name: "Firstname",
      last_name: "Lastname",
      title: "IM",
      federation: "BEL",
      fide_id: "",
      role: role["label"] || "",
      role_color: role["color"] || "#374151",
      room_access: [1]
    }
  end

  ## ---------- Render ----------

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
        <div class="min-w-0">
          <p class="hint" style="margin: 0">
            <.link navigate={~p"/badges"}>{gettext("Accreditation badges")}</.link>
          </p>
          <h1 id="badge-event-title">{@event.name}</h1>
          <p class="subtitle" style="margin: 0">
            {ngettext("1 badge", "%{count} badges", @badge_count)}
            <%= if @linked do %>
              · {gettext("from")}
              <.link id="badge-event-tournament-link" navigate={~p"/t/#{@linked.id}/players"}>
                {@linked.name}
              </.link>
            <% end %>
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <.link
            id="badge-tab-list"
            patch={~p"/badges/#{@event.id}"}
            class={["pe-btn", @live_action == :index && "tonal"]}
          >
            <.icon name="hero-rectangle-stack" class="w-4 h-4" /> {gettext("Badges")}
          </.link>
          <.link
            id="badge-tab-settings"
            patch={~p"/badges/#{@event.id}/settings"}
            class={["pe-btn", @live_action == :settings && "tonal"]}
          >
            <.icon name="hero-cog-6-tooth" class="w-4 h-4" /> {gettext("Event settings")}
          </.link>
          <a
            id="print-all-badges"
            href={~p"/badges/#{@event.id}/print"}
            target="_blank"
            rel="noopener"
            class={["pe-btn", @badge_count == 0 && "disabled"]}
          >
            <.icon name="hero-printer" class="w-4 h-4" /> {gettext("Print all")}
          </a>
          <button id="add-badge" type="button" class="pe-btn primary" phx-click="add_badge">
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add badge")}
          </button>
        </div>
      </div>

      <%= case @live_action do %>
        <% :index -> %>
          {render_list(assigns)}
        <% :edit -> %>
          {render_editor(assigns)}
        <% :settings -> %>
          {render_settings(assigns)}
      <% end %>
    </Layouts.app>
    """
  end

  defp render_list(assigns) do
    ~H"""
    <section :if={@event.tournament_id} id="badge-import" class="card mb-4">
      <div class="flex flex-wrap items-center justify-between gap-3 text-left">
        <p class="hint m-0 max-w-2xl text-left">
          <%= if @linked do %>
            {gettext(
              "Import the tournament's players and officials. Running an import again updates those badges in place; badges you added by hand, and fields you changed on a badge, are left alone."
            )}
          <% else %>
            {gettext("The linked tournament is no longer available to you.")}
          <% end %>
        </p>
        <div :if={@linked} class="flex gap-2">
          <button id="import-players" type="button" class="pe-btn" phx-click="import_players">
            <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> {gettext("Import players")}
          </button>
          <button id="import-officials" type="button" class="pe-btn" phx-click="import_officials">
            <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> {gettext("Import officials")}
          </button>
        </div>
      </div>
    </section>

    <div class="card table-card">
      <table class="pe-table">
        <thead>
          <tr>
            <th><span class="sr-only">{gettext("Photo")}</span></th>
            <th>{gettext("Name")}</th>
            <th>{gettext("Role")}</th>
            <th>{gettext("Rooms")}</th>
            <th>{gettext("Source")}</th>
            <th><span class="sr-only">{gettext("Actions")}</span></th>
          </tr>
        </thead>
        <tbody id="badges" phx-update="stream">
          <tr id="badges-empty" class="hidden only:table-row">
            <td colspan="6" class="empty">
              {gettext("No badges yet. Import them from the tournament, or add one by hand.")}
            </td>
          </tr>
          <tr :for={{dom_id, badge} <- @streams.badges} id={dom_id}>
            <td style="width: 44px">
              <div class="w-9 h-11 rounded overflow-hidden bg-neutral-200 flex items-center justify-center">
                <img
                  :if={badge.photo_content_type}
                  src={@urls.(:photo, badge)}
                  alt=""
                  loading="lazy"
                  class="w-full h-full object-cover"
                />
                <.icon
                  :if={!badge.photo_content_type}
                  name="hero-user"
                  class="w-5 h-5 text-neutral-400"
                />
              </div>
            </td>
            <td>
              <.link
                navigate={~p"/badges/#{@event.id}/badge/#{badge.id}"}
                class="font-semibold"
                id={"edit-badge-#{badge.id}"}
              >
                {Badge.display_name(badge) |> then(&if(&1 == "", do: gettext("(no name)"), else: &1))}
              </.link>
              <div class="hint">
                {[badge.title, badge.federation, badge.fide_id]
                |> Enum.reject(&(&1 in [nil, ""]))
                |> Enum.join(" · ")}
              </div>
            </td>
            <td>
              <span
                class="inline-block rounded px-2 py-0.5 text-xs font-bold uppercase tracking-wide text-white"
                style={"background-color: #{badge.role_color}"}
              >
                {badge.role}
              </span>
            </td>
            <td class="hint">{Enum.join(badge.room_access, " ")}</td>
            <td>
              <span class="hint">{source_label(badge)}</span>
              <span
                :if={badge.edited_fields != []}
                class="hint"
                title={gettext("Changed by hand; an import will not overwrite these fields.")}
              >
                · {gettext("edited")}
              </span>
            </td>
            <td style="text-align: right; white-space: nowrap">
              <a
                href={~p"/badges/#{@event.id}/print?badge=#{badge.id}"}
                target="_blank"
                rel="noopener"
                class="pe-btn"
                id={"print-badge-#{badge.id}"}
                title={gettext("Print this badge")}
              >
                <.icon name="hero-printer" class="w-4 h-4" />
                <span class="sr-only">{gettext("Print this badge")}</span>
              </a>
              <button
                type="button"
                class="pe-btn"
                id={"duplicate-badge-#{badge.id}"}
                phx-click="duplicate_badge"
                phx-value-id={badge.id}
                title={gettext("Duplicate")}
              >
                <.icon name="hero-document-duplicate" class="w-4 h-4" />
                <span class="sr-only">{gettext("Duplicate")}</span>
              </button>
              <button
                type="button"
                class="pe-btn danger-link"
                id={"delete-badge-#{badge.id}"}
                phx-click="delete_badge"
                phx-value-id={badge.id}
                data-confirm={gettext("Delete this badge?")}
              >
                {gettext("Delete")}
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp render_editor(assigns) do
    assigns = assign(assigns, :card, card(assigns.event, assigns.badge, assigns.urls))

    ~H"""
    <div class="grid gap-6 xl:grid-cols-[minmax(0,440px)_1fr]">
      <div class="flex flex-col gap-4">
        <div class="flex items-center justify-between gap-2">
          <.link patch={~p"/badges/#{@event.id}"} class="pe-btn" id="back-to-badges">
            <.icon name="hero-arrow-left" class="w-4 h-4" /> {gettext("All badges")}
          </.link>
          <span class="hint">{elem(@position, 0)} / {elem(@position, 1)}</span>
          <div class="flex gap-1">
            <.link
              :if={@prev_id}
              patch={~p"/badges/#{@event.id}/badge/#{@prev_id}"}
              class="pe-btn"
              id="prev-badge"
              title={gettext("Previous badge")}
            >
              <.icon name="hero-chevron-left" class="w-4 h-4" />
            </.link>
            <.link
              :if={@next_id}
              patch={~p"/badges/#{@event.id}/badge/#{@next_id}"}
              class="pe-btn"
              id="next-badge"
              title={gettext("Next badge")}
            >
              <.icon name="hero-chevron-right" class="w-4 h-4" />
            </.link>
          </div>
        </div>

        <section class="card" aria-labelledby="badge-details-heading">
          <h2 id="badge-details-heading">{gettext("Badge")}</h2>
          <.form for={@badge_form} id="badge-form" phx-change="save_badge" phx-submit="save_badge">
            <div class="grid grid-cols-2 gap-x-3">
              <.input
                field={@badge_form[:first_name]}
                label={gettext("First name")}
                phx-debounce="300"
              />
              <.input field={@badge_form[:last_name]} label={gettext("Last name")} phx-debounce="300" />
              <.input field={@badge_form[:title]} label={gettext("Title")} phx-debounce="300" />
              <.input
                field={@badge_form[:federation]}
                label={gettext("Federation")}
                phx-debounce="300"
              />
              <.input
                field={@badge_form[:fide_id]}
                label={gettext("FIDE ID")}
                inputmode="numeric"
                phx-debounce="300"
              />
              <.input field={@badge_form[:role]} label={gettext("Role")} phx-debounce="300" />
              <.input field={@badge_form[:role_color]} type="color" label={gettext("Role colour")} />
            </div>
          </.form>

          <p class="hint mb-1">{gettext("Roles of this event")}</p>
          <div id="role-presets" class="flex flex-wrap gap-1.5">
            <button
              :for={role <- @event.roles}
              type="button"
              id={"role-preset-#{role["key"]}"}
              phx-click="set_role"
              phx-value-key={role["key"]}
              class={[
                "rounded px-2 py-1 text-[11px] font-bold uppercase tracking-wide text-white transition hover:opacity-90",
                role["label"] == @badge.role && "ring-2 ring-offset-1 ring-neutral-900"
              ]}
              style={"background-color: #{role["color"]}"}
            >
              {role["label"]}
            </button>
          </div>
        </section>

        <section class="card" aria-labelledby="badge-rooms-heading">
          <div class="flex items-center justify-between gap-2 mb-2">
            <h2 id="badge-rooms-heading" class="m-0">{gettext("Room access")}</h2>
            <div class="flex gap-1">
              <button
                id="rooms-all"
                type="button"
                class="pe-btn"
                phx-click="room_preset"
                phx-value-preset="all"
              >
                {gettext("All")}
              </button>
              <button
                id="rooms-first-half"
                type="button"
                class="pe-btn"
                phx-click="room_preset"
                phx-value-preset="first_half"
              >
                {gettext("First half")}
              </button>
              <button
                id="rooms-none"
                type="button"
                class="pe-btn"
                phx-click="room_preset"
                phx-value-preset="none"
              >
                {gettext("None")}
              </button>
            </div>
          </div>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-1.5">
            <button
              :for={num <- 1..@event.room_count//1}
              type="button"
              id={"room-toggle-#{num}"}
              phx-click="toggle_room"
              phx-value-room={num}
              aria-pressed={to_string(num in @badge.room_access)}
              class={[
                "flex items-center gap-2 rounded-lg border px-2 py-1.5 text-left text-xs transition",
                if(num in @badge.room_access,
                  do: "border-neutral-900 bg-neutral-900 text-white",
                  else: "border-neutral-300 hover:border-neutral-500"
                )
              ]}
            >
              <span class={[
                "flex h-5 w-5 shrink-0 items-center justify-center rounded-full text-[10px] font-bold",
                if(num in @badge.room_access,
                  do: "bg-white text-neutral-900",
                  else: "border border-neutral-400"
                )
              ]}>
                {num}
              </span>
              <span class="truncate uppercase">{Event.room_name(@event, num)}</span>
            </button>
          </div>
        </section>

        <%!-- Paste: copy a photo anywhere (the player's FIDE profile, say)
              and press Ctrl+V on this page; it goes through the same upload,
              size and type checks as a picked file. The server cannot
              always fetch from FIDE itself - ratings.fide.com drops
              connections from datacenter addresses - but the arbiter's own
              browser can open the profile. --%>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".PastePhoto">
          export default {
            mounted() {
              this.onPaste = (e) => {
                const target = e.target
                if (target && (target.tagName === "INPUT" || target.tagName === "TEXTAREA" || target.isContentEditable)) return
                const items = Array.from((e.clipboardData && e.clipboardData.items) || [])
                const item = items.find((i) => i.kind === "file" && i.type.startsWith("image/"))
                if (!item) return
                const file = item.getAsFile()
                if (!file) return
                e.preventDefault()
                const ext = (file.type.split("/")[1] || "png").replace("jpeg", "jpg")
                const named = new File([file], `pasted-photo.${ext}`, { type: file.type })
                this.upload("photo", [named])
              }
              window.addEventListener("paste", this.onPaste)
            },
            destroyed() {
              window.removeEventListener("paste", this.onPaste)
            }
          }
        </script>

        <section
          id="badge-photo-section"
          class="card"
          aria-labelledby="badge-photo-heading"
          phx-hook=".PastePhoto"
        >
          <h2 id="badge-photo-heading">{gettext("Photo")}</h2>
          <div class="flex gap-4">
            <div class="w-20 h-24 shrink-0 rounded overflow-hidden bg-neutral-200 flex items-center justify-center">
              <img
                :if={@badge.photo_content_type}
                id="badge-photo-thumb"
                src={@urls.(:photo, @badge)}
                alt=""
                class="w-full h-full object-cover"
              />
              <.icon
                :if={!@badge.photo_content_type}
                name="hero-user"
                class="w-8 h-8 text-neutral-400"
              />
            </div>
            <div class="flex flex-col gap-2 min-w-0">
              <form id="photo-upload-form" phx-change="validate_upload" phx-submit="validate_upload">
                <label class="pe-btn cursor-pointer">
                  <.icon name="hero-arrow-up-tray" class="w-4 h-4" /> {gettext("Upload photo")}
                  <.live_file_input upload={@uploads.photo} class="sr-only" />
                </label>
              </form>
              <p :for={err <- upload_errors(@uploads.photo)} class="error-note">
                {upload_error(err)}
              </p>
              <div :for={entry <- @uploads.photo.entries}>
                <p :for={err <- upload_errors(@uploads.photo, entry)} class="error-note">
                  {upload_error(err)}
                </p>
              </div>
              <button
                id="fetch-fide-photo"
                type="button"
                class="pe-btn"
                phx-click="fetch_fide"
                phx-disable-with={gettext("Fetching…")}
                disabled={
                  @fetching? or @badge.fide_id in [nil, ""] or
                    (@badge.photo_source == "fide" and @badge.photo_content_type != nil)
                }
              >
                <.icon name="hero-cloud-arrow-down" class="w-4 h-4" />
                {if @fetching?, do: gettext("Fetching…"), else: gettext("Fetch from FIDE")}
              </button>
              <a
                :if={@badge.fide_id not in [nil, ""]}
                id="open-fide-profile"
                href={"https://ratings.fide.com/profile/#{@badge.fide_id}"}
                target="_blank"
                rel="noopener noreferrer"
                class="pe-btn"
              >
                <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" />
                {gettext("Open FIDE profile")}
              </a>
              <p class="hint m-0">
                {gettext("Or copy a photo and paste it here with Ctrl+V.")}
              </p>
              <p class="hint m-0">
                <%= cond do %>
                  <% @badge.photo_source == "fide" and @badge.photo_content_type != nil -> %>
                    {gettext("Fetched from FIDE and stored with the badge.")}
                  <% @badge.fide_id in [nil, ""] -> %>
                    {gettext("Enter a FIDE ID to fetch the photo from the player's FIDE profile.")}
                  <% true -> %>
                    {gettext(
                      "One request to ratings.fide.com; the photo is then stored with the badge."
                    )}
                <% end %>
              </p>
              <button
                :if={@badge.photo_content_type}
                id="clear-photo"
                type="button"
                class="pe-btn danger-link self-start"
                phx-click="clear_photo"
              >
                {gettext("Remove photo")}
              </button>
            </div>
          </div>
        </section>

        <section :if={Badge.imported?(@badge)} class="card" id="badge-source">
          <h2>{gettext("Imported")}</h2>
          <p class="hint">
            {if @badge.source == "player",
              do: gettext("From the tournament's player list."),
              else: gettext("From the tournament's officials.")}
            <%= if @badge.edited_fields != [] do %>
              {gettext("Changed by hand, and kept on re-import:")}
              <strong>{@badge.edited_fields |> Enum.map(&field_label/1) |> Enum.join(", ")}</strong>.
            <% end %>
          </p>
          <button
            :if={@badge.edited_fields != []}
            id="revert-badge"
            type="button"
            class="pe-btn"
            phx-click="revert_badge"
            data-confirm={gettext("Replace your changes with the tournament's data?")}
          >
            {gettext("Use the tournament's data again")}
          </button>
        </section>

        <div class="flex flex-wrap gap-2">
          <a
            id="print-this-badge"
            href={~p"/badges/#{@event.id}/print?badge=#{@badge.id}"}
            target="_blank"
            rel="noopener"
            class="pe-btn"
          >
            <.icon name="hero-printer" class="w-4 h-4" /> {gettext("Print this badge")}
          </a>
          <button
            id="duplicate-this-badge"
            type="button"
            class="pe-btn"
            phx-click="duplicate_badge"
            phx-value-id={@badge.id}
          >
            {gettext("Duplicate")}
          </button>
          <button
            id="delete-this-badge"
            type="button"
            class="pe-btn danger-link"
            phx-click="delete_badge"
            phx-value-id={@badge.id}
            data-confirm={gettext("Delete this badge?")}
          >
            {gettext("Delete")}
          </button>
        </div>
      </div>

      {render_preview(assigns)}
    </div>
    """
  end

  defp render_preview(assigns) do
    assigns = assign(assigns, :zooms, @zooms)

    ~H"""
    <section
      class="card min-w-0 self-start xl:sticky xl:top-4"
      aria-labelledby="badge-preview-heading"
    >
      <div class="flex flex-wrap items-center justify-between gap-2 mb-3">
        <h2 id="badge-preview-heading" class="m-0">{gettext("Preview")}</h2>
        <div class="flex flex-wrap items-center gap-2">
          <div class="flex gap-1" role="group" aria-label={gettext("Preview mode")}>
            <button
              id="preview-sides"
              type="button"
              class={["pe-btn", @preview == "sides" && "tonal"]}
              phx-click="preview"
              phx-value-mode="sides"
            >
              {gettext("Front and back")}
            </button>
            <button
              id="preview-flip"
              type="button"
              class={["pe-btn", @preview == "flip" && "tonal"]}
              phx-click="preview"
              phx-value-mode="flip"
            >
              {gettext("Flip card")}
            </button>
          </div>
          <form id="zoom-form" phx-change="zoom">
            <label class="hint flex items-center gap-1">
              {gettext("Zoom")}
              <select name="zoom" class="select select-sm w-auto">
                <option :for={z <- @zooms} value={z} selected={z == @zoom}>{z}%</option>
              </select>
            </label>
          </form>
        </div>
      </div>

      <div class="overflow-auto rounded-lg bg-neutral-200/60 p-4">
        <%= if @preview == "sides" do %>
          <div
            id="badge-preview"
            class="badge-zoom mx-auto flex w-max gap-6"
            style={"zoom: #{@zoom / 100};"}
          >
            <div class="shadow-lg">
              <.badge_front id="preview-front" badge={@card} qr_svg={@qr_svg} />
            </div>
            <div class="shadow-lg">
              <.badge_back id="preview-back" badge={@card} qr_svg={@qr_svg} />
            </div>
          </div>
        <% else %>
          <div id="badge-preview" class="badge-zoom mx-auto w-max" style={"zoom: #{@zoom / 100};"}>
            <button
              id="badge-flip"
              type="button"
              class="badge-flip block cursor-pointer"
              phx-click="flip"
              aria-label={gettext("Flip the badge")}
            >
              <div class={["badge-flip-inner shadow-lg", @flipped? && "is-flipped"]}>
                <div class="badge-flip-face">
                  <.badge_front id="preview-front" badge={@card} qr_svg={@qr_svg} />
                </div>
                <div class="badge-flip-face badge-flip-back">
                  <.badge_back id="preview-back" badge={@card} qr_svg={@qr_svg} />
                </div>
              </div>
            </button>
          </div>
        <% end %>
      </div>
      <p class="hint mt-2 mb-0">
        {gettext("Actual size at 100%: A6, 105 x 148.5 mm. Printed two badges to an A4 sheet.")}
      </p>
    </section>
    """
  end

  defp render_settings(assigns) do
    sample = assigns.sample || sample_badge(assigns.preview_event)

    assigns =
      assigns
      |> assign(:card, card(assigns.preview_event, sample, assigns.urls))
      |> assign(:rooms_shown, max(assigns.preview_event.room_count || 1, 1))
      |> assign(:import_keys, Defaults.import_role_keys())

    ~H"""
    <div class="grid gap-6 xl:grid-cols-[minmax(0,560px)_1fr]">
      <div class="flex flex-col gap-4">
        <section class="card" aria-labelledby="event-link-heading">
          <h2 id="event-link-heading">{gettext("Tournament")}</h2>
          <form id="event-link-form" phx-change="link_tournament">
            <.input
              name="link[tournament_id]"
              id="event-link-tournament"
              type="select"
              label={gettext("Import players and officials from")}
              value={@event.tournament_id}
              prompt={gettext("No tournament - a stand-alone event")}
              options={Enum.map(@tournaments, &{&1.name, &1.id})}
            />
          </form>
          <p class="hint m-0">
            {gettext("Only tournaments you own or collaborate on can be linked.")}
          </p>
        </section>

        <.form
          for={@event_form}
          id="event-settings-form"
          phx-change="validate_event"
          phx-submit="save_event"
          class="flex flex-col gap-4"
        >
          <section class="card" aria-labelledby="event-header-heading">
            <h2 id="event-header-heading">{gettext("Header")}</h2>
            <div class="grid grid-cols-2 gap-x-3">
              <div class="col-span-2">
                <.input field={@event_form[:name]} label={gettext("Event name")} phx-debounce="300" />
              </div>
              <div class="col-span-2">
                <.input field={@event_form[:subtitle]} label={gettext("Subtitle")} phx-debounce="300" />
              </div>
              <.input field={@event_form[:city]} label={gettext("City")} phx-debounce="300" />
              <.input field={@event_form[:year]} label={gettext("Year")} phx-debounce="300" />
              <div class="col-span-2">
                <.input
                  field={@event_form[:organiser]}
                  label={gettext("Organiser")}
                  phx-debounce="300"
                />
              </div>
              <div class="col-span-2">
                <.input
                  field={@event_form[:qr_url]}
                  label={gettext("QR code link (printed on both sides)")}
                  phx-debounce="300"
                />
              </div>
            </div>
          </section>

          <section class="card" aria-labelledby="event-conditions-heading">
            <div class="flex items-center justify-between gap-2">
              <h2 id="event-conditions-heading" class="m-0">{gettext("Back of the badge")}</h2>
              <button
                id="reset-conditions"
                type="button"
                class="pe-btn"
                phx-click="reset_conditions"
                data-confirm={gettext("Replace the conditions with the default text?")}
              >
                {gettext("Default text")}
              </button>
            </div>
            <.input
              field={@event_form[:conditions_title]}
              label={gettext("Heading")}
              phx-debounce="300"
            />
            <.input
              field={@event_form[:usage_conditions]}
              type="textarea"
              rows="12"
              label={gettext("Usage conditions")}
              phx-debounce="400"
            />
            <p class="hint m-0">
              {gettext(
                "$tournament-name and $organiser are filled in when printing. A line starting with \"if \" is indented under the point above it."
              )}
            </p>
          </section>

          <section class="card" aria-labelledby="event-rooms-heading">
            <h2 id="event-rooms-heading">{gettext("Rooms")}</h2>
            <.input
              field={@event_form[:room_count]}
              type="select"
              label={gettext("Numbered rooms or zones on the badge")}
              options={Enum.to_list(1..Defaults.max_rooms())}
            />
            <div class="grid grid-cols-2 gap-x-3">
              <.input
                :for={num <- 1..@rooms_shown//1}
                name={"event[room_names][#{num}]"}
                id={"event-room-name-#{num}"}
                value={Event.room_name(@preview_event, num)}
                label={gettext("Room %{num}", num: num)}
                phx-debounce="300"
              />
            </div>
          </section>

          <section class="card" aria-labelledby="event-roles-heading">
            <div class="flex items-center justify-between gap-2 mb-2">
              <h2 id="event-roles-heading" class="m-0">{gettext("Roles")}</h2>
              <button id="add-role" type="button" class="pe-btn" phx-click="add_role">
                <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add role")}
              </button>
            </div>
            <p class="hint">
              {gettext(
                "The role banner's text and colour. Write them in the languages the event prints in; players and officials are imported with the first four."
              )}
            </p>
            <div id="event-roles" class="flex flex-col gap-1">
              <div
                :for={{role, i} <- Enum.with_index(@preview_event.roles)}
                id={"event-role-#{role["key"]}"}
                class="flex items-end gap-2"
              >
                <input type="hidden" name={"event[roles][#{i}][key]"} value={role["key"]} />
                <div class="flex-1">
                  <.input
                    name={"event[roles][#{i}][label]"}
                    id={"event-role-label-#{i}"}
                    value={role["label"]}
                    label={if i == 0, do: gettext("Printed name")}
                    aria-label={gettext("Printed name of role %{n}", n: i + 1)}
                    phx-debounce="300"
                  />
                </div>
                <div class="w-20">
                  <.input
                    name={"event[roles][#{i}][color]"}
                    id={"event-role-color-#{i}"}
                    type="color"
                    value={role["color"]}
                    label={if i == 0, do: gettext("Colour")}
                    aria-label={gettext("Colour of role %{n}", n: i + 1)}
                  />
                </div>
                <div class="w-9 pb-3">
                  <button
                    :if={role["key"] not in @import_keys}
                    type="button"
                    class="pe-btn danger-link"
                    id={"remove-role-#{role["key"]}"}
                    phx-click="remove_role"
                    phx-value-key={role["key"]}
                    title={gettext("Remove role")}
                  >
                    <.icon name="hero-x-mark" class="w-4 h-4" />
                    <span class="sr-only">{gettext("Remove role")}</span>
                  </button>
                </div>
              </div>
            </div>
            <p :for={{msg, _} <- Keyword.get_values(@event_form.errors, :roles)} class="error-note">
              {msg}
            </p>
          </section>

          <div class="flex gap-2">
            <button id="save-event-settings" type="submit" class="pe-btn primary">
              {gettext("Save settings")}
            </button>
          </div>
        </.form>

        <section class="card" aria-labelledby="event-logos-heading">
          <h2 id="event-logos-heading">{gettext("Logos")}</h2>
          <p class="hint">
            {gettext(
              "PNG, JPEG, GIF or WebP, up to 1 MB and 3000 x 3000 pixels. Saved as soon as it is chosen."
            )}
          </p>
          <div class="flex flex-col gap-3">
            <div :for={slot <- Event.logo_slots()} class="flex items-center gap-3" id={"logo-#{slot}"}>
              <div class="w-24 h-12 shrink-0 rounded bg-white border border-neutral-300 flex items-center justify-center overflow-hidden">
                <img
                  :if={Map.get(@event, :"#{slot}_content_type")}
                  src={@urls.(:logo, slot)}
                  alt=""
                  class="max-w-full max-h-full object-contain"
                />
              </div>
              <div class="flex flex-col gap-1 min-w-0">
                <span class="text-sm font-semibold">{logo_label(slot)}</span>
                <div class="flex gap-2">
                  <form
                    id={"logo-upload-form-#{slot}"}
                    phx-change="validate_upload"
                    phx-submit="validate_upload"
                  >
                    <label class="pe-btn cursor-pointer">
                      {gettext("Upload")}
                      <.live_file_input upload={@uploads[slot]} class="sr-only" />
                    </label>
                  </form>
                  <button
                    :if={Map.get(@event, :"#{slot}_content_type")}
                    type="button"
                    class="pe-btn danger-link"
                    id={"clear-logo-#{slot}"}
                    phx-click="clear_logo"
                    phx-value-slot={slot}
                  >
                    {gettext("Remove")}
                  </button>
                </div>
                <p :for={err <- upload_errors(@uploads[slot])} class="error-note">
                  {upload_error(err)}
                </p>
                <div :for={entry <- @uploads[slot].entries}>
                  <p :for={err <- upload_errors(@uploads[slot], entry)} class="error-note">
                    {upload_error(err)}
                  </p>
                </div>
              </div>
            </div>
          </div>
        </section>

        <section class="card" aria-labelledby="event-delete-heading">
          <h2 id="event-delete-heading">{gettext("Delete event")}</h2>
          <p class="hint">{gettext("Deletes the event and every badge in it, photos included.")}</p>
          <button
            id="delete-event"
            type="button"
            class="pe-btn danger"
            phx-click="delete_event"
            data-confirm={
              gettext("Delete this badge event and all its badges? This cannot be undone.")
            }
          >
            {gettext("Delete event")}
          </button>
        </section>
      </div>

      <section
        class="card min-w-0 self-start xl:sticky xl:top-4"
        aria-labelledby="event-preview-heading"
      >
        <h2 id="event-preview-heading">{gettext("Preview")}</h2>
        <div class="overflow-auto rounded-lg bg-neutral-200/60 p-4">
          <div id="badge-preview" class="badge-zoom mx-auto flex w-max gap-6" style="zoom: 0.8;">
            <div class="shadow-lg">
              <.badge_front id="preview-front" badge={@card} qr_svg={@qr_svg} />
            </div>
            <div class="shadow-lg">
              <.badge_back id="preview-back" badge={@card} qr_svg={@qr_svg} />
            </div>
          </div>
        </div>
      </section>
    </div>
    """
  end
end
