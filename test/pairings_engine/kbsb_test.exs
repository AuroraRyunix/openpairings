defmodule PairingsEngine.KbsbTest do
  use PairingsEngine.DataCase, async: true

  import Ecto.Query

  alias PairingsEngine.Kbsb
  alias PairingsEngine.Kbsb.KbsbPlayer

  defp seed! do
    Repo.insert_all(KbsbPlayer, [
      %{
        national_id: "12345",
        last_name: "Peeters",
        first_name: "Jan",
        national_rating: 1850,
        fide_id: nil,
        club_number: 42,
        club_name: "KSK Antwerpen",
        federation: "VSF",
        birth_year: 1990
      },
      %{
        national_id: "67890",
        last_name: "Dubois",
        first_name: "Marie",
        national_rating: 2010,
        fide_id: 10_012_345,
        club_number: 13,
        club_name: "Cercle des Echecs",
        federation: "FEFB",
        birth_year: 1985
      },
      %{
        national_id: "00042",
        last_name: "Peeters",
        first_name: "Anna",
        national_rating: 1600,
        fide_id: nil,
        club_number: 42,
        club_name: "KSK Antwerpen",
        federation: "VSF",
        birth_year: 2005
      }
    ])
  end

  describe "search/1" do
    test "exact national-id match takes priority" do
      seed!()

      assert [%KbsbPlayer{national_id: "12345"}] = Kbsb.search("12345")
    end

    test "matches a name token, best rating first" do
      seed!()

      results = Kbsb.search("Peet")
      assert Enum.map(results, & &1.national_id) == ["12345", "00042"]
    end

    test "matches tokens in any order, and on the first name alone" do
      seed!()

      assert [%KbsbPlayer{national_id: "12345"}] = Kbsb.search("peeters jan")
      assert [%KbsbPlayer{national_id: "12345"}] = Kbsb.search("jan peeters")
      assert [%KbsbPlayer{national_id: "12345"}] = Kbsb.search("peeters, jan")
      assert [%KbsbPlayer{national_id: "12345"}] = Kbsb.search("jan")
    end

    test "folds diacritics, so an unaccented query finds an accented name" do
      Repo.insert_all(KbsbPlayer, [
        %{national_id: "55555", last_name: "Müller", first_name: "Jörg", national_rating: 1700}
      ])

      assert [%KbsbPlayer{national_id: "55555"}] = Kbsb.search("muller")
      assert [%KbsbPlayer{national_id: "55555"}] = Kbsb.search("jorg")
    end

    test "the full-text index is what answers, and the triggers keep it current" do
      seed!()

      # Proof the FTS path is live rather than the LIKE fallback: remove one
      # row from the index only, leaving `kbsb_players` untouched. If the
      # search were still scanning the table it would find it anyway.
      Repo.query!("DELETE FROM kbsb_players_fts WHERE national_id = ?", ["12345"])
      assert Enum.map(Kbsb.search("Peet"), & &1.national_id) == ["00042"]

      # And the UPDATE trigger puts a renamed player back under the new name.
      Repo.update_all(
        from(k in KbsbPlayer, where: k.national_id == "00042"),
        set: [last_name: "Janssens"]
      )

      assert Kbsb.search("Peet") == []
      assert [%KbsbPlayer{national_id: "00042"}] = Kbsb.search("Janssens")
    end

    test "queries under 2 characters return nothing" do
      seed!()

      assert Kbsb.search("P") == []
    end

    test "blank query returns nothing" do
      assert Kbsb.search("") == []
      assert Kbsb.search("   ") == []
    end

    test "unknown national id and unknown name both return an empty list" do
      seed!()

      assert Kbsb.search("99999") == []
      assert Kbsb.search("Nobody") == []
    end
  end

  describe "find_by_national_id/1" do
    test "finds an exact match" do
      seed!()

      assert %KbsbPlayer{last_name: "Dubois"} = Kbsb.find_by_national_id("67890")
    end

    test "returns nil for nil, blank, or unknown ids" do
      seed!()

      assert Kbsb.find_by_national_id(nil) == nil
      assert Kbsb.find_by_national_id("") == nil
      assert Kbsb.find_by_national_id("no-such-id") == nil
    end
  end

  describe "find_by_fide_id/1" do
    test "finds the KBSB row cross-referenced by FIDE id" do
      seed!()

      assert %KbsbPlayer{national_id: "67890"} = Kbsb.find_by_fide_id(10_012_345)
    end

    test "returns nil when nothing matches or fide_id is nil" do
      seed!()

      assert Kbsb.find_by_fide_id(nil) == nil
      assert Kbsb.find_by_fide_id(999) == nil
    end
  end

  describe "player_count/0 and last_sync/0" do
    test "player_count reflects the table, last_sync starts nil and updates on put_last_sync" do
      assert Kbsb.player_count() == 0
      assert Kbsb.last_sync() == nil

      seed!()
      assert Kbsb.player_count() == 3

      Kbsb.put_last_sync()
      assert Kbsb.last_sync() != nil
    end
  end

  describe "importing replaces existing rows on conflict (mirrors Sync's insert_all)" do
    test "on_conflict: :replace_all updates a row instead of erroring on a repeat national_id" do
      seed!()

      Repo.insert_all(
        KbsbPlayer,
        [
          %{
            national_id: "12345",
            last_name: "Peeters",
            first_name: "Jan",
            national_rating: 1900,
            fide_id: 4_000_000,
            club_number: 42,
            club_name: "KSK Antwerpen",
            federation: "VSF",
            birth_year: 1990
          }
        ],
        on_conflict: :replace_all,
        conflict_target: :national_id
      )

      assert Kbsb.player_count() == 3

      assert %KbsbPlayer{national_rating: 1900, fide_id: 4_000_000} =
               Kbsb.find_by_national_id("12345")
    end
  end
end
