defmodule PairingsEngineWeb.MobileResultsLive do
  @moduledoc """
  The no-account mobile result-entry screen - Manubrium's hall view
  (docs/manubrium.md). Reached only via an active enrollment (see
  `PairingsEngineWeb.MobileAuth`), scoped to that one tournament. A helper
  taps a board and picks the result - nothing else is reachable from here.

  With the `Manubrium` hook running, a tap does not come here at all: it
  becomes an entry in the phone's queue, sent to `/m/sync` and judged by
  `PairingsEngine.Mobile.Sync`, so it survives the hall wifi dropping. The
  `set_result` event below is the same write made directly, which is what a
  page without the hook (or a test) uses. Both go through
  `Mobile.permit_result/4` and `Tournaments.update_pairing_result/3`, and
  both refuse a result tapped on a board that changed since the phone drew
  it (the compare-and-set) - telling every phone in the hall, so two
  arbiters who disagree about a board find out from their phones, not from
  the standings.

  Beside each board: playing or finished, what the board in the hall
  reported when it has live boards (`PairingsEngine.BoardLink.compare/2`,
  red when it differs - never entered for anyone), and how long the round
  has been going.
  """
  use PairingsEngineWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.{BoardLink, Mobile, Standings, Tournaments}
  alias PairingsEngineWeb.Components.Manubrium
  alias PairingsEngine.Tournaments.{Pairing, Player, Tournament}

  @results [{"1-0", "1-0"}, {"1/2-1/2", "½-½"}, {"0-1", "0-1"}]

  # The rest of PairingsLive's own `@results` (forfeits and the asymmetric
  # disciplinary codes) - real results a helper at the board genuinely needs
  # to record, just rare enough that showing all 9 buttons on every board by
  # default would crowd the three that matter 95% of the time on a small
  # screen. Tucked behind "More…" (`toggle_extra/2`) instead of a long-press:
  # a long-press has no visible affordance at all (nothing on screen hints
  # it exists), fires inconsistently across mobile browsers, and collides
  # with the OS's own text-selection/context-menu gesture on many devices -
  # a plain, visible, always-there button is more reliable AND more
  # discoverable for exactly the audience (arbiters/helpers, not the
  # tournament owner) most likely to be seeing this screen for the first
  # time mid-round.
  @extra_results [
    {"1/2-0", "½-0 (asymmetric)"},
    {"0-1/2", "0-½ (asymmetric)"},
    {"1-0FF", "1-0 FF"},
    {"0-1FF", "0-1 FF"},
    {"0-0FF", "0-0 FF (double forfeit)"},
    {"0-0", "0-0 (both lose, played)"},
    {"1-0U", "1-0 (played, not rated)"},
    {"0-1U", "0-1 (played, not rated)"},
    {"1/2-1/2U", "½-½ (played, not rated)"},
    # Labelled at render time (`button_label/2`) so the words go through
    # gettext, and shown only where the tournament allows postponed games.
    {"*W", :postponed_white},
    {"*B", :postponed_black}
  ]

  # Every code an arbiter may write, from the one table
  # (`PairingsEngine.Results`) rather than typed out again here. This screen
  # used to carry a hand-copied ten-item list under a comment claiming it
  # mirrored the Pairings page; it had been missing the three unrated codes
  # since the day they shipped, so a helper's phone could not record a
  # played-but-unrated game that the same round could record by click.
  # How long a board stays on screen after its result goes in.
  #
  # The point is not decoration: a helper taps a small button on a phone in a
  # noisy hall and needs to see WHICH result landed on WHICH board before it
  # goes. Too short and it is a flicker that proves nothing; too long and the
  # list stops shrinking, which is the whole reason for hiding finished
  # boards. About a second and a half reads as a confirmation.
  @settle_ms 1_600

  @entry_codes PairingsEngine.Results.entry_codes()

  # How long the clear button waits for its second tap before it goes back
  # to being a plain "Clear result". Long enough to read the board number
  # and mean it, short enough that a stray tap does not leave a loaded gun
  # lying about in a noisy hall.
  @confirm_ms 4_000

  # How long a board whose result is on its way (the hook said so) stays on
  # screen if the answer never comes back. The answer normally arrives in a
  # fraction of a second and starts the ordinary `@settle_ms` instead; this
  # is only the ceiling for a reply lost on the way.
  @hold_ms 15_000

  # How often the round clock moves. Minutes are what it shows.
  @tick_ms 30_000

  # The buttons must offer everything the guard accepts, minus the blank
  # (which has its own labelled, two-tap "Clear result" button below the
  # results; tapping the chosen result again does nothing at all).
  # A build that drifts from that fails here rather than shipping a button
  # that writes nothing, or a code with no way to enter it.
  @offered Enum.map(@results ++ @extra_results, &elem(&1, 0))
  @expected @entry_codes -- [""]
  if Enum.sort(@offered) != Enum.sort(@expected) do
    raise "mobile result buttons have drifted from PairingsEngine.Results.entry_codes/0: " <>
            "#{inspect(@offered -- @expected)} offered here only, " <>
            "#{inspect(@expected -- @offered)} missing here"
  end

  @impl true
  def mount(_params, _session, socket) do
    tournament = socket.assigns.tournament

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Mobile.hall_topic(tournament.id))
      BoardLink.subscribe(tournament.id)
      Process.send_after(self(), :tick, @tick_ms)
    end

    paired = Engine.paired_rounds_count(tournament.id)
    enrollment = socket.assigns.mobile_enrollment

    {:ok,
     socket
     |> assign(
       page_title: "Enter results",
       results: @results,
       extra_results: @extra_results,
       paired: paired,
       read_only?: read_only?(tournament),
       locked: false,
       # Finished boards are hidden by default: a helper cannot change one
       # anyway, so on a phone they are a list to scroll past on the way to
       # the work. `show_all` brings them back for a deputy correcting one,
       # or for anyone wanting to check what they already entered.
       show_all: false,
       # Boards entered within the last `@settle_ms`, kept visible so the
       # helper can confirm what landed before the list closes over it.
       just_saved: MapSet.new(),
       # The board whose "Clear result" has had its first tap and is waiting
       # for the second (see `@confirm_ms`).
       confirm_clear: nil,
       saved_notice: "",
       # Boards whose result the phone's queue is sending right now: kept on
       # screen (not green yet) until the answer starts their settle.
       held: MapSet.new(),
       # The hall view's own board filter, on top of the enrolment's range:
       # "boards 21 to 40", for a deputy covering one room of a big hall.
       filter_form: to_form(%{"from" => "", "to" => ""}, as: :filter),
       filter_range: {nil, nil},
       # Which board's "More…" panel is open, if any - one at a time, so
       # the page doesn't grow tall with several boards expanded at once.
       # Cleared on round switch (below) since the boards it referred to no
       # longer apply.
       expanded_id: nil,
       # A name or a board number, typed: "where is Peeters playing?"
       search: "",
       # The boards the desk gave this arbiter (`Tournaments.assign_boards/4`),
       # for an account's own phone; `mine` narrows the list to them.
       my_range: Tournaments.assigned_boards(enrollment.user_id, tournament.id),
       mine: false,
       # Boards two entries disagreed about, `%{pairing_id => conflict}`,
       # until someone dismisses them or the board moves on.
       conflicts: %{},
       now: DateTime.utc_now()
     )
     |> assign_board_reports()
     |> load_round(max(paired, 1))}
  end

  # What the boards in the hall reported, or nil for a tournament with no
  # live boards (and then no board column on this page either).
  defp assign_board_reports(socket) do
    id = socket.assigns.tournament.id
    assign(socket, board_reports: if(BoardLink.connected?(id), do: BoardLink.summaries(id)))
  end

  # The arbiter has revoked THIS phone. Every phone on the tournament hears
  # the broadcast, so the id is checked before acting on it. Until this
  # existed the page kept reloading the round quite happily and only found
  # out it had been revoked when the helper next tried to write a result -
  # so "revoke" appeared to do nothing at all from the phone's side.
  @impl true
  # The other half of the settle window. Deleting by id rather than clearing
  # the set: a helper working quickly has several confirmations in flight,
  # and each timer must retire only its own.
  def handle_info({:settle_board, pairing_id}, socket) do
    {:noreply, update(socket, :just_saved, &MapSet.delete(&1, pairing_id))}
  end

  def handle_info({:release_hold, pairing_id}, socket) do
    {:noreply, update(socket, :held, &MapSet.delete(&1, pairing_id))}
  end

  def handle_info({:clear_confirm_expired, pairing_id}, socket) do
    if socket.assigns.confirm_clear == pairing_id,
      do: {:noreply, assign(socket, confirm_clear: nil)},
      else: {:noreply, socket}
  end

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, assign(socket, now: DateTime.utc_now())}
  end

  # A board in the hall reported a game's state, or the board link changed;
  # a move by itself changes nothing this page shows.
  def handle_info({:board_game, _tournament_id, _game, :state}, socket),
    do: {:noreply, socket |> assign_board_reports() |> assign_round_clock()}

  def handle_info({:board_game, _tournament_id, _game, _moves}, socket), do: {:noreply, socket}

  def handle_info({:board_link, _tournament_id}, socket),
    do: {:noreply, assign_board_reports(socket)}

  # Two entries disagreed about a board, here or on another phone
  # (`Mobile.announce_conflict/5`). Shown on the board until dismissed.
  def handle_info({:hall_conflict, %{pairing_id: id} = conflict}, socket) do
    if Enum.any?(socket.assigns.boards, &(&1.id == id)),
      do: {:noreply, update(socket, :conflicts, &Map.put(&1, id, conflict))},
      else: {:noreply, socket}
  end

  def handle_info({:mobile_enrollment_revoked, id}, socket) do
    if id == socket.assigns.mobile_enrollment.id do
      {:noreply,
       socket
       |> put_flash(:error, gettext("This phone's access has been ended by the arbiter."))
       |> redirect(to: ~p"/m")}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:tournament_changed, _id, _hint}, socket) do
    # `on_mount(:require_enrollment, ...)` only loads `tournament` once, at
    # connect - reload it here too, or an archive/unarchive elsewhere would
    # never reach this page and the result buttons would stay stuck in
    # whichever `disabled?` state was true at the moment this phone opened
    # the page.
    tournament = Tournaments.get_tournament(socket.assigns.tournament.id)

    socket =
      if tournament,
        do: assign(socket, tournament: tournament, read_only?: read_only?(tournament)),
        else: socket

    paired = Engine.paired_rounds_count(socket.assigns.tournament.id)

    # A helper has no round switcher (see the render) and is pinned to the
    # latest paired round by `Mobile.permit_round/3` - without tracking that
    # here too, a helper connected before round N+1 was paired would be left
    # stuck looking at round N: `permit_result/4` would (correctly) start
    # refusing every tap, with no button left on the page to reach the round
    # that now works. A deputy keeps whatever round they had open, same as
    # before - they have a switcher and may be deliberately reviewing an
    # earlier one.
    target_round =
      if helper?(socket.assigns.mobile_enrollment),
        do: max(paired, 1),
        else: socket.assigns.round_number

    {:noreply, socket |> assign(paired: paired) |> load_round(target_round)}
  end

  @impl true
  def handle_event("select_round", %{"number" => number}, socket) do
    requested = String.to_integer(number)
    latest = Engine.paired_rounds_count(socket.assigns.tournament.id)

    case Mobile.permit_round(socket.assigns.mobile_enrollment, requested, latest) do
      :ok ->
        {:noreply,
         socket |> assign(expanded_id: nil, confirm_clear: nil) |> load_round(requested)}

      {:error, :earlier_round} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "Helpers can only view the current round - ask the arbiter to check an earlier one."
           )
         )}
    end
  end

  # A "hand the phone to someone else / put it down for a second" guard, not
  # a security boundary - off by default (per-session, resets on reload), and
  # purely to stop an accidental tap from overwriting a result. The buttons
  # are also `disabled` client-side, but this is the actual enforcement.
  def handle_event("toggle_lock", _params, socket) do
    {:noreply, assign(socket, locked: !socket.assigns.locked)}
  end

  # Opens/closes one board's "More…" panel (the forfeit/asymmetric codes -
  # see `@extra_results`). Only one open at a time: opening a different
  # board's panel closes whichever was already open, same as an accordion.
  def handle_event("toggle_extra", %{"id" => id}, socket) do
    id = String.to_integer(id)
    current = socket.assigns.expanded_id
    {:noreply, assign(socket, expanded_id: if(current == id, do: nil, else: id))}
  end

  def handle_event("set_result", _params, socket)
      when socket.assigns.locked or socket.assigns.read_only?,
      do: {:noreply, socket}

  # Clearing takes two taps on a button that says what it does. The first
  # arms it for `@confirm_ms`; the second, on the same board, clears. The
  # button is only drawn where `clearable` allows it, and this is the check
  # behind that courtesy - the write still goes through
  # `Mobile.permit_result/4` and `Tournaments.update_pairing_result/3`.
  def handle_event("clear_result", _params, socket)
      when socket.assigns.locked or socket.assigns.read_only?,
      do: {:noreply, socket}

  def handle_event("clear_result", %{"id" => id}, socket) do
    pairing_id = String.to_integer(id)

    cond do
      not MapSet.member?(socket.assigns.clearable, pairing_id) ->
        {:noreply, socket}

      socket.assigns.confirm_clear == pairing_id ->
        handle_event(
          "set_result",
          %{"id" => id, "result" => ""},
          assign(socket, confirm_clear: nil)
        )

      true ->
        Process.send_after(self(), {:clear_confirm_expired, pairing_id}, @confirm_ms)
        {:noreply, assign(socket, confirm_clear: pairing_id)}
    end
  end

  # Only pairings belonging to the loaded round (which is loaded from the
  # enrollment's own tournament) can be set - a crafted pairing id from
  # another tournament simply isn't in the set and is ignored. The codes
  # accepted are every code an arbiter may write, from `@entry_codes` above:
  # mobile shows three by default, but anything reachable through "More…"
  # has to actually be writable too.
  def handle_event("set_result", %{"id" => id, "result" => result} = params, socket)
      when result in @entry_codes do
    # Re-validate the enrollment on every write so a revoked or expired phone
    # is kicked out immediately, not only on its next page load.
    if Mobile.get_active(socket.assigns.mobile_enrollment.id) do
      round = socket.assigns.round
      # What the phone showed on the board when it was tapped. `round` is
      # this page's copy, so it is read again: another phone may have
      # written since.
      shown = params["expected"]

      case round && Enum.find(round.pairings, &(to_string(&1.id) == id)) do
        # Tapping the result a board already has is not a change. It used to
        # be re-saved, and logged as a change from X to X, by a deputy who
        # was trying to clear the board.
        %Pairing{result: current} when current == result ->
          {:noreply, socket}

        %Pairing{} = pairing when is_binary(shown) ->
          stored =
            PairingsEngine.Repo.one(
              from q in Pairing, where: q.id == ^pairing.id, select: q.result
            )

          if (stored || "") != shown and stored != result do
            Mobile.announce_conflict(
              socket.assigns.mobile_enrollment,
              pairing.id,
              pairing.board,
              result,
              stored
            )

            {:noreply,
             socket
             |> put_flash(
               :error,
               gettext(
                 "Board %{board}: not saved - it now says %{current}, entered elsewhere. Check with the other arbiter.",
                 board: pairing.board,
                 current: shown_result(stored)
               )
             )
             |> load_round(socket.assigns.round_number)}
          else
            handle_event("set_result", Map.delete(params, "expected"), socket)
          end

        %Pairing{} = pairing ->
          # The domain decides, not this LiveView - see `Mobile.permit_result/4`
          # for the three rules (round, board range, fill-once) and why each
          # one is checked here again even though the render already hides
          # what it can: hiding is the courtesy, this is the enforcement, and
          # a hidden control is still a control absent-from-the-page HTML,
          # not absent from what a client can send.
          latest = Engine.paired_rounds_count(socket.assigns.tournament.id)

          case Mobile.permit_result(
                 socket.assigns.mobile_enrollment,
                 pairing,
                 socket.assigns.round_number,
                 latest
               ) do
            :ok ->
              previous = pairing.result

              socket =
                case Tournaments.update_pairing_result(pairing, result) do
                  {:ok, _} ->
                    log_mobile_result(socket, pairing, previous, result)

                    # Hold the board on screen a moment so the helper can see
                    # what landed on which board before the list closes over
                    # it. Only entering settles; clearing puts the board back
                    # among the unfinished, which is its own confirmation.
                    if result == "" do
                      assign(socket,
                        saved_notice:
                          gettext("Board %{board}: result cleared", board: pairing.board)
                      )
                    else
                      Process.send_after(self(), {:settle_board, pairing.id}, @settle_ms)

                      socket
                      |> update(:just_saved, &MapSet.put(&1, pairing.id))
                      # The green flash on the board is the eye's confirmation;
                      # this is a screen reader's, through the page's status line.
                      |> assign(
                        saved_notice:
                          gettext("Board %{board}: %{result} saved",
                            board: pairing.board,
                            result: result
                          )
                      )
                    end

                  # The arbiter moved somebody since this phone drew the
                  # board. Nothing was written; the reload shows who sits
                  # there now.
                  {:error, :board_changed} ->
                    put_flash(
                      socket,
                      :error,
                      gettext(
                        "Not saved: board %{board} changed - the arbiter changed its players. Check who is on it now and enter the result again.",
                        board: pairing.board
                      )
                    )

                  {:error, :archived} ->
                    put_flash(
                      socket,
                      :error,
                      gettext(
                        "This tournament is archived - the arbiter needs to unarchive it before results can be entered."
                      )
                    )

                  # The other half of the write gate, and the one that can
                  # arrive mid-round: the arbiter handed the tournament to
                  # another machine while this phone had the board open. Said
                  # in the same words as its sibling, because "could not save"
                  # sends a helper looking for a network problem.
                  {:error, :handed_off} ->
                    put_flash(
                      socket,
                      :error,
                      gettext(
                        "This tournament has been handed to another machine - the arbiter needs to take it back before results can be entered."
                      )
                    )

                  # A postponed game given a decisive result. Every round
                  # paired since counted it as a draw, and the arbiter has to
                  # confirm that knowingly (VCL4THP Q163) - which this screen
                  # has no room to do properly, so it sends the result there.
                  {:error, {:needs_acknowledgement, [:adjourned_non_draw_result]}} ->
                    put_flash(
                      socket,
                      :error,
                      gettext(
                        "Board %{board} was postponed and counted provisionally for pairing. A result that is not a draw has to be entered by the arbiter, on the Pairings page.",
                        board: pairing.board
                      )
                    )

                  # A correction after a later round was paired (a
                  # Correction PIBE, VCL4THP Q115), or a result already sent
                  # in a finalised TRF: the same, for the same reason - the
                  # Pairings page asks first.
                  {:error, {:needs_acknowledgement, ids}} ->
                    put_flash(
                      socket,
                      :error,
                      if(:result_correction in ids,
                        do:
                          gettext(
                            "A later round was already paired with the result of board %{board}. Correcting it has to be done by the arbiter, on the Pairings page.",
                            board: pairing.board
                          ),
                        else:
                          gettext(
                            "Board %{board} was already sent in a TRF finalised for sending. Changing it has to be done by the arbiter, on the Pairings page.",
                            board: pairing.board
                          )
                      )
                    )

                  {:error, _reason} ->
                    put_flash(socket, :error, gettext("Could not save that result."))
                end

              {:noreply, load_round(socket, socket.assigns.round_number)}

            {:error, reason} ->
              {:noreply,
               socket
               |> put_flash(:error, permit_error_message(reason, pairing))
               |> load_round(socket.assigns.round_number)}
          end

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("This phone's access was ended by the arbiter."))
       |> redirect(to: ~p"/m")}
    end
  end

  # The queue (`assets/js/manubrium/`) tells the page a board's result is
  # on its way, and then that it arrived. Neither writes anything - the
  # write is `/m/sync`'s - they only keep the board on screen long enough
  # for the helper to see it land, as a direct tap always did. Ids not on
  # this page's boards are ignored.
  def handle_event("manubrium_hold", %{"ids" => ids}, socket) when is_list(ids) do
    ids = board_ids(socket, ids)
    Enum.each(ids, &Process.send_after(self(), {:release_hold, &1}, @hold_ms))
    {:noreply, update(socket, :held, &MapSet.union(&1, MapSet.new(ids)))}
  end

  def handle_event("manubrium_settle", %{"ids" => ids}, socket) when is_list(ids) do
    ids = board_ids(socket, ids)
    Enum.each(ids, &Process.send_after(self(), {:settle_board, &1}, @settle_ms))

    {:noreply,
     socket
     |> update(:held, &MapSet.difference(&1, MapSet.new(ids)))
     |> update(:just_saved, &MapSet.union(&1, MapSet.new(ids)))
     |> assign(saved_notice: saved_notice(socket, ids))}
  end

  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, assign(socket, search: String.slice(String.trim(q), 0, 60))}

  def handle_event("toggle_mine", _params, socket),
    do:
      {:noreply, assign(socket, mine: not socket.assigns.mine and socket.assigns.my_range != nil)}

  def handle_event("dismiss_conflict", %{"id" => id}, socket),
    do: {:noreply, update(socket, :conflicts, &Map.delete(&1, to_int(id)))}

  def handle_event("filter_boards", %{"filter" => params}, socket) do
    range = {parse_board(params["from"]), parse_board(params["to"])}

    {:noreply,
     assign(socket,
       filter_form: to_form(Map.take(params, ["from", "to"]), as: :filter),
       filter_range: range
     )}
  end

  # Deputies correct filled boards, so they need the whole list back; helpers
  # cannot, so for them this is really "let me check what I already did".
  def handle_event("toggle_show_all", _params, socket) do
    {:noreply, assign(socket, show_all: not socket.assigns.show_all)}
  end

  def handle_event("set_result", _params, socket), do: {:noreply, socket}

  # A board a helper tapped that already carries a result is the refusal a
  # helper is actually likely to hit, mid-round, with players waiting - it
  # gets its own plain sentence rather than a generic "could not save" so
  # the next step ("find the arbiter") is obvious from the flash alone.
  defp permit_error_message(:already_set, pairing) do
    gettext("Board %{board} already has a result - only the arbiter can change it.",
      board: pairing.board
    )
  end

  defp permit_error_message(:board_out_of_range, pairing) do
    gettext("Board %{board} is outside the boards this phone is allowed to enter.",
      board: pairing.board
    )
  end

  defp permit_error_message(:earlier_round, _pairing) do
    gettext("Helpers can only enter results for the current round.")
  end

  defp button_label("*W", :postponed_white), do: gettext("* postponed by White")
  defp button_label("*B", :postponed_black), do: gettext("* postponed by Black")
  defp button_label(_value, label), do: label

  defp board_ids(socket, ids) do
    on_page = MapSet.new(socket.assigns.boards, & &1.id)

    ids
    |> Enum.map(&to_int/1)
    |> Enum.filter(&MapSet.member?(on_page, &1))
  end

  defp saved_notice(socket, ids) do
    socket.assigns.boards
    |> Enum.filter(&(&1.id in ids))
    |> Enum.map_join(" ", &gettext("Board %{board}: saved.", board: &1.board))
  end

  defp to_int(id) when is_integer(id), do: id

  defp to_int(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_int(_), do: nil

  defp parse_board(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_board(_), do: nil

  # The nine-squares mark, small, in the header: the middle column filled,
  # the centre in the accent (brand/marks/manubrium.svg).
  defp manubrium_mark(assigns) do
    ~H"""
    <svg class="mobile-mark" viewBox="0 0 24 24" aria-hidden="true">
      <rect x="2.6" y="2.6" width="4.8" height="4.8" class="mobile-mark-open" />
      <rect x="9" y="2" width="6" height="6" class="mobile-mark-fill" />
      <rect x="16.6" y="2.6" width="4.8" height="4.8" class="mobile-mark-open" />
      <rect x="2.6" y="9.6" width="4.8" height="4.8" class="mobile-mark-open" />
      <rect x="9" y="9" width="6" height="6" class="mobile-mark-accent" />
      <rect x="16.6" y="9.6" width="4.8" height="4.8" class="mobile-mark-open" />
      <rect x="2.6" y="16.6" width="4.8" height="4.8" class="mobile-mark-open" />
      <rect x="9" y="16" width="6" height="6" class="mobile-mark-fill" />
      <rect x="16.6" y="16.6" width="4.8" height="4.8" class="mobile-mark-open" />
    </svg>
    """
  end

  defp my_boards_label({from, nil}), do: gettext("My boards (%{from}+)", from: from)
  defp my_boards_label({nil, to}), do: gettext("My boards (up to %{to})", to: to)
  defp my_boards_label({from, to}), do: gettext("My boards (%{from}-%{to})", from: from, to: to)

  defp helper?(%Mobile.Enrollment{level: "helper"}), do: true
  defp helper?(%Mobile.Enrollment{}), do: false

  # The same gate every write in the app is refused by, rather than a second
  # reading of one of its two reasons. This was `archived_at` alone, so a
  # tournament handed to another machine still rendered its result buttons
  # enabled: the write was correctly refused server-side, but only after a
  # helper had tapped it, and only as gettext("Could not save that result.")
  defp read_only?(tournament), do: Tournaments.ensure_writable(tournament) != :ok

  # The audit row lives with the queued path's in `Mobile.log_result/6`, so
  # a tap and a queued tap are recorded in one shape.
  defp log_mobile_result(socket, pairing, previous, result) do
    Mobile.log_result(
      socket.assigns.mobile_enrollment,
      pairing,
      socket.assigns.round_number,
      previous,
      result
    )
  end

  # Boards still worth showing: everything unfinished, plus whatever was just
  # entered and is still being confirmed. `show_all?` overrides both.
  #
  # Clearing a result puts a board back among the unfinished ones on its own,
  # because "unfinished" is read from the result rather than remembered.
  #
  # The hall filter's range applies on top, whatever `show_all?` says.
  #
  # A search shows every board it finds, finished or not: whoever asks
  # "where is board 12" wants board 12, whatever it holds.
  defp visible_boards(assigns) do
    %{boards: boards, just_saved: just_saved, held: held, show_all: show_all?} = assigns
    {from, to} = assigns.filter_range

    {my_from, my_to} =
      if assigns.mine and assigns.my_range, do: assigns.my_range, else: {nil, nil}

    search = assigns.search

    boards
    |> Enum.filter(fn p ->
      (is_nil(from) or p.board >= from) and (is_nil(to) or p.board <= to) and
        (is_nil(my_from) or p.board >= my_from) and (is_nil(my_to) or p.board <= my_to)
    end)
    |> Enum.filter(fn p ->
      if search != "" do
        matches?(p, search)
      else
        show_all? or p.result in [nil, ""] or MapSet.member?(just_saved, p.id) or
          MapSet.member?(held, p.id)
      end
    end)
  end

  defp matches?(pairing, search) do
    case Integer.parse(search) do
      {n, ""} ->
        pairing.board == n

      _name ->
        needle = String.downcase(search)

        Enum.any?([pairing.white_player, pairing.black_player], fn
          %{name: name} when is_binary(name) -> String.contains?(String.downcase(name), needle)
          _ -> false
        end)
    end
  end

  # Since when this round has been going, and how we know: the moment its
  # pairings were published, or failing that the first report from a board
  # in the hall. A round that has neither has no clock - better none than
  # one counting from the moment the arbiter pressed "Pair".
  defp assign_round_clock(socket) do
    round = socket.assigns[:round]

    clock =
      cond do
        is_nil(round) ->
          nil

        match?(%DateTime{}, round.published_at) and
            DateTime.compare(round.published_at, DateTime.utc_now()) != :gt ->
          {round.published_at, :published}

        at = first_board_report(socket.assigns.tournament.id, round) ->
          {at, :board}

        true ->
          nil
      end

    assign(socket, round_clock: clock)
  end

  defp first_board_report(tournament_id, round) do
    uids = round.pairings |> Enum.map(& &1.game_uid) |> Enum.reject(&is_nil/1)

    case BoardLink.first_report_at(tournament_id, uids) do
      %DateTime{} = at -> at
      %NaiveDateTime{} = at -> DateTime.from_naive!(at, "Etc/UTC")
      _none -> nil
    end
  end

  defp elapsed(%DateTime{} = since, %DateTime{} = now) do
    minutes = max(div(DateTime.diff(now, since, :second), 60), 0)

    if minutes < 60,
      do: gettext("%{m} min", m: minutes),
      else: gettext("%{h} h %{m} min", h: div(minutes, 60), m: rem(minutes, 60))
  end

  defp shown_result(nil), do: gettext("no result")
  defp shown_result(""), do: gettext("no result")
  defp shown_result(result), do: String.replace(result, "1/2", "½")

  # The board in the hall against the result entered, when there are live
  # boards: `BoardLink.compare/2`, nothing more. It is never entered.
  defp board_state(nil, _pairing), do: :none

  defp board_state(reports, pairing),
    do: BoardLink.compare(pairing.result, Map.get(reports, pairing.game_uid))

  defp remaining_count(boards), do: Enum.count(boards, &(&1.result in [nil, ""]))

  defp load_round(socket, number) do
    tournament = socket.assigns.tournament
    enrollment = socket.assigns.mobile_enrollment
    round = Tournaments.get_round(tournament.id, number)

    boards =
      case round do
        nil ->
          []

        r ->
          r.pairings
          |> Enum.reject(&(&1.black_player_id == nil))
          # A board outside the enrollment's range is simply not here to
          # tap - the courtesy half of "hide what cannot be used"; the
          # enforcement half is `Mobile.permit_result/4`, reached via
          # `round.pairings` (unfiltered) rather than `@boards`, so a
          # crafted event naming an out-of-range pairing id is still
          # refused, not merely hidden.
          |> Enum.filter(&Mobile.board_in_range?(enrollment, &1.board))
          |> Enum.sort_by(& &1.board)
      end

    # Score shown alongside each name is the player's total entering this
    # round (same convention as a printed pairing sheet) - not their live
    # score once this round's own results start coming in.
    scores =
      tournament
      |> Standings.standings(through_round: number - 1)
      |> Map.new(&{&1.player.id, &1.points})

    # A conflict is about a board as it stood; once the board holds
    # something else again, or is gone, it has said what it had to say.
    conflicts =
      Map.filter(socket.assigns[:conflicts] || %{}, fn {id, c} ->
        Enum.any?(boards, &(&1.id == id and (&1.result || "") == c.current))
      end)

    socket
    |> assign(
      round_number: number,
      round: round,
      boards: boards,
      scores: scores,
      conflicts: conflicts,
      clearable: clearable_boards(enrollment, boards)
    )
    |> assign_round_clock()
  end

  # The boards this phone may be offered "Clear result" on: a deputy's, with
  # a result on them, that the write would not turn away
  # (`Tournaments.result_clearable?/1`: archived, handed off, a closed
  # FIDE-mode round, a result already sent, a match with a score). A helper
  # is fill-once, so none.
  defp clearable_boards(%Mobile.Enrollment{level: "deputy"} = enrollment, boards) do
    boards
    |> Enum.filter(fn p ->
      p.result not in [nil, ""] and Mobile.board_in_range?(enrollment, p.board) and
        Tournaments.result_clearable?(p)
    end)
    |> MapSet.new(& &1.id)
  end

  defp clearable_boards(_enrollment, _boards), do: MapSet.new()

  defp player_meta(nil, _scores), do: ""

  defp player_meta(player, scores) do
    rating = Player.rating(player)
    points = format_score(Map.get(scores, player.id, 0.0))

    [if(rating > 0, do: "#{rating}"), "#{points} pts"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp format_score(v) when is_float(v) do
    if v == Float.round(v, 0), do: trunc(v), else: v
  end

  defp format_score(v), do: v

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :visible, visible_boards(assigns))

    ~H"""
    <div class="mobile-shell">
      <header class="mobile-header">
        <div>
          <div class="mobile-brand">
            <.manubrium_mark /> <strong>Manubrium Lite</strong>
          </div>
          <%!-- The page's one heading: which tournament this phone is entering
                results for. --%>
          <h1 class="mobile-tname">{@tournament.name}</h1>
          <%!-- Sent, waiting, refused: kept by the queue in the browser,
                because it has to be right while this LiveView is
                unreachable. --%>
          <Manubrium.count />
        </div>
        <div class="mobile-header-actions">
          <%!-- Phone-side settings, kept by the phone (hook.js): the screen
                stays on while the round runs, and the controls move to
                where a thumb is. --%>
          <span id="manubrium-toggles" class="mq-toggles" phx-update="ignore">
            <button
              type="button"
              class="mobile-lock-btn mq-toggle"
              id="manubrium-wake"
              data-mq-wake
              aria-pressed="false"
              title={gettext("Keep the screen on")}
              aria-label={gettext("Keep the screen on")}
              hidden
            >
              <.icon name="hero-sun" class="size-5" />
            </button>
            <button
              type="button"
              class="mobile-lock-btn mq-toggle"
              id="manubrium-hand"
              data-mq-hand
              aria-pressed="false"
              title={gettext("One-handed layout")}
              aria-label={gettext("One-handed layout")}
            >
              <.icon name="hero-hand-raised" class="size-5" />
            </button>
          </span>
          <button
            type="button"
            class={["mobile-lock-btn", @locked && "active"]}
            phx-click="toggle_lock"
            title={if @locked, do: gettext("Unlock result entry"), else: gettext("Lock result entry")}
            aria-label={
              if @locked, do: gettext("Unlock result entry"), else: gettext("Lock result entry")
            }
          >
            {if @locked, do: "🔒", else: "🔓"}
          </button>
          <Layouts.theme_switch />
          <.link href={~p"/m/leave"} class="mobile-leave" id="mobile-leave" data-mq-leave>
            {gettext("Leave")}
          </.link>
        </div>
      </header>

      <%!-- This screen has no `<Layouts.app>` (it is a deliberately bare
            kiosk shell, not the full desktop chrome), so it never got a
            flash outlet of its own - `put_flash/3` below was writing to
            `@flash` with nowhere on THIS page to show it. That was already
            true for "this tournament is archived" before the guards on this
            page existed; it would have been true for every refusal added
            here too. --%>
      <Layouts.flash_group flash={@flash} />

      <Manubrium.outbox />

      <%!-- `<main>` for the root layout's skip link, which this bare shell had
            nowhere to send; and the status line a screen reader hears each
            save through - always on the page, so a change to its text is
            announced. It is also the queue's hook: taps on the boards inside
            it become entries (assets/js/manubrium/hook.js). --%>
      <main
        id="main-content"
        tabindex="-1"
        phx-hook="Manubrium"
        data-enrollment={@mobile_enrollment.id}
      >
        <p class="sr-only" role="status">{@saved_notice}</p>

        <%!-- A helper is pinned to the latest paired round (`Mobile.permit_round/3`)
            and has no other round to switch to - showing a switcher with
            every earlier round disabled/hidden but one lone "current round"
            button in it would just be a button that does nothing, so the
            whole strip is left off rather than hidden-but-half-there. --%>
        <div :if={@paired > 1 and not helper?(@mobile_enrollment)} class="mobile-rounds">
          <button
            :for={n <- 1..@paired}
            type="button"
            class={["mobile-round-btn", n == @round_number && "active"]}
            aria-pressed={to_string(n == @round_number)}
            phx-click="select_round"
            phx-value-number={n}
          >
            R{n}
          </button>
        </div>

        <p :if={@round_clock} class="mobile-clock" id="round-clock">
          <%= case @round_clock do %>
            <% {since, :published} -> %>
              {gettext("Round going for %{time} (since the pairings were published)",
                time: elapsed(since, @now)
              )}
            <% {since, :board} -> %>
              {gettext("Round going for %{time} (since the first board reported)",
                time: elapsed(since, @now)
              )}
          <% end %>
        </p>

        <p class="mobile-hint">
          {gettext("Round %{n}", n: @round_number)} ·
          <%= if @locked do %>
            🔒 {gettext("locked - tap the lock to enter results")}
          <% else %>
            {gettext("tap a result for each board")}
          <% end %>
        </p>

        <div :if={@boards == []} class="mobile-empty">
          {gettext("No boards paired for this round yet.")}
        </div>

        <%!-- Finished boards drop out of the list as they are entered, so what
            is left on screen is what is left to do. The count is the honest
            version of that: a helper wants to know how many are outstanding,
            not how many exist. --%>
        <form
          :if={@boards != []}
          id="hall-search"
          class="mobile-search"
          phx-change="search"
          phx-submit="search"
          role="search"
        >
          <input
            type="search"
            name="q"
            value={@search}
            id="hall-search-input"
            placeholder={gettext("Name or board number")}
            aria-label={gettext("Find a player or a board")}
            autocomplete="off"
            phx-debounce="250"
            class="mobile-search-input"
          />
          <button
            :if={@my_range}
            type="button"
            id="hall-mine"
            class={["mobile-filter-btn", @mine && "active"]}
            aria-pressed={to_string(@mine)}
            phx-click="toggle_mine"
          >
            {my_boards_label(@my_range)}
          </button>
        </form>

        <div :if={@boards != []} class="mobile-filter">
          <span class="mobile-filter-count">
            <%= case remaining_count(@boards) do %>
              <% 0 -> %>
                {gettext("All results in")}
              <% 1 -> %>
                {gettext("1 board left")}
              <% n -> %>
                {gettext("%{n} boards left", n: n)}
            <% end %>
          </span>

          <button type="button" class="mobile-filter-btn" phx-click="toggle_show_all">
            {if @show_all, do: gettext("Hide finished"), else: gettext("Show all")}
          </button>
        </div>

        <%!-- The hall view's range: "my room is boards 21-40". Narrows what is
              shown, never what is allowed - that is the enrolment's range,
              checked on every write. Only offered where there are enough
              boards for it to matter. --%>
        <.form
          :if={length(@boards) > 6}
          for={@filter_form}
          id="hall-filter"
          class="mobile-range"
          phx-change="filter_boards"
          phx-submit="filter_boards"
        >
          <span class="mobile-range-label">{gettext("Boards")}</span>
          <.input
            field={@filter_form[:from]}
            type="number"
            min="1"
            inputmode="numeric"
            placeholder={gettext("from")}
            aria-label={gettext("First board to show")}
            class="mobile-range-input"
            phx-debounce="300"
          />
          <span aria-hidden="true">–</span>
          <.input
            field={@filter_form[:to]}
            type="number"
            min="1"
            inputmode="numeric"
            placeholder={gettext("to")}
            aria-label={gettext("Last board to show")}
            class="mobile-range-input"
            phx-debounce="300"
          />
        </.form>

        <div :if={@boards != [] and @visible == []} class="mobile-empty">
          <%= if @search != "" do %>
            {gettext("No board matches \"%{search}\".", search: @search)}
          <% else %>
            <%= if @filter_range == {nil, nil} and not @mine do %>
              {gettext("Every board in this round has a result. Tap \"Show all\" to look them over.")}
            <% else %>
              {gettext("No open boards in that range.")}
            <% end %>
          <% end %>
        </div>

        <%!-- Keyed by id, so LiveView keeps each board's own elements when a
            finished board drops out of the list: matched by position, the
            buttons of the board below were being reused for the board that
            left, focus included. Each row of result buttons is a group named
            for its board and players, and the recorded result is
            `aria-pressed` - it was a colour.

            The `data-*` on the board are what a queued entry is made of:
            where it is, who sits there, and what the phone believes the
            board holds (the compare-and-set in `Mobile.Sync`). --%>
        <div
          :for={p <- @visible}
          id={"mobile-board-#{p.id}"}
          class={["mobile-board", MapSet.member?(@just_saved, p.id) && "just-saved"]}
          phx-hook=".KeepFocus"
          data-pairing={p.id}
          data-board={p.board}
          data-round={@round_number}
          data-white={p.white_player_id}
          data-black={p.black_player_id}
          data-result={p.result}
        >
          <div class="mobile-board-head">
            <span class="mobile-board-no" id={"mobile-board-#{p.id}-no"}>
              {gettext("Board %{board}", board: p.board)}
            </span>
            <span
              id={"mobile-board-#{p.id}-status"}
              class={["mobile-status", if(p.result in [nil, ""], do: "playing", else: "finished")]}
            >
              {if p.result in [nil, ""], do: gettext("Playing"), else: gettext("Finished")}
            </span>
            <span id={"mobile-board-#{p.id}-queue"} phx-update="ignore" data-mq-badge></span>
            <button
              type="button"
              id={"mobile-incident-#{p.id}"}
              class="mobile-incident-btn"
              disabled={@locked}
              data-incident
              aria-label={
                if helper?(@mobile_enrollment),
                  do: gettext("Call the arbiter to board %{board}", board: p.board),
                  else: gettext("Log an incident on board %{board}", board: p.board)
              }
            >
              {if helper?(@mobile_enrollment), do: gettext("Call arbiter"), else: gettext("Incident")}
            </button>
          </div>
          <%!-- Two entries disagreed about this board; the one that stands is
                on it, the other was refused. Both phones see this. --%>
          <div
            :if={c = @conflicts[p.id]}
            id={"mobile-conflict-#{p.id}"}
            class="mobile-conflict"
            role="alert"
          >
            <span>
              {gettext(
                "Two entries disagree: %{entered} was refused, the board holds %{current}. Settle it between you before anyone changes it.",
                entered: shown_result(c.entered),
                current: shown_result(c.current)
              )}
            </span>
            <button
              type="button"
              class="mobile-conflict-ok"
              phx-click="dismiss_conflict"
              phx-value-id={p.id}
            >
              {gettext("OK")}
            </button>
          </div>

          <%!-- What the board in the hall saw, beside what was entered. A
                warning, never an entry: nothing here writes it. --%>
          <div
            :if={(state = board_state(@board_reports, p)) != :none}
            id={"mobile-board-#{p.id}-report"}
            class={["mobile-report", to_string(state)]}
            data-state={state}
          >
            <%= case state do %>
              <% :live -> %>
                {gettext("Board: playing")}
              <% :pending -> %>
                {gettext("Board saw %{result} - not entered yet",
                  result: shown_result(@board_reports[p.game_uid].result)
                )}
              <% :match -> %>
                {gettext("Board saw the same result")}
              <% :mismatch -> %>
                <.icon name="hero-exclamation-triangle" class="size-4" />
                {gettext("Board saw %{board}, entered %{entered} - check it",
                  board: shown_result(@board_reports[p.game_uid].result),
                  entered: shown_result(p.result)
                )}
            <% end %>
          </div>

          <div class="mobile-players">
            <div class="mobile-side">
              <span class="mobile-white" id={"mobile-board-#{p.id}-white"}>
                {p.white_player && p.white_player.name}
              </span>
              <span class="mobile-meta">{player_meta(p.white_player, @scores)}</span>
            </div>
            <span class="mobile-vs">{gettext("vs")}</span>
            <div class="mobile-side mobile-side--black">
              <span class="mobile-black" id={"mobile-board-#{p.id}-black"}>
                {p.black_player && p.black_player.name}
              </span>
              <span class="mobile-meta">{player_meta(p.black_player, @scores)}</span>
            </div>
          </div>
          <div
            class="mobile-results"
            role="group"
            aria-labelledby={"mobile-board-#{p.id}-no mobile-board-#{p.id}-white mobile-board-#{p.id}-black"}
          >
            <button
              :for={{value, label} <- @results}
              type="button"
              disabled={@locked || @read_only?}
              class={["mobile-result-btn", p.result == value && "chosen"]}
              aria-pressed={to_string(p.result == value)}
              phx-click="set_result"
              phx-value-id={p.id}
              phx-value-result={value}
              phx-value-expected={p.result || ""}
              data-entry={value}
            >
              {label}
            </button>
            <button
              type="button"
              disabled={@locked || @read_only?}
              class={["mobile-result-btn", "mobile-more", @expanded_id == p.id && "chosen"]}
              phx-click="toggle_extra"
              phx-value-id={p.id}
            >
              {if @expanded_id == p.id, do: gettext("▲ Less"), else: gettext("▼ More")}
            </button>
          </div>

          <%!-- Deputies only, and only where the clear would be accepted.
              Two taps: the first arms the button, the second clears. Never
              queued: taking a result away waits for a connection. --%>
          <div :if={MapSet.member?(@clearable, p.id)} class="mobile-clear-row">
            <button
              type="button"
              id={"mobile-clear-#{p.id}"}
              disabled={@locked || @read_only?}
              class={["mobile-clear-btn", @confirm_clear == p.id && "confirming"]}
              phx-click="clear_result"
              phx-value-id={p.id}
            >
              <%= if @confirm_clear == p.id do %>
                {gettext("Tap again to clear board %{board}", board: p.board)}
              <% else %>
                {gettext("Clear result")}
              <% end %>
            </button>
          </div>

          <%!-- Forfeits and the asymmetric disciplinary codes - rare, so
              tucked here instead of cluttering every board's default three
              buttons. Stays open if that's already this board's own
              recorded result, so "what's currently set" is never hidden
              behind a tap the arbiter has no reason to make. --%>
          <div
            :if={@expanded_id == p.id or (p.result != "" and p.result not in ~w(1-0 1/2-1/2 0-1))}
            class="mobile-results mobile-results--extra"
          >
            <button
              :for={{value, label} <- @extra_results}
              :if={value not in ~w(*W *B) or Tournament.postponed_allowed?(@tournament)}
              type="button"
              disabled={@locked || @read_only?}
              class={["mobile-result-btn", p.result == value && "chosen"]}
              aria-pressed={to_string(p.result == value)}
              phx-click="set_result"
              phx-value-id={p.id}
              phx-value-result={value}
              phx-value-expected={p.result || ""}
              data-entry={value}
            >
              {button_label(value, label)}
            </button>
          </div>
        </div>

        <Manubrium.incident_dialog level={@mobile_enrollment.level} />
      </main>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".KeepFocus">
        // A board leaves the list a moment after its result is entered, and
        // takes with it the button that entered it - the one with focus. Left
        // there, focus falls to the page itself and a screen reader or a
        // keyboard starts again from the top. So the board that had focus
        // hands it on as it goes: to the board that moves up into its place,
        // the last one if it was last, or the page's main region if none are
        // left ("All results in").
        export default {
          mounted() {
            this.onFocus = () => {
              const boards = Array.from(document.querySelectorAll(".mobile-board"));
              window.peBoardFocus = { id: this.el.id, index: boards.indexOf(this.el) };
            };
            this.el.addEventListener("focusin", this.onFocus);

            // Focus that LEFT the board - to another board, the header, or the
            // page itself after a tap on empty space - is no longer this
            // board's to hand on. Checked a tick later, because a board being
            // removed can report focus leaving too: then it is no longer in the
            // page, the record stays, and `destroyed` hands focus on as meant.
            // Without this, a board entered by another phone could pull focus
            // back from wherever the arbiter had since put it.
            this.onBlur = () => {
              setTimeout(() => {
                if (!this.el.isConnected || this.el.contains(document.activeElement)) return;
                if (window.peBoardFocus && window.peBoardFocus.id === this.el.id) {
                  window.peBoardFocus = null;
                }
              }, 0);
            };
            this.el.addEventListener("focusout", this.onBlur);
          },

          destroyed() {
            const last = window.peBoardFocus;
            if (!last || last.id !== this.el.id) return;
            window.peBoardFocus = null;

            requestAnimationFrame(() => {
              const active = document.activeElement;
              if (active && active !== document.body) return;
              // Gone with the whole page (a navigation), not just this board.
              if (!document.querySelector(".mobile-shell")) return;

              const boards = Array.from(document.querySelectorAll(".mobile-board"));
              const board = boards[Math.min(last.index, boards.length - 1)];
              const target =
                (board && board.querySelector("button:not([disabled])")) ||
                document.getElementById("main-content");

              if (target) target.focus();
            });
          }
        };
      </script>
    </div>
    """
  end
end
