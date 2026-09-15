defmodule PairingsEngine.Federations.BEL.SwarTwoAxisCategoriesTest do
  @moduledoc """
  End-to-end coverage for a two-axis SWAR category import/export round trip
  (`Categorie` type 3/4 - age-then-rating, rating-then-age).

  Builds the `.swar` bytes with `SwarExport` rather than a committed
  fixture - SWAR's own file format is proprietary and no `.swar` file may
  be committed to this repo (see `docs/swar-import.md`). `SwarExport`
  already writes exactly the `[CATEGORIES]` layout `SwarImport` reads, so
  round-tripping through both is equivalent to reading a real two-axis club
  file, without needing one.

  See `PairingsEngine.Federations.BEL.SwarCategoryWarningTest` for the pure
  `category_axes/2`/`category_warnings/1` unit coverage (including the
  edge-bound cases), and `docs/swar-import.md`'s "Categories: two axes, two
  tag sets" section for the model this pins down.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Federations.BEL.{SwarExport, SwarImport}
  alias PairingsEngine.Tournaments.{Tournament, Player}

  # Age-then-rating: axis 1 is age bounds, axis 2 is rating bounds.
  defp build_two_axis_tournament do
    Repo.insert!(%Tournament{
      name: "Two Axis Open",
      type: "swiss",
      pairing_system: "swiss",
      rounds_count: 3,
      federation: "BEL",
      categories: ["-14", "-18", "-1600", "-2000"],
      swar_category_type: 3,
      swar_category_axis2: ["-1600", "-2000"],
      categories_enabled: true,
      pair_by_category: true,
      swar_guid: "two-axis-test-guid"
    })
  end

  defp build_player(tournament, attrs) do
    Repo.insert!(
      struct(
        %Player{tournament_id: tournament.id, name: "P", pairing_number: 1},
        attrs
      )
    )
  end

  defp export_to_tmp_file(tournament_id) do
    path = Path.join(System.tmp_dir!(), "swar-two-axis-#{System.unique_integer([:positive])}.bin")
    File.write!(path, SwarExport.export(tournament_id))
    on_exit(fn -> File.rm(path) end)
    path
  end

  setup do
    tournament = build_two_axis_tournament()

    young_low =
      build_player(tournament, %{
        name: "Young Low",
        pairing_number: 1,
        category: "-14",
        categories: ["-14", "-1600"]
      })

    old_high =
      build_player(tournament, %{
        name: "Old High",
        pairing_number: 2,
        category: "-18",
        categories: ["-18", "-2000"]
      })

    # On a bound exactly, and missing one axis entirely (birth year/rating
    # unresolvable to a category is out of this module's scope - a player
    # simply carries no tag for the axis they didn't qualify for).
    edge_player =
      build_player(tournament, %{
        name: "Edge Only Age",
        pairing_number: 3,
        category: "-18",
        categories: ["-18"]
      })

    %{tournament: tournament, players: [young_low, old_high, edge_player]}
  end

  test "both axes import as separate tags, and the pairing category is axis 1", %{
    tournament: t
  } do
    path = export_to_tmp_file(t.id)

    assert {:ok, imported, warnings} = SwarImport.import_file(path)
    assert warnings == []

    assert Enum.sort(imported.categories) == Enum.sort(["-14", "-18", "-1600", "-2000"])
    assert imported.swar_category_type == 3
    assert Enum.sort(imported.swar_category_axis2) == Enum.sort(["-1600", "-2000"])

    players = Tournaments.list_players(imported.id) |> Map.new(&{&1.name, &1})

    young_low = players["Young Low"]
    assert Enum.sort(young_low.categories) == Enum.sort(["-14", "-1600"])
    assert young_low.category == "-14"

    old_high = players["Old High"]
    assert Enum.sort(old_high.categories) == Enum.sort(["-18", "-2000"])
    assert old_high.category == "-18"

    edge = players["Edge Only Age"]
    assert edge.categories == ["-18"]
    assert edge.category == "-18"
  end

  test "import -> export -> import gives identical categories and assignments", %{tournament: t} do
    path1 = export_to_tmp_file(t.id)
    {:ok, imported1, []} = SwarImport.import_file(path1)

    path2 = export_to_tmp_file(imported1.id)
    {:ok, imported2, []} = SwarImport.import_file(path2)

    assert Enum.sort(imported1.categories) == Enum.sort(imported2.categories)
    assert imported1.swar_category_type == imported2.swar_category_type
    assert Enum.sort(imported1.swar_category_axis2) == Enum.sort(imported2.swar_category_axis2)

    players1 = Tournaments.list_players(imported1.id) |> Enum.sort_by(& &1.pairing_number)
    players2 = Tournaments.list_players(imported2.id) |> Enum.sort_by(& &1.pairing_number)

    assert Enum.map(players1, & &1.name) == Enum.map(players2, & &1.name)

    assert Enum.map(players1, &Enum.sort(&1.categories)) ==
             Enum.map(players2, &Enum.sort(&1.categories))

    assert Enum.map(players1, & &1.category) == Enum.map(players2, & &1.category)
  end

  test "a plain (non-two-axis) category import round-trips exactly as before" do
    t =
      Repo.insert!(%Tournament{
        name: "Single Axis",
        type: "swiss",
        pairing_system: "swiss",
        rounds_count: 2,
        categories: ["U18", "U16"],
        swar_guid: "single-axis-test-guid"
      })

    build_player(t, %{name: "Kid", pairing_number: 1, category: "U16", categories: ["U16"]})

    path = export_to_tmp_file(t.id)
    assert {:ok, imported, []} = SwarImport.import_file(path)

    assert Enum.sort(imported.categories) == Enum.sort(["U18", "U16"])
    assert imported.swar_category_type == nil
    assert imported.swar_category_axis2 == []

    [player] = Tournaments.list_players(imported.id)
    assert player.categories == ["U16"]
    assert player.category == "U16"
  end
end
