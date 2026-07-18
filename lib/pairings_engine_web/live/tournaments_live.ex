defmodule PairingsEngineWeb.TournamentsLive do
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{Audit, Tournaments, SwarImport, TournamentImport, TrfImport}
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

  @pairing_system_options for ps <- Tournament.pairing_systems(),
                              do: {ps, Tournament.pairing_system_label(ps)}
  @rr_cycles_options for c <- Tournament.rr_cycles_values(),
                         do: {c, Tournament.rr_cycles_label(c)}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(
        PairingsEngine.PubSub,
        Tournaments.user_tournaments_topic(socket.assigns.current_scope.user.id)
      )
    end

    # Lazy sweep: purge any recycle-bin tournament past its 3-month
    # retention on every page load, rather than on a schedule — see
    # `Tournaments.purge_expired_tournaments/0`.
    Tournaments.purge_expired_tournaments()

    {:ok,
     socket
     |> assign(
       page_title: "Tournaments",
       creating: false,
       importing: false,
       importing_trf: false,
       importing_backup: false,
       error: nil,
       delete_target: nil,
       delete_confirm_text: "",
       purge_target: nil,
       purge_confirm_text: "",
       new_pairing_system: "swiss",
       new_team?: false,
       swar_pending: nil
     )
     # ".swar"/".trf" have no registered MIME type, so the browser-side accept
     # filter can't be used; each parser rejects anything that isn't its own
     # format anyway.
     |> allow_upload(:swar, accept: :any, max_entries: 1, max_file_size: 5_000_000)
     |> allow_upload(:trf, accept: :any, max_entries: 1, max_file_size: 5_000_000)
     |> allow_upload(:backup, accept: ~w(.json), max_entries: 1, max_file_size: 25_000_000)
     |> assign_tournaments()
     |> assign_deleted_tournaments()
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
    {:noreply,
     socket |> assign_tournaments() |> assign_deleted_tournaments() |> assign_pending_invitations()}
  end

  defp assign_tournaments(socket) do
    assign(socket, :tournaments, Tournaments.list_tournaments(socket.assigns.current_scope))
  end

  defp assign_deleted_tournaments(socket) do
    assign(
      socket,
      :deleted_tournaments,
      Tournaments.list_deleted_tournaments(socket.assigns.current_scope)
    )
  end

  defp assign_pending_invitations(socket) do
    assign(
      socket,
      :pending_invitations,
      Tournaments.list_pending_invitations(socket.assigns.current_scope)
    )
  end

  ## ---------- Pending invitations (accept/decline from the list page) ----------

  def handle_event("accept_invite", %{"token" => token}, socket) do
    case Tournaments.accept_invitation(socket.assigns.current_scope, token) do
      {:ok, collaborator} ->
        Audit.log(
          collaborator.tournament_id,
          socket.assigns.current_scope,
          "collaborator.accepted",
          %{email: collaborator.email}
        )

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
      {:ok, collaborator} ->
        Audit.log(
          collaborator.tournament_id,
          socket.assigns.current_scope,
          "collaborator.declined",
          %{email: collaborator.email}
        )

        {:noreply, assign_pending_invitations(socket)}

      {:error, _reason} ->
        {:noreply, assign_pending_invitations(socket)}
    end
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply,
     assign(socket,
       creating: true,
       importing: false,
       importing_trf: false,
       new_pairing_system: "swiss",
       new_team?: false
     )}
  end

  # Tracks the "Pairing system" select's (and the "Team tournament"
  # checkbox's) live value so the "Cycles" field can be shown only for
  # round_robin, without a full form round-trip — see `derive_type/2` for
  # where these two combine into the single `type` value actually stored.
  def handle_event("pairing_system_picked", %{"tournament" => params}, socket) do
    {:noreply,
     assign(socket,
       new_pairing_system: params["pairing_system"],
       new_team?: params["team"] == "true"
     )}
  end

  def handle_event("import", _params, socket) do
    {:noreply,
     assign(socket,
       importing: true,
       creating: false,
       importing_trf: false,
       importing_backup: false
     )}
  end

  def handle_event("import_trf", _params, socket) do
    {:noreply,
     assign(socket,
       importing_trf: true,
       creating: false,
       importing: false,
       importing_backup: false
     )}
  end

  def handle_event("import_backup", _params, socket) do
    {:noreply,
     assign(socket,
       importing_backup: true,
       creating: false,
       importing: false,
       importing_trf: false
     )}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply,
     assign(socket,
       creating: false,
       importing: false,
       importing_trf: false,
       importing_backup: false,
       error: nil,
       new_pairing_system: "swiss",
       new_team?: false,
       swar_pending: nil
     )}
  end

  # The "Tournament format" select is gone from the creation modal — `type`
  # (the FIDE-report classification: swiss | roundrobin | team-swiss |
  # team-roundrobin) is *always* derived here from the single "Pairing
  # system" choice plus the "Team tournament" checkbox, never taken from
  # the client, so the two can never disagree (see docs/pairing-systems.md
  # and the "New tournament" form below).
  def handle_event("create", %{"tournament" => params}, socket) do
    params = Map.put(params, "type", derive_type(params["pairing_system"], params["team"]))

    case Tournaments.create_tournament(socket.assigns.current_scope, params) do
      {:ok, tournament} ->
        Audit.log(tournament.id, socket.assigns.current_scope, "tournament.created", %{
          name: tournament.name,
          pairing_system: tournament.pairing_system
        })

        {:noreply, push_navigate(socket, to: ~p"/t/#{tournament.id}/players")}

      {:error, changeset} ->
        {:noreply, assign(socket, error: error_text(changeset))}
    end
  end

  # The file input's phx-change target; nothing to do until submit.
  def handle_event("validate_swar", _params, socket), do: {:noreply, socket}

  def handle_event("import_swar", _params, socket) do
    results =
      consume_uploaded_entries(socket, :swar, fn %{path: path}, _entry ->
        {:ok, SwarImport.prepare_import(path)}
      end)

    case results do
      [{:ok, %{unresolved: []} = prepared}] ->
        commit_swar(socket, prepared, %{})

      [{:ok, %{unresolved: unresolved} = prepared}] when unresolved != [] ->
        {:noreply, assign(socket, swar_pending: prepared, importing: false, error: nil)}

      [{:error, reason}] ->
        {:noreply, assign(socket, error: "Could not read this SWAR file: #{inspect(reason)}")}

      [] ->
        {:noreply, assign(socket, error: "Choose a .swar file first")}
    end
  end

  ## ---------- SWAR FIDE-match confirm step (players with no FIDE id) ----------
  #
  # Only reached when `prepare_import/1` came back with `unresolved != []`
  # (see `import_swar` above) — every player SWAR itself already had a FIDE
  # id for, and every player who matched exactly one local FIDE database
  # entry on name+federation+birth-year, is already settled at that point
  # and never shown here.

  # Each unresolved player renders a radio group named
  # `resolution[<ni>]` — either a candidate's FIDE id, or "skip" (the
  # default) to import them with no `fide_id` at all, same as if no local
  # FIDE database match had ever been attempted.
  def handle_event("resolve_swar", %{"resolution" => resolution_params}, socket) do
    resolutions =
      Map.new(resolution_params, fn {ni_str, value} ->
        fide_id =
          case Integer.parse(value) do
            {id, ""} -> id
            _ -> nil
          end

        {String.to_integer(ni_str), fide_id}
      end)

    commit_swar(socket, socket.assigns.swar_pending, resolutions)
  end

  def handle_event("resolve_swar", _params, socket) do
    commit_swar(socket, socket.assigns.swar_pending, %{})
  end

  def handle_event("cancel_swar_resolve", _params, socket) do
    {:noreply, assign(socket, swar_pending: nil, importing: true, error: nil)}
  end

  ## ---------- TRF16 import (one step — no resolve modal) ----------

  # The file input's phx-change target; nothing to do until submit.
  def handle_event("validate_trf", _params, socket), do: {:noreply, socket}

  def handle_event("import_trf_file", _params, socket) do
    scope = socket.assigns.current_scope

    results =
      consume_uploaded_entries(socket, :trf, fn %{path: path}, _entry ->
        {:ok, TrfImport.import_text(File.read!(path), scope)}
      end)

    case results do
      [{:ok, tournament, warnings}] ->
        Audit.log(tournament.id, socket.assigns.current_scope, "import.trf", %{
          name: tournament.name
        })

        {:noreply,
         socket
         |> maybe_flash_trf_warnings(warnings)
         |> assign(importing_trf: false)
         |> push_navigate(to: ~p"/t/#{tournament.id}/standings")}

      [{:error, reason}] ->
        {:noreply, assign(socket, error: TrfImport.error_message(reason))}

      [] ->
        {:noreply, assign(socket, error: "Choose a .trf file first")}
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

        Enum.each(imported, fn tournament ->
          Audit.log(tournament.id, socket.assigns.current_scope, "import.json", %{
            name: tournament.name
          })
        end)

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
        {:ok, _} = Tournaments.soft_delete_tournament(tournament)

        Audit.log(tournament.id, socket.assigns.current_scope, "tournament.deleted", %{
          name: tournament.name
        })

        {:noreply,
         socket
         |> assign(delete_target: nil, delete_confirm_text: "")
         |> assign_tournaments()
         |> assign_deleted_tournaments()}

      _ ->
        {:noreply, socket}
    end
  end

  ## ---------- Recycle bin (restore / permanently delete) ----------

  def handle_event("restore_tournament", %{"id" => id}, socket) do
    tournament =
      Tournaments.get_owned_tournament_including_deleted!(socket.assigns.current_scope, id)

    {:ok, _} = Tournaments.restore_tournament(tournament)

    Audit.log(tournament.id, socket.assigns.current_scope, "tournament.restored", %{
      name: tournament.name
    })

    {:noreply,
     socket
     |> assign_tournaments()
     |> assign_deleted_tournaments()}
  end

  def handle_event("purge_start", %{"id" => id}, socket) do
    tournament =
      Tournaments.get_owned_tournament_including_deleted!(socket.assigns.current_scope, id)

    {:noreply, assign(socket, purge_target: tournament, purge_confirm_text: "")}
  end

  def handle_event("purge_cancel", _params, socket) do
    {:noreply, assign(socket, purge_target: nil, purge_confirm_text: "")}
  end

  def handle_event("purge_confirm_input", %{"confirm" => value}, socket) do
    {:noreply, assign(socket, purge_confirm_text: value)}
  end

  def handle_event("purge_confirmed", _params, socket) do
    case socket.assigns do
      %{purge_target: %Tournament{} = tournament, purge_confirm_text: "DELETE"} ->
        {:ok, _} = Tournaments.purge_tournament(tournament)

        {:noreply,
         socket
         |> assign(purge_target: nil, purge_confirm_text: "")
         |> assign_deleted_tournaments()}

      _ ->
        {:noreply, socket}
    end
  end

  defp commit_swar(socket, prepared, resolutions) do
    scope = socket.assigns.current_scope

    case SwarImport.commit_import(prepared, resolutions, scope) do
      {:ok, tournament, warnings} ->
        Audit.log(tournament.id, scope, "import.swar", %{name: tournament.name})

        {:noreply,
         socket
         |> maybe_flash_swar_warnings(warnings)
         |> assign(swar_pending: nil)
         |> push_navigate(to: ~p"/t/#{tournament.id}/players")}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           swar_pending: nil,
           importing: true,
           error: "Could not import this SWAR file: #{inspect(reason)}"
         )}
    end
  end

  defp maybe_flash_trf_warnings(socket, []), do: socket

  defp maybe_flash_trf_warnings(socket, warnings) do
    # Layouts.flash_group/1 only renders :info and :error kinds — this is
    # a notice, not a failure, so :info (not :error) even though it reads
    # as a warning.
    put_flash(
      socket,
      :info,
      "Imported, but the TRF file's own points column didn't match the recomputed total for " <>
        Enum.map_join(warnings, ", ", fn w ->
          "#{w.player_name} (file: #{format_points(w.trf_points)}, recomputed: #{format_points(w.computed_points)})"
        end)
    )
  end

  defp maybe_flash_swar_warnings(socket, []), do: socket

  defp maybe_flash_swar_warnings(socket, warnings) do
    # Same reasoning as maybe_flash_trf_warnings/2 — :info, not :error, since
    # this is a notice about a discarded arbiter correction, not a failure.
    put_flash(
      socket,
      :info,
      "Imported, but the SWAR file's points_adjusted didn't match the recomputed total for " <>
        Enum.map_join(warnings, ", ", fn w ->
          "#{w.player_name} (file: #{format_points(w.swar_adjusted_points)}, recomputed: #{format_points(w.computed_points)})"
        end)
    )
  end

  defp format_points(p), do: :erlang.float_to_binary(p / 1, decimals: 1)

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

  # The "Tournament format" select is gone from the creation modal — `type`
  # (the FIDE-report classification: swiss | roundrobin | team-swiss |
  # team-roundrobin) is *always* derived from the single "Pairing system"
  # choice plus the "Team tournament" checkbox, never taken from the
  # client, so the two can never disagree (see docs/pairing-systems.md and
  # the "create" event handler above).
  defp derive_type("round_robin", "true"), do: "team-roundrobin"
  defp derive_type("round_robin", _team?), do: "roundrobin"
  # keizer is Swiss-classified for FIDE reporting purposes — there's no
  # separate "type" for it (see `PairingsEngine.Tournaments.Tournament`'s
  # `pairing_system` field docs).
  defp derive_type(_swiss_or_keizer, "true"), do: "team-swiss"
  defp derive_type(_swiss_or_keizer, _team?), do: "swiss"

  defp standard_options, do: @standard_options
  defp rate_of_play_options, do: @rate_of_play_options
  defp pairing_system_options, do: @pairing_system_options
  defp rr_cycles_options, do: @rr_cycles_options

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
          <button :if={!@importing_trf} class="pe-btn" phx-click="import_trf">Import TRF file</button>
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
              <tr :for={
                %{collaborator: c, tournament: t, owner_email: owner_email} <- @pending_invitations
              }>
                <td><strong>{t.name}</strong></td>
                
                <td>{owner_email}</td>
                
                <td style="text-align: right">
                  <button
                    class="pe-btn primary"
                    phx-click="accept_invite"
                    phx-value-token={c.invite_token}
                  >
                    Accept
                  </button>
                  
                  <button
                    class="pe-btn danger-link"
                    phx-click="decline_invite"
                    phx-value-token={c.invite_token}
                  >
                    Decline
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
      
      <form
        :if={@creating}
        id="new-tournament-form"
        class="card"
        phx-submit="create"
        phx-change="pairing_system_picked"
      >
        <h2>New tournament</h2>
        
        <div class="form-grid">
          <label class="field">
            <span>Name</span>
            <input name="tournament[name]" autofocus placeholder="e.g. Summer Open 2026" />
          </label>
          
          <label class="field">
            <span>Pairing system</span>
            <select name="tournament[pairing_system]">
              <option
                :for={{val, label} <- pairing_system_options()}
                value={val}
                selected={val == @new_pairing_system}
              >
                {label}
              </option>
            </select>
          </label>
          
          <label :if={@new_pairing_system == "round_robin"} class="field">
            <span>Cycles</span>
            <select name="tournament[rr_cycles]">
              <option :for={{val, label} <- rr_cycles_options()} value={val}>{label}</option>
            </select>
          </label>
          
          <label class="field field-check" style="margin-top: 1.6rem">
            <input
              type="checkbox"
              name="tournament[team]"
              value="true"
              checked={@new_team?}
              style="width: auto"
            /> <span>Team tournament</span>
          </label>
          
          <label class="field">
            <span>Rounds</span>
            <input type="number" name="tournament[rounds_count]" value="9" min="1" max="30" />
          </label>
          
          <label class="field">
            <span>Place</span> <input name="tournament[city]" placeholder="e.g. Gent" />
          </label>
          
          <label class="field">
            <span>Date from</span> <input type="date" name="tournament[start_date]" />
          </label>
          
          <label class="field">
            <span>Date to</span> <input type="date" name="tournament[end_date]" />
          </label>
          
          <div class="field">
            <span>Standard</span>
            <div style="display: flex; gap: 1rem; flex-wrap: wrap; align-items: center">
              <label :for={{val, label} <- standard_options()} class="opt-row">
                <input
                  type="radio"
                  name="tournament[standard]"
                  value={val}
                  checked={val == "standard"}
                /> {label}
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
      
      <form
        :if={@importing}
        id="swar-import-form"
        class="card"
        phx-submit="import_swar"
        phx-change="validate_swar"
      >
        <h2>Import a SWAR tournament</h2>
        
        <p class="hint" style="margin-top: 0">
          Pick a <code>.swar</code> file — the tournament, its players, rounds and results
          are imported and become yours to continue here.
        </p>
        
        <div
          class={["dropzone", @uploads.swar.entries != [] && "has-file"]}
          phx-drop-target={@uploads.swar.ref}
        >
          <.live_file_input upload={@uploads.swar} class="dropzone-input" />
          <div class="dropzone-label">
            <%= if @uploads.swar.entries == [] do %>
              <strong>Choose a .swar file</strong> <span class="hint">or drag and drop it here</span>
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
      
      <form :if={@swar_pending} id="swar-resolve-form" class="card" phx-submit="resolve_swar">
        <h2>Resolve FIDE ids</h2>
        
        <p class="hint" style="margin-top: 0">
          SWAR has no FIDE id on file for {length(@swar_pending.unresolved)} player{if length(
                                                                                         @swar_pending.unresolved
                                                                                       ) != 1, do: "s"}. Pick a match below if one of
          these is the right person, or import them without a FIDE id — nothing is saved until
          you confirm.
        </p>
        
        <div
          :for={entry <- @swar_pending.unresolved}
          class="card"
          style="background: var(--pe-bg-alt, #f7f7f7)"
        >
          <h3 style="margin-top: 0">
            {entry.name}
            <span class="hint">
              — {if entry.federation == "", do: "no federation", else: entry.federation},
              born {entry.birth_year || "unknown"}
            </span>
          </h3>
          
          <div style="display: flex; flex-direction: column; gap: .4rem">
            <label :for={c <- entry.candidates} class="opt-row opt-baseline">
              <input type="radio" name={"resolution[#{entry.ni}]"} value={c.fide_id} />
              <span>
                <strong>{c.name}</strong>
                — FIDE {c.fide_id} — {if c.federation == "", do: "?", else: c.federation},
                born {c.birth_year || "unknown"}{if c.title != "", do: ", #{c.title}"}{if c.standard_rating,
                  do: ", #{c.standard_rating}"}
              </span>
            </label>
            
            <label class="opt-row opt-baseline">
              <input type="radio" name={"resolution[#{entry.ni}]"} value="skip" checked />
              Import without a FIDE id
            </label>
          </div>
        </div>
        
        <p :if={@error} class="error-note">{@error}</p>
        
        <div class="actions">
          <button type="submit" class="pe-btn primary">Confirm and import</button>
          <button type="button" class="pe-btn" phx-click="cancel_swar_resolve">Back</button>
        </div>
      </form>
      
      <form
        :if={@importing_trf}
        id="trf-import-form"
        class="card"
        phx-submit="import_trf_file"
        phx-change="validate_trf"
      >
        <h2>Import a TRF16 tournament</h2>
        
        <p class="hint" style="margin-top: 0">
          Pick a <code>.trf</code> file — the tournament, its players, rounds and results are
          imported and become yours to continue here. If the file's own points column doesn't
          match what we recompute from the imported results, you'll see a notice after import.
        </p>
        
        <div
          class={["dropzone", @uploads.trf.entries != [] && "has-file"]}
          phx-drop-target={@uploads.trf.ref}
        >
          <.live_file_input upload={@uploads.trf} class="dropzone-input" />
          <div class="dropzone-label">
            <%= if @uploads.trf.entries == [] do %>
              <strong>Choose a .trf file</strong> <span class="hint">or drag and drop it here</span>
            <% else %>
              <span :for={entry <- @uploads.trf.entries} class="dropzone-file">
                {entry.client_name}
              </span>
            <% end %>
          </div>
        </div>
        
        <p :for={err <- upload_errors(@uploads.trf)} class="error-note">{inspect(err)}</p>
        
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
          Pick a <code>.json</code>
          file exported from <em>Settings → Export / backup</em>
          or <em>Export all (JSON)</em>
          — every tournament it contains is imported as a brand-new
          tournament owned by you, with all players, rounds and results intact. This never
          overwrites an existing tournament.
        </p>
        
        <div
          class={["dropzone", @uploads.backup.entries != [] && "has-file"]}
          phx-drop-target={@uploads.backup.ref}
        >
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
      
      <div
        :if={
          @tournaments == [] && !@creating && !@importing && !@importing_trf && !@importing_backup &&
            !@swar_pending
        }
        class="card empty"
      >
        <p><strong>No tournaments yet.</strong></p>
        
        <p>Create your first tournament, or import one from SWAR, TRF16, or a backup.</p>
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
                <button
                  :if={owned?}
                  class="pe-btn danger-link"
                  phx-click="delete_start"
                  phx-value-id={t.id}
                >
                  Delete
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@deleted_tournaments != []} class="card">
        <h2>Recycle bin</h2>

        <p class="hint" style="margin-top: 0">
          Deleted tournaments stay here for 3 months, after which they are purged automatically.
          Restore one to bring it back, or delete it permanently right away.
        </p>

        <div class="card-table-wrap">
          <table class="pe-table">
            <thead>
              <tr>
                <th>Name</th>

                <th>Deleted</th>

                <th></th>
              </tr>
            </thead>

            <tbody>
              <tr :for={t <- @deleted_tournaments}>
                <td><strong>{t.name}</strong></td>

                <td>{t.deleted_at}</td>

                <td style="text-align: right">
                  <button class="pe-btn" phx-click="restore_tournament" phx-value-id={t.id}>
                    Restore
                  </button>

                  <button class="pe-btn danger-link" phx-click="purge_start" phx-value-id={t.id}>
                    Delete permanently
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <.delete_tournament_modal
        :if={@delete_target}
        tournament={@delete_target}
        confirm_text={@delete_confirm_text}
      />

      <.purge_tournament_modal
        :if={@purge_target}
        tournament={@purge_target}
        confirm_text={@purge_confirm_text}
      />
    </Layouts.app>
    """
  end

  attr :tournament, Tournament, required: true
  attr :confirm_text, :string, required: true

  defp delete_tournament_modal(assigns) do
    ~H"""
    <div class="modal-overlay" phx-window-keydown="delete_cancel" phx-key="escape">
      <div class="modal-card" phx-click-away="delete_cancel" style="max-width: 440px">
        <h2>Delete tournament</h2>
        
        <p>
          This moves <strong>{@tournament.name}</strong>
          to the Recycle bin — it disappears from your tournament list and its pages, but you can
          restore it (or delete it permanently) for the next 3 months, after which it is purged
          automatically.
        </p>

        <form id="delete-confirm-form" phx-change="delete_confirm_input">
          <label class="field">
            <span>Type DELETE to confirm</span>
            <input name="confirm" value={@confirm_text} autocomplete="off" phx-mounted={JS.focus()} />
          </label>
        </form>

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

  attr :tournament, Tournament, required: true
  attr :confirm_text, :string, required: true

  defp purge_tournament_modal(assigns) do
    ~H"""
    <div class="modal-overlay" phx-window-keydown="purge_cancel" phx-key="escape">
      <div class="modal-card" phx-click-away="purge_cancel" style="max-width: 440px">
        <h2>Delete permanently</h2>

        <p>
          This permanently deletes <strong>{@tournament.name}</strong>
          and all of its players, rounds and results. This cannot be undone.
        </p>

        <form id="purge-confirm-form" phx-change="purge_confirm_input">
          <label class="field">
            <span>Type DELETE to confirm</span>
            <input name="confirm" value={@confirm_text} autocomplete="off" phx-mounted={JS.focus()} />
          </label>
        </form>

        <div class="actions">
          <button
            type="button"
            class="pe-btn danger"
            phx-click="purge_confirmed"
            disabled={@confirm_text != "DELETE"}
          >
            Delete permanently
          </button>
           <button type="button" class="pe-btn" phx-click="purge_cancel">Cancel</button>
        </div>
      </div>
    </div>
    """
  end
end
