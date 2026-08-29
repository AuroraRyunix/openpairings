defmodule PairingsEngine.SwarImportPresenceTest do
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

  alias PairingsEngine.{SwarImport, Standings}

  ## ---------- synthetic .swar binary builder ----------
  #
  # Mirrors PairingsEngine.SwarImport.parse/1's field-by-field layout (header,
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
      SwarImport.import_file(path, nil, allow_swiss321: true)
    after
      File.rm(path)
    end
  end

  # SWAR result codes (manual §5.2): LOST_BYE (0x0010) - unpaired-but-present
  # round, imported as a `byes` row with `type: "requested-zero"`.
  @lost_bye 0x0010
  # WIN_BYE (0x0040) - pairing-allocated bye, imported as a `Pairing` row
  # with `result: "bye"`.
  @win_bye 0x0040

  test "import_file/1 maps SW321_Pre onto tournament.presence_value, and a LOST_BYE round scores presence_value (not points_loss)" do
    opts = %{
      version: "v6.60",
      type: 3,
      # win=2.0, draw=1.0, loss=0.0, bye=2.0, presence=1.0 (raw ÷4)
      sw321: {8, 4, 0, 8, 4},
      prebye: 0,
      players: [
        %{ni: 1, name: "Player, One", rounds: [%{round_nr: 1, result: @lost_bye, advers: 0}]}
      ]
    }

    assert {:ok, tournament, _warnings} = import_synthetic!(opts)

    assert tournament.points_win == 2.0
    assert tournament.points_draw == 1.0
    assert tournament.points_loss == 0.0
    assert tournament.presence_value == 1.0

    [player] = PairingsEngine.Tournaments.list_players(tournament.id)
    entries = Standings.standings(tournament)
    entry = Enum.find(entries, &(&1.player.id == player.id))

    # Scored at presence_value (1.0), not at points_loss (0.0) - the bug
    # this fixes: before presence_value existed, a "requested-zero" bye
    # always fell through to points_loss regardless of SW321_Pre.
    assert entry.points == 1.0
  end

  test "import_file/1 maps nonzero SW321_PreBye onto presence_on_allocated_bye, and a WIN_BYE round scores bye_value + presence_value" do
    opts = %{
      version: "v6.60",
      type: 3,
      sw321: {8, 4, 0, 8, 4},
      # SW321_PreBye nonzero ("Add presence points for bye games", manual §5.16)
      prebye: 4,
      players: [
        %{ni: 1, name: "Player, One", rounds: [%{round_nr: 1, result: @win_bye, advers: 0}]}
      ]
    }

    assert {:ok, tournament, _warnings} = import_synthetic!(opts)

    # bye_value stays at plain SW321_Bye (8/4 = 2.0) - the PreBye add-on is
    # the flag, applied by Standings.bye_points/2, not a fold into bye_value.
    assert tournament.bye_value == 2.0
    assert tournament.presence_on_allocated_bye == true

    [player] = PairingsEngine.Tournaments.list_players(tournament.id)
    entries = Standings.standings(tournament)
    entry = Enum.find(entries, &(&1.player.id == player.id))
    # 8/4 (SW321_Bye) + 4/4 (SW321_Pre) = 3.0 - SWAR pays presence points ON
    # TOP of the bye points for a pairing-allocated bye when PreBye is set.
    assert entry.points == 3.0
  end

  test "import_file/1 reads SW321_PreBye as a flag, not as a particular number" do
    # This test exists because of what `abs_value` cost, one field over in the
    # same importer. That clause checked `== 5` on the strength of a stale
    # `// 0 ou 5` comment; every synthetic fixture hardcoded 5, so it passed,
    # and every REAL file with the box actually checked - raw byte 1 - was
    # mapped to the opposite of what the club had configured.
    #
    # `prebye_set?/1` is correctly written as `!= 0`, and the real fixture
    # carries 1 while the tests above carry 4. Nothing pinned that: tightening
    # it to `== 1` or `== 4` would leave this whole file green and break the
    # other encoding silently.
    #
    # So: several nonzero values, none of them privileged.
    for raw <- [1, 2, 4, 5, 8, 255] do
      opts = %{
        version: "v6.60",
        type: 3,
        sw321: {8, 4, 0, 8, 4},
        prebye: raw,
        players: [
          %{ni: 1, name: "Player, One", rounds: [%{round_nr: 1, result: @win_bye, advers: 0}]}
        ]
      }

      assert {:ok, tournament, _warnings} = import_synthetic!(opts)

      assert tournament.presence_on_allocated_bye == true,
             "SW321_PreBye = #{raw} did not set the flag"
    end
  end

  test "import_file/1 leaves presence_on_allocated_bye false when SW321_PreBye is zero, scoring a WIN_BYE at bye_value alone" do
    opts = %{
      version: "v6.60",
      type: 3,
      sw321: {8, 4, 0, 8, 4},
      prebye: 0,
      players: [
        %{ni: 1, name: "Player, One", rounds: [%{round_nr: 1, result: @win_bye, advers: 0}]}
      ]
    }

    assert {:ok, tournament, _warnings} = import_synthetic!(opts)

    assert tournament.bye_value == 2.0
    assert tournament.presence_on_allocated_bye == false

    [player] = PairingsEngine.Tournaments.list_players(tournament.id)
    entries = Standings.standings(tournament)
    entry = Enum.find(entries, &(&1.player.id == player.id))
    # SW321_Bye (2.0) only - no presence add-on.
    assert entry.points == 2.0
  end

  test "import_file/1 leaves presence_on_allocated_bye false when SW321_PreBye is absent (pre-v6.03 file)" do
    opts = %{
      # < v6.03 - SW321_PreBye isn't even present in the file format at this
      # version, so it parses to `nil` regardless of what a caller might
      # otherwise want to set.
      version: "v5.90",
      type: 3,
      sw321: {8, 4, 0, 8, 4},
      players: [
        %{ni: 1, name: "Player, One", rounds: [%{round_nr: 1, result: @win_bye, advers: 0}]}
      ]
    }

    assert {:ok, tournament, _warnings} = import_synthetic!(opts)

    # 8/4 (SW321_Bye) only, and no flag - SW321_PreBye doesn't exist yet at
    # this file version.
    assert tournament.bye_value == 2.0
    assert tournament.presence_value == 1.0
    assert tournament.presence_on_allocated_bye == false
  end

  test "import_file/1 never sets presence_on_allocated_bye for a non-3-2-1 tournament, even with SW321_PreBye bytes present" do
    opts = %{
      version: "v6.60",
      # type != 3 - the whole 3-2-1 mapping (including the PreBye flag) must
      # not fire at all, same regression guard as the presence_value test
      # below.
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

    [player] = PairingsEngine.Tournaments.list_players(tournament.id)
    entries = Standings.standings(tournament)
    entry = Enum.find(entries, &(&1.player.id == player.id))
    # Scores at the schema-default bye_value (1.0) with no presence add-on.
    assert entry.points == 1.0
  end

  test "import_file/1 leaves presence_value nil and requested-zero byes at plain points_loss for a non-3-2-1 tournament" do
    opts = %{
      version: "v6.60",
      # type != 3 - 3-2-1 mapping must not fire at all, same regression this
      # guards for the ordinary points_win/points_draw/points_loss fields.
      type: 0,
      sw321: {8, 4, 0, 8, 4},
      players: [
        %{ni: 1, name: "Player, One", rounds: [%{round_nr: 1, result: @lost_bye, advers: 0}]}
      ]
    }

    assert {:ok, tournament, _warnings} = import_synthetic!(opts)

    assert tournament.presence_value == nil
    assert tournament.points_loss == 0.0

    [player] = PairingsEngine.Tournaments.list_players(tournament.id)
    entries = Standings.standings(tournament)
    entry = Enum.find(entries, &(&1.player.id == player.id))

    # Unchanged behaviour: falls straight through to points_loss (0.0) since
    # presence_value is nil.
    assert entry.points == 0.0
  end

  describe "3-2-1 import is switched off" do
    # Every test in this file passes `allow_swiss321: true`, which is the
    # test-only door. The DEFAULT - what the app actually does - is to
    # refuse, because the scoring is not fully settled: SWAR pays a presence
    # point per round attended (verified against its own source, and modelled
    # in Standings), but what a BYE is worth under the scheme is unresolved,
    # and the only real fixture has SW321_Bye, SW321_Pre and
    # points_loss + presence all equal to 1.0, so it cannot tell the
    # candidate models apart.
    #
    # Importing anyway would produce a standings table that looks right and
    # is wrong, which is the worst available outcome.
    defp import_without_optin(opts) do
      binary = build_swar_binary(opts)
      path = Path.join(System.tmp_dir!(), "refuse-#{System.unique_integer([:positive])}.swar")
      File.write!(path, binary)

      try do
        SwarImport.import_file(path)
      after
        File.rm(path)
      end
    end

    test "a 3-2-1 file is refused by default, with an explanation" do
      assert {:error, message} = import_without_optin(%{type: 3, sw321: {8, 4, 0, 8, 4}})

      assert message =~ "3-2-1"
      assert message =~ "cannot import yet"
      assert message =~ "planned"
    end

    test "every other tournament type still imports" do
      assert {:ok, _tournament, _warnings} = import_without_optin(%{type: 0})
    end
  end
end
