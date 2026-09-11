defmodule PairingsEngine.Federations.BEL.SwarImportPass2Test do
  @moduledoc """
  Regression coverage for the code-shaped findings the SWAR source audit's
  second pass left open (`docs/swar-source-audit-pass2-2026-09-09.md`):
  the round-robin bye value SWAR forces at load (§3, F11), the legacy
  `CatIndex < 100` normalisation (§5.2), and the XtraPoints
  manual-acceleration warning (§5.4, F13). The pass's fourth item, §2/F10's
  tie-break mapping, turned out to already be closed by 0.54.0 -
  `swar_tiebreak_mapping_test.exs` pins that one.

  Deliberately a SEPARATE module from swar_import_test.exs (tagged
  `:swar_fixture`, excluded on a checkout without the gitignored real
  fixtures) - everything here builds its own minimal `.swar` binary, same
  convention as swar_import_validation_test.exs and
  swar_import_presence_test.exs, whose field layout this mirrors.

  The synthetic version is pinned below v6.49 on purpose: at v6.49 or above
  `points_adjusted_warnings/3` compares every player's file-stored
  `points_adjusted` (always 0 here, since it isn't what any test below is
  about) against their recomputed standings total, and several scenarios
  here deliberately score a player a non-zero point (a forced round-robin
  bye) - which would otherwise add an unrelated points-mismatch warning to
  every `warnings` assertion.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.Repo
  alias PairingsEngine.Federations.BEL.SwarImport
  alias PairingsEngine.Tournaments.Player

  ## ---------- synthetic .swar binary builder ----------
  #
  # Mirrors SwarImport.parse/1's field-by-field layout (header, [TOURNOI],
  # [DATES], [TIE_BREAK], [EXCLUSION], [CATEGORIES], [XTRA_POINTS],
  # [JOUEURS] with per-player [RONDE] rounds) closely enough to produce a
  # binary parse/1 accepts - every field not under test is a zero/blank
  # placeholder.

  defp w_str(s), do: <<byte_size(s)::little-signed-32, s::binary>>
  defp w_i32(n), do: <<n::little-signed-32>>
  defp w_i16(n), do: <<n::little-signed-16>>
  defp w_u8(n), do: <<n::8>>

  defp version_gte?(version, target), do: version >= target

  defp build_swar_binary(opts) do
    version = Map.get(opts, :version, "v6.40")
    type = Map.get(opts, :type, 0)
    bye_value = Map.get(opts, :bye_value, 0)
    cat_type = Map.get(opts, :cat_type, 0)
    cat_value1 = Map.get(opts, :cat_value1, [])
    xtra_points = Map.get(opts, :xtra_points, List.duplicate({0, 0}, 4))
    players = Map.get(opts, :players, [])
    nb_rounds = Map.get(opts, :nb_rounds, 1)

    header = w_str(version) <> w_str("guid") <> w_str("mac")

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
        w_i32(0) <>
        w_i32(0) <>
        w_i32(0) <>
        w_i32(0) <>
        w_i32(0) <>
        prebye_block(version, 0) <>
        w_i32(0) <>
        w_i32(0) <>
        w_i32(0) <>
        w_i32(0) <>
        w_i32(0) <>
        w_i32(bye_value) <>
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
    value1 = pad_categories(cat_value1, max_categ + 1)
    value2 = pad_categories([], max_categ + 1)

    categories =
      w_str("CATEGORIES") <>
        w_i32(cat_type) <>
        Enum.map_join(value1, "", &w_str/1) <>
        Enum.map_join(value2, "", &w_str/1)

    xtra_points_bin =
      w_str("XTRA_POINTS") <>
        Enum.map_join(xtra_points, "", fn {pts, elo} -> w_i32(pts) <> w_i32(elo) end)

    joueurs =
      w_str("[JOUEURS]") <>
        w_i32(length(players)) <>
        Enum.map_join(players, "", &build_player(&1, version))

    header <>
      tournoi <> dates <> tie_break <> exclusion <> categories <> xtra_points_bin <> joueurs
  end

  defp pad_categories(list, size), do: list ++ List.duplicate("", size - length(list))

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
      w_i32(Map.get(p, :cat_index, 0)) <>
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
      w_i32(Map.get(p, :extra_pts, 0)) <>
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

    path =
      Path.join(System.tmp_dir!(), "synthetic-pass2-#{System.unique_integer([:positive])}.swar")

    File.write!(path, binary)

    try do
      SwarImport.import_file(path, nil)
    after
      File.rm(path)
    end
  end

  # SWAR result codes (manual §5.2): WIN (0x4000), LOSS (0x1000),
  # WIN_BYE (0x0040) - a pairing-allocated bye.
  @win 0x4000
  @loss 0x1000
  @win_bye 0x0040

  ## ---------- §3 / F11: round-robin bye forced to a full point ----------

  describe "a round robin's stored ByeValue" do
    test "is overridden to a full point, mirroring SWAR's own load-time forcing" do
      opts = %{
        # TOURNOI_TYPE.ROBIN
        type: 4,
        # ByeValue 2 = zero points, per the file itself - SWAR ignores this
        # at load for a round robin and always forces a full point instead.
        bye_value: 2,
        players: [
          %{ni: 1, name: "Odd, One", rounds: [%{round_nr: 1, result: @win_bye}]}
        ]
      }

      assert {:ok, tournament, warnings} = import_synthetic!(opts)
      assert tournament.bye_value == 1.0

      assert [message] = warnings
      assert message =~ "full point"
      assert message =~ "round robin"
    end

    test "says nothing when the round robin has no bye to speak of" do
      opts = %{
        type: 4,
        bye_value: 2,
        players: [
          %{
            ni: 1,
            name: "White, One",
            rounds: [%{round_nr: 1, advers: 2, result: @win, color: 1, table: 1}]
          },
          %{
            ni: 2,
            name: "Black, Two",
            rounds: [%{round_nr: 1, advers: 1, result: @loss, color: -1, table: 1}]
          }
        ]
      }

      # Still forced, even with nothing to trigger the warning - the
      # forcing is unconditional on the type, the warning is conditional
      # on there being a bye an arbiter would notice.
      assert {:ok, tournament, warnings} = import_synthetic!(opts)
      assert tournament.bye_value == 1.0
      assert warnings == []
    end

    test "an ordinary Swiss import still reads ByeValue from the file, unforced" do
      opts = %{
        type: 0,
        bye_value: 2,
        players: [%{ni: 1, name: "Solo, One"}]
      }

      assert {:ok, tournament, warnings} = import_synthetic!(opts)
      assert tournament.bye_value == 0.0
      assert warnings == []
    end
  end

  ## ---------- §5.2: legacy CatIndex < 100 normalisation ----------

  describe "a legacy CatIndex under 100" do
    test "still resolves to the player's category instead of going blank" do
      opts = %{
        type: 1,
        cat_type: 1,
        cat_value1: ["Senior", "Junior", "Cadet"],
        players: [%{ni: 1, name: "Old, File", cat_index: 2}]
      }

      assert {:ok, tournament, _warnings} = import_synthetic!(opts)
      assert [player] = Repo.all(Player)
      assert player.category == "Junior"
      assert tournament.categories == ["Senior", "Junior", "Cadet"]
    end

    test "a modern, already-scaled index is unaffected" do
      opts = %{
        type: 1,
        cat_type: 1,
        cat_value1: ["Senior", "Junior", "Cadet"],
        players: [%{ni: 1, name: "New, File", cat_index: 200}]
      }

      assert {:ok, _tournament, _warnings} = import_synthetic!(opts)
      assert [player] = Repo.all(Player)
      assert player.category == "Junior"
    end

    test "cat_index 0 still means no category at all" do
      opts = %{
        type: 1,
        cat_type: 1,
        cat_value1: ["Senior", "Junior"],
        players: [%{ni: 1, name: "None, One", cat_index: 0}]
      }

      assert {:ok, _tournament, _warnings} = import_synthetic!(opts)
      assert [player] = Repo.all(Player)
      assert player.category == ""
    end
  end

  ## ---------- §5.4 / F13: XtraPoints manual acceleration ----------

  describe "a Swiss file carrying XtraPoints" do
    test "warns that manual acceleration does not reach the pairing engine" do
      opts = %{
        type: 0,
        players: [%{ni: 1, name: "Accelerated, One", extra_pts: 8}]
      }

      assert {:ok, _tournament, warnings} = import_synthetic!(opts)
      assert [message] = warnings
      assert message =~ "XtraPoints"
      assert message =~ "acceleration"
    end

    test "a populated band table warns even before any player carries points" do
      opts = %{
        type: 0,
        xtra_points: [{4, 2000}, {0, 0}, {0, 0}, {0, 0}],
        players: [%{ni: 1, name: "Banded, One"}]
      }

      assert {:ok, _tournament, warnings} = import_synthetic!(opts)
      assert [message] = warnings
      assert message =~ "XtraPoints"
    end

    test "says nothing for an ordinary file with no acceleration configured" do
      opts = %{type: 0, players: [%{ni: 1, name: "Plain, One"}]}

      assert {:ok, _tournament, warnings} = import_synthetic!(opts)
      assert warnings == []
    end

    test "stays quiet for a round robin, where SWAR itself zeroes ExtraPts on load" do
      opts = %{
        type: 4,
        players: [%{ni: 1, name: "Robin, One", extra_pts: 8}]
      }

      assert {:ok, _tournament, warnings} = import_synthetic!(opts)
      assert warnings == []
    end
  end
end
