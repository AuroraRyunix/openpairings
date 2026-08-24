defmodule PairingsEngine.Keizer do
  @moduledoc """
  The Keizer system - a Dutch/Belgian club-league ladder (as used by
  PairTwo and similar SWAR-adjacent software). Players are ranked on a
  running "Keizer list" with a value attached to each rung; every round they
  score points based on the *current* value of whoever/whatever they faced,
  and after every round the whole list is re-ranked and re-valued from
  scratch. That retroactive step is the signature Keizer feature: nothing
  Keizer-specific is ever stored - nothing but results, byes and absences
  are - so the list is always freshly recomputed from those and is always
  reproducible.

  ## The algorithm

  1. **Ladder values.** With `N` schedulable players (see
     `PairingsEngine.Pairing.eligible_players/2`) and a configured top value
     `T` (`tournaments.keizer_top_value`, nil meaning automatic = `2 * N`),
     the effective top is `max(T, N + 1)` so the bottom rung never goes to
     zero or negative. The player ranked `i` (1-based, best first) is worth
     `effective_top - (i - 1)`.

  2. **Initial ranking**, before round 1: rating descending, name ascending
     as the tiebreak (deterministic).

  3. **Scoring** a played round for a player, given the *current* ladder
     values: win → opponent's value; draw → half the opponent's value;
     loss → 0. A forfeit win (no game played) → half the player's *own*
     value, same as an unpaired bye; forfeit loss / double forfeit / a
     played "0-0" → 0. An excused absence (the `absent` flag, or the round
     listed in `absent_rounds`) → a third of the player's own value. An
     unpaired (odd-count) bye → half the player's own value. Rounds before
     a player's `start_round` → 0.

  4. **Retroactive recalculation.** Ranking and scoring are mutually
     dependent, so this is a fixed point: start from the initial rating
     order, assign values, score every round played so far, re-rank by
     total Keizer points (ties: rating desc, then name), reassign values,
     rescore every round again - repeat until the order stops changing or
     20 iterations, whichever comes first (guards against a pathological
     oscillation; the last iteration's order wins). Because every round is
     rescored with the *current* values on every iteration, an opponent you
     beat in round 1 who later climbs the list keeps increasing what that
     round-1 win is worth.

  5. **Pairing numbers.** The first time a Keizer tournament pairs a round,
     `pairing_number` is frozen over the tournament's active players exactly
     the way the Swiss path does (`PairingsEngine.Pairing.ensure_pairing_numbers/2`,
     reused rather than duplicated) - highest rating first, name ascending as
     the tie-break, then never reassigned. A newcomer who joins later gets a
     number the next time this runs, same as Swiss. Nothing about the ladder
     itself uses this number - it exists purely so the crosstable print and
     the player grid have a stable "Nr" to show.

  6. **Pairing** the next round takes the recalculated order (round 1: the
     initial rating order - scoring is a no-op with no rounds played, so
     this falls out of the fixed point for free), drops anyone not eligible
     this round (same eligibility Swiss pairing uses - see
     `PairingsEngine.Pairing.eligible_players/2` - they score an excused
     absence instead), then walks top-down pairing each unpaired player
     with the nearest unpaired player below them they haven't already
     played, backtracking (a small recursive matcher, nearest-first) when a
     dead end is hit. A `forbidden_pairings` pair is never paired; if a
     repeat is truly unavoidable the pair repeated longest ago is preferred
     over failing outright. An odd count gives the *bottom*-ranked eligible
     player the bye - stored the same way `PairingsEngine.Pairing` stores a
     pairing-allocated bye: a `pairings` row with no black player and
     `result: "bye"`, not a `byes`-table row (a `byes`-table row would be
     double-counted by `PairingsEngine.Standings`, which already reads
     `pairings.result == "bye"` for FIDE-style bye points - see
     `add_bye_records/1` there). Round-specific/permanent absences *do* get
     a `byes` row (`"requested-zero"` / `"absent"`), mirroring
     `PairingsEngine.Pairing.insert_round_absentee_byes/3`, so TRF export
     and any FIDE-facing view of a Keizer tournament still show something
     sensible for that round.

  7. **Colours**: the player with fewer games as White so far gets White;
     tied, the lower-ranked player (further down the list) gets White.
     Colour is never a reason to reject a pairing.

  `PairingsEngine.Pairing.pair_next_round/1` dispatches here for any
  tournament with `pairing_system: "keizer"`. Unlike that dispatcher's
  fallback (Swiss) clause, it does **not** broadcast on our behalf - see
  `PairingsEngine.Pairing.dispatch_stub/2` - so `pair_next_round/1` below
  broadcasts `:rounds` itself on success.
  """

  import Ecto.Query

  alias PairingsEngine.{Repo, Tournaments, Exclusions}
  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.{Player, Round, Pairing, Tournament}

  @max_iterations 20

  ## ---------- DB edge: pairing ----------

  @doc "Pairs the next round using the Keizer system."
  @spec pair_next_round(Tournament.t()) :: {:ok, Round.t()} | {:error, term()}
  def pair_next_round(%Tournament{} = tournament) do
    paired = Engine.paired_rounds_count(tournament.id)
    next_number = paired + 1
    eligible = Engine.eligible_players(tournament.id, next_number)

    cond do
      next_number > tournament.rounds_count ->
        {:error, "All #{tournament.rounds_count} rounds have already been paired"}

      length(eligible) < 2 ->
        {:error, "At least two active players are needed"}

      not Engine.round_complete?(tournament.id, paired) ->
        {:error, "Round #{paired} still has missing results"}

      true ->
        do_pair(tournament, next_number, eligible, paired)
    end
  end

  defp do_pair(tournament, next_number, eligible, paired_count) do
    # Freeze pairing_number exactly the way Swiss does (see
    # PairingsEngine.Pairing.ensure_pairing_numbers/2) - over the tournament's
    # active players (not just this round's eligible ones), so a player
    # excused for round 1 alone still gets a number. Without this, a Keizer
    # tournament's players never carry a pairing_number at all: the crosstable
    # print and the player grid's "Nr" column would show "?" forever.
    Engine.ensure_pairing_numbers(tournament, Engine.active_players(tournament.id))

    ladder_pool = ladder_players(tournament.id)
    {games, byes} = rounds_data(tournament.id, paired_count)

    %{order: order} =
      recalculate(ladder_pool, games, byes, tournament.keizer_top_value, paired_count)

    eligible_ids = MapSet.new(eligible, & &1.id)
    ranked_eligible = Enum.filter(order, &MapSet.member?(eligible_ids, &1.id))

    history = build_history(games)
    forbidden = read_forbidden(tournament, ladder_pool)

    case match_round(ranked_eligible, history, forbidden) do
      {:error, reason} ->
        {:error, "Could not pair round #{next_number}: #{reason}"}

      {:ok, pairs, bye_player} ->
        white_counts = build_white_counts(games)
        coloured = assign_colours(pairs, order, white_counts)

        case create_round(tournament, coloured, bye_player, next_number) do
          {:ok, _round} = result ->
            insert_absentee_byes(tournament, next_number, ladder_pool, eligible_ids)
            Tournaments.broadcast_tournament_change(tournament.id, :rounds)
            result

          error ->
            error
        end
    end
  end

  # Players still excluded for this round (in the ladder pool but not among
  # the eligible players actually paired) get a `byes` row so TRF
  # export/print/standings for a Keizer tournament see the round the same
  # way they would for a Swiss round-specific absence - see
  # `PairingsEngine.Pairing.insert_round_absentee_byes/3`. Only covers
  # `absent`/`absent_rounds` exclusions (the ones Keizer's own scoring
  # treats as "excused") - a withdrawn or forfeited player gets no row,
  # same as Swiss never creates one for them either.
  defp insert_absentee_byes(tournament, round_number, ladder_pool, eligible_ids) do
    rows =
      ladder_pool
      |> Enum.reject(&MapSet.member?(eligible_ids, &1.id))
      |> Enum.filter(&excused_absence?(&1, round_number))
      |> Enum.map(fn p ->
        # One type for both, since they are the same event: you only know
        # before pairing because the player told you. Keizer used to split
        # them, which meant a Keizer bye and a Keizer absence drew from
        # different settings for no reason a arbiter could see.
        %{tournament_id: tournament.id, player_id: p.id, round: round_number, type: "absent"}
      end)

    if rows != [], do: Repo.insert_all("byes", rows, on_conflict: :nothing)
    :ok
  end

  ## ---------- DB edge: standings ----------

  @doc """
  Ranked Keizer standings for `tournament`: one entry per ladder player,
  `%{rank:, player:, value:, points:, played:, wins:, draws:, losses:,
  raw_points:}` - `value` is the player's current ladder value, `points`
  their Keizer points (1 decimal), `raw_points` the same rounds scored in
  ordinary FIDE-style game points (win/draw/loss/bye_value from
  `tournament`), for an at-a-glance "how would this look under normal
  scoring" comparison.

  Accepts `through_round: n` to compute the ladder as it stood right after
  round `n` (rounds `<= n` only) - same idea as
  `PairingsEngine.Standings.standings/2`'s option of the same name, used by
  `PairingsEngineWeb.PrintController`'s `?round=n` standings print. Omit the
  option (or pass a round `>=` the latest paired round) for the current/
  overall ladder.
  """
  def standings(%Tournament{} = tournament, opts \\ []) do
    paired = Engine.paired_rounds_count(tournament.id)
    through = min(Keyword.get(opts, :through_round) || paired, paired)
    ladder_pool = ladder_players(tournament.id)
    {games, byes} = rounds_data(tournament.id, through)

    %{order: order, values: values, scored: scored} =
      recalculate(ladder_pool, games, byes, tournament.keizer_top_value, through)

    order
    |> Enum.with_index(1)
    |> Enum.map(fn {player, rank} ->
      entry = Map.fetch!(scored, player.id)
      stats = round_stats(entry.rounds, tournament)

      %{
        rank: rank,
        player: player,
        value: Map.fetch!(values, player.id),
        points: round_f(entry.points, 1),
        played: stats.played,
        wins: stats.wins,
        draws: stats.draws,
        losses: stats.losses,
        raw_points: stats.raw_points
      }
    end)
  end

  defp round_stats(entries, t) do
    Enum.reduce(entries, %{played: 0, wins: 0, draws: 0, losses: 0, raw_points: 0.0}, fn e, acc ->
      case e.class do
        :win ->
          %{
            acc
            | played: acc.played + 1,
              wins: acc.wins + 1,
              raw_points: acc.raw_points + t.points_win
          }

        :draw ->
          %{
            acc
            | played: acc.played + 1,
              draws: acc.draws + 1,
              raw_points: acc.raw_points + t.points_draw
          }

        :loss ->
          %{
            acc
            | played: acc.played + 1,
              losses: acc.losses + 1,
              raw_points: acc.raw_points + t.points_loss
          }

        :zero ->
          %{
            acc
            | played: acc.played + 1,
              losses: acc.losses + 1,
              raw_points: acc.raw_points + t.points_loss
          }

        :forfeit_win ->
          %{acc | wins: acc.wins + 1, raw_points: acc.raw_points + t.points_win}

        :forfeit_loss ->
          %{acc | losses: acc.losses + 1, raw_points: acc.raw_points + t.points_loss}

        :unpaired_bye ->
          %{acc | raw_points: acc.raw_points + t.bye_value}

        :excused ->
          acc

        :not_joined ->
          acc
      end
    end)
    |> Map.update!(:raw_points, &round_f(&1, 1))
  end

  ## ---------- DB edge: data extraction ----------

  # The full ladder pool considered for ranking/scoring - every non-withdrawn
  # player, regardless of `absent`/`forfeit` (those affect eligibility for
  # *pairing*, not whether a player stays on the list and keeps scoring
  # excused-absence fractions - see the module doc). Matches
  # `PairingsEngine.Standings`, which also doesn't filter by status.
  defp ladder_players(tournament_id) do
    tournament_id
    |> Tournaments.list_players()
    |> Enum.filter(&(&1.status == "active"))
  end

  defp rounds_data(_tournament_id, 0), do: {[], []}

  defp rounds_data(tournament_id, paired_count) do
    rounds =
      Repo.all(
        from r in Round,
          where: r.tournament_id == ^tournament_id and r.number <= ^paired_count,
          order_by: r.number,
          preload: [pairings: []]
      )

    games =
      for round <- rounds, p <- round.pairings do
        %{
          round: round.number,
          white_id: p.white_player_id,
          black_id: p.black_player_id,
          result: p.result
        }
      end

    byes =
      Repo.all(
        from b in "byes",
          where: b.tournament_id == ^tournament_id and b.round <= ^paired_count,
          select: %{round: b.round, player_id: b.player_id, type: b.type}
      )

    {games, byes}
  end

  # Unions explicit forbidden pairings with club/federation exclusion rules
  # (PairingsEngine.Exclusions - see docs/forbidden-pairings.md), both keyed
  # by `pair_key/2` (player ids) since that's the id space `match_round/3`
  # and friends already work in. `players` only needs to cover this round's
  # ladder pool - Exclusions.excluded_pairs/2 only ever produces pairs drawn
  # from whatever list it's given.
  defp read_forbidden(tournament, players) do
    explicit =
      tournament.id
      |> Tournaments.list_forbidden_pairings()
      |> MapSet.new(&pair_key(&1.player_a_id, &1.player_b_id))

    exclusions =
      tournament
      |> Exclusions.excluded_pairs(players)
      |> MapSet.new(fn {a, b} -> pair_key(a.id, b.id) end)

    MapSet.union(explicit, exclusions)
  end

  defp create_round(tournament, coloured_pairs, bye_player, next_number) do
    Repo.transaction(fn ->
      round =
        Repo.insert!(%Round{
          tournament_id: tournament.id,
          number: next_number,
          status: "playing",
          published_at: Tournaments.compute_published_at(tournament, next_number)
        })

      coloured_pairs
      |> Enum.with_index(1)
      |> Enum.each(fn {{white, black}, board} ->
        Repo.insert!(%Pairing{
          round_id: round.id,
          board: board,
          white_player_id: white.id,
          black_player_id: black.id,
          result: ""
        })
      end)

      if bye_player do
        Repo.insert!(%Pairing{
          round_id: round.id,
          board: length(coloured_pairs) + 1,
          white_player_id: bye_player.id,
          black_player_id: nil,
          result: "bye"
        })
      end

      Tournaments.freeze_round_display_boards!(round.id)

      round
    end)
  end

  ## ---------- pure core: ladder values ----------

  @doc """
  The effective Keizer top value: `top_value_config` if set, otherwise
  `2 * n` (automatic), floored at `n + 1` so the bottom rung's value stays
  positive.
  """
  def effective_top_value(top_value_config, n) do
    base = top_value_config || 2 * n
    max(base, n + 1)
  end

  @doc "Initial (round-1) ladder order: rating descending, name ascending."
  def initial_order(players), do: Enum.sort_by(players, &{-Player.rating(&1), &1.name})

  @doc "Ladder values for `order` (best first) given `top`: player i (1-based) is worth `top - (i - 1)`."
  def assign_values(order, top) do
    order
    |> Enum.with_index()
    |> Map.new(fn {p, idx} -> {p.id, top - idx} end)
  end

  ## ---------- pure core: retroactive recalculation ----------

  @doc """
  Runs the Keizer fixed point for `players` given every round's `games`
  (plain maps `%{round:, white_id:, black_id: id | nil, result:}` - a bye
  is `black_id: nil, result: "bye"`, same shape as `pairings` rows) and
  `byes` (plain maps `%{round:, player_id:, type:}`, same shape as `byes`
  rows), over `rounds_count` completed rounds.

  Returns `%{order:, values:, scored:, top_value:, iterations:}` - `order`
  is the final ranked player list (best first), `values` a `%{player_id =>
  integer}` map, `scored` a `%{player_id => %{points:, rounds: [%{round:,
  class:, points:, opponent_id:}]}}` map, `iterations` how many
  assign/score/re-rank passes it took (capped at 20 - a value of 20 means
  the ranking was still changing and the cap, not convergence, ended it).
  """
  def recalculate(players, games, byes, top_value_config, rounds_count) do
    top = effective_top_value(top_value_config, length(players))
    {order, iterations} = converge(initial_order(players), games, byes, top, rounds_count, 1)
    values = assign_values(order, top)
    scored = score_all(order, games, byes, values, rounds_count)

    %{order: order, values: values, scored: scored, top_value: top, iterations: iterations}
  end

  defp converge(order, games, byes, top, rounds_count, iteration) do
    values = assign_values(order, top)
    scored = score_all(order, games, byes, values, rounds_count)
    new_order = rerank(order, scored)

    cond do
      ids(new_order) == ids(order) -> {order, iteration}
      iteration >= @max_iterations -> {new_order, iteration}
      true -> converge(new_order, games, byes, top, rounds_count, iteration + 1)
    end
  end

  defp rerank(order, scored) do
    Enum.sort_by(order, fn p ->
      entry = Map.fetch!(scored, p.id)
      {-entry.points, -Player.rating(p), p.name}
    end)
  end

  defp ids(order), do: Enum.map(order, & &1.id)

  ## ---------- pure core: scoring ----------

  @doc """
  Scores every player in `players` over rounds `1..rounds_count`, given the
  current ladder `values`. Returns `%{player_id => %{points:, rounds:
  [%{round:, class:, points:, opponent_id:}]}}` - `class` is one of `:win`,
  `:draw`, `:loss`, `:forfeit_win`, `:forfeit_loss`, `:half_win`, `:half_loss`
  (VCL.13's asymmetric "1/2-0"/"0-1/2" - scored like `:draw`/`:loss`
  respectively, since the ½ side earned the same value as an ordinary draw),
  `:zero` (played "0-0" or otherwise unaccounted), `:unpaired_bye`,
  `:excused`, `:not_joined`.
  """
  def score_all(players, games, byes, values, rounds_count) do
    games_by_round = Enum.group_by(games, & &1.round)
    byes_by_round = Enum.group_by(byes, & &1.round)
    rounds = if rounds_count > 0, do: Enum.to_list(1..rounds_count), else: []

    Map.new(players, fn p ->
      entries = Enum.map(rounds, &score_round(p, &1, games_by_round, byes_by_round, values))
      points = entries |> Enum.map(& &1.points) |> Enum.sum()
      {p.id, %{points: points, rounds: entries}}
    end)
  end

  @doc "Scores a single player's single round. Exposed for focused fraction tests."
  def score_round(player, round_number, games_by_round, byes_by_round, values) do
    cond do
      round_number < (player.start_round || 1) ->
        %{round: round_number, class: :not_joined, points: 0.0, opponent_id: nil}

      game =
          Enum.find(
            games_by_round[round_number] || [],
            &(&1.white_id == player.id or &1.black_id == player.id)
          ) ->
        score_game(player, game, values)

      bye = Enum.find(byes_by_round[round_number] || [], &(&1.player_id == player.id)) ->
        {class, fraction} = bye_class_and_fraction(bye.type)

        %{
          round: round_number,
          class: class,
          points: own(values, player) * fraction,
          opponent_id: nil
        }

      excused_absence?(player, round_number) ->
        %{round: round_number, class: :excused, points: own(values, player) / 3, opponent_id: nil}

      true ->
        %{round: round_number, class: :zero, points: 0.0, opponent_id: nil}
    end
  end

  defp score_game(player, game, values) do
    white? = game.white_id == player.id
    opponent_id = if white?, do: game.black_id, else: game.white_id

    if game.result == "bye" or opponent_id == nil do
      %{
        round: game.round,
        class: :unpaired_bye,
        points: own(values, player) / 2,
        opponent_id: nil
      }
    else
      class = classify_result(game.result, white?)
      points = class_points(class, player, opponent_id, values)
      %{round: game.round, class: class, points: points, opponent_id: opponent_id}
    end
  end

  # Mirrors PairingsEngine.Pairing's result semantics (see `trf_game/3`
  # there): forfeits/double-forfeits are always unplayed for both sides;
  # played "0-0" is a played game where both lose.
  defp classify_result(result, white?) do
    case {result, white?} do
      {"1-0", true} -> :win
      {"1-0", false} -> :loss
      {"0-1", true} -> :loss
      {"0-1", false} -> :win
      {"1/2-1/2", _} -> :draw
      {"1/2-0", true} -> :half_win
      {"1/2-0", false} -> :half_loss
      {"0-1/2", true} -> :half_loss
      {"0-1/2", false} -> :half_win
      {"1-0FF", true} -> :forfeit_win
      {"1-0FF", false} -> :forfeit_loss
      {"0-1FF", true} -> :forfeit_loss
      {"0-1FF", false} -> :forfeit_win
      {"0-0FF", _} -> :forfeit_loss
      {"0-0", _} -> :zero
      {"+--", true} -> :forfeit_win
      {"+--", false} -> :forfeit_loss
      {"--+", true} -> :forfeit_loss
      {"--+", false} -> :forfeit_win
      _ -> :zero
    end
  end

  defp class_points(:win, _p, opponent_id, values), do: own_id(values, opponent_id)
  defp class_points(:draw, _p, opponent_id, values), do: own_id(values, opponent_id) / 2
  defp class_points(:loss, _p, _o, _v), do: 0.0
  defp class_points(:half_win, _p, opponent_id, values), do: own_id(values, opponent_id) / 2
  defp class_points(:half_loss, _p, _o, _v), do: 0.0
  defp class_points(:forfeit_win, p, _o, values), do: own(values, p) / 2
  defp class_points(:forfeit_loss, _p, _o, _v), do: 0.0
  defp class_points(:zero, _p, _o, _v), do: 0.0

  # "pairing-allocated"/"requested-half" are half-point byes (no game
  # played, unpaired) - same bucket as an odd-count bye.
  # "requested-zero"/"absent" are excused absences - a third.
  defp bye_class_and_fraction(type) when type in ["pairing-allocated", "requested-half"],
    do: {:unpaired_bye, 1 / 2}

  defp bye_class_and_fraction(_type), do: {:excused, 1 / 3}

  defp own(values, player), do: Map.get(values, player.id, 0)
  defp own_id(values, id), do: Map.get(values, id, 0)

  defp excused_absence?(player, round_number) do
    player.absent || round_number in parse_absent_rounds(player.absent_rounds)
  end

  defp parse_absent_rounds(nil), do: []
  defp parse_absent_rounds(""), do: []

  defp parse_absent_rounds(rounds) when is_binary(rounds) do
    rounds
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.to_integer/1)
  end

  ## ---------- pure core: pairing ----------

  @no_valid_pairing "no valid pairing (forbidden pairings block every option)"

  @doc """
  Pairs `players` (ranked best-first, already restricted to this round's
  eligible players) into `{:ok, [{p1, p2}, ...], bye_player_or_nil}`, given
  `history` (`%{pair_key => last_round_played}`, see `pair_key/2`) and
  `forbidden` (a `MapSet` of `pair_key/2` results). Pairs top-down -
  nearest first, never-played preferred over a repeat, backtracking when a
  candidate leads to a dead end further down. An odd-length list gives the
  bye to the lowest-ranked player it can - that's the strong preference,
  but if giving them the bye would leave the rest impossible to pair (a
  forbidden pair with no other option), the next-lowest-ranked candidate is
  tried instead, and so on. Returns `{:error, reason}` only if no valid
  pairing exists at all no matter who takes the bye.
  """
  def match_round(players, history, forbidden) do
    if rem(length(players), 2) == 1 do
      match_with_bye(players, history, forbidden)
    else
      case pair_list(players, history, forbidden) do
        {:ok, pairs} -> {:ok, pairs, nil}
        :error -> {:error, @no_valid_pairing}
      end
    end
  end

  defp match_with_bye(players, history, forbidden) do
    players
    |> Enum.reverse()
    |> Enum.reduce_while({:error, @no_valid_pairing}, fn candidate, _acc ->
      case pair_list(List.delete(players, candidate), history, forbidden) do
        {:ok, pairs} -> {:halt, {:ok, pairs, candidate}}
        :error -> {:cont, {:error, @no_valid_pairing}}
      end
    end)
  end

  defp pair_list([], _history, _forbidden), do: {:ok, []}

  defp pair_list([top | rest], history, forbidden) do
    candidates = Enum.reject(rest, &forbidden?(top, &1, forbidden))
    fresh = Enum.reject(candidates, &played?(top, &1, history))

    with :error <- try_candidates(top, fresh, rest, history, forbidden) do
      repeats =
        candidates
        |> Enum.filter(&(&1 not in fresh))
        |> Enum.sort_by(&last_played(top, &1, history))

      try_candidates(top, repeats, rest, history, forbidden)
    end
  end

  defp try_candidates(_top, [], _rest, _history, _forbidden), do: :error

  defp try_candidates(top, [candidate | more], rest, history, forbidden) do
    case pair_list(List.delete(rest, candidate), history, forbidden) do
      {:ok, pairs} -> {:ok, [{top, candidate} | pairs]}
      :error -> try_candidates(top, more, rest, history, forbidden)
    end
  end

  @doc "Order-insensitive key for a pair of player ids - `{a, b}` and `{b, a}` are the same pair."
  def pair_key(a, b), do: {min(a, b), max(a, b)}

  defp forbidden?(a, b, forbidden), do: MapSet.member?(forbidden, pair_key(a.id, b.id))
  defp played?(a, b, history), do: Map.has_key?(history, pair_key(a.id, b.id))
  defp last_played(a, b, history), do: Map.get(history, pair_key(a.id, b.id), 0)

  @doc "Builds the `pair_key/2 => last_round_played` history map from `games` (real, non-bye pairings only)."
  def build_history(games) do
    games
    |> Enum.filter(&(&1.black_id != nil and &1.result != "bye"))
    |> Enum.reduce(%{}, fn g, acc ->
      Map.update(acc, pair_key(g.white_id, g.black_id), g.round, &max(&1, g.round))
    end)
  end

  ## ---------- pure core: colours ----------

  @doc """
  Assigns colours to `pairs` (as returned by `match_round/3`): the player
  with fewer games as White so far gets White; tied, the lower-ranked
  player (further down `order`) gets White. Returns `[{white, black}, ...]`.
  """
  def assign_colours(pairs, order, white_counts) do
    rank_index = order |> Enum.with_index() |> Map.new(fn {p, i} -> {p.id, i} end)

    Enum.map(pairs, fn {a, b} ->
      wc_a = Map.get(white_counts, a.id, 0)
      wc_b = Map.get(white_counts, b.id, 0)

      cond do
        wc_a < wc_b -> {a, b}
        wc_b < wc_a -> {b, a}
        Map.fetch!(rank_index, a.id) > Map.fetch!(rank_index, b.id) -> {a, b}
        true -> {b, a}
      end
    end)
  end

  @doc "Builds the `player_id => games played as White` map from `games` (real, non-bye pairings only)."
  def build_white_counts(games) do
    games
    |> Enum.filter(&(&1.black_id != nil and &1.result != "bye"))
    |> Enum.reduce(%{}, fn g, acc -> Map.update(acc, g.white_id, 1, &(&1 + 1)) end)
  end

  ## ---------- shared ----------

  defp round_f(value, precision), do: Float.round(value / 1, precision)
end
