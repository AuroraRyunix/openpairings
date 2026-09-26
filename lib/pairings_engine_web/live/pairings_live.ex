defmodule PairingsEngineWeb.PairingsLive do
  use PairingsEngineWeb, :live_view

  alias PairingsEngineWeb.PublicLink

  import PairingsEngineWeb.SettingsSupport, only: [setup_field_path: 2, error_text: 1]

  alias PairingsEngine.{
    Audit,
    PairingDisplay,
    PairingRationale,
    PostponedGames,
    ResultsImport,
    RoundRobin,
    Snapshots,
    Standings,
    TeamMatches,
    Tournaments
  }

  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.Tournament
  alias PairingsEngineWeb.Postponed

  @results [
    {"", "…"},
    {"1-0", "1-0"},
    {"1/2-1/2", "½-½"},
    {"0-1", "0-1"},
    {"1/2-0", "½-0 (asymmetric - disciplinary point adjustment)"},
    {"0-1/2", "0-½ (asymmetric - disciplinary point adjustment)"},
    {"1-0FF", "1-0 FF (White wins by forfeit)"},
    {"0-1FF", "0-1 FF (Black wins by forfeit)"},
    {"0-0FF", "0-0 FF (double forfeit)"},
    {"0-0", "0-0 (both lose, game played)"},
    {"1-0U", "1-0 (played, not rated)"},
    {"0-1U", "0-1 (played, not rated)"},
    {"1/2-1/2U", "½-½ (played, not rated)"},
    # Labelled at render time by `results/2`, so the words go through
    # gettext, and offered only where the tournament allows postponed games.
    {"*W", :postponed_white},
    {"*B", :postponed_black}
  ]

  # The labels above belong to this page; the CODES do not. They must be
  # exactly what an arbiter is allowed to write, and that list lives in
  # PairingsEngine.Results - so a code added there and forgotten here (or
  # the reverse) fails the build instead of quietly becoming unenterable.
  @offered Enum.map(@results, &elem(&1, 0))
  if Enum.sort(@offered) != Enum.sort(PairingsEngine.Results.entry_codes()) do
    raise "PairingsLive @results has drifted from PairingsEngine.Results.entry_codes/0: " <>
            "#{inspect(@offered -- PairingsEngine.Results.entry_codes())} offered here only, " <>
            "#{inspect(PairingsEngine.Results.entry_codes() -- @offered)} missing here"
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)
    paired = Engine.paired_rounds_count(tournament.id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     socket
     |> assign(
       tournament: tournament,
       page_title: "#{tournament.name} · Pairings",
       round_number: max(paired, 1),
       error: nil,
       # Bumped whenever a result-entry write is REFUSED (e.g. an archived
       # tournament) - see the `result`/`confirm_clear_result` handlers'
       # comments and the `.BlindResultEntry` hook's `updated()` for why: a
       # refused write leaves every assign byte-identical to before, so
       # LiveView's diff for that board's <select> is empty and no patch is
       # sent - the browser's own "user just picked this option" native
       # state is left uncorrected, LOOKING like the change went through
       # even though nothing was written. Threading this counter into each
       # select's markup guarantees a patch fires on every refusal, so the
       # hook's existing data-result resync actually runs.
       write_refused_nonce: 0,
       # The postponed-game warnings the last "pair" click confirmed, and the
       # missing results it is recording as postponed - see
       # `handle_event("pair", ...)` and `note_recorded_missing/1`.
       pair_acknowledged: [],
       recorded_missing: nil,
       # Set while a team Swiss round is pairing in a supervised task (see
       # `do_pair_team_swiss_async/1`) - 300-500 teams can take 10-50
       # seconds, run IN THIS BEAM with no subprocess timeout of its own.
       # Kept out of the LiveView process while it runs so a slow search
       # can't be mistaken for a frozen page, and the "pair" handler uses it
       # to refuse a second click instead of starting a second search.
       pairing_in_progress: false,
       importing_results: false,
       import_errors: nil,
       # The pairing (if any) awaiting explicit confirmation to have its
       # result CLEARED - see `handle_event("result", ...)`'s guard below.
       confirm_clear_pairing_id: nil,
       # A postponed game given a result that is not a draw, staged until the
       # arbiter confirms it (`%{pairing_id:, result:}`) - VCL4THP Q163, see
       # `handle_event("confirm_postponed_result", ...)`.
       confirm_postponed: nil,
       # The board whose result select takes focus back when it reappears:
       # the clear-confirmation box replaces the select that had focus, and
       # without this closing the box dropped the keyboard at the top of the
       # page, mid-round.
       refocus_result: nil,
       # Hand-editing state - see "Editing a paired round by hand" below.
       # `menu` is the open right-click menu; `swap_first`/`pool_first` are
       # half-finished two-click gestures; `seat_pick` is a pool player
       # waiting to be told WHICH vacancy to fill; `confirm` is the staged
       # change, and the only one of these that can write anything.
       menu: nil,
       swap_first: nil,
       pool_first: nil,
       seat_pick: nil,
       confirm: nil
     )
     |> allow_upload(:results_csv, accept: :any, max_entries: 1, max_file_size: 2_000_000)
     |> refresh()}
  end

  # Results are entered inline (each select saves immediately on change, no
  # draft state to protect), so a broadcast can just reload everything -
  # including the tournament itself, since rounds_count/status can change
  # from the Settings page.
  #
  # This LiveView is subscribed to its own tournament's topic, so every
  # mutation it causes itself (pair/unpair/result/import) broadcasts right
  # back to this same process too - by the time that echo arrives, the
  # triggering `handle_event` has already called `refresh/1` synchronously,
  # so this just re-does the same (cheap) reload a second time. A visible
  # "updated by another arbiter" notice used to fire here too; removed -
  # it sat as a toast that kept surprising people mid-click regardless of
  # how it was positioned, and the round data refreshing live underneath
  # it is the part that actually matters.
  @impl true
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
        # Real report: an arbiter had "pair with another player who isn't
        # playing…" staged behind its confirm dialog when someone ELSE
        # entered a totally unrelated result elsewhere in the round - and
        # got silently bounced out, as if they'd hit Escape themselves.
        # `keep_gesture: true` here is the fix: a REMOTE broadcast leaves
        # any half-finished menu/swap/confirm gesture alone (the round data
        # underneath it still refreshes fully either way, so whatever gets
        # applied is checked against the current state regardless - see
        # each `Tournaments.*` write function's own guards). Only the
        # arbiter's OWN completed action (every other `refresh()` call
        # site, still defaulting to reset) clears it - that's the point
        # where the gesture is genuinely done, not a bystander update.
        {:noreply, socket |> assign(tournament: tournament) |> refresh(keep_gesture: true)}
    end
  end

  # The team Swiss pairing task's reply - see `do_pair_team_swiss_async/1`.
  # `tournament.id` is checked against the CURRENT tournament - if the
  # arbiter has since navigated to a different tournament's Pairings page in
  # the same LiveView (impossible today, this LiveView is mounted per `:id`,
  # but cheap insurance against a future navigate_to that reuses the
  # process) a stray reply is dropped rather than misapplied.
  def handle_info({:team_pairing_result, tournament_id, result}, socket) do
    if socket.assigns.tournament.id == tournament_id do
      apply_pair_result(assign(socket, pairing_in_progress: false), result)
    else
      {:noreply, socket}
    end
  end

  defp refresh(socket, opts \\ []) do
    %{tournament: t, round_number: n} = socket.assigns
    paired = Engine.paired_rounds_count(t.id)
    postponed_open = PostponedGames.open_games(t)
    missing_setup = Tournament.missing_setup_fields(t)
    setup_complete = missing_setup == []
    round = Tournaments.get_round(t.id, n)

    socket =
      assign(socket,
        round: round,
        # Fully-vacated rows the arbiter has hidden from the main table
        # (see `set_pairing_hidden/3`) - kept as their own list so the
        # "Hidden boards" management panel can still offer Unhide/Delete
        # even though `display_rows/1` skips them everywhere else.
        hidden_pairings: (round && Enum.filter(round.pairings, & &1.hidden)) || [],
        # Each player's score coming INTO round `n` - shown next to their
        # name on the board list, same as a real printed pairing sheet.
        scores: Standings.player_scores_before_round(t, n),
        # The pool is a superset of `list_byes_for_round/2` - it adds anyone
        # simply unpaired - so the byes-only query this page used to run is
        # no longer needed here. Other views still use it.
        round_pool: Tournaments.list_round_pool(t.id, n),
        # The pool chips' absence counts, built once per refresh rather
        # than queried once per chip (`Standings.absent_counts/1`). Empty,
        # and no query at all, unless the tournament caps "Pt ABSENT" by
        # occurrence - which is why this was easy to miss.
        absent_counts: Standings.absent_counts(t),
        paired_rounds: paired,
        next_pairable: paired + 1,
        setup_complete: setup_complete,
        missing_setup: missing_setup,
        recommended_missing: Tournament.missing_recommended_fields(t),
        can_pair:
          setup_complete and paired < t.rounds_count and Engine.round_complete?(t.id, paired),
        # Postponed games (VCL4THP Q157-169): every one still to be played,
        # so it can be found and given its result from any round, and the
        # warnings pairing the next round comes with.
        postponed_open: postponed_open,
        pairing_warnings: PostponedGames.pairing_warnings(t, postponed_open),
        team_matches: team_matches(t, round),
        teams_by_id: teams_by_id(t),
        unattached_boards: unattached_boards(t, round)
      )

    if Keyword.get(opts, :keep_gesture, false) do
      socket
    else
      # Whatever a half-finished gesture was pointing at may no longer be
      # current by the time OUR OWN action just completed here (a round
      # switch, or the change's own confirmed write) - safer to drop back
      # to "nothing selected" than to leave a just-consumed gesture
      # sitting around.
      assign(socket, menu: nil, swap_first: nil, pool_first: nil, seat_pick: nil, confirm: nil)
    end
  end

  # The matches of a tournament paired as teams, for the round on screen - the
  # summary card above the board list. Empty for every other tournament
  # (including a team Swiss paired player by player), so nothing about an
  # individual event's page changes.
  defp team_matches(t, round) do
    if round && Tournament.paired_as_teams?(t) do
      t
      |> PairingsEngine.TeamStandings.matches(through_round: round.number)
      |> Enum.filter(&(&1.round == round.number))
    else
      []
    end
  end

  # Boards of a round paired as teams that belong to no match - added by hand
  # from the pool, or left over from an import that could not rebuild the
  # round's matches - each with where it would fit, if anywhere
  # (`TeamMatches.fitting_slot/5`). They count for neither team, and the page
  # says so.
  defp unattached_boards(t, round) do
    if round do
      t
      |> TeamMatches.unattached_boards(round)
      |> Enum.map(fn p ->
        slot =
          if p.white_player_id && p.black_player_id,
            do: TeamMatches.fitting_slot(t, round, p.white_player_id, p.black_player_id, p.id),
            else: {:error, :no_team}

        %{pairing: p, slot: slot}
      end)
    else
      []
    end
  end

  defp no_team?(unattached, pairing), do: Enum.any?(unattached, &(&1.pairing.id == pairing.id))

  # The marker beside the board number of a board that belongs to no match.
  # Rendered only for such a board, so every other board's cell stays exactly
  # `<td class="num">N</td>`.
  defp no_team(assigns) do
    ~H"""
    <span class="badge" title={gettext("Not part of a match: counts for no team")}>
      {gettext("no team")}<span class="sr-only">{gettext(": not part of a match, counts for no team")}</span>
    </span>
    """
  end

  # The initial colour, where a Swiss has one to show (C.04.3 Art. 5.1,
  # C.04.6 Art. 4.1): what the lot gave, or what the arbiter set. Nothing
  # before a draw, for round robin and Keizer, or for an event paired before
  # the draw was recorded.
  defp initial_colour_text(%Tournament{pairing_system: "swiss"} = t) do
    PairingsEngineWeb.SettingsSupport.initial_colour_status(t)
  end

  defp initial_colour_text(_t), do: nil

  defp teams_by_id(t) do
    if Tournament.team?(t),
      do: t.id |> Tournaments.list_teams() |> Map.new(&{&1.id, &1}),
      else: %{}
  end

  defp match_team_name(teams_by_id, id) do
    case Map.get(teams_by_id, id) do
      nil -> "-"
      team -> team.name
    end
  end

  defp match_board_range([]), do: "-"

  defp match_board_range(boards) do
    numbers = Enum.map(boards, & &1.pairing.board)
    "#{Enum.min(numbers)}-#{Enum.max(numbers)}"
  end

  defp format_match_score(n) when is_float(n),
    do: if(n == Float.round(n, 0), do: trunc(n), else: n)

  defp format_match_score(n), do: n

  @impl true
  def handle_event("select_round", %{"number" => number}, socket) do
    {:noreply,
     socket
     |> assign(round_number: String.to_integer(number), error: nil, refocus_result: nil)
     |> refresh()}
  end

  def handle_event("pair", params, socket) do
    socket = assign(socket, pair_acknowledged: acknowledged(params))

    cond do
      # Belt and braces beside the button's own `disabled` - a second "pair"
      # event that reached the mailbox before the first one's task replied
      # (e.g. a double-click landing faster than the DOM patch that disables
      # the button) must not start a second search for the same round.
      socket.assigns.pairing_in_progress ->
        {:noreply, socket}

      not Tournament.setup_complete?(socket.assigns.tournament) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Finish the tournament setup before pairing - missing: " <>
             missing_setup_summary(socket.assigns.missing_setup)
         )}

      true ->
        do_pair(socket)
    end
  end

  def handle_event("unpair", _params, socket) do
    %{tournament: t, round_number: round_number} = socket.assigns

    # Unpairing deletes the round and every result in it. Snapshot first -
    # see PairingsEngine.Snapshots for why this sits at the call site and
    # why its result is ignored.
    Snapshots.capture(t, "pairing.round_deleted", socket.assigns.current_scope,
      summary: "Before unpairing round #{round_number}"
    )

    case Engine.delete_round(t.id, round_number) do
      :ok ->
        Audit.log(t.id, socket.assigns.current_scope, "pairing.round_deleted", %{
          round: round_number
        })

        {:noreply, socket |> assign(error: nil) |> refresh()}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  # The four publish/unpublish controls - see the "Publishing pairings and
  # standings" section of `PairingsEngine.Tournaments` for the four rules
  # these implement, and `CoreComponents.publish_toggle/1` for the button
  # that sends them. `round` comes from `phx-value-round` on each toggle
  # rather than `socket.assigns.round` (the round being VIEWED) so the
  # round-context-menu's copy of these controls - which can target a round
  # other than the one on screen - and the on-page copy share one pair of
  # handlers.
  def handle_event("publish_pairings", %{"round" => round}, socket) do
    tournament = socket.assigns.tournament
    round_number = String.to_integer(round)

    case Tournaments.publish_pairings_through(tournament, round_number) do
      {:ok, tournament} ->
        Audit.log(tournament.id, socket.assigns.current_scope, "pairing.pairings_published", %{
          through_round: round_number
        })

        {:noreply, socket |> assign(tournament: tournament) |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_text(reason))}
    end
  end

  def handle_event("unpublish_pairings", %{"round" => round}, socket) do
    tournament = socket.assigns.tournament
    round_number = String.to_integer(round)

    case Tournaments.unpublish_pairings_through(tournament, round_number) do
      {:ok, tournament} ->
        Audit.log(tournament.id, socket.assigns.current_scope, "pairing.pairings_unpublished", %{
          from_round: round_number
        })

        {:noreply, socket |> assign(tournament: tournament) |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_text(reason))}
    end
  end

  def handle_event("publish_standings", %{"round" => round}, socket) do
    tournament = socket.assigns.tournament
    round_number = String.to_integer(round)

    case Tournaments.publish_standings_through(tournament, round_number) do
      {:ok, tournament} ->
        Audit.log(tournament.id, socket.assigns.current_scope, "standings.published", %{
          through_round: round_number
        })

        {:noreply, socket |> assign(tournament: tournament) |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_text(reason))}
    end
  end

  def handle_event("unpublish_standings", %{"round" => round}, socket) do
    tournament = socket.assigns.tournament
    round_number = String.to_integer(round)

    case Tournaments.unpublish_standings_through(tournament, round_number) do
      {:ok, tournament} ->
        Audit.log(tournament.id, socket.assigns.current_scope, "standings.unpublished", %{
          from_round: round_number
        })

        {:noreply, socket |> assign(tournament: tournament) |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_text(reason))}
    end
  end

  # The third switch, "Results round N" - see the "Publishing a round's
  # results" section of `PairingsEngine.Tournaments`. Per round, not
  # cumulative: switching round 3's results on says nothing about round 2's.
  def handle_event("publish_results", %{"round" => round}, socket) do
    tournament = socket.assigns.tournament
    round_number = String.to_integer(round)

    case Tournaments.publish_results(tournament, round_number) do
      {:ok, tournament} ->
        Audit.log(tournament.id, socket.assigns.current_scope, "pairing.results_published", %{
          round: round_number
        })

        {:noreply, socket |> assign(tournament: tournament) |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, results_error_text(reason))}
    end
  end

  def handle_event("unpublish_results", %{"round" => round}, socket) do
    tournament = socket.assigns.tournament
    round_number = String.to_integer(round)

    case Tournaments.unpublish_results(tournament, round_number) do
      {:ok, tournament} ->
        Audit.log(tournament.id, socket.assigns.current_scope, "pairing.results_unpublished", %{
          round: round_number
        })

        {:noreply, socket |> assign(tournament: tournament) |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, results_error_text(reason))}
    end
  end

  ## ---------- Editing a paired round by hand ----------
  #
  # Three gestures, all starting from a right-click:
  #
  #   right-click a player  -> a context menu (`open_menu`, pushed by the
  #                            `.PairingMenu` hook's `contextmenu` listener)
  #   "Swap with…"          -> arms `swap_first`; the NEXT LEFT-click on
  #                            another player picks the target. A right-click
  #                            never completes a swap - it only ever opens
  #                            the menu, so the destructive half of the
  #                            gesture is always a deliberate second action.
  #   "Mark absent"         -> empties that seat (see the vacancy model in
  #                            `Tournaments.vacate_seat/3`)
  #
  # Everything that writes goes through `@confirm` first - one modal, one
  # shape, whatever the action (see `confirm_for/2` and `apply_confirm/2`).

  # Archived is checked here, once, rather than at every downstream
  # gesture handler (arm_swap, stage_vacate, stage_bye, stage_fill,
  # offer_seats, stage_pool_pair) - this is the single entry point every
  # one of them is reached through (a right-click on a player), so
  # refusing to even open the menu on an archived tournament silently
  # closes off the whole editing surface in one place. The underlying
  # writes are refused server-side regardless (`ensure_writable/1`,
  # confirmed by the whole `archive_test.exs` suite) - this is purely
  # about not dangling an editing menu in front of someone on a read-only
  # tournament.
  def handle_event("open_menu", _params, %{assigns: %{tournament: %{archived_at: at}}} = socket)
      when not is_nil(at) do
    {:noreply, put_flash(socket, :error, error_text(:archived))}
  end

  # The payload is the `.PairingMenu` hook's, so it is checked rather than
  # trusted: a missing position, an id that is not a whole number or a scope
  # `pairing_menu/1` has no branch for used to crash the page (a MatchError,
  # an ArgumentError, a CaseClauseError in the render). Any of those now opens
  # nothing.
  @menu_scopes ~w(seated pool vacant round)

  def handle_event("open_menu", params, socket) do
    scope = params["scope"] || "seated"
    player_id = menu_id(params["player-id"])
    pairing_id = menu_id(params["pairing-id"])

    if scope in @menu_scopes and player_id != :error and pairing_id != :error do
      menu = %{
        x: coord(params["x"]),
        y: coord(params["y"]),
        player_id: player_id,
        pairing_id: pairing_id,
        seat: params["seat"],
        scope: scope,
        # Opened from the keyboard (Enter, Space, the context-menu key or
        # Shift+F10 on a seat): the menu takes focus. The same menu, the same
        # items, the same events either way - only where focus goes differs.
        keyboard: params["keyboard"] in [true, "true"]
      }

      {:noreply, assign(socket, menu: menu)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_menu", _params, socket), do: {:noreply, assign(socket, menu: nil)}

  # Arming says so out loud as well as in the banner: a screen reader has no
  # other way to learn that the next seat it presses Enter on is the swap.
  def handle_event("arm_swap", %{"player-id" => id}, socket) do
    case parse_id(id) do
      nil ->
        {:noreply, socket}

      player_id ->
        {:noreply,
         socket
         |> assign(
           menu: nil,
           confirm: nil,
           swap_first: %{id: player_id, name: display_name(socket, player_id)}
         )
         |> announce(
           gettext("Swap armed: choose the second seat and press Enter; Escape to cancel.")
         )}
    end
  end

  def handle_event("arm_swap", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_swap", _params, socket) do
    socket =
      if socket.assigns.swap_first,
        do: announce(socket, gettext("Swap cancelled.")),
        else: socket

    {:noreply, assign(socket, swap_first: nil, confirm: nil, menu: nil)}
  end

  # The second half of a swap: a plain LEFT-click, on either a seated
  # player or someone in the round's pool.
  def handle_event("pick_swap_target", %{"player-id" => id}, socket) do
    case parse_id(id) do
      nil ->
        {:noreply, socket}

      target_id ->
        case socket.assigns.swap_first do
          nil -> {:noreply, socket}
          %{id: ^target_id} -> {:noreply, socket}
          first -> {:noreply, stage(socket, {:swap, first.id, target_id})}
        end
    end
  end

  def handle_event("pick_swap_target", _params, socket), do: {:noreply, socket}

  def handle_event("stage_vacate", %{"player-id" => id}, socket) do
    case parse_id(id) do
      nil -> {:noreply, socket}
      player_id -> {:noreply, stage(socket, {:vacate, player_id})}
    end
  end

  def handle_event("stage_vacate", _params, socket), do: {:noreply, socket}

  def handle_event("stage_bye", %{"pairing-id" => id}, socket) do
    case parse_id(id) do
      nil -> {:noreply, socket}
      pairing_id -> {:noreply, stage(socket, {:bye, pairing_id})}
    end
  end

  def handle_event("stage_bye", _params, socket), do: {:noreply, socket}

  def handle_event("stage_fill", %{"pairing-id" => pid, "player-id" => plid}, socket) do
    with pairing_id when not is_nil(pairing_id) <- parse_id(pid),
         player_id when not is_nil(player_id) <- parse_id(plid) do
      {:noreply, stage(socket, {:fill, pairing_id, player_id})}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("stage_fill", _params, socket), do: {:noreply, socket}

  # Hide/unhide is a plain, immediate toggle - not staged behind `@confirm`
  # the way the other hand-edit gestures are. It's display-only and fully
  # reversible (see `Tournaments.set_pairing_hidden/3`'s doc), so it doesn't
  # need the same "review a board diff before committing" ceremony a real
  # pairing-structure change does; that ceremony is reserved for
  # `stage_delete_pairing` below, which actually removes the row.
  def handle_event("toggle_hidden", %{"pairing-id" => id}, socket) do
    %{tournament: t, round: round, round_number: round_number} = socket.assigns
    pairing_id = String.to_integer(id)

    with {:ok, pairing} <- fetch_pairing(round, pairing_id),
         {:ok, updated} <- Tournaments.set_pairing_hidden(round, pairing, !pairing.hidden) do
      Audit.log(
        t.id,
        socket.assigns.current_scope,
        if(updated.hidden, do: "pairing.hidden", else: "pairing.unhidden"),
        %{pairing_id: pairing.id, round: round_number, board: pairing.board}
      )
    end

    {:noreply, refresh(socket)}
  end

  def handle_event("stage_delete_pairing", %{"pairing-id" => id}, socket) do
    {:noreply, stage(socket, {:delete_pairing, String.to_integer(id)})}
  end

  # Choosing which vacant seat a pool player should go into. With exactly
  # one vacancy open there's nothing to choose, so it stages directly.
  def handle_event("offer_seats", %{"player-id" => id}, socket) do
    player_id = String.to_integer(id)

    case vacant_pairings(socket.assigns.round) do
      [] ->
        {:noreply, assign(socket, menu: nil)}

      [only] ->
        {:noreply, stage(socket, {:fill, only.id, player_id})}

      _many ->
        {:noreply,
         socket
         |> assign(menu: nil, seat_pick: player_id)
         |> announce(
           gettext(
             "Seat choice armed: choose which empty seat they take and press Enter; Escape to cancel."
           )
         )}
    end
  end

  def handle_event("cancel_seat_pick", _params, socket) do
    socket =
      if socket.assigns.seat_pick,
        do: announce(socket, gettext("Seat choice cancelled.")),
        else: socket

    {:noreply, assign(socket, seat_pick: nil)}
  end

  def handle_event("stage_pool_pair", %{"player-id" => id}, socket) do
    player_id = String.to_integer(id)

    case socket.assigns.pool_first do
      %{id: first_id} when first_id != player_id ->
        {:noreply, stage(socket, {:pool_pair, first_id, player_id})}

      _ ->
        {:noreply,
         socket
         |> assign(
           menu: nil,
           pool_first: %{id: player_id, name: display_name(socket, player_id)}
         )
         |> announce(
           gettext(
             "Pairing armed: choose their opponent in the not-playing list and press Enter; Escape to cancel."
           )
         )}
    end
  end

  def handle_event("cancel_pool_pair", _params, socket) do
    socket =
      if socket.assigns.pool_first,
        do: announce(socket, gettext("Pairing cancelled.")),
        else: socket

    {:noreply, assign(socket, pool_first: nil, menu: nil)}
  end

  def handle_event("set_confirm_board", %{"board" => board}, socket) do
    case Integer.parse(String.trim(board)) do
      {n, ""} when n > 0 ->
        confirm = Map.put(socket.assigns.confirm, :board, n)

        confirm =
          case confirm do
            %{kind: :pool_pair, a_id: a, b_id: b} ->
              %{
                confirm
                | team_note:
                    pool_pair_team_note(socket.assigns.tournament, socket.assigns.round, a, b, n)
              }

            other ->
              other
          end

        {:noreply, assign(socket, confirm: confirm)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_confirm", _params, socket),
    do: {:noreply, assign(socket, confirm: nil)}

  # The "I understand - apply this to round N anyway" checkbox on a
  # frozen-round confirm (see `frozen_round?/1`) - the primary button
  # stays disabled until this is ticked.
  def handle_event("toggle_frozen_ack", _params, socket) do
    case socket.assigns.confirm do
      nil -> {:noreply, socket}
      confirm -> {:noreply, assign(socket, confirm: Map.update!(confirm, :frozen_ack, &(!&1)))}
    end
  end

  # The same for a round already sent in a TRF finalised for sending (see
  # `stage/2`): its own box, because it is its own reason.
  def handle_event("toggle_sent_ack", _params, socket) do
    case socket.assigns.confirm do
      nil -> {:noreply, socket}
      confirm -> {:noreply, assign(socket, confirm: Map.update!(confirm, :sent_ack, &(!&1)))}
    end
  end

  def handle_event("apply_confirm", _params, socket) do
    apply_confirm(socket, socket.assigns.confirm)
  end

  def handle_event("result", %{"pairing-id" => id, "result" => result}, socket) do
    %{tournament: t, round_number: round_number} = socket.assigns

    case Enum.find(socket.assigns.round.pairings, &(&1.id == String.to_integer(id))) do
      nil ->
        {:noreply, refresh(socket)}

      %{result: previous} = pairing when result in ["", nil] and previous not in [nil, ""] ->
        # A blank submission arriving for a board that already has a real
        # result on file is NEVER committed straight away - only staged,
        # pending an explicit confirm click (see "confirm_clear_result"
        # below). A genuine "select the blank option to reset this board"
        # click from an arbiter still works, just one extra click.
        #
        # This exists because of a real incident: a burst of ~11
        # simultaneous "result" events fired for every board in a round at
        # once (almost certainly triggered by a LiveView reconnect after a
        # dropped socket - this page had been reconnecting every 1-2
        # minutes over a flaky mobile connection), and 4 of them carried a
        # blank value, silently wiping 4 already-recorded results. Nothing
        # about a single incoming event distinguishes "an arbiter meant to
        # clear this" from "a stray reconnect-triggered submission" - the
        # payload looks identical either way - so this guard doesn't try
        # to guess; it just refuses to let a blank value overwrite a real
        # one without a second, explicit action confirming it.
        Audit.log(t.id, socket.assigns.current_scope, "pairing.result_clear_attempted", %{
          pairing_id: pairing.id,
          round: round_number,
          board: pairing.board,
          white: player_name(pairing.white_player),
          black: player_name(pairing.black_player),
          from: previous
        })

        {:noreply, assign(socket, confirm_clear_pairing_id: pairing.id)}

      pairing ->
        previous = pairing.result

        case Tournaments.update_pairing_result(pairing, result) do
          {:ok, _} ->
            action =
              if previous in [nil, ""],
                do: "pairing.result_entered",
                else: "pairing.result_changed"

            Audit.log(t.id, socket.assigns.current_scope, action, %{
              pairing_id: pairing.id,
              round: round_number,
              board: pairing.board,
              white: player_name(pairing.white_player),
              black: player_name(pairing.black_player),
              from: previous,
              to: result
            })

            {:noreply,
             socket |> assign(confirm_clear_pairing_id: nil, confirm_postponed: nil) |> refresh()}

          # A postponed game given a result that is not a draw (VCL4THP
          # Q163), or a result already sent in a finalised TRF. Nothing was
          # written; the choice is staged and the board asks first, the way
          # clearing a result does. The nonce bump puts the select back to
          # what is stored in the meantime.
          {:error, {:needs_acknowledgement, ids}} ->
            {:noreply,
             socket
             |> assign(
               confirm_clear_pairing_id: nil,
               confirm_postponed: %{pairing_id: pairing.id, result: result, ids: ids},
               write_refused_nonce: socket.assigns.write_refused_nonce + 1
             )
             |> refresh()}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, error_text(reason))
             |> assign(
               confirm_clear_pairing_id: nil,
               write_refused_nonce: socket.assigns.write_refused_nonce + 1
             )
             |> refresh()}
        end
    end
  end

  # The arbiter confirmed a result that is not a draw for a postponed game.
  # Re-fetched from the round on screen rather than trusted from the staged
  # map, and written with the one acknowledgement the confirmation stood for
  # - if the board has changed underneath (someone else entered a result, or
  # postponed it again), the write path decides afresh.
  def handle_event("confirm_postponed_result", %{"pairing-id" => id}, socket) do
    %{tournament: t, round_number: round_number, confirm_postponed: staged} = socket.assigns

    with %{pairing_id: staged_id, result: result, ids: ids} <- staged,
         true <- to_string(staged_id) == id,
         %{} = pairing <- Enum.find(socket.assigns.round.pairings, &(&1.id == staged_id)) do
      previous = pairing.result

      case Tournaments.update_pairing_result(pairing, result, acknowledged: ids) do
        {:ok, _} ->
          Audit.log(t.id, socket.assigns.current_scope, "pairing.result_changed", %{
            pairing_id: pairing.id,
            round: round_number,
            board: pairing.board,
            white: player_name(pairing.white_player),
            black: player_name(pairing.black_player),
            from: previous,
            to: result,
            confirmed: Enum.map_join(ids, ",", &Atom.to_string/1)
          })

          {:noreply,
           socket |> assign(confirm_postponed: nil, refocus_result: pairing.id) |> refresh()}

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, error_text(reason))
           |> assign(
             confirm_postponed: nil,
             write_refused_nonce: socket.assigns.write_refused_nonce + 1
           )
           |> refresh()}
      end
    else
      _ -> {:noreply, socket |> assign(confirm_postponed: nil) |> refresh()}
    end
  end

  def handle_event("cancel_postponed_result", _params, socket) do
    refocus = socket.assigns.confirm_postponed && socket.assigns.confirm_postponed.pairing_id
    {:noreply, assign(socket, confirm_postponed: nil, refocus_result: refocus)}
  end

  # The explicit second click confirming a blank-result overwrite staged by
  # the guard above. Re-fetches the pairing fresh rather than trusting
  # anything already in `socket.assigns` - the confirmation could be
  # sitting on screen for a while, and this is exactly the code path a
  # stale/incorrect write must never happen through.
  def handle_event("confirm_clear_result", %{"pairing-id" => id}, socket) do
    %{tournament: t, round_number: round_number} = socket.assigns

    case Enum.find(socket.assigns.round.pairings, &(&1.id == String.to_integer(id))) do
      nil ->
        {:noreply, socket |> assign(confirm_clear_pairing_id: nil) |> refresh()}

      pairing ->
        previous = pairing.result

        case Tournaments.update_pairing_result(pairing, "") do
          {:ok, _} ->
            Audit.log(t.id, socket.assigns.current_scope, "pairing.result_cleared", %{
              pairing_id: pairing.id,
              round: round_number,
              board: pairing.board,
              white: player_name(pairing.white_player),
              black: player_name(pairing.black_player),
              from: previous
            })

            {:noreply,
             socket
             |> assign(confirm_clear_pairing_id: nil, refocus_result: pairing.id)
             |> refresh()}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, error_text(reason))
             |> assign(
               confirm_clear_pairing_id: nil,
               write_refused_nonce: socket.assigns.write_refused_nonce + 1
             )
             |> refresh()}
        end
    end
  end

  # Backs out of a staged clear without writing anything - the select
  # reverts to its real (unchanged) value on the next render, since the DB
  # was never touched.
  def handle_event("cancel_clear_result", _params, socket) do
    {:noreply,
     assign(socket,
       confirm_clear_pairing_id: nil,
       refocus_result: socket.assigns.confirm_clear_pairing_id
     )}
  end

  ## ---------- team matches: forfeit by decision, boards outside a match ----------

  # "Forfeit this match to <team>": every board becomes that team's forfeit
  # win and the decision is recorded (`TeamMatches.forfeit_match/3`). A
  # restore point is taken first, as for a results import - it rewrites a
  # whole match's results in one go - and the decision itself can be
  # withdrawn from the same row.
  def handle_event("forfeit_match", %{"match-id" => match_id, "team-id" => team_id}, socket) do
    %{tournament: t, round_number: round_number} = socket.assigns

    with %{} = match <- find_match(socket, match_id),
         team_id when is_integer(team_id) <- parse_id(team_id) do
      Snapshots.capture(t, "pairing.match_forfeited", socket.assigns.current_scope,
        summary: "Before forfeiting match #{match.board} of round #{round_number}"
      )

      case TeamMatches.forfeit_match(t, match, team_id) do
        {:ok, _} ->
          loser = if team_id == match.team_a_id, do: match.team_b_id, else: match.team_a_id
          teams = socket.assigns.teams_by_id

          Audit.log(t.id, socket.assigns.current_scope, "pairing.match_forfeited", %{
            round: round_number,
            match: match.board,
            winner: match_team_name(teams, team_id),
            loser: match_team_name(teams, loser)
          })

          text =
            gettext("Match %{match} forfeited to %{team}.",
              match: match.board,
              team: match_team_name(teams, team_id)
            )

          {:noreply, socket |> assign(error: nil) |> refresh() |> announce(text)}

        {:error, reason} ->
          {:noreply,
           socket |> put_flash(:error, error_text(reason)) |> assign(error: nil) |> refresh()}
      end
    else
      _ -> {:noreply, refresh(socket)}
    end
  end

  def handle_event("withdraw_match_forfeit", %{"match-id" => match_id}, socket) do
    %{tournament: t, round_number: round_number} = socket.assigns

    case find_match(socket, match_id) do
      nil ->
        {:noreply, refresh(socket)}

      match ->
        teams = socket.assigns.teams_by_id

        case TeamMatches.withdraw_forfeit(t, match) do
          {:ok, _} ->
            Audit.log(t.id, socket.assigns.current_scope, "pairing.match_forfeit_withdrawn", %{
              round: round_number,
              match: match.board,
              winner: match_team_name(teams, match.forfeited_to_team_id)
            })

            text = gettext("Decision on match %{match} withdrawn.", match: match.board)
            {:noreply, socket |> assign(error: nil) |> refresh() |> announce(text)}

          {:error, reason} ->
            {:noreply, socket |> put_flash(:error, error_text(reason)) |> refresh()}
        end
    end
  end

  # A board outside every match, moved into the one it fits.
  def handle_event("attach_board", %{"pairing-id" => pairing_id}, socket) do
    %{tournament: t, round: round, round_number: round_number} = socket.assigns

    with id when is_integer(id) <- parse_id(pairing_id),
         {:ok, pairing} <- fetch_pairing(round, id) do
      case TeamMatches.attach_board(t, round, pairing) do
        {:ok, updated} ->
          Audit.log(t.id, socket.assigns.current_scope, "pairing.board_attached", %{
            round: round_number,
            from_board: pairing.board,
            board: updated.board
          })

          text =
            gettext("Board %{board} is now part of a match and counts for its team.",
              board: updated.board
            )

          {:noreply, socket |> assign(error: nil) |> refresh() |> announce(text)}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(error: "Could not attach that board: " <> slot_reason(reason))
           |> refresh()}
      end
    else
      _ -> {:noreply, refresh(socket)}
    end
  end

  ## ---------- CSV results import ----------

  def handle_event("toggle_import_results", _params, socket) do
    {:noreply,
     assign(socket, importing_results: not socket.assigns.importing_results, import_errors: nil)}
  end

  # The file input's phx-change target; nothing to do until submit.
  def handle_event("validate_results_csv", _params, socket), do: {:noreply, socket}

  def handle_event("import_results_csv", _params, socket) do
    %{tournament: tournament, round_number: round_number} = socket.assigns

    uploaded =
      consume_uploaded_entries(socket, :results_csv, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end)

    case uploaded do
      [csv_text] ->
        # Overwrites a whole round's results in one go - snapshot first.
        Snapshots.capture(
          tournament,
          "pairing.results_imported",
          socket.assigns.current_scope,
          summary: "Before importing results into round #{round_number}"
        )

        with {:ok, rows} <- ResultsImport.parse_text(csv_text),
             {:ok, count} <- ResultsImport.apply_import(tournament, round_number, rows) do
          Audit.log(tournament.id, socket.assigns.current_scope, "pairing.results_imported", %{
            round: round_number,
            results_set: count
          })

          {:noreply,
           socket
           |> put_flash(:info, "Imported #{count} result#{if count != 1, do: "s"}.")
           |> assign(import_errors: nil, importing_results: false, error: nil)
           |> refresh()}
        else
          {:error, errors} -> {:noreply, assign(socket, import_errors: errors)}
        end

      [] ->
        {:noreply, assign(socket, import_errors: ["Choose a CSV file first"])}
    end
  end

  # The menu's position, straight from the click event, and interpolated into
  # a `style` attribute by `context_menu/1`. HEEx escapes the attribute, so
  # this was never markup injection - but it was a raw client string in a
  # CSS declaration list, which the ids beside it never were
  # (`menu_id/1`). A number is what the renderer wants and the only thing
  # the browser sends, so parse one and put the menu at the origin when the
  # value is anything else.
  #
  # Including a fractional one: a menu opened from the keyboard is placed at
  # the seat's `getBoundingClientRect()`, which is fractional under display
  # scaling or zoom, and a float used to fall through to the origin - the menu
  # opened in the top-left corner of the window instead of under the seat.
  defp coord(value) when is_integer(value), do: value
  defp coord(value) when is_float(value), do: round(value)

  defp coord(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _rest} -> n
      :error -> 0
    end
  end

  defp coord(_value), do: 0

  # nil when the payload names no id, the id when it is a whole number, and
  # :error for anything else - which `open_menu` refuses rather than passing
  # a non-id on to the menu's buttons.
  defp menu_id(nil), do: nil
  defp menu_id(""), do: nil
  defp menu_id(value) when is_integer(value), do: value

  defp menu_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> :error
    end
  end

  defp menu_id(_value), do: :error

  # A whole number from an `arm_swap`/`pick_swap_target`/`stage_vacate`/
  # `stage_bye`/`stage_fill` payload's `player-id`/`pairing-id`, or nil for
  # anything else (missing, non-numeric, a float, a map, a list) - each of
  # those five used to crash on `String.to_integer/1`. An id that parses
  # fine but names a player or pairing from another tournament is not a
  # write: `stage/2` -> `confirm_for/2` (and `arm_swap`'s own
  # `display_name/2`) look it up only inside `socket.assigns.round` and
  # `socket.assigns.round_pool`, both scoped to this tournament by
  # `mount/3`, so a foreign id just matches nothing (`{:error,
  # :not_in_round}` or a blank name) - and `Tournaments.fill_seat/3`
  # additionally refuses a foreign player id with `{:error, :invalid_player}`
  # even if it somehow reached that far.
  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_id(_id), do: nil

  # Builds the confirm state for an action and closes every transient bit
  # of UI around it, so the modal is always the only thing on screen
  # asking for a decision.
  defp stage(socket, action) do
    case confirm_for(socket, action) do
      {:ok, confirm} ->
        frozen? = frozen_round?(socket)

        # A round already sent to the federation: who played whom in it is
        # on file there, and a change here cannot reach that file. Blocked
        # behind its own warning and tick; `Tournaments` refuses too.
        sent? =
          PostponedGames.round_sent?(socket.assigns.tournament.id, socket.assigns.round_number)

        confirm =
          Map.merge(confirm, %{
            frozen: frozen?,
            frozen_ack: !frozen?,
            sent: sent?,
            sent_ack: !sent?
          })

        assign(socket, confirm: confirm, menu: nil, seat_pick: nil)

      {:error, _reason} ->
        assign(socket, menu: nil, seat_pick: nil)
    end
  end

  # A round that isn't the tournament's current latest PAIRED round -
  # every `confirm_for/2` action (swap, mark absent, pool-pair, fill a
  # seat, award a bye - everything that alters who's paired with whom)
  # runs through `stage/2`, so gating it here covers all of them
  # uniformly. Entering/editing a RESULT is untouched - only pairing
  # structure gets the extra gate. `paired_rounds == 0` (nothing paired
  # yet at all) is never "frozen"; there's no other round to confuse this
  # one with.
  defp frozen_round?(socket) do
    %{round_number: n, paired_rounds: paired} = socket.assigns
    paired > 0 and n != paired
  end

  ## ---------- Hand-editing a round: preview + apply ----------
  #
  # Every action builds the SAME confirm shape, so one modal renders all
  # of them:
  #
  #     %{kind:, title:, subtitle:, changes: [board diff], note:, ...}
  #
  # `changes` is a list of `%{board, before:, after:}` where `before`/
  # `after` are `{white_name, black_name}` - the modal draws those as two
  # board cards side by side and highlights whichever seat differs, which
  # is why they stay as a tuple rather than a pre-joined string.

  defp confirm_for(socket, {:swap, a_id, b_id}) do
    round = socket.assigns.round
    pool = socket.assigns.round_pool

    cond do
      # Both seated - a straight seat trade, possibly a colour-only swap.
      seated?(round, a_id) and seated?(round, b_id) ->
        with {:ok, {pa, fa}} <- locate_seat(round.pairings, a_id),
             {:ok, {pb, fb}} <- locate_seat(round.pairings, b_id) do
          a = display_name(socket, a_id)
          b = display_name(socket, b_id)
          same? = pa.id == pb.id

          changes =
            if same?,
              do: [board_change(pa, [{fa, b}, {fb, a}])],
              else: [board_change(pa, [{fa, b}]), board_change(pb, [{fb, a}])]

          {:ok,
           %{
             kind: :swap,
             a_id: a_id,
             b_id: b_id,
             title: if(same?, do: "Swap colours", else: "Swap players"),
             subtitle: "#{a}  ⇄  #{b}",
             changes: changes,
             # Every distinct name shown across the diff, each its own
             # colour - see `identity_colors/1`. Only `:swap` gets one:
             # it's the one confirm kind where more than one player can
             # be on screen at once with something to tell apart.
             colors: identity_colors(changes),
             note: nil
           }}
        end

      # One seated, one in the pool - a substitution.
      seated?(round, a_id) or seated?(round, b_id) ->
        {seated_id, pool_id} = if seated?(round, a_id), do: {a_id, b_id}, else: {b_id, a_id}

        if pool_member?(pool, pool_id) do
          {:ok, {pairing, field}} = locate_seat(round.pairings, seated_id)
          seated_name = display_name(socket, seated_id)
          pool_name = display_name(socket, pool_id)
          changes = [board_change(pairing, [{field, pool_name}])]

          {:ok,
           %{
             kind: :swap_pool,
             seated_id: seated_id,
             pool_id: pool_id,
             title: "Substitute player",
             subtitle: "#{pool_name} takes #{seated_name}'s place",
             changes: changes,
             # The mirror image of the board row above: the pool player was
             # on the bench before this action, the seated player lands
             # there after. Rendered as its own row (`bench_card/1`), not
             # another `changes` entry - it isn't a board, it has no
             # number/colours, and it only ever has one seat instead of
             # two. Its two names are already both present in `changes`
             # above (seated_name in `before`, pool_name in `after`), so
             # `identity_colors/1` picks up both without any change there.
             # Putting this row inside the SAME `#confirm-board-diffs`
             # container as the board row is what lets `.SwapArrows`'
             # global name-matching (`matchTravellers/1`) draw the two
             # journey arrows for free - one leaving the bench, one
             # arriving on it - with no JS changes needed.
             bench: %{before: pool_name, after: seated_name},
             # `:swap` used to be the only kind with more than one
             # identifiable player on screen at once; a substitution now
             # is too (the bench row adds a second), so it earns the same
             # per-traveller colour coding `:swap` already has.
             colors: identity_colors(changes),
             note:
               "#{seated_name} moves to the not-playing list for this round." <>
                 whole_event_note(socket, pool_id)
           }}
        else
          {:error, :not_in_round}
        end

      true ->
        {:error, :not_in_round}
    end
  end

  defp confirm_for(socket, {:vacate, player_id}) do
    round = socket.assigns.round

    with {:ok, {pairing, field}} <- locate_seat(round.pairings, player_id) do
      name = display_name(socket, player_id)
      opponent = other_seat_name(pairing, field)

      {:ok,
       %{
         kind: :vacate,
         player_id: player_id,
         title: "Mark absent",
         subtitle: "#{name} is not playing round #{socket.assigns.round_number}",
         changes: [board_change(pairing, [{field, ""}])],
         note:
           "Board #{pairing.board} keeps its number and #{blank_dash(opponent)} stays put. " <>
             "The empty seat can be filled from the not-playing list, or turned into a bye - " <>
             "until then the round counts as unfinished."
       }}
    end
  end

  defp confirm_for(socket, {:bye, pairing_id}) do
    with {:ok, pairing} <- fetch_pairing(socket.assigns.round, pairing_id) do
      remaining = pairing.white_player || pairing.black_player
      name = player_label(remaining)

      {:ok,
       %{
         kind: :bye,
         pairing_id: pairing_id,
         title: "Award a bye",
         subtitle: "#{name} sits out round #{socket.assigns.round_number}",
         changes: [%{board: pairing.board, before: board_seats(pairing), after: {name, "bye"}}],
         note: "Scores #{socket.assigns.tournament.bye_value} pt, as a pairing-allocated bye."
       }}
    end
  end

  defp confirm_for(socket, {:fill, pairing_id, player_id}) do
    with {:ok, pairing} <- fetch_pairing(socket.assigns.round, pairing_id) do
      name = display_name(socket, player_id)
      field = if is_nil(pairing.white_player_id), do: :white_player_id, else: :black_player_id

      {:ok,
       %{
         kind: :fill,
         pairing_id: pairing_id,
         player_id: player_id,
         title: "Fill the empty seat",
         subtitle: "#{name} joins board #{pairing.board}",
         changes: [board_change(pairing, [{field, name}])],
         note:
           "#{name} is no longer marked absent for this round." <>
             whole_event_note(socket, player_id)
       }}
    end
  end

  defp confirm_for(socket, {:delete_pairing, pairing_id}) do
    with {:ok, pairing} <- fetch_pairing(socket.assigns.round, pairing_id) do
      {:ok,
       %{
         kind: :delete_pairing,
         pairing_id: pairing_id,
         title: "Delete this board",
         subtitle: "Board #{pairing.board} is removed from round #{socket.assigns.round_number}",
         # Nothing to diff - the row is already empty on both seats
         # (delete is only offered/allowed on a fully-vacated board), so
         # the modal's board-diff cards would just show "empty ⇄ empty".
         # The title/subtitle/note carry the whole story instead.
         changes: [],
         note:
           "This removes the board row itself, not just hides it - permanently, and only " <>
             "possible on the round's last board, so no other board's number ever has to " <>
             "change. This cannot be undone from here."
       }}
    end
  end

  defp confirm_for(socket, {:pool_pair, a_id, b_id}) do
    %{tournament: t, round: round} = socket.assigns

    # In a round paired as teams, the board is offered where it fits one of
    # the round's matches - number and colours included - so it counts for
    # its team. `team_note` says which, or that it will count for no team.
    {board, a_id, b_id} =
      case Tournament.paired_as_teams?(t) && TeamMatches.fitting_slot(t, round, a_id, b_id) do
        {:ok, slot} -> {slot.board, slot.white_id, slot.black_id}
        _ -> {Tournaments.next_free_board(round), a_id, b_id}
      end

    a = display_name(socket, a_id)
    b = display_name(socket, b_id)

    {:ok,
     %{
       kind: :pool_pair,
       a_id: a_id,
       b_id: b_id,
       board: board,
       title: "Pair these two",
       subtitle: "#{a}  vs  #{b}",
       changes: [%{board: board, before: {"", ""}, after: {a, b}}],
       note: "Neither will be marked absent for this round any more.",
       team_note: pool_pair_team_note(t, round, a_id, b_id, board)
     }}
  end

  # What the new board will be to the team standings, for the dialog: nil
  # for a tournament not paired as teams.
  defp pool_pair_team_note(t, round, a_id, b_id, board) do
    if Tournament.paired_as_teams?(t) do
      case TeamMatches.slot_at(t, round, a_id, b_id, board) do
        {:ok, match} ->
          {:ok,
           gettext(
             "This board becomes part of match %{match}: %{a} - %{b}, and counts for both teams.",
             match: match.board,
             a: match_team_name(teams_by_id(t), match.team_a_id),
             b: match_team_name(teams_by_id(t), match.team_b_id)
           )}

        {:error, reason} ->
          {:warn,
           gettext("Not part of a match: this board counts for no team.") <>
             " " <> slot_reason(reason)}
      end
    end
  end

  @doc false
  def slot_reason(:no_team),
    do: gettext("Its two players are not on two different teams.")

  def slot_reason(:no_match),
    do:
      gettext("No match of this round is between these two players' teams at that table number.")

  def slot_reason(:board_taken),
    do: gettext("Every board of their teams' match is already taken.")

  def slot_reason(:colours),
    do:
      gettext(
        "The colours do not fit: the team named first in the match has White on the odd boards."
      )

  def slot_reason(:board_order),
    do: gettext("Their board orders do not fit between the boards already in the match.")

  def slot_reason(_other), do: ""

  defp apply_confirm(socket, nil), do: {:noreply, socket}

  # Belt-and-braces: the modal's primary button is already `disabled` in
  # this state (see the template), but a disabled button is a client-side
  # courtesy, not a guarantee - refuse server-side too rather than trust
  # it.
  defp apply_confirm(socket, %{frozen: true, frozen_ack: false}), do: {:noreply, socket}
  defp apply_confirm(socket, %{sent: true, sent_ack: false}), do: {:noreply, socket}

  defp apply_confirm(socket, confirm) do
    %{tournament: t, round: round} = socket.assigns
    apply_confirmed(socket, confirm, round, t)
  end

  # Said through the root layout's `#announcer` by the `phx:announce`
  # listener in assets/js/app.js - the words are gettext's, here.
  defp announce(socket, text), do: push_event(socket, "announce", %{text: text})

  # The board an applied hand edit leaves focus on, in the round as it now
  # is: where the swap's first player now sits (the seat the keyboard
  # completed the swap on), the board a change was made to, or - for a
  # deleted board - the board above it. `nil` when there is none to show.
  defp edited_pairing_id(nil, _confirm, _old_round), do: nil

  defp edited_pairing_id(round, %{kind: :swap, a_id: a}, _old_round) do
    case locate_seat(round.pairings, a) do
      {:ok, {pairing, _field}} -> pairing.id
      _ -> nil
    end
  end

  defp edited_pairing_id(round, %{kind: :delete_pairing, pairing_id: id}, old_round) do
    with %{board: gone} <- find_pairing(old_round, id),
         [_ | _] = above <- Enum.filter(round.pairings, &(not &1.hidden and &1.board < gone)) do
      Enum.max_by(above, & &1.board).id
    else
      _ -> nil
    end
  end

  defp edited_pairing_id(round, %{changes: [%{board: board} | _]}, _old_round) do
    case Enum.find(round.pairings, &(&1.board == board)) do
      nil -> nil
      pairing -> pairing.id
    end
  end

  defp edited_pairing_id(_round, _confirm, _old_round), do: nil

  defp apply_confirmed(socket, confirm, round, t) do
    ack = if confirm[:sent], do: [acknowledged: [:sent_round_changed]], else: []

    result =
      case confirm do
        %{kind: :swap, a_id: a, b_id: b} ->
          Tournaments.swap_players_in_round(round, a, b, ack)

        %{kind: :swap_pool, seated_id: s, pool_id: p} ->
          Tournaments.swap_seated_with_pool_player(round, s, p, ack)

        %{kind: :vacate, player_id: p} ->
          Tournaments.vacate_seat(round, p, "absent", ack)

        %{kind: :bye, pairing_id: id} ->
          with {:ok, pairing} <- fetch_pairing(round, id),
               do: Tournaments.award_bye_for_vacancy(round, pairing, ack)

        %{kind: :fill, pairing_id: id, player_id: p} ->
          with {:ok, pairing} <- fetch_pairing(round, id),
               do: Tournaments.fill_seat(round, pairing, p, ack)

        %{kind: :pool_pair, a_id: a, b_id: b, board: board} ->
          Tournaments.pair_from_pool(round, a, b, board, ack)

        %{kind: :delete_pairing, pairing_id: id} ->
          with {:ok, pairing} <- fetch_pairing(round, id),
               do: Tournaments.delete_pairing(round, pairing)
      end

    case result do
      {:ok, _} ->
        Audit.log(
          t.id,
          socket.assigns.current_scope,
          audit_action(confirm.kind),
          Map.merge(
            %{round: socket.assigns.round_number, summary: confirm.subtitle},
            if(confirm[:sent], do: %{confirmed: "sent_round_changed"}, else: %{})
          )
        )

        socket = socket |> assign(error: nil) |> refresh()

        # After the patch, focus lands on the edited board (the
        # `.PairingMenu` hook), not wherever the closing dialog left it.
        {:noreply,
         push_event(socket, "hand_edit_applied", %{
           pairing_id: edited_pairing_id(socket.assigns.round, confirm, round)
         })}

      {:error, :archived} ->
        {:noreply,
         assign(socket,
           error: error_text(:archived),
           confirm: nil,
           swap_first: nil,
           pool_first: nil
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           error: "Could not apply that change: #{error_text(reason)}",
           confirm: nil,
           swap_first: nil,
           pool_first: nil
         )}
    end
  end

  defp audit_action(:swap), do: "pairing.players_swapped"
  defp audit_action(:swap_pool), do: "pairing.player_substituted"
  defp audit_action(:vacate), do: "pairing.seat_vacated"
  defp audit_action(:bye), do: "pairing.bye_awarded"
  defp audit_action(:fill), do: "pairing.seat_filled"
  defp audit_action(:pool_pair), do: "pairing.pool_paired"
  defp audit_action(:delete_pairing), do: "pairing.deleted"

  ## ---------- Round lookups ----------

  defp seated?(nil, _player_id), do: false

  defp seated?(round, player_id) do
    Enum.any?(
      round.pairings,
      &(&1.white_player_id == player_id or &1.black_player_id == player_id)
    )
  end

  defp pool_member?(pool, player_id), do: Enum.any?(pool, &(&1.player.id == player_id))

  # Bringing someone in for ONE round does not un-withdraw them from the
  # event, and silently clearing a tournament-wide flag as a side effect
  # of a board-level swap would be a surprise. So the flag stays and the
  # modal says so, with the one place that can change it.
  defp whole_event_note(socket, player_id) do
    if Enum.any?(socket.assigns.round_pool, &(&1.player.id == player_id and &1.absent?)) do
      " They stay marked absent for the whole event - clear that on the Players page if they " <>
        "are back for good, or the next round will leave them out again."
    else
      ""
    end
  end

  # A match of the round on screen, by the id a button carried - nil for an
  # id that is not one of them.
  defp find_match(socket, match_id) do
    with %{} = round <- socket.assigns.round,
         id when is_integer(id) <- parse_id(match_id) do
      round.id |> Tournaments.list_matches() |> Enum.find(&(&1.id == id))
    else
      _ -> nil
    end
  end

  defp fetch_pairing(nil, _id), do: {:error, :not_in_round}

  defp fetch_pairing(round, id) do
    case Enum.find(round.pairings, &(&1.id == id)) do
      nil -> {:error, :not_in_round}
      pairing -> {:ok, pairing}
    end
  end

  # Bare lookup (not the tagged tuple `fetch_pairing/2` returns) for the two
  # spots that just want the struct or `nil` - `pairing_menu/1`'s eligibility
  # checks below, and the "Hidden boards" panel.
  defp find_pairing(nil, _id), do: nil
  defp find_pairing(round, id), do: Enum.find(round.pairings, &(&1.id == id))

  defp locate_seat(pairings, player_id) do
    Enum.find_value(pairings, {:error, :not_in_round}, fn pairing ->
      cond do
        pairing.white_player_id == player_id -> {:ok, {pairing, :white_player_id}}
        pairing.black_player_id == player_id -> {:ok, {pairing, :black_player_id}}
        true -> nil
      end
    end)
  end

  defp vacant_pairings(nil), do: []

  defp vacant_pairings(round) do
    Enum.filter(round.pairings, &vacant?/1)
  end

  # A vacancy, not a bye: exactly one empty seat AND no result. A bye is
  # an empty black seat carrying `result: "bye"`.
  defp vacant?(%{result: "bye"}), do: false

  defp vacant?(pairing),
    do: is_nil(pairing.white_player_id) or is_nil(pairing.black_player_id)

  # BOTH seats empty - the state two "mark absent" gestures on the same
  # board eventually leave behind, and the only state `set_pairing_hidden/3`
  # and `delete_pairing/2` accept. Distinct from `vacant?/1` above, which
  # is "at least one" (an ordinary one-sided vacancy still needs its
  # "award a bye" option, which makes no sense once BOTH seats are empty).
  defp fully_vacant?(pairing),
    do: is_nil(pairing.white_player_id) and is_nil(pairing.black_player_id)

  # Whether `pairing` sits on `round`'s own highest real board number -
  # the one board `Tournaments.delete_pairing/2` ever allows removing, so
  # the menu/panel can grey the option out instead of just letting the
  # server bounce it. Mirrors that function's own guard exactly (same
  # `board` field, same `Enum.max`), never the frozen `display_board`.
  defp last_board?(nil, _pairing), do: false

  defp last_board?(round, pairing) do
    case round.pairings do
      [] -> false
      pairings -> pairing.board == pairings |> Enum.map(& &1.board) |> Enum.max()
    end
  end

  # `player_label/1` by id, across both the boards and the pool - a click
  # only tells the server which id was hit.
  defp display_name(socket, player_id) do
    seated =
      case socket.assigns.round do
        nil ->
          nil

        round ->
          Enum.find_value(round.pairings, fn pairing ->
            cond do
              pairing.white_player_id == player_id -> pairing.white_player
              pairing.black_player_id == player_id -> pairing.black_player
              true -> nil
            end
          end)
      end

    pooled =
      Enum.find_value(socket.assigns.round_pool, fn %{player: p} ->
        if p.id == player_id, do: p
      end)

    player_label(seated || pooled)
  end

  defp board_seats(pairing),
    do: {player_label(pairing.white_player), player_label(pairing.black_player)}

  # One board's before/after, given the seat substitutions to apply.
  # `substitutions` is a list of `{field, new_name}`; `""` empties a seat.
  defp board_change(pairing, substitutions) do
    {before_white, before_black} = board_seats(pairing)

    {after_white, after_black} =
      Enum.reduce(substitutions, {before_white, before_black}, fn
        {:white_player_id, name}, {_w, b} -> {name, b}
        {:black_player_id, name}, {w, _b} -> {w, name}
      end)

    %{
      board: pairing.board,
      before: {before_white, before_black},
      after: {after_white, after_black},
      result_will_clear?: pairing.result not in ["", "bye"]
    }
  end

  # A fixed palette, not derived from the tournament's own accent colour
  # (`Layouts.theme_switch/1`) - that's a single colour the WHOLE app is
  # tinted with, so using it here couldn't tell two people apart even
  # once, let alone four. Assigned in the order names first appear
  # scanning `changes` (before, then after, board by board) - stable and
  # deterministic for a given swap, not tied to seat/colour/pairing_number.
  @identity_palette ~w(#3b82f6 #ec4899 #f59e0b #10b981 #8b5cf6 #06b6d4)

  # One colour per distinct name across the WHOLE diff - every player
  # shown, not just the ones who moved, so e.g. board 1's "stays put"
  # opponent is exactly as identifiable as the two who traded seats.
  # `board_card/1` turns this into each seat's `--swap-color`; the
  # `.SwapArrows` hook reads that same value back off the seat elements
  # so an arrow always matches its own traveller's colour, with no
  # separate colour list to keep in sync between Elixir and JS.
  defp identity_colors(changes) do
    changes
    |> Enum.flat_map(fn c -> Tuple.to_list(c.before) ++ Tuple.to_list(c.after) end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.with_index()
    |> Map.new(fn {name, i} ->
      {name, Enum.at(@identity_palette, rem(i, length(@identity_palette)))}
    end)
  end

  defp other_seat_name(pairing, :white_player_id), do: player_label(pairing.black_player)
  defp other_seat_name(pairing, :black_player_id), do: player_label(pairing.white_player)

  defp blank_dash(""), do: "the empty seat"
  defp blank_dash(name), do: name

  defp do_pair(socket) do
    cond do
      socket.assigns.tournament.pairing_system == "round_robin" ->
        do_pair_all_rounds(socket)

      Tournament.team_swiss?(socket.assigns.tournament) ->
        do_pair_team_swiss_async(socket)

      true ->
        Snapshots.capture(
          socket.assigns.tournament,
          "pairing.round_paired",
          socket.assigns.current_scope,
          summary: "Before pairing round #{socket.assigns.round_number}"
        )

        socket
        |> assign(recorded_missing: missing_to_record(socket))
        |> apply_pair_result(
          Engine.pair_next_round(socket.assigns.tournament,
            acknowledged: socket.assigns.pair_acknowledged
          )
        )
    end
  end

  # The postponed-game warnings the arbiter confirmed on the button they
  # clicked (`phx-value-acknowledged`, comma-separated ids). Only ids the
  # write path knows are kept, so a crafted value cannot mint an atom.
  defp acknowledged(%{"acknowledged" => ids}) when is_binary(ids) do
    known = Map.new(PostponedGames.acknowledgement_ids(), &{Atom.to_string(&1), &1})

    ids
    |> String.split(",", trim: true)
    |> Enum.flat_map(&List.wrap(Map.get(known, String.trim(&1))))
  end

  defp acknowledged(_params), do: []

  # The missing results this pairing run will record as postponed, when the
  # arbiter confirmed that - kept so the page can say so once the round is
  # paired, and write it to the audit trail.
  defp missing_to_record(socket) do
    if :missing_results_recorded_as_adjourned in socket.assigns.pair_acknowledged do
      Enum.find(
        socket.assigns.pairing_warnings,
        &(&1.id == :missing_results_recorded_as_adjourned)
      )
    end
  end

  # Team Swiss (`PairingsEngine.TeamSwiss`) is the one path that can
  # genuinely take a while: 10-50 seconds at 300-500 teams, running IN THIS
  # BEAM with no subprocess timeout of its own (unlike JaVaFo/Ainalrami's
  # individual path, which already has `Engine.run_with_timeout/2`). Run in
  # a supervised task so the LiveView process - and so the socket - stays
  # responsive while it works, the same pattern `FideLive`'s connection poll
  # uses: `send/2` a plain message back to this process rather than
  # blocking on `Task.await/2` here, which would put us right back to
  # freezing on the calling process either way.
  defp do_pair_team_swiss_async(socket) do
    tournament = socket.assigns.tournament
    round_number = socket.assigns.round_number
    parent = self()

    Snapshots.capture(tournament, "pairing.round_paired", socket.assigns.current_scope,
      summary: "Before pairing round #{round_number}"
    )

    acknowledged = socket.assigns.pair_acknowledged

    Task.Supervisor.start_child(PairingsEngine.TaskSupervisor, fn ->
      result = Engine.pair_next_round(tournament, acknowledged: acknowledged)
      send(parent, {:team_pairing_result, tournament.id, result})
    end)

    {:noreply,
     assign(socket,
       pairing_in_progress: true,
       error: nil,
       recorded_missing: missing_to_record(socket)
     )}
  end

  defp apply_pair_result(socket, result) do
    case result do
      {:ok, round} ->
        socket = note_recorded_missing(socket)
        log_round_paired(socket, round.number)
        {:noreply, socket |> assign(round_number: round.number, error: nil) |> refresh()}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, assign(socket, error: "Could not save the round")}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  # The round was paired after its missing results were recorded as
  # postponed (VCL4THP Q159-160): said on the page and kept in the trail, so
  # the recording is not a side effect nobody sees.
  defp note_recorded_missing(%{assigns: %{recorded_missing: %{round: n, count: count}}} = socket) do
    Audit.log(
      socket.assigns.tournament.id,
      socket.assigns.current_scope,
      "pairing.missing_recorded_postponed",
      %{round: n, count: count}
    )

    socket
    |> assign(recorded_missing: nil)
    |> put_flash(
      :info,
      ngettext(
        "Round %{round}'s board without a result was recorded as a postponed game.",
        "Round %{round}'s %{count} boards without a result were recorded as postponed games.",
        count,
        round: n
      )
    )
  end

  defp note_recorded_missing(socket), do: socket

  # Round-robin pairs its whole Berger schedule in one click instead of one
  # round at a time (see RoundRobin.pair_all_rounds/1's doc - there's
  # nothing to wait on between rounds the way Swiss waits on results) -
  # every round it generates still gets its own "pairing.round_paired"
  # audit entry, same depth of trail one-round-at-a-time pairing would
  # have produced.
  defp do_pair_all_rounds(socket) do
    tournament = socket.assigns.tournament
    already_paired = Engine.paired_rounds_count(tournament.id)

    # Generates the entire Berger schedule in one irreversible click, so this
    # is the single most valuable thing to have a snapshot in front of.
    Snapshots.capture(tournament, "pairing.round_paired", socket.assigns.current_scope,
      summary: "Before pairing the whole round-robin schedule"
    )

    case RoundRobin.pair_all_rounds(tournament) do
      {:ok, last_round_number} ->
        for round_number <- (already_paired + 1)..last_round_number do
          log_round_paired(socket, round_number)
        end

        # RoundRobin.pair_all_rounds/1 may have corrected rounds_count
        # (see ensure_correct_rounds_count/2) - reload straight away so
        # the round picker reflects the real schedule length on this same
        # render, instead of waiting on the settings-change broadcast this
        # LiveView is subscribed to anyway (handle_info below) to catch up
        # a moment later.
        fresh_tournament =
          Tournaments.get_authorized_tournament!(socket.assigns.current_scope, tournament.id)

        {:noreply,
         socket
         |> assign(tournament: fresh_tournament, round_number: 1, error: nil)
         |> refresh()}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, assign(socket, error: "Could not save the round")}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  # Logs the rich "pairing.round_paired" audit entry, reusing the exact same
  # PairingRationale analysis the "Explain this round" page renders live - so
  # the durable audit record and the visual page describe the same decision.
  # `swiss_match_format` pairs two rounds in one action; we log the primary
  # (leg-1) round number, whose rationale covers the decision that was made.
  defp log_round_paired(socket, round_number) do
    t = socket.assigns.tournament
    rationale = PairingRationale.for_round(t, round_number)

    Audit.log(
      t.id,
      socket.assigns.current_scope,
      "pairing.round_paired",
      PairingRationale.audit_payload(rationale)
    )
  end

  # The result select's options for `pairing`. The two postponed codes only
  # when the tournament allows postponed games; the unnamed `*` - recorded at
  # pairing time or read from a TRF, never offered - only on the board that
  # holds it, so the select shows what is stored rather than its first option.
  defp results(tournament, pairing) do
    offered =
      Enum.flat_map(@results, fn
        {"*W", :postponed_white} ->
          if tournament.postponed_games,
            do: [{"*W", gettext("* postponed by White")}],
            else: []

        {"*B", :postponed_black} ->
          if tournament.postponed_games,
            do: [{"*B", gettext("* postponed by Black")}],
            else: []

        other ->
          [other]
      end)

    held =
      if pairing.result == "*" or
           (PairingsEngine.Results.postponed?(pairing.result) and not tournament.postponed_games),
         do: [{pairing.result, gettext("* postponed")}],
         else: []

    offered ++ held
  end

  # Plain-text summary of `Tournament.missing_setup_fields/1`'s messages, for
  # the flash/tooltip shown when pairing is blocked - the on-page banner (see
  # render/1) additionally links each item to the Settings (sub-)page it
  # lives on.
  defp missing_setup_summary(missing) do
    Enum.map_join(missing, "; ", fn {_field, message} -> message end)
  end

  # Long JaVaFo failures come through as multi-line output - show a short
  # first-line preview as the collapsed summary, never a truncated message
  # (the full text is always available by expanding the block).
  defp error_summary(text) do
    text |> String.split("\n", parts: 2) |> hd()
  end

  # The pairing engine actually used, for button/notice copy - only Swiss runs
  # JaVaFo, so the label must not claim it for round-robin (Berger schedule) or
  # Keizer.
  # Swiss falls through to whichever engine the tournament actually selected.
  # This used to hardcode "JaVaFo" for every Swiss tournament, so a
  # tournament opted into Ainalrami still had a button reading "Pair round 5
  # (JaVaFo)" and a sheet describing pairings JaVaFo had not produced - the
  # one place in the app where the engine choice was invisible after making
  # it.
  defp pairing_engine_label(tournament), do: Tournament.engine_name(tournament)

  defp pairing_engine_description(%{pairing_system: "round_robin"}),
    do: "round-robin schedule (Berger tables)"

  defp pairing_engine_description(%{pairing_system: "keizer"}), do: "Keizer ladder pairing"

  defp pairing_engine_description(%{pairing_engine: "ainalrami"}),
    do: "FIDE Dutch pairing (Ainalrami)"

  defp pairing_engine_description(_swiss), do: "FIDE Dutch pairing (JaVaFo)"

  # Bare display name for an audit-log payload (nil = a bye's empty side).
  defp player_name(nil), do: nil
  defp player_name(player), do: player.name

  # A results-import problem: a sentence from `ResultsImport`, or the one
  # reason it hands over to be worded here.
  defp import_error_text({:postponed_non_draw, board}),
    do:
      gettext(
        "board %{board}: the game was postponed and counted provisionally for pairing - enter a result that is not a draw on this page, where it is confirmed",
        board: board
      )

  defp import_error_text({:finalised_result_changed, board}),
    do:
      gettext(
        "board %{board}: this result was already sent in a TRF finalised for sending - change it on this page, where it is confirmed",
        board: board
      )

  defp import_error_text({:postponed_games_off, board}),
    do:
      gettext(
        "board %{board}: this tournament does not allow postponed games - turn them on under Settings, Scoring first",
        board: board
      )

  defp import_error_text(text), do: text

  ## ---------- postponed games: the pair buttons' confirmations ----------

  defp has_warning?(warnings, id), do: Enum.any?(warnings, &(&1.id == id))

  # The ids of `ids` that apply now, as the button's `phx-value-acknowledged`
  # - the confirmation text the arbiter read and the acknowledgement the
  # click carries come from the same list, so they cannot say different
  # things. nil (no attribute) when none applies.
  defp acknowledged_value(warnings, ids) do
    case Enum.filter(ids, &has_warning?(warnings, &1)) do
      [] -> nil
      present -> Enum.map_join(present, ",", &Atom.to_string/1)
    end
  end

  # The browser confirmation for the same warnings (`Postponed.pair_confirm_text/2`).
  defp pair_confirm_text(warnings, ids, next_round) do
    warnings |> Enum.filter(&(&1.id in ids)) |> Postponed.pair_confirm_text(next_round)
  end

  defp player_label(nil), do: ""

  defp player_label(player) do
    rating = PairingsEngine.Tournaments.Player.rating(player)

    "#{if player.title != "", do: "#{player.title} "}#{player.name}" <>
      if(rating > 0, do: " (#{rating})", else: "")
  end

  # Board-list label only: `player_label/1` plus the player's score coming
  # into this round, in the same parenthetical - "Name (2400, 2.5)", or
  # "Name (2.5)" with no rating. Deliberately separate from
  # `player_label/1` itself, which every OTHER player-name spot on this
  # page (swap dialogs, the not-playing pool, audit text) keeps using
  # unchanged - the incoming score is specifically a pairing-SHEET thing.
  # No `nil` clause: `seat_cell/1`'s `@player ->` branch (the only caller)
  # only ever reaches this with a real player.
  defp seat_label(player, scores) do
    rating = PairingsEngine.Tournaments.Player.rating(player)
    score = format_score(Map.get(scores, player.id, 0.0))
    title = if player.title != "", do: "#{player.title} "

    bracket = if rating > 0, do: "(#{rating}, #{score})", else: "(#{score})"

    "#{title}#{player.name} #{bracket}"
  end

  defp format_score(v) when is_float(v) do
    if v == Float.round(v, 0), do: trunc(v), else: v
  end

  defp format_score(v), do: v

  # A round's pairings preload in whatever order the DB/JaVaFo output them,
  # not board order. `PairingDisplay.with_display_boards/1` both sorts
  # (fixed-table boards moved to the end, ordered by their own table
  # number) and relabels (the ordinary boards renumbered to close the gap
  # a pulled-out fixed-table board leaves) - see its moduledoc. Presentation
  # only: `pairing.board` itself, used everywhere else in this file
  # (audit log entries, swap-menu subtitles), is untouched.
  # Hidden rows (see `Tournaments.set_pairing_hidden/3`) never reach
  # `PairingDisplay` at all - filtering them out here, before the board
  # renumbering pass, means a hidden row plays no part in it whatsoever,
  # same as if it didn't exist for display purposes. This is safe against
  # the 0.14.6 bug class specifically because `display_board` is already
  # FROZEN (see `PairingDisplay`'s moduledoc) - every other row's label was
  # decided once, at pairing time, and doesn't get recomputed here just
  # because one row is missing from this list.
  defp display_rows(pairings) do
    pairings |> Enum.reject(& &1.hidden) |> PairingDisplay.with_display_boards()
  end

  # Label for a byes-table row's `type` - distinct from the "bye" badge
  # shown for a pairing-allocated bye (a real Pairing row), since these
  # never appear in round.pairings (see Tournaments.list_byes_for_round/2).
  defp bye_type_label("requested-half"), do: "requested half-point bye"
  defp bye_type_label("requested-zero"), do: "requested zero-point bye"
  defp bye_type_label("absent"), do: "absent"
  defp bye_type_label(other), do: other

  # Cosmetic-only: under `rr_match_format`/`swiss_match_format`, round
  # 2k-1/2k are legs 1/2 of the same "match" (Pairing.max_pairable_round/1,
  # RoundRobin.do_pair/3 - leg 2 is always a colour-reversed mirror of leg
  # 1, never a separate JaVaFo decision). `rounds_count` keeps meaning
  # "total physical rounds" everywhere else; this only changes what the
  # round-picker buttons and the "Round N" heading display.
  defp match_format?(%Tournament{rr_match_format: true}), do: true
  defp match_format?(%Tournament{swiss_match_format: true}), do: true
  defp match_format?(_), do: false

  defp round_label(n, tournament) do
    if match_format?(tournament) do
      "M#{match_number(n)}·#{leg_number(n)}"
    else
      to_string(n)
    end
  end

  # Same match/leg breakdown as `round_label/2`, but spelled out for the
  # "Round ..." heading below the picker, where the compact button label
  # would read ambiguously ("Round M1·1").
  defp round_heading(n, tournament) do
    if match_format?(tournament) do
      "Match #{match_number(n)}, game #{leg_number(n)}"
    else
      "Round #{n}"
    end
  end

  defp match_number(n), do: div(n - 1, 2) + 1
  defp leg_number(n), do: if(rem(n, 2) == 1, do: 1, else: 2)

  ## ---------- publish/unpublish controls ----------

  attr :tournament, Tournament, required: true
  attr :round, :any, required: true
  # This component is rendered twice on screen at once - once in the
  # round-header actions row, once in the round's own right-click context
  # menu (hidden by CSS/JS until opened, but still present in the DOM, so
  # LiveView still requires its ids to be unique) - so the caller gives each
  # copy its own id prefix.
  attr :id_prefix, :string, default: ""
  # The round-header copy sits in a group labelled with the round already
  # ("Public" beside "Round N"), so it names only what each switch shows.
  attr :short, :boolean, default: false

  defp publish_controls(assigns) do
    assigns =
      assign(assigns,
        pairings_label:
          if(assigns.short,
            do: gettext("Pairings"),
            else: gettext("Pairings round %{n}", n: assigns.round.number)
          ),
        standings_label:
          if(assigns.short,
            do: gettext("Standings"),
            else: gettext("Standings after round %{n}", n: assigns.round.number)
          ),
        results_label:
          if(assigns.short,
            do: gettext("Results"),
            else: gettext("Results round %{n}", n: assigns.round.number)
          )
      )

    ~H"""
    <.publish_toggle
      :if={@tournament.publish_mode == "immediate"}
      id={"#{@id_prefix}pairings-toggle-#{@round.number}"}
      label={@pairings_label}
      state={:public}
      locked
      reason={immediate_lock_reason()}
    />

    <%= if @tournament.publish_mode != "immediate" do %>
      <% pairings_public? = Tournaments.round_published?(@tournament, @round) %>
      <.publish_toggle
        id={"#{@id_prefix}pairings-toggle-#{@round.number}"}
        label={@pairings_label}
        state={if pairings_public?, do: :public, else: :not_public}
        confirm={confirm_unpublish_pairings(@tournament, @round)}
        phx-click={if pairings_public?, do: "unpublish_pairings", else: "publish_pairings"}
        phx-value-round={@round.number}
      />
    <% end %>

    <.publish_toggle
      :if={@tournament.publish_mode == "immediate"}
      id={"#{@id_prefix}standings-toggle-#{@round.number}"}
      label={@standings_label}
      state={:public}
      locked
      reason={immediate_lock_reason()}
    />

    <%= if @tournament.publish_mode != "immediate" do %>
      <% standings_public? = Tournaments.standings_public?(@tournament, @round.number) %>
      <% blocked = Tournaments.standings_publish_blocked_reason(@tournament, @round.number, @round) %>
      <.publish_toggle
        id={"#{@id_prefix}standings-toggle-#{@round.number}"}
        label={@standings_label}
        state={if standings_public?, do: :public, else: :not_public}
        disabled={not standings_public? and not is_nil(blocked)}
        reason={standings_reason_text(blocked, @round.number)}
        confirm={confirm_unpublish_standings(@tournament, @round.number)}
        phx-click={if standings_public?, do: "unpublish_standings", else: "publish_standings"}
        phx-value-round={@round.number}
      />
    <% end %>

    <% results_locked = Tournaments.results_locked_reason(@tournament, @round) %>
    <.publish_toggle
      :if={results_locked}
      id={"#{@id_prefix}results-toggle-#{@round.number}"}
      label={@results_label}
      state={:public}
      locked
      reason={results_lock_reason(results_locked, @round.number)}
    />
    <.publish_toggle
      :if={is_nil(results_locked)}
      id={"#{@id_prefix}results-toggle-#{@round.number}"}
      label={@results_label}
      state={if @round.results_public, do: :public, else: :not_public}
      confirm={
        gettext(
          "Take round %{n}'s results off the public page? Its pairings stay public, without results.",
          n: @round.number
        )
      }
      phx-click={if @round.results_public, do: "unpublish_results", else: "publish_results"}
      phx-value-round={@round.number}
    />
    """
  end

  defp results_lock_reason(:immediate, _round_number), do: immediate_lock_reason()

  defp results_lock_reason(:standings_public, round_number),
    do:
      gettext(
        "Standings after round %{n} are public, and they already contain every result of the round - so its results are public too.",
        n: round_number
      )

  defp results_error_text(:results_locked),
    do: gettext("These results are public because the standings after this round are.")

  defp results_error_text(:not_paired), do: gettext("That round hasn't been paired yet.")
  defp results_error_text(reason), do: error_text(reason)

  defp immediate_lock_reason do
    gettext(
      "Every round - and the standings behind it - is public here the instant it's paired. Change that in Settings → OpenResults."
    )
  end

  # Rule 4's confirm - named consequences, not a bare "are you sure?": which
  # rounds actually go dark (the round clicked is always at least one of
  # them; manual publishing can make it more, per `round_published?/2`'s own
  # doc), and whether the cascade in `unpublish_pairings_through/2` would
  # also pull public standings back.
  defp confirm_unpublish_pairings(tournament, round) do
    cap = round.number - 1

    standings_drop? =
      not is_nil(tournament.standings_through) and tournament.standings_through > cap

    hide =
      gettext(
        "Hide round %{n} - and every round after it - from the public pairings page? Their results stop being public too.",
        n: round.number
      )

    if standings_drop? do
      hide <> " " <> gettext("Public standings will also drop back to after round %{n}.", n: cap)
    else
      hide
    end
  end

  # Rule 3's confirm - the mirror image: which rounds' PAIRINGS would go
  # dark as a side effect of pulling standings back (see
  # `unpublish_standings_through/2`'s own doc for why a later sheet has to
  # be hidden too).
  defp confirm_unpublish_standings(tournament, round_number) do
    base =
      if round_number == 0 do
        gettext("Hide the entry list from the public page again?")
      else
        gettext(
          "Hide public standings after round %{n}? They will drop back to after round %{prev}.",
          n: round_number,
          prev: round_number - 1
        ) <>
          " " <>
          gettext("Round %{n}'s results stay public only if its Results switch is on.",
            n: round_number
          )
      end

    case lowest_published_round_above(tournament, round_number) do
      nil ->
        base

      hidden_from ->
        base <>
          " " <>
          gettext(
            "This also hides round %{n}'s pairings and results, and every round after it.",
            n: hidden_from
          )
    end
  end

  defp lowest_published_round_above(tournament, round_number) do
    tournament.id
    |> Tournaments.list_rounds()
    |> Enum.filter(&(&1.number > round_number and Tournaments.round_published?(tournament, &1)))
    |> Enum.map(& &1.number)
    |> case do
      [] -> nil
      numbers -> Enum.min(numbers)
    end
  end

  defp standings_reason_text(nil, _round_number), do: nil

  defp standings_reason_text(:not_paired, round_number),
    do: gettext("Round %{n} hasn't been paired yet.", n: round_number)

  defp standings_reason_text(:pairings_not_public, round_number),
    do: gettext("Round %{n}'s pairings aren't public yet - publish them first.", n: round_number)

  defp standings_reason_text(:round_not_complete, round_number),
    do:
      gettext(
        "Round %{n} isn't finished yet - every result must be entered first.",
        n: round_number
      )

  ## ---------- Hand-editing UI pieces ----------

  # One board drawn as a card: White over Black, the way the pairing sheet
  # reads. `compare` (the other side of the diff) is what makes a changed
  # seat light up, so the arbiter can see WHICH name moved rather than
  # having to read two strings and spot the difference themselves.
  attr :seats, :any, required: true
  attr :state, :string, required: true
  attr :compare, :any, default: nil
  # `%{name => "#hex"}` - see `identity_colors/1`. Every seat gets its
  # colour set as an inline `--swap-color` custom property regardless of
  # whether it changed; CSS decides what actually uses it (currently:
  # the name text, always, and the "changed" highlight/chip, only where
  # those already applied). Empty for every confirm kind but `:swap`.
  attr :color_by_name, :map, default: %{}

  defp board_card(assigns) do
    {white, black} = assigns.seats
    {was_white, was_black} = assigns.compare || assigns.seats

    assigns =
      assign(assigns,
        white: white,
        black: black,
        white_changed?: white != was_white,
        black_changed?: black != was_black,
        # Only the "after" card highlights a differing seat - that's the
        # one the arbiter is being asked to approve. The "before" card
        # marks the same seats with an unstyled class purely so the
        # `.SwapArrows` hook can find where each traveller starts; it
        # deliberately carries no visual weight of its own.
        changed_class:
          if(assigns.state == "after", do: "board-seat-changed", else: "board-seat-moving")
      )

    ~H"""
    <div class={["board-card", "board-card-#{@state}"]}>
      <div
        class={["board-seat", @white_changed? && @changed_class]}
        style={seat_color_style(@color_by_name, @white)}
      >
        <span class="board-seat-colour" aria-label={gettext("White")}>W</span>
        <span class="board-seat-name" title={seat_text(@white)}>{seat_text(@white)}</span>
      </div>

      <div
        class={["board-seat", @black_changed? && @changed_class]}
        style={seat_color_style(@color_by_name, @black)}
      >
        <span class="board-seat-colour board-seat-black" aria-label={gettext("Black")}>B</span>
        <span class="board-seat-name" title={seat_text(@black)}>{seat_text(@black)}</span>
      </div>
    </div>
    """
  end

  # The "not playing list" row `confirm_for/2`'s `:swap_pool` branch adds
  # alongside the board row - the one `board_card/1` caller that only ever
  # has ONE seat, not two, so it gets its own small component rather than
  # forcing an optional-second-seat attr onto `board_card/1`. Deliberately
  # reuses `board_card/1`'s class vocabulary (`.board-card`/
  # `.board-card-#{state}`/`.board-seat`/`.board-seat-name`) rather than
  # inventing new ones: `.SwapArrows`' `matchTravellers/1` finds its
  # travellers by querying those classes GLOBALLY across the whole modal,
  # not board-by-board, so as long as this row lives inside the same
  # `#confirm-board-diffs` container it's picked up for free. What it
  # skips is the W/B colour disc `board_card/1` always draws - colour is
  # meaningless off the board, and drawing one here would claim a seat
  # this row doesn't have.
  attr :name, :string, required: true
  attr :state, :string, required: true
  attr :color_by_name, :map, default: %{}

  defp bench_card(assigns) do
    ~H"""
    <div class={["board-card", "board-card-#{@state}"]}>
      <div
        class={["board-seat", "board-seat-bench", bench_changed_class(@state)]}
        style={seat_color_style(@color_by_name, @name)}
      >
        <span class="board-seat-name" title={seat_text(@name)}>{seat_text(@name)}</span>
      </div>
    </div>
    """
  end

  # Both sides of the bench row always differ from each other (the whole
  # point of a substitution is that the two names swap places) - unlike
  # `board_card/1`, there's no "did this seat actually change?" branch to
  # make; both cards always get the highlight/no-visual-weight split
  # `board_card/1` also uses so `.SwapArrows` can find where each
  # traveller starts.
  defp bench_changed_class("after"), do: "board-seat-changed"
  defp bench_changed_class(_before), do: "board-seat-moving"

  defp seat_color_style(color_by_name, name) do
    case Map.get(color_by_name, name) do
      nil -> nil
      hex -> "--swap-color: #{hex}"
    end
  end

  defp seat_text(""), do: "- empty -"
  defp seat_text(name), do: name

  # A left-click in the pool means "complete the armed gesture" - which
  # gesture depends on which one is armed. With a swap armed it's the swap
  # target; otherwise it's the second half of a pool pairing.
  defp pool_click(nil), do: "stage_pool_pair"
  defp pool_click(_swap_first), do: "pick_swap_target"

  # What the pool chip says about WHY someone isn't playing, and what it
  # scores. The tournament-wide `absent` flag is reported ahead of the
  # per-round byes row because it is the reason they are not in the
  # pairing at all - and, being the flag an arbiter most often reverses
  # on the day, the one they need to recognise at a glance.
  defp pool_tag(%{absent?: true}, _tournament, _counts), do: "absent (whole event)"

  defp pool_tag(%{type: nil}, _tournament, _counts), do: "unpaired"

  defp pool_tag(%{type: type} = entry, tournament, counts) do
    points = PairingsEngine.Standings.bye_points_for_row(entry, tournament, counts)
    "#{bye_type_label(type)} · #{points} pt"
  end

  # One seat in the pairings table. Three states: an ordinary player
  # (right-click for the menu, left-click to complete an armed swap), a
  # bye's empty black side (nothing to act on - the Result column already
  # says "bye"), and a VACANCY, which is the one that asks to be filled.
  #
  # Every seat that has something to act on is a keyboard target too (R2 of
  # docs/accessibility-2026-09-13.md): `role="button"`, in the Tab order,
  # named for its colour and board, with `data-seat` for the `.PairingMenu`
  # hook. Enter, Space, the context-menu key or Shift+F10 opens the same menu
  # a right-click does - except on a seat marked `data-armed`, where Enter
  # completes the armed swap exactly as a left-click does. Spans rather than
  # `<button>`s so a browser's own Enter/Space activation can never fire the
  # `phx-click` behind the hook's back, and the seats look as they did.
  attr :player, :any, required: true
  attr :pairing, :map, required: true
  attr :side, :atom, required: true
  attr :board, :any, required: true
  attr :swap_first, :any, required: true
  attr :seat_pick, :any, required: true
  attr :scores, :map, required: true

  defp seat_cell(assigns) do
    ~H"""
    <%= cond do %>
      <% @player -> %>
        <span
          class={[
            "swap-target",
            @side == :white && "seat-white",
            @swap_first && @swap_first.id == @player.id && "swap-selected",
            @swap_first && @swap_first.id != @player.id && "swap-eligible"
          ]}
          id={seat_id(@pairing, @side)}
          role="button"
          tabindex="0"
          aria-haspopup="menu"
          aria-label={seat_name(@side, @board, seat_label(@player, @scores))}
          aria-describedby={@swap_first && "swap-banner-text"}
          data-seat
          data-armed={@swap_first && @swap_first.id != @player.id}
          data-player-id={@player.id}
          data-scope="seated"
          phx-click="pick_swap_target"
          phx-value-player-id={@player.id}
          title={gettext("Right-click for swap / absent options")}
        >
          {seat_label(@player, @scores)}
          <span :if={@swap_first && @swap_first.id == @player.id} class="swap-armed-tag">
            {gettext("swapping")}
          </span>
        </span>
      <% @pairing.result == "bye" -> %>
        <span class="seat-none">-</span>
      <% @seat_pick -> %>
        <button
          type="button"
          class="seat-vacant seat-vacant-armed"
          id={seat_id(@pairing, @side)}
          aria-label={put_here_name(@side, @board)}
          phx-click="stage_fill"
          phx-value-pairing-id={@pairing.id}
          phx-value-player-id={@seat_pick}
        >
          {gettext("Put them here")}
        </button>
      <% true -> %>
        <span
          class="seat-vacant"
          id={seat_id(@pairing, @side)}
          role="button"
          tabindex="0"
          aria-haspopup="menu"
          aria-label={seat_name(@side, @board, gettext("empty seat"))}
          data-seat
          data-pairing-id={@pairing.id}
          data-scope="vacant"
          title={
            gettext(
              "Empty seat - right-click to award a bye, or pick a replacement from the not-playing list below"
            )
          }
        >
          {gettext("- empty -")}
        </span>
    <% end %>
    """
  end

  # One id per seat position, whoever sits there, so focus can find the same
  # seat again after a patch - `DialogFocus` returns to it by id.
  defp seat_id(pairing, side), do: "seat-#{pairing.id}-#{side}"

  defp seat_name(:white, board, who),
    do: gettext("White on board %{board}: %{name}", board: board, name: who)

  defp seat_name(:black, board, who),
    do: gettext("Black on board %{board}: %{name}", board: board, name: who)

  defp put_here_name(:white, board),
    do: gettext("Put them here: white on board %{board}", board: board)

  defp put_here_name(:black, board),
    do: gettext("Put them here: black on board %{board}", board: board)

  # The right-click menu. Fixed-positioned at the click point, so it opens
  # where the pointer is instead of at the top of the page.
  attr :menu, :map, required: true
  attr :round, :any, required: true
  attr :tournament, :map, required: true

  defp pairing_menu(assigns) do
    pairing = assigns.menu.pairing_id && find_pairing(assigns.round, assigns.menu.pairing_id)

    assigns =
      assign(assigns,
        vacancies: length(vacant_pairings(assigns.round)),
        fully_vacant?: pairing != nil and fully_vacant?(pairing),
        pairing_hidden?: pairing != nil and pairing.hidden,
        deletable?:
          pairing != nil and fully_vacant?(pairing) and last_board?(assigns.round, pairing)
      )

    ~H"""
    <div class="ctx-backdrop" phx-click="close_menu" phx-window-keydown="close_menu" phx-key="escape">
      <%!-- A real menu for the three seat scopes (`role="menu"`, its buttons
            `menuitem`s); the round's publishing controls are switches, not
            menu items, so that scope stays a plain group. `.HandEditMenu`
            moves focus in when the keyboard opened it (`data-keyboard`),
            walks the items with the arrow keys, and puts focus back on the
            seat it came from when it closes. `data-transient-menu` keeps
            `DialogFocus` from mistaking an item for the control a
            confirmation should return to. --%>
      <div
        class="ctx-menu"
        id="hand-edit-menu"
        role={if @menu.scope == "round", do: "group", else: "menu"}
        aria-label={gettext("Hand edits")}
        style={"left: #{@menu.x}px; top: #{@menu.y}px"}
        phx-click-away="close_menu"
        phx-hook=".HandEditMenu"
        data-keyboard={@menu.keyboard}
        data-transient-menu
      >
        <%= case @menu.scope do %>
          <% "seated" -> %>
            <button
              type="button"
              role="menuitem"
              phx-click="arm_swap"
              phx-value-player-id={@menu.player_id}
            >
              {gettext("Swap with…")}
            </button>

            <button
              type="button"
              role="menuitem"
              phx-click="stage_vacate"
              phx-value-player-id={@menu.player_id}
            >
              {gettext("Mark absent for this round")}
            </button>
          <% "pool" -> %>
            <button
              type="button"
              role="menuitem"
              phx-click="arm_swap"
              phx-value-player-id={@menu.player_id}
            >
              {gettext("Swap with a player on a board…")}
            </button>

            <button
              :if={@vacancies > 0}
              type="button"
              role="menuitem"
              phx-click="offer_seats"
              phx-value-player-id={@menu.player_id}
            >
              {gettext("Put in an empty seat")}{if @vacancies > 1, do: "…", else: ""}
            </button>

            <button
              type="button"
              role="menuitem"
              phx-click="stage_pool_pair"
              phx-value-player-id={@menu.player_id}
            >
              {gettext("Pair with another player who isn't playing…")}
            </button>
          <% "vacant" -> %>
            <button
              :if={!@fully_vacant?}
              type="button"
              role="menuitem"
              phx-click="stage_bye"
              phx-value-pairing-id={@menu.pairing_id}
            >
              {gettext("Award a bye to the remaining player")}
            </button>

            <button
              :if={@fully_vacant?}
              type="button"
              role="menuitem"
              phx-click="toggle_hidden"
              phx-value-pairing-id={@menu.pairing_id}
            >
              {if @pairing_hidden?, do: "Unhide this board", else: "Hide this board"}
            </button>

            <button
              :if={@deletable?}
              type="button"
              role="menuitem"
              class="danger-link"
              phx-click="stage_delete_pairing"
              phx-value-pairing-id={@menu.pairing_id}
            >
              {gettext("Delete this board…")}
            </button>
          <% "round" -> %>
            <div style="padding: 8px 10px; display: flex; flex-direction: column; gap: 8px">
              <.publish_controls id_prefix="menu-" tournament={@tournament} round={@round} />
            </div>
        <% end %>
      </div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      update_notice={assigns[:update_notice]}
      flash={@flash}
      current_path={assigns[:current_path]}
      current_scope={@current_scope}
      tournament={@tournament}
      active="pairings"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>

          <p class="subtitle" style="margin: 0">{gettext("Pairings & results")}</p>
        </div>

        <div class="actions" style="margin: 0">
          <a
            :if={PublicLink.public?(@tournament)}
            class="pe-btn"
            href={PublicLink.url(@tournament, :pairings)}
            target="_blank"
            title={gettext("Opens the results site - no login needed, share this link")}
          >
            {gettext("Public page")}
          </a>

          <%!-- "Live" reads as "live to the public", and this page is the
                opposite: it is the LOCAL view, the screen in the venue and
                the arbiter's own tab. What's public is OpenResults - and
                now that page also carries the projector cycle and only
                ever shows PUBLISHED rounds, calling this one "live" invited
                exactly the confusion the publish gating exists to remove. --%>
          <a class="pe-btn" href={~p"/t/#{@tournament.id}/live"} target="_blank">
            {gettext("Local view & phone QR")}
          </a>
        </div>
      </div>

      <%!-- Every postponed game still to be played, whichever round is on
            screen (VCL4THP Q162): its result can be entered at any time, and
            this is where it is found. Each one opens its own round. --%>
      <div
        :if={@postponed_open != []}
        id="postponed-games"
        class="card"
        style="display: block; margin: 12px 0; border-left: 3px solid var(--warn)"
      >
        <strong>{Postponed.not_final_text(length(@postponed_open))}</strong>
        <ul style="margin: 6px 0 0; padding-left: 20px">
          <li :for={game <- @postponed_open} id={"postponed-game-#{game.pairing.id}"}>
            {gettext("Round %{round}, board %{board}: %{white} - %{black}",
              round: game.round,
              # The frozen label the pairing sheet prints, like every other
              # board number an arbiter reads on this page.
              board: game.pairing.display_board || game.pairing.board,
              white: player_name(game.pairing.white_player),
              black: player_name(game.pairing.black_player)
            )}
            <button
              :if={game.round != @round_number}
              type="button"
              class="pe-btn"
              id={"postponed-open-round-#{game.pairing.id}"}
              phx-click="select_round"
              phx-value-number={game.round}
            >
              {gettext("Go to round %{n}", n: game.round)}
            </button>
          </li>
        </ul>
      </div>

      <div :if={!@setup_complete} class="card error-note" style="display: block; margin: 12px 0">
        {gettext("Finish the tournament setup before pairing - still missing:")}
        <ul style="margin: 6px 0 0; padding-left: 20px">
          <li :for={{field, message} <- @missing_setup}>
            <.link navigate={setup_field_path(@tournament, field)}>{message}</.link>
          </li>
        </ul>
      </div>

      <div
        :if={@setup_complete and @recommended_missing != []}
        class="card"
        style="display: block; margin: 12px 0; border-left: 3px solid var(--accent)"
      >
        {gettext("You're ready to pair. For a complete FIDE report, you may also want to fill in:")}
        <ul style="margin: 6px 0 0; padding-left: 20px">
          <li :for={{field, message} <- @recommended_missing}>
            <.link navigate={setup_field_path(@tournament, field)}>{message}</.link>
          </li>
        </ul>
      </div>

      <div class="round-picker">
        <button
          :for={n <- 1..@tournament.rounds_count}
          class={[
            "pe-btn",
            match_format?(@tournament) && "filter-picker",
            n == @round_number && "active"
          ]}
          aria-pressed={to_string(n == @round_number)}
          phx-click="select_round"
          phx-value-number={n}
        >
          {round_label(n, @tournament)}
        </button>
      </div>

      <div class="page-header" style="margin-top: 16px">
        <div>
          <h2 style="margin: 0">{round_heading(@round_number, @tournament)}</h2>

          <p class="subtitle" style="margin: 0">
            <span class={["badge", @round == nil && "muted"]}>
              {cond do
                @round == nil ->
                  "not paired"

                Enum.any?(@round.pairings, &(&1.result == "")) ->
                  "playing"

                Enum.any?(@round.pairings, &PairingsEngine.Results.postponed?(&1.result)) ->
                  gettext("postponed game still to be played")

                true ->
                  "finished"
              end}
            </span>
          </p>
        </div>

        <div class="actions" style="margin: 0; align-items: center">
          <div
            :if={@round != nil}
            id="round-publish-group"
            class="pe-publish-group"
            role="group"
            aria-label={gettext("Round %{n} on the public page", n: @round.number)}
          >
            <span class="pe-publish-group-label" aria-hidden="true">{gettext("Public")}</span>
            <.publish_controls tournament={@tournament} round={@round} short />
          </div>
          <button
            :if={@round == nil && @round_number == @next_pairable && !@tournament.archived_at}
            class="pe-btn primary"
            id="pair-round"
            phx-click="pair"
            phx-value-acknowledged={
              acknowledged_value(@pairing_warnings, [:adjourned_older_round_open])
            }
            disabled={!@can_pair || @pairing_in_progress}
            data-confirm={
              cond do
                @tournament.pairing_system == "round_robin" ->
                  "This generates the whole round-robin schedule at once (every round, not just " <>
                    "this one) and locks in who's playing - anyone added afterward won't be in " <>
                    "it, and the schedule can't be changed once it exists. Continue?"

                true ->
                  pair_confirm_text(@pairing_warnings, [:adjourned_older_round_open], @next_pairable)
              end
            }
            title={
              cond do
                !@setup_complete ->
                  "Finish the tournament setup first - missing: " <>
                    missing_setup_summary(@missing_setup)

                !@can_pair ->
                  "Previous round still has missing results"

                true ->
                  nil
              end
            }
          >
            {cond do
              @pairing_in_progress ->
                gettext("Pairing round %{n}… this can take up to a minute for large events",
                  n: @round_number
                )

              @tournament.pairing_system == "round_robin" ->
                "Pair the whole tournament (Berger)"

              true ->
                "Pair round #{@round_number} (#{pairing_engine_label(@tournament)})"
            end}
          </button>

          <%!-- The last round still has boards without a result, and every
                one of them has two players: pairing can record them as
                postponed and go ahead (VCL4THP Q159), once the arbiter has
                read what that does (Q160). The button above stays disabled
                for exactly this case, so recording is always a separate,
                deliberate click. --%>
          <button
            :if={
              @round == nil && @round_number == @next_pairable && !@tournament.archived_at &&
                !@can_pair && @setup_complete && @next_pairable <= @tournament.rounds_count &&
                has_warning?(@pairing_warnings, :missing_results_recorded_as_adjourned)
            }
            id="pair-recording-postponed"
            class="pe-btn"
            phx-click="pair"
            phx-value-acknowledged={
              acknowledged_value(@pairing_warnings, [
                :missing_results_recorded_as_adjourned,
                :adjourned_older_round_open
              ])
            }
            disabled={@pairing_in_progress}
            data-confirm={
              pair_confirm_text(
                @pairing_warnings,
                [:missing_results_recorded_as_adjourned, :adjourned_older_round_open],
                @next_pairable
              )
            }
          >
            {gettext("Record missing results as postponed and pair round %{n}", n: @round_number)}
          </button>

          <%!-- Everything for this round that is not entering results: what
                to print, and a "More" menu for the rest - PGN, a results CSV,
                and unpairing, last and apart. Native <details> menus, so every
                item is a real link or LiveView button; `.RoundMenu` closes
                them on an outside click, Escape or a choice, and the `open`
                attribute survives a re-render (results arrive live). --%>
          <details
            :if={@round != nil}
            id={"round-print-menu-#{@round_number}"}
            class="pe-dropdown"
            phx-hook=".RoundMenu"
            phx-mounted={JS.ignore_attributes(["open"])}
          >
            <summary class="pe-btn">{gettext("Print")}</summary>
            <div class="pe-dropdown-panel" role="menu">
              <a
                role="menuitem"
                id={"print-pairings-#{@round_number}"}
                href={~p"/t/#{@tournament.id}/print/pairings?round=#{@round_number}"}
                target="_blank"
              >
                {gettext("Pairings")}
              </a>
              <a
                role="menuitem"
                href={~p"/t/#{@tournament.id}/print/pairings?round=#{@round_number}&absentees=1"}
                target="_blank"
                title={
                  gettext(
                    "Same pairing sheet, with a below-the-table section listing requested byes and absences"
                  )
                }
              >
                {gettext("Pairings, with absentees section")}
              </a>
              <hr />
              <a
                role="menuitem"
                id={"print-results-#{@round_number}"}
                href={~p"/t/#{@tournament.id}/print/results?round=#{@round_number}"}
                target="_blank"
              >
                {gettext("Result cards")}
              </a>
              <a
                role="menuitem"
                href={~p"/t/#{@tournament.id}/print/results?round=#{@round_number}&limit=3"}
                target="_blank"
                title={
                  gettext(
                    "Print just the first 3 result cards, to check printer alignment before printing the full stack"
                  )
                }
              >
                {gettext("Result cards: test print (first 3)")}
              </a>
              <a
                role="menuitem"
                href={~p"/t/#{@tournament.id}/print/results?round=#{@round_number}&order=stack"}
                target="_blank"
                title={
                  gettext(
                    "Reorders cards so guillotine-cutting the printed stack into 8 piles and collating them recovers board order"
                  )
                }
              >
                {gettext("Result cards: stack-cut order")}
              </a>
            </div>
          </details>

          <details
            :if={@round != nil}
            id={"round-more-menu-#{@round_number}"}
            class="pe-dropdown"
            phx-hook=".RoundMenu"
            phx-mounted={JS.ignore_attributes(["open"])}
          >
            <summary class="pe-btn">{gettext("More")}</summary>
            <div class="pe-dropdown-panel" role="menu">
              <span class="pe-dropdown-label">
                {gettext("PGN (metadata only - no moves are recorded)")}
              </span>
              <a
                role="menuitem"
                id={"export-pgn-#{@round_number}"}
                href={~p"/t/#{@tournament.id}/export/pgn?round=#{@round_number}"}
                target="_blank"
              >
                {gettext("This round")}
              </a>
              <a
                role="menuitem"
                href={~p"/t/#{@tournament.id}/export/pgn?round=#{@round_number}&board=1"}
                target="_blank"
                title={
                  gettext(
                    ~s(Adds a [Board "N"] tag to every game, using the same board number shown on the pairing sheet)
                  )
                }
              >
                {gettext("This round, with board numbers")}
              </a>
              <a role="menuitem" href={~p"/t/#{@tournament.id}/export/pgn"} target="_blank">
                {gettext("All rounds")}
              </a>
              <a role="menuitem" href={~p"/t/#{@tournament.id}/export/pgn?board=1"} target="_blank">
                {gettext("All rounds, with board numbers")}
              </a>
              <%!-- A range of boards, e.g. the top boards for a broadcast:
                    the numbers printed on the pairing sheet. --%>
              <form
                id={"pgn-boards-form-#{@round_number}"}
                class="pe-dropdown-form"
                method="get"
                action={~p"/t/#{@tournament.id}/export/pgn"}
                target="_blank"
              >
                <input type="hidden" name="round" value={@round_number} />
                <input type="hidden" name="board" value="1" />
                <input
                  type="text"
                  name="boards"
                  id={"pgn-boards-#{@round_number}"}
                  class="pe-select"
                  placeholder={gettext("boards, e.g. 1-4")}
                  aria-label={gettext("Boards to export")}
                  required
                />
                <button type="submit" role="menuitem" class="pe-btn">
                  {gettext("This round, these boards")}
                </button>
              </form>
              <hr :if={!@tournament.archived_at} />
              <button
                :if={!@tournament.archived_at}
                type="button"
                role="menuitem"
                id={"import-results-csv-#{@round_number}"}
                phx-click="toggle_import_results"
              >
                {gettext("Import results (CSV)")}
              </button>
              <hr :if={@round_number == @paired_rounds && !@tournament.archived_at} />
              <button
                :if={@round_number == @paired_rounds && !@tournament.archived_at}
                type="button"
                role="menuitem"
                id={"unpair-round-#{@round_number}"}
                class="is-danger"
                phx-click="unpair"
                data-confirm={"Unpair round #{@round_number}? All its results will be deleted."}
              >
                {gettext("Unpair round")}
              </button>
            </div>
          </details>
        </div>
      </div>

      <div :if={@error} class="error-note" style="display: block">
        <details open={String.length(@error) <= 160}>
          <summary style="cursor: pointer">{error_summary(@error)}</summary>
          <pre style="max-height: 320px; overflow: auto; white-space: pre-wrap; word-break: break-word; margin: 6px 0 0">{@error}</pre>
        </details>
      </div>

      <form
        :if={@importing_results}
        id="results-csv-import-form"
        class="card"
        phx-submit="import_results_csv"
        phx-change="validate_results_csv"
        style="margin: 8px 0"
      >
        <h3 style="margin-top: 0">
          {gettext("Import results (CSV) - round %{n}", n: @round_number)}
        </h3>

        <p class="hint" style="margin-top: 0">
          <.rich_text text={
            gettext(
              "One line per board: %[format] (or %[semicolon]-separated). Results: %[win], %[loss], %[draw] (or %[equals]), %[both_lose] (both lose, played), %[ff_win] (forfeit win), %[double_ff] (double forfeit). Boards left out keep their current result."
            )
          }>
            <:part name="format"><code>board,result</code></:part>
            <:part name="semicolon"><code>;</code></:part>
            <:part name="win"><code>1-0</code></:part>
            <:part name="loss"><code>0-1</code></:part>
            <:part name="draw"><code>1/2-1/2</code></:part>
            <:part name="equals"><code>=</code></:part>
            <:part name="both_lose"><code>0-0</code></:part>
            <:part name="ff_win"><code>1-0FF</code>/<code>0-1FF</code></:part>
            <:part name="double_ff"><code>0-0FF</code></:part>
          </.rich_text>
        </p>

        <div
          class={["dropzone", @uploads.results_csv.entries != [] && "has-file"]}
          phx-drop-target={@uploads.results_csv.ref}
        >
          <.live_file_input
            upload={@uploads.results_csv}
            class="dropzone-input"
            aria-labelledby={"#{@uploads.results_csv.ref}-label"}
          />
          <div class="dropzone-label" id={"#{@uploads.results_csv.ref}-label"}>
            <%= if @uploads.results_csv.entries == [] do %>
              <strong>{gettext("Choose a .csv file")}</strong>
              <span class="hint">{gettext("or drag and drop it here")}</span>
            <% else %>
              <span :for={entry <- @uploads.results_csv.entries} class="dropzone-file">
                {entry.client_name}
              </span>
            <% end %>
          </div>
        </div>

        <p :for={err <- upload_errors(@uploads.results_csv)} class="error-note">{inspect(err)}</p>

        <div :if={@import_errors} class="error-note" style="display: block">
          <strong>{gettext("Nothing was saved - fix these and try again:")}</strong>
          <ul style="margin: 6px 0 0">
            <li :for={err <- @import_errors}>{import_error_text(err)}</li>
          </ul>
        </div>

        <div class="actions">
          <button type="submit" class="pe-btn primary">{gettext("Import")}</button>
          <button type="button" class="pe-btn" phx-click="toggle_import_results">
            {gettext("Cancel")}
          </button>
        </div>
      </form>

      <div :if={@swap_first} class="swap-banner" phx-window-keydown="cancel_swap" phx-key="escape">
        <span class="swap-banner-dot"></span>
        <span id="swap-banner-text">
          <.rich_text text={
            gettext(
              "Swapping %[name] - now click whoever they should trade places with, on a board or in the not-playing list below."
            )
          }>
            <:part name="name"><strong>{@swap_first.name}</strong></:part>
          </.rich_text>
        </span>
        <button type="button" class="pe-btn" phx-click="cancel_swap">{gettext("Cancel (Esc)")}</button>
      </div>

      <div
        :if={@pool_first}
        class="swap-banner"
        phx-window-keydown="cancel_pool_pair"
        phx-key="escape"
      >
        <span class="swap-banner-dot"></span>
        <span id="pool-pair-banner-text">
          <.rich_text text={gettext("Pairing %[name] - now click who they should play.")}>
            <:part name="name"><strong>{@pool_first.name}</strong></:part>
          </.rich_text>
        </span>
        <button type="button" class="pe-btn" phx-click="cancel_pool_pair">{gettext("Cancel (Esc)")}</button>
      </div>

      <div
        :if={@seat_pick}
        class="swap-banner"
        phx-window-keydown="cancel_seat_pick"
        phx-key="escape"
      >
        <span class="swap-banner-dot"></span>
        <span>{gettext("Which empty seat should they take? Click one below.")}</span>
        <button type="button" class="pe-btn" phx-click="cancel_seat_pick">{gettext("Cancel (Esc)")}</button>
      </div>
      <.pairing_menu :if={@menu} menu={@menu} round={@round} tournament={@tournament} />
      <div :if={@confirm} class="pe-modal" phx-window-keydown="cancel_confirm" phx-key="escape">
        <div
          class="pe-modal-card pe-modal-wide"
          phx-click-away="cancel_confirm"
          id="hand-edit-dialog"
          role="dialog"
          aria-modal="true"
          aria-labelledby="hand-edit-title"
          tabindex="-1"
          phx-hook="DialogFocus"
          data-dialog
        >
          <header class="pe-modal-head">
            <h2 id="hand-edit-title">{@confirm.title}</h2>

            <p>{@confirm.subtitle}</p>
          </header>

          <div class="pe-modal-body">
            <div id="confirm-board-diffs" class="board-diff-group" phx-hook=".SwapArrows">
              <div :for={c <- @confirm.changes} class="board-diff">
                <div class="board-diff-num">{gettext("Board %{n}", n: c.board)}</div>
                <.board_card
                  seats={c.before}
                  state="before"
                  compare={c.after}
                  color_by_name={@confirm[:colors] || %{}}
                />
                <div class="board-diff-arrow">→</div>
                <.board_card
                  seats={c.after}
                  state="after"
                  compare={c.before}
                  color_by_name={@confirm[:colors] || %{}}
                />
              </div>
              <%!-- The "not playing list" row a `:swap_pool` substitution adds
                    alongside its board row - see `confirm_for/2`'s comment on
                    `bench:`. Inside the same `#confirm-board-diffs` container
                    as the loop above so `.SwapArrows` finds both rows' seats
                    together. --%>
              <div :if={@confirm[:bench]} class="board-diff board-diff-bench">
                <div class="board-diff-num">{gettext("Not playing list")}</div>
                <.bench_card
                  name={@confirm.bench.before}
                  state="before"
                  color_by_name={@confirm[:colors] || %{}}
                />
                <div class="board-diff-arrow">→</div>
                <.bench_card
                  name={@confirm.bench.after}
                  state="after"
                  color_by_name={@confirm[:colors] || %{}}
                />
              </div>
              <%!-- Filled in by the .SwapArrows hook; phx-update="ignore" so
                    LiveView leaves the generated SVG alone on re-render. --%>
              <div id="swap-arrows-layer" class="swap-arrows-layer" phx-update="ignore"></div>
            </div>

            <label :if={@confirm.kind == :pool_pair} class="board-number-field">
              <span>{gettext("Table number")}</span>
              <form id="confirm-board-form" phx-change="set_confirm_board">
                <input type="number" name="board" value={@confirm.board} min="1" />
              </form>
            </label>

            <p :if={@confirm.note} class="pe-modal-note">{@confirm.note}</p>

            <p
              :if={match?({:ok, _}, @confirm[:team_note])}
              id="confirm-team-note"
              class="pe-modal-note"
              role="status"
            >
              {elem(@confirm.team_note, 1)}
            </p>

            <p
              :if={match?({:warn, _}, @confirm[:team_note])}
              id="confirm-team-note"
              class="pe-modal-warn"
              role="status"
            >
              {elem(@confirm.team_note, 1)}
            </p>

            <p
              :if={Enum.any?(@confirm.changes, &Map.get(&1, :result_will_clear?))}
              class="pe-modal-warn"
            >
              {gettext(
                "A recorded result will be cleared - it described a game between players who are no longer both on that board."
              )}
            </p>

            <%!-- The loudest thing in the dialog: the federation already has
                  this round. --%>
            <div
              :if={@confirm[:sent]}
              class="pe-modal-warn"
              id="confirm-sent-round"
              role="alert"
              style="border-width: 2px; font-size: 1.05em"
            >
              <strong>
                {gettext(
                  "⚠ Round %{n} was already sent to FIDE in a TRF finalised for sending.",
                  n: @round_number
                )}
              </strong>
              <p style="margin: 6px 0 0">
                {gettext(
                  "This changes who played whom here only: the file that was sent keeps the old pairing, and the tournament will no longer agree with it. The round stays marked as sent and is not sent again. Only go on to correct a real mistake, and tell the rating officer."
                )}
              </p>

              <label style="display: flex; align-items: center; gap: 6px; margin-top: 6px; font-weight: 400">
                <input
                  type="checkbox"
                  id="confirm-sent-ack"
                  checked={@confirm.sent_ack}
                  phx-click="toggle_sent_ack"
                />
                {gettext("I understand - change the sent round %{n} anyway", n: @round_number)}
              </label>
            </div>

            <div :if={@confirm.frozen} class="pe-modal-warn">
              <strong>
                {gettext("You're changing round %{n}, not the current round (round %{current}).",
                  n: @round_number,
                  current: @paired_rounds
                )}
              </strong>

              <label style="display: flex; align-items: center; gap: 6px; margin-top: 6px; font-weight: 400">
                <input type="checkbox" checked={@confirm.frozen_ack} phx-click="toggle_frozen_ack" />
                {gettext("I understand - apply this to round %{n} anyway", n: @round_number)}
              </label>
            </div>
          </div>

          <footer class="pe-modal-foot">
            <button type="button" class="pe-btn" phx-click="cancel_confirm">
              {gettext("Cancel")}
            </button>
            <button
              type="button"
              class="pe-btn primary pe-modal-go"
              phx-click="apply_confirm"
              disabled={
                (@confirm.frozen and !@confirm.frozen_ack) or
                  (@confirm[:sent] == true and !@confirm.sent_ack)
              }
            >
              {@confirm.title}
            </button>
          </footer>
        </div>
      </div>

      <p :if={initial_colour_text(@tournament)} id="initial-colour" class="hint">
        {initial_colour_text(@tournament)}
      </p>

      <div :if={@team_matches != []} id="team-matches" class="card table-card">
        <table class="pe-table">
          <caption>{gettext("Matches - round %{n}", n: @round_number)}</caption>
          <thead>
            <tr>
              <th scope="col" class="num">{gettext("Match")}</th>
              <th scope="col" class="num">{gettext("Boards")}</th>
              <th scope="col">{gettext("Team (White on board 1)")}</th>
              <th scope="col" class="num">{gettext("Game points")}</th>
              <th scope="col">{gettext("Team")}</th>
              <th scope="col" class="num">{gettext("Match points")}</th>
              <th scope="col">{gettext("Forfeit by decision")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={m <- @team_matches} id={"team-match-#{m.match_id}"}>
              <td class="num">{m.number}</td>
              <td class="num">{match_board_range(m.boards)}</td>
              <td><strong>{match_team_name(@teams_by_id, m.team_a_id)}</strong></td>
              <td :if={m.bye?} class="num">-</td>
              <td :if={!m.bye?} class="num">
                {format_match_score(m.gp_a)} - {format_match_score(m.gp_b)}
              </td>
              <td :if={m.bye? and is_nil(m.mp_a)}><em>{gettext("does not play this round")}</em></td>
              <td :if={m.bye? and not is_nil(m.mp_a)}>
                <em>{gettext("pairing-allocated bye, scored as a drawn match")}</em>
              </td>
              <td :if={!m.bye?}><strong>{match_team_name(@teams_by_id, m.team_b_id)}</strong></td>
              <td :if={m.bye? and is_nil(m.mp_a)} class="num">-</td>
              <td :if={m.bye? and not is_nil(m.mp_a)} class="num">{format_match_score(m.mp_a)}</td>
              <td :if={!m.bye? and m.complete?} class="num">
                {format_match_score(m.mp_a)} - {format_match_score(m.mp_b)}
              </td>
              <%!-- A match with a postponed board is not complete: its score
                    is the provisional one the next round is paired with, the
                    postponed boards counting as draws. --%>
              <td
                :if={!m.bye? and m.scored? and !m.complete?}
                class="num"
                id={"match-provisional-#{m.match_id}"}
              >
                {format_match_score(m.mp_a)} - {format_match_score(m.mp_b)}
                <span class="hint">
                  {ngettext(
                    "(provisional: %{count} board postponed)",
                    "(provisional: %{count} boards postponed)",
                    m.postponed_boards
                  )}
                </span>
              </td>
              <td :if={!m.bye? and !m.scored?} class="num">
                <span class="hint">{gettext("in progress")}</span>
              </td>
              <td :if={m.bye?}>-</td>
              <td :if={!m.bye? and not is_nil(m.forfeited_to)}>
                <span id={"match-decision-#{m.match_id}"}>
                  {gettext("Forfeited to %{team} by decision",
                    team: match_team_name(@teams_by_id, m.forfeited_to)
                  )}
                </span>
                <button
                  type="button"
                  class="pe-btn"
                  phx-click="withdraw_match_forfeit"
                  phx-value-match-id={m.match_id}
                  aria-describedby={"match-decision-#{m.match_id}"}
                  data-confirm={
                    gettext(
                      "Withdraw the decision? The boards of match %{match} get back the results they had before it.",
                      match: m.number
                    )
                  }
                  disabled={!is_nil(@tournament.archived_at)}
                >
                  {gettext("Withdraw the decision")}
                </button>
              </td>
              <td :if={!m.bye? and is_nil(m.forfeited_to)}>
                <button
                  :for={team_id <- [m.team_a_id, m.team_b_id]}
                  type="button"
                  class="pe-btn"
                  phx-click="forfeit_match"
                  phx-value-match-id={m.match_id}
                  phx-value-team-id={team_id}
                  aria-label={
                    gettext("Forfeit match %{match} to %{team}",
                      match: m.number,
                      team: match_team_name(@teams_by_id, team_id)
                    )
                  }
                  data-confirm={
                    gettext(
                      "Forfeit match %{match} to %{team}? Every board becomes a forfeit win for %{team}. The decision can be withdrawn.",
                      match: m.number,
                      team: match_team_name(@teams_by_id, team_id)
                    )
                  }
                  disabled={!is_nil(@tournament.archived_at) or m.boards == []}
                >
                  {gettext("To %{team}", team: match_team_name(@teams_by_id, team_id))}
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div
        :if={@unattached_boards != []}
        id="unattached-boards"
        class="card"
        role="region"
        aria-labelledby="unattached-boards-title"
      >
        <h2 id="unattached-boards-title" class="pe-modal-warn" style="margin: 0 0 8px">
          {ngettext(
            "%{count} board in this round is not part of a match: it counts for no team.",
            "%{count} boards in this round are not part of a match: they count for no team.",
            length(@unattached_boards)
          )}
        </h2>
        <ul>
          <li :for={u <- @unattached_boards} id={"unattached-board-#{u.pairing.id}"}>
            {gettext("Board %{board}: %{white} - %{black}.",
              board: u.pairing.board,
              white: player_name(u.pairing.white_player) || "-",
              black: player_name(u.pairing.black_player) || "-"
            )}
            <%= case u.slot do %>
              <% {:ok, slot} -> %>
                <button
                  type="button"
                  class="pe-btn"
                  phx-click="attach_board"
                  phx-value-pairing-id={u.pairing.id}
                  disabled={!is_nil(@tournament.archived_at)}
                >
                  {gettext("Make it board %{board} of match %{match}",
                    board: slot.board,
                    match: slot.match.board
                  )}
                </button>
              <% {:error, reason} -> %>
                <span class="hint">{slot_reason(reason)}</span>
            <% end %>
          </li>
        </ul>
      </div>

      <div class="card table-card">
        <%!-- `data-scope="round"` sits on the table itself, not one more
             row or cell, so a right-click anywhere on the board that
             ISN'T already a more specific target (a seat, an empty seat)
             falls through to it - discoverable "board by board", per the
             maintainer's own framing of this gap, without adding a new
             element just to hold the attribute. Only present once there
             IS a round: with none paired, the table has nothing but the
             "not paired yet" placeholder row and no round to publish. --%>
        <table
          class="pe-table"
          id={"pairings-table-#{@round_number}"}
          phx-hook=".PairingMenu"
          data-scope={@round && "round"}
        >
          <%!-- White right-aligned, Result centred, Black left-aligned - a
               printed pairing sheet's convention, not two left-aligned name
               columns with the result floating between whatever they leave
               over. `.pairing-white`/`.pairing-black` also split the width
               the Board and Result columns don't use, so the result sits in
               the middle of the row rather than just centred in its own
               fixed box. See `assets/css/app.css`. --%>
          <thead>
            <tr>
              <th class="num">{gettext("Board")}</th>

              <th class="pairing-white">{gettext("White")}</th>

              <th class="pairing-result">{gettext("Result")}</th>

              <th class="pairing-black">{gettext("Black")}</th>
            </tr>
          </thead>

          <tbody>
            <tr :if={@round == nil}>
              <td colspan="4">
                <div class="empty">
                  <p><strong>{gettext("This round has not been paired yet.")}</strong></p>

                  <p class="hint">
                    <%= cond do %>
                      <% @tournament.archived_at -> %>
                        {gettext(
                          "This tournament is archived, so no more rounds can be paired. Unarchive it first if you need to change that."
                        )}
                      <% @tournament.pairing_system == "round_robin" -> %>
                        {gettext(
                          "Press \"Pair the whole tournament\" to generate every round of the Berger schedule at once - round-robin doesn't pair one round at a time."
                        )}
                      <% @round_number == @next_pairable -> %>
                        {gettext(
                          "Press \"Pair round %{n}\" to generate the %{engine}.",
                          n: @round_number,
                          engine: pairing_engine_description(@tournament)
                        )}
                      <% true -> %>
                        {gettext("Rounds are paired in order - round %{n} is next.",
                          n: @next_pairable
                        )}
                    <% end %>
                  </p>

                  <%!-- A postponed game in the last round counts as a draw for
                        this pairing (VCL4THP Q158, Q167) - said beside the
                        button, not asked: nothing is unusual about it. --%>
                  <p
                    :for={w <- @pairing_warnings}
                    :if={w.id == :adjourned_counted_as_draw and @round_number == @next_pairable}
                    id="postponed-counted-as-draw"
                    class="hint"
                  >
                    {Postponed.pairing_warning_text(w, @next_pairable)}
                  </p>
                </div>
              </td>
            </tr>

            <tr
              :for={
                %{pairing: pairing, board: display_board} <-
                  display_rows((@round && @round.pairings) || [])
              }
              id={"pairing-row-#{pairing.id}"}
            >
              <td class="num" phx-no-format>{display_board}<.no_team :if={no_team?(@unattached_boards, pairing)} /></td>

              <td class="pairing-white">
                <.seat_cell
                  player={pairing.white_player}
                  pairing={pairing}
                  side={:white}
                  board={display_board}
                  swap_first={@swap_first}
                  seat_pick={@seat_pick}
                  scores={@scores}
                />
              </td>

              <td class="pairing-result">
                <%= cond do %>
                  <% pairing.result == "bye" -> %>
                    <span class="badge">{gettext("bye (%{pts} pt)", pts: @tournament.bye_value)}</span>
                  <% @confirm_postponed && @confirm_postponed.pairing_id == pairing.id -> %>
                    <%!-- A postponed game given a result that is not a draw
                          (VCL4THP Q163): the same shape as clearing a result,
                          focus on Cancel. --%>
                    <div
                      class="confirm-clear-result confirm-postponed"
                      id={"confirm-postponed-#{pairing.id}"}
                    >
                      <span class="hint" id={"confirm-postponed-text-#{pairing.id}"}>
                        <span :if={:adjourned_non_draw_result in @confirm_postponed.ids}>
                          {Postponed.non_draw_text(
                            @round_number,
                            display_board,
                            @confirm_postponed.result,
                            pairing
                          )}
                        </span>
                        <span
                          :if={:finalised_result_changed in @confirm_postponed.ids}
                          id={"confirm-finalised-#{pairing.id}"}
                        >
                          {Postponed.finalised_changed_text(
                            @round_number,
                            display_board,
                            @confirm_postponed.result
                          )}
                        </span>
                      </span>

                      <button
                        type="button"
                        class="pe-btn primary"
                        id={"confirm-postponed-yes-#{pairing.id}"}
                        phx-click="confirm_postponed_result"
                        phx-value-pairing-id={pairing.id}
                        aria-describedby={"confirm-postponed-text-#{pairing.id}"}
                      >
                        {gettext("Enter %{result}", result: @confirm_postponed.result)}
                      </button>

                      <button
                        type="button"
                        class="pe-btn"
                        id={"confirm-postponed-cancel-#{pairing.id}"}
                        phx-click="cancel_postponed_result"
                        aria-describedby={"confirm-postponed-text-#{pairing.id}"}
                        phx-mounted={JS.focus()}
                      >
                        {gettext("Cancel")}
                      </button>
                    </div>
                  <% @confirm_clear_pairing_id == pairing.id -> %>
                    <%!-- This box REPLACES the result select, which had focus, so
                          focus is put on Cancel as it appears - the safe answer,
                          one Shift+Tab from "Yes" - and both buttons carry the
                          question, which a screen reader otherwise never reads. --%>
                    <div class="confirm-clear-result">
                      <span class="hint" id={"confirm-clear-#{pairing.id}"}>
                        {gettext("Clear the recorded result (%{result}) for this board?",
                          result: pairing.result
                        )}
                      </span>

                      <button
                        type="button"
                        class="pe-btn danger-link"
                        phx-click="confirm_clear_result"
                        phx-value-pairing-id={pairing.id}
                        aria-describedby={"confirm-clear-#{pairing.id}"}
                      >
                        {gettext("Yes, clear it")}
                      </button>

                      <button
                        type="button"
                        class="pe-btn"
                        phx-click="cancel_clear_result"
                        aria-describedby={"confirm-clear-#{pairing.id}"}
                        phx-mounted={JS.focus()}
                      >
                        {gettext("Cancel")}
                      </button>
                    </div>
                  <% true -> %>
                    <%!-- Named for the board and the two players: tabbing (or
                          typing 1/2/3) from board to board, the name is all a
                          screen reader says about which game this is. Focus comes
                          back here when the clear-confirmation box above closes
                          (`refocus_result`). --%>
                    <form phx-change="result" id={"result-form-#{pairing.id}"}>
                      <input type="hidden" name="pairing-id" value={pairing.id} />
                      <select
                        name="result"
                        class="pe-select"
                        id={"result-select-#{pairing.id}"}
                        phx-hook=".BlindResultEntry"
                        aria-label={
                          gettext("Result, board %{board}: %{white} against %{black}",
                            board: display_board,
                            white: player_name(pairing.white_player),
                            black: player_name(pairing.black_player)
                          )
                        }
                        phx-mounted={@refocus_result == pairing.id && JS.focus()}
                        data-board-select
                        data-result={pairing.result}
                        data-refused={@write_refused_nonce}
                        disabled={!is_nil(@tournament.archived_at)}
                      >
                        <option
                          :for={{value, label} <- results(@tournament, pairing)}
                          value={value}
                          selected={pairing.result == value}
                        >
                          {label}
                        </option>
                      </select>
                    </form>
                <% end %>
              </td>

              <td class="pairing-black">
                <.seat_cell
                  player={pairing.black_player}
                  pairing={pairing}
                  side={:black}
                  board={display_board}
                  swap_first={@swap_first}
                  seat_pick={@seat_pick}
                  scores={@scores}
                />
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <%!-- Hidden rows never render in the table above (see `display_rows/1`),
           so this is their only reachable management surface: unhide them,
           or (only on the round's actual last board) delete them for
           good. Boards are listed by their real number, not the frozen
           display label - an arbiter managing clutter cares which
           physical board this is, and a hidden row by definition no
           longer has a display label anyone sees anywhere else. --%>
      <div :if={@hidden_pairings != []} class="card table-card" style="margin-top: 16px">
        <h3 style="margin-top: 0">{gettext("Hidden boards")}</h3>

        <p class="hint">
          {gettext(
            "Fully-vacated boards hidden from this round's table, prints, live view and public page. Hiding never renumbers anything else - un-hide any time to bring a row back exactly as it was."
          )}
        </p>

        <ul class="pool-list">
          <li
            :for={pairing <- @hidden_pairings}
            style="display: flex; align-items: center; gap: 8px"
          >
            <span>{gettext("Board %{n}", n: pairing.board)}</span>

            <button
              type="button"
              class="pe-btn"
              phx-click="toggle_hidden"
              phx-value-pairing-id={pairing.id}
            >
              {gettext("Unhide")}
            </button>

            <button
              :if={last_board?(@round, pairing)}
              type="button"
              class="pe-btn danger-link"
              phx-click="stage_delete_pairing"
              phx-value-pairing-id={pairing.id}
            >
              {gettext("Delete…")}
            </button>
          </li>
        </ul>
      </div>

      <div
        :if={@round != nil and @round_pool != []}
        class="card pool-panel"
        id={"round-pool-#{@round_number}"}
        phx-hook=".PairingMenu"
      >
        <div class="pool-head">
          <h3>{gettext("Not playing round %{n}", n: @round_number)}</h3>

          <p class="hint">
            {gettext(
              "Right-click anyone here to put them in an empty seat, swap them onto a board, or pair two of them together."
            )}
          </p>
        </div>

        <ul class="pool-list">
          <li
            :for={entry <- @round_pool}
            class={[
              "pool-chip",
              @swap_first && @swap_first.id == entry.player.id && "swap-selected",
              @pool_first && @pool_first.id == entry.player.id && "swap-selected",
              @swap_first && @swap_first.id != entry.player.id && "swap-eligible"
            ]}
            data-player-id={entry.player.id}
            data-scope="pool"
            phx-click={if @swap_first || @pool_first, do: pool_click(@swap_first), else: nil}
            phx-value-player-id={entry.player.id}
            title={gettext("Right-click for options")}
          >
            <%!-- The keyboard target is the name, not the `<li>` (a list
                  item cannot be a button); a keydown or a click on it
                  reaches the chip's `data-scope` and `phx-click` above. --%>
            <span
              class="pool-chip-name"
              id={"pool-seat-#{entry.player.id}"}
              role="button"
              tabindex="0"
              aria-haspopup="menu"
              aria-label={gettext("Not playing: %{name}", name: player_label(entry.player))}
              aria-describedby={
                (@swap_first && "swap-banner-text") || (@pool_first && "pool-pair-banner-text")
              }
              data-seat
              data-armed={
                (@swap_first && @swap_first.id != entry.player.id) ||
                  (@pool_first && @pool_first.id != entry.player.id)
              }
            >
              {player_label(entry.player)}
            </span>
            <span class="pool-chip-tag">{pool_tag(entry, @tournament, @absent_counts)}</span>
            <span
              :if={
                (@swap_first && @swap_first.id == entry.player.id) ||
                  (@pool_first && @pool_first.id == entry.player.id)
              }
              class="swap-armed-tag"
            >
              {if @swap_first, do: gettext("swapping"), else: gettext("pairing")}
            </span>
          </li>
        </ul>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".BlindResultEntry">
        // SWAR-style "blind" result entry: with a board's result <select>
        // focused, typing 1 / 2 / 3 sets that board's result (white win /
        // draw / black win) and moves focus to the next board's result
        // select, so a sequence like "131312" fills in six boards in a row
        // without touching the mouse.
        // Mapped by PHYSICAL key (e.code) so the top-row/numpad 1/2/3 keys
        // work on any keyboard layout (e.g. AZERTY, where the top row
        // produces & é " without Shift). e.key is kept as a fallback.
        const CODE_TO_VALUE = {
          "Digit1": "1-0", "Numpad1": "1-0",
          "Digit2": "1/2-1/2", "Numpad2": "1/2-1/2",
          "Digit3": "0-1", "Numpad3": "0-1"
        };
        const KEY_TO_VALUE = {"1": "1-0", "2": "1/2-1/2", "3": "0-1"};

        export default {
          mounted() {
            // A native <select> opens its dropdown on the same click that
            // focuses it - and while that native popup is open, the browser
            // intercepts number keys for its own "jump to option" behavior
            // before our keydown listener below ever sees them (confirmed:
            // typing did nothing until a second click closed the popup,
            // leaving the element focused-but-closed). Clicking to open a
            // fresh select is the arbiter's actual entry point for the "1/2/3"
            // workflow, so it must land focused-and-CLOSED in one click.
            // Only intercept the click that's ABOUT to focus this element -
            // if it's already focused, let a second click open the dropdown
            // normally (still needed to pick a code with no 1/2/3 shortcut,
            // e.g. a forfeit result).
            this.onMousedown = (e) => {
              this.abandon();
              if (document.activeElement !== this.el) {
                e.preventDefault();
                this.el.focus();
              }
            };
            this.el.addEventListener("mousedown", this.onMousedown);

            // Walking the options with the arrow keys. On a CLOSED select,
            // Windows and Linux browsers change the value - and fire
            // "change" - on every arrow press, so going from 1-0 to 0-1 by
            // keyboard wrote 1/2-1/2 on the way (a result and an audit row),
            // and passing the blank option staged the "clear this result?"
            // box, which replaced the select under the keyboard mid-walk.
            // While `browsing`, those intermediate events are held back here,
            // before LiveView (listening further up) sees them; the choice
            // is sent once, on Enter or when focus leaves, and Escape puts
            // the recorded result back. A mouse pick, the 1/2/3 keys and an
            // opened dropdown's own Enter still send straight away.
            this.browsing = false;

            this.hold = (e) => {
              if (this.browsing && !this.committing) { e.stopPropagation(); }
            };
            this.el.addEventListener("input", this.hold);
            this.el.addEventListener("change", this.hold);

            this.onBlur = () => { if (this.browsing) { this.commit(); } };
            this.el.addEventListener("blur", this.onBlur);

            this.onKeydown = (e) => {
              // Opening the list (Alt+Down, F4, Space) abandons an arrow walk:
              // the pick is about to come from the list, whose own Enter the
              // page never sees, so nothing may still be held back by then.
              if ((e.altKey && ["ArrowUp", "ArrowDown"].includes(e.key)) || e.key === "F4" || e.key === " ") {
                this.abandon();
                return;
              }

              if (["ArrowUp", "ArrowDown", "PageUp", "PageDown", "Home", "End"].includes(e.key)) {
                this.browsing = true;
                return;
              }

              if (e.key === "Enter" && this.browsing) {
                e.preventDefault();
                this.commit();
                return;
              }

              if (e.key === "Escape" && this.browsing) {
                this.abandon();
                return;
              }

              // Ctrl, Alt or Cmd with a digit is somebody else's shortcut -
              // Ctrl+1..3 switches browser tabs, AltGr (Ctrl+Alt) types ~ and #
              // on AZERTY - not a result. Matched by physical key, these used
              // to record one on the focused board and swallow the shortcut.
              // Shift stays allowed: AZERTY needs it for the digits.
              if (e.ctrlKey || e.altKey || e.metaKey) return;

              const value = CODE_TO_VALUE[e.code] || KEY_TO_VALUE[e.key];
              if (!value) return; // let every other key behave natively

              const hasOption = Array.from(this.el.options).some((o) => o.value === value);
              if (!hasOption) return;

              // Stop the browser's native "jump to option starting with
              // this character" select behavior - we're fully driving the
              // value ourselves.
              e.preventDefault();

              this.browsing = false;
              this.el.value = value;
              // LiveView's phx-change listens for a real "change" event
              // bubbling up from the form.
              this.el.dispatchEvent(new Event("change", {bubbles: true}));

              // Close any open native dropdown before moving focus, or it
              // stays visibly open over the next board's select.
              this.el.blur();

              this.focusNextBoard();
            };

            this.el.addEventListener("keydown", this.onKeydown);
          },

          // Drops an arrow-key walk and shows the recorded result again.
          abandon() {
            if (!this.browsing) { return; }
            this.browsing = false;
            this.el.value = this.el.dataset.result || "";
          },

          // Sends the value an arrow-key walk ended on, if it differs from
          // what is recorded.
          commit() {
            this.browsing = false;
            if (this.el.value === (this.el.dataset.result || "")) { return; }

            this.committing = true;
            this.el.dispatchEvent(new Event("change", {bubbles: true}));
            this.committing = false;
          },

          // Real incident: an arbiter changed a result on one tab (e.g.
          // "0-0FF" -> "0-0"); a second arbiter viewing the same round, who
          // simply had that SAME board's select focused (nothing more --
          // no typing in progress), never saw the change. Root cause is a
          // genuine Phoenix LiveView behavior, not a bug in this app's own
          // code: once a form control has been interacted with, LiveView's
          // client won't overwrite its `value`/`selected` state on a
          // server-pushed diff, so as not to clobber someone's in-progress
          // typing - and confirmed by hand, that pin doesn't even clear on
          // blur; the element stays stuck on the stale value until it's
          // touched again or the page reloads. That protection makes sense
          // for a free-text field mid-keystroke; it's actively wrong for a
          // discrete-choice dropdown like this one, where "reflect the
          // truth immediately" matters far more than "don't disturb an
          // open dropdown" for the sliver of a second that's even at risk.
          //
          // Fix: the true value is ALSO mirrored into `data-result` (a
          // plain attribute, not `value`/`selected`, so it's exempt from
          // that protection and patches normally regardless of focus).
          // `updated()` fires on every server-pushed diff to this element,
          // focused or not - resync `value` from it whenever they drift.
          updated() {
            const truth = this.el.dataset.result;
            if (truth !== undefined && this.el.value !== truth) {
              this.el.value = truth;
            }
          },

          focusNextBoard() {
            const selects = Array.from(document.querySelectorAll("select[data-board-select]"));
            const index = selects.indexOf(this.el);
            if (index >= 0 && index < selects.length - 1) {
              const next = selects[index + 1];

              // Focusing normally makes the browser jump-scroll the next
              // select into view only once it's fully out of the viewport -
              // the screen sits still for several entries, then lurches
              // several rows at once. `preventScroll` stops that native
              // jump so we can drive a smooth, one-row-at-a-time scroll
              // ourselves below instead.
              next.focus({ preventScroll: true });

              const row = next.closest("tr") || next;
              const calm = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
              row.scrollIntoView({ behavior: calm ? "auto" : "smooth", block: "center" });
            } else {
              // The last board: stay on it. The blur above closed any open
              // dropdown, and leaving focus there dropped the keyboard onto
              // the page itself, somewhere above the table.
              this.el.focus({ preventScroll: true });
            }
          },

          destroyed() {
            this.el.removeEventListener("keydown", this.onKeydown);
            this.el.removeEventListener("mousedown", this.onMousedown);
            this.el.removeEventListener("input", this.hold);
            this.el.removeEventListener("change", this.hold);
            this.el.removeEventListener("blur", this.onBlur);
          }
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".SwapArrows">
        // Draws one curved arrow per player SHOWN in the confirm modal, not
        // only the ones who moved: from where they sit in the "before" card
        // to where they sit in the "after" one. A two-board player swap
        // shows 4 people - the 2 who traded boards (a real, crossing
        // journey) plus whoever they left in place on each board (a short
        // arrow back to their own seat) - so every name shown has one,
        // rather than 2 obviously-moved arrows next to 2 unmarked names
        // that look forgotten. A same-board colour swap only ever shows the
        // 2 who moved, since there's nobody else on that one board to draw.
        //
        // Which seats to join is decided by NAME MATCHING, not by a flag
        // from the server: a curve exists exactly when one name appears on
        // both sides. That's 4 curves for a player swap, 2 for a colour
        // swap, and ZERO for mark-absent / award-bye / fill-seat /
        // pool-pair / substitute-from-pool, where nobody shown keeps the
        // same identity on both sides of an empty seat - no new server
        // state to keep in sync, and it cannot mislabel a non-swap as one.
        //
        // The curves route through the middle grid column (normally just the
        // static "→", hidden while arrows are up and widened into a real
        // channel). Straight-line arrows would tunnel under the opaque
        // board cards; routing through the empty channel keeps every name
        // readable.
        //
        // Pure enhancement: no JS, a failed measurement or an ambiguous
        // name match all leave the plain "→" layout exactly as it is.
        const REDUCED_MOTION = "(prefers-reduced-motion: reduce)";
        const SVG_NS = "http://www.w3.org/2000/svg";
        // Straight run at each end of a curve, and how far short of the
        // destination card the arrowhead stops.
        const STUB = 12;
        const HEAD_GAP = 4;
        // `seat_text("")`'s own placeholder, verbatim - an empty seat never
        // gets an arrow drawn to/from it (see `matchTravellers/1`).
        const EMPTY_SEAT_TEXT = "- empty -";

        export default {
          mounted() {
            this.onResize = () => this.schedule();
            window.addEventListener("resize", this.onResize);
            this.schedule();
          },

          // LiveView re-renders this modal for reasons unrelated to the
          // diff (the frozen-round checkbox, a remote broadcast that now
          // keeps the confirm open) and its patch drops both the class and
          // the generated SVG, so redraw rather than assume they survived.
          updated() {
            this.schedule();
          },

          destroyed() {
            window.removeEventListener("resize", this.onResize);
            clearTimeout(this.timer);
          },

          // Deliberately setTimeout, not requestAnimationFrame: rAF never
          // fires while the tab isn't compositing (backgrounded, or a
          // hidden panel), which would leave the arrows silently missing
          // until something forced a repaint.
          schedule() {
            clearTimeout(this.timer);
            this.timer = setTimeout(() => this.draw(), 0);
          },

          draw() {
            const layer = this.el.querySelector(".swap-arrows-layer");
            if (!layer) return;

            layer.replaceChildren();
            this.el.classList.remove("has-swap-arrows");

            const pairs = this.matchTravellers();
            if (pairs.length === 0) return;

            // Widening the channel reflows the grid, so the new column
            // widths have to land BEFORE anything is measured - reading a
            // layout property forces that synchronously, rather than
            // waiting on a frame that may never come.
            this.el.classList.add("has-swap-arrows");
            void this.el.offsetHeight;

            this.render(layer, pairs);
          },

          // [beforeSeatEl, afterSeatEl] for every name shown on BOTH sides -
          // not only the ones already flagged "changed". A two-board player
          // swap shows 4 people (the 2 who traded boards, plus whoever they
          // left in place on each board); a same-board colour swap shows
          // only the 2 who moved, since there's nobody else on that board to
          // draw. Either way every name gets an arrow: the 2 (or 4) who
          // actually moved get a real journey: the ones who didn't get a
          // short one back to their own seat, same colour, so nobody shown
          // reads as "forgotten" next to the ones who visibly moved.
          //
          // A name appearing twice on either side is ambiguous (two players
          // sharing a display name) - skipped rather than guessed at, since
          // a wrong arrow is worse than none. The empty-seat placeholder
          // text is excluded outright: two different blank seats matching
          // each other by that shared placeholder would be a false pair,
          // not a real name.
          matchTravellers() {
            const nameOf = (el) =>
              (el.querySelector(".board-seat-name")?.textContent || "").trim();
            const isRealName = (name) => name && name !== EMPTY_SEAT_TEXT;

            const before = Array.from(this.el.querySelectorAll(".board-card-before .board-seat"));
            const after = Array.from(this.el.querySelectorAll(".board-card-after .board-seat"));

            const tally = (els) => {
              const counts = new Map();
              els.forEach((el) => {
                const n = nameOf(el);
                if (isRealName(n)) counts.set(n, (counts.get(n) || 0) + 1);
              });
              return counts;
            };

            const beforeCounts = tally(before);
            const afterCounts = tally(after);
            const pairs = [];

            before.forEach((from) => {
              const name = nameOf(from);
              if (!isRealName(name)) return;
              if (beforeCounts.get(name) !== 1 || afterCounts.get(name) !== 1) return;

              const to = after.find((el) => nameOf(el) === name);
              if (to) pairs.push([from, to]);
            });

            return pairs;
          },

          render(layer, pairs) {
            const group = this.el.getBoundingClientRect();
            const box = (el) => {
              const r = el.getBoundingClientRect();
              return { x: r.left - group.left, y: r.top - group.top, w: r.width, h: r.height };
            };
            // A seat's arrow attaches to its CARD's edge, at the seat row's
            // own height - so the curve leaves the card beside the right
            // name rather than from the card's middle.
            const exit = (seat) => {
              const card = box(seat.closest(".board-card"));
              const row = box(seat);
              return { x: card.x + card.w, y: row.y + row.h / 2 };
            };
            const entry = (seat) => {
              const card = box(seat.closest(".board-card"));
              const row = box(seat);
              return { x: card.x, y: row.y + row.h / 2 };
            };

            const svg = document.createElementNS(SVG_NS, "svg");
            svg.setAttribute("class", "swap-arrows");
            svg.setAttribute("width", group.width);
            svg.setAttribute("height", group.height);
            svg.setAttribute("aria-hidden", "true");

            const defs = document.createElementNS(SVG_NS, "defs");
            svg.append(defs);

            const animate = !window.matchMedia(REDUCED_MOTION).matches;

            pairs.forEach(([from, to], i) => {
              const start = exit(from);
              const end = entry(to);

              // Each traveller's OWN colour, read straight off the seat
              // element `board_card/1` already set it on (`identity_colors/1`
              // assigned it server-side) - so the arrow always matches the
              // name/highlight it belongs to, with no colour list of our
              // own to keep in sync. `from` and `to` are the same person by
              // construction (matchTravellers/1 paired them by name), so
              // either would do; `from` is just as good as `to`.
              const color = getComputedStyle(from).getPropertyValue("--swap-color").trim();
              const markerId = `swap-arrow-head-${i}`;
              defs.append(this.arrowHeadDef(markerId, color));

              // A straight stub at each end: the curve is done bending
              // before the arrowhead, so the head sits on a level run
              // instead of still turning as it lands. Same at the dot.
              const tip = end.x - HEAD_GAP;
              const stub = Math.min(STUB, Math.max(0, (tip - start.x) / 4));
              const from_x = start.x + stub;
              const to_x = tip - stub;

              // Symmetric control points - `+k` out of the start, `−k`
              // into the end. Both curves of a swap then pass through the
              // exact centre of the channel at their own half-way point,
              // so they cross dead centre. (Giving each curve a single
              // shared control x instead - one "lane" per arrow - is what
              // made the crossing drift below the middle.)
              const k = Math.max((to_x - from_x) / 2, 14);

              const path = document.createElementNS(SVG_NS, "path");
              path.setAttribute("class", "swap-arrow-path");
              path.setAttribute(
                "d",
                `M ${start.x} ${start.y} L ${from_x} ${start.y}` +
                  ` C ${from_x + k} ${start.y}, ${to_x - k} ${end.y}, ${to_x} ${end.y}` +
                  ` L ${tip} ${end.y}`
              );
              path.setAttribute("marker-end", `url(#${markerId})`);
              if (color) path.style.stroke = color;

              const dot = document.createElementNS(SVG_NS, "circle");
              dot.setAttribute("class", "swap-arrow-dot");
              dot.setAttribute("cx", start.x);
              dot.setAttribute("cy", start.y);
              dot.setAttribute("r", 3);
              if (color) dot.style.fill = color;

              svg.append(path, dot);

              if (animate) {
                const length = path.getTotalLength();
                path.style.strokeDasharray = length;
                path.style.strokeDashoffset = length;
                // Read back a layout value so the browser commits the
                // pre-animation state instead of collapsing both writes.
                void path.getBoundingClientRect();
                path.style.transition = "stroke-dashoffset .45s ease-out";
                path.style.strokeDashoffset = "0";
              }
            });

            layer.append(svg);
          },

          // One `<marker>` per arrow, not one shared by all of them - an
          // SVG marker has exactly one fill, so two differently-coloured
          // arrowheads need two markers. `id` just needs to be unique
          // within this one SVG.
          arrowHeadDef(id, color) {
            const marker = document.createElementNS(SVG_NS, "marker");
            marker.setAttribute("id", id);
            marker.setAttribute("viewBox", "0 0 8 8");
            marker.setAttribute("refX", "7");
            marker.setAttribute("refY", "4");
            marker.setAttribute("markerWidth", "5");
            marker.setAttribute("markerHeight", "5");
            marker.setAttribute("orient", "auto");

            const head = document.createElementNS(SVG_NS, "path");
            head.setAttribute("class", "swap-arrow-head");
            head.setAttribute("d", "M 0 0 L 8 4 L 0 8 z");
            if (color) head.style.fill = color;

            marker.append(head);
            return marker;
          }
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".PairingMenu">
        // Opens the hand-editing menu where the pointer is. There's no
        // native phx-contextmenu binding, so this half needs JS; the
        // left-click half (completing an armed swap) is a plain phx-click
        // in the markup. One delegated listener per panel rather than one
        // per name.
        //
        // A right-click NEVER completes anything - it only ever opens the
        // menu. Every write is behind a menu item plus the confirm modal,
        // so no two-right-clicks-in-a-row can change a pairing by accident.
        //
        // The keyboard (R2 of docs/accessibility-2026-09-13.md): every seat
        // with something to act on is a `[data-seat]` button. The
        // context-menu key and Shift+F10 open the menu through the same
        // `contextmenu` event, placed under the seat instead of at a pointer;
        // Enter or Space opens it too - except on a seat the server marked
        // `data-armed` (a swap or a pool pairing is waiting for its second
        // player), where Enter or Space is the left-click that completes it, sent as
        // that very click so both paths push the same event. Either way the
        // payload is the one a right-click sends, plus `keyboard: true` so
        // the menu takes focus.

        // What a keydown on a seat asks for: "menu-key" (a contextmenu event
        // follows), "complete", "menu" (Enter: open it now), "menu-keyup"
        // (Space: open it when the key comes back up), or null. Pure, so it
        // can be checked on its own.
        //
        // Space waits for its keyup, as it does on the Players grid: the menu
        // takes focus on its first item as soon as the server has drawn it,
        // which on a local copy is well inside one key press, and the keyup
        // then landed on that item - in a browser that activates a button on
        // Space's keyup, choosing "Swap with..." or "Hide this board" unasked.
        export const seatKeyAction = (e, armed) => {
          if (e.key === "ContextMenu" || (e.shiftKey && e.key === "F10")) return "menu-key";
          if (e.altKey || e.ctrlKey || e.metaKey || e.shiftKey) return null;
          if (e.key !== "Enter" && e.key !== " ") return null;
          if (armed) return "complete";
          return e.key === " " ? "menu-keyup" : "menu";
        };

        // Where a menu opens: at the pointer, or under the seat from the
        // keyboard, kept on screen either way (it's ~280x150).
        export const menuPosition = (x, y, width, height) => ({
          x: Math.max(8, Math.min(x, width - 300)),
          y: Math.max(8, Math.min(y, height - 170))
        });

        export default {
          mounted() {
            this.keyMenuAt = 0;

            this.openMenu = (target, x, y, keyboard) => {
              const at = menuPosition(x, y, window.innerWidth, window.innerHeight);
              this.pushEvent("open_menu", {
                x: at.x,
                y: at.y,
                scope: target.dataset.scope,
                "player-id": target.dataset.playerId || null,
                "pairing-id": target.dataset.pairingId || null,
                keyboard
              });
            };

            this.onContextMenu = (e) => {
              const target = e.target.closest("[data-scope]");
              if (!target) return;
              e.preventDefault();

              const keyboard =
                Date.now() - this.keyMenuAt < 1000 ||
                e.pointerType === "" ||
                (e.clientX === 0 && e.clientY === 0);
              this.keyMenuAt = 0;

              if (keyboard) {
                const box = (e.target.closest("[data-seat], select, button") || target).getBoundingClientRect();
                this.openMenu(target, box.left, box.bottom, true);
              } else {
                this.openMenu(target, e.clientX, e.clientY, false);
              }
            };

            this.onKeydown = (e) => {
              const seat = e.target.closest("[data-seat]");
              if (!seat) return;

              const action = seatKeyAction(e, seat.hasAttribute("data-armed"));
              if (action === "menu-key") { this.keyMenuAt = Date.now(); return; }
              if (!action) return;
              e.preventDefault();

              if (action === "complete") {
                seat.click();
              } else if (action === "menu-keyup") {
                this.spaceOn = seat;
              } else {
                this.openFromKeys(seat);
              }
            };

            this.onKeyup = (e) => {
              if (e.key !== " " || !this.spaceOn) return;
              const seat = this.spaceOn;
              this.spaceOn = null;
              if (e.target.closest("[data-seat]") === seat) this.openFromKeys(seat);
            };

            this.openFromKeys = (seat) => {
              const box = seat.getBoundingClientRect();
              this.openMenu(seat.closest("[data-scope]"), box.left, box.bottom, true);
            };

            this.el.addEventListener("contextmenu", this.onContextMenu);
            this.el.addEventListener("keydown", this.onKeydown);
            this.el.addEventListener("keyup", this.onKeyup);

            // After an applied hand edit the confirmation closes and
            // `DialogFocus` puts focus back where the edit started - a frame
            // later. Two frames later still, focus moves onto the edited
            // board if it is not on it already: the seat it was on, when that
            // seat is on the board, else the board's first seat or result.
            // Only the table's copy of this hook listens; the pool's has no
            // boards.
            if (this.el.tagName === "TABLE") {
              this.handleEvent("hand_edit_applied", ({pairing_id}) => {
                if (!pairing_id) return;
                requestAnimationFrame(() => requestAnimationFrame(() => {
                  const row = document.getElementById(`pairing-row-${pairing_id}`);
                  if (!row || row.contains(document.activeElement)) return;
                  const target = row.querySelector("[data-seat], select, button");
                  if (target) target.focus();
                }));
              });
            }
          },

          destroyed() {
            this.el.removeEventListener("contextmenu", this.onContextMenu);
            this.el.removeEventListener("keydown", this.onKeydown);
            this.el.removeEventListener("keyup", this.onKeyup);
          }
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".HandEditMenu">
        // The hand-edit menu itself, rendered by the server. Opened from the
        // keyboard (`data-keyboard`) it takes focus on its first item; Up,
        // Down, Home and End walk the items; Tab closes it the way Escape
        // does (Escape is the backdrop's `phx-window-keydown`). However it
        // closes - an item chosen, Escape, a click away - focus goes back to
        // the seat that opened it, by id when a patch has replaced that seat,
        // unless something else (a confirmation dialog) has already taken it.

        // The item Up/Down/Home/End moves to, from `index` among `count`
        // (-1 when focus is not on an item yet). Pure.
        export const menuStep = (key, index, count) => {
          if (!count) return null;
          switch (key) {
            case "ArrowDown": return (index + 1 + count) % count;
            case "ArrowUp": return index < 0 ? count - 1 : (index - 1 + count) % count;
            case "Home": return 0;
            case "End": return count - 1;
            default: return null;
          }
        };

        export default {
          mounted() {
            const at = document.activeElement;
            this.opener = at && at !== document.body && !this.el.contains(at) ? at : null;
            this.openerId = this.opener && this.opener.id;

            this.items = () =>
              Array.from(this.el.querySelectorAll("button:not([disabled])"));

            this.onKeydown = (e) => {
              const items = this.items();
              if (e.key === "Tab") {
                e.preventDefault();
                this.pushEvent("close_menu", {});
                return;
              }
              const next = menuStep(e.key, items.indexOf(document.activeElement), items.length);
              if (next === null) return;
              e.preventDefault();
              items[next].focus();
            };
            this.el.addEventListener("keydown", this.onKeydown);

            if (this.el.hasAttribute("data-keyboard")) {
              const first = this.items()[0];
              if (first) first.focus();
            }
          },

          destroyed() {
            const at = document.activeElement;
            if (at && at !== document.body && at.isConnected) return;

            const back =
              (this.opener && this.opener.isConnected && this.opener) ||
              (this.openerId && document.getElementById(this.openerId));
            if (back) back.focus({preventScroll: true});
          }
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".RoundMenu">
        // A <details> menu that closes like a menu: on a click outside it,
        // on Escape (focus back to its button), and once an item is chosen.
        export default {
          mounted() {
            this.close = (refocus) => {
              if (!this.el.open) return;
              this.el.open = false;
              if (refocus) this.el.querySelector("summary").focus();
            };
            this.onDocMousedown = (e) => {
              if (!this.el.contains(e.target)) this.close(false);
            };
            this.onKeydown = (e) => {
              if (e.key === "Escape") this.close(true);
            };
            this.onClick = (e) => {
              if (e.target.closest("[role=menuitem]")) this.close(false);
            };
            document.addEventListener("mousedown", this.onDocMousedown);
            this.el.addEventListener("keydown", this.onKeydown);
            this.el.addEventListener("click", this.onClick);
          },
          destroyed() {
            document.removeEventListener("mousedown", this.onDocMousedown);
          }
        }
      </script>
    </Layouts.app>
    """
  end
end
