defmodule PairingsEngineWeb.SettingsRoomsLive do
  @moduledoc """
  Settings, Rooms (`/t/:id/settings/rooms`): the playing hall's rooms, each
  a name and the boards it holds ("1-20, 35, 40-45"). Add one, rename one,
  remove one, change its boards; every keystroke is read back at once
  (`PairingsEngine.Rooms.normalize/1`, the same check the save goes
  through), so a board in two rooms is pointed out before anybody prints
  the wrong sheet in the wrong room.

  The rooms are what the pairing list and the printed pairings name per
  board, and what a print station or a hall announcer is placed in. A
  room keeps its id through a rename, so what was placed in it stays
  placed.

  Nothing on this page is advanced, so it has no switch.
  """
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport

  alias PairingsEngine.{BoardRanges, Rooms, Tournaments}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     socket
     |> attach_dirty_tracker()
     |> assign(
       tournament: tournament,
       page_title: "#{tournament.name} · Settings · " <> gettext("Rooms"),
       note: nil,
       error: nil,
       dirty: false,
       stale: false
     )
     |> put_rows(stored_rows(tournament))}
  end

  defp stored_rows(tournament) do
    for r <- Rooms.list(tournament), do: %{"id" => r.id, "name" => r.name, "boards" => r.boards}
  end

  # The rows as typed, and what the checker makes of them right now.
  defp put_rows(socket, rows) do
    problems =
      case Rooms.normalize(rows) do
        {:ok, _} -> %{}
        {:error, list} -> Enum.group_by(list, &elem(&1, 0), &elem(&1, 1))
      end

    assign(socket, rows: rows, problems: problems)
  end

  @impl true
  def handle_info({:tournament_changed, _id, _hint}, %{assigns: %{dirty: true}} = socket),
    do: handle_stale_check(socket)

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
         socket
         |> assign(tournament: tournament, stale: false)
         |> put_rows(stored_rows(tournament))}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("change", params, socket) do
    {:noreply, socket |> put_rows(rows_from(params, socket.assigns.rows)) |> assign(note: nil)}
  end

  def handle_event("add_room", _params, socket) do
    rows = socket.assigns.rows ++ [%{"id" => "", "name" => "", "boards" => ""}]
    {:noreply, socket |> put_rows(rows) |> assign(note: nil)}
  end

  def handle_event("remove_room", %{"index" => index}, socket) do
    rows =
      case Integer.parse(index) do
        {i, ""} -> List.delete_at(socket.assigns.rows, i)
        _ -> socket.assigns.rows
      end

    {:noreply, socket |> put_rows(rows) |> assign(note: nil)}
  end

  def handle_event("save", params, socket) do
    rows = rows_from(params, socket.assigns.rows)
    base = Tournaments.get_tournament!(socket.assigns.tournament.id)

    case Tournaments.update_tournament(base, %{"rooms" => rows}) do
      {:ok, tournament} ->
        log_settings_change(socket, base, tournament)

        {:noreply,
         socket
         |> assign(
           tournament: tournament,
           note: gettext("Saved."),
           error: nil,
           dirty: false,
           stale: false
         )
         |> put_rows(stored_rows(tournament))}

      {:error, %Ecto.Changeset{} = changeset} ->
        error =
          if Keyword.has_key?(changeset.errors, :rooms),
            do: gettext("Not saved: a room below needs fixing first."),
            else: error_text(changeset)

        {:noreply, socket |> put_rows(rows) |> assign(error: error, note: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_text(reason), note: nil)}
    end
  end

  # The form's rows, in the page's order. A row the form did not send (one
  # just added, before anything was typed in it) keeps what it had.
  defp rows_from(params, current) do
    sent = Map.get(params, "rooms", %{})

    current
    |> Enum.with_index()
    |> Enum.map(fn {row, i} ->
      case Map.get(sent, Integer.to_string(i)) do
        %{} = r ->
          %{
            "id" => row["id"],
            "name" => r["name"] || row["name"],
            "boards" => r["boards"] || row["boards"]
          }

        _ ->
          row
      end
    end)
  end

  ## ---------- view ----------

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
      active="settings"
    >
      <.settings_page
        tournament={@tournament}
        current_scope={@current_scope}
        active={:rooms}
        subtitle={gettext("Settings - Rooms")}
      >
        <.stale_banner stale={@stale} />
        <form id="rooms-form" phx-change="change" phx-submit="save">
          <div class="card" id="rooms-card">
            <h2>{gettext("Rooms")}</h2>

            <p class="hint" style="margin-top: 0">
              {gettext(
                "For a hall of more than one room: give each room its boards. The pairing list and the printed pairings then say which room a board is in, and a print station or a hall announcer can be placed in a room. A board in no room is fine; a board in two is not."
              )}
            </p>

            <p :if={@rows == []} id="rooms-empty" class="hint">
              {gettext("No rooms yet: the whole tournament plays in one.")}
            </p>

            <div id="rooms-rows" class="room-rows">
              <div :for={{row, i} <- Enum.with_index(@rows)} id={"room-#{i}"} class="room-row">
                <label class="room-field" for={"room-#{i}-name"}>
                  <span class="set-row-label">{gettext("Name")}</span>
                  <input
                    type="text"
                    id={"room-#{i}-name"}
                    name={"rooms[#{i}][name]"}
                    value={row["name"]}
                    maxlength={Rooms.name_max()}
                    placeholder={gettext("e.g. Main hall")}
                    class="pe-input"
                    phx-debounce="200"
                  />
                </label>
                <label class="room-field room-boards" for={"room-#{i}-boards"}>
                  <span class="set-row-label">{gettext("Boards")}</span>
                  <input
                    type="text"
                    id={"room-#{i}-boards"}
                    name={"rooms[#{i}][boards]"}
                    value={row["boards"]}
                    placeholder="1-20, 35, 40-45"
                    class="pe-input"
                    phx-debounce="200"
                  />
                </label>
                <button
                  type="button"
                  class="pe-btn room-remove"
                  id={"room-#{i}-remove"}
                  phx-click="remove_room"
                  phx-value-index={i}
                  aria-label={gettext("Remove room %{name}", name: row_label(row, i))}
                >
                  <.icon name="hero-trash-micro" class="size-4" /> {gettext("Remove")}
                </button>
                <p
                  id={"room-#{i}-feedback"}
                  class={["room-feedback", if(@problems[i], do: "error-note", else: "hint")]}
                  aria-live="polite"
                >
                  {feedback(row, @problems[i])}
                </p>
              </div>
            </div>

            <div class="actions">
              <button
                type="button"
                class="pe-btn"
                id="rooms-add"
                phx-click="add_room"
                disabled={length(@rows) >= Rooms.max_rooms()}
              >
                <.icon name="hero-plus-micro" class="size-4" /> {gettext("Add a room")}
              </button>
            </div>
          </div>

          <div class="actions">
            <button type="submit" class="pe-btn primary" id="rooms-save">
              {gettext("Save rooms")}
            </button>
            <.save_status note={@note} error={@error} />
          </div>
        </form>
      </.settings_page>
    </Layouts.app>
    """
  end

  defp row_label(%{"name" => name}, i) do
    case String.trim(name || "") do
      "" -> gettext("%{n} (no name yet)", n: i + 1)
      name -> name
    end
  end

  # One line under a row: the first thing wrong with it, or what its
  # boards read as.
  defp feedback(_row, [problem | _]), do: problem_text(problem)

  defp feedback(row, _none) do
    case BoardRanges.parse(row["boards"]) do
      {:ok, []} ->
        gettext("No boards yet.")

      {:ok, ranges} ->
        count = Enum.reduce(ranges, 0, fn {a, b}, acc -> acc + b - a + 1 end)

        ngettext("Board %{list}: 1 board.", "Boards %{list}: %{count} boards.", count,
          list: BoardRanges.format(ranges)
        )

      {:error, reason} ->
        problem_text({:boards, reason})
    end
  end

  defp problem_text(:blank_name), do: gettext("Give this room a name.")

  defp problem_text(:name_too_long),
    do: gettext("A room's name is at most %{n} characters.", n: Rooms.name_max())

  defp problem_text(:duplicate_name), do: gettext("Another room already has this name.")

  defp problem_text(:too_many),
    do: gettext("A tournament has at most %{n} rooms.", n: Rooms.max_rooms())

  defp problem_text({:overlap, other, board}),
    do: gettext("Board %{board} is already in %{room}.", board: board, room: other)

  defp problem_text({:boards, {:backwards, token}}),
    do: gettext("\"%{token}\" runs backwards: put the smaller number first.", token: token)

  defp problem_text({:boards, {:too_big, token}}),
    do: gettext("\"%{token}\" is past board 9999.", token: token)

  defp problem_text({:boards, {_bad, token}}),
    do: gettext("\"%{token}\" is not a board number or a range like 40-45.", token: token)
end
