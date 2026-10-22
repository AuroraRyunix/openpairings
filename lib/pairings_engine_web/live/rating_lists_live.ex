defmodule PairingsEngineWeb.RatingListsLive do
  @moduledoc """
  The rating lists an administrator loads from CSV files (`/rating-lists`):
  upload, a preview that reports every problem with its line, then the import.
  A tournament can name these lists in its rating-list sequence
  (`PairingsEngine.RatingLists`).

  The lists are machine-wide, like the FIDE and national lists, so loading and
  deleting them is for administrators (`PairingsEngine.Authz`); support can look.
  """
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.Authz
  alias PairingsEngine.RatingLists
  alias PairingsEngine.RatingLists.Csv
  alias PairingsEngineWeb.UploadGuard

  @max_bytes 10_000_000
  @preview_rows 8

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: gettext("Rating lists"),
       may_admin?: Authz.may_administer?(socket.assigns.current_scope.user),
       name: "",
       preview: nil,
       errors: [],
       notice: nil,
       renaming: nil,
       rename_error: nil,
       rename_form: to_form(%{"name" => ""}, as: :rename),
       lists: RatingLists.custom_lists()
     )
     |> allow_upload(:csv,
       auto_upload: true,
       accept: ~w(.csv .txt),
       max_entries: 1,
       max_file_size: @max_bytes
     )}
  end

  @impl true
  def handle_event("validate", params, socket) do
    {:noreply, assign(socket, name: Map.get(params, "name", socket.assigns.name))}
  end

  def handle_event("preview", params, %{assigns: %{may_admin?: false}} = socket) do
    _ = params
    {:noreply, assign(socket, errors: [admin_only()], preview: nil)}
  end

  def handle_event("preview", params, socket) do
    name = params |> Map.get("name", socket.assigns.name) |> String.trim()
    socket = assign(socket, name: name, notice: nil)

    case UploadGuard.status(socket, :csv) do
      :uploading ->
        {:noreply, assign(socket, errors: [UploadGuard.still_uploading_message()], preview: nil)}

      :errored ->
        {:noreply, assign(socket, errors: [UploadGuard.entry_error_message()], preview: nil)}

      :ready ->
        case consume_uploaded_entries(socket, :csv, fn %{path: path}, _entry ->
               {:ok, File.read(path)}
             end) do
          [] ->
            {:noreply,
             assign(socket, errors: [gettext("Choose a CSV file first.")], preview: nil)}

          [{:ok, raw}] ->
            {:noreply, preview(socket, name, raw)}

          _ ->
            {:noreply,
             assign(socket, errors: [gettext("The file could not be read.")], preview: nil)}
        end
    end
  end

  def handle_event("confirm_import", _params, %{assigns: %{may_admin?: false}} = socket),
    do: {:noreply, assign(socket, errors: [admin_only()])}

  def handle_event("confirm_import", _params, %{assigns: %{preview: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm_import", _params, socket) do
    %{name: name, rows: rows} = socket.assigns.preview

    case RatingLists.import_list(name, rows) do
      {:ok, list, replaced?} ->
        notice =
          if replaced?,
            do:
              gettext("%{name} replaced: %{count} players.",
                name: list.name,
                count: list.entry_count
              ),
            else:
              gettext("%{name} loaded: %{count} players.",
                name: list.name,
                count: list.entry_count
              )

        {:noreply,
         assign(socket,
           preview: nil,
           errors: [],
           name: "",
           notice: notice,
           lists: RatingLists.custom_lists()
         )}

      {:error, message} ->
        {:noreply, assign(socket, errors: [message])}
    end
  end

  def handle_event("cancel_preview", _params, socket),
    do: {:noreply, assign(socket, preview: nil, errors: [])}

  def handle_event("delete_list", %{"id" => id}, socket) do
    if socket.assigns.may_admin? do
      with {n, ""} <- Integer.parse(id),
           {:ok, list} <- RatingLists.delete_list(n) do
        {:noreply,
         assign(socket,
           notice: gettext("%{name} deleted.", name: list.name),
           lists: RatingLists.custom_lists()
         )}
      else
        _ ->
          {:noreply,
           assign(socket,
             errors: [gettext("That list no longer exists.")],
             lists: RatingLists.custom_lists()
           )}
      end
    else
      {:noreply, assign(socket, errors: [admin_only()])}
    end
  end

  # Rename: one row at a time turns into a small form. The id is what
  # sequences hold, so nothing a tournament reads changes but the label.
  def handle_event("rename_start", %{"id" => id}, socket) do
    with true <- socket.assigns.may_admin?,
         {n, ""} <- Integer.parse(id),
         %{} = list <- RatingLists.get_list(n) do
      {:noreply,
       assign(socket,
         renaming: list.id,
         rename_form: to_form(%{"name" => list.name}, as: :rename),
         rename_error: nil
       )}
    else
      false -> {:noreply, assign(socket, errors: [admin_only()])}
      _ -> {:noreply, list_gone(socket)}
    end
  end

  def handle_event("rename_cancel", _params, socket),
    do: {:noreply, assign(socket, renaming: nil, rename_error: nil)}

  def handle_event("rename_save", %{"rename" => %{"name" => name}}, socket) do
    with true <- socket.assigns.may_admin?,
         id when is_integer(id) <- socket.assigns.renaming do
      case RatingLists.rename_list(id, name) do
        {:ok, list, old_name} ->
          {:noreply,
           assign(socket,
             renaming: nil,
             rename_error: nil,
             notice:
               gettext(
                 "“%{old}” is now called “%{name}”. Tournaments that read it keep reading it.",
                 old: old_name,
                 name: list.name
               ),
             lists: RatingLists.custom_lists()
           )}

        {:error, :not_found} ->
          {:noreply, socket |> assign(renaming: nil) |> list_gone()}

        {:error, reason} ->
          {:noreply,
           assign(socket,
             rename_error: rename_error(reason),
             rename_form: to_form(%{"name" => name}, as: :rename)
           )}
      end
    else
      false -> {:noreply, assign(socket, errors: [admin_only()])}
      _ -> {:noreply, socket}
    end
  end

  defp list_gone(socket) do
    socket
    |> put_flash(:error, gettext("That list no longer exists."))
    |> assign(lists: RatingLists.custom_lists())
  end

  defp rename_error(:blank), do: gettext("Give the list a name.")
  defp rename_error(:too_long), do: gettext("The name is longer than 80 characters.")
  defp rename_error(:taken), do: gettext("Another list already has that name.")

  defp preview(socket, name, raw) do
    cond do
      name == "" ->
        assign(socket, errors: [gettext("Give the list a name.")], preview: nil)

      true ->
        case Csv.parse(raw) do
          {:ok, rows} ->
            assign(socket,
              errors: [],
              preview: %{
                name: name,
                rows: rows,
                sample: Enum.take(rows, @preview_rows),
                replaces: RatingLists.existing_list(name)
              }
            )

          {:error, errors} ->
            assign(socket, errors: errors, preview: nil)
        end
    end
  end

  defp admin_only, do: gettext("Loading rating lists needs an administrator.")

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
      active="fide"
    >
      <h1>{gettext("Rating lists")}</h1>

      <p class="subtitle">
        {gettext(
          "Rating lists of your own, loaded from a CSV file, to use beside the FIDE and national lists: they turn up when a player is added, and a tournament can put them in its rating-list sequence (Settings, FIDE). They are shared by every tournament on this machine."
        )}
      </p>

      <div :if={@notice} id="rating-list-notice" class="card ok-note" role="status">{@notice}</div>

      <div class="card" id="custom-rating-lists">
        <h2>{gettext("Loaded lists")}</h2>

        <p :if={@lists == []} id="no-custom-lists" class="hint">
          {gettext("No list of your own has been loaded.")}
        </p>

        <table :if={@lists != []} class="pe-table">
          <thead>
            <tr>
              <th>{gettext("Name")}</th>

              <th>{gettext("Players")}</th>

              <th><span class="sr-only">{gettext("Actions")}</span></th>
            </tr>
          </thead>

          <tbody>
            <tr :for={list <- @lists} id={"custom-list-#{list.id}"}>
              <td>
                <span :if={@renaming != list.id}>{list.name}</span>
                <.form
                  :if={@renaming == list.id}
                  for={@rename_form}
                  id={"rename-custom-list-form-#{list.id}"}
                  class="inline-rename"
                  phx-submit="rename_save"
                >
                  <input
                    type="text"
                    name={@rename_form[:name].name}
                    id={"rename-custom-list-name-#{list.id}"}
                    value={@rename_form[:name].value}
                    maxlength="80"
                    class="pe-input"
                    aria-label={gettext("New name for “%{name}”", name: list.name)}
                    phx-mounted={JS.focus()}
                  />
                  <button type="submit" class="pe-btn primary" id={"rename-custom-list-save-#{list.id}"}>
                    {gettext("Rename")}
                  </button>
                  <button type="button" class="pe-btn" phx-click="rename_cancel">
                    {gettext("Cancel")}
                  </button>
                  <p :if={@rename_error} id="rename-custom-list-error" class="error-note" role="alert">
                    {@rename_error}
                  </p>
                </.form>
              </td>

              <td>{list.entry_count}</td>

              <td style="text-align: right; white-space: nowrap">
                <button
                  :if={@may_admin? and @renaming != list.id}
                  type="button"
                  class="pe-btn"
                  id={"rename-custom-list-#{list.id}"}
                  phx-click="rename_start"
                  phx-value-id={list.id}
                >
                  {gettext("Rename")}
                </button>
                <button
                  :if={@may_admin?}
                  type="button"
                  class="pe-btn danger-link"
                  id={"delete-custom-list-#{list.id}"}
                  phx-click="delete_list"
                  phx-value-id={list.id}
                  data-confirm={
                    gettext(
                      "Delete “%{name}”? Tournaments that use it in their rating-list sequence drop it.",
                      name: list.name
                    )
                  }
                >
                  {gettext("Delete")}
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="card" id="custom-list-load">
        <h2>{gettext("Load a list")}</h2>

        <p class="hint" style="margin-top: 0">
          {gettext(
            "A CSV file whose first row names the columns: id, name and rating are required; federation, title, birth_year and fide_id are optional. The id is the list's own number for the player; fide_id, when given, shows the player beside the FIDE hit. Comma, semicolon or tab separated. A rating that is empty or 0 is unrated. Nothing is loaded unless every row is valid."
          )}
        </p>

        <p :if={!@may_admin?} class="hint">{admin_only()}</p>

        <form id="custom-list-form" phx-change="validate" phx-submit="preview">
          <label class="field">
            <span>{gettext("List name")}</span>
            <input
              id="custom-list-name"
              name="name"
              value={@name}
              maxlength="80"
              class="pe-input"
              disabled={!@may_admin?}
            />
          </label>

          <.live_file_input
            upload={@uploads.csv}
            id="custom-list-file"
            disabled={!@may_admin?}
            aria-label={gettext("Load a list")}
          />
          <p :for={msg <- UploadGuard.error_messages(@uploads.csv)} class="error-note">{msg}</p>

          <div class="actions">
            <button
              type="submit"
              id="custom-list-preview"
              class="pe-btn primary"
              disabled={!@may_admin?}
            >
              {gettext("Check the file")}
            </button>
          </div>
        </form>

        <div :if={@errors != []} id="custom-list-errors" class="error-note" role="alert">
          <p style="margin: 8px 0 4px">{gettext("The list was not loaded:")}</p>

          <ul style="margin: 0; padding-left: 20px">
            <li :for={msg <- @errors}>{msg}</li>
          </ul>
        </div>

        <div :if={@preview} id="custom-list-preview-card" style="margin-top: 12px">
          <p>
            {ngettext(
              "%{count} player found in the file.",
              "%{count} players found in the file.",
              length(@preview.rows)
            )}
          </p>

          <p :if={@preview.replaces} id="custom-list-replaces" class="pe-modal-warn">
            {gettext("A list called %{name} exists (%{count} players). Loading replaces it.",
              name: @preview.replaces.name,
              count: @preview.replaces.entry_count
            )}
          </p>

          <div class="card-table-wrap">
            <table class="pe-table" id="custom-list-sample">
              <thead>
                <tr>
                  <th>{gettext("Id")}</th>

                  <th>{gettext("Name")}</th>

                  <th>{gettext("Rating")}</th>

                  <th>{gettext("Federation")}</th>

                  <th>{gettext("Title")}</th>

                  <th>{gettext("Birth year")}</th>

                  <th>{gettext("FIDE ID")}</th>
                </tr>
              </thead>

              <tbody>
                <tr :for={row <- @preview.sample}>
                  <td>{row.ext_id}</td>

                  <td>{row.name}</td>

                  <td>{row.rating}</td>

                  <td>{row.federation}</td>

                  <td>{row.title}</td>

                  <td>{row.birth_year}</td>

                  <td>{row.fide_id}</td>
                </tr>
              </tbody>
            </table>
          </div>

          <div class="actions">
            <button
              type="button"
              id="custom-list-confirm"
              class="pe-btn primary"
              phx-click="confirm_import"
            >
              {gettext("Load the list")}
            </button>

            <button type="button" class="pe-btn" phx-click="cancel_preview">
              {gettext("Cancel")}
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
