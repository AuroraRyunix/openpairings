defmodule PairingsEngineWeb.TournamentsLive do
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{
    Audit,
    Tournaments,
    SwarImport,
    TournamentExport,
    TournamentImport,
    TrfImport,
    RateOfPlay
  }

  alias PairingsEngine.Tools.Parser
  alias PairingsEngine.Tournaments.Tournament

  # Initial values for the "New tournament" form — kept in `new_params` and
  # bound to each input so a phx-change re-render never wipes them.
  @new_tournament_defaults %{
    "pairing_system" => "swiss",
    "rounds_count" => "9",
    "standard" => "standard"
  }

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
       new_standard: "standard",
       new_params: @new_tournament_defaults,
       swar_pending: nil,
       swar_duplicate: nil
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
     socket
     |> assign_tournaments()
     |> assign_deleted_tournaments()
     |> assign_pending_invitations()}
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
       new_team?: false,
       new_standard: "standard",
       new_params: @new_tournament_defaults
     )}
  end

  # Tracks the "Pairing system" select's (and the "Team tournament"
  # checkbox's) live value so the "Cycles" field can be shown only for
  # round_robin, without a full form round-trip — see `derive_type/2` for
  # where these two combine into the single `type` value actually stored.
  # Also tracks the picked "Standard" (Standard/Rapid/Blitz) so the "Rate of
  # play" preset list switches to match — mirroring the Options settings page.
  # A form-level phx-change sends the WHOLE form's current values on every
  # keystroke/toggle, so we stash them in `new_params` and bind every input's
  # value back to it — otherwise each re-render (e.g. toggling "Team
  # tournament", or the rate-of-play list reacting to the format) would wipe
  # the uncontrolled text inputs the arbiter had already filled in.
  def handle_event("pairing_system_picked", %{"tournament" => params}, socket) do
    {:noreply,
     assign(socket,
       new_params: params,
       new_pairing_system: params["pairing_system"] || "swiss",
       new_team?: params["team"] == "true",
       new_standard: params["standard"] || "standard"
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
       new_standard: "standard",
       new_params: @new_tournament_defaults,
       swar_pending: nil,
       swar_duplicate: nil
     )}
  end

  # The "Tournament format" select is gone from the creation modal — `type`
  # (the FIDE-report classification: swiss | roundrobin | team-swiss |
  # team-roundrobin) is *always* derived here from the single "Pairing
  # system" choice plus the "Team tournament" checkbox, never taken from
  # the client, so the two can never disagree (see docs/pairing-systems.md
  # and the "New tournament" form below).
  def handle_event("create", %{"tournament" => params}, socket) do
    params =
      params
      |> Map.put("type", derive_type(params["pairing_system"], params["team"]))
      |> seed_round_dates()

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

  def handle_event("import_swar", _params, socket), do: import_tournament_file(socket, :swar)

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

  def handle_event("cancel_swar_duplicate", _params, socket) do
    {:noreply, assign(socket, swar_duplicate: nil, importing: true, error: nil)}
  end

  def handle_event("swar_duplicate_open_existing", _params, socket) do
    existing = socket.assigns.swar_duplicate.existing

    {:noreply,
     socket
     |> assign(swar_duplicate: nil)
     |> push_navigate(to: ~p"/t/#{existing.id}/players")}
  end

  def handle_event("swar_duplicate_import_anyway", _params, socket) do
    prepared = socket.assigns.swar_duplicate.prepared
    {:noreply, socket} = continue_swar_prepared(socket, prepared)
    {:noreply, assign(socket, swar_duplicate: nil)}
  end

  ## ---------- TRF16 import (one step — no resolve modal) ----------

  # The file input's phx-change target; nothing to do until submit.
  def handle_event("validate_trf", _params, socket), do: {:noreply, socket}

  def handle_event("import_trf_file", _params, socket), do: import_tournament_file(socket, :trf)

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

  ## ---------- Duplicate tournament ("Copy of ...") ----------

  # Reuses the same export -> import round trip Settings > Export/backup and
  # "re-upload a .json backup" already go through (PairingsEngine.
  # TournamentExport / TournamentImport) rather than a bespoke struct copy —
  # it already does the hard part correctly (fresh ids throughout, every
  # internal foreign key remapped inside one transaction) and is exactly
  # what a user could already do by hand today (export, then re-import),
  # just automated. Available to the owner and any collaborator alike, same
  # as the existing "Export" link right next to it — the copy is owned by
  # whoever clicks it, with no collaborators carried over (the export
  # envelope never includes them).
  def handle_event("duplicate", %{"id" => id}, socket) do
    case Tournaments.get_authorized_tournament(socket.assigns.current_scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Tournament not found.")}

      tournament ->
        envelope =
          tournament
          |> TournamentExport.export_tournament()
          |> put_in(
            ["tournaments", Access.at(0), "tournament", "name"],
            "Copy of #{tournament.name}"
          )

        case TournamentImport.import(envelope, socket.assigns.current_scope) do
          {:ok, [new_tournament]} ->
            Audit.log(new_tournament.id, socket.assigns.current_scope, "tournament.duplicated", %{
              from_tournament_id: tournament.id,
              from_name: tournament.name
            })

            {:noreply,
             socket
             |> put_flash(:info, "Duplicated as \"#{new_tournament.name}\".")
             |> assign_tournaments()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not duplicate: #{reason}")}
        end
    end
  end

  ## ---------- Leave a shared tournament (collaborator self-service) ----------

  # The owner-only counterpart is delete_confirmed above; a collaborator has
  # never been able to remove themselves at all (Tournaments.
  # remove_collaborator/3 is explicitly owner-only) — "I can't delete a
  # shared tournament makes sense, but I also can't leave" was a real gap,
  # not intentional. No confirm-DELETE-to-type modal like the owner's
  # delete — leaving isn't destructive to the tournament itself, and the
  # owner can always re-invite.
  def handle_event("leave_tournament", %{"id" => id}, socket) do
    case Tournaments.get_authorized_tournament(socket.assigns.current_scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Tournament not found.")}

      tournament ->
        case Tournaments.leave_tournament(socket.assigns.current_scope, tournament) do
          {:ok, _collaborator} ->
            Audit.log(tournament.id, socket.assigns.current_scope, "tournament.left", %{
              name: tournament.name
            })

            {:noreply,
             socket
             |> put_flash(:info, "Left \"#{tournament.name}\".")
             |> assign_tournaments()}

          {:error, :owner} ->
            {:noreply,
             put_flash(socket, :error, "You own this tournament — delete it instead of leaving.")}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "You're not a collaborator on this tournament.")}
        end
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

  # Shared by both import panels. Neither `.swar` nor `.trf` has a registered
  # browser MIME type, so both dropzones have to accept `:any` and a file can
  # always be dropped into the "wrong" one — which panel it came through
  # therefore says nothing about what it is. Route on the CONTENT
  # (`Parser.detect_format/2`) and run the importer the file actually needs;
  # `panel` only breaks the tie when the bytes are inconclusive, so the box
  # the user chose still decides which error they get for genuine junk.
  #
  # A SWAR file routed here from the TRF panel still gets the full SWAR
  # journey, resolve step included: `swar_pending` renders its own form
  # independently of both modals, so closing them both is all this has to do.
  defp import_tournament_file(socket, panel) do
    scope = socket.assigns.current_scope

    results =
      consume_uploaded_entries(socket, panel, fn %{path: path}, entry ->
        content = File.read!(path)

        case Parser.detect_format(entry.client_name, content) do
          :swar -> {:ok, {:swar, SwarImport.prepare_import(path)}}
          :trf -> {:ok, {:trf, TrfImport.import_text(content, scope)}}
          :unknown when panel == :swar -> {:ok, {:swar, SwarImport.prepare_import(path)}}
          :unknown -> {:ok, {:trf, TrfImport.import_text(content, scope)}}
        end
      end)

    case results do
      [{:swar, {:ok, prepared}}] ->
        continue_or_warn_swar(socket, scope, prepared)

      [{:swar, {:error, reason}}] ->
        {:noreply, assign(socket, error: "Could not read this SWAR file: #{inspect(reason)}")}

      [{:trf, {:ok, tournament, warnings}}] ->
        Audit.log(tournament.id, scope, "import.trf", %{name: tournament.name})

        {:noreply,
         socket
         |> maybe_flash_trf_warnings(warnings)
         |> assign(importing: false, importing_trf: false)
         |> push_navigate(to: ~p"/t/#{tournament.id}/standings")}

      [{:trf, {:error, reason}}] ->
        {:noreply, assign(socket, error: TrfImport.error_message(reason))}

      [] ->
        {:noreply,
         assign(socket,
           error: "Choose a #{if panel == :swar, do: ".swar", else: ".trf"} file first"
         )}
    end
  end

  # A `.swar` file carries SWAR's own persistent per-tournament GUID (see
  # `Tournaments.find_tournament_by_swar_guid/2`), unchanged across every
  # re-export of the same tournament. If this upload's GUID already belongs
  # to a tournament the uploader can already reach, pause and ask instead of
  # silently creating a duplicate — this is the single most common way a
  # re-upload goes wrong (a re-sync mid-event, forgetting a tournament was
  # already imported).
  defp continue_or_warn_swar(socket, scope, %{data: %{guid: guid}} = prepared) do
    case Tournaments.find_tournament_by_swar_guid(scope, guid) do
      nil ->
        continue_swar_prepared(socket, prepared)

      existing ->
        {:noreply,
         assign(socket,
           swar_duplicate: %{prepared: prepared, existing: existing},
           importing: false,
           importing_trf: false,
           error: nil
         )}
    end
  end

  defp continue_swar_prepared(socket, %{unresolved: []} = prepared),
    do: commit_swar(socket, prepared, %{})

  defp continue_swar_prepared(socket, %{unresolved: unresolved} = prepared)
       when unresolved != [] do
    {:noreply,
     assign(socket,
       swar_pending: prepared,
       importing: false,
       importing_trf: false,
       error: nil
     )}
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
  # Seed one round date per round from the start date, so a freshly created
  # tournament isn't blocked on the "Round dates" required-setup item (which
  # otherwise sends the arbiter to the Dates page to fill each round by hand
  # before they can pair). It's only a sensible default — the arbiter refines
  # the individual round dates on the Dates page — so we never overwrite dates
  # the caller already supplied, and do nothing when there's no start date or
  # no valid round count to seed from.
  defp seed_round_dates(%{"round_dates" => existing} = params) when existing not in [nil, []],
    do: params

  defp seed_round_dates(params) do
    start_date = String.trim(params["start_date"] || "")
    rounds = parse_rounds_count(params["rounds_count"])

    if start_date != "" and rounds > 0 do
      Map.put(params, "round_dates", List.duplicate(start_date, rounds))
    else
      params
    end
  end

  defp parse_rounds_count(n) when is_integer(n), do: n

  defp parse_rounds_count(n) when is_binary(n) do
    case Integer.parse(n) do
      {int, _} when int > 0 -> int
      _ -> 0
    end
  end

  defp parse_rounds_count(_), do: 0

  defp derive_type("round_robin", "true"), do: "team-roundrobin"
  defp derive_type("round_robin", _team?), do: "roundrobin"
  # keizer is Swiss-classified for FIDE reporting purposes — there's no
  # separate "type" for it (see `PairingsEngine.Tournaments.Tournament`'s
  # `pairing_system` field docs).
  defp derive_type(_swiss_or_keizer, "true"), do: "team-swiss"
  defp derive_type(_swiss_or_keizer, _team?), do: "swiss"

  defp standard_options, do: RateOfPlay.standard_options()
  # Rate-of-play presets shown on the create form depend on the picked Standard
  # (Standard / Rapid / Blitz) — the same cadence-appropriate lists the Options
  # settings page uses, via the shared `PairingsEngine.RateOfPlay` catalogue.
  defp rate_of_play_options(standard), do: RateOfPlay.select_options(standard, nil)
  defp pairing_system_options, do: @pairing_system_options
  defp rr_cycles_options, do: @rr_cycles_options

  # A single-day tournament (the common case for a club event) has
  # start_date == end_date — showing "2026-08-12 → 2026-08-12" is just
  # noise, so collapse it to the one date. Free-text fields (no format
  # enforced at the schema level), so this is a plain string comparison,
  # not a date-arithmetic one.
  defp date_range("", _end_date), do: "-"
  defp date_range(start_date, end_date) when end_date in [nil, "", start_date], do: start_date
  defp date_range(start_date, end_date), do: "#{start_date} → #{end_date}"

  # "setup" already reads as muted/inactive; "finished" needs its own look
  # too so it doesn't share "running"'s (the accent colour, which is also
  # user-customizable) look — otherwise the two are visually identical.
  defp status_class("setup"), do: "muted"
  defp status_class("finished"), do: "done"
  defp status_class(_), do: nil

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
            <input
              name="tournament[name]"
              value={Map.get(@new_params, "name", "")}
              autofocus
              placeholder="e.g. Summer Open 2026"
            />
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
              <option
                :for={{val, label} <- rr_cycles_options()}
                value={val}
                selected={to_string(val) == Map.get(@new_params, "rr_cycles", "1")}
              >
                {label}
              </option>
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
            <input
              type="number"
              name="tournament[rounds_count]"
              value={Map.get(@new_params, "rounds_count", "9")}
              min="1"
              max="30"
            />
          </label>

          <label class="field">
            <span>Place</span>
            <input
              name="tournament[city]"
              value={Map.get(@new_params, "city", "")}
              placeholder="e.g. Gent"
            />
          </label>

          <label class="field">
            <span>Date from</span>
            <input
              type="date"
              name="tournament[start_date]"
              value={Map.get(@new_params, "start_date", "")}
            />
            <span class="hint">
              Just seeds every round to this date — refine per-round (and the tournament's end
              date, derived from those) on the Dates page after creating it.
            </span>
          </label>

          <div class="field">
            <span>Format</span>
            <div style="display: flex; gap: 1rem; flex-wrap: wrap; align-items: center">
              <label :for={{val, label} <- standard_options()} class="opt-row">
                <input
                  type="radio"
                  name="tournament[standard]"
                  value={val}
                  checked={val == @new_standard}
                /> {label}
              </label>
            </div>
          </div>

          <label class="field">
            <span>Rate of play</span>
            <select name="tournament[rate_of_play]">
              <option
                :for={opt <- rate_of_play_options(@new_standard)}
                value={opt}
                selected={opt == Map.get(@new_params, "rate_of_play", "")}
              >
                {if opt == "", do: "- none -", else: opt}
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
          Pick a <code>.swar</code> file - the tournament, its players, rounds and results
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

      <div :if={@swar_duplicate} id="swar-duplicate-warning" class="card">
        <h2>This looks like a tournament you already have</h2>

        <p class="hint" style="margin-top: 0">
          This file's SWAR tournament id matches <strong>{@swar_duplicate.existing.name}</strong>, already imported here. Re-uploading a
          sync of the same tournament as a new import would create a second, separate copy rather
          than updating the one you already have.
        </p>

        <div class="actions">
          <button
            type="button"
            class="pe-btn primary"
            phx-click="swar_duplicate_open_existing"
          >
            Open {@swar_duplicate.existing.name}
          </button>
          <button type="button" class="pe-btn" phx-click="swar_duplicate_import_anyway">
            Import as a new tournament anyway
          </button>
          <button type="button" class="pe-btn" phx-click="cancel_swar_duplicate">Cancel</button>
        </div>
      </div>

      <form :if={@swar_pending} id="swar-resolve-form" class="card" phx-submit="resolve_swar">
        <h2>Resolve FIDE ids</h2>

        <p class="hint" style="margin-top: 0">
          SWAR has no FIDE id on file for {length(@swar_pending.unresolved)} player{if length(
                                                                                         @swar_pending.unresolved
                                                                                       ) != 1, do: "s"}. Pick a match below if one of
          these is the right person, or import them without a FIDE id - nothing is saved until
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
              - {if entry.federation == "", do: "no federation", else: entry.federation},
              born {entry.birth_year || "unknown"}
            </span>
          </h3>

          <div style="display: flex; flex-direction: column; gap: .4rem">
            <label :for={c <- entry.candidates} class="opt-row opt-baseline">
              <input type="radio" name={"resolution[#{entry.ni}]"} value={c.fide_id} />
              <span>
                <strong>{c.name}</strong>
                - FIDE {c.fide_id} - {if c.federation == "", do: "?", else: c.federation},
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
          Pick a <code>.trf</code> file - the tournament, its players, rounds and results are
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
          - every tournament it contains is imported as a brand-new
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
            !@swar_pending && !@swar_duplicate
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

              <td>{date_range(t.start_date, t.end_date)}</td>

              <td>
                <span class={["badge", status_class(t.status)]}>{t.status}</span>
              </td>

              <td style="text-align: right">
                <a class="pe-btn" href={~p"/t/#{t.id}/export/json"} target="_blank">Export</a>
                <button class="pe-btn" phx-click="duplicate" phx-value-id={t.id}>
                  Copy
                </button>
                <button
                  :if={owned?}
                  class="pe-btn danger-link"
                  phx-click="delete_start"
                  phx-value-id={t.id}
                >
                  Delete
                </button>
                <button
                  :if={!owned?}
                  class="pe-btn danger-link"
                  phx-click="leave_tournament"
                  phx-value-id={t.id}
                  data-confirm={"Leave \"#{t.name}\"? You'll lose access to it unless the owner invites you again."}
                >
                  Leave
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
          to the Recycle bin - it disappears from your tournament list and its pages, but you can
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
