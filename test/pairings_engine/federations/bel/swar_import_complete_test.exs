defmodule PairingsEngine.Federations.BEL.SwarImportCompleteTest do
  @moduledoc """
  What a SWAR file brings with it beyond players and games
  (docs/swar-import.md, "Import and export: what goes where"): extra points
  counted as SWAR counts them, SWAR's "separate categories", its seed order
  as pairing numbers - so a round robin continued here plays SWAR's own
  Berger table - its FIDE homologation, and its initial colour.
  """

  use PairingsEngine.DataCase, async: false

  import Ecto.Query

  alias PairingsEngine.{Repo, RoundRobin, Standings, SwarFixture, Tournaments}
  alias PairingsEngine.Federations.BEL.SwarImport
  alias PairingsEngine.Tournaments.Pairing

  @moduletag :tmp_dir

  defp import!(dir, opts) do
    path = SwarFixture.write!(dir, SwarFixture.build(opts))
    assert {:ok, t, warnings} = SwarImport.import_file(path)
    {Repo.reload!(t), warnings}
  end

  defp by_name(t), do: Map.new(Tournaments.list_players(t.id), &{&1.name, &1})

  # Every board of `round`, as `{white name, black name}` or `{name, :bye}`.
  defp boards(t, round) do
    names = Map.new(Tournaments.list_players(t.id), &{&1.id, &1.name})
    %{id: round_id} = Tournaments.get_round(t.id, round)

    from(p in Pairing, where: p.round_id == ^round_id, order_by: p.board)
    |> Repo.all()
    |> Enum.map(fn p -> {names[p.white_player_id], names[p.black_player_id] || :bye} end)
  end

  describe "extra points" do
    test "a Swiss that gives extra points counts them, as SWAR does", %{tmp_dir: dir} do
      {t, warnings} =
        import!(dir, %{
          nb_rounds: 1,
          players: [%{ni: 1, name: "A", extra_pts: 4}, %{ni: 2, name: "B"}],
          games: [{1, 1, 1, 2, :draw}]
        })

      assert t.count_extra_points
      assert by_name(t)["A"].extra_points == 1.0
      assert [first | _] = Standings.standings(t)
      assert first.player.name == "A"
      assert Enum.any?(warnings, &(is_binary(&1) and &1 =~ "count in the standings here"))
    end

    test "a round robin has none, as SWAR's loader zeroes them", %{tmp_dir: dir} do
      {t, _} =
        import!(dir, %{
          nb_rounds: 1,
          tournament: %{type: 4},
          players: [%{ni: 1, name: "A", extra_pts: 4}, %{ni: 2, name: "B"}],
          games: [{1, 1, 1, 2, :draw}]
        })

      refute t.count_extra_points
      assert by_name(t)["A"].extra_points == 0.0
    end

    test "a file without extra points leaves the setting off", %{tmp_dir: dir} do
      {t, _} = import!(dir, %{nb_rounds: 1, players: [%{ni: 1}, %{ni: 2}]})
      refute t.count_extra_points
    end
  end

  describe "categories" do
    test "a file with categories imports with them switched on", %{tmp_dir: dir} do
      {t, _} =
        import!(dir, %{
          categories: {5, ["A", "B"], []},
          players: [%{ni: 1, cat_index: 100}, %{ni: 2, cat_index: 200}]
        })

      assert t.categories_enabled
      refute t.categories_ranked_separately
      refute t.pair_by_category
    end

    test "SWAR's separate categories: paired and ranked separately", %{tmp_dir: dir} do
      {t, _} =
        import!(dir, %{
          tournament: %{cat_separes: 1},
          categories: {2, ["-12", "-16"], []},
          players: [%{ni: 1, cat_index: 100}, %{ni: 2, cat_index: 200}]
        })

      assert t.categories_enabled and t.pair_by_category and t.categories_ranked_separately
    end

    test "separate categories without any categories changes nothing", %{tmp_dir: dir} do
      {t, _} = import!(dir, %{tournament: %{cat_separes: 1}, players: [%{ni: 1}, %{ni: 2}]})
      refute t.categories_enabled or t.categories_ranked_separately or t.pair_by_category
    end

    test "direct encounter is decided inside the category", %{tmp_dir: dir} do
      # Two groups of four (SWAR's Rokade Rapid has sixteen). In each, the
      # second seed beat the first and both end on 2 points - so do the
      # first two of the other group. Ranked as one field, the four players
      # on 2 points have not all met and direct encounter decides nothing
      # (the list runs out and the names order them: N1 before N2). Ranked
      # per category, as SWAR's separate categories are, N2 is first.
      games = fn [a, b, c, d], board ->
        [
          {1, board, a, d, :white_wins},
          {1, board + 1, b, c, :black_wins},
          {2, board, c, a, :black_wins},
          {2, board + 1, d, b, :black_wins},
          {3, board, b, a, :white_wins},
          {3, board + 1, c, d, :draw}
        ]
      end

      opts = %{
        nb_rounds: 3,
        tournament: %{type: 4, cat_separes: 1},
        categories: {5, ["North", "South"], []},
        tiebreaks: [8],
        players:
          for {name, ni} <- Enum.with_index(~w(N1 N2 N3 N4 S1 S2 S3 S4), 1) do
            %{
              ni: ni,
              name: name,
              rank: rem(ni - 1, 4) + 1,
              cat_index: if(ni <= 4, do: 100, else: 200)
            }
          end,
        games: games.([1, 2, 3, 4], 1) ++ games.([5, 6, 7, 8], 3)
      }

      {t, _} = import!(dir, opts)
      entries = Standings.standings(t)

      assert Enum.map(entries, &{&1.player.name, &1.category_place}) == [
               {"N2", 1},
               {"N1", 2},
               {"N3", 3},
               {"N4", 4},
               {"S2", 1},
               {"S1", 2},
               {"S3", 3},
               {"S4", 4}
             ]

      assert Enum.find(entries, &(&1.player.name == "N2")).tiebreaks["DE"] == 1.0

      # The same tournament ranked as one field.
      {:ok, one_field} =
        Tournaments.update_tournament(t, %{"categories_ranked_separately" => "false"})

      names = one_field |> Standings.standings() |> Enum.map(& &1.player.name)
      assert Enum.take(names, 4) == ~w(N1 N2 S1 S2)
    end
  end

  describe "pairing numbers are SWAR's seed order" do
    test "a Swiss numbers its players by Rank, not by registration", %{tmp_dir: dir} do
      {t, _} =
        import!(dir, %{
          players: [
            %{ni: 1, name: "Third", rank: 3},
            %{ni: 2, name: "First", rank: 1},
            %{ni: 3, name: "Second", rank: 2}
          ]
        })

      players = by_name(t)
      assert players["First"].pairing_number == 1
      assert players["Second"].pairing_number == 2
      assert players["Third"].pairing_number == 3
    end

    test "a round robin saved before pairing plays SWAR's Berger table", %{tmp_dir: dir} do
      # Five players, registered in an order that is not their seed. SWAR's
      # table (FIDE's Berger table for six, 6 being the free round) by Rank:
      #   round 1: 1-6, 2-5, 3-4   round 2: 6-4, 5-3, 1-2   round 3: 2-6, 3-1, 4-5
      {t, _} =
        import!(dir, %{
          nb_rounds: 5,
          tournament: %{type: 4},
          players: [
            %{ni: 1, name: "R5", rank: 5},
            %{ni: 2, name: "R3", rank: 3},
            %{ni: 3, name: "R1", rank: 1},
            %{ni: 4, name: "R4", rank: 4},
            %{ni: 5, name: "R2", rank: 2}
          ]
        })

      assert {:ok, 5} = RoundRobin.pair_all_rounds(t)

      assert Enum.sort(boards(t, 1)) == Enum.sort([{"R2", "R5"}, {"R3", "R4"}, {"R1", :bye}])
      assert Enum.sort(boards(t, 2)) == Enum.sort([{"R5", "R3"}, {"R1", "R2"}, {"R4", :bye}])
      assert Enum.sort(boards(t, 3)) == Enum.sort([{"R3", "R1"}, {"R4", "R5"}, {"R2", :bye}])
    end

    test "with separate categories, each category plays its own table", %{tmp_dir: dir} do
      {t, _} =
        import!(dir, %{
          nb_rounds: 3,
          tournament: %{type: 4, cat_separes: 1},
          categories: {5, ["A", "B"], []},
          players: [
            %{ni: 1, name: "A2", rank: 2, cat_index: 100},
            %{ni: 2, name: "B1", rank: 1, cat_index: 200},
            %{ni: 3, name: "A1", rank: 1, cat_index: 100},
            %{ni: 4, name: "B3", rank: 3, cat_index: 200},
            %{ni: 5, name: "A3", rank: 3, cat_index: 100},
            %{ni: 6, name: "B2", rank: 2, cat_index: 200}
          ]
        })

      assert {:ok, 3} = RoundRobin.pair_all_rounds(t)

      for round <- 1..3, {white, black} <- boards(t, round), black != :bye do
        assert String.first(white) == String.first(black), "#{white} met #{black}"
      end

      # Round 1 of a three-player table: 1-4 (the free round), 2-3.
      assert {"A2", "A3"} in boards(t, 1)
      assert {"A1", :bye} in boards(t, 1)
      assert {"B2", "B3"} in boards(t, 1)
    end

    test "a free round in a round robin continued here is worth SWAR's point", %{tmp_dir: dir} do
      {t, _} =
        import!(dir, %{
          nb_rounds: 3,
          tournament: %{type: 4},
          players: [%{ni: 1, name: "X", rank: 1}, %{ni: 2, rank: 2}, %{ni: 3, rank: 3}]
        })

      assert {:ok, _} = RoundRobin.pair_all_rounds(t)
      assert {"X", :bye} in boards(t, 1)
      assert Tournaments.list_byes_for_round(t.id, 1) == []

      x = Enum.find(Standings.standings(t), &(&1.player.name == "X"))
      assert x.points == 1.0
    end
  end

  describe "FIDE homologation and the initial colour" do
    test "the homologation tickbox and per-round ids", %{tmp_dir: dir} do
      {t, _} =
        import!(dir, %{
          tournament: %{fide_homolog: 1, fide_ids: [{1, 5, 111}, {3, 4, 222}, {0, 0, 333}]},
          players: [%{ni: 1}, %{ni: 2}]
        })

      assert t.fide_homologated
      assert t.event_code == "111, 222, 333"
      # 3-4 overlaps 1-5 and 333 has no rounds: only the first is a range.
      assert t.fide_id_ranges == [
               %{"fide_tournament_id" => "111", "from_round" => 1, "to_round" => 5}
             ]
    end

    test "SWAR's colour of the top seed in round 1", %{tmp_dir: dir} do
      {white, _} = import!(dir, %{tournament: %{appar_order: 0}, players: [%{ni: 1}]})
      {black, _} = import!(dir, %{tournament: %{appar_order: 1}, players: [%{ni: 1}]})
      {random, _} = import!(dir, %{tournament: %{appar_order: 2}, players: [%{ni: 1}]})

      assert white.initial_colour == "white"
      assert black.initial_colour == "black"
      assert random.initial_colour == "lot"
    end
  end
end
