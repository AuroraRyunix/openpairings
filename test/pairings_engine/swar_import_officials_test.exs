defmodule PairingsEngine.SwarImportOfficialsTest do
  # Officials autofill: SWAR stores every arbiter for an event in two free-text
  # fields ("IA Sylvin De Vet, NA Marc Van Dyck"), while the IT3/FA1 forms want
  # them split into numbered slots with a FIDE id each. Covers the parsing
  # (pure) and the id lookup (needs the FIDE table), plus the diacritic folding
  # that decides whether a player is offered any candidates at all.
  #
  # Synthetic binaries rather than the real `.swar` fixtures, which are
  # gitignored personal data — same approach as swar_import_presence_test.exs.
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Repo, SwarImport}
  alias PairingsEngine.Fide.FidePlayer

  ## ---------- synthetic .swar builder (v6.78) ----------

  defp w_str(s), do: <<byte_size(s)::little-signed-32, s::binary>>
  defp w_i32(n), do: <<n::little-signed-32>>
  defp w_i16(n), do: <<n::little-signed-16>>
  defp w_u8(n), do: <<n::8>>

  defp build(opts) do
    arbiter1 = Map.get(opts, :arbiter1, "")
    arbiter2 = Map.get(opts, :arbiter2, "")
    fide_ids = Map.get(opts, :fide_ids, List.duplicate(0, 16))
    players = Map.get(opts, :players, [])

    tournoi =
      w_str("[TOURNOI]") <>
        w_str("Officials Test") <>
        w_str("") <>
        w_str("") <>
        w_str("") <>
        w_str(arbiter1) <>
        w_str(arbiter2) <>
        w_str("") <>
        w_str("") <>
        w_i32(0) <>
        w_str("") <>
        w_i32(1) <>
        Enum.map_join(1..7, "", fn _ -> w_i32(0) end) <>
        Enum.map_join(fide_ids, "", fn id -> w_i32(0) <> w_i32(0) <> w_i32(id) end) <>
        w_str("") <>
        w_str("") <>
        w_str("") <>
        w_str("") <>
        Enum.map_join(1..17, "", fn _ -> w_i32(0) end) <>
        w_u8(0) <>
        w_u8(0) <>
        w_u8(0) <>
        w_u8(0) <>
        w_i32(0) <>
        w_i32(0)

    cat_strs = Enum.map_join(1..17, "", fn _ -> w_str("") end)

    w_str("v6.78") <>
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
      Enum.map_join(players, "", &build_player/1)
  end

  defp build_player(p) do
    w_i32(0) <>
      w_str(Map.fetch!(p, :name)) <>
      w_i32(Map.fetch!(p, :ni)) <>
      w_i32(1) <>
      w_i32(0) <>
      w_str(Map.get(p, :birth, "")) <>
      w_i32(1) <>
      w_str(Map.get(p, :country, "BEL")) <>
      w_i32(0) <>
      w_i32(Map.get(p, :mat_fide, 0)) <>
      w_i32(1) <>
      w_i32(0) <>
      w_i32(0) <>
      w_i32(0) <>
      w_i32(0) <>
      w_str("") <>
      w_i32(0) <>
      w_i32(0) <>
      w_i32(0) <>
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

  defp import!(opts) do
    path = Path.join(System.tmp_dir!(), "officials-#{System.unique_integer([:positive])}.swar")
    File.write!(path, build(opts))

    try do
      SwarImport.import_file(path)
    after
      File.rm(path)
    end
  end

  ## ---------- parsing (pure) ----------

  describe "split_officials/1 and strip_arbiter_title/1" do
    test "splits a comma-separated field into people and drops the title grades" do
      assert SwarImport.split_officials("IA Sylvin De Vet, NA Marc Van Dyck") ==
               ["Sylvin De Vet", "Marc Van Dyck"]
    end

    test "a single official with no comma stays one person" do
      assert SwarImport.split_officials("FA Jan Peeters") == ["Jan Peeters"]
    end

    test "blank fields produce no officials at all" do
      assert SwarImport.split_officials("") == []
      assert SwarImport.split_officials(nil) == []
    end

    test "strips stacked grades but never eats the actual name" do
      assert SwarImport.strip_arbiter_title("IO NA Marc Van Dyck") == "Marc Van Dyck"
      assert SwarImport.strip_arbiter_title("Luc Cornet") == "Luc Cornet"
      # "Ian" starts with IA's letters but isn't a grade — must survive.
      assert SwarImport.strip_arbiter_title("Ian Nepomniachtchi") == "Ian Nepomniachtchi"
    end
  end

  describe "cadence_label/2" do
    # Reverse-engineered from SWAR's own source (Utils.cpp's GetCadence/2 +
    # Languages/Swar.Lang.fr.ini's [CADENCES] section), not from a .swar
    # sample — see the moduledoc comment above cadence_label/2 for how.
    test "standard cadence 12 (0-based) is 90 min + 30 sec/move — the real Geraardsbergen 2026 value" do
      assert SwarImport.cadence_label(0, 12) == "90 min + 30 sec/move"
    end

    test "picks the rapid or blitz table when tournoi_std says so" do
      assert SwarImport.cadence_label(1, 0) == "Rapid 10 min + 10 sec/move"
      assert SwarImport.cadence_label(2, 0) == "Blitz 3 min + 2 sec/move"
    end

    test "the last index of each list ('autre cadence' / Other) is deliberately unmapped" do
      # Standard has 13 real entries (0-12); index 13 is "autre cadence".
      refute SwarImport.cadence_label(0, 13)
      refute SwarImport.cadence_label(1, 22)
      refute SwarImport.cadence_label(2, 13)
    end

    test "an out-of-range or missing cadence falls through to nil" do
      refute SwarImport.cadence_label(0, 999)
      refute SwarImport.cadence_label(0, nil)
    end
  end

  ## ---------- import wiring ----------

  test "deputies land in numbered officials slots and the chief loses its grade" do
    assert {:ok, t, _warnings} =
             import!(%{
               arbiter1: "IA Luc Cornet",
               arbiter2: "IA Sylvin De Vet, NA Marc Van Dyck",
               players: [%{ni: 1, name: "Player, One"}]
             })

    assert t.chief_arbiter == "Luc Cornet"
    # The free-text field itself is preserved verbatim for reports/exports.
    assert t.deputy_arbiter == "IA Sylvin De Vet, NA Marc Van Dyck"
    assert t.officials["deputy1_name"] == "Sylvin De Vet"
    assert t.officials["deputy2_name"] == "Marc Van Dyck"
  end

  test "an official matching exactly one FIDE entry gets their id filled in" do
    Repo.insert_all(FidePlayer, [
      # FIDE stores "Last, First"; SWAR wrote "First Last". Must still match.
      %{fide_id: 205_494, name: "Cornet, Luc", federation: "BEL"},
      %{fide_id: 214_787, name: "De Vet, Sylvin", federation: "BEL"}
    ])

    assert {:ok, t, _warnings} =
             import!(%{
               arbiter1: "IA Luc Cornet",
               arbiter2: "IA Sylvin De Vet",
               players: [%{ni: 1, name: "Player, One"}]
             })

    assert t.officials["chief_arbiter_fide_id"] == "205494"
    assert t.officials["deputy1_fide_id"] == "214787"
  end

  test "an ambiguous official is left blank rather than guessed" do
    Repo.insert_all(FidePlayer, [
      %{fide_id: 207_640, name: "Van Dyck, Marc", federation: "BEL", birth_year: 1960},
      %{fide_id: 228_494, name: "Van Dyck, Marc", federation: "BEL", birth_year: 1953}
    ])

    assert {:ok, t, _warnings} =
             import!(%{
               arbiter2: "NA Marc Van Dyck",
               players: [%{ni: 1, name: "Player, One"}]
             })

    assert t.officials["deputy1_name"] == "Marc Van Dyck"
    refute Map.has_key?(t.officials, "deputy1_fide_id")
  end

  test "an official with no FIDE entry at all is left blank" do
    assert {:ok, t, _warnings} =
             import!(%{
               arbiter2: "NA Nobody Here",
               players: [%{ni: 1, name: "Player, One"}]
             })

    assert t.officials["deputy1_name"] == "Nobody Here"
    refute Map.has_key?(t.officials, "deputy1_fide_id")
  end

  ## ---------- FIDE event code ----------

  describe "event_code from the [TOURNOI] FIDE block" do
    test "a single homologation id becomes the event code" do
      ids = List.replace_at(List.duplicate(0, 16), 0, 123_456)

      assert {:ok, t, _} = import!(%{fide_ids: ids, players: [%{ni: 1, name: "P, One"}]})
      assert t.event_code == "123456"
    end

    test "several distinct ids are all kept, in file order" do
      ids =
        List.duplicate(0, 16)
        |> List.replace_at(0, 111)
        |> List.replace_at(1, 222)
        # a repeat must not be listed twice
        |> List.replace_at(2, 111)

      assert {:ok, t, _} = import!(%{fide_ids: ids, players: [%{ni: 1, name: "P, One"}]})
      assert t.event_code == "111, 222"
    end

    test "an unhomologated tournament (all zeroes) leaves it blank" do
      assert {:ok, t, _} = import!(%{players: [%{ni: 1, name: "P, One"}]})
      assert t.event_code == ""
    end
  end

  ## ---------- player matching: diacritics and federation ----------

  describe "candidates for a player SWAR left without a FIDE id" do
    test "a name differing only by diacritics still produces a candidate" do
      Repo.insert_all(FidePlayer, [
        %{fide_id: 999_001, name: "Muller, Hans", federation: "BEL", birth_year: 1980}
      ])

      path = Path.join(System.tmp_dir!(), "diacritic-#{System.unique_integer([:positive])}.swar")

      # SWAR strings are CP-1252, so "ü" is the single byte 0xFC — writing the
      # UTF-8 encoding here would make the parser (correctly) decode it as
      # "Ã¼" and the test would be checking the wrong thing.
      umlaut_name = <<"M", 0xFC, "ller, Hans">>

      File.write!(
        path,
        build(%{players: [%{ni: 1, name: umlaut_name, country: "BEL", birth: "19800101"}]})
      )

      try do
        assert {:ok, %{data: data, unresolved: unresolved}} = SwarImport.prepare_import(path)
        # Exact name + federation + birth year, once folded — auto-adopted.
        assert unresolved == []
        assert [%{mat_fide: 999_001}] = data.players
      after
        File.rm(path)
      end
    end

    test "a player whose federation disagrees with FIDE's is still offered as a choice" do
      Repo.insert_all(FidePlayer, [
        %{fide_id: 999_002, name: "Transfer, Tim", federation: "NED", birth_year: 1990}
      ])

      path = Path.join(System.tmp_dir!(), "fed-#{System.unique_integer([:positive])}.swar")

      File.write!(
        path,
        build(%{players: [%{ni: 1, name: "Transfer, Tim", country: "BEL", birth: "19900101"}]})
      )

      try do
        assert {:ok, %{unresolved: [entry]}} = SwarImport.prepare_import(path)
        # Never auto-adopted across federations — but offered for a human to pick.
        assert Enum.map(entry.candidates, & &1.fide_id) == [999_002]
      after
        File.rm(path)
      end
    end
  end
end
