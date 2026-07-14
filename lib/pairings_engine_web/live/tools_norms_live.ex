defmodule PairingsEngineWeb.ToolsNormsLive do
  @moduledoc """
  The public, no-login arbiter tools page — `/tools/norms` (see
  docs/tools.md). Lets an arbiter with no OpenPairings account drop one or
  more `.swar`/`.trf` files and download the IT3/FA1/IA1 FIDE report forms
  straight from them, without ever creating a tournament here.

  Parsing goes through `PairingsEngine.Tools.Parser` (dispatches on filename
  extension to `PairingsEngine.SwarImport.build_structs/1` /
  `PairingsEngine.TrfImport.build_structs/1` — both pure, no `Repo` calls).
  Two or more successfully parsed files can be combined into one "Festival"
  report via `PairingsEngine.Norms.Combine`, same as the authenticated Norms
  page would need a real multi-tournament event for.

  Nothing here is ever written to the database. This LiveView's own assigns
  (`:files`, `:master_index`, `:overlay`, `:candidate`) are mirrored into
  `PairingsEngine.Tools.Session` — a plain in-memory ETS store, keyed by a
  random `:token` generated at `mount/3` — on every change, so that
  `PairingsEngineWeb.ToolsController`'s plain `GET` download routes (a
  different process from this LiveView) can look the parsed data back up by
  token. Uploaded file bytes themselves are read via
  `consume_uploaded_entries/3` straight into memory and never touch this
  LiveView's assigns or the session store — only the parsed
  `%Tournament{}`/`%Player{}` structs do.
  """

  use PairingsEngineWeb, :live_view

  alias PairingsEngine.Tools.{Parser, Session}

  @max_entries 10
  @max_file_size 5_000_000

  @overlay_fields ~w(chief_arbiter_name chief_arbiter_fide_id organizer event_code
                      deputy1_name deputy1_fide_id deputy2_name deputy2_fide_id
                      deputy3_name deputy3_fide_id deputy4_name deputy4_fide_id)
  @candidate_fields ~w(last_name first_name fide_id federation)

  @impl true
  def mount(_params, _session, socket) do
    overlay = empty_fields(@overlay_fields)
    candidate = empty_fields(@candidate_fields)

    # Only the connected mount claims a session entry — the static render
    # never shows a download link (no files can have been parsed yet), so a
    # disconnected-mount token would just be an orphan ETS entry.
    token =
      if connected?(socket) do
        Session.put(session_payload(%{files: [], master_index: 0}, overlay, candidate))
      end

    {:ok,
     socket
     |> assign(
       page_title: "Arbiter tools — Norms",
       token: token,
       files: [],
       master_index: 0,
       overlay: overlay,
       candidate: candidate
     )
     |> allow_upload(:files,
       accept: :any,
       max_entries: @max_entries,
       max_file_size: @max_file_size
     )}
  end

  ## ---------- events ----------

  # The file input's phx-change target; nothing to do until submit — same
  # no-op pattern TournamentsLive's own SWAR/TRF/backup inputs use.
  @impl true
  def handle_event("validate_files", _params, socket), do: {:noreply, socket}

  def handle_event("parse_files", _params, socket) do
    new_rows =
      consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
        content = File.read!(path)
        {:ok, parse_row(entry.client_name, content)}
      end)

    files = socket.assigns.files ++ new_rows

    {:noreply, socket |> assign(files: files) |> sync_session()}
  end

  def handle_event("remove_file", %{"id" => id}, socket) do
    files = Enum.reject(socket.assigns.files, &(&1.id == id))
    master_index = clamp_master_index(socket.assigns.master_index, successful(files))

    {:noreply, socket |> assign(files: files, master_index: master_index) |> sync_session()}
  end

  def handle_event("set_master", %{"index" => index}, socket) do
    {:noreply, socket |> assign(master_index: String.to_integer(index)) |> sync_session()}
  end

  def handle_event("update_fields", params, socket) do
    overlay = Map.merge(socket.assigns.overlay, Map.get(params, "overlay", %{}))
    candidate = Map.merge(socket.assigns.candidate, Map.get(params, "candidate", %{}))

    {:noreply, socket |> assign(overlay: overlay, candidate: candidate) |> sync_session()}
  end

  ## ---------- parsing ----------

  defp parse_row(filename, content) do
    case Parser.parse(filename, content) do
      {:ok, {tournament, players}} ->
        %{id: row_id(), filename: filename, tournament: tournament, players: players, error: nil}

      {:error, message} ->
        %{id: row_id(), filename: filename, tournament: nil, players: nil, error: message}
    end
  end

  defp row_id, do: System.unique_integer([:positive, :monotonic]) |> Integer.to_string()

  defp successful(files), do: Enum.filter(files, &is_nil(&1.error))

  defp failed(files), do: Enum.reject(files, &is_nil(&1.error))

  defp clamp_master_index(_index, []), do: 0
  defp clamp_master_index(index, files), do: index |> max(0) |> min(length(files) - 1)

  ## ---------- session sync ----------

  defp sync_session(socket) do
    Session.put(
      socket.assigns.token,
      session_payload(
        %{files: socket.assigns.files, master_index: socket.assigns.master_index},
        socket.assigns.overlay,
        socket.assigns.candidate
      )
    )

    socket
  end

  defp session_payload(%{files: files, master_index: master_index}, overlay, candidate) do
    %{files: files, master_index: master_index, overlay: overlay, candidate: candidate}
  end

  defp empty_fields(keys), do: Map.new(keys, &{&1, ""})

  ## ---------- view helpers ----------

  defp rounds_label(%{rounds_count: n}), do: n

  defp upload_error_label(:too_large), do: "File is larger than 5 MB"
  defp upload_error_label(:too_many_files), do: "Too many files — 10 at a time, max"
  defp upload_error_label(:not_accepted), do: "That file type isn't accepted"
  defp upload_error_label(other), do: inspect(other)

  attr :field, :string, required: true
  attr :label, :string, required: true
  attr :values, :map, required: true
  attr :prefix, :string, required: true

  defp overlay_input(assigns) do
    ~H"""
    <label class="field">
      <span>{@label}</span>
      <input name={"#{@prefix}[#{@field}]"} value={Map.get(@values, @field, "")} />
    </label>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active="tools">
      <div class="page-header">
        <div>
          <h1>Arbiter tools</h1>
          <p class="subtitle" style="margin: 0">
            Upload a SWAR or TRF file, no account needed — download the IT3/FA1/IA1 FIDE report forms.
          </p>
        </div>
      </div>

      <p class="hint">
        Nothing here is saved: uploaded files are parsed in memory only, never written to a
        database, and this whole session (files, officials, arbiter candidate) is discarded after
        60 minutes of inactivity or as soon as you close the tab and come back later. See
        <.link navigate={~p"/"}>OpenPairings</.link>
        if you'd rather manage a tournament with an account.
      </p>

      <form
        id="tools-upload-form"
        class="card"
        phx-submit="parse_files"
        phx-change="validate_files"
      >
        <h2>Upload files</h2>
        <p class="hint" style="margin-top: 0">
          Up to 10 files, 5 MB each — <code>.swar</code> or <code>.trf</code>. Two or more files
          combine into one "Festival" report (see below).
        </p>

        <div class={["dropzone", @uploads.files.entries != [] && "has-file"]} phx-drop-target={@uploads.files.ref}>
          <.live_file_input upload={@uploads.files} class="dropzone-input" />
          <div class="dropzone-label">
            <%= if @uploads.files.entries == [] do %>
              <strong>Choose SWAR/TRF files</strong> <span class="hint">or drag and drop them here</span>
            <% else %>
              <span :for={entry <- @uploads.files.entries} class="dropzone-file">
                {entry.client_name}
              </span>
            <% end %>
          </div>
        </div>

        <p :for={err <- upload_errors(@uploads.files)} class="error-note">{upload_error_label(err)}</p>
        <div :for={entry <- @uploads.files.entries}>
          <p :for={err <- upload_errors(@uploads.files, entry)} class="error-note">
            {entry.client_name}: {upload_error_label(err)}
          </p>
        </div>

        <div class="actions">
          <button type="submit" class="pe-btn primary" disabled={@uploads.files.entries == []}>
            Parse files
          </button>
        </div>
      </form>

      <div :if={@files != []} class="card table-card">
        <h2 style="padding: 16px 16px 0">Uploaded files</h2>
        <table class="pe-table">
          <thead>
            <tr>
              <th :if={successful(@files) |> length() >= 2}>Master</th>
              <th>File</th>
              <th>Tournament</th>
              <th class="num">Players</th>
              <th class="num">Rounds</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{row, idx} <- Enum.with_index(successful(@files))}>
              <td :if={successful(@files) |> length() >= 2}>
                <input
                  type="radio"
                  name="master_index"
                  checked={@master_index == idx}
                  phx-click="set_master"
                  phx-value-index={idx}
                />
              </td>
              <td>{row.filename}</td>
              <td>{row.tournament.name}</td>
              <td class="num">{length(row.players)}</td>
              <td class="num">{rounds_label(row.tournament)}</td>
              <td style="text-align: right">
                <button class="pe-btn danger-link" phx-click="remove_file" phx-value-id={row.id}>
                  Remove
                </button>
              </td>
            </tr>
            <tr :for={row <- failed(@files)}>
              <td :if={successful(@files) |> length() >= 2}></td>
              <td>{row.filename}</td>
              <td colspan="3" class="error-note">{row.error}</td>
              <td style="text-align: right">
                <button class="pe-btn danger-link" phx-click="remove_file" phx-value-id={row.id}>
                  Remove
                </button>
              </td>
            </tr>
          </tbody>
        </table>

        <p :if={successful(@files) |> length() >= 2} class="hint" style="padding: 0 16px 16px">
          These {successful(@files) |> length()} files combine into one "Festival" report — the
          master file supplies the name/dates/venue/officials, players from every file are pooled,
          and the same player can't appear in more than one of them.
        </p>
      </div>

      <div :if={successful(@files) != []} class="card">
        <h2>Officials &amp; arbiter candidate</h2>
        <p class="hint" style="margin-top: 0">
          Fill in anything the uploaded file(s) don't already carry — nothing here is saved either.
        </p>

        <form id="tools-fields-form" phx-change="update_fields">
          <div class="form-grid">
            <.overlay_input prefix="overlay" field="chief_arbiter_name" label="Chief arbiter — name" values={@overlay} />
            <.overlay_input prefix="overlay" field="chief_arbiter_fide_id" label="Chief arbiter — FIDE ID" values={@overlay} />
            <.overlay_input prefix="overlay" field="organizer" label="Organizer" values={@overlay} />
            <.overlay_input prefix="overlay" field="event_code" label="FIDE event code" values={@overlay} />
          </div>

          <h3 style="margin-bottom: 4px">Deputy arbiters</h3>
          <div :for={n <- 1..4} class="form-grid">
            <.overlay_input prefix="overlay" field={"deputy#{n}_name"} label={"Deputy #{n} — name"} values={@overlay} />
            <.overlay_input prefix="overlay" field={"deputy#{n}_fide_id"} label={"Deputy #{n} — FIDE ID"} values={@overlay} />
          </div>

          <h3 style="margin-bottom: 4px">FA1 / IA1 arbiter norm candidate</h3>
          <div class="form-grid">
            <.overlay_input prefix="candidate" field="last_name" label="Last name" values={@candidate} />
            <.overlay_input prefix="candidate" field="first_name" label="First name" values={@candidate} />
            <.overlay_input prefix="candidate" field="fide_id" label="FIDE ID" values={@candidate} />
            <.overlay_input prefix="candidate" field="federation" label="Federation" values={@candidate} />
          </div>
        </form>
      </div>

      <div :if={successful(@files) != []} class="card">
        <h2>Download</h2>
        <div class="actions">
          <a class="pe-btn primary" href={~p"/tools/download/#{@token}/it3"}>Download IT3</a>
          <a class="pe-btn primary" href={~p"/tools/download/#{@token}/fa1"}>Download FA1 (FIDE Arbiter)</a>
          <a class="pe-btn primary" href={~p"/tools/download/#{@token}/ia1"}>Download IA1 (International Arbiter)</a>
        </div>
      </div>

      <footer class="hint" style="text-align: center; margin: 32px 0 8px">
        <.link navigate={~p"/"}>OpenPairings</.link>
        — the full free tournament manager these forms come from.
      </footer>
    </Layouts.app>
    """
  end
end
