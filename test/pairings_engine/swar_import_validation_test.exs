defmodule PairingsEngine.SwarImportValidationTest do
  # Deliberately a SEPARATE module from swar_import_test.exs, which carries
  # `@moduletag :swar_fixture` (excluded when the gitignored real .swar
  # fixtures aren't present) - same rationale as swar_import_presence_test.exs
  # and swar_import_abs_value_test.exs, whose synthetic `.swar` binary builder
  # this file reuses. Everything here is malformed-input handling, so it has to
  # run on a fresh checkout too.
  use PairingsEngine.DataCase, async: false

  import Ecto.Query

  alias PairingsEngine.{Repo, SwarImport}
  alias PairingsEngine.Tournaments.{Pairing, Player, Tournament}

  ## ---------- synthetic .swar binary builder ----------
  #
  # Mirrors PairingsEngine.SwarImport.parse/1's field-by-field layout closely
  # enough to produce a binary `parse/1` accepts - every field not under test
  # is written as a zero/blank placeholder.

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
    abs_nbfois = Map.get(opts, :abs_nbfois, 0)
    abs_jusque = Map.get(opts, :abs_jusque, 0)
    players = Map.get(opts, :players, [])
    nb_rounds = Map.get(opts, :nb_rounds, 1)

    header = w_str(version) <> w_str("guid") <> w_str("mac")

    # legacy ByeValue field - not under test here
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
        w_u8(abs_value) <>
        w_u8(abs_nbfois) <>
        w_u8(abs_jusque) <>
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

    path =
      Path.join(
        System.tmp_dir!(),
        "synthetic-validation-#{System.unique_integer([:positive])}.swar"
      )

    File.write!(path, binary)

    try do
      SwarImport.import_file(path, nil)
    after
      File.rm(path)
    end
  end

  # SWAR result codes (manual 5.2), as used by `result_class/1`.
  @win 0x4000
  @loss 0x1000

  defp counts do
    {Repo.aggregate(Tournament, :count), Repo.aggregate(Player, :count)}
  end

  defp pairings(tournament) do
    Repo.all(
      from p in Pairing,
        join: r in assoc(p, :round),
        where: r.tournament_id == ^tournament.id
    )
  end

  ## ---------- M8: an invalid player is reported, not a MatchError ----------

  describe "a player the Player changeset rejects" do
    test "comes back as an error tuple, and nothing is written" do
      before = counts()

      opts = %{
        players: [
          %{ni: 1, name: "Valid, Player"},
          %{ni: 2, name: ""}
        ]
      }

      assert {:error, message} = import_synthetic!(opts)
      assert is_binary(message)
      assert message =~ "Could not import player"
      assert message =~ "name"

      # The whole transaction rolled back - neither the valid player nor the
      # tournament row survived.
      assert counts() == before
    end
  end

  ## ---------- M9: one-sided and self-referential [RONDE] entries ----------

  describe "a [RONDE] entry whose opponent does not agree" do
    test "a player pointing at themselves is never paired against themselves" do
      opts = %{
        players: [
          %{ni: 1, name: "Selfie, One", rounds: [%{round_nr: 1, advers: 1, result: @win}]},
          %{ni: 2, name: "Other, Two", rounds: [%{round_nr: 1, advers: 0, result: 0}]}
        ]
      }

      assert {:ok, tournament, _warnings} = import_synthetic!(opts)

      for pairing <- pairings(tournament) do
        refute pairing.black_player_id == pairing.white_player_id
      end
    end

    test "a non-mutual reference falls through to the single-sided path" do
      # 1 says it played 2; 2's own record names nobody. Before the mutuality
      # guard this built a real two-sided game from one side's word alone.
      opts = %{
        players: [
          %{ni: 1, name: "Claims, One", rounds: [%{round_nr: 1, advers: 2, result: @win}]},
          %{ni: 2, name: "Denies, Two", rounds: [%{round_nr: 1, advers: 0, result: 0}]}
        ]
      }

      assert {:ok, tournament, _warnings} = import_synthetic!(opts)

      # No board at all carries two players: the unilateral claim was not
      # enough to build one.
      refute Enum.any?(pairings(tournament), &(&1.black_player_id != nil))
    end

    test "a mutual pair still becomes one real game" do
      opts = %{
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

      assert {:ok, tournament, _warnings} = import_synthetic!(opts)

      assert [pairing] = pairings(tournament)
      assert pairing.result == "1-0"
      refute pairing.black_player_id == nil
      refute pairing.black_player_id == pairing.white_player_id
    end
  end

  ## ---------- M10: duplicate NI ----------

  describe "two [JOUEURS] records sharing an NI" do
    test "are refused before anything is written" do
      before = counts()

      opts = %{
        players: [
          %{ni: 1, name: "First, One"},
          %{ni: 1, name: "Second, One"},
          %{ni: 3, name: "Third, Three"}
        ]
      }

      assert {:error, {:parse_failed, message}} = import_synthetic!(opts)
      assert message =~ "duplicate player number"
      assert message =~ "1"

      assert counts() == before
    end

    test "are refused by parse/1 itself, so the pure struct path refuses too" do
      binary = build_swar_binary(%{players: [%{ni: 7, name: "A"}, %{ni: 7, name: "B"}]})

      assert {:error, {:parse_failed, _}} = SwarImport.parse(binary)
      assert {:error, {:parse_failed, _}} = SwarImport.build_structs(binary)
    end

    test "distinct NIs parse fine" do
      binary = build_swar_binary(%{players: [%{ni: 7, name: "A"}, %{ni: 8, name: "B"}]})

      assert {:ok, %{players: [_, _]}} = SwarImport.parse(binary)
    end
  end
end
