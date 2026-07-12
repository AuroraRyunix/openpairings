defmodule PairingsEngineWeb.TournamentsLive do
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{Tournaments, SwarImport, TournamentImport}
  alias PairingsEngine.Tournaments.Tournament

  # Kept in sync with SettingsLive's own copies (SWAR TournoiStd / Cadence).
  @standard_options [
    {"standard", "Standard"},
    {"rapid", "Rapid"},
    {"blitz", "Blitz"}
  ]

  @rate_of_play_options [
    "",
    "105 min/40 moves + 15 min. QPF",
    "90 min/40 moves + 30 min + 30 sec/move",
    "90 min + 30 sec/move",
    "60 min QPF",
    "25 min + 10 sec/move",
    "15 min + 5 sec/move",
    "5 min + 3 sec/move",
    "3 min + 2 sec/move"
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(
        PairingsEngine.PubSub,
        Tournaments.user_tournaments_topic(socket.assigns.current_scope.user.id)
      )
    end

    {:ok,
     socket
     |> assign(
       page_title: "Tournaments",
       creating: false,
       importing: false,
       importing_backup: false,
       error: nil,
       delete_target: nil,
       delete_confirm_text: ""
     )
     # ".swar" has no registered MIME type, so the browser-side accept filter
     # can't be used; the binary parser rejects anything that isn't SWAR anyway.
     |> allow_upload(:swar, accept: :any, max_entries: 1, max_file_size: 5_000_000)
     |> allow_upload(:backup, accept: ~w(.json), max_entries: 1, max_file_size: 25_000_000)
     |> assign_tournaments()
     |> assign_pending_invitations()}
  end

  # Refresh the list only — the delete-confirmation modal (if open) keeps
  # its own `delete_target`/`delete_confirm_text` assigns untouched, since
  # `assign_tournaments/1` only ever sets `:tournaments`.
  #
  # `add_collaborator/3`, `accept_invitation/2` and `decline_invitation/2`
  # all broadcast on this same `:tournaments_changed` topic (the invitee's
  # own user-tournaments topic), so both the tournament list and the
  # "Pending invitations" section stay live without a separate subscription.
  @impl true
  def handle_info({:tournaments_changed, _user_id}, socket) do
    {:noreply, socket |> assign_tournaments() |> assign_pending_invitations()}
  end

  defp assign_tournaments(socket) do
    assign(socket, :tournaments, Tournaments.list_tournaments(socket.assigns.current_scope))
  end

  defp assign_pending_invitations(socket) do
    assign(socket, :pending_invitations, Tournaments.list_pending_invitations(socket.assigns.current_scope))
  end

  ## ---------- Pending invitations (accept/decline from the list page) ----------

  def handle_event("accept_invite", %{"token" => token}, socket) do
    case Tournaments.accept_invitation(socket.assigns.current_scope, token) do
      {:ok, collaborator} ->
        {:noreply,
         socket
         |> put_flash(:info, "Invitation accepted.")
         |> push_navigate(to: ~p"/t/#{collaborator.tournament_id}/players")}

      {:error, _reason} ->
        {:noreply, socket |> assign_tournaments() |> assign_pending_invitations()}
    end
  end

  def handle_event("decline_invite", %{"token" => token}, socket) do
    case Tournaments.decline_invitation(socket.assigns.current_scope, token) do
      {:ok, _collaborator} -> {:noreply, assign_pending_invitations(socket)}
      {:error, _reason} -> {:noreply, assign_pending_invitations(socket)}
    end
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, assign(socket, creating: true, importing: false)}
  end

  def handle_event("import", _params, socket) do
    {:noreply, assign(socket, importing: true, creating: false, importing_backup: false)}
  end

  def handle_event("import_backup", _params, socket) do
    {:noreply, assign(socket, importing_backup: true, creating: false, importing: false)}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, creating: false, importing: false, importing_backup: false, error: nil)}
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

  ## ---------- JSON backup import (full-fidelity, single or all tournaments) ----------

  # The file input's phx-change target; nothing to do until submit.
  def handle_event("validate_backup", _params, socket), do: {:noreply, socket}

  def handle_event("import_backup_file", _params, socket) do
    scope = socket.assigns.current_scope

    results =
      consume_uploaded_entries(socket, :backup, fn %{path: path}, _entry ->
        {:ok, decode_and_import(path, scope)}
      end)

    case results do
      [{:ok, imported}] ->
        count = length(imported)

        {:noreply,
         socket
         |> put_flash(:info, "Imported #{count} tournament#{if count != 1, do: "s"}.")
         |> assign(importing_backup: false, error: nil)
         |> assign_tournaments()}

      [{:error, reason}] ->
        {:noreply, assign(socket, error: reason)}

      [] ->
        {:noreply, assign(socket, error: "Choose a .json export file first")}
    end
  end

  ## ---------- Delete tournament (with type-DELETE-to-confirm modal) ----------

  def handle_event("delete_start", %{"id" => id}, socket) do
    tournament = Tournaments.get_user_tournament!(socket.assigns.current_scope, id)
    {:noreply, assign(socket, delete_target: tournament, delete_confirm_text: "")}
  end

  def handle_event("delete_cancel", _params, socket) do
    {:noreply, assign(socket, delete_target: nil, delete_confirm_text: "")}
  end

  def handle_event("delete_confirm_input", %{"confirm" => value}, socket) do
    {:noreply, assign(socket, delete_confirm_text: value)}
  end

  def handle_event("delete_confirmed", _params, socket) do
    case socket.assigns do
      %{delete_target: %Tournament{} = tournament, delete_confirm_text: "DELETE"} ->
        {:ok, _} = Tournaments.delete_tournament(tournament)

        {:noreply,
         socket
         |> assign(delete_target: nil, delete_confirm_text: "")
         |> assign_tournaments()}

      _ ->
        {:noreply, socket}
    end
  end

  defp decode_and_import(path, scope) do
    with {:ok, content} <- File.read(path),
         {:ok, data} <- Jason.decode(content) do
      TournamentImport.import(data, scope)
    else
      {:error, %Jason.DecodeError{}} -> {:error, "This file is not valid JSON"}
      {:error, reason} -> {:error, "Could not read this file: #{inspect(reason)}"}
    end
  end

  defp error_text(changeset) do
    Enum.map_join(changeset.errors, ", ", fn {field, {msg, _}} -> "#{field} #{msg}" end)
  end

  defp standard_options, do: @standard_options
  defp rate_of_play_options, do: @rate_of_play_options

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
          <a class="pe-btn" href={~p"/export/tournaments.json"} target="_blank">Export all (JSON)</a>
          <button :if={!@importing_backup} class="pe-btn" phx-click="import_backup">
            Import backup (JSON)
          </button>
          <button :if={!@importing} class="pe-btn" phx-click="import">Import SWAR file</button>
          <button :if={!@creating} class="pe-btn primary" phx-click="new">New tournament</button>
        </div>
      </div>

      <div :if={@pending_invitations != []} class="card">
        <h2>Pending invitations</h2>
        <p class="hint" style="margin-top: 0">
          Someone has invited you to collaborate on these tournaments. Accepting gives you full
          editing access; declining removes the invitation.
        </p>
        <div class="card-table-wrap">
          <table class="pe-table">
            <thead>
              <tr>
                <th>Tournament</th>
                <th>Invited by</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={%{collaborator: c, tournament: t, owner_email: owner_email} <- @pending_invitations}>
                <td><strong>{t.name}</strong></td>
                <td>{owner_email}</td>
                <td style="text-align: right">
                  <button class="pe-btn primary" phx-click="accept_invite" phx-value-token={c.invite_token}>
                    Accept
                  </button>
                  <button class="pe-btn danger-link" phx-click="decline_invite" phx-value-token={c.invite_token}>
                    Decline
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
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
          <label class="field">
            <span>Place</span>
            <input name="tournament[city]" placeholder="e.g. Gent" />
          </label>
          <label class="field">
            <span>Date from</span>
            <input type="date" name="tournament[start_date]" />
          </label>
          <label class="field">
            <span>Date to</span>
            <input type="date" name="tournament[end_date]" />
          </label>
          <div class="field">
            <span>Standard</span>
            <div style="display: flex; gap: 1rem; flex-wrap: wrap; align-items: center">
              <label :for={{val, label} <- standard_options()} style="display: flex; gap: .35rem; align-items: center; font-weight: 400">
                <input type="radio" name="tournament[standard]" value={val} checked={val == "standard"} /> {label}
              </label>
            </div>
          </div>
          <label class="field">
            <span>Rate of play</span>
            <select name="tournament[rate_of_play]">
              <option :for={opt <- rate_of_play_options()} value={opt}>
                {if opt == "", do: "— none —", else: opt}
              </option>
            </select>
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
        <div class={["dropzone", @uploads.swar.entries != [] && "has-file"]} phx-drop-target={@uploads.swar.ref}>
          <.live_file_input upload={@uploads.swar} class="dropzone-input" />
          <div class="dropzone-label">
            <%= if @uploads.swar.entries == [] do %>
              <strong>Choose a .swar file</strong>
              <span class="hint">or drag and drop it here</span>
            <% else %>
              <span :for={entry <- @uploads.swar.entries} class="dropzone-file">
                {entry.client_name}
              </span>
            <% end %>
          </div>
        </div>
        <p :for={err <- upload_errors(@uploads.swar)} class="error-note">{inspect(err)}</p>
        <p :if={@error} class="error-note">{@error}</p>
        <div class="actions">
          <button type="submit" class="pe-btn primary">Import</button>
          <button type="button" class="pe-btn" phx-click="cancel">Cancel</button>
        </div>
      </form>

      <form
        :if={@importing_backup}
        id="backup-import-form"
        class="card"
        phx-submit="import_backup_file"
        phx-change="validate_backup"
      >
        <h2>Import an OpenPairings backup</h2>
        <p class="hint" style="margin-top: 0">
          Pick a <code>.json</code> file exported from
          <em>Settings → Export / backup</em>
          or <em>Export all (JSON)</em> — every tournament it contains is imported as a brand-new
          tournament owned by you, with all players, rounds and results intact. This never
          overwrites an existing tournament.
        </p>
        <div class={["dropzone", @uploads.backup.entries != [] && "has-file"]} phx-drop-target={@uploads.backup.ref}>
          <.live_file_input upload={@uploads.backup} class="dropzone-input" />
          <div class="dropzone-label">
            <%= if @uploads.backup.entries == [] do %>
              <strong>Choose a .json backup file</strong>
              <span class="hint">or drag and drop it here</span>
            <% else %>
              <span :for={entry <- @uploads.backup.entries} class="dropzone-file">
                {entry.client_name}
              </span>
            <% end %>
          </div>
        </div>
        <p :for={err <- upload_errors(@uploads.backup)} class="error-note">{inspect(err)}</p>
        <p :if={@error} class="error-note">{@error}</p>
        <div class="actions">
          <button type="submit" class="pe-btn primary">Import</button>
          <button type="button" class="pe-btn" phx-click="cancel">Cancel</button>
        </div>
      </form>

      <div :if={@tournaments == [] && !@creating && !@importing && !@importing_backup} class="card empty">
        <p><strong>No tournaments yet.</strong></p>
        <p>Create your first tournament, or import one from SWAR or a backup.</p>
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
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{t, player_count, owned?} <- @tournaments}>
              <td>
                <.link navigate={~p"/t/#{t.id}/players"}><strong>{t.name}</strong></.link>
                <span :if={!owned?} class="badge muted" title="Shared with you by its owner">shared</span>
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
              <td style="text-align: right">
                <a class="pe-btn" href={~p"/t/#{t.id}/export/json"} target="_blank">Export</a>
                <button :if={owned?} class="pe-btn danger-link" phx-click="delete_start" phx-value-id={t.id}>
                  Delete
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <.delete_tournament_modal
        :if={@delete_target}
        tournament={@delete_target}
        confirm_text={@delete_confirm_text}
      />
    </Layouts.app>
    """
  end

  attr :tournament, Tournament, required: true
  attr :confirm_text, :string, required: true

  defp delete_tournament_modal(assigns) do
    ~H"""
    <div class="modal-overlay" phx-click="delete_cancel" phx-window-keydown="delete_cancel" phx-key="escape">
      <div class="modal-card" onclick="event.stopPropagation()" style="max-width: 440px">
        <h2>Delete tournament</h2>
        <p>
          This permanently deletes <strong>{@tournament.name}</strong>
          and all of its players, rounds and results. This cannot be undone.
        </p>
        <label class="field">
          <span>Type DELETE to confirm</span>
          <input
            name="confirm"
            value={@confirm_text}
            phx-change="delete_confirm_input"
            autocomplete="off"
            phx-mounted={JS.focus()}
          />
        </label>
        <div class="actions">
          <button
            type="button"
            class="pe-btn danger"
            phx-click="delete_confirmed"
            disabled={@confirm_text != "DELETE"}
          >
            Delete tournament
          </button>
          <button type="button" class="pe-btn" phx-click="delete_cancel">Cancel</button>
        </div>
      </div>
    </div>
    """
  end
end
