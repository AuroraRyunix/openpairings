defmodule PairingsEngineWeb.PairingsLive do
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport, only: [setup_field_path: 2]

  alias PairingsEngine.{
    Audit,
    PairingDisplay,
    PairingRationale,
    ResultsImport,
    RoundRobin,
    Standings,
    Tournaments
  }

  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.Tournament

  @results [
    {"", "…"},
    {"1-0", "1-0"},
    {"1/2-1/2", "½-½"},
    {"0-1", "0-1"},
    {"1/2-0", "½-0 (asymmetric — disciplinary point adjustment)"},
    {"0-1/2", "0-½ (asymmetric — disciplinary point adjustment)"},
    {"1-0FF", "1-0 FF (White wins by forfeit)"},
    {"0-1FF", "0-1 FF (Black wins by forfeit)"},
    {"0-0FF", "0-0 FF (double forfeit)"},
    {"0-0", "0-0 (both lose, game played)"}
  ]

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
       importing_results: false,
       import_errors: nil,
       # The pairing (if any) awaiting explicit confirmation to have its
       # result CLEARED — see `handle_event("result", ...)`'s guard below.
       confirm_clear_pairing_id: nil,
       # Hand-editing state — see "Editing a paired round by hand" below.
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
  # draft state to protect), so a broadcast can just reload everything —
  # including the tournament itself, since rounds_count/status can change
  # from the Settings page.
  #
  # This LiveView is subscribed to its own tournament's topic, so every
  # mutation it causes itself (pair/unpair/result/import) broadcasts right
  # back to this same process too — by the time that echo arrives, the
  # triggering `handle_event` has already called `refresh/1` synchronously,
  # so this just re-does the same (cheap) reload a second time. A visible
  # "updated by another arbiter" notice used to fire here too; removed —
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
        # entered a totally unrelated result elsewhere in the round — and
        # got silently bounced out, as if they'd hit Escape themselves.
        # `keep_gesture: true` here is the fix: a REMOTE broadcast leaves
        # any half-finished menu/swap/confirm gesture alone (the round data
        # underneath it still refreshes fully either way, so whatever gets
        # applied is checked against the current state regardless — see
        # each `Tournaments.*` write function's own guards). Only the
        # arbiter's OWN completed action (every other `refresh()` call
        # site, still defaulting to reset) clears it — that's the point
        # where the gesture is genuinely done, not a bystander update.
        {:noreply, socket |> assign(tournament: tournament) |> refresh(keep_gesture: true)}
    end
  end

  defp refresh(socket, opts \\ []) do
    %{tournament: t, round_number: n} = socket.assigns
    paired = Engine.paired_rounds_count(t.id)
    missing_setup = Tournament.missing_setup_fields(t)
    setup_complete = missing_setup == []

    socket =
      assign(socket,
        round: Tournaments.get_round(t.id, n),
        # Each player's score coming INTO round `n` — shown next to their
        # name on the board list, same as a real printed pairing sheet.
        scores: Standings.player_scores_before_round(t, n),
        # The pool is a superset of `list_byes_for_round/2` — it adds anyone
        # simply unpaired — so the byes-only query this page used to run is
        # no longer needed here. Other views still use it.
        round_pool: Tournaments.list_round_pool(t.id, n),
        paired_rounds: paired,
        next_pairable: paired + 1,
        setup_complete: setup_complete,
        missing_setup: missing_setup,
        recommended_missing: Tournament.missing_recommended_fields(t),
        can_pair:
          setup_complete and paired < t.rounds_count and Engine.round_complete?(t.id, paired)
      )

    if Keyword.get(opts, :keep_gesture, false) do
      socket
    else
      # Whatever a half-finished gesture was pointing at may no longer be
      # current by the time OUR OWN action just completed here (a round
      # switch, or the change's own confirmed write) — safer to drop back
      # to "nothing selected" than to leave a just-consumed gesture
      # sitting around.
      assign(socket, menu: nil, swap_first: nil, pool_first: nil, seat_pick: nil, confirm: nil)
    end
  end

  @impl true
  def handle_event("select_round", %{"number" => number}, socket) do
    {:noreply, socket |> assign(round_number: String.to_integer(number), error: nil) |> refresh()}
  end

  def handle_event("pair", _params, socket) do
    if not Tournament.setup_complete?(socket.assigns.tournament) do
      {:noreply,
       put_flash(
         socket,
         :error,
         "Finish the tournament setup before pairing — missing: " <>
           missing_setup_summary(socket.assigns.missing_setup)
       )}
    else
      do_pair(socket)
    end
  end

  def handle_event("unpair", _params, socket) do
    %{tournament: t, round_number: round_number} = socket.assigns

    case Engine.delete_round(t.id, round_number) do
      :ok ->
        Audit.log(t.id, socket.assigns.current_scope, "pairing.round_deleted", %{
          round: round_number
        })

        {:noreply, socket |> assign(error: nil) |> refresh()}

      {:error, reason} ->
        {:noreply, assign(socket, error: reason)}
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
  #                            never completes a swap — it only ever opens
  #                            the menu, so the destructive half of the
  #                            gesture is always a deliberate second action.
  #   "Mark absent"         -> empties that seat (see the vacancy model in
  #                            `Tournaments.vacate_seat/3`)
  #
  # Everything that writes goes through `@confirm` first — one modal, one
  # shape, whatever the action (see `confirm_for/2` and `apply_confirm/2`).

  def handle_event("open_menu", params, socket) do
    %{"x" => x, "y" => y} = params

    menu = %{
      x: x,
      y: y,
      player_id: int_or_nil(params["player-id"]),
      pairing_id: int_or_nil(params["pairing-id"]),
      seat: params["seat"],
      scope: params["scope"] || "seated"
    }

    {:noreply, assign(socket, menu: menu)}
  end

  def handle_event("close_menu", _params, socket), do: {:noreply, assign(socket, menu: nil)}

  def handle_event("arm_swap", %{"player-id" => id}, socket) do
    player_id = String.to_integer(id)

    {:noreply,
     assign(socket,
       menu: nil,
       confirm: nil,
       swap_first: %{id: player_id, name: display_name(socket, player_id)}
     )}
  end

  def handle_event("cancel_swap", _params, socket) do
    {:noreply, assign(socket, swap_first: nil, confirm: nil, menu: nil)}
  end

  # The second half of a swap: a plain LEFT-click, on either a seated
  # player or someone in the round's pool.
  def handle_event("pick_swap_target", %{"player-id" => id}, socket) do
    target_id = String.to_integer(id)

    case socket.assigns.swap_first do
      nil -> {:noreply, socket}
      %{id: ^target_id} -> {:noreply, socket}
      first -> {:noreply, stage(socket, {:swap, first.id, target_id})}
    end
  end

  def handle_event("stage_vacate", %{"player-id" => id}, socket) do
    {:noreply, stage(socket, {:vacate, String.to_integer(id)})}
  end

  def handle_event("stage_bye", %{"pairing-id" => id}, socket) do
    {:noreply, stage(socket, {:bye, String.to_integer(id)})}
  end

  def handle_event("stage_fill", %{"pairing-id" => pid, "player-id" => plid}, socket) do
    {:noreply, stage(socket, {:fill, String.to_integer(pid), String.to_integer(plid)})}
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
        {:noreply, assign(socket, menu: nil, seat_pick: player_id)}
    end
  end

  def handle_event("cancel_seat_pick", _params, socket),
    do: {:noreply, assign(socket, seat_pick: nil)}

  def handle_event("stage_pool_pair", %{"player-id" => id}, socket) do
    player_id = String.to_integer(id)

    case socket.assigns.pool_first do
      %{id: first_id} when first_id != player_id ->
        {:noreply, stage(socket, {:pool_pair, first_id, player_id})}

      _ ->
        {:noreply,
         assign(socket,
           menu: nil,
           pool_first: %{id: player_id, name: display_name(socket, player_id)}
         )}
    end
  end

  def handle_event("cancel_pool_pair", _params, socket),
    do: {:noreply, assign(socket, pool_first: nil, menu: nil)}

  def handle_event("set_confirm_board", %{"board" => board}, socket) do
    case Integer.parse(String.trim(board)) do
      {n, ""} when n > 0 ->
        {:noreply, assign(socket, confirm: Map.put(socket.assigns.confirm, :board, n))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_confirm", _params, socket),
    do: {:noreply, assign(socket, confirm: nil)}

  # The "I understand — apply this to round N anyway" checkbox on a
  # frozen-round confirm (see `frozen_round?/1`) — the primary button
  # stays disabled until this is ticked.
  def handle_event("toggle_frozen_ack", _params, socket) do
    case socket.assigns.confirm do
      nil -> {:noreply, socket}
      confirm -> {:noreply, assign(socket, confirm: Map.update!(confirm, :frozen_ack, &(!&1)))}
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
        # result on file is NEVER committed straight away — only staged,
        # pending an explicit confirm click (see "confirm_clear_result"
        # below). A genuine "select the blank option to reset this board"
        # click from an arbiter still works, just one extra click.
        #
        # This exists because of a real incident: a burst of ~11
        # simultaneous "result" events fired for every board in a round at
        # once (almost certainly triggered by a LiveView reconnect after a
        # dropped socket — this page had been reconnecting every 1-2
        # minutes over a flaky mobile connection), and 4 of them carried a
        # blank value, silently wiping 4 already-recorded results. Nothing
        # about a single incoming event distinguishes "an arbiter meant to
        # clear this" from "a stray reconnect-triggered submission" — the
        # payload looks identical either way — so this guard doesn't try
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

          _ ->
            :ok
        end

        {:noreply, socket |> assign(confirm_clear_pairing_id: nil) |> refresh()}
    end
  end

  # The explicit second click confirming a blank-result overwrite staged by
  # the guard above. Re-fetches the pairing fresh rather than trusting
  # anything already in `socket.assigns` — the confirmation could be
  # sitting on screen for a while, and this is exactly the code path a
  # stale/incorrect write must never happen through.
  def handle_event("confirm_clear_result", %{"pairing-id" => id}, socket) do
    %{tournament: t, round_number: round_number} = socket.assigns

    case Enum.find(socket.assigns.round.pairings, &(&1.id == String.to_integer(id))) do
      nil ->
        :ok

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

          _ ->
            :ok
        end
    end

    {:noreply, socket |> assign(confirm_clear_pairing_id: nil) |> refresh()}
  end

  # Backs out of a staged clear without writing anything — the select
  # reverts to its real (unchanged) value on the next render, since the DB
  # was never touched.
  def handle_event("cancel_clear_result", _params, socket) do
    {:noreply, assign(socket, confirm_clear_pairing_id: nil)}
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

  defp int_or_nil(nil), do: nil
  defp int_or_nil(""), do: nil
  defp int_or_nil(value) when is_integer(value), do: value
  defp int_or_nil(value), do: String.to_integer(value)

  # Builds the confirm state for an action and closes every transient bit
  # of UI around it, so the modal is always the only thing on screen
  # asking for a decision.
  defp stage(socket, action) do
    case confirm_for(socket, action) do
      {:ok, confirm} ->
        frozen? = frozen_round?(socket)
        confirm = Map.merge(confirm, %{frozen: frozen?, frozen_ack: !frozen?})
        assign(socket, confirm: confirm, menu: nil, seat_pick: nil)

      {:error, _reason} ->
        assign(socket, menu: nil, seat_pick: nil)
    end
  end

  # A round that isn't the tournament's current latest PAIRED round —
  # every `confirm_for/2` action (swap, mark absent, pool-pair, fill a
  # seat, award a bye — everything that alters who's paired with whom)
  # runs through `stage/2`, so gating it here covers all of them
  # uniformly. Entering/editing a RESULT is untouched — only pairing
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
  # `after` are `{white_name, black_name}` — the modal draws those as two
  # board cards side by side and highlights whichever seat differs, which
  # is why they stay as a tuple rather than a pre-joined string.

  defp confirm_for(socket, {:swap, a_id, b_id}) do
    round = socket.assigns.round
    pool = socket.assigns.round_pool

    cond do
      # Both seated — a straight seat trade, possibly a colour-only swap.
      seated?(round, a_id) and seated?(round, b_id) ->
        with {:ok, {pa, fa}} <- locate_seat(round.pairings, a_id),
             {:ok, {pb, fb}} <- locate_seat(round.pairings, b_id) do
          a = display_name(socket, a_id)
          b = display_name(socket, b_id)
          same? = pa.id == pb.id

          changes =
            if same?,
              do: [board_change(pa, [{fa, b}, {fb, a}])],
              else: [
                board_change(pa, [{fa, b}], pb.board),
                board_change(pb, [{fb, a}], pa.board)
              ]

          {:ok,
           %{
             kind: :swap,
             a_id: a_id,
             b_id: b_id,
             title: if(same?, do: "Swap colours", else: "Swap players"),
             subtitle: "#{a}  ⇄  #{b}",
             changes: changes,
             note: nil
           }}
        end

      # One seated, one in the pool — a substitution.
      seated?(round, a_id) or seated?(round, b_id) ->
        {seated_id, pool_id} = if seated?(round, a_id), do: {a_id, b_id}, else: {b_id, a_id}

        if pool_member?(pool, pool_id) do
          {:ok, {pairing, field}} = locate_seat(round.pairings, seated_id)
          seated_name = display_name(socket, seated_id)
          pool_name = display_name(socket, pool_id)

          {:ok,
           %{
             kind: :swap_pool,
             seated_id: seated_id,
             pool_id: pool_id,
             title: "Substitute player",
             subtitle: "#{pool_name} takes #{seated_name}'s place",
             changes: [board_change(pairing, [{field, pool_name}])],
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
             "The empty seat can be filled from the not-playing list, or turned into a bye — " <>
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

  defp confirm_for(socket, {:pool_pair, a_id, b_id}) do
    a = display_name(socket, a_id)
    b = display_name(socket, b_id)
    board = Tournaments.next_free_board(socket.assigns.round)

    {:ok,
     %{
       kind: :pool_pair,
       a_id: a_id,
       b_id: b_id,
       board: board,
       title: "Pair these two",
       subtitle: "#{a}  vs  #{b}",
       changes: [%{board: board, before: {"", ""}, after: {a, b}}],
       note: "Neither will be marked absent for this round any more."
     }}
  end

  defp apply_confirm(socket, nil), do: {:noreply, socket}

  # Belt-and-braces: the modal's primary button is already `disabled` in
  # this state (see the template), but a disabled button is a client-side
  # courtesy, not a guarantee — refuse server-side too rather than trust
  # it.
  defp apply_confirm(socket, %{frozen: true, frozen_ack: false}), do: {:noreply, socket}

  defp apply_confirm(socket, confirm) do
    %{tournament: t, round: round} = socket.assigns

    result =
      case confirm do
        %{kind: :swap, a_id: a, b_id: b} ->
          Tournaments.swap_players_in_round(round, a, b)

        %{kind: :swap_pool, seated_id: s, pool_id: p} ->
          Tournaments.swap_seated_with_pool_player(round, s, p)

        %{kind: :vacate, player_id: p} ->
          Tournaments.vacate_seat(round, p)

        %{kind: :bye, pairing_id: id} ->
          with {:ok, pairing} <- fetch_pairing(round, id),
               do: Tournaments.award_bye_for_vacancy(round, pairing)

        %{kind: :fill, pairing_id: id, player_id: p} ->
          with {:ok, pairing} <- fetch_pairing(round, id),
               do: Tournaments.fill_seat(round, pairing, p)

        %{kind: :pool_pair, a_id: a, b_id: b, board: board} ->
          Tournaments.pair_from_pool(round, a, b, board)
      end

    case result do
      {:ok, _} ->
        Audit.log(t.id, socket.assigns.current_scope, audit_action(confirm.kind), %{
          round: socket.assigns.round_number,
          summary: confirm.subtitle
        })

        {:noreply, socket |> assign(error: nil) |> refresh()}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           error: "Could not apply that change: #{inspect(reason)}",
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
      " They stay marked absent for the whole event — clear that on the Players page if they " <>
        "are back for good, or the next round will leave them out again."
    else
      ""
    end
  end

  defp fetch_pairing(nil, _id), do: {:error, :not_in_round}

  defp fetch_pairing(round, id) do
    case Enum.find(round.pairings, &(&1.id == id)) do
      nil -> {:error, :not_in_round}
      pairing -> {:ok, pairing}
    end
  end

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

  # `player_label/1` by id, across both the boards and the pool — a click
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
  # `related_board`, when given, is the OTHER board involved in a
  # two-board swap — see `board_card/1`'s `related_board` attr.
  defp board_change(pairing, substitutions, related_board \\ nil) do
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
      result_will_clear?: pairing.result not in ["", "bye"],
      related_board: related_board
    }
  end

  defp other_seat_name(pairing, :white_player_id), do: player_label(pairing.black_player)
  defp other_seat_name(pairing, :black_player_id), do: player_label(pairing.white_player)

  defp blank_dash(""), do: "the empty seat"
  defp blank_dash(name), do: name

  defp do_pair(socket) do
    if socket.assigns.tournament.pairing_system == "round_robin" do
      do_pair_all_rounds(socket)
    else
      case Engine.pair_next_round(socket.assigns.tournament) do
        {:ok, round} ->
          log_round_paired(socket, round.number)
          {:noreply, socket |> assign(round_number: round.number, error: nil) |> refresh()}

        {:error, %Ecto.Changeset{}} ->
          {:noreply, assign(socket, error: "Could not save the round")}

        {:error, reason} ->
          {:noreply, assign(socket, error: to_string(reason))}
      end
    end
  end

  # Round-robin pairs its whole Berger schedule in one click instead of one
  # round at a time (see RoundRobin.pair_all_rounds/1's doc — there's
  # nothing to wait on between rounds the way Swiss waits on results) —
  # every round it generates still gets its own "pairing.round_paired"
  # audit entry, same depth of trail one-round-at-a-time pairing would
  # have produced.
  defp do_pair_all_rounds(socket) do
    tournament = socket.assigns.tournament
    already_paired = Engine.paired_rounds_count(tournament.id)

    case RoundRobin.pair_all_rounds(tournament) do
      {:ok, last_round_number} ->
        for round_number <- (already_paired + 1)..last_round_number do
          log_round_paired(socket, round_number)
        end

        # RoundRobin.pair_all_rounds/1 may have corrected rounds_count
        # (see ensure_correct_rounds_count/2) — reload straight away so
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
        {:noreply, assign(socket, error: to_string(reason))}
    end
  end

  # Logs the rich "pairing.round_paired" audit entry, reusing the exact same
  # PairingRationale analysis the "Explain this round" page renders live — so
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

  defp results, do: @results

  # Plain-text summary of `Tournament.missing_setup_fields/1`'s messages, for
  # the flash/tooltip shown when pairing is blocked — the on-page banner (see
  # render/1) additionally links each item to the Settings (sub-)page it
  # lives on.
  defp missing_setup_summary(missing) do
    Enum.map_join(missing, "; ", fn {_field, message} -> message end)
  end

  # Long JaVaFo failures come through as multi-line output — show a short
  # first-line preview as the collapsed summary, never a truncated message
  # (the full text is always available by expanding the block).
  defp error_summary(text) do
    text |> String.split("\n", parts: 2) |> hd()
  end

  # The pairing engine actually used, for button/notice copy — only Swiss runs
  # JaVaFo, so the label must not claim it for round-robin (Berger schedule) or
  # Keizer.
  defp pairing_engine_label(%{pairing_system: "round_robin"}), do: "Berger"
  defp pairing_engine_label(%{pairing_system: "keizer"}), do: "Keizer"
  defp pairing_engine_label(_swiss), do: "JaVaFo"

  defp pairing_engine_description(%{pairing_system: "round_robin"}),
    do: "round-robin schedule (Berger tables)"

  defp pairing_engine_description(%{pairing_system: "keizer"}), do: "Keizer ladder pairing"
  defp pairing_engine_description(_swiss), do: "FIDE Dutch pairing (JaVaFo)"

  # Bare display name for an audit-log payload (nil = a bye's empty side).
  defp player_name(nil), do: nil
  defp player_name(player), do: player.name

  defp player_label(nil), do: ""

  defp player_label(player) do
    rating = PairingsEngine.Tournaments.Player.rating(player)

    "#{if player.title != "", do: "#{player.title} "}#{player.name}" <>
      if(rating > 0, do: " (#{rating})", else: "")
  end

  # Board-list label only: `player_label/1` plus the player's score coming
  # into this round, in the same parenthetical — "Name (2400, 2.5)", or
  # "Name (2.5)" with no rating. Deliberately separate from
  # `player_label/1` itself, which every OTHER player-name spot on this
  # page (swap dialogs, the not-playing pool, audit text) keeps using
  # unchanged — the incoming score is specifically a pairing-SHEET thing.
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
  # a pulled-out fixed-table board leaves) — see its moduledoc. Presentation
  # only: `pairing.board` itself, used everywhere else in this file
  # (audit log entries, swap-menu subtitles), is untouched.
  defp display_rows(pairings), do: PairingDisplay.with_display_boards(pairings)

  # Label for a byes-table row's `type` — distinct from the "bye" badge
  # shown for a pairing-allocated bye (a real Pairing row), since these
  # never appear in round.pairings (see Tournaments.list_byes_for_round/2).
  defp bye_type_label("requested-half"), do: "requested half-point bye"
  defp bye_type_label("requested-zero"), do: "requested zero-point bye"
  defp bye_type_label("absent"), do: "absent"
  defp bye_type_label(other), do: other

  # Cosmetic-only: under `rr_match_format`/`swiss_match_format`, round
  # 2k-1/2k are legs 1/2 of the same "match" (Pairing.max_pairable_round/1,
  # RoundRobin.do_pair/3 — leg 2 is always a colour-reversed mirror of leg
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

  ## ---------- Hand-editing UI pieces ----------

  # One board drawn as a card: White over Black, the way the pairing sheet
  # reads. `compare` (the other side of the diff) is what makes a changed
  # seat light up, so the arbiter can see WHICH name moved rather than
  # having to read two strings and spot the difference themselves.
  attr :seats, :any, required: true
  attr :state, :string, required: true
  attr :compare, :any, default: nil
  # The OTHER board a changed seat's new occupant is trading places with,
  # for a genuine two-board swap — see `confirm_for/2`'s `:swap` clause
  # and `board_change/3`. `nil` for every other confirm kind (nothing to
  # cross-reference: a colour swap, an absence, a bye, a pool fill are
  # all single-board).
  attr :related_board, :any, default: nil

  defp board_card(assigns) do
    {white, black} = assigns.seats
    {was_white, was_black} = assigns.compare || assigns.seats

    assigns =
      assign(assigns,
        white: white,
        black: black,
        white_changed?: white != was_white,
        black_changed?: black != was_black,
        # Only the "after" card highlights a differing seat — that's the
        # one the arbiter is being asked to approve. The "before" card
        # marks the same seats with an unstyled class purely so the
        # `.SwapArrows` hook can find where each traveller starts; it
        # deliberately carries no visual weight of its own.
        changed_class:
          if(assigns.state == "after", do: "board-seat-changed", else: "board-seat-moving")
      )

    ~H"""
    <div class={["board-card", "board-card-#{@state}"]}>
      <div class={["board-seat", @white_changed? && @changed_class]}>
        <span class="board-seat-colour" aria-label="White">W</span>
        <span class="board-seat-name">{seat_text(@white)}</span>
        <span
          :if={@state == "after" and @white_changed? and @related_board}
          class="board-seat-swap-ref"
        >
          ⇄ Board {@related_board}
        </span>
      </div>

      <div class={["board-seat", @black_changed? && @changed_class]}>
        <span class="board-seat-colour board-seat-black" aria-label="Black">B</span>
        <span class="board-seat-name">{seat_text(@black)}</span>
        <span
          :if={@state == "after" and @black_changed? and @related_board}
          class="board-seat-swap-ref"
        >
          ⇄ Board {@related_board}
        </span>
      </div>
    </div>
    """
  end

  defp seat_text(""), do: "— empty —"
  defp seat_text(name), do: name

  # A left-click in the pool means "complete the armed gesture" — which
  # gesture depends on which one is armed. With a swap armed it's the swap
  # target; otherwise it's the second half of a pool pairing.
  defp pool_click(nil), do: "stage_pool_pair"
  defp pool_click(_swap_first), do: "pick_swap_target"

  # What the pool chip says about WHY someone isn't playing, and what it
  # scores. The tournament-wide `absent` flag is reported ahead of the
  # per-round byes row because it is the reason they are not in the
  # pairing at all — and, being the flag an arbiter most often reverses
  # on the day, the one they need to recognise at a glance.
  defp pool_tag(%{absent?: true}, _tournament), do: "absent (whole event)"

  defp pool_tag(%{type: nil}, _tournament), do: "unpaired"

  defp pool_tag(%{type: type} = entry, tournament) do
    points = PairingsEngine.Standings.bye_points_for_row(entry, tournament)
    "#{bye_type_label(type)} · #{points} pt"
  end

  # One seat in the pairings table. Three states: an ordinary player
  # (right-click for the menu, left-click to complete an armed swap), a
  # bye's empty black side (nothing to act on — the Result column already
  # says "bye"), and a VACANCY, which is the one that asks to be filled.
  attr :player, :any, required: true
  attr :pairing, :map, required: true
  attr :side, :atom, required: true
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
          data-player-id={@player.id}
          data-scope="seated"
          phx-click="pick_swap_target"
          phx-value-player-id={@player.id}
          title="Right-click for swap / absent options"
        >
          {seat_label(@player, @scores)}
        </span>
      <% @pairing.result == "bye" -> %>
        <span class="seat-none">—</span>
      <% @seat_pick -> %>
        <button
          type="button"
          class="seat-vacant seat-vacant-armed"
          phx-click="stage_fill"
          phx-value-pairing-id={@pairing.id}
          phx-value-player-id={@seat_pick}
        >
          Put them here
        </button>
      <% true -> %>
        <span
          class="seat-vacant"
          data-pairing-id={@pairing.id}
          data-scope="vacant"
          title="Empty seat — right-click to award a bye, or pick a replacement from the not-playing list below"
        >
          — empty —
        </span>
    <% end %>
    """
  end

  # The right-click menu. Fixed-positioned at the click point, so it opens
  # where the pointer is instead of at the top of the page.
  attr :menu, :map, required: true
  attr :round, :any, required: true

  defp pairing_menu(assigns) do
    assigns = assign(assigns, vacancies: length(vacant_pairings(assigns.round)))

    ~H"""
    <div class="ctx-backdrop" phx-click="close_menu" phx-window-keydown="close_menu" phx-key="escape">
      <div
        class="ctx-menu"
        style={"left: #{@menu.x}px; top: #{@menu.y}px"}
        phx-click-away="close_menu"
      >
        <%= case @menu.scope do %>
          <% "seated" -> %>
            <button type="button" phx-click="arm_swap" phx-value-player-id={@menu.player_id}>
              Swap with…
            </button>

            <button type="button" phx-click="stage_vacate" phx-value-player-id={@menu.player_id}>
              Mark absent for this round
            </button>
          <% "pool" -> %>
            <button type="button" phx-click="arm_swap" phx-value-player-id={@menu.player_id}>
              Swap with a player on a board…
            </button>

            <button
              :if={@vacancies > 0}
              type="button"
              phx-click="offer_seats"
              phx-value-player-id={@menu.player_id}
            >
              Put in an empty seat{if @vacancies > 1, do: "…", else: ""}
            </button>

            <button type="button" phx-click="stage_pool_pair" phx-value-player-id={@menu.player_id}>
              Pair with another player who isn't playing…
            </button>
          <% "vacant" -> %>
            <button type="button" phx-click="stage_bye" phx-value-pairing-id={@menu.pairing_id}>
              Award a bye to the remaining player
            </button>
        <% end %>
      </div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      tournament={@tournament}
      active="pairings"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>

          <p class="subtitle" style="margin: 0">Pairings &amp; results</p>
        </div>

        <div class="actions" style="margin: 0">
          <a
            :if={@tournament.public_pages_enabled}
            class="pe-btn"
            href={~p"/p/#{@tournament.public_slug}/pairings"}
            target="_blank"
            title="No login needed - share this link"
          >
            Public pairings link
          </a>

          <a class="pe-btn" href={~p"/t/#{@tournament.id}/live"} target="_blank">
            Live view &amp; phone QR
          </a>

          <a class="pe-btn" href={~p"/t/#{@tournament.id}/export/trf"} target="_blank">
            Export TRF (all rounds)
          </a>

          <form
            id="trf-rounds-export-form"
            method="get"
            action={~p"/t/#{@tournament.id}/export/trf"}
            target="_blank"
            style="display: flex; gap: 6px; align-items: center; margin: 0"
          >
            <input
              type="text"
              name="rounds"
              placeholder="e.g. 1-5 or 1,3,5"
              class="pe-select"
              style="width: 150px"
            />
            <button type="submit" class="pe-btn" title="Export only the rounds listed here">
              Export rounds…
            </button>
          </form>
        </div>
      </div>

      <p
        :if={@tournament.manual_ranking}
        class="hint"
        style="margin-top: -8px; margin-bottom: 12px"
      >
        Manual ranking is on for this tournament, but the TRF export's rank column reflects the
        computed/starting-rank order, not the arbiter's hand-set display order.
      </p>

      <div :if={!@setup_complete} class="card error-note" style="display: block; margin: 12px 0">
        Finish the tournament setup before pairing - still missing:
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
        You're ready to pair. For a complete FIDE report, you may also want to fill in:
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
                @round == nil -> "not paired"
                Enum.any?(@round.pairings, &(&1.result == "")) -> "playing"
                true -> "finished"
              end}
            </span>
          </p>
        </div>

        <div class="actions" style="margin: 0">
          <button
            :if={@round == nil && @round_number == @next_pairable}
            class="pe-btn primary"
            phx-click="pair"
            disabled={!@can_pair}
            data-confirm={
              @tournament.pairing_system == "round_robin" &&
                "This generates the whole round-robin schedule at once (every round, not just " <>
                  "this one) and locks in who's playing — anyone added afterward won't be in " <>
                  "it, and the schedule can't be changed once it exists. Continue?"
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
            {if @tournament.pairing_system == "round_robin",
              do: "Pair the whole tournament (Berger)",
              else: "Pair round #{@round_number} (#{pairing_engine_label(@tournament)})"}
          </button>

          <div
            :if={@round != nil}
            class="print-menu-wrap"
            phx-hook=".PrintMenu"
            id={"print-pairings-menu-#{@round_number}"}
          >
            <a
              class="pe-btn"
              href={~p"/t/#{@tournament.id}/print/pairings?round=#{@round_number}"}
              target="_blank"
              title="Right-click for more print options"
            >
              Print pairings <span class="print-menu-affordance">⋯</span>
            </a>

            <div class="print-menu-items" hidden>
              <a
                href={~p"/t/#{@tournament.id}/print/pairings?round=#{@round_number}&absentees=1"}
                target="_blank"
                title="Same pairing sheet, with a below-the-table section listing requested byes and absences"
              >
                With absentees section
              </a>
            </div>
          </div>

          <a
            :if={@round != nil}
            class="pe-btn"
            href={~p"/t/#{@tournament.id}/print/standings?round=#{@round_number}"}
            target="_blank"
          >
            Print standings
          </a>

          <div
            :if={@round != nil}
            class="print-menu-wrap"
            phx-hook=".PrintMenu"
            id={"print-results-menu-#{@round_number}"}
          >
            <a
              class="pe-btn"
              href={~p"/t/#{@tournament.id}/print/results?round=#{@round_number}"}
              target="_blank"
              title="Right-click for more print options"
            >
              Print result cards <span class="print-menu-affordance">⋯</span>
            </a>

            <div class="print-menu-items" hidden>
              <a
                href={~p"/t/#{@tournament.id}/print/results?round=#{@round_number}&limit=3"}
                target="_blank"
                title="Print just the first 3 result cards, to check printer alignment before printing the full stack"
              >
                Test print (first 3 cards)
              </a>

              <a
                href={~p"/t/#{@tournament.id}/print/results?round=#{@round_number}&order=stack"}
                target="_blank"
                title="Reorders cards so guillotine-cutting the printed stack into 8 piles and collating them recovers board order"
              >
                Stack-cut order
              </a>
            </div>
          </div>

          <div
            :if={@round != nil}
            class="print-menu-wrap"
            phx-hook=".PrintMenu"
            id={"pgn-export-menu-#{@round_number}"}
          >
            <a
              class="pe-btn"
              href={~p"/t/#{@tournament.id}/export/pgn?round=#{@round_number}"}
              target="_blank"
              title="Metadata-only PGN - no moves are recorded in OpenPairings. Right-click for more options"
            >
              Export PGN <span class="print-menu-affordance">⋯</span>
            </a>

            <div class="print-menu-items" hidden>
              <a
                href={~p"/t/#{@tournament.id}/export/pgn?round=#{@round_number}&board=1"}
                target="_blank"
                title="Adds a [Board &quot;N&quot;] tag to every game, using the same board number shown on the pairing sheet"
              >
                This round, with board numbers
              </a>

              <a href={~p"/t/#{@tournament.id}/export/pgn"} target="_blank">
                All rounds
              </a>

              <a href={~p"/t/#{@tournament.id}/export/pgn?board=1"} target="_blank">
                All rounds, with board numbers
              </a>
            </div>
          </div>

          <button
            :if={@round != nil}
            class="pe-btn"
            phx-click="toggle_import_results"
          >
            Import results (CSV)
          </button>

          <button
            :if={@round != nil && @round_number == @paired_rounds}
            class="pe-btn danger-link"
            phx-click="unpair"
            data-confirm={"Unpair round #{@round_number}? All its results will be deleted."}
          >
            Unpair round
          </button>
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
        <h3 style="margin-top: 0">Import results (CSV) - round {@round_number}</h3>

        <p class="hint" style="margin-top: 0">
          One line per board: <code>board,result</code>
          (or <code>;</code>-separated).
          Results: <code>1-0</code>, <code>0-1</code>, <code>1/2-1/2</code>
          (or <code>=</code>), <code>0-0</code>
          (both lose, played), <code>1-0FF</code>/<code>0-1FF</code>
          (forfeit win), <code>0-0FF</code>
          (double forfeit). Boards left out keep their current result.
        </p>

        <div
          class={["dropzone", @uploads.results_csv.entries != [] && "has-file"]}
          phx-drop-target={@uploads.results_csv.ref}
        >
          <.live_file_input upload={@uploads.results_csv} class="dropzone-input" />
          <div class="dropzone-label">
            <%= if @uploads.results_csv.entries == [] do %>
              <strong>Choose a .csv file</strong> <span class="hint">or drag and drop it here</span>
            <% else %>
              <span :for={entry <- @uploads.results_csv.entries} class="dropzone-file">
                {entry.client_name}
              </span>
            <% end %>
          </div>
        </div>

        <p :for={err <- upload_errors(@uploads.results_csv)} class="error-note">{inspect(err)}</p>

        <div :if={@import_errors} class="error-note" style="display: block">
          <strong>Nothing was saved - fix these and try again:</strong>
          <ul style="margin: 6px 0 0">
            <li :for={err <- @import_errors}>{err}</li>
          </ul>
        </div>

        <div class="actions">
          <button type="submit" class="pe-btn primary">Import</button>
          <button type="button" class="pe-btn" phx-click="toggle_import_results">Cancel</button>
        </div>
      </form>

      <p class="hint" style="margin: 8px 0">
        Tip: click a result box and press 1 / 2 / 3 (top row or numpad, any keyboard layout) to enter results rapidly (white win / draw / black win) - focus jumps to the next board automatically.
        <strong>Right-click any player</strong>
        to swap them, or to mark them absent for this round.
      </p>

      <div :if={@swap_first} class="swap-banner" phx-window-keydown="cancel_swap" phx-key="escape">
        <span class="swap-banner-dot"></span>
        <span>
          Swapping <strong>{@swap_first.name}</strong>
          — now click whoever they should trade places with, on a board or in the
          not-playing list below.
        </span>
        <button type="button" class="pe-btn" phx-click="cancel_swap">Cancel (Esc)</button>
      </div>

      <div
        :if={@pool_first}
        class="swap-banner"
        phx-window-keydown="cancel_pool_pair"
        phx-key="escape"
      >
        <span class="swap-banner-dot"></span>
        <span>
          Pairing <strong>{@pool_first.name}</strong> — now click who they should play.
        </span>
        <button type="button" class="pe-btn" phx-click="cancel_pool_pair">Cancel (Esc)</button>
      </div>

      <div
        :if={@seat_pick}
        class="swap-banner"
        phx-window-keydown="cancel_seat_pick"
        phx-key="escape"
      >
        <span class="swap-banner-dot"></span>
        <span>Which empty seat should they take? Click one below.</span>
        <button type="button" class="pe-btn" phx-click="cancel_seat_pick">Cancel (Esc)</button>
      </div>
      <.pairing_menu :if={@menu} menu={@menu} round={@round} />
      <div :if={@confirm} class="pe-modal" phx-window-keydown="cancel_confirm" phx-key="escape">
        <div class="pe-modal-card" phx-click-away="cancel_confirm">
          <header class="pe-modal-head">
            <h2>{@confirm.title}</h2>

            <p>{@confirm.subtitle}</p>
          </header>

          <div class="pe-modal-body">
            <div id="confirm-board-diffs" class="board-diff-group" phx-hook=".SwapArrows">
              <div :for={c <- @confirm.changes} class="board-diff">
                <div class="board-diff-num">Board {c.board}</div>
                <.board_card seats={c.before} state="before" compare={c.after} />
                <div class="board-diff-arrow">→</div>
                <.board_card
                  seats={c.after}
                  state="after"
                  compare={c.before}
                  related_board={c[:related_board]}
                />
              </div>
              <%!-- Filled in by the .SwapArrows hook; phx-update="ignore" so
                    LiveView leaves the generated SVG alone on re-render. --%>
              <div id="swap-arrows-layer" class="swap-arrows-layer" phx-update="ignore"></div>
            </div>

            <label :if={@confirm.kind == :pool_pair} class="board-number-field">
              <span>Table number</span>
              <form phx-change="set_confirm_board">
                <input type="number" name="board" value={@confirm.board} min="1" />
              </form>
            </label>

            <p :if={@confirm.note} class="pe-modal-note">{@confirm.note}</p>

            <p
              :if={Enum.any?(@confirm.changes, &Map.get(&1, :result_will_clear?))}
              class="pe-modal-warn"
            >
              A recorded result will be cleared — it described a game between players who are
              no longer both on that board.
            </p>

            <div :if={@confirm.frozen} class="pe-modal-warn">
              <strong>
                You're changing round {@round_number}, not the current round (round {@paired_rounds}).
              </strong>

              <label style="display: flex; align-items: center; gap: 6px; margin-top: 6px; font-weight: 400">
                <input type="checkbox" checked={@confirm.frozen_ack} phx-click="toggle_frozen_ack" />
                I understand — apply this to round {@round_number} anyway
              </label>
            </div>
          </div>

          <footer class="pe-modal-foot">
            <button type="button" class="pe-btn" phx-click="cancel_confirm">Cancel</button>
            <button
              type="button"
              class="pe-btn primary pe-modal-go"
              phx-click="apply_confirm"
              disabled={@confirm.frozen and !@confirm.frozen_ack}
            >
              {@confirm.title}
            </button>
          </footer>
        </div>
      </div>

      <div class="card table-card">
        <table class="pe-table" id={"pairings-table-#{@round_number}"} phx-hook=".PairingMenu">
          <thead>
            <tr>
              <th class="num">Board</th>

              <th>White</th>

              <th style="text-align: center; width: 220px">Result</th>

              <th>Black</th>
            </tr>
          </thead>

          <tbody>
            <tr :if={@round == nil}>
              <td colspan="4">
                <div class="empty">
                  <p><strong>This round has not been paired yet.</strong></p>

                  <p class="hint">
                    <%= cond do %>
                      <% @tournament.pairing_system == "round_robin" -> %>
                        Press "Pair the whole tournament" to generate every round of the Berger
                        schedule at once — round-robin doesn't pair one round at a time.
                      <% @round_number == @next_pairable -> %>
                        Press "Pair round {@round_number}" to generate the {pairing_engine_description(
                          @tournament
                        )}.
                      <% true -> %>
                        Rounds are paired in order - round {@next_pairable} is next.
                    <% end %>
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
              <td class="num">{display_board}</td>

              <td>
                <.seat_cell
                  player={pairing.white_player}
                  pairing={pairing}
                  side={:white}
                  swap_first={@swap_first}
                  seat_pick={@seat_pick}
                  scores={@scores}
                />
              </td>

              <td style="text-align: center">
                <%= cond do %>
                  <% pairing.result == "bye" -> %>
                    <span class="badge">bye ({@tournament.bye_value} pt)</span>
                  <% @confirm_clear_pairing_id == pairing.id -> %>
                    <div class="confirm-clear-result">
                      <span class="hint">
                        Clear the recorded result ({pairing.result}) for this board?
                      </span>

                      <button
                        type="button"
                        class="pe-btn danger-link"
                        phx-click="confirm_clear_result"
                        phx-value-pairing-id={pairing.id}
                      >
                        Yes, clear it
                      </button>

                      <button type="button" class="pe-btn" phx-click="cancel_clear_result">
                        Cancel
                      </button>
                    </div>
                  <% true -> %>
                    <form phx-change="result" id={"result-form-#{pairing.id}"}>
                      <input type="hidden" name="pairing-id" value={pairing.id} />
                      <select
                        name="result"
                        class="pe-select"
                        id={"result-select-#{pairing.id}"}
                        phx-hook=".BlindResultEntry"
                        data-board-select
                        data-result={pairing.result}
                      >
                        <option
                          :for={{value, label} <- results()}
                          value={value}
                          selected={pairing.result == value}
                        >
                          {label}
                        </option>
                      </select>
                    </form>
                <% end %>
              </td>

              <td>
                <.seat_cell
                  player={pairing.black_player}
                  pairing={pairing}
                  side={:black}
                  swap_first={@swap_first}
                  seat_pick={@seat_pick}
                  scores={@scores}
                />
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div
        :if={@round != nil and @round_pool != []}
        class="card pool-panel"
        id={"round-pool-#{@round_number}"}
        phx-hook=".PairingMenu"
      >
        <div class="pool-head">
          <h3>Not playing round {@round_number}</h3>

          <p class="hint">
            Right-click anyone here to put them in an empty seat, swap them onto a board, or
            pair two of them together.
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
            title="Right-click for options"
          >
            <span class="pool-chip-name">{player_label(entry.player)}</span>
            <span class="pool-chip-tag">{pool_tag(entry, @tournament)}</span>
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
              if (document.activeElement !== this.el) {
                e.preventDefault();
                this.el.focus();
              }
            };
            this.el.addEventListener("mousedown", this.onMousedown);

            this.onKeydown = (e) => {
              const value = CODE_TO_VALUE[e.code] || KEY_TO_VALUE[e.key];
              if (!value) return; // let every other key behave natively

              const hasOption = Array.from(this.el.options).some((o) => o.value === value);
              if (!hasOption) return;

              // Stop the browser's native "jump to option starting with
              // this character" select behavior - we're fully driving the
              // value ourselves.
              e.preventDefault();

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

          // Real incident: an arbiter changed a result on one tab (e.g.
          // "0-0FF" -> "0-0"); a second arbiter viewing the same round, who
          // simply had that SAME board's select focused (nothing more --
          // no typing in progress), never saw the change. Root cause is a
          // genuine Phoenix LiveView behavior, not a bug in this app's own
          // code: once a form control has been interacted with, LiveView's
          // client won't overwrite its `value`/`selected` state on a
          // server-pushed diff, so as not to clobber someone's in-progress
          // typing — and confirmed by hand, that pin doesn't even clear on
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
          // focused or not — resync `value` from it whenever they drift.
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
              row.scrollIntoView({ behavior: "smooth", block: "center" });
            }
          },

          destroyed() {
            this.el.removeEventListener("keydown", this.onKeydown);
            this.el.removeEventListener("mousedown", this.onMousedown);
          }
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".SwapArrows">
        // Draws one curved arrow per player who MOVES in the confirm modal:
        // from where they sit now (a changed seat in a "before" card) to
        // where they land (the same name, in an "after" card). For a
        // two-board swap that's two curves crossing in the middle — the
        // crossing is the swap. For a same-board colour swap the two curves
        // cross inside the single row.
        //
        // Which seats to join is decided by NAME MATCHING, not by a flag
        // from the server: a curve exists exactly when one name is a changed
        // seat on both sides. That yields 2 curves for either kind of swap
        // and ZERO for mark-absent / award-bye / fill-seat / pool-pair /
        // substitute-from-pool, where nobody travels between two shown
        // boards — no new server state to keep in sync, and it cannot
        // mislabel a non-swap as one.
        //
        // The curves route through the middle grid column (normally just the
        // static "→", hidden while arrows are up and widened into a real
        // channel). Straight-line arrows would tunnel under the opaque
        // board cards; routing through the empty channel keeps every name
        // readable.
        //
        // Pure enhancement: no JS, a failed measurement or an ambiguous
        // name match all leave the plain "→" layout and the "⇄ Board N"
        // chips exactly as they are.
        const REDUCED_MOTION = "(prefers-reduced-motion: reduce)";
        const SVG_NS = "http://www.w3.org/2000/svg";

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
            // widths have to land BEFORE anything is measured — reading a
            // layout property forces that synchronously, rather than
            // waiting on a frame that may never come.
            this.el.classList.add("has-swap-arrows");
            void this.el.offsetHeight;

            this.render(layer, pairs);
          },

          // [beforeSeatEl, afterSeatEl] for every name that changed seats on
          // both sides. A name appearing twice on either side is ambiguous
          // (two players sharing a display name) — skipped rather than
          // guessed at, since a wrong arrow is worse than none.
          matchTravellers() {
            const nameOf = (el) =>
              (el.querySelector(".board-seat-name")?.textContent || "").trim();

            // `board-seat-moving` is the before card's unstyled twin of
            // `board-seat-changed` — see `board_card/1`'s `changed_class`.
            const before = Array.from(
              this.el.querySelectorAll(".board-card-before .board-seat-moving")
            );
            const after = Array.from(
              this.el.querySelectorAll(".board-card-after .board-seat-changed")
            );

            const tally = (els) => {
              const counts = new Map();
              els.forEach((el) => {
                const n = nameOf(el);
                counts.set(n, (counts.get(n) || 0) + 1);
              });
              return counts;
            };

            const beforeCounts = tally(before);
            const afterCounts = tally(after);
            const pairs = [];

            before.forEach((from) => {
              const name = nameOf(from);
              if (!name) return;
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
            // own height — so the curve leaves the card beside the right
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
            svg.append(this.arrowHeadDefs());

            const animate = !window.matchMedia(REDUCED_MOTION).matches;

            pairs.forEach(([from, to], i) => {
              const start = exit(from);
              const end = entry(to);

              // Each curve gets its own lane in the channel so two of them
              // read as a crossing X rather than one doubled line.
              const mid = (start.x + end.x) / 2;
              const lane = mid + (i - (pairs.length - 1) / 2) * 14;

              const path = document.createElementNS(SVG_NS, "path");
              path.setAttribute("class", "swap-arrow-path");
              path.setAttribute(
                "d",
                `M ${start.x} ${start.y} C ${lane} ${start.y}, ${lane} ${end.y}, ${end.x - 4} ${end.y}`
              );
              path.setAttribute("marker-end", "url(#swap-arrow-head)");

              const dot = document.createElementNS(SVG_NS, "circle");
              dot.setAttribute("class", "swap-arrow-dot");
              dot.setAttribute("cx", start.x);
              dot.setAttribute("cy", start.y);
              dot.setAttribute("r", 3);

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

          arrowHeadDefs() {
            const defs = document.createElementNS(SVG_NS, "defs");
            const marker = document.createElementNS(SVG_NS, "marker");
            marker.setAttribute("id", "swap-arrow-head");
            marker.setAttribute("viewBox", "0 0 8 8");
            marker.setAttribute("refX", "7");
            marker.setAttribute("refY", "4");
            marker.setAttribute("markerWidth", "5");
            marker.setAttribute("markerHeight", "5");
            marker.setAttribute("orient", "auto");

            const head = document.createElementNS(SVG_NS, "path");
            head.setAttribute("class", "swap-arrow-head");
            head.setAttribute("d", "M 0 0 L 8 4 L 0 8 z");

            marker.append(head);
            defs.append(marker);
            return defs;
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
        // A right-click NEVER completes anything — it only ever opens the
        // menu. Every write is behind a menu item plus the confirm modal,
        // so no two-right-clicks-in-a-row can change a pairing by accident.
        export default {
          mounted() {
            this.onContextMenu = (e) => {
              const target = e.target.closest("[data-scope]");
              if (!target) return;
              e.preventDefault();

              // Keep the menu fully on screen: it's ~280x150, so flip it
              // back inside the viewport when the click lands near an edge.
              const x = Math.min(e.clientX, window.innerWidth - 300);
              const y = Math.min(e.clientY, window.innerHeight - 170);

              this.pushEvent("open_menu", {
                x: Math.max(8, x),
                y: Math.max(8, y),
                scope: target.dataset.scope,
                "player-id": target.dataset.playerId || null,
                "pairing-id": target.dataset.pairingId || null
              });
            };
            this.el.addEventListener("contextmenu", this.onContextMenu);
          },

          destroyed() {
            this.el.removeEventListener("contextmenu", this.onContextMenu);
          }
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".PrintMenu">
        // Consolidates a print button's variants behind a right-click
        // context menu instead of a row of separate buttons: left-click on
        // the anchor still opens the plain/default print in a new tab
        // (native <a target="_blank"> behavior, untouched); right-click
        // suppresses the browser's context menu and shows this small popup
        // built from the hidden ".print-menu-items" sibling's own <a> tags,
        // so each menu item is a real link with its own href/target/title -
        // no data-JSON to keep in sync with the markup.
        export default {
          mounted() {
            this.menu = this.el.querySelector(".print-menu-items");
            this.popup = null;

            this.onContextMenu = (e) => {
              e.preventDefault();
              this.openAt(e.clientX, e.clientY);
            };
            this.el.addEventListener("contextmenu", this.onContextMenu);

            this.onDocMousedown = (e) => {
              if (this.popup && !this.popup.contains(e.target)) this.close();
            };
            this.onDocKeydown = (e) => {
              if (e.key === "Escape") this.close();
            };
            document.addEventListener("mousedown", this.onDocMousedown);
            document.addEventListener("keydown", this.onDocKeydown);
          },

          openAt(x, y) {
            this.close();

            const popup = document.createElement("div");
            popup.className = "print-menu-popup";
            popup.style.left = `${x}px`;
            popup.style.top = `${y}px`;

            Array.from(this.menu.querySelectorAll("a")).forEach((link) => {
              const item = link.cloneNode(true);
              item.addEventListener("click", () => this.close());
              popup.appendChild(item);
            });

            document.body.appendChild(popup);
            this.popup = popup;
          },

          close() {
            if (this.popup) {
              this.popup.remove();
              this.popup = null;
            }
          },

          destroyed() {
            this.close();
            this.el.removeEventListener("contextmenu", this.onContextMenu);
            document.removeEventListener("mousedown", this.onDocMousedown);
            document.removeEventListener("keydown", this.onDocKeydown);
          }
        }
      </script>
    </Layouts.app>
    """
  end
end
