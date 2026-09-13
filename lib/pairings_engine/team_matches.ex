defmodule PairingsEngine.TeamMatches do
  @moduledoc """
  What an arbiter does to a team match after it is paired: forfeit it by
  decision, and put a board added by hand into it. See
  `docs/team-tournaments.md`.

  ## A match forfeited by decision

  `forfeit_match/3` awards a match to one team: every board of it becomes the
  forfeit result for that team (`1-0FF` where it has White, `0-1FF` where it
  has Black), the decision is recorded on the match (`forfeited_to_team_id`),
  and the results the boards held before are kept
  (`forfeit_previous_results`, by board number). `withdraw_forfeit/2` puts
  them back - the same thing as retyping them, done in one action, which is
  how a result is undone anywhere else in the app.

  What such a match then counts as, and why:

    * **The pairing-allocated bye ([C2], C.04.6 Art. 2.1.2)** - the team it
      was awarded to has "won a match by forfeit" and cannot take the bye
      (`TeamSwiss.won_match_by_forfeit?/1`). The research note on open
      question 6 gives this reading medium confidence: a match-level forfeit
      status an arbiter sets (Swiss-Manager's match "Forfeit" and TRF-2026's
      record 330 both have one), and the bye barred on that status.
    * **A meeting, and colours ([C1], C.04.2 Art. 3.5, C.04.6 Art. 1.6.1)** -
      when at least one game had been played before the decision, the teams
      did play: they have met, and their board-1 colours count. A decision
      over a match nobody sat down to leaves it unplayed, exactly as the
      boards already say.
    * **Tie-breaks (C.07 Art. 15.1, 16)** - "an unplayed round is any round in
      which a participant ... did not play a match". A match with games
      played before the decision was played, so it is not an Article 16
      unplayed round: opponents' Buchholz reads it as the awarded match
      points, like any other played match.

  ## A board added by hand

  A board added from the pool of a round paired as teams belongs to a match
  only when it fits one (`slot_at/5`): its two players are on that match's
  two teams, its board number is one of the match's free boards, the team
  named first has White on the odd boards of it, and both players' board
  orders sit between the boards already there. `fitting_slot/4` finds the
  first such place for two players; `attach_board/3` moves an existing
  board into it. A board that fits nowhere stays outside every match and
  counts for neither team, and the Pairings page says so.
  """

  import Ecto.Query

  alias PairingsEngine.{Repo, Results, TeamRounds, Tournaments}
  alias PairingsEngine.Tournaments.{Match, Pairing, Player, Round, Tournament}

  ## ---------- forfeit by decision ----------

  @doc """
  Forfeits `match` to the team `winner_team_id`: every board becomes that
  team's forfeit win, and the decision and the boards' previous results are
  recorded. `{:ok, match}` or `{:error, reason}` - `:bye_match`,
  `:not_in_match`, `:already_forfeited`, `:no_boards`, or the writability
  refusal.
  """
  def forfeit_match(%Tournament{} = t, %Match{} = match, winner_team_id) do
    boards = match_boards(match)

    cond do
      refusal = Tournaments.write_refused(t.id) -> refusal
      is_nil(match.team_b_id) -> {:error, :bye_match}
      winner_team_id not in [match.team_a_id, match.team_b_id] -> {:error, :not_in_match}
      not is_nil(match.forfeited_to_team_id) -> {:error, :already_forfeited}
      boards == [] -> {:error, :no_boards}
      true -> do_forfeit(t, match, boards, winner_team_id)
    end
  end

  defp do_forfeit(t, match, boards, winner_team_id) do
    per_match = max(t.team_boards || 1, 1)
    winner_is_a? = winner_team_id == match.team_a_id

    Repo.transaction(fn ->
      Enum.each(boards, fn p ->
        k = rem(p.board - 1, per_match) + 1
        winner_white? = winner_is_a? == TeamRounds.team_a_white?(k)
        result = if winner_white?, do: "1-0FF", else: "0-1FF"
        p |> Pairing.changeset(%{result: result}) |> Repo.update!()
      end)

      match
      |> Ecto.Changeset.change(
        forfeited_to_team_id: winner_team_id,
        forfeit_previous_results: Map.new(boards, &{Integer.to_string(&1.board), &1.result})
      )
      |> Repo.update!()
    end)
    |> finish(t.id)
  end

  @doc """
  Withdraws a forfeit decision: the boards get back the results they had
  before it, and the match is decided on its boards again. A board added to
  the match after the decision keeps whatever it holds. `{:error,
  :not_forfeited}` when there is no decision to withdraw.
  """
  def withdraw_forfeit(%Tournament{} = t, %Match{} = match) do
    cond do
      refusal = Tournaments.write_refused(t.id) ->
        refusal

      is_nil(match.forfeited_to_team_id) ->
        {:error, :not_forfeited}

      true ->
        previous = match.forfeit_previous_results || %{}

        Repo.transaction(fn ->
          for p <- match_boards(match),
              {:ok, result} <- [Map.fetch(previous, Integer.to_string(p.board))] do
            p |> Pairing.changeset(%{result: result}) |> Repo.update!()
          end

          match
          |> Ecto.Changeset.change(forfeited_to_team_id: nil, forfeit_previous_results: nil)
          |> Repo.update!()
        end)
        |> finish(t.id)
    end
  end

  @doc """
  Whether a game was played on any board of a forfeited match before the
  decision - read from the results the decision replaced. False for a match
  with no decision.
  """
  def played_before_decision?(%{forfeited_to_team_id: nil}), do: false

  def played_before_decision?(%{forfeit_previous_results: previous}) when is_map(previous),
    do: Enum.any?(previous, fn {_board, result} -> result != "" and Results.played?(result) end)

  def played_before_decision?(_match), do: false

  defp match_boards(%Match{} = match) do
    Repo.all(from p in Pairing, where: p.match_id == ^match.id, order_by: p.board)
  end

  defp finish({:ok, updated}, tournament_id) do
    Tournaments.invalidate_manual_ranking(tournament_id)
    Tournaments.broadcast_tournament_change(tournament_id, :results)
    Tournaments.refresh_status!(tournament_id)
    {:ok, updated}
  end

  defp finish({:error, _} = error, _tournament_id), do: error

  ## ---------- boards added by hand ----------

  @doc """
  Whether a board numbered `board` with `white_id` against `black_id` fits
  a match of `round`: `{:ok, match}` or `{:error, reason}`, where reason is

    * `:not_team` - the tournament is not paired as teams;
    * `:no_team` - a player is on no team, or both on the same one;
    * `:no_match` - no match of the round has exactly these two teams, or
      the board number is not one of that match's boards;
    * `:board_taken` - another board already has that number;
    * `:colours` - the first-named team would not have White on an odd
      board or Black on an even one;
    * `:board_order` - a player's board order does not sit between the
      boards already in the match.

  `ignore_pairing_id` leaves one existing board out of the check - the board
  being moved, for `attach_board/3`.
  """
  def slot_at(%Tournament{} = t, %Round{} = round, white_id, black_id, board, ignore \\ nil) do
    with :ok <- teams_mode(t),
         {:ok, white, black} <- two_team_players(t.id, white_id, black_id) do
      per_match = max(t.team_boards || 1, 1)
      match_no = div(board - 1, per_match) + 1
      k = rem(board - 1, per_match) + 1
      pairings = round_pairings(round.id) |> Enum.reject(&(&1.id == ignore))
      teams = MapSet.new([white.team_id, black.team_id])

      match =
        Repo.one(
          from m in Match,
            where: m.round_id == ^round.id and m.board == ^match_no and not is_nil(m.team_b_id)
        )

      cond do
        is_nil(match) or MapSet.new([match.team_a_id, match.team_b_id]) != teams ->
          {:error, :no_match}

        Enum.any?(pairings, &(&1.board == board)) ->
          {:error, :board_taken}

        white.team_id == match.team_a_id != TeamRounds.team_a_white?(k) ->
          {:error, :colours}

        not order_fits?(t, match, pairings, k, white, black) ->
          {:error, :board_order}

        true ->
          {:ok, match}
      end
    end
  end

  @doc """
  The first place in `round`'s matches where two players could be seated as
  a board: `{:ok, %{match: match, board: n, white_id: id, black_id: id}}` with
  the colours the match needs, or the reason from `slot_at/5` that ruled the
  last candidate out (`:no_match` when there was none).
  """
  def fitting_slot(%Tournament{} = t, %Round{} = round, player_a_id, player_b_id, ignore \\ nil) do
    with :ok <- teams_mode(t),
         {:ok, a, b} <- two_team_players(t.id, player_a_id, player_b_id) do
      per_match = max(t.team_boards || 1, 1)
      teams = [a.team_id, b.team_id]

      match =
        Repo.one(
          from m in Match,
            where: m.round_id == ^round.id and not is_nil(m.team_b_id),
            where: m.team_a_id in ^teams and m.team_b_id in ^teams,
            limit: 1
        )

      case match do
        nil ->
          {:error, :no_match}

        match ->
          candidates =
            for k <- 1..per_match do
              board = (match.board - 1) * per_match + k

              {w, b} =
                if a.team_id == match.team_a_id == TeamRounds.team_a_white?(k),
                  do: {player_a_id, player_b_id},
                  else: {player_b_id, player_a_id}

              {board, w, b}
            end

          Enum.reduce_while(candidates, {:error, :no_match}, fn {board, w, b}, acc ->
            case slot_at(t, round, w, b, board, ignore) do
              {:ok, match} ->
                {:halt, {:ok, %{match: match, board: board, white_id: w, black_id: b}}}

              {:error, :board_taken} ->
                {:cont, if(acc == {:error, :no_match}, do: {:error, :board_taken}, else: acc)}

              {:error, reason} ->
                {:cont, {:error, reason}}
            end
          end)
      end
    end
  end

  @doc """
  Moves an existing board that belongs to no match into the first match it
  fits (`fitting_slot/5`): its board number and match change, and its seats
  swap when the match needs the other colours. A board with a result whose
  colours would have to swap is refused (`:colours`): the result describes
  the game as it was seated.
  """
  def attach_board(%Tournament{} = t, %Round{} = round, %Pairing{} = pairing) do
    cond do
      refusal = Tournaments.write_refused(t.id) ->
        refusal

      not is_nil(pairing.match_id) ->
        {:error, :already_attached}

      is_nil(pairing.white_player_id) or is_nil(pairing.black_player_id) ->
        {:error, :no_team}

      true ->
        with {:ok, slot} <-
               fitting_slot(
                 t,
                 round,
                 pairing.white_player_id,
                 pairing.black_player_id,
                 pairing.id
               ),
             :ok <- colours_keep_result(pairing, slot) do
          pairing
          |> Ecto.Changeset.change(
            board: slot.board,
            match_id: slot.match.id,
            white_player_id: slot.white_id,
            black_player_id: slot.black_id
          )
          |> Repo.update()
          |> tap(fn
            {:ok, updated} -> Tournaments.freeze_new_pairing_display_board!(updated)
            _ -> :ok
          end)
          |> finish(t.id)
        end
    end
  end

  defp colours_keep_result(%Pairing{result: result} = p, slot) do
    if slot.white_id != p.white_player_id and result not in ["", nil],
      do: {:error, :colours},
      else: :ok
  end

  @doc """
  The boards of `round` that belong to no match although players sit at
  them - in a round paired as teams, boards that count for neither team.
  Empty for every other tournament.
  """
  def unattached_boards(%Tournament{} = t, %{pairings: pairings}) when is_list(pairings) do
    if Tournament.paired_as_teams?(t) do
      pairings
      |> Enum.filter(fn p ->
        is_nil(p.match_id) and not p.hidden and
          (not is_nil(p.white_player_id) or not is_nil(p.black_player_id))
      end)
      |> Enum.sort_by(& &1.board)
    else
      []
    end
  end

  def unattached_boards(_t, _round), do: []

  defp teams_mode(t), do: if(Tournament.paired_as_teams?(t), do: :ok, else: {:error, :not_team})

  defp two_team_players(tournament_id, a_id, b_id) do
    players =
      Repo.all(
        from p in Player, where: p.tournament_id == ^tournament_id and p.id in ^[a_id, b_id]
      )

    a = Enum.find(players, &(&1.id == a_id))
    b = Enum.find(players, &(&1.id == b_id))

    if a && b && a.team_id && b.team_id && a.team_id != b.team_id,
      do: {:ok, a, b},
      else: {:error, :no_team}
  end

  defp round_pairings(round_id),
    do: Repo.all(from p in Pairing, where: p.round_id == ^round_id)

  # Board orders line up: on each side, the players already seated on the
  # match's lower boards have lower board orders than the new player, and
  # those on higher boards higher ones. A player with no board order has no
  # place to check and never blocks.
  defp order_fits?(t, match, pairings, k, white, black) do
    per_match = max(t.team_boards || 1, 1)
    {new_a, new_b} = if white.team_id == match.team_a_id, do: {white, black}, else: {black, white}

    seated =
      pairings
      |> Enum.filter(&(&1.match_id == match.id))
      |> Enum.map(fn p ->
        j = rem(p.board - 1, per_match) + 1

        {a_id, b_id} =
          if TeamRounds.team_a_white?(j),
            do: {p.white_player_id, p.black_player_id},
            else: {p.black_player_id, p.white_player_id}

        {j, a_id, b_id}
      end)

    ids = seated |> Enum.flat_map(fn {_, a, b} -> [a, b] end) |> Enum.reject(&is_nil/1)

    orders =
      Repo.all(from p in Player, where: p.id in ^ids, select: {p.id, p.board_order}) |> Map.new()

    side_fits? = fn new_player, pick ->
      Enum.all?(seated, fn {j, _, _} = row ->
        other = orders[pick.(row)]

        cond do
          is_nil(other) or is_nil(new_player.board_order) -> true
          j < k -> other < new_player.board_order
          true -> other > new_player.board_order
        end
      end)
    end

    side_fits?.(new_a, fn {_, a, _} -> a end) and side_fits?.(new_b, fn {_, _, b} -> b end)
  end
end
