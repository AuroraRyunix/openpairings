defmodule PairingsEngineWeb.TournamentsLive do
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{Tournaments, SwarImport}
  alias PairingsEngine.Tournaments.Tournament

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Tournaments", creating: false, importing: false, error: nil)
     # ".swar" has no registered MIME type, so the browser-side accept filter
     # can't be used; the binary parser rejects anything that isn't SWAR anyway.
     |> allow_upload(:swar, accept: :any, max_entries: 1, max_file_size: 5_000_000)
     |> assign_tournaments()}
  end

  defp assign_tournaments(socket) do
    assign(socket, :tournaments, Tournaments.list_tournaments(socket.assigns.current_scope))
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, assign(socket, creating: true, importing: false)}
  end

  def handle_event("import", _params, socket) do
    {:noreply, assign(socket, importing: true, creating: false)}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, creating: false, importing: false, error: nil)}
  end

  def handle_event("create", %{"tournament" => params}, socket) do
    case Tournaments.create_tournament(socket.assigns.current_scope, params) do
      {:ok, tournament} ->
        {:noreply, push_navigate(socket, to: ~p"/t/#{tournament.id}/players")}

      {:error, changeset} ->
        {:noreply, assign(socket, error: error_text(changeset))}
    end
  end

  # The file input's phx-change target; nothing to do until submit.
  def handle_event("validate_swar", _params, socket), do: {:noreply, socket}

  def handle_event("import_swar", _params, socket) do
    scope = socket.assigns.current_scope

    results =
      consume_uploaded_entries(socket, :swar, fn %{path: path}, _entry ->
        {:ok, SwarImport.import_file(path, scope)}
      end)

    case results do
      [{:ok, tournament}] ->
        {:noreply, push_navigate(socket, to: ~p"/t/#{tournament.id}/standings")}

      [{:error, reason}] ->
        {:noreply, assign(socket, error: "Could not read this SWAR file: #{inspect(reason)}")}

      [] ->
        {:noreply, assign(socket, error: "Choose a .swar file first")}
    end
  end

  defp error_text(changeset) do
    Enum.map_join(changeset.errors, ", ", fn {field, {msg, _}} -> "#{field} #{msg}" end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active="tournaments">
      <div class="page-header">
        <div>
          <h1>Tournaments</h1>
          <p class="subtitle">Everything you are organising, most recent first.</p>
        </div>
        <div class="actions" style="margin: 0">
          <button :if={!@importing} class="pe-btn" phx-click="import">Import SWAR file</button>
          <button :if={!@creating} class="pe-btn primary" phx-click="new">New tournament</button>
        </div>
      </div>

      <form :if={@creating} class="card" phx-submit="create">
        <h2>New tournament</h2>
        <div class="form-grid">
          <label class="field">
            <span>Name</span>
            <input name="tournament[name]" autofocus placeholder="e.g. Summer Open 2026" />
          </label>
          <label class="field">
            <span>Pairing system</span>
            <select name="tournament[type]">
              <option :for={type <- Tournament.types()} value={type}>
                {Tournament.type_label(type)}
              </option>
            </select>
          </label>
          <label class="field">
            <span>Rounds</span>
            <input type="number" name="tournament[rounds_count]" value="9" min="1" max="30" />
          </label>
        </div>
        <p :if={@error} class="error-note">{@error}</p>
        <div class="actions">
          <button type="submit" class="pe-btn primary">Create tournament</button>
          <button type="button" class="pe-btn" phx-click="cancel">Cancel</button>
        </div>
      </form>

      <form :if={@importing} class="card" phx-submit="import_swar" phx-change="validate_swar">
        <h2>Import a SWAR tournament</h2>
        <p class="hint" style="margin-top: 0">
          Pick a <code>.swar</code> file — the tournament, its players, rounds and results
          are imported and become yours to continue here.
        </p>
        <.live_file_input upload={@uploads.swar} />
        <p :for={err <- upload_errors(@uploads.swar)} class="error-note">{inspect(err)}</p>
        <p :if={@error} class="error-note">{@error}</p>
        <div class="actions">
          <button type="submit" class="pe-btn primary">Import</button>
          <button type="button" class="pe-btn" phx-click="cancel">Cancel</button>
        </div>
      </form>

      <div :if={@tournaments == [] && !@creating && !@importing} class="card empty">
        <p><strong>No tournaments yet.</strong></p>
        <p>Create your first tournament, or import one from SWAR.</p>
      </div>

      <div :if={@tournaments != []} class="card table-card">
        <table class="pe-table">
          <thead>
            <tr>
              <th>Name</th>
              <th>System</th>
              <th class="num">Rounds</th>
              <th class="num">Players</th>
              <th>Dates</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{t, player_count} <- @tournaments}>
              <td>
                <.link navigate={~p"/t/#{t.id}/players"}><strong>{t.name}</strong></.link>
              </td>
              <td>{Tournament.type_label(t.type)}</td>
              <td class="num">{t.rounds_count}</td>
              <td class="num">{player_count}</td>
              <td>
                {if t.start_date == "", do: "—", else: t.start_date}{if t.end_date != "",
                  do: " → #{t.end_date}"}
              </td>
              <td>
                <span class={["badge", t.status == "setup" && "muted"]}>{t.status}</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end
end
