defmodule PairingsEngineWeb.FideLive do
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.Accounts.User
  alias PairingsEngine.Kbsb
  alias PairingsEngine.Fide.Sync, as: FideSync
  alias PairingsEngine.Kbsb.Sync, as: KbsbSync

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, FideSync.topic())
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, KbsbSync.topic())
    end

    {:ok,
     socket
     |> assign(
       page_title: "Rating lists",
       status: FideSync.status(),
       kbsb_status: KbsbSync.status(),
       kbsb_query: "",
       kbsb_results: [],
       kbsb_error: nil,
       # Local self-registration is open to anyone — the full FIDE list
       # download (~41 MB, once a click) is exactly the kind of thing that's
       # cheap to trigger and expensive to serve, so it's restricted to
       # accounts we actually vouch for (SSO), same reasoning as
       # `PairingsEngine.Accounts.User.sso?/1`'s own moduledoc.
       sso?: User.sso?(socket.assigns.current_scope.user)
     )
     # There's no registered MIME type to filter on (the export format isn't
     # standardized — see docs/kbsb-sync.md), so accept anything and let the
     # parser reject anything that isn't a recognisable rating list.
     |> allow_upload(:kbsb_list, accept: :any, max_entries: 1, max_file_size: 25_000_000)}
  end

  @impl true
  def handle_info({:fide_sync, _state}, socket) do
    {:noreply, assign(socket, status: FideSync.status())}
  end

  def handle_info({:kbsb_sync, _state}, socket) do
    {:noreply, assign(socket, kbsb_status: KbsbSync.status())}
  end

  @impl true
  def handle_event("sync", _params, socket) do
    if socket.assigns.sso? do
      FideSync.start_sync()
      {:noreply, assign(socket, status: FideSync.status())}
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         "Downloading the full FIDE rating list is limited to SSO-signed-in accounts."
       )}
    end
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    if socket.assigns.sso? do
      FideSync.cancel_sync()
    end

    {:noreply, assign(socket, status: FideSync.status())}
  end

  def handle_event("validate_kbsb", _params, socket), do: {:noreply, socket}

  def handle_event("import_kbsb", _params, socket) do
    results =
      consume_uploaded_entries(socket, :kbsb_list, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end)

    case results do
      [binary] ->
        KbsbSync.start_import(binary)
        {:noreply, assign(socket, kbsb_status: KbsbSync.status(), kbsb_error: nil)}

      [] ->
        {:noreply, assign(socket, kbsb_error: "Choose a file first")}
    end
  end

  def handle_event("cancel_kbsb", _params, socket) do
    KbsbSync.cancel_import()
    {:noreply, assign(socket, kbsb_status: KbsbSync.status())}
  end

  def handle_event("kbsb_search", %{"q" => q}, socket) do
    {:noreply, assign(socket, kbsb_query: q, kbsb_results: Kbsb.search(q))}
  end

  defp busy?(%{status: s}), do: s in [:downloading, :importing]

  defp percent(%{status: :downloading, loaded_bytes: loaded, total_bytes: total})
       when total > 0 do
    Float.round(loaded / total * 100, 1)
  end

  defp percent(%{status: :importing, imported_rows: done, total_rows: total}) when total > 0 do
    Float.round(done / total * 100, 1)
  end

  defp percent(_), do: nil

  defp format_count(n) do
    n |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active="fide">
      <h1>Rating lists</h1>
      <p class="subtitle">
        Local copies of the FIDE and Belgian national (KBSB/FRBE) rating lists, used to look up
        players when registering them.
      </p>

      <div class="card">
        <h2>FIDE database</h2>
        <p>
          <strong>{format_count(@status.player_count)}</strong>
          players in the local database.
          <%= if @status.last_sync do %>
            Last updated: <strong>{@status.last_sync}</strong> (UTC).
          <% else %>
            The database is empty - download the rating list to get started.
          <% end %>
        </p>

        <div :if={busy?(@status)} class="progress-block">
          <div class="progress-track">
            <div
              class={["progress-fill", percent(@status) == nil && "indeterminate"]}
              style={percent(@status) && "width: #{percent(@status)}%"}
            />
          </div>
          <p class="ok-note">{if @status.progress != "", do: @status.progress, else: "Working…"}</p>
        </div>
        <p :if={@status.status == :error} class="error-note">
          Update failed: {@status.error}
        </p>

        <p class="hint">
          FIDE publishes a new list every month (~1.9 million players, download is around 41 MB).
          Updating takes a minute or two.
        </p>
        <p :if={!@sso?} class="hint">
          Downloading the full list is limited to SSO-signed-in accounts, so it can't be
          triggered by just anyone with a local account.
        </p>
        <div class="actions">
          <button
            class="pe-btn primary"
            phx-click="sync"
            disabled={busy?(@status) or !@sso?}
            title={if !@sso?, do: "Sign in with SSO to update the FIDE rating list"}
          >
            {cond do
              busy?(@status) -> "Updating…"
              @status.player_count > 0 -> "Update from FIDE"
              true -> "Download rating list"
            end}
          </button>
          <button :if={busy?(@status) and @sso?} class="pe-btn" phx-click="cancel">
            Cancel
          </button>
        </div>
      </div>

      <div class="card">
        <h2>Belgian national rating list (KBSB/FRBE)</h2>
        <p>
          <strong>{format_count(@kbsb_status.player_count)}</strong>
          players in the local database.
          <%= if @kbsb_status.last_sync do %>
            Last updated: <strong>{@kbsb_status.last_sync}</strong> (UTC).
          <% else %>
            The database is empty - upload a rating-list file to get started.
          <% end %>
        </p>

        <p class="hint">
          KBSB/FRBE doesn't publish a stable automatic download (see docs/kbsb-sync.md), so upload
          the official rating-list export by hand. Uploading a new file replaces the local copy.
        </p>

        <form
          id="kbsb-import-form"
          phx-submit="import_kbsb"
          phx-change="validate_kbsb"
          phx-drop-target={@uploads.kbsb_list.ref}
        >
          <div class={["dropzone", @uploads.kbsb_list.entries != [] && "has-file"]}>
            <.live_file_input upload={@uploads.kbsb_list} class="dropzone-input" />
            <div class="dropzone-label">
              <%= if @uploads.kbsb_list.entries == [] do %>
                <strong>Choose the KBSB rating-list file</strong>
                <span class="hint">or drag and drop it here</span>
              <% else %>
                <span :for={entry <- @uploads.kbsb_list.entries} class="dropzone-file">
                  {entry.client_name}
                </span>
              <% end %>
            </div>
          </div>
          <p :for={err <- upload_errors(@uploads.kbsb_list)} class="error-note">{inspect(err)}</p>

          <div :if={busy?(@kbsb_status)} class="progress-block">
            <div class="progress-track">
              <div
                class={["progress-fill", percent(@kbsb_status) == nil && "indeterminate"]}
                style={percent(@kbsb_status) && "width: #{percent(@kbsb_status)}%"}
              />
            </div>
            <p class="ok-note">
              {if @kbsb_status.progress != "", do: @kbsb_status.progress, else: "Working…"}
            </p>
          </div>
          <p :if={@kbsb_status.status == :error} class="error-note">
            Import failed: {@kbsb_status.error}
          </p>
          <p :if={@kbsb_error} class="error-note">{@kbsb_error}</p>

          <div class="actions">
            <button type="submit" class="pe-btn primary" disabled={busy?(@kbsb_status)}>
              {if busy?(@kbsb_status), do: "Importing…", else: "Import file"}
            </button>
            <button :if={busy?(@kbsb_status)} type="button" class="pe-btn" phx-click="cancel_kbsb">
              Cancel
            </button>
          </div>
        </form>

        <div class="field search-wrap" style="margin-top: 16px">
          <span style="display:block;font-size:13px;font-weight:600;color:var(--text-soft);margin-bottom:4px">
            Search the local KBSB database (national ID or last name)
          </span>
          <input
            type="text"
            name="q"
            value={@kbsb_query}
            phx-change="kbsb_search"
            phx-debounce="250"
            autocomplete="off"
            placeholder="Start typing a last name or matricule…"
            class="pe-input"
          />
          <div :if={@kbsb_results != []} class="search-results">
            <div :for={kp <- @kbsb_results} class="kbsb-result-row">
              <span>{kp.last_name}{if kp.first_name != "", do: ", #{kp.first_name}"}</span>
              <span class="meta">
                {kp.national_id} · {kp.club_name} · {kp.national_rating || "unrated"}{if kp.fide_id,
                  do: " · FIDE #{kp.fide_id}"}
              </span>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
