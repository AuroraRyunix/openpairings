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
      refusal = Tournaments.write_refused(t.id) ->
        refusal

      refusal = round_closed(t, match) ->
        refusal

      is_nil(match.team_b_id) ->
        {:error, :bye_match}

      winner_team_id not in [match.team_a_id, match.team_b_id] ->
        {:error, :not_in_match}

      not is_nil(match.forfeited_to_team_id) or match.double_forfeit ->
        {:error, :already_forfeited}

      match_score?(match) ->
        {:error, :match_score_set}

      boards == [] ->
        {:error, :no_boards}

      true ->
        do_forfeit(t, match, boards, winner_team_id)
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
  Records a DOUBLE forfeit: neither team turned up, so both lose the match by
  forfeit. Every board becomes `0-0FF` - a forfeit loss for both seats - the
  match is marked `double_forfeit`, and the boards' previous results are kept
  as for `forfeit_match/3`, so `withdraw_forfeit/2` puts them back.

  Scored by `PairingsEngine.TeamStandings` as a lost match for both teams:
  the loss's match points and no game points to either (TRF-2026 record
  `330`, type `--`; Ainalrami's reading T8 of C.07). It is not a meeting and
  gives neither team a colour (C.04.2 Art. 3.5, C.04.6 Art. 1.6.1): no game
  was played. `{:error, reason}` as `forfeit_match/3`.
  """
  def double_forfeit(%Tournament{} = t, %Match{} = match) do
    boards = match_boards(match)

    cond do
      refusal = Tournaments.write_refused(t.id) ->
        refusal

      refusal = round_closed(t, match) ->
        refusal

      is_nil(match.team_b_id) ->
        {:error, :bye_match}

      not is_nil(match.forfeited_to_team_id) or match.double_forfeit ->
        {:error, :already_forfeited}

      match_score?(match) ->
        {:error, :match_score_set}

      boards == [] ->
        {:error, :no_boards}

      # Neither team turned up: a match in which a game was played is not
      # one. (Forfeiting a played match to one side is `forfeit_match/3`.)
      Enum.any?(boards, &(&1.result != "" and Results.played?(&1.result))) ->
        {:error, :games_played}

      true ->
        Repo.transaction(fn ->
          Enum.each(boards, fn p ->
            p |> Pairing.changeset(%{result: "0-0FF"}) |> Repo.update!()
          end)

          match
          |> Ecto.Changeset.change(
            double_forfeit: true,
            forfeit_previous_results: Map.new(boards, &{Integer.to_string(&1.board), &1.result})
          )
          |> Repo.update!()
        end)
        |> finish(t.id)
    end
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

      refusal = round_closed(t, match) ->
        refusal

      is_nil(match.forfeited_to_team_id) and not match.double_forfeit ->
        {:error, :not_forfeited}

      true ->
        previous = match.forfeit_previous_results || %{}

        Repo.transaction(fn ->
          for p <- match_boards(match),
              {:ok, result} <- [Map.fetch(previous, Integer.to_string(p.board))] do
            p |> Pairing.changeset(%{result: result}) |> Repo.update!()
          end

          match
          |> Ecto.Changeset.change(
            forfeited_to_team_id: nil,
            forfeit_previous_results: nil,
            double_forfeit: false
          )
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

  # A postponed board (`"*"`) is a game still to be played, so it is not one
  # that was played before the decision, even though it counts as played for
  # the tie-breaks while it waits.
  def played_before_decision?(%{forfeit_previous_results: previous}) when is_map(previous),
    do:
      Enum.any?(previous, fn {_board, result} ->
        result != "" and Results.played?(result) and not Results.postponed?(result)
      end)

  def played_before_decision?(_match), do: false

  # A forfeit decision rewrites every board of the match, so FIDE mode's
  # round window (`Tournaments.ensure_round_editable/2`, C.04.2:4.3) holds
  # for it as for any other result.
  defp round_closed(%Tournament{} = t, %Match{round_id: round_id}) do
    number = Repo.one(from r in Round, where: r.id == ^round_id, select: r.number)

    case number && Tournaments.ensure_round_editable(t, number) do
      {:error, _} = refusal -> refusal
      _ok -> nil
    end
  end

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

  ## ---------- a match decided by its score ----------

  @doc """
  Decides `match` by its score alone: `score_a` to `score_b` in boards (2.5
  and 1.5 for 2½-1½), for a team event whose line-ups are optional
  (`Tournament.team_lineups_optional?/1`) and a match nobody sits at.

  The score is written onto the match's boards as board results
  (`score_results/3`), and kept on the match (`match_score_a`/`_b`) so the
  pages can say the boards came from a match score. Everything that reads
  boards - the round's completeness, game and match points, the team
  standings and tie-breaks, the TRF `310` totals, the published snapshot -
  then reads the match exactly as if its boards had been entered one by
  one. No game is invented for anybody: the boards have no players, so the
  results are on no player's record and no `001` line.

  Refused with `{:error, reason}`:

    * `:not_optional` - the tournament's line-ups are required;
    * `:bye_match`;
    * `:players_seated` - a board of the match has a player: enter that
      board's result instead (or empty the line-ups first);
    * `:match_started` - a board already has a result, or the match was
      forfeited by decision;
    * `:bad_score` - not two non-negative multiples of ½ adding up to the
      number of boards;
    * the writability and FIDE-mode round-window refusals.

  Returns `{:ok, match}`. `clear_match_score/2` undoes it.
  """
  def set_match_score(%Tournament{} = t, %Match{} = match, score_a, score_b) do
    boards = match_boards(match)
    per_match = max(t.team_boards || 1, 1)

    cond do
      refusal = Tournaments.write_refused(t.id) ->
        refusal

      refusal = round_closed(t, match) ->
        refusal

      not Tournament.team_lineups_optional?(t) ->
        {:error, :not_optional}

      is_nil(match.team_b_id) ->
        {:error, :bye_match}

      Enum.any?(boards, &(&1.white_player_id || &1.black_player_id)) ->
        {:error, :players_seated}

      not is_nil(match.forfeited_to_team_id) or match.double_forfeit or
        match_score?(match) or Enum.any?(boards, &(&1.result not in ["", nil])) ->
        {:error, :match_started}

      not valid_score?(score_a, score_b, per_match) ->
        {:error, :bad_score}

      true ->
        results = score_results(score_a * 1.0, score_b * 1.0, per_match)
        by_k = Map.new(boards, &{rem(&1.board - 1, per_match) + 1, &1})

        Repo.transaction(fn ->
          for {k, result} <- results do
            case Map.get(by_k, k) do
              nil ->
                %Pairing{
                  round_id: match.round_id,
                  match_id: match.id,
                  board: (match.board - 1) * per_match + k,
                  result: result
                }
                |> Repo.insert!()
                |> Tournaments.freeze_new_pairing_display_board!()

              p ->
                p |> Pairing.changeset(%{result: result}) |> Repo.update!()
            end
          end

          match
          |> Ecto.Changeset.change(match_score_a: score_a * 1.0, match_score_b: score_b * 1.0)
          |> Repo.update!()
        end)
        |> finish(t.id)
    end
  end

  @doc """
  Withdraws a match score (`set_match_score/4`): the boards are blank again,
  ready for a new score or their own results. `{:error, :no_match_score}`
  for a match not decided by its score.
  """
  def clear_match_score(%Tournament{} = t, %Match{} = match) do
    cond do
      refusal = Tournaments.write_refused(t.id) ->
        refusal

      refusal = round_closed(t, match) ->
        refusal

      not match_score?(match) ->
        {:error, :no_match_score}

      true ->
        Repo.transaction(fn ->
          for p <- match_boards(match), is_nil(p.white_player_id), is_nil(p.black_player_id) do
            p |> Pairing.changeset(%{result: ""}) |> Repo.update!()
          end

          match
          |> Ecto.Changeset.change(match_score_a: nil, match_score_b: nil)
          |> Repo.update!()
        end)
        |> finish(t.id)
    end
  end

  defp valid_score?(a, b, per_match) when is_number(a) and is_number(b) do
    half?(a) and half?(b) and a >= 0 and b >= 0 and a + b == per_match
  end

  defp valid_score?(_a, _b, _per_match), do: false

  defp half?(x), do: x * 2 == Float.round(x * 2.0)

  @doc """
  The board results a match score is written as, `[{board_in_match,
  result}]` for boards 1..`boards`: as many draws as the score allows, and
  the difference as wins - the winning team's on the top boards. 2½-1½ on
  four boards is a win for the first team on board 1 and three draws; 3-1 a
  win on boards 1 and 2 and two draws; 2-2 four draws. Each result is from
  White's side (`TeamRounds.team_a_white?/1`: the first team has White on
  the odd boards). Pure.

  The split is a convention, not a record of the games, and it is the one
  that invents the least: a board result says nothing the score does not.
  It matters only to the tie-breaks that weigh boards (`BB`, `TBR`, `BBE`),
  which read it as the top boards having decided the match.
  """
  def score_results(score_a, score_b, boards) do
    wins = abs(score_a - score_b) |> round()
    a_wins? = score_a > score_b

    for k <- 1..boards do
      outcome = if k <= wins, do: if(a_wins?, do: :a, else: :b), else: :draw
      {k, board_result(outcome, TeamRounds.team_a_white?(k))}
    end
  end

  defp board_result(:draw, _a_white?), do: "1/2-1/2"
  defp board_result(:a, true), do: "1-0"
  defp board_result(:a, false), do: "0-1"
  defp board_result(:b, true), do: "0-1"
  defp board_result(:b, false), do: "1-0"

  @doc """
  The boards of `tournament_id`'s matches that are no game for the rating
  report - at least one seat empty - per round: `[{round, count}]`, by
  round. With optional line-ups these hold results the team scores count
  but no `001` line carries (`PairingsEngine.TrfExport`), so the Export page
  warns in FIDE mode before such a round is sent. Empty when every board of
  every match has two players.
  """
  def empty_board_rounds(tournament_id) do
    Repo.all(
      from p in Pairing,
        join: r in Round,
        on: p.round_id == r.id,
        where: r.tournament_id == ^tournament_id and not is_nil(p.match_id),
        where: is_nil(p.white_player_id) or is_nil(p.black_player_id),
        group_by: r.number,
        order_by: r.number,
        select: {r.number, count(p.id)}
    )
  end

  ## ---------- line-ups ----------

  @doc """
  The two line-ups of `match` as they stand on its boards: `%{a: [player_id
  | nil], b: [player_id | nil]}`, one entry per board of the match (board 1
  first), nil for an empty seat.
  """
  def lineups(%Tournament{} = t, %Match{} = match) do
    per_match = max(t.team_boards || 1, 1)
    by_k = Map.new(match_boards(match), &{rem(&1.board - 1, per_match) + 1, &1})

    {a, b} =
      1..per_match
      |> Enum.map(fn k ->
        case Map.get(by_k, k) do
          nil ->
            {nil, nil}

          p ->
            if TeamRounds.team_a_white?(k),
              do: {p.white_player_id, p.black_player_id},
              else: {p.black_player_id, p.white_player_id}
        end
      end)
      |> Enum.unzip()

    %{a: a, b: b}
  end

  @doc """
  Whether `match`'s line-ups may still change: no result has been entered on
  it. A board one team could not fill carries its forfeit result from the
  moment it is written (`TeamRounds.match_boards/4`), so only a board with
  two players counts - or, with optional line-ups, a board that carries a
  played result although nobody sits at it, which only the arbiter writes;
  a match forfeited by decision, a double forfeit, or a match decided by its
  score (`set_match_score/4`) has started in the sense that matters.
  """
  def lineup_open?(%Match{} = match) do
    is_nil(match.forfeited_to_team_id) and not match.double_forfeit and
      not match_score?(match) and
      not Enum.any?(match_boards(match), &result_entered?/1)
  end

  defp result_entered?(%Pairing{result: result}) when result in ["", nil], do: false

  defp result_entered?(%Pairing{} = p),
    do: (p.white_player_id && p.black_player_id && true) || Results.played?(p.result)

  @doc "Whether `match` was decided by its score alone (`set_match_score/4`)."
  def match_score?(%Match{match_score_a: a, match_score_b: b}),
    do: is_number(a) and is_number(b)

  def match_score?(_match), do: false

  @doc """
  The line-up a team plays with by default in round `number`: its roster in
  board order minus anyone unavailable that round, cut to the match size -
  what the pairing seats (`TeamRounds.lineup/3`), padded with nil.
  """
  def default_lineup(%Tournament{} = t, team_id, number) do
    per_match = max(t.team_boards || 1, 1)

    t.id
    |> Tournaments.team_roster(team_id)
    |> TeamRounds.lineup(number, per_match)
    |> Enum.map(& &1.id)
    |> pad(per_match)
  end

  defp pad(ids, n), do: Enum.take(ids ++ List.duplicate(nil, n), n)

  @doc """
  Sets both line-ups of `match` and rewrites its boards to match: `lineup_a`
  and `lineup_b` are each a list of player ids (or nil for an empty seat),
  board 1 first, for `team_a` and `team_b`.

  Allowed until the first result of the match is entered (`lineup_open?/1`),
  and in FIDE mode only while the round is still open
  (`Tournaments.ensure_round_editable/2`). Each line-up must be:

    * players of that team, each available for the round
      (`TeamRounds.available?/2`), none twice - `{:error, {:not_on_team,
      id}}`, `{:error, {:unavailable, player}}`, `{:error, {:twice, player}}`;
    * filled from board 1 down with no gap - a team short of players
      forfeits the BOTTOM boards - `{:error, :gap}`;
    * in the roster's board order: a player listed lower may not sit above
      one listed higher (the fixed board order of FIDE team events: Chess
      Olympiad 2026 regulations Art. 4.17.6, World Team Rapid & Blitz 2026
      Art. 4.2.1, Asian Team Championships Art. 4.2.3-4.2.4) -
      `{:error, {:board_order, upper, lower}}`.
      Unless a plugin's regulations set the board order for this
      tournament (`PairingsEngine.Plugins.plugin_board_order?/1`): then the
      plugin's line-up check reports on it instead.

  At least one team must field a player (`{:error, :no_players}`; a match
  neither team plays is a double forfeit, `double_forfeit/2`). Boards are
  seated as the pairing seats them (`TeamRounds.match_boards/3`): a seat one
  team cannot fill is the other side's forfeit win, a board neither fills is
  removed. Returns `{:ok, match}`.
  """
  def set_lineups(%Tournament{} = t, %Match{} = match, lineup_a, lineup_b) do
    per_match = max(t.team_boards || 1, 1)
    number = round_number(match)

    cond do
      refusal = Tournaments.write_refused(t.id) ->
        refusal

      refusal = round_closed(t, match) ->
        refusal

      not Tournament.paired_as_teams?(t) ->
        {:error, :not_team}

      is_nil(match.team_b_id) ->
        {:error, :bye_match}

      not lineup_open?(match) ->
        {:error, :match_started}

      true ->
        optional? = Tournament.team_lineups_optional?(t)

        with {:ok, a} <- check_lineup(t, match.team_a_id, lineup_a, number, per_match),
             {:ok, b} <- check_lineup(t, match.team_b_id, lineup_b, number, per_match),
             :ok <-
               if(a == [] and b == [] and not optional?, do: {:error, :no_players}, else: :ok) do
          Repo.transaction(fn -> rewrite_boards(t, match, a, b, per_match) end)
          |> finish(t.id)
        end
    end
  end

  defp round_number(%Match{round_id: round_id}),
    do: Repo.one(from r in Round, where: r.id == ^round_id, select: r.number)

  # The players of one line-up, board 1 first, with the trailing empty seats
  # dropped - or the reason it cannot be played.
  #
  # With optional line-ups an empty seat is a player not entered, so a gap is
  # allowed: the line-up comes back as a list per board, nil for an empty
  # seat, and only the seated players are checked.
  defp check_lineup(t, team_id, ids, number, per_match) do
    ids = ids |> Enum.take(per_match) |> pad(per_match)
    optional? = Tournament.team_lineups_optional?(t)

    {seated, rest} =
      if optional?,
        do: {Enum.reject(ids, &is_nil/1), []},
        else: Enum.split_while(ids, &(not is_nil(&1)))

    roster = Tournaments.team_roster(t.id, team_id)
    by_id = Map.new(roster, &{&1.id, &1})
    position = roster |> Enum.with_index() |> Map.new(fn {p, i} -> {p.id, i} end)

    unavailable =
      Enum.find_value(seated, fn id ->
        player = Map.get(by_id, id)
        if player && not TeamRounds.available?(player, number), do: player
      end)

    # A plugin whose regulations set the board order (`PairingsEngine.
    # Plugins.plugin_board_order?/1`) judges it in its own line-up check,
    # which reports and never refuses; the roster order is then only the
    # order the pairing seats by default.
    out_of_order =
      if PairingsEngine.Plugins.plugin_board_order?(t) do
        nil
      else
        seated
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.find(fn [x, y] -> Map.get(position, x, 0) > Map.get(position, y, 0) end)
      end

    duplicate = seated |> Enum.frequencies() |> Enum.find(fn {_id, n} -> n > 1 end)

    cond do
      Enum.any?(rest, &(not is_nil(&1))) ->
        {:error, :gap}

      stranger = Enum.find(seated, &(not Map.has_key?(by_id, &1))) ->
        {:error, {:not_on_team, stranger}}

      duplicate ->
        {:error, {:twice, Map.fetch!(by_id, elem(duplicate, 0))}}

      unavailable ->
        {:error, {:unavailable, unavailable}}

      out_of_order ->
        [upper, lower] = out_of_order
        {:error, {:board_order, Map.fetch!(by_id, upper), Map.fetch!(by_id, lower)}}

      optional? ->
        {:ok, Enum.map(ids, &(&1 && Map.fetch!(by_id, &1)))}

      true ->
        {:ok, Enum.map(seated, &Map.fetch!(by_id, &1))}
    end
  end

  defp rewrite_boards(t, match, lineup_a, lineup_b, per_match) do
    numbered =
      t
      |> TeamRounds.ensure_player_numbers(Enum.reject(lineup_a ++ lineup_b, &is_nil/1))
      |> Map.new(&{&1.id, &1})

    lineup_a = Enum.map(lineup_a, &(&1 && Map.fetch!(numbered, &1.id)))
    lineup_b = Enum.map(lineup_b, &(&1 && Map.fetch!(numbered, &1.id)))

    existing = Map.new(match_boards(match), &{rem(&1.board - 1, per_match) + 1, &1})

    # Optional line-ups keep every board, an empty seat with no result
    # (`TeamRounds.match_boards/4`); required ones seat as the pairing does.
    wanted =
      lineup_a
      |> TeamRounds.match_boards(lineup_b, per_match,
        optional: Tournament.team_lineups_optional?(t)
      )
      |> Map.new(fn {k, w, b, result} -> {k, {w, b, result}} end)

    for k <- 1..per_match do
      case {Map.get(existing, k), Map.get(wanted, k)} do
        {nil, nil} ->
          :ok

        {%Pairing{} = p, nil} ->
          Repo.delete!(p)

        {nil, {white, black, result}} ->
          %Pairing{
            round_id: match.round_id,
            match_id: match.id,
            board: (match.board - 1) * per_match + k,
            white_player_id: white && white.id,
            black_player_id: black && black.id,
            result: result
          }
          |> Repo.insert!()
          |> Tournaments.freeze_new_pairing_display_board!()

        {%Pairing{} = p, {white, black, result}} ->
          p
          |> Ecto.Changeset.change(
            white_player_id: white && white.id,
            black_player_id: black && black.id,
            result: result
          )
          |> Repo.update!()
      end
    end

    Repo.reload!(match)
  end

  @doc """
  League-style board colours (`Tournament.home_and_away?/1`): makes the away
  team the home team. `team_a` is always the team with White on the odd
  boards, so the two teams change places on the match and every board's two
  seats swap. Only before the match has a result (`lineup_open?/1`).
  """
  def swap_home(%Tournament{} = t, %Match{} = match) do
    cond do
      refusal = Tournaments.write_refused(t.id) ->
        refusal

      refusal = round_closed(t, match) ->
        refusal

      not Tournament.home_and_away?(t) ->
        {:error, :not_home_and_away}

      is_nil(match.team_b_id) ->
        {:error, :bye_match}

      not lineup_open?(match) ->
        {:error, :match_started}

      true ->
        Repo.transaction(fn ->
          for p <- match_boards(match) do
            p
            |> Ecto.Changeset.change(
              white_player_id: p.black_player_id,
              black_player_id: p.white_player_id,
              result: flip(p.result)
            )
            |> Repo.update!()
          end

          match
          |> Ecto.Changeset.change(team_a_id: match.team_b_id, team_b_id: match.team_a_id)
          |> Repo.update!()
        end)
        |> finish(t.id)
    end
  end

  defp flip("1-0FF"), do: "0-1FF"
  defp flip("0-1FF"), do: "1-0FF"
  defp flip(result), do: result

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
