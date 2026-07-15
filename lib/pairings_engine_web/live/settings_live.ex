defmodule PairingsEngineWeb.SettingsLive do
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{Tournaments, Tiebreaks, Pairing, Exclusions, Fide}
  alias PairingsEngine.Tournaments.Tournament

  # 4th tuple element marks a field as mandatory setup data (see
  # `Tournament.required_setup_fields/0`) — its label renders bold with a
  # red "*" (see `general_field_label/2`). `rounds_count` is also required
  # but lives on the Format card, so it's marked bold there directly.
  @general_fields [
    {"name", "Tournament name", "text", true},
    {"venue", "Venue", "text", false},
    {"city", "City", "text", false},
    {"federation", "Federation", "text", false},
    {"start_date", "Start date", "date", true},
    {"end_date", "End date", "date", false},
    {"organizer", "Organizer", "text", false},
    {"organizer_club_number", "Organizer club nr / logo", "text", false}
  ]

  # SWAR TournoiStd (§5.13): Standard / Rapid / Blitz.
  @standard_options [
    {"standard", "Standard"},
    {"rapid", "Rapid"},
    {"blitz", "Blitz"}
  ]

  # Rate-of-play presets, one list per `standard` value — exact option sets
  # (including order) as specified for OpenPairings; changing "Type" swaps
  # which of these three lists the "Rate of play" select offers (see
  # `standard_change` below).
  @rate_of_play_standard [
    "100min/end+30sec/move from move 1",
    "100min/40moves+50min/20moves+15min/end+30sec/move from move 1",
    "105min/40moves+15min/end",
    "120min/40moves+15min/end+30sec/move from move 40",
    "120min/40moves+30min/end",
    "120min/10moves+30min/end+30sec/move from move 40",
    "120min/end",
    "120min/end+10sec/move from move 40",
    "120min/end+30sec/move from move 1",
    "120min/end+30sec/move from move 40",
    "150min/end",
    "30min/end+30sec/move from move 1",
    "40min/end+30sec/move from move 1",
    "60min/end",
    "60min/end+30sec/move from move 1",
    "65min/end",
    "75min/end+30sec/move from move 1",
    "90min/40moves+15min/end+30sec/move from move 1",
    "90min/end+10sec/move from move 1",
    "90min/end+30sec DELAY /move from move 1",
    "90min/end",
    "90min/end+30sec/move from move 1",
    "90min/40moves+30min/end+30sec/move from move 1"
  ]

  @rate_of_play_rapid [
    "10min/end+10sec/move from move 1",
    "10min/end+15sec/move from move 1",
    "10min/end+2sec/move from move 1",
    "10min/end+5sec DELAY /move from move 1",
    "10min/end+5sec/move from move 1",
    "11min/end",
    "12min/end",
    "12min/end+10sec/move from move 1",
    "12min/end+3sec/move from move 1",
    "12min/end+5sec/move from move 1",
    "13min/end+3sec/move from move 1",
    "13min/end+5sec/move from move 1",
    "15min/end",
    "15min/end+10sec/move from move 1",
    "15min/end+15sec/move from move 1",
    "15min/end+5sec/move from move 1",
    "20min/end",
    "20min/end+10sec/move from move 1",
    "20min/end+15sec/move from move 1",
    "20min/end+5sec/move from move 1",
    "25min/end+10sec/move from move 1",
    "25min/end+15sec/move from move 1",
    "25min/end+5sec/move from move 1",
    "25min/end",
    "30min/end",
    "30min/end+10sec/move from move 1",
    "30min/end+20sec/move from move 1",
    "40min/end+10sec/move from move 1",
    "45min/end",
    "59min/end",
    "8min/end+4sec/move from move 1"
  ]

  @rate_of_play_blitz [
    "10min/end",
    "3min/end+2sec/move from move 1",
    "3min/end+3sec/move from move 1",
    "4min/end+2sec/move from move 1",
    "4min/end+3sec/move from move 1",
    "5min/end",
    "5min/end+2sec/move from move 1",
    "5min/end+3sec DELAY /move from move 1",
    "5min/end+3sec/move from move 1",
    "6min/end+2sec/move from move 1",
    "6min/end+3sec/move from move 1",
    "7min/end+2sec/move from move 1",
    "7min/end+3sec/move from move 1",
    "8min/end+2sec/move from move 1",
    "8min/end+3sec/move from move 1"
  ]

  # Officials & FIDE report fields not on the Tournament schema directly —
  # nested under tournament[officials][KEY] and stored in the :officials map
  # (see PairingsEngine.Tournaments.Tournament for the recognised keys).
  @officials_fields [
    {"organizer_id", "Organizer FIDE ID", "text"},
    {"organizer_email", "Organizer e-mail", "text"},
    {"chief_arbiter_email", "Chief arbiter e-mail", "text"}
  ]

  @deputy_fields [
    {1, "1st deputy arbiter"},
    {2, "2nd deputy arbiter"}
  ]

  @pairing_system_options for ps <- Tournament.pairing_systems(),
                              do: {ps, Tournament.pairing_system_label(ps)}
  @rr_cycles_options for c <- Tournament.rr_cycles_values(),
                         do: {c, Tournament.rr_cycles_label(c)}

  # SWAR §5.22 Tie-break Presets (TB_PERSONEL). The manual only names the
  # enum members (TB_FIDE_RR, TB_DIS_SW, TB_REG_SW, TB_OLD_SW) without
  # publishing the exact method sequence SWAR assigns to each one, so the
  # sequences below are a best-effort mapping onto our own catalogue codes
  # (see Tiebreaks.catalogue/0) rather than a verbatim transcription —
  # flagged for review.
  @tb_presets [
    {"fide_rr", "FIDE Round Robin", ~w(DE WIN SB KS)},
    {"disparate_sw", "Disparate Swiss (wide rating range)", ~w(BHC1 BH SB)},
    {"regular_sw", "Regular Swiss", ~w(BHC1 BH PS)},
    {"old_sw", "Old Swiss (classic)", ~w(PS BH SB)}
  ]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)
    owner? = Tournaments.owner?(tournament, socket.assigns.current_scope)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    # Unlike the other tournament views, this whole page IS one big
    # always-open form with no explicit "editing" flag — so we can't just
    # blindly reassign `@tournament` on every broadcast: since form
    # fields render their default `value` straight from `@tournament`,
    # doing so could reset text the user is mid-typing. This hook flips
    # `dirty` true the moment *any* event fires (typing, reordering
    # tiebreaks, calculating round dates, ...); the tournament_changed
    # handler below only reloads while the socket isn't dirty. A
    # successful "save" clears it again, since local edits were just
    # committed.
    socket =
      attach_hook(socket, :settings_dirty_tracker, :handle_event, fn _event, _params, socket ->
        {:cont, assign(socket, dirty: true)}
      end)

    {:ok,
     socket
     |> assign(
       tournament: tournament,
       owner?: owner?,
       page_title: "#{tournament.name} · Settings",
       tiebreaks: tournament.tiebreaks,
       round_dates: pad_dates(tournament.round_dates, tournament.rounds_count),
       standard: tournament.standard,
       rate_of_play: tournament.rate_of_play,
       note: nil,
       error: nil,
       dirty: false,
       stale: false,
       collaborator_error: nil,
       collaborator_note: nil,
       forbidden_pairing_error: nil,
       club_exclusion_mode: tournament.club_exclusion,
       fed_exclusion_mode: tournament.fed_exclusion,
       exclusion_error: nil,
       # Active FIDE-autocomplete dropdown for the Officials arbiter fields
       # (chief arbiter, person responsible for pairings, each deputy) —
       # `nil` when no field is focused/searching, else
       # `%{role: "chief_arbiter" | "person_responsible_pairings" | "deputy1" | "deputy2", results: [...]}`.
       arbiter_search: nil
     )
     |> assign_collaborators()
     |> assign_pairing_locks()
     |> assign_forbidden_pairings()
     # SWAR parity #14-16 (place cards): the print logo. Accept-list here is
     # only a browser-side hint (a UI nicety, easily spoofed) — the real
     # gate is Tournaments.set_logo/2's magic-byte sniff on "upload_logo"
     # below, which is what actually decides whether the bytes get stored.
     # SVG is deliberately absent from both: it's never accepted (see
     # Tournaments.detect_image_type/1).
     |> allow_upload(:logo,
       accept: ~w(.png .jpg .jpeg .gif .webp),
       max_entries: 1,
       max_file_size: 2_000_000
     )}
  end

  # `pairing_system` locks once the tournament has paired its first round —
  # switching engines mid-tournament would leave earlier rounds paired by a
  # different (possibly incompatible) system. `rr_cycles` locks separately,
  # once the number of already-paired rounds reaches what the *current*
  # cycles setting implies a round robin needs (players - 1, doubled for
  # cycles: 2) — past that point the schedule the current setting implies
  # has already played out, so changing cycles further has no sane target
  # to grow into. Best-effort definition: PairingsEngine.RoundRobin doesn't
  # exist yet, so there's no canonical schedule length to check against.
  defp assign_pairing_locks(socket) do
    tournament = socket.assigns.tournament
    paired = Pairing.paired_rounds_count(tournament.id)
    players = Tournaments.count_players(tournament.id)
    rr_base = max(players - 1, 1)
    rr_implied_limit = rr_base * tournament.rr_cycles

    assign(socket,
      paired_rounds: paired,
      pairing_system_locked?: paired > 0,
      rr_cycles_locked?: paired >= rr_implied_limit,
      # `rr_match_format` gets the same "can't flip mid-tournament" lock as
      # `pairing_system` itself (not the "schedule implied by the current
      # setting is exhausted" logic `rr_cycles_locked?` uses) — flipping
      # match format after round 1 has been paired would leave the already-
      # paired rounds in one shape and everything after in another, exactly
      # the problem `pairing_system_locked?` exists to prevent.
      rr_match_format_locked?: paired > 0,
      # Same "can't flip mid-tournament" reasoning as `rr_match_format_locked?`
      # above, for Swiss's own match-format flag.
      swiss_match_format_locked?: paired > 0,
      # Same "can't flip mid-tournament" reasoning again, for native
      # per-category Swiss pairing (SWAR-parity #24) — flipping it after
      # round 1 would leave already-paired rounds mixing categories freely
      # while later rounds suddenly split them apart (or vice versa).
      pair_by_category_locked?: paired > 0
    )
  end

  defp assign_collaborators(socket) do
    if socket.assigns.owner? do
      assign(socket, :collaborators, Tournaments.list_collaborators(socket.assigns.tournament))
    else
      assign(socket, :collaborators, [])
    end
  end

  # Forbidden pairings: like the rest of the Settings form, this is
  # available to any authorized user (owner or accepted collaborator), not
  # just the owner — see PairingsEngine.Tournaments' "Forbidden pairings"
  # section.
  defp assign_forbidden_pairings(socket) do
    tournament = socket.assigns.tournament
    players = Tournaments.list_players(tournament.id) |> Enum.sort_by(& &1.name)

    assign(socket,
      forbidden_pairings: Tournaments.list_forbidden_pairings(tournament.id),
      forbidden_pairing_players: players,
      # Hint shown on the exclusion-rules form — how many pairs the
      # currently-saved club/federation rules would exclude right now.
      # Purely informational (recomputed live at pairing time by
      # PairingsEngine.Exclusions, not stored) — uses every player on the
      # roster rather than just this round's eligible ones, since there's no
      # "round" context on the Settings page.
      excluded_pair_count: Exclusions.excluded_pairs(tournament, players) |> MapSet.size()
    )
  end

  # Another user (or tab) changed this tournament. If the local form is
  # untouched, it's safe to reload everything from the database. If the
  # user has started editing (typed a field, reordered tiebreaks, etc.),
  # reloading would clobber that in-progress work, so we skip the reload
  # and just flag the page as stale — their next "Save" will overwrite
  # whatever changed elsewhere, which is the expected last-write-wins
  # behaviour for a settings form.
  # While the form is dirty (see the `settings_dirty_tracker` hook above), a
  # broadcast on this tournament's topic could just be the echo of our own
  # write — e.g. `add_forbidden_pairing`/`remove_forbidden_pairing` and the
  # Categories card below call their own `Tournaments` functions directly
  # (not through the big "save" form) and broadcast `:settings` like every
  # other write does, but they don't touch the `tournaments` row itself (or,
  # for Categories, they already re-assigned `@tournament` to the exact
  # struct the write returned before this message was even processed). Only
  # flag the page `stale` when the freshly-loaded row actually *differs*
  # from what's already assigned — i.e. someone else's write raced ours —
  # rather than on every single broadcast while dirty, which used to
  # (wrongly) show the "updated elsewhere" banner right under the page
  # header after every forbidden-pairing add, visually reading as the page
  # jumping to the top. Comparing full structs rather than `updated_at`
  # deliberately sidesteps that column's second-level precision (two
  # genuinely different writes landing in the same second would otherwise
  # look identical by timestamp alone).
  @impl true
  def handle_info(
        {:tournament_changed, _tournament_id, _hint},
        %{assigns: %{dirty: true}} = socket
      ) do
    case Tournaments.get_authorized_tournament(
           socket.assigns.current_scope,
           socket.assigns.tournament.id
         ) do
      nil ->
        {:noreply, assign(socket, stale: true)}

      tournament ->
        if tournament == socket.assigns.tournament do
          {:noreply, socket}
        else
          {:noreply, assign(socket, stale: true)}
        end
    end
  end

  def handle_info({:tournament_changed, _tournament_id, _hint}, socket) do
    case Tournaments.get_authorized_tournament(
           socket.assigns.current_scope,
           socket.assigns.tournament.id
         ) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "This tournament was deleted.")
         |> push_navigate(to: ~p"/")}

      tournament ->
        {:noreply,
         socket
         |> assign(
           tournament: tournament,
           tiebreaks: tournament.tiebreaks,
           round_dates: pad_dates(tournament.round_dates, tournament.rounds_count),
           standard: tournament.standard,
           rate_of_play: tournament.rate_of_play,
           club_exclusion_mode: tournament.club_exclusion,
           fed_exclusion_mode: tournament.fed_exclusion,
           stale: false
         )
         |> assign_collaborators()
         |> assign_pairing_locks()
         |> assign_forbidden_pairings()}
    end
  end

  @impl true
  def handle_event("tb_up", %{"index" => index}, socket) do
    {:noreply,
     assign(socket,
       tiebreaks: swap(socket.assigns.tiebreaks, String.to_integer(index), -1),
       note: nil
     )}
  end

  def handle_event("tb_down", %{"index" => index}, socket) do
    {:noreply,
     assign(socket,
       tiebreaks: swap(socket.assigns.tiebreaks, String.to_integer(index), 1),
       note: nil
     )}
  end

  def handle_event("tb_remove", %{"code" => code}, socket) do
    {:noreply, assign(socket, tiebreaks: List.delete(socket.assigns.tiebreaks, code), note: nil)}
  end

  def handle_event("tb_add", %{"code" => ""}, socket), do: {:noreply, socket}

  def handle_event("tb_add", %{"code" => code}, socket) do
    {:noreply, assign(socket, tiebreaks: socket.assigns.tiebreaks ++ [code], note: nil)}
  end

  def handle_event("tb_reset", _params, socket) do
    {:noreply,
     assign(socket, tiebreaks: Tiebreaks.fide_defaults(socket.assigns.tournament.type), note: nil)}
  end

  def handle_event("tb_preset", %{"key" => "personel"}, socket), do: {:noreply, socket}

  def handle_event("tb_preset", %{"key" => key}, socket) do
    case Enum.find(@tb_presets, fn {k, _label, _methods} -> k == key end) do
      nil -> {:noreply, socket}
      {_key, _label, methods} -> {:noreply, assign(socket, tiebreaks: methods, note: nil)}
    end
  end

  def handle_event("rd_calc", _params, socket) do
    tournament = socket.assigns.tournament

    with start when start not in [nil, ""] <- tournament.start_date,
         {:ok, date} <- Date.from_iso8601(start) do
      dates =
        for i <- 0..(tournament.rounds_count - 1) do
          date |> Date.add(i * 7) |> Date.to_iso8601()
        end

      {:noreply, assign(socket, round_dates: dates, error: nil)}
    else
      {:error, _} ->
        {:noreply,
         assign(socket, error: "Start date must be a valid date before calculating round dates.")}

      _ ->
        {:noreply,
         assign(socket, error: "Set a start date (in General) before calculating round dates.")}
    end
  end

  def handle_event("rd_clear", _params, socket) do
    {:noreply,
     assign(socket, round_dates: List.duplicate("", socket.assigns.tournament.rounds_count))}
  end

  # Bonus convenience per spec: round 1 = start date, then +1 day for every
  # following round (as opposed to `rd_calc` above, which spaces rounds a
  # week apart for weekend tournaments).
  def handle_event("rd_fill_sequential", _params, socket) do
    tournament = socket.assigns.tournament

    with start when start not in [nil, ""] <- tournament.start_date,
         {:ok, date} <- Date.from_iso8601(start) do
      dates =
        for i <- 0..(tournament.rounds_count - 1) do
          date |> Date.add(i) |> Date.to_iso8601()
        end

      {:noreply, assign(socket, round_dates: dates, error: nil)}
    else
      {:error, _} ->
        {:noreply,
         assign(socket, error: "Start date must be a valid date before filling round dates.")}

      _ ->
        {:noreply,
         assign(socket, error: "Set a start date (in General) before filling round dates.")}
    end
  end

  # `standard` and `rate_of_play` are tracked as their own assigns (rather
  # than read straight off `@tournament`, like the rest of the big form)
  # because the "Rate of play" select's option list depends on which
  # "Type" is currently picked — switching type needs to update that list
  # (and clear/keep the current selection) before the form is ever
  # submitted, which plain HTML can't do on its own.
  def handle_event("standard_change", %{"tournament" => %{"standard" => new_standard}}, socket) do
    list = rate_of_play_list(new_standard)
    current = socket.assigns.rate_of_play

    new_rate = if current in list, do: current, else: ""

    {:noreply, assign(socket, standard: new_standard, rate_of_play: new_rate)}
  end

  def handle_event("save", %{"tournament" => params}, socket) do
    params =
      params
      |> Map.put("tiebreaks", socket.assigns.tiebreaks)
      |> apply_rate_of_play_override()
      |> normalize_round_dates()
      |> strip_locked_pairing_fields(socket.assigns)

    # Base the changeset on a *freshly loaded* row rather than
    # `socket.assigns.tournament` directly: an arbiter-autocomplete pick
    # (see `apply_arbiter_pick/3` above) optimistically writes the picked
    # name/FIDE id straight onto `@tournament` for instant UI feedback,
    # without touching the database. If the submitted params still carry
    # that same value (the common case — the user picked, then hit "Save"
    # without changing anything else), diffing against the already-mutated
    # in-memory struct would see no change on that field and Ecto would
    # silently skip writing it, leaving the database out of sync with what
    # the form just showed as saved. Reloading here keeps the changeset's
    # diff honest against what's actually persisted.
    base = Tournaments.get_tournament!(socket.assigns.tournament.id)

    case Tournaments.update_tournament(base, params) do
      {:ok, tournament} ->
        {:noreply,
         socket
         |> assign(
           tournament: tournament,
           round_dates: pad_dates(tournament.round_dates, tournament.rounds_count),
           standard: tournament.standard,
           rate_of_play: tournament.rate_of_play,
           note: "Saved.",
           error: nil,
           dirty: false,
           stale: false
         )
         |> assign_pairing_locks()}

      {:error, changeset} ->
        {:noreply, assign(socket, error: error_text(changeset), note: nil)}
    end
  end

  ## ---------- Officials arbiter FIDE-autocomplete (chief/pairings/deputies) ----------
  #
  # Mirrors PlayersLive's "search"/"pick" flow (see that module's add-player
  # form), but generalised over a `role` so the same handlers serve the
  # chief arbiter, "person responsible for pairings", and both deputy name
  # fields. A pick only updates the in-memory `@tournament` (name + FIDE id
  # under `officials`); like every other field on this page, it's only
  # persisted once "Save settings" is submitted. Free typing (never
  # picking a result) is fine too — the field is a plain text input.

  def handle_event("arbiter_search", %{"role" => role} = params, socket) do
    query = arbiter_query(role, params)

    results =
      if String.length(String.trim(to_string(query))) >= 2 do
        Fide.search(query)
      else
        []
      end

    {:noreply, assign(socket, arbiter_search: %{role: role, results: results})}
  end

  def handle_event("arbiter_pick", %{"role" => role, "fide-id" => fide_id}, socket) do
    results = (socket.assigns.arbiter_search || %{results: []}).results

    case Enum.find(results, &(&1.fide_id == String.to_integer(fide_id))) do
      nil ->
        {:noreply, socket}

      fp ->
        {:noreply,
         assign(socket,
           tournament: apply_arbiter_pick(socket.assigns.tournament, role, fp),
           arbiter_search: nil
         )}
    end
  end

  ## ---------- Share / Team (collaborators) — owner-only ----------

  def handle_event("add_collaborator", %{"email" => email}, socket) do
    case Tournaments.add_collaborator(
           socket.assigns.current_scope,
           socket.assigns.tournament,
           email
         ) do
      {:ok, collaborator} ->
        note =
          if collaborator.mail_status == :failed do
            "Invite saved, but the email could not be sent — share this link manually: " <>
              "/invites/#{collaborator.invite_token}"
          end

        {:noreply,
         socket
         |> assign(collaborator_error: nil, collaborator_note: note)
         |> assign_collaborators()}

      {:error, :blank_email} ->
        {:noreply,
         assign(socket, collaborator_error: "Enter an email address", collaborator_note: nil)}

      {:error, :cannot_add_owner} ->
        {:noreply,
         assign(socket,
           collaborator_error: "You already own this tournament",
           collaborator_note: nil
         )}

      {:error, :already_added} ->
        {:noreply,
         assign(socket,
           collaborator_error: "That email already has access",
           collaborator_note: nil
         )}

      {:error, :not_owner} ->
        {:noreply,
         assign(socket,
           collaborator_error: "Only the owner can manage collaborators",
           collaborator_note: nil
         )}

      {:error, changeset} ->
        {:noreply,
         assign(socket, collaborator_error: error_text(changeset), collaborator_note: nil)}
    end
  end

  def handle_event("remove_collaborator", %{"id" => id}, socket) do
    case Tournaments.remove_collaborator(
           socket.assigns.current_scope,
           socket.assigns.tournament,
           id
         ) do
      {:ok, _collaborator} -> {:noreply, assign_collaborators(socket)}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  ## ---------- Forbidden pairings — any authorized user (owner or collaborator) ----------

  def handle_event("add_forbidden_pairing", %{"player_a_id" => a, "player_b_id" => b}, socket) do
    with {a_id, ""} <- Integer.parse(a),
         {b_id, ""} <- Integer.parse(b) do
      case Tournaments.add_forbidden_pairing(socket.assigns.tournament, a_id, b_id) do
        {:ok, _forbidden_pairing} ->
          {:noreply,
           socket
           |> assign(forbidden_pairing_error: nil)
           |> assign_forbidden_pairings()}

        {:error, :same_player} ->
          {:noreply, assign(socket, forbidden_pairing_error: "Choose two different players")}

        {:error, :invalid_player} ->
          {:noreply,
           assign(socket, forbidden_pairing_error: "Choose two players from this tournament")}

        {:error, :already_forbidden} ->
          {:noreply, assign(socket, forbidden_pairing_error: "That pair is already forbidden")}

        {:error, _reason} ->
          {:noreply,
           assign(socket, forbidden_pairing_error: "Could not add that forbidden pairing")}
      end
    else
      _ -> {:noreply, assign(socket, forbidden_pairing_error: "Choose two players")}
    end
  end

  def handle_event("remove_forbidden_pairing", %{"id" => id}, socket) do
    case Tournaments.remove_forbidden_pairing(socket.assigns.tournament, id) do
      {:ok, _forbidden_pairing} -> {:noreply, assign_forbidden_pairings(socket)}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  ## ---------- Club/federation exclusions (PairingsEngine.Exclusions) — any authorized user ----------
  #
  # Like Categories below, this persists immediately through
  # `Tournaments.update_tournament/2` rather than the big form's "Save"
  # button — there's no reason to bundle an unrelated save into one click.
  # `club_exclusion_mode`/`fed_exclusion_mode` are local-only assigns (never
  # written to the tournament directly) that just control whether the
  # "listed" text input is shown; the real values are read straight out of
  # the submitted form on "save_exclusions", same as every other field here.

  def handle_event(
        "club_exclusion_mode_change",
        %{"tournament" => %{"club_exclusion" => mode}},
        socket
      ) do
    {:noreply, assign(socket, club_exclusion_mode: mode)}
  end

  def handle_event(
        "fed_exclusion_mode_change",
        %{"tournament" => %{"fed_exclusion" => mode}},
        socket
      ) do
    {:noreply, assign(socket, fed_exclusion_mode: mode)}
  end

  def handle_event("save_exclusions", %{"tournament" => params}, socket) do
    params =
      Map.take(params, [
        "club_exclusion",
        "club_exclusion_list",
        "fed_exclusion",
        "fed_exclusion_list"
      ])

    case Tournaments.update_tournament(socket.assigns.tournament, params) do
      {:ok, tournament} ->
        {:noreply,
         socket
         |> assign(
           tournament: tournament,
           club_exclusion_mode: tournament.club_exclusion,
           fed_exclusion_mode: tournament.fed_exclusion,
           exclusion_error: nil
         )
         |> assign_forbidden_pairings()}

      {:error, changeset} ->
        {:noreply, assign(socket, exclusion_error: error_text(changeset))}
    end
  end

  ## ---------- Print logo (SWAR parity #14-16) — any authorized user ----------
  #
  # `logo_data`/`logo_content_type` are deliberately not part of the big
  # settings form or its changeset (see Tournament.changeset/2's comment) —
  # this uploads and persists immediately, same pattern as Categories/
  # exclusions above, through Tournaments.set_logo/2 and clear_logo/1.

  # The file input's phx-change target; nothing to validate until submit —
  # same no-op pattern every other upload on this codebase uses (see
  # TournamentsLive's "validate_backup"/"validate_trf").
  def handle_event("validate_logo", _params, socket), do: {:noreply, socket}

  def handle_event("upload_logo", _params, socket) do
    results =
      consume_uploaded_entries(socket, :logo, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end)

    case results do
      [binary] ->
        case Tournaments.set_logo(socket.assigns.tournament, binary) do
          {:ok, tournament} ->
            {:noreply,
             socket
             |> assign(tournament: tournament)
             |> put_flash(:info, "Logo uploaded.")}

          {:error, :invalid_image} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "That file isn't a supported image. Only PNG, JPEG, GIF or WebP are accepted " <>
                 "(SVG is not supported) — the file's actual content is checked, not just its name."
             )}

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, error_text(changeset))}
        end

      [] ->
        {:noreply, put_flash(socket, :error, "Choose an image file first")}
    end
  end

  def handle_event("clear_logo", _params, socket) do
    case Tournaments.clear_logo(socket.assigns.tournament) do
      {:ok, tournament} ->
        {:noreply,
         socket
         |> assign(tournament: tournament)
         |> put_flash(:info, "Logo removed.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not remove the logo")}
    end
  end

  # Server-side enforcement of the locks assign_pairing_locks/1 computes —
  # the <select>/<input> are also HTML `disabled` in the template, but a
  # disabled field just never gets submitted; a crafted/replayed request
  # could still include the key, so drop it here regardless.
  defp strip_locked_pairing_fields(params, assigns) do
    params
    |> maybe_drop_locked("pairing_system", assigns.pairing_system_locked?)
    |> maybe_drop_locked("rr_cycles", assigns.rr_cycles_locked?)
    |> maybe_drop_locked("rr_match_format", assigns.rr_match_format_locked?)
    |> maybe_drop_locked("swiss_match_format", assigns.swiss_match_format_locked?)
    |> maybe_drop_locked("pair_by_category", assigns.pair_by_category_locked?)
  end

  defp maybe_drop_locked(params, _key, false), do: params
  defp maybe_drop_locked(params, key, true), do: Map.delete(params, key)

  defp swap(list, index, delta) do
    target = index + delta

    if target < 0 or target >= length(list) do
      list
    else
      a = Enum.at(list, index)
      b = Enum.at(list, target)
      list |> List.replace_at(index, b) |> List.replace_at(target, a)
    end
  end

  defp error_text(changeset) do
    Enum.map_join(changeset.errors, ", ", fn {field, {msg, _}} -> "#{field} #{msg}" end)
  end

  defp general_fields, do: @general_fields
  defp standard_options, do: @standard_options
  defp tb_presets, do: @tb_presets
  defp officials_fields, do: @officials_fields
  defp deputy_fields, do: @deputy_fields
  defp pairing_system_options, do: @pairing_system_options
  defp rr_cycles_options, do: @rr_cycles_options

  defp o_get(tournament, key), do: Map.get(tournament.officials || %{}, key, "")

  # Results for the arbiter-autocomplete dropdown currently focused on
  # `role`, or `[]` if no field is focused/searching, or another field is.
  defp arbiter_results(%{role: role, results: results}, role), do: results
  defp arbiter_results(_search, _role), do: []

  defp arbiter_query("chief_arbiter", %{"tournament" => t}), do: Map.get(t, "chief_arbiter", "")

  defp arbiter_query("person_responsible_pairings", %{"tournament" => %{"officials" => o}}),
    do: Map.get(o, "person_responsible_pairings", "")

  defp arbiter_query("deputy" <> _ = role, %{"tournament" => %{"officials" => o}}),
    do: Map.get(o, "#{role}_name", "")

  defp arbiter_query(_role, _params), do: ""

  defp apply_arbiter_pick(tournament, "chief_arbiter", fp) do
    %{
      tournament
      | chief_arbiter: fp.name,
        officials: put_official(tournament, "chief_arbiter_fide_id", fp.fide_id)
    }
  end

  defp apply_arbiter_pick(tournament, "person_responsible_pairings", fp) do
    officials =
      tournament
      |> put_official("person_responsible_pairings", fp.name)
      |> Map.put("person_responsible_pairings_fide_id", fp.fide_id)

    %{tournament | officials: officials}
  end

  defp apply_arbiter_pick(tournament, "deputy" <> _ = role, fp) do
    officials =
      tournament
      |> put_official("#{role}_name", fp.name)
      |> Map.put("#{role}_fide_id", fp.fide_id)

    %{tournament | officials: officials}
  end

  defp apply_arbiter_pick(tournament, _role, _fp), do: tournament

  defp put_official(tournament, key, value), do: Map.put(tournament.officials || %{}, key, value)

  defp available_tiebreaks(selected) do
    Enum.reject(Tiebreaks.catalogue(), &(&1.code in selected))
  end

  defp tb_preset_match(tiebreaks) do
    Enum.find_value(@tb_presets, "personel", fn {key, _label, methods} ->
      if tiebreaks == methods, do: key
    end)
  end

  defp pad_dates(dates, count) do
    dates = dates || []
    dates = Enum.take(dates, count)
    dates ++ List.duplicate("", max(count - length(dates), 0))
  end

  defp rate_of_play_list("rapid"), do: @rate_of_play_rapid
  defp rate_of_play_list("blitz"), do: @rate_of_play_blitz
  defp rate_of_play_list(_standard), do: @rate_of_play_standard

  # Blank option first, then the active list for `standard`. If the
  # tournament's currently-stored rate of play isn't on that list (e.g. a
  # free-text value pulled in from a SWAR import), it's prepended as its
  # own extra option so it isn't silently dropped from the select.
  defp rate_of_play_select_options(standard, current) do
    list = rate_of_play_list(standard)

    if current not in [nil, ""] and current not in list do
      [current, ""] ++ list
    else
      [""] ++ list
    end
  end

  @weekday_names {"Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"}

  defp weekday_label(date) when date in [nil, ""], do: nil

  defp weekday_label(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> elem(@weekday_names, Date.day_of_week(parsed) - 1)
      {:error, _} -> nil
    end
  end

  defp apply_rate_of_play_override(params) do
    case String.trim(Map.get(params, "rate_of_play_other", "")) do
      "" -> params
      other -> Map.put(params, "rate_of_play", other)
    end
  end

  defp normalize_round_dates(params) do
    count =
      case Integer.parse(to_string(Map.get(params, "rounds_count", ""))) do
        {n, _} -> n
        :error -> length(List.wrap(Map.get(params, "round_dates", [])))
      end

    dates = params |> Map.get("round_dates", []) |> List.wrap()
    Map.put(params, "round_dates", pad_dates(dates, count))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      tournament={@tournament}
      active="settings"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>

          <p class="subtitle" style="margin: 0">Settings</p>
        </div>
        <span class={["badge", @tournament.status == "setup" && "muted"]}>{@tournament.status}</span>
      </div>

      <p :if={@stale} class="error-note">
        This tournament was updated elsewhere while you were editing. Saving will overwrite that
        change with what's on this page — reload the page first if you want to see it instead.
      </p>

      <form phx-submit="save">
        <div class="card">
          <h2>General</h2>

          <div class="form-grid">
            <label :for={{field, label, type, required} <- general_fields()} class="field">
              <span :if={required} style="font-weight: 700">
                {label} <span style="color: var(--danger)">*</span>
              </span>
              <span :if={!required}>{label}</span>
              <input
                type={type}
                name={"tournament[#{field}]"}
                value={Map.get(@tournament, String.to_existing_atom(field))}
              />
            </label>
          </div>
        </div>

        <div class="card">
          <h2>Format</h2>

          <div class="form-grid">
            <label class="field">
              <span>Tournament format</span>
              <select name="tournament[type]">
                <option
                  :for={type <- Tournament.types()}
                  value={type}
                  selected={@tournament.type == type}
                >
                  {Tournament.type_label(type)}
                </option>
              </select>
            </label>

            <label class="field">
              <span style="font-weight: 700">
                Number of rounds <span style="color: var(--danger)">*</span>
              </span>

              <input
                type="number"
                name="tournament[rounds_count]"
                value={@tournament.rounds_count}
                min="1"
                max="30"
              />
            </label>

            <label class="field">
              <span>Pairing system</span>
              <select name="tournament[pairing_system]" disabled={@pairing_system_locked?}>
                <option
                  :for={{val, label} <- pairing_system_options()}
                  value={val}
                  selected={@tournament.pairing_system == val}
                >
                  {label}
                </option>
              </select>
              <span :if={@pairing_system_locked?} class="hint">locked after first pairing</span>
            </label>

            <label class="field">
              <span>Cycles</span>
              <select name="tournament[rr_cycles]" disabled={@rr_cycles_locked?}>
                <option
                  :for={{val, label} <- rr_cycles_options()}
                  value={val}
                  selected={@tournament.rr_cycles == val}
                >
                  {label}
                </option>
              </select>
              <span :if={@rr_cycles_locked?} class="hint">locked after first pairing</span>
            </label>

            <label
              class="field"
              style="display: flex; flex-direction: row; align-items: center; gap: .5rem"
            >
              <input type="hidden" name="tournament[rr_match_format]" value="false" />
              <input
                type="checkbox"
                name="tournament[rr_match_format]"
                value="true"
                checked={@tournament.rr_match_format}
                disabled={@rr_match_format_locked?}
              />
              <span>Match format (immediate 2-game rematch, reversed colours)</span>
              <span :if={@rr_match_format_locked?} class="hint">locked after first pairing</span>
            </label>

            <label class="field">
              <span>Keizer top value (blank = automatic)</span>
              <input
                type="number"
                name="tournament[keizer_top_value]"
                value={@tournament.keizer_top_value}
                min="1"
              />
            </label>

            <label class="field">
              <span>Pair by</span>
              <select name="tournament[rating_type]">
                <option value="fide" selected={@tournament.rating_type == "fide"}>FIDE rating</option>

                <option value="national" selected={@tournament.rating_type == "national"}>
                  National rating
                </option>
              </select>
            </label>

            <label class="field">
              <span>Acceleration</span>
              <select name="tournament[acceleration]">
                <option value="none" selected={@tournament.acceleration == "none"}>None</option>

                <option value="baku" selected={@tournament.acceleration == "baku"}>
                  Baku acceleration (FIDE C.04.5)
                </option>
              </select>
              <span class="hint">Swiss only — round robin and Keizer ignore this setting</span>
            </label>

            <label
              class="field"
              style="display: flex; flex-direction: row; align-items: center; gap: .5rem"
            >
              <input type="hidden" name="tournament[swiss_match_format]" value="false" />
              <input
                type="checkbox"
                name="tournament[swiss_match_format]"
                value="true"
                checked={@tournament.swiss_match_format}
                disabled={@swiss_match_format_locked?}
              />
              <span>Match format (immediate 2-game rematch, reversed colours)</span>
              <span :if={@swiss_match_format_locked?} class="hint">locked after first pairing</span>
            </label>
            <p class="hint" style="margin-top: -8px">
              Swiss only — requires an even number of rounds (each match is 2 rounds)
            </p>

            <label
              class="field"
              style="display: flex; flex-direction: row; align-items: center; gap: .5rem"
            >
              <input type="hidden" name="tournament[pair_by_category]" value="false" />
              <input
                type="checkbox"
                name="tournament[pair_by_category]"
                value="true"
                checked={@tournament.pair_by_category}
                disabled={@pair_by_category_locked? or not @tournament.categories_enabled}
              />
              <span>Pair each category independently</span>
              <span :if={@pair_by_category_locked?} class="hint">locked after first pairing</span>
              <span :if={not @tournament.categories_enabled and not @pair_by_category_locked?} class="hint">
                enable categories first
              </span>
            </label>
            <p class="hint" style="margin-top: -8px">
              Swiss only — each category gets its own independent pairings and byes within one combined round
            </p>

            <label class="field">
              <span>Type</span>
              <select name="tournament[standard]" phx-change="standard_change">
                <option
                  :for={{val, label} <- standard_options()}
                  value={val}
                  selected={@standard == val}
                >
                  {label}
                </option>
              </select>
            </label>

            <label class="field">
              <span>Rate of play</span>
              <select name="tournament[rate_of_play]">
                <option
                  :for={opt <- rate_of_play_select_options(@standard, @rate_of_play)}
                  value={opt}
                  selected={opt == @rate_of_play}
                >
                  {if opt == "", do: "— none —", else: opt}
                </option>
              </select>
            </label>

            <label class="field">
              <span>Other rate of play (overrides the select above)</span>
              <input
                type="text"
                name="tournament[rate_of_play_other]"
                value=""
                placeholder="e.g. 40 min + 10 sec/move"
              />
            </label>
          </div>
        </div>

        <div class="card">
          <h2>Officials &amp; FIDE report data</h2>

          <p class="hint" style="margin-top: 0">
            Feeds the IT3 / FA1 / IA1 / IT4 FIDE report forms on the
            <.link navigate={~p"/t/#{@tournament.id}/norms"}>Norms</.link>
            tab. Organizer name is set in General above; pairing mode is always computerized and
            the pairing program is always OpenPairings.
          </p>

          <div class="form-grid">
            <label class="field">
              <span>FIDE tournament ID</span>
              <input name="tournament[fide_tournament_id]" value={@tournament.fide_tournament_id} />
            </label>

            <label class="field">
              <span>FIDE event code</span>
              <input name="tournament[event_code]" value={@tournament.event_code} />
            </label>

            <label :for={{key, label, type} <- officials_fields()} class="field">
              <span>{label}</span>
              <input
                type={type}
                name={"tournament[officials][#{key}]"}
                value={o_get(@tournament, key)}
              />
            </label>

            <div class="field search-wrap">
              <span style="display:block;font-size:13px;font-weight:600;color:var(--text-soft);margin-bottom:4px">
                Chief arbiter
              </span>

              <input
                type="text"
                name="tournament[chief_arbiter]"
                value={@tournament.chief_arbiter}
                phx-change="arbiter_search"
                phx-value-role="chief_arbiter"
                phx-debounce="250"
                autocomplete="off"
              />
              <!-- No visible input for chief_arbiter_fide_id any more (a FIDE
                   pick sets it, see arbiter_pick/3) — carried through the
                   big form's submit via this hidden field so it survives
                   the officials map's full-replace cast on Save; without it
                   a save right after a pick (with no other officials edit)
                   would silently drop the id the user just picked. -->
              <input
                type="hidden"
                name="tournament[officials][chief_arbiter_fide_id]"
                value={o_get(@tournament, "chief_arbiter_fide_id")}
              />
              <span :if={o_get(@tournament, "chief_arbiter_fide_id") != ""} class="hint">
                FIDE ID: {o_get(@tournament, "chief_arbiter_fide_id")}
              </span>

              <div
                :if={arbiter_results(@arbiter_search, "chief_arbiter") != []}
                class="search-results"
              >
                <button
                  :for={fp <- arbiter_results(@arbiter_search, "chief_arbiter")}
                  type="button"
                  phx-click="arbiter_pick"
                  phx-value-role="chief_arbiter"
                  phx-value-fide-id={fp.fide_id}
                >
                  <span>{if fp.title != "", do: "#{fp.title} "}{fp.name}</span>
                  <span class="meta">{fp.federation}</span>
                </button>
              </div>
            </div>

            <div class="field search-wrap">
              <span style="display:block;font-size:13px;font-weight:600;color:var(--text-soft);margin-bottom:4px">
                Person responsible for pairings
              </span>

              <input
                type="text"
                name="tournament[officials][person_responsible_pairings]"
                value={o_get(@tournament, "person_responsible_pairings")}
                phx-change="arbiter_search"
                phx-value-role="person_responsible_pairings"
                phx-debounce="250"
                autocomplete="off"
              />
              <input
                type="hidden"
                name="tournament[officials][person_responsible_pairings_fide_id]"
                value={o_get(@tournament, "person_responsible_pairings_fide_id")}
              />
              <div
                :if={arbiter_results(@arbiter_search, "person_responsible_pairings") != []}
                class="search-results"
              >
                <button
                  :for={fp <- arbiter_results(@arbiter_search, "person_responsible_pairings")}
                  type="button"
                  phx-click="arbiter_pick"
                  phx-value-role="person_responsible_pairings"
                  phx-value-fide-id={fp.fide_id}
                >
                  <span>{if fp.title != "", do: "#{fp.title} "}{fp.name}</span>
                  <span class="meta">{fp.federation}</span>
                </button>
              </div>
            </div>

            <label class="field">
              <span>IT4 event type</span>
              <input
                name="tournament[officials][it4_event_type]"
                value={o_get(@tournament, "it4_event_type")}
              />
            </label>

            <label class="field" style="grid-column: 1 / -1">
              <span>Link to pairings web (IT4)</span>
              <input
                name="tournament[officials][pairings_web_link]"
                value={o_get(@tournament, "pairings_web_link")}
              />
            </label>
          </div>

          <h3 style="margin: 18px 0 8px; font-size: 14px">Deputy arbiters</h3>

          <div class="form-grid">
            <div :for={{n, label} <- deputy_fields()} style="display: contents">
              <div class="field search-wrap">
                <span style="display:block;font-size:13px;font-weight:600;color:var(--text-soft);margin-bottom:4px">
                  {label} — name
                </span>

                <input
                  type="text"
                  name={"tournament[officials][deputy#{n}_name]"}
                  value={o_get(@tournament, "deputy#{n}_name")}
                  phx-change="arbiter_search"
                  phx-value-role={"deputy#{n}"}
                  phx-debounce="250"
                  autocomplete="off"
                />
                <input
                  type="hidden"
                  name={"tournament[officials][deputy#{n}_fide_id]"}
                  value={o_get(@tournament, "deputy#{n}_fide_id")}
                />
                <span :if={o_get(@tournament, "deputy#{n}_fide_id") != ""} class="hint">
                  FIDE ID: {o_get(@tournament, "deputy#{n}_fide_id")}
                </span>

                <div
                  :if={arbiter_results(@arbiter_search, "deputy#{n}") != []}
                  class="search-results"
                >
                  <button
                    :for={fp <- arbiter_results(@arbiter_search, "deputy#{n}")}
                    type="button"
                    phx-click="arbiter_pick"
                    phx-value-role={"deputy#{n}"}
                    phx-value-fide-id={fp.fide_id}
                  >
                    <span>{if fp.title != "", do: "#{fp.title} "}{fp.name}</span>
                    <span class="meta">{fp.federation}</span>
                  </button>
                </div>
              </div>

              <label class="field">
                <span>{label} — e-mail</span>
                <input
                  name={"tournament[officials][deputy#{n}_email]"}
                  value={o_get(@tournament, "deputy#{n}_email")}
                />
              </label>
            </div>
          </div>

          <h3 style="margin: 18px 0 8px; font-size: 14px">Special remarks (IT3)</h3>

          <div class="form-grid">
            <label :for={n <- 1..4} class="field">
              <span>Remark {n}</span>
              <input
                name={"tournament[officials][remark#{n}]"}
                value={o_get(@tournament, "remark#{n}")}
              />
            </label>
          </div>
        </div>

        <div class="card">
          <h2>Scoring</h2>

          <div class="form-grid">
            <label class="field">
              <span>Points for a win</span>
              <input
                type="number"
                step="0.5"
                name="tournament[points_win]"
                value={@tournament.points_win}
              />
            </label>

            <label class="field">
              <span>Points for a draw</span>
              <input
                type="number"
                step="0.5"
                name="tournament[points_draw]"
                value={@tournament.points_draw}
              />
            </label>

            <label class="field">
              <span>Points for a loss</span>
              <input
                type="number"
                step="0.5"
                name="tournament[points_loss]"
                value={@tournament.points_loss}
              />
            </label>

            <label class="field">
              <span>Pairing-allocated bye worth</span>
              <input
                type="number"
                step="0.5"
                name="tournament[bye_value]"
                value={@tournament.bye_value}
              />
            </label>
          </div>
        </div>

        <div class="card">
          <h2>Categories</h2>

          <label
            class="field"
            style="display: flex; flex-direction: row; align-items: center; gap: .5rem"
          >
            <input type="hidden" name="tournament[categories_enabled]" value="false" />
            <input
              type="checkbox"
              name="tournament[categories_enabled]"
              value="true"
              checked={@tournament.categories_enabled}
            /> <span>Enable the Categories tab (category groups + extra points)</span>
          </label>
        </div>

        <div class="card">
          <h2>Round dates</h2>

          <p class="hint" style="margin-top: 0">
            One date per round (SWAR Dates tab). Leave blank if unknown; two or more rounds can
            share the same date (e.g. a Saturday double round).
          </p>

          <div class="form-grid">
            <label
              :for={{date, i} <- Enum.with_index(@round_dates)}
              class="field"
              style="display: flex; flex-direction: column; justify-content: flex-end"
            >
              <span>
                Round {i + 1}
                <span :if={weekday_label(date)} class="hint">({weekday_label(date)})</span>
              </span>
              <input type="date" name="tournament[round_dates][]" value={date} />
            </label>
          </div>

          <div class="actions" style="flex-wrap: wrap">
            <button type="button" class="pe-btn" phx-click="rd_fill_sequential">
              Fill sequentially from start date
            </button>

            <button type="button" class="pe-btn" phx-click="rd_calc">
              Calculate weekly from start date
            </button>
            <button type="button" class="pe-btn" phx-click="rd_clear">Clear all</button>
          </div>
        </div>

        <div class="card">
          <h2>Tiebreaks</h2>

          <p class="hint" style="margin-top: 0">
            Applied in order, following the FIDE Tie-Break Regulations. Higher in the list = decided first.
          </p>

          <div class="field" style="margin-bottom: 1rem">
            <span>Preset</span>
            <div style="display: flex; flex-wrap: wrap; gap: 1rem">
              <label style="display: flex; gap: .35rem; align-items: center; font-weight: 400">
                <input
                  type="radio"
                  name="tb_preset_display"
                  phx-click="tb_preset"
                  phx-value-key="personel"
                  checked={tb_preset_match(@tiebreaks) == "personel"}
                /> Custom
              </label>

              <label
                :for={{key, label, _methods} <- tb_presets()}
                style="display: flex; gap: .35rem; align-items: center; font-weight: 400"
              >
                <input
                  type="radio"
                  name="tb_preset_display"
                  phx-click="tb_preset"
                  phx-value-key={key}
                  checked={tb_preset_match(@tiebreaks) == key}
                /> {label}
              </label>
            </div>
          </div>

          <ol class="tb-list">
            <li :for={{code, i} <- Enum.with_index(@tiebreaks)}>
              <span class="tb-order">{i + 1}.</span>
              <div>
                <div class="tb-name">{tb_name(code)}</div>

                <div class="tb-desc">{tb_desc(code)}</div>
              </div>

              <div class="tb-buttons">
                <button
                  type="button"
                  class="pe-btn"
                  title="Move up"
                  disabled={i == 0}
                  phx-click="tb_up"
                  phx-value-index={i}
                >
                  ↑
                </button>

                <button
                  type="button"
                  class="pe-btn"
                  title="Move down"
                  disabled={i == length(@tiebreaks) - 1}
                  phx-click="tb_down"
                  phx-value-index={i}
                >
                  ↓
                </button>

                <button
                  type="button"
                  class="pe-btn"
                  title="Remove"
                  phx-click="tb_remove"
                  phx-value-code={code}
                >
                  ✕
                </button>
              </div>
            </li>
          </ol>

          <p :if={@tiebreaks == []} class="hint">
            No tiebreaks selected — tied players will share a rank.
          </p>

          <div class="actions" style="flex-wrap: wrap">
            <select phx-change="tb_add" name="code" style="width: auto" class="pe-select">
              <option value="">Add a tiebreak…</option>

              <option :for={tb <- available_tiebreaks(@tiebreaks)} value={tb.code}>{tb.name}</option>
            </select>
            <button type="button" class="pe-btn" phx-click="tb_reset">Reset to FIDE default</button>
          </div>
        </div>

        <div class="actions">
          <button type="submit" class="pe-btn primary">Save settings</button>
          <span :if={@note} class="ok-note" style="align-self: center">{@note}</span>
          <span :if={@error} class="error-note" style="align-self: center">{@error}</span>
        </div>
      </form>

      <div :if={@owner?} class="card">
        <h2>Share / Team</h2>

        <p class="hint" style="margin-top: 0">
          Invite other people to this tournament by email — they can open, edit, pair, enter
          results, print and export it, exactly like you, except they can't manage collaborators or
          delete the tournament. They only get access once they explicitly accept the emailed
          invitation while signed in with their own email
          (<.link navigate={~p"/users/log-in"}>magic link</.link>) — no shared password needed.
        </p>

        <form id="add-collaborator-form" phx-submit="add_collaborator">
          <div class="form-grid">
            <label class="field">
              <span>Email address</span>
              <input type="email" name="email" placeholder="teammate@example.com" />
            </label>
          </div>

          <p :if={@collaborator_error} class="error-note">{@collaborator_error}</p>

          <p :if={@collaborator_note} class="hint">{@collaborator_note}</p>

          <div class="actions">
            <button type="submit" class="pe-btn primary">Add collaborator</button>
          </div>
        </form>

        <div :if={@collaborators != []} class="card-table-wrap" style="margin-top: 16px">
          <table class="pe-table">
            <thead>
              <tr>
                <th>Email</th>

                <th>Status</th>

                <th></th>
              </tr>
            </thead>

            <tbody>
              <tr :for={c <- @collaborators}>
                <td>{c.email}</td>

                <td>
                  <span class={["badge", c.status != "accepted" && "muted"]}>
                    {if c.status == "accepted", do: "active", else: "invited (waiting for accept)"}
                  </span>
                </td>

                <td style="text-align: right">
                  <button
                    class="pe-btn danger-link"
                    phx-click="remove_collaborator"
                    phx-value-id={c.id}
                  >
                    Remove
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <p :if={@collaborators == []} class="hint" style="margin-bottom: 0">
          Nobody else has access to this tournament yet.
        </p>
      </div>

      <div class="card">
        <h2>Forbidden pairings</h2>

        <p class="hint" style="margin-top: 0">
          Two players who must never be paired against each other. Applies to Swiss pairing
          (a JaVaFo "XXP" rule) and to Keizer; a round robin's fixed schedule ignores this by design.
        </p>

        <form id="add-forbidden-pairing-form" phx-submit="add_forbidden_pairing">
          <div class="form-grid">
            <label class="field">
              <span>Player A</span>
              <select name="player_a_id" class="pe-select">
                <option
                  :for={p <- @forbidden_pairing_players}
                  value={p.id}
                >
                  {p.name}
                </option>
              </select>
            </label>

            <label class="field">
              <span>Player B</span>
              <select name="player_b_id" class="pe-select">
                <option
                  :for={p <- @forbidden_pairing_players}
                  value={p.id}
                >
                  {p.name}
                </option>
              </select>
            </label>
          </div>

          <p :if={@forbidden_pairing_error} class="error-note">{@forbidden_pairing_error}</p>

          <div class="actions">
            <button
              type="submit"
              class="pe-btn primary"
              disabled={length(@forbidden_pairing_players) < 2}
            >
              Add
            </button>
          </div>
        </form>

        <div :if={@forbidden_pairings != []} class="card-table-wrap" style="margin-top: 16px">
          <table class="pe-table">
            <thead>
              <tr>
                <th>Pair</th>

                <th></th>
              </tr>
            </thead>

            <tbody>
              <tr :for={fp <- @forbidden_pairings}>
                <td>{fp.player_a.name} — {fp.player_b.name}</td>

                <td style="text-align: right">
                  <button
                    class="pe-btn danger-link"
                    phx-click="remove_forbidden_pairing"
                    phx-value-id={fp.id}
                  >
                    Remove
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <p :if={@forbidden_pairings == []} class="hint" style="margin-bottom: 0">
          No forbidden pairings yet.
        </p>

        <h3 style="margin-top: 24px">Club / federation exclusions</h3>

        <p class="hint" style="margin-top: 0">
          Automatically forbid pairing any two players who share a club or federation, instead of
          listing every pair by hand. Applies to Swiss (JaVaFo "XXP" rules, same as above) and to
          Keizer; a round robin's fixed schedule ignores this by design.
        </p>

        <form id="exclusion-rules-form" phx-submit="save_exclusions">
          <div class="form-grid">
            <label class="field">
              <span>Clubs</span>
              <select
                name="tournament[club_exclusion]"
                class="pe-select"
                phx-change="club_exclusion_mode_change"
              >
                <option
                  :for={m <- Tournament.exclusion_modes()}
                  value={m}
                  selected={m == @club_exclusion_mode}
                >
                  {Tournament.exclusion_mode_label(m)}
                </option>
              </select>
            </label>

            <label :if={@club_exclusion_mode == "listed"} class="field">
              <span>Clubs (comma-separated)</span>
              <input
                type="text"
                name="tournament[club_exclusion_list]"
                value={@tournament.club_exclusion_list}
                placeholder="e.g. Chess Club A, Chess Club B"
              />
            </label>

            <label class="field">
              <span>Federations</span>
              <select
                name="tournament[fed_exclusion]"
                class="pe-select"
                phx-change="fed_exclusion_mode_change"
              >
                <option
                  :for={m <- Tournament.exclusion_modes()}
                  value={m}
                  selected={m == @fed_exclusion_mode}
                >
                  {Tournament.exclusion_mode_label(m)}
                </option>
              </select>
            </label>

            <label :if={@fed_exclusion_mode == "listed"} class="field">
              <span>Federations (comma-separated)</span>
              <input
                type="text"
                name="tournament[fed_exclusion_list]"
                value={@tournament.fed_exclusion_list}
                placeholder="e.g. BEL, NED"
              />
            </label>
          </div>

          <p class="hint" style="margin-bottom: 0">
            {@excluded_pair_count} pair(s) currently excluded by these rules.
          </p>

          <p :if={@exclusion_error} class="error-note">{@exclusion_error}</p>

          <div class="actions">
            <button type="submit" class="pe-btn primary">Save exclusion rules</button>
          </div>
        </form>
      </div>

      <div class="card">
        <h2>Logo</h2>

        <p class="hint" style="margin-top: 0">
          Shown on printed documents (place cards, and any other print page that has a logo slot —
          see <.link navigate={~p"/t/#{@tournament.id}/print"}>Print</.link>). Only raster images
          (PNG, JPEG, GIF, WebP) are accepted — SVG is rejected, since it can carry scripts and this
          image is embedded straight back into pages the app serves. Capped at 2&nbsp;MB.
        </p>

        <div :if={@tournament.logo_data} class="field" style="margin-bottom: 1rem">
          <span>Current logo</span>
          <img
            src={Tournaments.logo_data_uri(@tournament)}
            alt="Tournament logo"
            style="max-height: 80px; max-width: 240px; display: block; margin-top: 6px"
          />
          <div class="actions" style="margin-top: 8px">
            <button type="button" class="pe-btn danger-link" phx-click="clear_logo">
              Remove logo
            </button>
          </div>
        </div>

        <form id="logo-upload-form" phx-submit="upload_logo" phx-change="validate_logo">
          <div class={["dropzone", @uploads.logo.entries != [] && "has-file"]}>
            <.live_file_input upload={@uploads.logo} class="dropzone-input" />
            <div class="dropzone-label">
              <%= if @uploads.logo.entries == [] do %>
                <strong>Choose a PNG, JPEG, GIF or WebP image</strong>
                <span class="hint">or drag and drop it here</span>
              <% else %>
                <span :for={entry <- @uploads.logo.entries} class="dropzone-file">
                  {entry.client_name}
                </span>
              <% end %>
            </div>
          </div>

          <p :for={err <- upload_errors(@uploads.logo)} class="error-note">{inspect(err)}</p>

          <div class="actions">
            <button type="submit" class="pe-btn primary" disabled={@uploads.logo.entries == []}>
              Upload logo
            </button>
          </div>
        </form>
      </div>

      <div class="card">
        <h2>Export / backup</h2>

        <p class="hint" style="margin-top: 0">
          A full JSON backup of this tournament — settings, officials, every player (including norm
          data), rounds, pairings/results, byes and forbidden pairings. Re-importing it (from the
          <.link navigate={~p"/"}>Tournaments</.link>
          page) always creates a brand-new tournament, never overwrites this one. For a FIDE-report-shaped
          TRF16 file instead, see <.link navigate={~p"/t/#{@tournament.id}/pairings"}>Pairings</.link>{if @tournament.manual_ranking,
            do: " — note its rank column is the computed order, not manual ranking's hand-set one"}.
        </p>

        <div class="actions">
          <a class="pe-btn" href={~p"/t/#{@tournament.id}/export/json"} target="_blank">
            Export full backup (JSON)
          </a>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp tb_name(code), do: (Tiebreaks.get(code) || %{name: code}).name
  defp tb_desc(code), do: (Tiebreaks.get(code) || %{description: ""}).description
end
