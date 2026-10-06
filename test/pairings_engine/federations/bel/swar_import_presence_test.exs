defmodule PairingsEngine.Federations.BEL.SwarImportPresenceTest do
  # Deliberately a SEPARATE module from swar_import_test.exs, which carries
  # `@moduletag :swar_fixture` (excluded when the gitignored real .swar
  # fixtures aren't present - a fresh checkout, CI). ExUnit's bare-atom
  # `exclude: [:swar_fixture]` filter (see test/test_helper.exs) matches on
  # tag *presence*, not value - `@tag swar_fixture: false` on an individual
  # test does not un-exclude it (ExUnit.Filters.has_tag/2 for a bare atom key
  # only checks `Map.has_key?/2`). So a synthetic-binary test that must run
  # even without the real fixtures cannot live in that module; it lives here
  # instead, building its own minimal-but-format-valid `.swar` binary from
  # scratch (see `build_swar_binary/1` below) rather than depending on
  # test/fixtures/test3-321.swar.
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.Standings
  alias PairingsEngine.Federations.BEL.SwarImport

  ## ---------- synthetic .swar binary builder ----------
  #
  # Mirrors PairingsEngine.Federations.BEL.SwarImport.parse/1's field-by-field layout (header,
  # [TOURNOI], [DATES], [TIE_BREAK], [EXCLUSION], [CATEGORIES],
  # [XTRA_POINTS], [JOUEURS] with per-player [RONDE] rounds) closely enough
  # to produce a binary `parse/1` accepts - every field not under test is
  # written as a zero/blank placeholder. Only the handful of fields relevant
  # to 3-2-1 presence-points scoring are ever varied by callers.

  defp w_str(s), do: <<byte_size(s)::little-signed-32, s::binary>>
  defp w_i32(n), do: <<n::little-signed-32>>
  defp w_i16(n), do: <<n::little-signed-16>>
  defp w_u8(n), do: <<n::8>>

  defp version_gte?(version, target), do: version >= target

  defp build_swar_binary(opts) do
    version = Map.get(opts, :version, "v6.60")
    type = Map.get(opts, :type, 3)
    {win, nul, los, bye, pre} = Map.get(opts, :sw321, {8, 4, 0, 8, 4})
    prebye = Map.get(opts, :prebye, 0)
    players = Map.get(opts, :players, [])
    nb_rounds = Map.get(opts, :nb_rounds, 1)

    header = w_str(version) <> w_str("guid") <> w_str("mac")

    # legacy ByeValue field - deliberately not the one under test here
    tournoi =
      w_str("[TOURNOI]") <>
        w_str("Test Tournament") <>
        w_str("") <>
        w_str("") <>
        w_str("") <>
        w_str("") <>
        w_str("") <>
        w_str("") <>
        w_str("") <>
        w_i32(0) <>
        w_str("") <>
        w_i32(nb_rounds) <>
        w_i32(0) <>
        w_i32(0) <>
        w_i32(0) <>
        w_i32(0) <>
        w_i32(0) <>
        w_i32(0) <>
        w_i32(0) <>
        fide_ids_block(version) <>
        w_str("") <>
        w_str("") <>
        w_str("") <>
        w_str("") <>
        w_i32(type) <>
        pre_v603_dummy(version) <>
        w_i32(0) <>
        w_i32(0) <>
        w_i32(0) <>
        w_i32(0) <>
        w_i32(win) <>
        w_i32(nul) <>
        w_i32(los) <>
        w_i32(bye) <>
        w_i32(pre) <>
        prebye_block(version, prebye) <>
        w_i32(0) <>
        w_i32(0) <>
        w_i32(0) <>
        w_i32(0) <>
        w_i32(0) <>
        w_i32(0) <>
        w_u8(0) <>
        w_u8(0) <>
        w_u8(0) <>
        w_u8(0) <>
        w_i32(0) <>
        w_i32(0)

    dates = w_str("[DATES]") <> Enum.map_join(1..nb_rounds, "", fn _ -> w_str("") end)
    tie_break = w_str("TIE_BREAK") <> Enum.map_join(1..5, "", fn _ -> w_i32(0) end)
    exclusion = w_str("EXCLUSION") <> w_i32(0) <> w_str("")

    max_categ = if version_gte?(version, "v6.50"), do: 16, else: 12
    cat_strs = Enum.map_join(1..(max_categ + 1), "", fn _ -> w_str("") end)
    categories = w_str("CATEGORIES") <> w_i32(0) <> cat_strs <> cat_strs

    xtra_points =
      w_str("XTRA_POINTS") <> Enum.map_join(1..4, "", fn _ -> w_i32(0) <> w_i32(0) end)

    joueurs =
      w_str("[JOUEURS]") <>
        w_i32(length(players)) <>
        Enum.map_join(players, "", &build_player(&1, version))

    header <> tournoi <> dates <> tie_break <> exclusion <> categories <> xtra_points <> joueurs
  end

  defp fide_ids_block(version) do
    if version_gte?(version, "v5.24") do
      Enum.map_join(1..16, "", fn _ -> w_i32(0) <> w_i32(0) <> w_i32(0) end)
    else
      w_str("")
    end
  end

  defp pre_v603_dummy(version) do
    if version_gte?(version, "v6.03"), do: <<>>, else: w_i32(0)
  end

  defp prebye_block(version, prebye) do
    if version_gte?(version, "v6.03"), do: w_i32(prebye), else: <<>>
  end

  defp points_adjusted_block(version) do
    if version_gte?(version, "v6.49"), do: w_i32(0), else: <<>>
  end

  defp paye_block(version) do
    if version_gte?(version, "v5.52"), do: w_i32(1), else: <<>>
  end

  defp build_player(p, version) do
    rounds = Map.get(p, :rounds, [])
    nb_round = length(rounds)

    w_i32(0) <>
      w_str(Map.get(p, :name, "Test Player")) <>
      w_i32(Map.fetch!(p, :ni)) <>
      w_i32(1) <>
      w_i32(0) <>
      w_str("") <>
      w_i32(0) <>
      w_str("") <>
      w_i32(0) <>
      w_i32(0) <>
      w_i32(1) <>
      w_i32(0) <>
      w_i32(0) <>
      w_i32(0) <>
      w_i32(0) <>
      w_str("") <>
      w_i32(0) <>
      w_i32(0) <>
      points_adjusted_block(version) <>
      w_i32(0) <>
      Enum.map_join(1..5, "", fn _ -> w_i32(0) end) <>
      w_i32(0) <>
      paye_block(version) <>
      w_i32(0) <>
      w_str("") <>
      w_i32(0) <>
      w_i32(0) <>
      w_i16(nb_round) <>
      w_i16(0) <>
      w_str("[RONDE]") <>
      Enum.map_join(rounds, "", &build_round/1)
  end

  defp build_round(r) do
    w_i32(Map.get(r, :round_nr, 1)) <>
      w_i32(Map.get(r, :table, 0)) <>
      w_i32(Map.get(r, :advers, 0)) <>
      w_i32(Map.get(r, :result, 0)) <>
      w_i32(Map.get(r, :color, 0)) <>
      w_i32(Map.get(r, :float, 0)) <>
      w_i32(Map.get(r, :xtra_pts, 0))
  end

  defp import_synthetic!(opts) do
    binary = build_swar_binary(opts)
    path = Path.join(System.tmp_dir!(), "synthetic-#{System.unique_integer([:positive])}.swar")
    File.write!(path, binary)

    try do
      SwarImport.import_file(path)
    after
      File.rm(path)
    end
  end

  # SWAR result codes (Swar.h:227-247) and table sentinels (Swar.h:138-140).
  @win 0x4000
  @draw 0x2000
  @lost 0x1000
  @zero_zero 0x0400
  @draw_zero 0x0200
  @zero_draw 0x0100
  @win_bye 0x0040
  @draw_bye 0x0020
  @lost_bye 0x0010
  @zero_zeroff 0x0008
  @win_ff 0x0004
  @draw_ff 0x0002
  @lost_ff 0x0001
  @table_bye 0x1000
  @table_absent 0x4000

  defp points_by_name(tournament, opts \\ []) do
    tournament
    |> Standings.standings(opts)
    |> Map.new(&{&1.player.name, &1.points})
  end

  # One side of a game: `table`, opponent, own result, colour.
  defp game(round_nr, table, opponent, result, colour),
    do: %{round_nr: round_nr, table: table, advers: opponent, result: result, color: colour}

  defp pairing_bye(round_nr),
    do: %{round_nr: round_nr, table: @table_bye, advers: -1, result: @lost_bye}

  ## ---------- every result kind, against SWAR's own rules ----------
  #
  # Values chosen so that no two are equal: Win 3, Nul 2, Los 1, Bye 2.5,
  # Pre 0.5 (raw x4: 12, 8, 4, 10, 2 - TOptions.cpp:698-702). A total can
  # only come out right if every round is paid by the right rule.
  #
  # The rules, from SWAR 6.65's source:
  #   result points - `ConvertPoint321` (Utils.cpp:1206-1222): WIN, WIN_FF
  #     -> Win; DRAW, DRAW_FF, DRAW_ZERO -> Nul; LOST, LOST_FF, ZERO_DRAW ->
  #     Los; LOST_BYE -> Bye; anything else (ZERO_ZERO, ZERO_ZEROFF, an
  #     absence's NO_RESULT, WIN_BYE, DRAW_BYE) -> 0.
  #   presence - `GetPresentPtsUntilRound` (Classement.cpp:137-157): + Pre
  #     for NORMAUX | WIN | SPECIAUX; + Pre for any bye when PreBye is set.
  #     So no presence for LOST_FF, ZERO_ZEROFF or an absence.
  #   total - Points + SpecialPts (Classement.cpp:1389-1390, 1425).
  @sw321 {12, 8, 4, 10, 2}

  defp every_kind_players do
    [
      # R1 WIN (3 + .5)              R2 ZERO_ZERO 0-0 (0 + .5)
      %{ni: 1, name: "P1", rounds: [game(1, 1, 2, @win, 1), game(2, 1, 3, @zero_zero, 1)]},
      # R1 LOST (1 + .5)             R2 ZERO_ZEROFF 0-0FF (0, no presence)
      %{ni: 2, name: "P2", rounds: [game(1, 1, 1, @lost, -1), game(2, 2, 4, @zero_zeroff, 1)]},
      # R1 DRAW (2 + .5)             R2 ZERO_ZERO (0 + .5)
      %{ni: 3, name: "P3", rounds: [game(1, 2, 4, @draw, 1), game(2, 1, 1, @zero_zero, -1)]},
      # R1 DRAW (2 + .5)             R2 ZERO_ZEROFF (0)
      %{ni: 4, name: "P4", rounds: [game(1, 2, 3, @draw, -1), game(2, 2, 2, @zero_zeroff, -1)]},
      # R1 DRAW_ZERO, the ½ of ½-0 (2 + .5)   R2 WIN_FF as Black (3 + .5)
      %{
        ni: 5,
        name: "P5",
        rounds: [game(1, 3, 6, @draw_zero, 1), game(2, 3, 6, @win_ff, -1)]
      },
      # R1 ZERO_DRAW, the 0 of ½-0 (1 + .5)   R2 LOST_FF as White (1, no presence)
      %{
        ni: 6,
        name: "P6",
        rounds: [game(1, 3, 5, @zero_draw, -1), game(2, 3, 5, @lost_ff, 1)]
      },
      # R1 WIN_FF (3 + .5)           R2 pairing bye LOST_BYE (2.5 [+ .5])
      %{ni: 7, name: "P7", rounds: [game(1, 4, 8, @win_ff, 1), pairing_bye(2)]},
      # R1 LOST_FF (1)               R2 LOST_BYE off the bye table (2.5 [+ .5])
      %{
        ni: 8,
        name: "P8",
        rounds: [
          game(1, 4, 7, @lost_ff, -1),
          %{round_nr: 2, table: 0, advers: 0, result: @lost_bye}
        ]
      },
      # R1 pairing bye (2.5 [+ .5])  R2 WIN (3 + .5)
      %{ni: 9, name: "P9", rounds: [pairing_bye(1), game(2, 4, 10, @win, 1)]},
      # R1 absent: TABLE_ABSENT, NO_RESULT (0)   R2 LOST (1 + .5)
      %{
        ni: 10,
        name: "P10",
        rounds: [
          %{round_nr: 1, table: @table_absent, advers: -1, result: 0},
          game(2, 4, 9, @lost, -1)
        ]
      }
    ]
  end

  test "every result kind scores as SWAR scores it, PreBye off" do
    {:ok, tournament, warnings} =
      import_synthetic!(%{sw321: @sw321, prebye: 0, nb_rounds: 2, players: every_kind_players()})

    assert tournament.points_win == 3.0
    assert tournament.points_draw == 2.0
    assert tournament.points_loss == 1.0
    assert tournament.bye_value == 2.5
    assert tournament.presence_value == 0.5
    refute tournament.presence_on_allocated_bye

    assert points_by_name(tournament) == %{
             "P1" => 3.0 + 0.5 + (0.0 + 0.5),
             "P2" => 1.0 + 0.5 + 0.0,
             "P3" => 2.0 + 0.5 + (0.0 + 0.5),
             "P4" => 2.0 + 0.5 + 0.0,
             "P5" => 2.0 + 0.5 + (3.0 + 0.5),
             "P6" => 1.0 + 0.5 + 1.0,
             "P7" => 3.0 + 0.5 + 2.5,
             "P8" => 1.0 + 2.5,
             "P9" => 2.5 + (3.0 + 0.5),
             "P10" => 0.0 + (1.0 + 0.5)
           }

    # Nothing here lacks an equivalent, so no 3-2-1 warning.
    refute Enum.any?(warnings, &(is_binary(&1) and &1 =~ "3-2-1"))
  end

  test "every result kind scores as SWAR scores it, PreBye on: every bye gets the presence point" do
    {:ok, tournament, _warnings} =
      import_synthetic!(%{sw321: @sw321, prebye: 1, nb_rounds: 2, players: every_kind_players()})

    assert tournament.presence_on_allocated_bye

    points = points_by_name(tournament)
    assert points["P7"] == 3.0 + 0.5 + (2.5 + 0.5)
    assert points["P8"] == 1.0 + (2.5 + 0.5)
    assert points["P9"] == 2.5 + 0.5 + (3.0 + 0.5)
    # Nobody else had a bye, so nothing else moves.
    assert points["P1"] == 4.0
    assert points["P10"] == 1.5
  end

  test "result points alone are SWAR's stored Points: no presence, the bye's PreBye point included" do
    {:ok, tournament, _warnings} =
      import_synthetic!(%{sw321: @sw321, prebye: 1, nb_rounds: 2, players: every_kind_players()})

    # `Points` (Classement.cpp:1385) holds only `ConvertPoint321`; the
    # presence sum is `SpecialPts`, PreBye included.
    assert points_by_name(tournament, presence: false) == %{
             "P1" => 3.0,
             "P2" => 1.0,
             "P3" => 2.0,
             "P4" => 2.0,
             "P5" => 5.0,
             "P6" => 2.0,
             "P7" => 5.5,
             "P8" => 3.5,
             "P9" => 5.5,
             "P10" => 1.0
           }
  end

  test "a pairing bye (LOST_BYE on TABLE_BYE) imports as the pairing-allocated bye" do
    {:ok, tournament, _warnings} =
      import_synthetic!(%{sw321: @sw321, nb_rounds: 2, players: every_kind_players()})

    byes =
      for round <- PairingsEngine.Tournaments.list_rounds(tournament.id),
          p <- PairingsEngine.Repo.preload(round, pairings: :white_player).pairings,
          p.result == "bye",
          do: {round.number, p.white_player.name}

    assert Enum.sort(byes) == [{1, "P9"}, {2, "P7"}]
  end

  test "the engine's score column matches the standings for every result kind" do
    {:ok, tournament, _warnings} =
      import_synthetic!(%{sw321: @sw321, prebye: 1, nb_rounds: 2, players: every_kind_players()})

    standings = points_by_name(tournament)

    players = PairingsEngine.Tournaments.list_players(tournament.id)

    for row <- PairingsEngine.Pairing.trf_player_rows(tournament, players) do
      assert row.points == standings[row.name], row.name
    end
  end

  test "a round trip through SWAR export keeps the SW321 fields, the type and every total" do
    {:ok, tournament, _warnings} =
      import_synthetic!(%{sw321: @sw321, prebye: 1, nb_rounds: 2, players: every_kind_players()})

    binary = PairingsEngine.Federations.BEL.SwarExport.export(tournament.id)
    {:ok, parsed} = SwarImport.parse(binary)

    assert parsed.tournament.type == 3

    assert {parsed.tournament.sw321_win, parsed.tournament.sw321_nul, parsed.tournament.sw321_los,
            parsed.tournament.sw321_bye, parsed.tournament.sw321_pre} == @sw321

    assert parsed.tournament.sw321_prebye == 1

    path = Path.join(System.tmp_dir!(), "roundtrip-#{System.unique_integer([:positive])}.swar")
    File.write!(path, binary)

    try do
      {:ok, again, _warnings} = SwarImport.import_file(path)
      assert points_by_name(again) == points_by_name(tournament)
    after
      File.rm(path)
    end
  end

  test "the codes SWAR's 3-2-1 dialog never writes import with a warning naming their rounds" do
    players = [
      %{ni: 1, name: "P1", rounds: [%{round_nr: 1, table: 0, advers: 0, result: @win_bye}]},
      %{ni: 2, name: "P2", rounds: [%{round_nr: 1, table: 0, advers: 0, result: @draw_bye}]},
      %{ni: 3, name: "P3", rounds: [game(1, 1, 4, @lost, 1), game(2, 1, 4, @draw_ff, 1)]},
      %{ni: 4, name: "P4", rounds: [game(1, 1, 3, @win, -1), game(2, 1, 3, @draw_ff, -1)]}
    ]

    {:ok, _tournament, warnings} =
      import_synthetic!(%{sw321: @sw321, nb_rounds: 2, players: players})

    assert Enum.any?(warnings, &(is_binary(&1) and &1 =~ "3-2-1" and &1 =~ "(1, 2)"))
  end

  test "SW321_PreBye is read as a flag, not as a particular number" do
    # `abs_value`, one field over, once checked `== 5` on the strength of a
    # stale comment, and every real file with the box checked (raw 1) was
    # read backwards. The real 3-2-1 fixture carries 1; SWAR writes 0/1
    # (TOptions.cpp:703). Several nonzero values, none of them privileged.
    for raw <- [1, 2, 4, 5, 8, 255] do
      {:ok, tournament, _warnings} =
        import_synthetic!(%{
          sw321: {8, 4, 0, 8, 4},
          prebye: raw,
          players: [%{ni: 1, name: "Player, One", rounds: [pairing_bye(1)]}]
        })

      assert tournament.presence_on_allocated_bye == true,
             "SW321_PreBye = #{raw} did not set the flag"
    end
  end

  test "a pre-v6.03 file has no SW321_PreBye, so no bye presence point" do
    {:ok, tournament, _warnings} =
      import_synthetic!(%{
        version: "v5.90",
        sw321: {8, 4, 0, 8, 4},
        players: [%{ni: 1, name: "Player, One", rounds: [pairing_bye(1)]}]
      })

    assert tournament.bye_value == 2.0
    assert tournament.presence_value == 1.0
    assert tournament.presence_on_allocated_bye == false
    assert points_by_name(tournament)["Player, One"] == 2.0
  end

  test "a 3-2-1 file imports without being asked to" do
    assert {:ok, tournament, _warnings} =
             import_synthetic!(%{type: 3, sw321: {8, 4, 0, 8, 4}})

    assert tournament.presence_value == 1.0
  end

  ## ---------- not a 3-2-1 file: none of it applies ----------

  test "import_file/1 never sets presence_on_allocated_bye for a non-3-2-1 tournament, even with SW321_PreBye bytes present" do
    opts = %{
      version: "v6.60",
      type: 0,
      sw321: {8, 4, 0, 8, 4},
      prebye: 4,
      players: [
        %{ni: 1, name: "Player, One", rounds: [%{round_nr: 1, result: @win_bye, advers: 0}]}
      ]
    }

    assert {:ok, tournament, _warnings} = import_synthetic!(opts)

    assert tournament.presence_on_allocated_bye == false
    assert tournament.presence_value == nil
    # The schema-default bye_value (1.0), no presence add-on.
    assert points_by_name(tournament)["Player, One"] == 1.0
  end

  test "import_file/1 leaves presence_value nil and requested-zero byes at plain points_loss for a non-3-2-1 tournament" do
    opts = %{
      version: "v6.60",
      type: 0,
      sw321: {8, 4, 0, 8, 4},
      players: [
        %{ni: 1, name: "Player, One", rounds: [%{round_nr: 1, result: @lost_bye, advers: 0}]}
      ]
    }

    assert {:ok, tournament, _warnings} = import_synthetic!(opts)

    assert tournament.presence_value == nil
    assert tournament.points_loss == 0.0
    assert points_by_name(tournament)["Player, One"] == 0.0
  end
end
