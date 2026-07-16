defmodule PairingsEngine.SwarImportAbsValueTest do
  # Deliberately a SEPARATE module from swar_import_test.exs, which carries
  # `@moduletag :swar_fixture` (excluded when the gitignored real .swar
  # fixtures aren't present — a fresh checkout, CI). A synthetic-binary test
  # that must run even without the real fixtures cannot live in that module
  # — same rationale as swar_import_presence_test.exs, whose minimal-but-
  # format-valid `.swar` binary builder this file mirrors (with `abs_value`
  # made variable instead of hardcoded).
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{SwarImport, Standings}

  ## ---------- synthetic .swar binary builder ----------
  #
  # Mirrors PairingsEngine.SwarImport.parse/1's field-by-field layout closely
  # enough to produce a binary `parse/1` accepts — every field not under
  # test is written as a zero/blank placeholder.

  defp w_str(s), do: <<byte_size(s)::little-signed-32, s::binary>>
  defp w_i32(n), do: <<n::little-signed-32>>
  defp w_i16(n), do: <<n::little-signed-16>>
  defp w_u8(n), do: <<n::8>>

  defp version_gte?(version, target), do: version >= target

  defp build_swar_binary(opts) do
    version = Map.get(opts, :version, "v6.60")
    type = Map.get(opts, :type, 0)
    {win, nul, los, bye, pre} = Map.get(opts, :sw321, {4, 2, 0, 4, 0})
    prebye = Map.get(opts, :prebye, 0)
    abs_value = Map.get(opts, :abs_value, 0)
    players = Map.get(opts, :players, [])
    nb_rounds = Map.get(opts, :nb_rounds, 1)

    header = w_str(version) <> w_str("guid") <> w_str("mac")

    tournoi =
      w_str("TOURNOI") <>
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
        # legacy ByeValue field — not under test here
        w_i32(0) <>
        w_u8(abs_value) <>
        w_u8(0) <>
        w_u8(0) <>
        w_u8(0) <>
        w_i32(0) <>
        w_i32(0)

    dates = w_str("DATES") <> Enum.map_join(1..nb_rounds, "", fn _ -> w_str("") end)
    tie_break = w_str("TIE_BREAK") <> Enum.map_join(1..5, "", fn _ -> w_i32(0) end)
    exclusion = w_str("EXCLUSION") <> w_i32(0) <> w_str("")

    max_categ = if version_gte?(version, "v6.50"), do: 16, else: 12
    cat_strs = Enum.map_join(1..(max_categ + 1), "", fn _ -> w_str("") end)
    categories = w_str("CATEGORIES") <> w_i32(0) <> cat_strs <> cat_strs

    xtra_points =
      w_str("XTRA_POINTS") <> Enum.map_join(1..4, "", fn _ -> w_i32(0) <> w_i32(0) end)

    joueurs =
      w_str("JOUEURS") <>
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
      w_str("RONDE") <>
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
    path = Path.join(System.tmp_dir!(), "synthetic-abs-#{System.unique_integer([:positive])}.swar")
    File.write!(path, binary)

    try do
      SwarImport.import_file(path)
    after
      File.rm(path)
    end
  end

  # A `[RONDE]` entry with result 0 (SWAR's `:none`), a non-bye table, and
  # no real opponent (`advers: 0`) falls through `single_sided/2`'s
  # catch-all clause to a `byes` row with `type: "absent"` — the same shape
  # a TABLE_ABSENT-marked round from a real file would produce.
  defp absent_round(round_nr), do: %{round_nr: round_nr, result: 0, table: 0, advers: 0}

  ## ---------- parsed-map mapping: AbsValue 5/0 -> 0.5/0.0 ----------

  test "import_file/1 maps raw abs_value: 5 onto tournament.abs_value == 0.5" do
    opts = %{
      type: 0,
      abs_value: 5,
      players: [%{ni: 1, name: "Player, One", rounds: [absent_round(1)]}]
    }

    assert {:ok, tournament} = import_synthetic!(opts)
    assert tournament.abs_value == 0.5
  end

  test "import_file/1 maps raw abs_value: 0 onto tournament.abs_value == 0.0" do
    opts = %{
      type: 0,
      abs_value: 0,
      players: [%{ni: 1, name: "Player, One", rounds: [absent_round(1)]}]
    }

    assert {:ok, tournament} = import_synthetic!(opts)
    assert tournament.abs_value == 0.0
  end

  ## ---------- absent-bye scoring: abs_value when set, points_loss fallback otherwise ----------

  test "an \"absent\" bye scores at abs_value (0.5) when the tournament has one, for a standard-scoring import" do
    opts = %{
      # type != 3 — abs_value is a general [TOURNOI] field, unconditional on
      # tournament type, unlike presence_value (3-2-1 only).
      type: 0,
      abs_value: 5,
      players: [%{ni: 1, name: "Player, One", rounds: [absent_round(1)]}]
    }

    assert {:ok, tournament} = import_synthetic!(opts)
    assert tournament.abs_value == 0.5
    assert tournament.presence_value == nil

    [player] = PairingsEngine.Tournaments.list_players(tournament.id)
    entry = Enum.find(Standings.standings(tournament), &(&1.player.id == player.id))
    assert entry.points == 0.5
  end

  test "an \"absent\" bye scores at abs_value for a 3-2-1 (type == 3) import too — the field is type-independent" do
    opts = %{
      type: 3,
      sw321: {8, 4, 0, 8, 4},
      abs_value: 5,
      players: [%{ni: 1, name: "Player, One", rounds: [absent_round(1)]}]
    }

    assert {:ok, tournament} = import_synthetic!(opts)
    assert tournament.abs_value == 0.5
    # Confirms abs_value is mapped even though this is a 3-2-1 import whose
    # scoring_attrs/1 clause never touches it.
    assert tournament.points_loss == 0.0

    [player] = PairingsEngine.Tournaments.list_players(tournament.id)
    entry = Enum.find(Standings.standings(tournament), &(&1.player.id == player.id))
    assert entry.points == 0.5
  end

  test "an \"absent\" bye falls back to points_loss when the tournament isn't a SWAR import (abs_value nil)" do
    # Not a SWAR import at all — abs_value is nil by schema default.
    {:ok, tournament} =
      PairingsEngine.Tournaments.create_tournament(%{
        "name" => "Non-SWAR",
        "type" => "swiss",
        "rounds_count" => "3"
      })

    assert tournament.abs_value == nil

    {:ok, player} = PairingsEngine.Tournaments.create_player(tournament.id, %{"name" => "P"})

    PairingsEngine.Repo.insert_all("byes", [
      %{tournament_id: tournament.id, player_id: player.id, round: 1, type: "absent"}
    ])

    entry = Enum.find(Standings.standings(tournament), &(&1.player.id == player.id))
    assert entry.points == tournament.points_loss
    assert entry.points == 0.0
  end
end
