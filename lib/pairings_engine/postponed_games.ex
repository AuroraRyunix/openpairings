defmodule PairingsEngine.PostponedGames do
  @moduledoc """
  Postponed and adjourned games: a board whose game was paired and has not
  been played yet (VCL4THP Q157-169, `docs/design-fide-mode.md` Phase 5).

  ## What a postponed game is

  In club play a game is often not played in its round - moved by agreement
  to a later evening, or adjourned - while the tournament goes on. The board
  carries `PairingsEngine.Results.postponed/0` (`"*"`): result unknown, game
  still to be played. It is not a blank. A blank is a board nobody has
  reported on and stops the next round from being paired; `"*"` is the
  arbiter saying "this one is known to be open".

  What it is worth is decided in exactly one place, the `PairingsEngine.Results`
  table, which classifies it as a draw for both players. So the crosstable,
  the tie-breaks, the pairing engine's score brackets and every export read
  the same half point, and there is no second result-to-points mapping to
  drift from the first (the shape that caused three bugs before 0.17.1).
  When the real result is entered, everything recomputes from it.

  ## What this module adds

    * which games are open (`open_games/1`), for the pages that list them
      and for anything that must not call itself final while one is;
    * the warnings, as codes (`warnings/0`). Sentences live in the web layer
      (`PairingsEngineWeb.PostponedText`), the same split
      `PairingsEngine.Compliance` keeps, so a warning can be translated and
      so a FIDE warning level can be attached to each entry later without
      touching what fires it;
    * the checks the two write paths ask before they act:
      `pairing_warnings/1` before a round is paired, `result_warnings/2`
      before a result is written over a postponed game.

  ## The warnings and their levels

  VCL4THP asks for some of these at a "Level 2" or "Level 3". The levels are
  not defined anywhere this project can read yet (`docs/design-fide-mode.md`,
  Phase 0 and Phase 4), so none is guessed here: every warning is an ordinary
  confirmation or notice, identified by an id naming its VCL question. When
  the levels exist they become one more key per entry of `@warnings`.
  """

  import Ecto.Query

  alias PairingsEngine.{Repo, Results}
  alias PairingsEngine.Tournaments.{Pairing, Round, Tournament}

  # One entry per warning. `vcl` is the VCL4THP v13 question it answers;
  # `acknowledge?` is whether the action it guards waits for the arbiter to
  # confirm it (the write path refuses with `{:needs_acknowledgement, ids}`
  # until they have), as opposed to a notice shown beside the action.
  @warnings [
    %{id: :adjourned_non_draw_result, vcl: [163], acknowledge?: true},
    %{id: :missing_results_recorded_as_adjourned, vcl: [159, 160], acknowledge?: true},
    %{id: :adjourned_older_round_open, vcl: [168], acknowledge?: true},
    %{id: :adjourned_counted_as_draw, vcl: [158, 167], acknowledge?: false},
    %{id: :adjourned_standings_not_final, vcl: [161, 169], acknowledge?: false},
    %{id: :adjourned_trf_not_final, vcl: [164, 165, 169], acknowledge?: false},
    # Not a VCL question: a result that already went to the federation in a
    # TRF marked as sent (see `finalise/2`). The rule above every other one
    # here is that no wrong TRF data is ever sent, so changing a sent
    # result is possible - "semi-frozen" - but never silent.
    %{id: :finalised_result_changed, vcl: [], acknowledge?: true}
  ]

  @doc "Every warning this feature can raise, with the VCL question it answers."
  def warnings, do: @warnings

  @doc "The ids of the warnings an action waits on the arbiter to confirm."
  def acknowledgement_ids do
    for %{acknowledge?: true, id: id} <- @warnings, do: id
  end

  @doc """
  Every open postponed game in `tournament`, oldest round first, as
  `%{round: n, pairing: %Pairing{}}` with both players preloaded.
  """
  def open_games(%Tournament{id: id}), do: open_games(id)

  def open_games(tournament_id) when is_integer(tournament_id) do
    postponed = Results.postponed_codes()

    Repo.all(
      from p in Pairing,
        join: r in Round,
        on: p.round_id == r.id,
        where: r.tournament_id == ^tournament_id and p.result in ^postponed,
        order_by: [r.number, p.board],
        preload: [:white_player, :black_player],
        select: %{round: r.number, pairing: p}
    )
  end

  @doc "How many postponed games are still open in `tournament`."
  def open_count(%Tournament{id: id}), do: open_count(id)

  def open_count(tournament_id) when is_integer(tournament_id) do
    postponed = Results.postponed_codes()

    Repo.aggregate(
      from(p in Pairing,
        join: r in Round,
        on: p.round_id == r.id,
        where: r.tournament_id == ^tournament_id and p.result in ^postponed
      ),
      :count
    )
  end

  @doc """
  Whether anything computed from `tournament`'s results may call itself
  final: `false` while a postponed game is open, whatever round it is in.
  """
  def final?(tournament), do: open_count(tournament) == 0

  @doc """
  The warnings that apply to pairing `tournament`'s next round, as
  `%{id: atom, ...details}` maps.

    * `:missing_results_recorded_as_adjourned` - the last paired round
      still has boards with two players and no result. Pairing records them
      as postponed first (Q159) once the arbiter has confirmed it (Q160).
      Offered only when that would complete the round: a vacated seat has
      no second player to postpone a game with, and still has to be
      resolved on the board first.
    * `:adjourned_older_round_open` - a postponed game from a round before
      the last paired one is still open (Q168).
    * `:adjourned_counted_as_draw` - a postponed game in the last paired
      round; a notice that it counts as a draw for this pairing (Q158, Q167).

  Empty for a round robin, whose schedule does not depend on results, and
  before round 1. `open` is `open_games/1`'s answer when the caller already
  has it (the Pairings page lists the same games), so it is not asked twice.
  """
  def pairing_warnings(tournament, open \\ nil)

  def pairing_warnings(%Tournament{pairing_system: "round_robin"}, _open), do: []

  def pairing_warnings(%Tournament{} = tournament, open) do
    last = last_paired_round(tournament.id)

    cond do
      last == 0 ->
        []

      # Recording a board as postponed is only offered where postponed games
      # are allowed at all; elsewhere a blank still simply blocks pairing.
      not tournament.postponed_games ->
        open_warnings(open || open_games(tournament.id), last)

      true ->
        missing_warning(tournament.id, last) ++
          open_warnings(open || open_games(tournament.id), last)
    end
  end

  defp missing_warning(tournament_id, last) do
    blanks =
      Repo.all(
        from p in Pairing,
          join: r in Round,
          on: p.round_id == r.id,
          where: r.tournament_id == ^tournament_id and r.number == ^last and p.result == "",
          select: {p.white_player_id, p.black_player_id}
      )

    cond do
      blanks == [] -> []
      Enum.any?(blanks, fn {w, b} -> is_nil(w) or is_nil(b) end) -> []
      true -> [%{id: :missing_results_recorded_as_adjourned, round: last, count: length(blanks)}]
    end
  end

  defp open_warnings(open, last) do
    {older, current} = Enum.split_with(open, &(&1.round < last))

    older_warning =
      if older == [],
        do: [],
        else: [
          %{
            id: :adjourned_older_round_open,
            rounds: older |> Enum.map(& &1.round) |> Enum.uniq(),
            count: length(older)
          }
        ]

    current_warning =
      if current == [],
        do: [],
        else: [%{id: :adjourned_counted_as_draw, round: last, count: length(current)}]

    older_warning ++ current_warning
  end

  defp last_paired_round(tournament_id) do
    Repo.one(from r in Round, where: r.tournament_id == ^tournament_id, select: max(r.number)) ||
      0
  end

  @doc """
  The warnings that apply to writing `result` over the board as it is
  STORED now - read fresh, because the struct a page holds can be older
  than the database, and a stale blank must not hide a postponed game.

  `:adjourned_non_draw_result` (Q163), when a postponed game gets a result
  that is not a draw for both players. Every round paired since counted it
  as its provisional score, and those pairings stand; the arbiter confirms
  that they know. A draw, clearing the board and re-postponing it need no
  confirmation.

  `:finalised_result_changed`, when the board was already sent in a TRF
  marked as sent and the result would change: possible, never silent.
  """
  def result_warnings(%Pairing{id: id}, result) do
    stored = Repo.get!(Pairing, id)

    non_draw? =
      Results.postponed?(stored.result) and result not in ["", nil] and
        not Results.postponed?(result) and not Results.draw_for_both?(result)

    # A board already sent in a finalised TRF, with the result it was sent
    # with. An open postponed game sent as `?` is the exception: its real
    # result is still to come, and goes in the postponed-games file - after
    # which it is sent too.
    sent_changed? =
      result != stored.result and
        ((not is_nil(stored.finalised_at) and not stored.finalised_open) or
           not is_nil(stored.postponed_reported_at))

    if(non_draw?, do: [:adjourned_non_draw_result], else: []) ++
      if sent_changed?, do: [:finalised_result_changed], else: []
  end

  @doc """
  `:ok` when every warning in `warnings` (ids or `%{id: ...}` maps) that
  waits on the arbiter is in `acknowledged`, otherwise
  `{:error, {:needs_acknowledgement, ids}}` naming the ones that are not.
  Notices are never waited on.
  """
  def check_acknowledged(warnings, acknowledged) do
    missing =
      warnings
      |> Enum.map(&warning_id/1)
      |> Enum.filter(&(&1 in acknowledgement_ids()))
      |> Enum.reject(&(&1 in acknowledged))
      |> Enum.uniq()

    if missing == [], do: :ok, else: {:error, {:needs_acknowledgement, missing}}
  end

  defp warning_id(%{id: id}), do: id
  defp warning_id(id) when is_atom(id), do: id

  @doc """
  Records every two-player board of `round_number` that has no result as a
  postponed game (Q159), through `Tournaments.update_pairing_result/3` like
  every other result write. Returns `{:ok, pairing_ids}` - the boards it
  wrote, so a pairing run that then fails can put them back with
  `clear/1` - or the first write's error.
  """
  def record_missing(%Tournament{} = tournament, round_number) do
    blanks =
      Repo.all(
        from p in Pairing,
          join: r in Round,
          on: p.round_id == r.id,
          where:
            r.tournament_id == ^tournament.id and r.number == ^round_number and p.result == "" and
              not is_nil(p.white_player_id) and not is_nil(p.black_player_id)
      )

    Enum.reduce_while(blanks, {:ok, []}, fn pairing, {:ok, ids} ->
      case PairingsEngine.Tournaments.update_pairing_result(pairing, Results.postponed()) do
        {:ok, _} -> {:cont, {:ok, [pairing.id | ids]}}
        {:error, reason} -> {:halt, {:error, reason, ids}}
      end
    end)
    |> case do
      {:ok, ids} ->
        {:ok, Enum.reverse(ids)}

      # One write refused (a locked database, a hand-off landing mid-run):
      # the boards already recorded go back too, so a refusal leaves the
      # round exactly as the arbiter left it.
      {:error, reason, ids} ->
        clear(ids)
        {:error, reason}
    end
  end

  @doc """
  Puts boards `record_missing/2` postponed back to no result - the undo for
  a pairing run that failed after the missing results were recorded, so a
  refused round leaves the tournament exactly as it found it.
  """
  def clear(pairing_ids) do
    for pairing <- Repo.all(from p in Pairing, where: p.id in ^pairing_ids),
        Results.postponed?(pairing.result),
        is_nil(pairing.finalised_at) do
      PairingsEngine.Tournaments.update_pairing_result(pairing, "")
    end

    :ok
  end

  ## ---------- sending results: finalise, and the postponed-games file ----------
  #
  # The rule above every other one here: no wrong TRF data is ever sent, and
  # no game is sent twice. Two records make that checkable rather than a
  # matter of care:
  #
  #   * `finalised_at` - the board went into a TRF the arbiter downloaded "for
  #     sending". Its result is then semi-frozen: changing it asks first
  #     (`:finalised_result_changed`).
  #   * `finalised_open` - it was an open postponed game at that moment, so
  #     it went out as `?`. Every later main report writes it as `?` again,
  #     so a file already sent never changes; its real result, once played,
  #     goes in the postponed-games file (`sendable_late_games/1`), and
  #     `postponed_reported_at` records that it has been sent there - once.

  @doc """
  Marks every board of `rounds` as sent (see the section above). Refuses,
  writing nothing, while any of those boards has no result at all (a file
  for sending must not carry a gap nobody decided about), or when one of
  those rounds was already finalised: its games have been sent, and a second
  file with them would send them twice. Downloading without finalising is
  always possible, to see or keep a copy.

  Returns `{:ok, newly_marked}`, `{:error, {:already_sent, rounds}}` or
  `{:error, {:blank_results, rounds}}`.
  """
  def finalise(%Tournament{} = tournament, rounds) when is_list(rounds) do
    sent_rounds =
      Repo.all(
        from p in Pairing,
          join: r in Round,
          on: p.round_id == r.id,
          where:
            r.tournament_id == ^tournament.id and r.number in ^rounds and
              not is_nil(p.finalised_at),
          distinct: true,
          select: r.number
      )

    blank_rounds =
      Repo.all(
        from p in Pairing,
          join: r in Round,
          on: p.round_id == r.id,
          where: r.tournament_id == ^tournament.id and r.number in ^rounds and p.result == "",
          distinct: true,
          select: r.number
      )

    cond do
      sent_rounds != [] ->
        {:error, {:already_sent, Enum.sort(sent_rounds)}}

      blank_rounds != [] ->
        {:error, {:blank_results, Enum.sort(blank_rounds)}}

      true ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        ids =
          Repo.all(
            from p in Pairing,
              join: r in Round,
              on: p.round_id == r.id,
              where:
                r.tournament_id == ^tournament.id and r.number in ^rounds and
                  is_nil(p.finalised_at),
              select: {p.id, p.result}
          )

        # Compared here, not in SQL: SQLite hands a boolean back as 0 or 1.
        {open, known} = Enum.split_with(ids, &Results.postponed?(elem(&1, 1)))
        mark(Enum.map(open, &elem(&1, 0)), finalised_at: now, finalised_open: true)
        mark(Enum.map(known, &elem(&1, 0)), finalised_at: now, finalised_open: false)
        {:ok, length(ids)}
    end
  end

  defp mark([], _set), do: :ok

  defp mark(ids, set) do
    Repo.update_all(from(p in Pairing, where: p.id in ^ids), set: set)
    :ok
  end

  @doc """
  The numbers of the rounds of `tournament` already finalised for sending,
  in order - the ones `finalise/2` refuses a second time.
  """
  def sent_rounds(%Tournament{id: id}) do
    Repo.all(
      from p in Pairing,
        join: r in Round,
        on: p.round_id == r.id,
        where: r.tournament_id == ^id and not is_nil(p.finalised_at),
        distinct: true,
        order_by: r.number,
        select: r.number
    )
  end

  @doc """
  Every postponed game ever recorded in `tournament` - open, played in time
  for its round's report, or played later - as `%{round:, pairing:}`, oldest
  round first. A board counts as postponed once it has carried a
  provisional outcome, which is stamped when it is postponed and kept.
  """
  def all_games(%Tournament{id: id}) do
    Repo.all(
      from p in Pairing,
        join: r in Round,
        on: p.round_id == r.id,
        where: r.tournament_id == ^id and not is_nil(p.provisional_white),
        order_by: [r.number, p.board],
        preload: [:white_player, :black_player],
        select: %{round: r.number, pairing: p}
    )
  end

  @doc """
  The games the postponed-games TRF carries: sent as `?` in a finalised main
  report (`finalised_open`), played since (a real result, not `*`), and not
  yet sent in a postponed-games file.
  """
  def sendable_late_games(%Tournament{id: id}) do
    unplayed = ["", "bye" | Results.postponed_codes()]

    Repo.all(
      from p in Pairing,
        join: r in Round,
        on: p.round_id == r.id,
        where:
          r.tournament_id == ^id and p.finalised_open == true and
            p.result not in ^unplayed and is_nil(p.postponed_reported_at) and
            not is_nil(p.white_player_id) and not is_nil(p.black_player_id),
        order_by: [p.played_on, r.number, p.board],
        preload: [:white_player, :black_player],
        select: %{round: r.number, pairing: p}
    )
  end

  @doc "Records that `games` (from `sendable_late_games/1`) were sent."
  def mark_late_games_sent(games) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    mark(Enum.map(games, & &1.pairing.id), postponed_reported_at: now)
  end

  # Past this many placements the exact search gives up and first-fit
  # stands. A club's postponed games number in the tens, where the search
  # finishes instantly; the cap only keeps a pathological input from
  # hanging a download.
  @pack_budget 200_000

  @doc """
  Packs `games` (anything with `white_player_id` and `black_player_id`, in
  the order they should come - by date played) into as few rounds as
  possible with nobody playing twice in one round. Returns a list of rounds,
  each a list of games in input order.

  The fewest rounds possible is at least the most games any one player has.
  That many is tried first, then one more at a time, by exhaustive search
  within a budget; if the budget runs out, first-fit in date order is used,
  which is never wrong - only possibly one round longer than it had to be.
  """
  def pack([]), do: []

  def pack(games) do
    lower =
      games
      |> Enum.flat_map(&[&1.white_player_id, &1.black_player_id])
      |> Enum.frequencies()
      |> Map.values()
      |> Enum.max()

    Enum.find_value(lower..length(games), fn k -> exact_pack(games, k) end) ||
      first_fit(games)
  end

  defp exact_pack(games, k) do
    Process.put(:pack_budget, @pack_budget)
    slots = List.duplicate(MapSet.new(), k)

    case place(games, slots, []) do
      {:ok, assignment} -> to_rounds(games, Enum.reverse(assignment), k)
      :none -> nil
    end
  end

  defp place([], _slots, acc), do: {:ok, acc}

  defp place([game | rest], slots, acc) do
    budget = Process.get(:pack_budget) - 1
    Process.put(:pack_budget, budget)

    if budget < 0 do
      :none
    else
      slots
      |> Enum.with_index()
      |> Enum.find_value(:none, fn {used, i} ->
        if MapSet.member?(used, game.white_player_id) or
             MapSet.member?(used, game.black_player_id) do
          nil
        else
          used = used |> MapSet.put(game.white_player_id) |> MapSet.put(game.black_player_id)

          case place(rest, List.replace_at(slots, i, used), [i | acc]) do
            {:ok, _} = ok -> ok
            :none -> nil
          end
        end
      end)
    end
  end

  defp first_fit(games) do
    {rounds, _used} =
      Enum.reduce(games, {[], []}, fn game, {rounds, used} ->
        free =
          Enum.find_index(used, fn set ->
            not MapSet.member?(set, game.white_player_id) and
              not MapSet.member?(set, game.black_player_id)
          end)

        pair = MapSet.new([game.white_player_id, game.black_player_id])

        case free do
          nil ->
            {rounds ++ [[game]], used ++ [pair]}

          i ->
            {List.update_at(rounds, i, &(&1 ++ [game])),
             List.update_at(used, i, &MapSet.union(&1, pair))}
        end
      end)

    rounds
  end

  defp to_rounds(games, assignment, k) do
    by_round = games |> Enum.zip(assignment) |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    for i <- 0..(k - 1), games = Map.get(by_round, i, []), games != [], do: games
  end
end
