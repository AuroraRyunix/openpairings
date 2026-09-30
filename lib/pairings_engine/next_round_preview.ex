defmodule PairingsEngine.NextRoundPreview do
  @moduledoc """
  "Which boards of the next round are already certain?" - for the arbiter
  who wants to put out name cards while the last games of a round are still
  being played.

  With `k` games of the current round still open, every combination of
  their results is tried - 1-0, ½-½ and 0-1 each, so `3^k` outcomes - and
  for each one the next round is paired by
  `PairingsEngine.Pairing.preview_round/2`: the real "pair next round"
  pipeline (`plan_round/4`), with the same options, run in memory. Nothing
  is saved. Comparing the outcomes, each board of the next round falls in
  one of four classes:

    1. **fixed** - the same two players, the same colours and the same
       board in every outcome: its cards can go out;
    2. **shifting** - the same two players with the same colours, but the
       board number depends on the results (the range is given);
    3. **colours open** - the same two players, colours depending on the
       results;
    4. **open** - everything else. For each open player: who they might
       meet, and which open games decide it.

  The pairing-allocated bye is fixed (the same player, or nobody, in every
  outcome) or open.

  Exact, and so capped: `max_open_games/0` open games at most (729
  outcomes). A forfeit is not tried as an outcome - it changes a colour
  history, and the arbiter who expects one can wait for it.

  The work runs in the caller's process: the Pairings page starts it with
  `start_async/4` under `PairingsEngine.TaskSupervisor`, and the outcomes
  are paired `concurrency/0` at a time. A finished preview is kept by
  `PairingsEngine.NextRoundPreview.Cache` against the `fingerprint/1` of
  the data it was worked out from, which is how the print view finds it.
  """

  import Ecto.Query

  alias PairingsEngine.{PairingDisplay, Repo, Tournaments}
  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}

  @max_open_games 6
  @outcomes ["1-0", "1/2-1/2", "0-1"]

  # How many outcomes are paired at once. The hosted server has two cores
  # and must stay responsive while it works, so one fewer than there are,
  # and never more than four.
  @max_concurrency 4

  @doc "The most open games the preview enumerates (`3^n` outcomes)."
  def max_open_games, do: @max_open_games

  @doc "The results each open game is tried with."
  def outcomes, do: @outcomes

  @doc false
  def concurrency do
    Application.get_env(
      :pairings_engine,
      :next_round_preview_concurrency,
      System.schedulers_online() |> Kernel.-(1) |> max(1) |> min(@max_concurrency)
    )
  end

  @doc """
  Whether the preview applies to `tournament` as it stands, cheaply enough
  for every refresh of the Pairings page:

    * `{:available, k}` - an individual Swiss whose latest round has `k`
      open games (`1..max_open_games/0`), with a next round to pair;
    * `{:too_many, k}` - the same, with more open games than the cap;
    * `:unavailable` - anything else: no open game, no next round in the
      schedule, not an individual Swiss, or read-only.
  """
  def availability(%Tournament{} = t) do
    with true <- individual_swiss?(t),
         :ok <- Tournaments.ensure_writable(t),
         paired when paired > 0 <- Engine.paired_rounds_count(t.id),
         true <- paired + 1 <= Engine.max_pairable_round(t) do
      case open_game_count(t.id, paired) do
        0 -> :unavailable
        k when k > @max_open_games -> {:too_many, k}
        k -> {:available, k}
      end
    else
      _ -> :unavailable
    end
  end

  defp individual_swiss?(t), do: t.pairing_system == "swiss" and not Tournament.team?(t)

  defp open_games_query(tournament_id, round_number) do
    from p in Pairing,
      join: r in Round,
      on: p.round_id == r.id,
      where:
        r.tournament_id == ^tournament_id and r.number == ^round_number and p.result == "" and
          not is_nil(p.white_player_id) and not is_nil(p.black_player_id)
  end

  defp open_game_count(tournament_id, round_number),
    do: Repo.aggregate(open_games_query(tournament_id, round_number), :count)

  @doc """
  The open games of round `round_number`: boards with two players and no
  result, in board order, players preloaded.
  """
  def open_games(tournament_id, round_number) do
    Repo.all(
      from p in open_games_query(tournament_id, round_number),
        order_by: p.board,
        preload: [:white_player, :black_player]
    )
  end

  @doc """
  A value that changes whenever anything the next round's pairing reads
  changes: the tournament's settings and its `data_version` (moved by every
  write to its players, rounds, pairings and byes - see
  `PairingsEngine.StandingsCache`), and its forbidden pairings.
  """
  def fingerprint(tournament_id) do
    case Repo.get(Tournament, tournament_id) do
      nil ->
        nil

      t ->
        forbidden =
          Repo.all(
            from f in PairingsEngine.Tournaments.ForbiddenPairing,
              where: f.tournament_id == ^tournament_id,
              order_by: f.id,
              select: {f.player_a_id, f.player_b_id, f.soft}
          )

        :erlang.phash2({Map.delete(t, :__meta__), forbidden})
    end
  end

  @doc """
  Works the preview out. `opts[:progress]`, if given, is called as
  `progress.(done, total)` as outcomes finish (about fifty times in all).

  `{:ok, preview}` - see `classify/3` for its shape, plus `:round`,
  `:next_round`, `:games` (the open games), `:players`
  (`%{id => %{name:, rating:}}`), `:fingerprint` and `:elapsed_ms` - or
  `{:error, reason}`: one of `preview_context/1`'s, `:no_open_games`,
  `{:too_many, k}`, or `{:all_failed, reason}` when no outcome could be
  paired at all.
  """
  def run(%Tournament{} = tournament, opts \\ []) do
    progress = Keyword.get(opts, :progress, fn _done, _total -> :ok end)
    started = System.monotonic_time(:millisecond)
    fingerprint = fingerprint(tournament.id)

    with {:ok, context} <- Engine.preview_context(tournament),
         games = open_games(tournament.id, context.round_number),
         :ok <- check_count(length(games)) do
      worlds = worlds(length(games))
      total = length(worlds)
      step = max(1, div(total, 50))
      player_ids = context.active |> Enum.map(& &1.id) |> Enum.sort()

      outcomes =
        worlds
        |> Task.async_stream(&pair_world(context, games, &1),
          max_concurrency: concurrency(),
          timeout: :infinity
        )
        |> Stream.with_index(1)
        |> Enum.map(fn {{:ok, outcome}, done} ->
          if rem(done, step) == 0 or done == total, do: progress.(done, total)
          outcome
        end)

      with {:ok, classified} <- classify(length(games), player_ids, outcomes) do
        {:ok,
         Map.merge(classified, %{
           round: context.round_number,
           next_round: context.next_number,
           games: Enum.map(games, &game_row/1),
           players: players_map(context.active),
           fingerprint: fingerprint,
           elapsed_ms: System.monotonic_time(:millisecond) - started
         })}
      end
    end
  end

  defp check_count(0), do: {:error, :no_open_games}
  defp check_count(k) when k > @max_open_games, do: {:error, {:too_many, k}}
  defp check_count(_k), do: :ok

  @doc """
  Every combination of outcome indices for `k` games, the first game
  varying slowest - so outcome `w` is the base-3 number `w` with one digit
  per game, which `classify/3` relies on to find two outcomes that differ
  in one game only.
  """
  def worlds(0), do: [[]]
  def worlds(k), do: for(o <- 0..2, rest <- worlds(k - 1), do: [o | rest])

  defp pair_world(context, games, world) do
    results =
      games
      |> Enum.zip(world)
      |> Map.new(fn {game, outcome} -> {game.id, Enum.at(@outcomes, outcome)} end)

    case Engine.preview_round(context, results) do
      {:ok, boards} -> {:ok, seats(boards)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  One outcome's boards as seats: `%{player_id => {opponent_id | :bye,
  :white | :black | nil, board label}}` (a player not seated has no
  entry). The label is the board number the sheet will print
  (`PairingsEngine.PairingDisplay.compute_labels/1` - a fixed table keeps
  its own number and the rest are numbered around it), exactly as the real
  pairing freezes it.
  """
  def seats(boards) do
    labels =
      boards
      |> Enum.map(fn {board, white, black} ->
        %Pairing{id: board, board: board, white_player: white, black_player: black}
      end)
      |> PairingDisplay.compute_labels()

    Enum.reduce(boards, %{}, fn {board, white, black}, acc ->
      label = labels |> Map.fetch!(board) |> Map.fetch!(:display_board)

      case black do
        nil ->
          Map.put(acc, white.id, {:bye, nil, label})

        black ->
          acc
          |> Map.put(white.id, {black.id, :white, label})
          |> Map.put(black.id, {white.id, :black, label})
      end
    end)
  end

  @doc """
  Compares the outcomes. `k` is the number of open games, `outcomes` one
  `{:ok, seats}` (`seats/1`) or `{:error, reason}` per outcome in
  `worlds/1` order. Only the outcomes that could be paired are compared;
  `{:error, {:all_failed, reason}}` when none could.

  Returns `{:ok, map}` with

    * `:outcomes` / `:failed` - how many outcomes, and how many of them the
      real pairing would refuse; `:failure` - the first such reason;
    * `:fixed` - `[%{label:, white:, black:}]`, in board order;
    * `:shifting` - `[%{white:, black:, labels:}]`;
    * `:colours_open` - `[%{players: [a, b], labels:}]`;
    * `:open` - `[%{player:, opponents:, depends_on:}]`: the opponents it
      meets in some outcome (`:bye` for the bye), and the indices of the
      open games whose result alone changes its board;
    * `:bye` - `%{status: :fixed | :none | :open, holder:, candidates:,
      depends_on:}`.
  """
  def classify(k, player_ids, outcomes) do
    paired =
      outcomes
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{:ok, seats}, index} -> [{index, seats}]
        _failed -> []
      end)

    failures = for {:error, reason} <- outcomes, do: reason

    case paired do
      [] ->
        {:error, {:all_failed, List.first(failures)}}

      [{_index, reference} | _] = paired ->
        {:ok,
         paired
         |> compare(reference, player_ids, k)
         |> Map.merge(%{
           outcomes: length(outcomes),
           failed: length(failures),
           failure: List.first(failures)
         })}
    end
  end

  defp compare(paired, reference, player_ids, k) do
    seated = Enum.filter(player_ids, &Map.has_key?(reference, &1))

    # For every seated player: does their opponent ever differ from the
    # reference outcome's, do their colours, and which board labels they
    # get. One pass over the outcomes.
    initial = Map.new(seated, &{&1, {true, true, MapSet.new()}})

    folded =
      Enum.reduce(paired, initial, fn {_index, seats}, acc ->
        Map.new(acc, fn {id, {same_opponent?, same_colour?, labels}} ->
          {ref_opponent, ref_colour, _} = Map.fetch!(reference, id)

          case Map.get(seats, id) do
            {opponent, colour, label} ->
              {id,
               {same_opponent? and opponent == ref_opponent,
                same_colour? and colour == ref_colour, MapSet.put(labels, label)}}

            nil ->
              {id, {false, false, labels}}
          end
        end)
      end)

    fixed_pair? = fn id ->
      {opponent, _, _} = Map.fetch!(reference, id)
      opponent != :bye and elem(Map.fetch!(folded, id), 0)
    end

    pairs =
      for id <- seated,
          {opponent, :white, _label} <- [Map.fetch!(reference, id)],
          fixed_pair?.(id) do
        {_, same_colour?, labels} = Map.fetch!(folded, id)
        %{white: id, black: opponent, same_colour?: same_colour?, labels: sort_labels(labels)}
      end

    {fixed, shifting} =
      pairs
      |> Enum.filter(& &1.same_colour?)
      |> Enum.split_with(&match?([_], &1.labels))

    colours_open =
      pairs
      |> Enum.reject(& &1.same_colour?)
      |> Enum.map(&%{players: [&1.white, &1.black], labels: &1.labels})
      |> Enum.sort_by(&label_order(hd(&1.labels)))

    bye = bye(paired, seated, k)
    in_fixed_pair = MapSet.new(pairs, & &1.white) |> MapSet.union(MapSet.new(pairs, & &1.black))

    open_ids =
      Enum.reject(seated, fn id ->
        MapSet.member?(in_fixed_pair, id) or (bye.status == :fixed and bye.holder == id)
      end)

    %{
      fixed:
        fixed
        |> Enum.map(&%{label: hd(&1.labels), white: &1.white, black: &1.black})
        |> Enum.sort_by(&label_order(&1.label)),
      shifting:
        shifting
        |> Enum.map(&Map.take(&1, [:white, :black, :labels]))
        |> Enum.sort_by(&label_order(hd(&1.labels))),
      colours_open: colours_open,
      open: open_players(open_ids, paired, k),
      bye: bye
    }
  end

  defp bye(paired, seated, k) do
    holders =
      paired
      |> Enum.map(fn {_index, seats} ->
        Enum.find(seated, fn id -> match?({:bye, _, _}, Map.get(seats, id)) end)
      end)
      |> Enum.uniq()

    case holders do
      [nil] ->
        %{status: :none, holder: nil, candidates: [], depends_on: []}

      [holder] ->
        %{status: :fixed, holder: holder, candidates: [holder], depends_on: []}

      holders ->
        holder_of = fn seats -> Enum.find(seated, &match?({:bye, _, _}, Map.get(seats, &1))) end

        %{
          status: :open,
          holder: nil,
          candidates: Enum.reject(holders, &is_nil/1),
          depends_on: depends_on(paired, k, holder_of)
        }
    end
  end

  defp open_players(open_ids, paired, k) do
    Enum.map(open_ids, fn id ->
      opponents =
        paired
        |> Enum.map(fn {_index, seats} -> seats |> Map.get(id) |> seat_opponent() end)
        |> Enum.uniq()

      %{
        player: id,
        opponents: opponents,
        depends_on: depends_on(paired, k, &(&1 |> Map.get(id) |> seat_without_label()))
      }
    end)
  end

  defp seat_opponent({opponent, _colour, _label}), do: opponent
  defp seat_opponent(nil), do: nil

  defp seat_without_label({opponent, colour, _label}), do: {opponent, colour}
  defp seat_without_label(nil), do: nil

  # The open games (by index) whose result alone changes `value_of.(seats)`:
  # game j is one when two outcomes that differ in game j only, both
  # paired, disagree. Outcome `w`'s result for game j is digit j of `w` in
  # base 3, the first game the most significant (`worlds/1`).
  defp depends_on(paired, k, value_of) do
    by_index = Map.new(paired, fn {index, seats} -> {index, value_of.(seats)} end)

    Enum.filter(0..(k - 1)//1, fn j ->
      weight = Integer.pow(3, k - 1 - j)

      Enum.any?(by_index, fn {index, value} ->
        digit = index |> div(weight) |> rem(3)

        Enum.any?((digit + 1)..2//1, fn other ->
          case Map.fetch(by_index, index + (other - digit) * weight) do
            {:ok, other_value} -> other_value != value
            :error -> false
          end
        end)
      end)
    end)
  end

  # Board labels are numbers, except a fixed table's ("30", or "12/30" for
  # two pinned players); numbers first, in numeric order.
  defp label_order(label) do
    case Integer.parse(label) do
      {n, ""} -> {0, n, label}
      _ -> {1, 0, label}
    end
  end

  defp sort_labels(labels), do: labels |> MapSet.to_list() |> Enum.sort_by(&label_order/1)

  @doc """
  Board labels compressed into ranges for a sentence: `["1", "2", "3",
  "5", "30"]` -> `"1–3, 5, 30"`.
  """
  def label_ranges(labels) do
    {numbers, others} =
      Enum.split_with(labels, &match?({_, ""}, Integer.parse(&1)))

    numbers
    |> Enum.map(&String.to_integer/1)
    |> Enum.sort()
    |> Enum.uniq()
    |> Enum.chunk_while(
      [],
      fn
        n, [] -> {:cont, [n]}
        n, [last | _] = acc when n == last + 1 -> {:cont, [n | acc]}
        n, acc -> {:cont, Enum.reverse(acc), [n]}
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
    |> Enum.map(fn
      [n] -> to_string(n)
      [first | rest] -> "#{first}–#{List.last(rest)}"
    end)
    |> Kernel.++(Enum.sort(others))
    |> Enum.join(", ")
  end

  defp game_row(%Pairing{} = p) do
    %{
      id: p.id,
      label: PairingDisplay.board_label(p),
      white: p.white_player.name,
      black: p.black_player.name
    }
  end

  defp players_map(players) do
    Map.new(players, fn p -> {p.id, %{name: p.name, rating: Player.rating(p)}} end)
  end
end
