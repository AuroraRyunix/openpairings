defmodule PairingsEngine.Standings do
  @moduledoc """
  Standings and tiebreak calculation per the FIDE Tie-Break Regulations (C.07,
  in force from 1 March 2026).

  Individual tiebreaks implemented: BH, BHC1, BHC2, MBH, SB, DE, WIN, WON,
  BPG, PS, KS, ARO, AROC1. Team tiebreaks (MP/GP/BB) arrive with team events.

  Unplayed rounds follow Article 16: an opponent's score is adjusted (trailing
  voluntarily-unplayed rounds count as draws), and the participant's own
  unplayed rounds contribute a capped "dummy opponent" score to Buchholz-style
  sums.
  """

  import Ecto.Query
  alias PairingsEngine.Repo
  alias PairingsEngine.Tournaments
  alias PairingsEngine.Tournaments.{Pairing, Round}

  @doc """
  Returns standings entries sorted by `total` (game points plus the player's
  administrative `extra_points`, per SWAR "P.Tot" semantics), then the
  tournament's configured tiebreaks:
  `[%{player: p, points: float, extra_points: float, total: float, rank: n, tiebreaks: %{"BH" => v, ...}}]`

  `points` is game points only — FIDE tiebreaks (Buchholz, Sonneborn-Berger,
  etc.) keep using opponents' game points, unaffected by administrative bonus
  points. `total` is what determines the ranking.

  Accepts `through_round: n` to compute standings using only rounds `<= n`
  (and byes recorded for those rounds) — i.e. "standings as they stood right
  after round n". This is exactly the same code path ordinary standings use
  once a tournament is mid-way through (they simply never see rounds beyond
  the latest paired one), so a past round number produces the same honest
  figures the tournament actually showed at the time. Omit the option (or
  pass a round `>=` the latest paired round) for the current/overall
  standings.
  """
  def standings(tournament, opts \\ []), do: build_standings(tournament, tournament.tiebreaks, opts)

  @doc """
  Same as `standings/1`, but the `:tiebreaks` map on every entry is guaranteed
  to include BH, BHC1, SB, PS and DE, regardless of which codes the tournament
  is actually configured to use (the player grid displays these columns
  unconditionally). Ranking and ordering still follow the tournament's own
  configured tiebreaks, so `:rank` matches `standings/1` exactly.
  """
  def grid_standings(tournament) do
    codes = Enum.uniq(tournament.tiebreaks ++ ~w(BH BHC1 SB PS DE))
    build_standings(tournament, codes, [])
  end

  defp build_standings(tournament, tiebreak_codes, opts) do
    players = Tournaments.list_players(tournament.id)
    games_by_player = games_by_player(tournament, players, opts)

    entries =
      Enum.map(players, fn player ->
        games = Map.get(games_by_player, player.id, [])
        points = total_points(games)
        extra_points = (player.extra_points || 0.0) |> round_f(1)
        %{
          player: player,
          games: games,
          points: points,
          extra_points: extra_points,
          total: round_f(points + extra_points, 1)
        }
      end)

    entries = compute_tiebreaks(entries, tournament, tiebreak_codes)

    entries
    |> Enum.sort_by(fn e ->
      tb_values = Enum.map(tournament.tiebreaks, &Map.get(e.tiebreaks, &1, 0.0))
      # ARO-style tiebreaks sort descending like the rest (higher = better).
      [-e.total | Enum.map(tb_values, &(-&1))]
    end)
    |> Enum.with_index(1)
    |> Enum.map(fn {e, rank} -> Map.put(e, :rank, rank) end)
  end

  @doc "Number of rounds that have at least one pairing."
  def rounds_paired(tournament_id) do
    Repo.aggregate(from(r in Round, where: r.tournament_id == ^tournament_id), :count)
  end

  ## ---------- game extraction ----------

  # One record per player per paired round:
  # %{round: n, opponent_id: id | nil, colour: :w | :b | nil, points: float,
  #   played: boolean (over the board), voluntary: boolean (for unplayed)}
  #
  # `opts[:through_round]`, when set, limits rounds (and byes) to `<= n` —
  # this is how round-scoped ("as of round n") standings are computed.
  defp games_by_player(tournament, players, opts) do
    through_round = Keyword.get(opts, :through_round)

    rounds_query =
      from r in Round, where: r.tournament_id == ^tournament.id, order_by: r.number, preload: [pairings: []]

    rounds_query =
      case through_round do
        nil -> rounds_query
        n -> from r in rounds_query, where: r.number <= ^n
      end

    rounds = Repo.all(rounds_query)

    byes = byes_by_player_round(tournament.id, through_round)
    player_ids = MapSet.new(players, & &1.id)

    for round <- rounds,
        pairing <- round.pairings,
        record <- pairing_records(pairing, round.number, tournament),
        MapSet.member?(player_ids, record.player_id),
        reduce: %{} do
      acc -> Map.update(acc, record.player_id, [record], &(&1 ++ [record]))
    end
    |> add_bye_records(byes, tournament)
  end

  defp byes_by_player_round(tournament_id, through_round) do
    query =
      from b in "byes",
        where: b.tournament_id == ^tournament_id,
        select: %{player_id: b.player_id, round: b.round, type: b.type}

    query =
      case through_round do
        nil -> query
        n -> from b in query, where: b.round <= ^n
      end

    Repo.all(query)
  end

  defp add_bye_records(games_by_player, byes, tournament) do
    Enum.reduce(byes, games_by_player, fn bye, acc ->
      points =
        case bye.type do
          "requested-half" -> tournament.points_draw
          "pairing-allocated" -> tournament.bye_value
          _ -> tournament.points_loss
        end

      record = %{
        round: bye.round,
        player_id: bye.player_id,
        opponent_id: nil,
        colour: nil,
        points: points,
        played: false,
        voluntary: bye.type in ["requested-half", "requested-zero", "absent"]
      }

      Map.update(acc, bye.player_id, [record], &(&1 ++ [record]))
    end)
  end

  # Expands one stored pairing into records for both players.
  defp pairing_records(%Pairing{result: ""}, _round, _t), do: []

  defp pairing_records(pairing, round_number, t) do
    w = pairing.white_player_id
    b = pairing.black_player_id

    # `played` marks a game contested over the board (FIDE Art. 16 unplayed
    # rules apply otherwise). A forfeit — win or loss, single or double — is
    # always unplayed for BOTH sides, even for the side awarded the point.
    # Plain "0-0" is a played game where both players lose (e.g. both
    # defaulted after making moves); "0-0FF" is the double-forfeit, unplayed.
    # "+--"/"--+" are the legacy forfeit notation kept for
    # historical/SWAR-imported data.
    {wp, bp, played, forfeit} =
      case pairing.result do
        "1-0" -> {t.points_win, t.points_loss, true, false}
        "1/2-1/2" -> {t.points_draw, t.points_draw, true, false}
        "0-1" -> {t.points_loss, t.points_win, true, false}
        "1-0FF" -> {t.points_win, t.points_loss, false, true}
        "0-1FF" -> {t.points_loss, t.points_win, false, true}
        "0-0FF" -> {t.points_loss, t.points_loss, false, true}
        "0-0" -> {t.points_loss, t.points_loss, true, false}
        "+--" -> {t.points_win, t.points_loss, false, true}
        "--+" -> {t.points_loss, t.points_win, false, true}
        "bye" -> {t.bye_value, 0.0, false, false}
        _ -> {0.0, 0.0, false, false}
      end

    white_record = %{
      round: round_number,
      player_id: w,
      opponent_id: if(pairing.result == "bye", do: nil, else: b),
      colour: :w,
      points: wp,
      played: played,
      voluntary: not played and not forfeit
    }

    if b == nil or pairing.result == "bye" do
      [white_record]
    else
      [
        white_record,
        %{
          round: round_number,
          player_id: b,
          opponent_id: w,
          colour: :b,
          points: bp,
          played: played,
          voluntary: false
        }
      ]
    end
  end

  defp total_points(games), do: games |> Enum.map(& &1.points) |> Enum.sum() |> round_f(1)

  ## ---------- tiebreak computation ----------

  defp compute_tiebreaks(entries, tournament, tiebreak_codes) do
    by_id = Map.new(entries, &{&1.player.id, &1})

    entries =
      Enum.map(entries, fn entry ->
        values =
          for code <- tiebreak_codes, code != "DE", into: %{} do
            {code, tiebreak(code, entry, by_id, tournament)}
          end

        Map.put(entry, :tiebreaks, values)
      end)

    if "DE" in tiebreak_codes do
      add_direct_encounter(entries)
    else
      entries
    end
  end

  # Article 8.1: sum of the (adjusted) scores of the opponents; own unplayed
  # rounds contribute a capped dummy score (Article 16.4).
  defp tiebreak("BH", entry, by_id, t), do: buchholz_contributions(entry, by_id, t) |> Enum.sum() |> round_f(2)

  # Article 14.1.1: cut the least significant value(s).
  defp tiebreak("BHC1", entry, by_id, t), do: cut(buchholz_contributions(entry, by_id, t), 1, 0)
  defp tiebreak("BHC2", entry, by_id, t), do: cut(buchholz_contributions(entry, by_id, t), 2, 0)
  defp tiebreak("MBH", entry, by_id, t), do: cut(buchholz_contributions(entry, by_id, t), 1, 1)

  # Article 9.1: sum of opponents' (adjusted) scores × points scored against them.
  defp tiebreak("SB", entry, by_id, t) do
    entry.games
    |> Enum.map(fn g ->
      case opponent(g, by_id) do
        nil -> dummy_score(entry, g, t) * g.points
        opp -> adjusted_score(opp, t) * g.points
      end
    end)
    |> Enum.sum()
    |> round_f(2)
  end

  # Article 7.1: rounds worth as many points as a win, with or without playing.
  defp tiebreak("WIN", entry, _by_id, t) do
    Enum.count(entry.games, &(&1.points >= t.points_win)) / 1
  end

  # Article 7.2: games won over the board.
  defp tiebreak("WON", entry, _by_id, t) do
    Enum.count(entry.games, &(&1.played and &1.points >= t.points_win)) / 1
  end

  # Games played with the black pieces.
  defp tiebreak("BPG", entry, _by_id, _t) do
    Enum.count(entry.games, &(&1.played and &1.colour == :b)) / 1
  end

  # Article 7.5: sum of the running score after each round.
  defp tiebreak("PS", entry, _by_id, _t) do
    entry.games
    |> Enum.sort_by(& &1.round)
    |> Enum.map_reduce(0.0, fn g, acc -> {acc + g.points, acc + g.points} end)
    |> elem(0)
    |> Enum.sum()
    |> round_f(1)
  end

  # Article 9.2: points against opponents with >= 50% of the maximum score.
  defp tiebreak("KS", entry, by_id, t) do
    max_score = rounds_played_count(by_id) * t.points_win

    entry.games
    |> Enum.filter(fn g ->
      opp = opponent(g, by_id)
      opp != nil and opp.points >= max_score / 2
    end)
    |> Enum.map(& &1.points)
    |> Enum.sum()
    |> round_f(1)
  end

  # Article 10.1: average rating of opponents played over the board.
  defp tiebreak("ARO", entry, by_id, _t), do: aro(entry, by_id, 0)
  defp tiebreak("AROC1", entry, by_id, _t), do: aro(entry, by_id, 1)

  defp tiebreak(_unknown, _entry, _by_id, _t), do: 0.0

  defp aro(entry, by_id, cut_lowest) do
    ratings =
      entry.games
      |> Enum.filter(& &1.played)
      |> Enum.map(fn g -> opponent(g, by_id) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&PairingsEngine.Tournaments.Player.rating(&1.player))
      |> Enum.sort()
      |> Enum.drop(cut_lowest)

    case ratings do
      [] -> 0.0
      list -> Float.round(Enum.sum(list) / length(list) + 1.0e-9) / 1
    end
  end

  defp buchholz_contributions(entry, by_id, t) do
    Enum.map(entry.games, fn g ->
      case opponent(g, by_id) do
        nil -> dummy_score(entry, g, t)
        opp -> adjusted_score(opp, t)
      end
    end)
  end

  # Article 16.3: for tiebreak purposes an opponent's trailing voluntarily
  # unplayed rounds count as draws; other rounds count as the points awarded.
  defp adjusted_score(opp_entry, t) do
    games = Enum.sort_by(opp_entry.games, & &1.round)

    trailing_voluntary =
      games
      |> Enum.reverse()
      |> Enum.take_while(&(not &1.played and &1.voluntary))
      |> length()

    {head, tail} = Enum.split(games, length(games) - trailing_voluntary)

    Enum.sum(Enum.map(head, & &1.points)) + length(tail) * t.points_draw
  end

  # Article 16.4: an unplayed round contributes the score of a dummy opponent —
  # the participant's score before the round, the complementary result, then
  # draws for every later round — capped at draw points × total rounds.
  defp dummy_score(entry, game, t) do
    before =
      entry.games
      |> Enum.filter(&(&1.round < game.round))
      |> Enum.map(& &1.points)
      |> Enum.sum()

    complement = max(t.points_win - game.points, t.points_loss)
    remaining = t.rounds_count - game.round

    dummy = before + complement + remaining * t.points_draw
    dummy |> min(t.points_draw * t.rounds_count) |> round_f(2)
  end

  defp cut(contributions, n_lowest, n_highest) do
    contributions
    |> Enum.sort()
    |> Enum.drop(n_lowest)
    |> Enum.reverse()
    |> Enum.drop(n_highest)
    |> Enum.sum()
    |> round_f(2)
  end

  # Float.round that also accepts integers (sums of integer points).
  defp round_f(value, precision), do: Float.round(value / 1, precision)

  defp opponent(%{opponent_id: nil}, _by_id), do: nil
  defp opponent(%{opponent_id: id}, by_id), do: Map.get(by_id, id)

  defp rounds_played_count(by_id) do
    by_id
    |> Map.values()
    |> Enum.map(&length(&1.games))
    |> Enum.max(fn -> 0 end)
  end

  # Article 6: direct encounter within groups tied on points. Only decisive
  # when every pair in the tied group has met (Swiss partial ties otherwise
  # stay tied here and fall through to the next tiebreak).
  defp add_direct_encounter(entries) do
    entries
    |> Enum.group_by(& &1.points)
    |> Enum.flat_map(fn {_points, group} ->
      ids = MapSet.new(group, & &1.player.id)

      all_met? =
        length(group) > 1 and
          Enum.all?(group, fn e ->
            met = MapSet.new(e.games |> Enum.filter(& &1.played) |> Enum.map(& &1.opponent_id))
            MapSet.subset?(MapSet.delete(ids, e.player.id), met)
          end)

      Enum.map(group, fn e ->
        value =
          if all_met? do
            e.games
            |> Enum.filter(&(&1.played and &1.opponent_id in ids))
            |> Enum.map(& &1.points)
            |> Enum.sum()
            |> round_f(1)
          else
            0.0
          end

        put_in(e.tiebreaks["DE"], value)
      end)
    end)
  end
end
