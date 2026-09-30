defmodule PairingsEngine.NextRoundPreviewTest do
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.NextRoundPreviewFixture

  alias PairingsEngine.{NextRoundPreview, Repo, Tournaments}
  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.{Player, Round, Tournament}

  # Seats as `NextRoundPreview.seats/1` returns them.
  defp w(opponent, label), do: {opponent, :white, label}
  defp b(opponent, label), do: {opponent, :black, label}

  describe "classify/3 on constructed outcomes" do
    # One open game, three outcomes. Players 1-2 are fixed on board 1;
    # 3-4 keep their colours but move between boards 2 and 3; 5-6 swap
    # colours; 7, 8 and 9 meet each other or take the bye.
    defp three_outcomes do
      common = %{1 => w(2, "1"), 2 => b(1, "1")}

      [
        Map.merge(common, %{
          3 => w(4, "2"),
          4 => b(3, "2"),
          5 => w(6, "3"),
          6 => b(5, "3"),
          7 => w(8, "4"),
          8 => b(7, "4"),
          9 => {:bye, nil, "5"}
        }),
        Map.merge(common, %{
          3 => w(4, "3"),
          4 => b(3, "3"),
          5 => b(6, "2"),
          6 => w(5, "2"),
          7 => w(9, "4"),
          9 => b(7, "4"),
          8 => {:bye, nil, "5"}
        }),
        Map.merge(common, %{
          3 => w(4, "2"),
          4 => b(3, "2"),
          5 => w(6, "3"),
          6 => b(5, "3"),
          7 => w(8, "4"),
          8 => b(7, "4"),
          9 => {:bye, nil, "5"}
        })
      ]
      |> Enum.map(&{:ok, &1})
    end

    test "a fixed board, a shifting pair, a pair with open colours and open players" do
      assert {:ok, preview} = NextRoundPreview.classify(1, Enum.to_list(1..9), three_outcomes())

      assert preview.fixed == [%{label: "1", white: 1, black: 2}]
      assert preview.shifting == [%{white: 3, black: 4, labels: ["2", "3"]}]
      assert preview.colours_open == [%{players: [5, 6], labels: ["2", "3"]}]

      open = Map.new(preview.open, &{&1.player, &1})
      assert Map.keys(open) |> Enum.sort() == [7, 8, 9]
      assert Enum.sort(open[7].opponents) == [8, 9]
      assert MapSet.new(open[8].opponents) == MapSet.new([7, :bye])
      assert open[9].depends_on == [0]

      assert preview.bye.status == :open
      assert Enum.sort(preview.bye.candidates) == [8, 9]
      assert preview.bye.depends_on == [0]
      assert {preview.outcomes, preview.failed} == {3, 0}
    end

    test "a bye every outcome gives to the same player is fixed" do
      same = %{1 => w(2, "1"), 2 => b(1, "1"), 3 => {:bye, nil, "2"}}
      outcomes = List.duplicate({:ok, same}, 3)

      assert {:ok, preview} = NextRoundPreview.classify(1, [1, 2, 3], outcomes)
      assert preview.bye == %{status: :fixed, holder: 3, candidates: [3], depends_on: []}
      assert preview.open == []
      assert preview.fixed == [%{label: "1", white: 1, black: 2}]
    end

    test "no bye in any outcome" do
      same = %{1 => w(2, "1"), 2 => b(1, "1")}

      assert {:ok, preview} =
               NextRoundPreview.classify(1, [1, 2], List.duplicate({:ok, same}, 3))

      assert preview.bye.status == :none
    end

    test "which open games a player's board depends on" do
      # Two open games, nine outcomes (game 0 varies slowest). Player 1's
      # opponent follows game 1's result only; players 3-4 never move.
      outcomes =
        for g0 <- 0..2, g1 <- 0..2 do
          _ = g0
          opponent = if g1 == 0, do: 2, else: 5

          {:ok,
           %{
             1 => w(opponent, "2"),
             opponent => b(1, "2"),
             if(opponent == 2, do: 5, else: 2) => {:bye, nil, "3"},
             3 => w(4, "1"),
             4 => b(3, "1")
           }}
        end

      assert {:ok, preview} = NextRoundPreview.classify(2, [1, 2, 3, 4, 5], outcomes)
      open = Map.new(preview.open, &{&1.player, &1})

      assert open[1].depends_on == [1]
      assert Enum.sort(open[1].opponents) == [2, 5]
      assert preview.bye.depends_on == [1]
      assert preview.fixed == [%{label: "1", white: 3, black: 4}]
    end

    test "outcomes the real pairing would refuse are counted and left out of the comparison" do
      [first | _] = three_outcomes()
      outcomes = [first, {:error, "no legal pairing"}, first]

      assert {:ok, preview} = NextRoundPreview.classify(1, Enum.to_list(1..9), outcomes)
      assert {preview.outcomes, preview.failed, preview.failure} == {3, 1, "no legal pairing"}
      # Only the two identical outcomes are compared: everything is fixed.
      assert preview.open == []
      assert preview.bye.status == :fixed
    end

    test "no outcome could be paired" do
      assert {:error, {:all_failed, :boom}} =
               NextRoundPreview.classify(1, [1], List.duplicate({:error, :boom}, 3))
    end

    test "label_ranges/1" do
      assert NextRoundPreview.label_ranges(["3", "1", "2", "5", "30", "12/30"]) ==
               "1–3, 5, 30, 12/30"

      assert NextRoundPreview.label_ranges(["7"]) == "7"
      assert NextRoundPreview.label_ranges([]) == ""
    end

    test "worlds/1 enumerates 3^k outcomes, the first game varying slowest" do
      assert NextRoundPreview.worlds(1) == [[0], [1], [2]]
      assert length(NextRoundPreview.worlds(6)) == 729
      assert Enum.at(NextRoundPreview.worlds(2), 3) == [1, 0]
    end
  end

  describe "availability/1 and the cap" do
    test "only while the latest round has open games, up to the cap" do
      t = plain_tournament(16)
      assert NextRoundPreview.availability(reload(t)) == :unavailable

      pair!(t)
      assert NextRoundPreview.availability(reload(t)) == {:too_many, 8}

      finish_some(t, 2)
      assert NextRoundPreview.availability(reload(t)) == {:available, 6}
      assert NextRoundPreview.max_open_games() == 6

      finish_latest_round(t)
      assert NextRoundPreview.availability(reload(t)) == :unavailable
    end

    test "above the cap the preview refuses rather than approximating" do
      t = plain_tournament(16)
      pair!(t)
      finish_some(t, 1)

      assert NextRoundPreview.availability(reload(t)) == {:too_many, 7}
      assert NextRoundPreview.run(reload(t)) == {:error, {:too_many, 7}}
    end

    test "not with JaVaFo: one JVM per outcome" do
      t = plain_tournament(10, %{pairing_engine: "javafo"})
      # Paired by Ainalrami here, so no JVM is needed for the test itself.
      Repo.update_all(from(x in Tournament, where: x.id == ^t.id),
        set: [pairing_engine: "ainalrami"]
      )

      pair!(t)
      finish_some(t, 3)

      Repo.update_all(from(x in Tournament, where: x.id == ^t.id),
        set: [pairing_engine: "javafo"]
      )

      assert NextRoundPreview.availability(reload(t)) == :javafo
      assert NextRoundPreview.run(reload(t)) == {:error, :javafo}
    end

    test "not for the last round of the schedule, nor a read-only or team event" do
      t = plain_tournament(8, %{rounds_count: 1})
      pair!(t)
      assert NextRoundPreview.availability(reload(t)) == :unavailable

      t2 = plain_tournament(8)
      pair!(t2)

      Repo.update_all(from(x in Tournament, where: x.id == ^t2.id),
        set: [archived_at: DateTime.utc_now(:second)]
      )

      assert NextRoundPreview.availability(reload(t2)) == :unavailable
      assert NextRoundPreview.run(reload(t2)) == {:error, :read_only}

      assert NextRoundPreview.availability(%Tournament{
               id: t.id,
               type: "team-swiss",
               pairing_system: "swiss"
             }) == :unavailable
    end
  end

  describe "the preview's pairing is the real pairing" do
    test "every outcome of two open games, with most options on, pairs exactly as the real click" do
      t = options_tournament()
      pair!(t)
      finish_latest_round(t)
      pair!(t)
      finish_latest_round(t)
      pair!(t)
      # A late entrant joining next round, with no pairing number yet: the
      # preview numbers them in memory, the real pairing on disk.
      insert_player(t, 24, %{start_round: 4})
      leave_open(t, 2)

      assert_every_outcome_matches(t)
    end

    test "per category, with a one-player category's automatic bye" do
      t =
        Repo.insert!(%Tournament{
          name: "Categories",
          type: "swiss",
          rounds_count: 5,
          categories_enabled: true,
          pair_by_category: true,
          categories: ["A", "B", "C"]
        })

      for i <- 1..15 do
        category = if i == 15, do: "C", else: if(rem(i, 2) == 0, do: "A", else: "B")
        insert_player(t, i, %{category: category, categories: [category]})
      end

      pair!(t)
      finish_latest_round(t)
      pair!(t)
      leave_open(t, 2)

      assert_every_outcome_matches(t)
    end

    test "working out the preview writes nothing" do
      t = plain_tournament(12)
      pair!(t)
      finish_some(t, 3)
      insert_player(t, 13, %{start_round: 2})

      before = NextRoundPreview.fingerprint(t.id)
      rounds = Repo.aggregate(from(r in Round, where: r.tournament_id == ^t.id), :count)

      assert {:ok, preview} = NextRoundPreview.run(reload(t))
      assert preview.outcomes == 27
      assert preview.next_round == 2

      assert NextRoundPreview.fingerprint(t.id) == before
      assert Repo.aggregate(from(r in Round, where: r.tournament_id == ^t.id), :count) == rounds

      assert Repo.one(from p in Player, where: p.name == "Player 013", select: p.pairing_number) ==
               nil
    end

    test "progress is reported at the start, throttled in between, and at the end" do
      t = plain_tournament(12)
      pair!(t)
      finish_some(t, 3)
      test = self()

      assert {:ok, _preview} =
               NextRoundPreview.run(reload(t),
                 progress: fn done, total -> send(test, {:progress, done, total}) end,
                 progress_interval_ms: 60_000
               )

      # 27 outcomes, and a minute between reports: the start, the first
      # batch of outcomes done, and the last.
      reports = collect_progress([])
      assert List.first(reports) == {0, 27}
      assert List.last(reports) == {27, 27}
      assert length(reports) == 3
    end

    test "a fixed board of the preview is on that board whatever the results" do
      t = plain_tournament(20)
      pair!(t)
      finish_latest_round(t)
      pair!(t)
      leave_open(t, 2)

      assert {:ok, preview} = NextRoundPreview.run(reload(t))
      assert preview.fixed != []

      boards = real_boards_per_outcome(t)

      for fixed <- preview.fixed, real <- boards do
        assert {fixed.label, fixed.white, fixed.black} in real
      end
    end
  end

  defp collect_progress(acc) do
    receive do
      {:progress, done, total} -> collect_progress([{done, total} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Enters results so that exactly `open` boards of the latest round are
  # still without one.
  defp leave_open(t, open) do
    round = latest_round(t)
    games = round.pairings |> Enum.filter(&(&1.black_player_id && &1.result == ""))
    keep = games |> Enum.sort_by(& &1.board) |> Enum.take(open) |> MapSet.new(& &1.id)

    for p <- games, not MapSet.member?(keep, p.id) do
      {:ok, _} = Tournaments.update_pairing_result(p, default_result(p.board))
    end
  end

  defp finish_some(t, count) do
    round = latest_round(t)

    round.pairings
    |> Enum.filter(&(&1.black_player_id && &1.result == ""))
    |> Enum.sort_by(& &1.board)
    |> Enum.take(count)
    |> Enum.each(&({:ok, _} = Tournaments.update_pairing_result(&1, "1-0")))
  end

  # For every outcome of the open games: the preview's boards, then the same
  # results entered and the round really paired - which must agree board
  # for board, label and colours included - then unpaired and the results
  # taken back, for the next outcome.
  #
  # Both of the preview's ways to the engine are held to the real pairing:
  # the TRF built and read per outcome, and the field parsed once from the
  # first outcome and re-ranked per outcome (`Pairing.preview_base/2`) -
  # whose field must also be exactly what the engine would read off that
  # outcome's TRF.
  defp assert_every_outcome_matches(t) do
    {:ok, context} = Engine.preview_context(reload(t))
    games = NextRoundPreview.open_games(t.id, context.round_number)
    [first | _] = worlds = NextRoundPreview.worlds(length(games))
    fast = Engine.preview_base(context, NextRoundPreview.world_results(games, first))
    single_pool? = not context.tournament.pair_by_category

    assert fast.base != nil or not single_pool?

    for world <- worlds do
      results = NextRoundPreview.world_results(games, world)

      if single_pool? do
        [reranked, read] = Engine.preview_fields(fast, results)
        assert reranked == read, "outcome #{inspect(world)}: the re-ranked field differs"
      end

      previews =
        for ctx <- [context, fast] do
          {:ok, boards} = Engine.preview_round(ctx, results)
          seats = NextRoundPreview.seats(boards)

          boards
          |> Enum.map(fn {_board, white, black} ->
            {white_seat_label(seats, white.id), white.id, black && black.id}
          end)
          |> Enum.sort()
        end

      real = real_pairing(t, games, results)

      for preview <- previews do
        assert real == preview, "outcome #{inspect(world)} differs"
      end
    end
  end

  defp white_seat_label(seats, id), do: seats |> Map.fetch!(id) |> elem(2)

  defp real_pairing(t, games, results) do
    for g <- games do
      {:ok, _} = Tournaments.update_pairing_result(Repo.reload!(g), Map.fetch!(results, g.id))
    end

    round = pair!(t) |> Repo.preload(:pairings, force: true)
    round = Repo.get!(Round, round.id) |> Repo.preload(:pairings)

    boards =
      round.pairings
      |> Enum.map(&{&1.display_board, &1.white_player_id, &1.black_player_id})
      |> Enum.sort()

    :ok = Engine.delete_round(t.id, round.number)

    for g <- games do
      {:ok, _} = Tournaments.update_pairing_result(Repo.reload!(g), "")
    end

    boards
  end

  defp real_boards_per_outcome(t) do
    {:ok, context} = Engine.preview_context(reload(t))
    games = NextRoundPreview.open_games(t.id, context.round_number)

    for world <- NextRoundPreview.worlds(length(games)) do
      results =
        games
        |> Enum.zip(world)
        |> Map.new(fn {g, o} -> {g.id, Enum.at(NextRoundPreview.outcomes(), o)} end)

      real_pairing(t, games, results)
    end
  end
end
