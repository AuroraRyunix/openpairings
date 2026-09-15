defmodule PairingsEngine.Federations.BEL.SwarImportSafeErrorTest do
  # Deliberately a separate module from swar_import_test.exs (real,
  # gitignored fixtures, `@moduletag :swar_fixture`) - this builds its own
  # synthetic, truncated `.swar` binary (the same builder
  # swar_import_validation_test.exs uses, copied rather than shared so this
  # file has no compile-time dependency on another test module), so it has
  # to run on a fresh checkout too.
  use PairingsEngine.DataCase, async: false

  import ExUnit.CaptureLog

  alias PairingsEngine.Federations.BEL.SwarImport

  ## ---------- synthetic .swar binary builder (mirrors swar_import_validation_test.exs) ----------

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

  ## ---------- the leak scenario ----------

  # Truncates `binary` a few bytes into the FIRST occurrence of `needle` -
  # here, a player's name - so `read_str/1`'s
  # `<<bytes::binary-size(^len), rest2::binary>> = rest` fails to match
  # partway through reading it. Exactly the KBSB 0.62.5 shape (a `rescue`
  # quoting the term it failed on) reproduced in the SWAR parser: the
  # `MatchError`'s own `Exception.message/1` would quote `rest`, which
  # starts with this partial name.
  defp truncate_inside(binary, needle) do
    {start, _len} = :binary.match(binary, needle)
    binary_part(binary, 0, start + 3)
  end

  describe "a file truncated partway through a player's name" do
    test "never quotes the player data it failed on, on the page or in the log" do
      full =
        build_swar_binary(%{
          players: [%{ni: 1, name: "Peeters, SecretFakeName"}]
        })

      binary = truncate_inside(full, "SecretFakeName")

      log =
        capture_log(fn ->
          assert {:error, {:parse_failed, message}} = SwarImport.parse(binary)
          refute message =~ "SecretFakeName"
          assert message =~ "MatchError"
        end)

      refute log =~ "SecretFakeName"
    end

    test "the same protection holds through prepare_import/1 and error_message/1" do
      full =
        build_swar_binary(%{
          players: [%{ni: 1, name: "Peeters, SecretFakeName"}]
        })

      binary = truncate_inside(full, "SecretFakeName")
      path = Path.join(System.tmp_dir!(), "truncated-#{System.unique_integer([:positive])}.swar")
      File.write!(path, binary)

      try do
        log =
          capture_log(fn ->
            assert {:error, reason} = SwarImport.prepare_import(path)
            flash = SwarImport.error_message(reason)
            refute flash =~ "SecretFakeName"
          end)

        refute log =~ "SecretFakeName"
      after
        File.rm(path)
      end
    end
  end
end
