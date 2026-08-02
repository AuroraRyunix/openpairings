defmodule PairingsEngine.SwarImportV7Test do
  # SWAR v7 changed the on-disk layout in three places (see the version-gate
  # comments in `SwarImport`): [TOURNOI]'s tail lost 12 bytes between the
  # FIDE-id block and `Type`, [JOUEURS] lost `EloFide`, and [JOUEURS] lost one
  # int from the `NbParties`..`Perf` run. A real v7 file is a 26 KB list of
  # named people, so this covers the layout with synthetic binaries instead —
  # same approach (and the same builder shape) as
  # swar_import_presence_test.exs and swar_import_abs_value_test.exs, and for
  # the same reason: it must run on a checkout that has no real `.swar`
  # fixtures.
  use ExUnit.Case, async: true

  alias PairingsEngine.SwarImport

  ## ---------- synthetic .swar binary builder ----------

  defp w_str(s), do: <<byte_size(s)::little-signed-32, s::binary>>
  defp w_i32(n), do: <<n::little-signed-32>>
  defp w_i16(n), do: <<n::little-signed-16>>
  defp w_u8(n), do: <<n::8>>

  # `layout` picks which of the two indistinguishable-on-zeroes readings of
  # v7's shortened [TOURNOI] tail to *write*: `:strings` drops three of the
  # four trailing strings, `:fide_ids` drops one 3-int FIDE-id entry instead.
  # Real v7 files are one or the other; the parser probes for both.
  defp build(opts) do
    version = Map.get(opts, :version, "v7.04")
    layout = Map.get(opts, :layout, :strings)
    players = Map.get(opts, :players, [])
    arb1 = Map.get(opts, :fide_arb1, "")
    v7? = version >= "v7.00"

    n_fide_ids = if v7? and layout == :fide_ids, do: 15, else: 16

    trailing_strings =
      if v7? and layout == :strings,
        do: w_str(""),
        else: w_str(arb1) <> w_str("") <> w_str("") <> w_str("")

    tournoi =
      w_str("[TOURNOI]") <>
        w_str("V7 Open") <>
        Enum.map_join(1..7, "", fn _ -> w_str("") end) <>
        w_i32(0) <>
        w_str("") <>
        w_i32(1) <>
        Enum.map_join(1..7, "", fn _ -> w_i32(0) end) <>
        Enum.map_join(1..n_fide_ids, "", fn _ -> w_i32(0) <> w_i32(0) <> w_i32(0) end) <>
        trailing_strings <>
        tournoi_tail_ints() <>
        w_u8(0) <>
        w_u8(0) <>
        w_u8(0) <>
        w_u8(0) <>
        w_i32(0) <>
        w_i32(0)

    cat_strs = Enum.map_join(1..17, "", fn _ -> w_str("") end)

    w_str(version) <>
      w_str("guid") <>
      w_str("mac") <>
      tournoi <>
      w_str("[DATES]") <>
      w_str("02/08/2026") <>
      w_str("[TIE_BREAK]") <>
      Enum.map_join(1..5, "", fn _ -> w_i32(0) end) <>
      w_str("[EXCLUSION]") <>
      w_i32(0) <>
      w_str("") <>
      w_str("[CATEGORIES]") <>
      w_i32(0) <>
      cat_strs <>
      cat_strs <>
      w_str("[XTRA_POINTS]") <>
      Enum.map_join(1..4, "", fn _ -> w_i32(0) <> w_i32(0) end) <>
      w_str("[JOUEURS]") <>
      w_i32(length(players)) <>
      Enum.map_join(players, "", &build_player(&1, version))
  end

  # Type, SW_EloR1..SW321_Pre, SW321_PreBye (v6.03+), EloUsed..ByeValue —
  # unchanged in v7, and none of them under test here.
  defp tournoi_tail_ints, do: Enum.map_join(1..17, "", fn _ -> w_i32(0) end)

  # Gone in v7, which carries a single Elo instead of the national/FIDE pair.
  defp elo_fide_field(p, version) do
    if version >= "v7.00", do: <<>>, else: w_i32(Map.get(p, :elo_fide, 0))
  end

  # `Pts_Corr`: added in v6.49, gone again in v7.
  defp points_adjusted_field(version) do
    if version >= "v6.49" and version < "v7.00", do: w_i32(0), else: <<>>
  end

  defp build_player(p, version) do
    elo = Map.get(p, :elo, 0)

    w_i32(0) <>
      w_str(Map.get(p, :name, "Test Player")) <>
      w_i32(Map.fetch!(p, :ni)) <>
      w_i32(1) <>
      w_i32(0) <>
      w_str("") <>
      w_i32(1) <>
      w_str("BEL") <>
      w_i32(0) <>
      w_i32(Map.get(p, :mat_fide, 0)) <>
      w_i32(1) <>
      w_i32(elo) <>
      elo_fide_field(p, version) <>
      w_i32(Map.get(p, :title, 0)) <>
      w_i32(0) <>
      w_str("") <>
      w_i32(0) <>
      w_i32(0) <>
      points_adjusted_field(version) <>
      w_i32(0) <>
      Enum.map_join(1..5, "", fn _ -> w_i32(0) end) <>
      w_i32(0) <>
      w_i32(1) <>
      w_i32(0) <>
      w_str("") <>
      w_i32(0) <>
      w_i32(0) <>
      w_i16(0) <>
      w_i16(0) <>
      w_str("[RONDE]")
  end

  ## ---------- tests ----------

  test "parses a v7 file whose [TOURNOI] tail dropped three trailing strings" do
    binary = build(%{layout: :strings, players: [%{ni: 1}, %{ni: 2}]})

    assert {:ok, data} = SwarImport.parse(binary)
    assert data.version == "v7.04"
    assert data.tournament.name == "V7 Open"
    assert data.dates == ["02/08/2026"]
    assert length(data.players) == 2
  end

  test "parses a v7 file whose [TOURNOI] tail dropped a FIDE-id entry instead" do
    binary = build(%{layout: :fide_ids, players: [%{ni: 1}]})

    assert {:ok, data} = SwarImport.parse(binary)
    assert data.tournament.name == "V7 Open"
    assert length(data.players) == 1
  end

  # The two v7 readings only diverge once a trailing string is non-empty —
  # exactly the case the layout probe exists for. A `:fide_ids`-layout file
  # carrying a real FIDE arbiter id must not be read with the `:strings`
  # layout, which would swallow it and desynchronise everything after.
  test "a non-empty FIDE arbiter id picks the FIDE-id-entry layout" do
    binary = build(%{layout: :fide_ids, fide_arb1: "12345678", players: [%{ni: 1}]})

    assert {:ok, data} = SwarImport.parse(binary)
    assert data.tournament.fide_arb1 == "12345678"
    assert length(data.players) == 1
  end

  test "v7 mirrors the single remaining Elo into elo_fide, and keeps Title" do
    binary =
      build(%{players: [%{ni: 1, elo: 2346, title: 5, mat_fide: 250_511}]})

    assert {:ok, %{players: [player]}} = SwarImport.parse(binary)
    assert player.elo == 2346
    # v7 has no EloFide field; the one Elo it does carry is the FIDE rating.
    assert player.elo_fide == 2346
    assert player.title == 5
    assert player.mat_fide == 250_511
  end

  test "v7 carries no points_adjusted (the field is gone from the record)" do
    assert {:ok, %{players: [player]}} = SwarImport.parse(build(%{players: [%{ni: 1}]}))
    assert player.points_adjusted == 0
  end

  # Guards the shared code path: the v6 layout must keep reading EloFide and
  # Pts_Corr as separate fields, i.e. the v7 gates are gates, not rewrites.
  test "v6 still reads EloFide and points_adjusted as their own fields" do
    binary =
      build(%{
        version: "v6.78",
        players: [%{ni: 1, elo: 1610, elo_fide: 1602, title: 0}]
      })

    assert {:ok, %{players: [player]}} = SwarImport.parse(binary)
    assert player.elo == 1610
    assert player.elo_fide == 1602
  end

  test "a file matching no known [TOURNOI] layout fails with a clear error" do
    <<head::binary-size(120), rest::binary>> = build(%{players: [%{ni: 1}]})
    binary = head <> <<0, 0, 0, 0>> <> rest

    assert {:error, {:parse_failed, message}} = SwarImport.parse(binary)
    assert message =~ "[TOURNOI]"
  end
end
