defmodule PairingsEngine.PrintScheduleTest do
  @moduledoc """
  The printed schedule promises that a round printed before it is paired is
  the round pairing will write. These tests hold it to that: print every
  round, pair them, and compare board by board - labels, both players,
  colours and the byes.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Pairing, PrintSchedule, Repo, RoundRobin, StartingNumbers, Tournaments}
  alias PairingsEngine.Tournaments.Tournament

  import PairingsEngine.TeamFixtures

  defp round_robin(players, attrs \\ %{}) do
    t =
      Repo.insert!(
        struct(
          Tournament,
          Map.merge(
            %{
              name: "Schedule RR",
              type: "roundrobin",
              pairing_system: "round_robin",
              rounds_count: 3,
              rr_cycles: 1
            },
            attrs
          )
        )
      )

    for {name, rating} <- players do
      {:ok, _} =
        Tournaments.create_player(t.id, %{"name" => name, "fide_rating" => "#{rating}"})
    end

    Repo.reload!(t)
  end

  defp field(n), do: for(i <- 1..n, do: {"Player #{i}", 2400 - i * 10})

  # A round as `{[{label, white_id, black_id}], [bye player ids]}` - the
  # printed shape and the paired shape reduced to the same thing.
  defp shape(round) do
    boards =
      Enum.map(round.rows, fn %{pairing: p, board: board} ->
        {board, p.white_player_id, p.black_player_id}
      end)

    {boards, round.byes |> Enum.map(& &1.player.id) |> Enum.sort()}
  end

  defp printed(t) do
    {:ok, schedule} = PrintSchedule.individual(Repo.reload!(t))
    schedule
  end

  defp assert_prints_what_pairs(t) do
    before = printed(t)
    assert Enum.any?(before.rounds, & &1.projected?)

    {:ok, _} = RoundRobin.pair_all_rounds(Repo.reload!(t))
    after_pairing = printed(t)

    assert after_pairing.certainty == :final
    assert length(after_pairing.rounds) == length(before.rounds)

    for {planned, paired} <- Enum.zip(before.rounds, after_pairing.rounds) do
      assert paired.paired?
      assert shape(planned) == shape(paired), "round #{paired.number} differs from its print"
    end

    {before, after_pairing}
  end

  describe "individual round robin: what is printed is what is paired" do
    test "an even field, nothing paired yet" do
      t = round_robin(field(6))
      {before, _} = assert_prints_what_pairs(t)
      assert before.certainty == :until_round_one
      assert length(before.rounds) == 5
    end

    test "an odd double round robin with the last two rounds reversed, byes included" do
      t = round_robin(field(5), %{rr_cycles: 2, rr_reverse_last_two: true})
      {before, _} = assert_prints_what_pairs(t)

      assert length(before.rounds) == 10
      # One bye a round, everyone twice.
      byes = Enum.flat_map(before.rounds, & &1.byes)
      assert length(byes) == 10
      assert byes |> Enum.frequencies_by(& &1.player.id) |> Map.values() |> Enum.uniq() == [2]
    end

    test "match format" do
      t = round_robin(field(4), %{rr_match_format: true})
      {before, _} = assert_prints_what_pairs(t)
      assert length(before.rounds) == 6
    end

    test "after round 1, the rest of the table is certain and still matches" do
      t = round_robin(field(7))
      {:ok, _} = Pairing.pair_next_round(Repo.reload!(t))

      mid = printed(t)
      assert mid.certainty == :table
      assert mid.first_unpaired == 2
      assert hd(mid.rounds).paired?

      # A late entry is not in a frozen table, on paper or in the pairing.
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => "Late", "fide_rating" => "2500"})
      assert_prints_what_pairs(t)
    end

    test "starting numbers set by hand, and an entry after them, before round 1" do
      t = round_robin(field(4))
      {:ok, _} = StartingNumbers.draw_lots_seeded(Repo.reload!(t), 42)
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => "Newcomer", "fide_rating" => "2600"})

      {before, _} = assert_prints_what_pairs(t)
      assert length(before.rounds) == 5
    end

    test "a withdrawal before round 1 leaves the table, a withdrawal after it does not" do
      t = round_robin(field(5))
      gone = Enum.find(Tournaments.list_players(t.id), &(&1.name == "Player 2"))
      {:ok, _} = Tournaments.update_player(gone, %{"status" => "withdrawn"})

      {before, _} = assert_prints_what_pairs(t)

      ids =
        for r <- before.rounds,
            %{pairing: p} <- r.rows,
            do: [p.white_player_id, p.black_player_id]

      refute gone.id in List.flatten(ids)
    end

    test "a player with a fixed table keeps the label pairing freezes" do
      t = round_robin(field(6))
      fixed = Enum.find(Tournaments.list_players(t.id), &(&1.name == "Player 6"))
      {:ok, _} = Tournaments.update_player(fixed, %{"fixed_board" => "100"})

      {before, _} = assert_prints_what_pairs(t)
      assert Enum.any?(before.rounds, fn r -> Enum.any?(r.rows, &(&1.board == "100")) end)
    end

    test "two tables, one per category" do
      t =
        round_robin(field(6), %{
          categories: ["A", "B"],
          categories_enabled: true,
          pair_by_category: true
        })

      for p <- Tournaments.list_players(t.id) do
        cat = if p.fide_rating >= 2370, do: "A", else: "B"
        {:ok, _} = Tournaments.update_player(p, %{"categories" => [cat]})
      end

      assert_prints_what_pairs(t)
    end

    test "fewer than two players is refused" do
      t = round_robin(field(1))
      assert {:error, :too_few_players} = PrintSchedule.individual(t)
    end
  end

  describe "a Swiss" do
    test "has only its paired rounds; the rest are empty, nothing is invented" do
      t = round_robin(field(4), %{pairing_system: "swiss", type: "swiss", rounds_count: 3})
      {:ok, _} = Pairing.pair_next_round(Repo.reload!(t))

      {:ok, s} = PrintSchedule.individual(Repo.reload!(t))
      assert s.certainty == :swiss
      assert [%{paired?: true}, %{rows: [], projected?: false}, %{rows: []}] = s.rounds
    end
  end

  describe "team round robin: what is printed is what is paired" do
    defp team_shape(round) do
      Enum.map(round.matches, fn m ->
        {m.number, m.team_a.id, m.team_b && m.team_b.id,
         Enum.map(m.boards, &{&1.k, &1.white && &1.white.id, &1.black && &1.black.id})}
      end)
    end

    test "five teams, every round, matches and boards" do
      {t, _teams} =
        team_round_robin(
          for(i <- 1..5, do: {"T#{i}", [2100 - i * 10, 2000 - i * 10, 1900 - i * 10]}),
          boards: 2
        )

      {:ok, before} = PrintSchedule.team(t)
      assert before.certainty == :until_round_one
      assert length(before.rounds) == 5

      t = pair_all!(t)
      {:ok, after_pairing} = PrintSchedule.team(t)
      assert after_pairing.certainty == :final

      for {planned, paired} <- Enum.zip(before.rounds, after_pairing.rounds) do
        assert team_shape(planned) == team_shape(paired), "round #{paired.number} differs"
      end
    end

    test "teams seeded by rating before round 1 print in that order" do
      {t, _teams} =
        team_round_robin(
          [
            {"Weak", [1500, 1500]},
            {"Strong", [2500, 2500]},
            {"Middle", [2000, 2000]},
            {"Low", [1400, 1400]}
          ],
          teams_ordered_by_hand: false
        )

      {:ok, before} = PrintSchedule.team(t)
      t = pair_all!(t)
      {:ok, after_pairing} = PrintSchedule.team(t)

      for {planned, paired} <- Enum.zip(before.rounds, after_pairing.rounds) do
        assert team_shape(planned) == team_shape(paired)
      end
    end

    test "team_rows: every team plays or sits out each round of a single cycle" do
      {t, [t1 | _]} = team_round_robin(for(i <- 1..4, do: {"T#{i}", [2000, 1900]}))
      {:ok, s} = PrintSchedule.team(t)

      rows = PrintSchedule.team_rows(s, t1)
      assert length(rows) == 3
      assert rows |> Enum.map(& &1.opponent.id) |> Enum.uniq() |> length() == 3
    end
  end
end
