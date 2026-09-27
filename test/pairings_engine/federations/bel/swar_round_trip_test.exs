defmodule PairingsEngine.Federations.BEL.SwarRoundTripTest do
  @moduledoc """
  Import -> export -> import gives the same tournament, one synthetic SWAR
  file per feature the import reads (`PairingsEngine.SwarFixture`).

  Two things are checked for each file:

    * the tournament the export re-imports as is the tournament that was
      exported - every column, player, board, bye and forbidden pair
      (`SwarFixture.snapshot/1`), bar the three SWAR settings a v7 file has
      no place for;
    * exporting that second tournament gives the same bytes as exporting
      the first - so nothing drifts on the way round, and a tournament can
      go to SWAR and back any number of times.

  The same check over the real SWAR files at hand is run by hand (they are
  real events and are never committed) - docs/swar-import.md, "Export:
  what the file holds".
  """

  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.SwarFixture
  alias PairingsEngine.Federations.BEL.{SwarExport, SwarImport}

  @moduletag :tmp_dir

  # Four players, three rounds, every kind of result and bye SWAR has.
  defp swiss(overrides \\ %{}) do
    Map.merge(
      %{
        nb_rounds: 3,
        players: [
          %{ni: 1, name: "Aerts, Anna", rank: 2, sex: 2, title: 4, elo: 2100, mat_fide: 205_001},
          %{ni: 2, name: "Bos, Bert", rank: 1, elo: 2200, club_nr: 618, club: "KSK Test"},
          %{ni: 3, name: "Claes, Cis", rank: 3, elo: 1800, paye: 2, affilie: 0},
          %{ni: 4, name: "Dirks, Dirk", rank: 4, elo: 1600, handy_table: 7},
          %{ni: 5, name: "Eyck, Eva", rank: 5, elo: 1400, absent: 2, absent_rondes: "3"}
        ],
        games: [
          {1, 1, 2, 1, :draw},
          {1, 2, 3, 4, :white_ff},
          {2, 1, 1, 3, :white_wins},
          {2, 2, 4, 2, :black_wins},
          {3, 1, 2, 3, :double_ff},
          {3, 2, 1, 4, :zero_zero}
        ],
        byes: [{1, 5, :pab}, {2, 5, :half}, {3, 5, :absent}]
      },
      overrides
    )
  end

  defp round_trip!(dir, opts) do
    path1 = SwarFixture.write!(dir, SwarFixture.build(opts))
    assert {:ok, t1, _warnings} = SwarImport.import_file(path1, nil, as_individual: true)

    export1 = SwarExport.export(t1.id)
    path2 = SwarFixture.write!(dir, export1)
    assert {:ok, t2, _warnings} = SwarImport.import_file(path2, nil, as_individual: true)

    diff = SwarFixture.diff(SwarFixture.snapshot(t1.id), SwarFixture.snapshot(t2.id))
    assert diff == [], "re-import differs: #{inspect(diff, pretty: true)}"

    assert SwarExport.export(t2.id) == export1, "the second export differs from the first"

    {t1, t2}
  end

  test "a Swiss with every result, bye, absence and player field", %{tmp_dir: dir} do
    {t, _} =
      round_trip!(
        dir,
        swiss(%{tournament: %{arbiter1: "IA Luc Cornet", arbiter2: "FA Jan Jansen"}})
      )

    t = PairingsEngine.Repo.reload!(t)
    assert t.chief_arbiter == "Luc Cornet"
  end

  test "SWAR's own settings OpenPairings has no place for travel back", %{tmp_dir: dir} do
    {t, _} =
      round_trip!(
        dir,
        swiss(%{
          tournament: %{
            elo_used: 2,
            first_table: 11,
            plusieurs: 1,
            frbe_from: 1,
            frbe_to: 3,
            fide_from: 2,
            fide_to: 3,
            tb_personel: 3,
            elo_equal: 2,
            elo_ou_pays: 4,
            federation: 5,
            fide_remarks: "Checked",
            mac: "00-11-22-33-44-55",
            cadence: 3
          }
        })
      )

    settings = PairingsEngine.Repo.reload!(t).swar_settings
    assert settings["elo_used"] == 2
    assert settings["first_table"] == 11
    assert settings["federation"] == 5

    {:ok, parsed} = t.id |> SwarExport.export() |> SwarImport.parse()
    assert parsed.tournament.first_table == 11
    assert parsed.tournament.federation == 5
    assert parsed.tournament.fide_remarks == "Checked"
    assert parsed.mac == "00-11-22-33-44-55"
  end

  test "FIDE homologation and its per-round tournament ids", %{tmp_dir: dir} do
    {t, _} =
      round_trip!(
        dir,
        swiss(%{tournament: %{fide_homolog: 1, fide_ids: [{1, 2, 480_001}, {3, 3, 480_002}]}})
      )

    t = PairingsEngine.Repo.reload!(t)
    assert t.fide_homologated
    assert t.event_code == "480001, 480002"

    assert t.fide_id_ranges == [
             %{"fide_tournament_id" => "480001", "from_round" => 1, "to_round" => 2},
             %{"fide_tournament_id" => "480002", "from_round" => 3, "to_round" => 3}
           ]
  end

  test "every tie-break SWAR has, including the three with no counterpart", %{tmp_dir: dir} do
    {t, _} = round_trip!(dir, swiss(%{tiebreaks: [3, 13, 11, 9, 15]}))
    assert PairingsEngine.Repo.reload!(t).tiebreaks == ["AROC1", "KS"]

    {:ok, parsed} = t.id |> SwarExport.export() |> SwarImport.parse()
    assert parsed.tiebreaks == [3, 13, 11, 9, 15]
  end

  test "extra points, counted as SWAR counts them", %{tmp_dir: dir} do
    opts =
      swiss()
      |> Map.update!(:players, fn [a | rest] -> [Map.put(a, :extra_pts, 4) | rest] end)
      |> Map.put(:xtra_points, [{4, 2000}, {2, 1800}])

    {t, _} = round_trip!(dir, opts)
    t = PairingsEngine.Repo.reload!(t)
    assert t.count_extra_points
    assert t.swar_settings["xtra_points"] == [[4, 2000], [2, 1800], [0, 0], [0, 0]]
  end

  test "absence points with their caps", %{tmp_dir: dir} do
    round_trip!(
      dir,
      swiss(%{tournament: %{abs_value: 1, abs_nbfois: 1, abs_jusque: 2, bye_value: 1}})
    )
  end

  test "a round robin with an odd field and a free round", %{tmp_dir: dir} do
    {t, _} =
      round_trip!(dir, %{
        nb_rounds: 3,
        tournament: %{type: 4},
        tiebreaks: [8, 10, 6, 9, 14],
        players: [%{ni: 1, rank: 1}, %{ni: 2, rank: 2}, %{ni: 3, rank: 3}],
        games: [{1, 1, 2, 3, :draw}, {2, 1, 3, 1, :white_wins}, {3, 1, 1, 2, :unplayed}],
        byes: [{1, 1, :pab}, {2, 2, :pab}, {3, 3, :pab}]
      })

    assert PairingsEngine.Repo.reload!(t).pairing_system == "round_robin"
  end

  for {type, label} <- [{5, "double rounds (match format)"}, {6, "aller-retour (two cycles)"}] do
    test "a round robin, #{label}", %{tmp_dir: dir} do
      round_trip!(dir, %{
        nb_rounds: 2,
        tournament: %{type: unquote(type)},
        tiebreaks: [8, 6],
        players: [%{ni: 1}, %{ni: 2}],
        games: [{1, 1, 1, 2, :white_wins}, {2, 1, 2, 1, :draw}]
      })
    end
  end

  test "a round robin of two groups, categories separate", %{tmp_dir: dir} do
    {t, _} =
      round_trip!(dir, %{
        nb_rounds: 1,
        tournament: %{type: 4, cat_separes: 1},
        categories: {5, ["A", "B"], []},
        tiebreaks: [8, 10],
        players: [
          %{ni: 1, rank: 1, cat_index: 100},
          %{ni: 2, rank: 2, cat_index: 100},
          %{ni: 3, rank: 1, cat_index: 200},
          %{ni: 4, rank: 2, cat_index: 200}
        ],
        games: [{1, 1, 1, 2, :draw}, {1, 2, 3, 4, :white_wins}]
      })

    t = PairingsEngine.Repo.reload!(t)
    assert t.categories_enabled and t.categories_ranked_separately and t.pair_by_category
  end

  test "a Swiss with categories paired and ranked separately", %{tmp_dir: dir} do
    round_trip!(
      dir,
      swiss(%{
        tournament: %{cat_separes: 1},
        categories: {2, ["-12", "-16"], []},
        players: [
          %{ni: 1, rank: 1, cat_index: 100},
          %{ni: 2, rank: 2, cat_index: 100},
          %{ni: 3, rank: 3, cat_index: 200},
          %{ni: 4, rank: 4, cat_index: 200}
        ],
        games: [{1, 1, 1, 2, :white_wins}, {1, 2, 3, 4, :black_wins}],
        byes: []
      })
    )
  end

  test "two-axis categories", %{tmp_dir: dir} do
    round_trip!(
      dir,
      swiss(%{
        categories: {3, ["-12", "-16"], ["-1400", "-1800"]},
        players: [
          %{ni: 1, cat_index: 101},
          %{ni: 2, cat_index: 102},
          %{ni: 3, cat_index: 201},
          %{ni: 4, cat_index: 202}
        ],
        games: [{1, 1, 1, 2, :white_wins}, {1, 2, 3, 4, :draw}],
        byes: []
      })
    )
  end

  test "a Swiss of double rounds (match format)", %{tmp_dir: dir} do
    {t, _} =
      round_trip!(dir, %{
        nb_rounds: 2,
        tournament: %{type: 1},
        players: [%{ni: 1}, %{ni: 2}],
        games: [{1, 1, 1, 2, :white_wins}, {2, 1, 2, 1, :draw}]
      })

    assert PairingsEngine.Repo.reload!(t).swiss_match_format
  end

  test "an accelerated Swiss keeps SWAR's type", %{tmp_dir: dir} do
    {t, _} = round_trip!(dir, swiss(%{tournament: %{type: 2}}))
    {:ok, parsed} = t.id |> SwarExport.export() |> SwarImport.parse()
    assert parsed.tournament.type == 2
  end

  test "the initial colour", %{tmp_dir: dir} do
    for {appar, colour} <- [{0, "white"}, {1, "black"}, {2, "lot"}] do
      {t, _} = round_trip!(dir, swiss(%{tournament: %{appar_order: appar}}))
      assert PairingsEngine.Repo.reload!(t).initial_colour == colour
    end
  end

  describe "exclusions" do
    test "groups of players", %{tmp_dir: dir} do
      {t, _} = round_trip!(dir, swiss(%{exclusion: {0, "1,2,3:4,5"}}))
      assert length(PairingsEngine.Tournaments.list_forbidden_pairings(t.id)) == 4

      # The pairs go back as the groups they came from. Numbers are the
      # export's (the seed order: Bos, ranked 1, is player 1 now).
      {:ok, parsed} = t.id |> SwarExport.export() |> SwarImport.parse()
      assert parsed.exclusion == %{type: 0, values: "1,2,3:4,5"}
    end

    test "listed clubs", %{tmp_dir: dir} do
      opts =
        swiss(%{exclusion: {1, "618"}})
        |> Map.update!(:players, fn players ->
          Enum.map(players, fn p ->
            if p.ni in [2, 3], do: Map.merge(p, %{club_nr: 618, club: "KSK Test"}), else: p
          end)
        end)

      {t, _} = round_trip!(dir, opts)
      t = PairingsEngine.Repo.reload!(t)
      assert t.club_exclusion == "listed"
      assert t.club_exclusion_list == "KSK Test"
    end

    test "listed nationalities", %{tmp_dir: dir} do
      {t, _} = round_trip!(dir, swiss(%{exclusion: {2, "BEL:FRA"}}))
      assert PairingsEngine.Repo.reload!(t).fed_exclusion_list == "BEL, FRA"
    end

    test "every club", %{tmp_dir: dir} do
      opts =
        swiss(%{exclusion: {3, ""}})
        |> Map.update!(:players, fn players ->
          Enum.map(players, &Map.merge(&1, %{club_nr: 600 + &1.ni, club: "Club #{&1.ni}"}))
        end)

      {t, _} = round_trip!(dir, opts)
      assert PairingsEngine.Repo.reload!(t).club_exclusion == "all"
    end

    test "every nationality", %{tmp_dir: dir} do
      {t, _} = round_trip!(dir, swiss(%{exclusion: {4, ""}}))
      assert PairingsEngine.Repo.reload!(t).fed_exclusion == "all"
    end
  end

  test "a round SWAR saved before pairing it", %{tmp_dir: dir} do
    opts =
      swiss(%{nb_rounds: 4})
      |> Map.update!(:byes, fn byes ->
        byes ++ for(ni <- 1..5, do: {4, ni, :unpaired})
      end)

    {t, _} = round_trip!(dir, opts)
    assert length(PairingsEngine.Tournaments.list_rounds(t.id)) == 3
  end

  test "SWAR's player-list template, with an empty round 0", %{tmp_dir: dir} do
    {t, _} =
      round_trip!(dir, %{
        nb_rounds: 5,
        players: [%{ni: 1}, %{ni: 2}, %{ni: 3}],
        byes: [{0, 1, :unpaired}, {0, 2, :unpaired}, {0, 3, :unpaired}]
      })

    assert PairingsEngine.Tournaments.list_rounds(t.id) == []
  end

  test "a file with data after the player list", %{tmp_dir: dir} do
    round_trip!(dir, swiss(%{trailing: <<9, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9>>}))
  end

  test "an OpenPairings tournament, exported twice, gives the same file", %{tmp_dir: dir} do
    # The other direction: a tournament made here, not in SWAR.
    {t, _} = round_trip!(dir, swiss())
    t = PairingsEngine.Repo.reload!(t)

    {:ok, t} =
      t
      |> Ecto.Changeset.change(swar_settings: %{}, tiebreaks: ["BH", "WON", "SB"])
      |> PairingsEngine.Repo.update()

    export1 = SwarExport.export(t.id)
    {:ok, t2, _} = SwarImport.import_file(SwarFixture.write!(dir, export1), nil)
    assert SwarExport.export(t2.id) == export1

    {:ok, parsed} = SwarImport.parse(export1)
    # WON has no SWAR code; SB moves up.
    assert parsed.tiebreaks == [1, 6, 0, 0, 0]
  end
end
