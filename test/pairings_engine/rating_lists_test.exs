defmodule PairingsEngine.RatingListsTest do
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Fide, Meta, RatingLists, RatingRefresh, Tournaments}
  alias PairingsEngine.Fide.FidePlayer
  alias PairingsEngine.RatingLists.Csv
  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.AccountsFixtures

  defp tournament(attrs \\ %{}) do
    scope = Scope.for_user(AccountsFixtures.user_fixture())

    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Lists", "type" => "swiss"}, attrs)
      )

    tournament
  end

  defp csv(rows),
    do: Enum.join(["id,name,rating,federation,title,birth_year,fide_id" | rows], "\n")

  describe "the default sequence (VCL4THP 123)" do
    test "follows the rate of play, with the lists the draft names" do
      assert RatingLists.default_sequence("standard") ==
               ["fide_standard", "fide_rapid", "fide_blitz"]

      assert RatingLists.default_sequence("rapid") == ["effective_rapid", "fide_blitz"]
      assert RatingLists.default_sequence("blitz") == ["effective_blitz", "fide_rapid"]
    end

    test "a new tournament has the default for its rate of play, and follows a change of it" do
      t = tournament(%{"standard" => "rapid"})
      assert t.rating_list_sequence == nil
      assert RatingLists.sequence(t) == ["effective_rapid", "fide_blitz"]
      refute RatingLists.custom_sequence?(t)

      {:ok, t} = Tournaments.update_tournament(t, %{"standard" => "blitz"})
      assert RatingLists.sequence(t) == ["effective_blitz", "fide_rapid"]
    end
  end

  describe "a sequence of the tournament's own (VCL4THP 124, 126)" do
    test "is stored, in the order given, and used" do
      t = tournament()

      {:ok, t} =
        Tournaments.update_tournament(t, %{
          "rating_list_sequence" => ["fide_rapid", "fide_standard", "national"]
        })

      assert t.rating_list_sequence == ["fide_rapid", "fide_standard", "national"]
      assert RatingLists.sequence(t) == ["fide_rapid", "fide_standard", "national"]
      assert RatingLists.custom_sequence?(t)
    end

    test "unknown lists and repeats are dropped, and an empty sequence means the default" do
      t = tournament()

      {:ok, t} =
        Tournaments.update_tournament(t, %{
          "rating_list_sequence" => ["fide_blitz", "nonsense", "fide_blitz", "custom:abc"]
        })

      assert t.rating_list_sequence == ["fide_blitz"]

      {:ok, t} = Tournaments.update_tournament(t, %{"rating_list_sequence" => []})
      assert t.rating_list_sequence == nil
      assert RatingLists.sequence(t) == RatingLists.default_sequence("standard")
    end

    test "a custom list that was deleted falls out of the sequence" do
      t = tournament()
      {:ok, list, _} = RatingLists.import_list("Club", [row("1", "A", 1500)])

      {:ok, t} =
        Tournaments.update_tournament(t, %{
          "rating_list_sequence" => ["fide_standard", "custom:#{list.id}"]
        })

      assert RatingLists.sequence(t) == ["fide_standard", "custom:#{list.id}"]

      {:ok, _} = RatingLists.delete_list(list.id)
      assert RatingLists.sequence(t) == ["fide_standard"]
    end
  end

  describe "ratings in the lists of a sequence" do
    test "the effective lists fall back to Standard, the FIDE lists do not" do
      fp = %FidePlayer{fide_id: 1, standard_rating: 1800, rapid_rating: nil, blitz_rating: 0}

      assert RatingLists.fide_rating(fp, "effective_rapid") == {1800, "standard"}
      assert RatingLists.fide_rating(fp, "effective_blitz") == {1800, "standard"}
      assert RatingLists.fide_rating(fp, "fide_rapid") == nil
      assert RatingLists.fide_rating(fp, "fide_blitz") == nil

      assert RatingLists.fide_rating(%{fp | rapid_rating: 1700}, "effective_rapid") ==
               {1700, "rapid"}
    end

    test "the main list's values are what is entered, the others are offered" do
      fp = %FidePlayer{fide_id: 1, standard_rating: nil, rapid_rating: 1850, blitz_rating: 1900}
      Meta.put("fide_list_period", "2026-10")
      seq = ["fide_standard", "fide_rapid", "fide_blitz"]

      assert %{"fide_rating" => nil, "fide_rating_source" => ""} =
               RatingLists.main_values(fp, seq)

      assert [%{entry: "fide_rapid", rating: 1850}, %{entry: "fide_blitz", rating: 1900}] =
               RatingLists.other_ratings(fp, seq)

      other = Enum.find(RatingLists.other_ratings(fp, seq), &(&1.entry == "fide_rapid"))

      assert %{
               "fide_rating" => 1850,
               "fide_rating_source" => "rapid",
               "fide_rating_period" => "2026-10",
               "fide_rating_listed" => 1850
             } = RatingLists.values(other)
    end

    test "a custom list gives its rating to the FIDE record it links to, as the national rating" do
      {:ok, list, _} =
        RatingLists.import_list("Club", [
          %{row("c1", "Linked", 1550) | fide_id: 77},
          row("c2", "Unlinked", 1400)
        ])

      fp = %FidePlayer{fide_id: 77, standard_rating: 1800}
      seq = ["fide_standard", "custom:#{list.id}"]

      assert [%{entry: "custom:" <> _, rating: 1550, lane: :national, label: "Club"} = other] =
               RatingLists.other_ratings(fp, seq)

      assert RatingLists.values(other) == %{"national_rating" => 1550}
      assert RatingLists.main_values(fp, seq)["fide_rating"] == 1800
    end

    test "a custom list as the main list clears the FIDE rating and fills the national one" do
      {:ok, list, _} =
        RatingLists.import_list("Club", [%{row("c1", "Linked", 1550) | fide_id: 77}])

      fp = %FidePlayer{fide_id: 77, standard_rating: 1800}

      values = RatingLists.main_values(fp, ["custom:#{list.id}", "fide_standard"])
      assert values["national_rating"] == 1550
      assert values["fide_rating"] == nil
    end
  end

  describe "custom lists (VCL4THP 117)" do
    test "import, search, replace keeping the id, delete" do
      {:ok, list, false} =
        RatingLists.import_list("Club", [
          row("a1", "Smith, John", 1600),
          row("a2", "Jones, Ann", nil)
        ])

      assert list.entry_count == 2
      seq = ["fide_standard", "custom:#{list.id}"]

      assert [{"Club", %{name: "Smith, John", rating: 1600}}] =
               RatingLists.search_custom(seq, "smith")

      assert [{"Club", %{ext_id: "a2"}}] = RatingLists.search_custom(seq, "a2")
      assert RatingLists.search_custom(["fide_standard"], "smith") == []

      {:ok, again, true} = RatingLists.import_list("club", [row("b1", "Brown, Bob", 1200)])
      assert again.id == list.id
      assert again.entry_count == 1
      assert RatingLists.search_custom(seq, "smith") == []
      assert [{_, %{name: "Brown, Bob"}}] = RatingLists.search_custom(seq, "brown")

      {:ok, _} = RatingLists.delete_list(list.id)
      assert RatingLists.custom_lists() == []
      assert RatingLists.search_custom(seq, "brown") == []
    end

    test "an empty list or a nameless one is refused" do
      assert {:error, _} = RatingLists.import_list("X", [])
      assert {:error, _} = RatingLists.import_list("  ", [row("1", "A", 1)])
    end

    test "search treats LIKE wildcards as plain text" do
      {:ok, list, _} = RatingLists.import_list("Club", [row("1", "Smith", 1500)])
      assert RatingLists.search_custom(["custom:#{list.id}"], "%%") == []
    end
  end

  describe "CSV files" do
    test "a valid file, with aliases, a semicolon and quotes" do
      raw =
        "Nr;Naam;Elo;Fed;Titel;Born;FIDE\n1;\"Smith; John\";1600;bel;fm;1990;12345\n2;Ann;;;;;\n"

      assert {:ok, [first, second]} = Csv.parse(raw)

      assert %{
               ext_id: "1",
               name: "Smith; John",
               rating: 1600,
               federation: "BEL",
               title: "FM",
               birth_year: 1990,
               fide_id: 12_345
             } = first

      assert %{name: "Ann", rating: nil, federation: "", title: "", birth_year: nil, fide_id: nil} =
               second
    end

    test "tabs, a byte order mark and Windows-1252 are read" do
      raw = <<0xEF, 0xBB, 0xBF>> <> "id\tname\trating\n1\tJosé\t1500\n"
      assert {:ok, [%{name: "José"}]} = Csv.parse(raw)

      latin = "id,name,rating\n1,Jos" <> <<0xE9>> <> ",1500\n"
      assert {:ok, [%{name: "José"}]} = Csv.parse(latin)
    end

    test "the header must name id, name and rating" do
      assert {:error, [msg]} = Csv.parse("id,name\n1,A\n")
      assert msg =~ "rating"
      assert {:error, [_]} = Csv.parse("")
    end

    test "every bad row is reported with its line, and nothing is returned" do
      raw =
        csv([
          "1,Good,1500,BEL,GM,1980,10",
          "2,,1500,,,,",
          "3,BadRating,abc,,,,",
          "4,BadFed,1500,BELG,,,",
          "5,BadTitle,1500,,XX,,",
          "6,BadYear,1500,,,1500,",
          "7,BadFide,1500,,,,x",
          "1,Duplicate,1400,,,,"
        ])

      assert {:error, errors} = Csv.parse(raw)
      assert length(errors) == 7
      assert Enum.any?(errors, &(&1 =~ "Line 3: the name is empty"))
      assert Enum.any?(errors, &(&1 =~ "Line 4: the rating"))
      assert Enum.any?(errors, &(&1 =~ "Line 5: the federation"))
      assert Enum.any?(errors, &(&1 =~ "Line 6: the title"))
      assert Enum.any?(errors, &(&1 =~ "Line 7: the birth year"))
      assert Enum.any?(errors, &(&1 =~ "Line 8: the FIDE ID"))
      assert Enum.any?(errors, &(&1 =~ "Line 9: the id 1 appears twice"))
    end

    test "a very long digit string is refused, not converted" do
      raw = csv(["1,A,#{String.duplicate("9", 500_000)},,,,"])
      assert {:error, [msg]} = Csv.parse(raw)
      assert msg =~ "rating"
    end
  end

  describe "the FIDE rating a refresh reads (VCL4THP 123)" do
    setup do
      Meta.put("fide_list_period", Fide.month_of(Date.utc_today()))
      :ok
    end

    test "comes from the first FIDE list of the tournament's sequence" do
      t = tournament()

      {:ok, _} =
        Tournaments.create_player(t.id, %{
          "name" => "Alice",
          "fide_id" => "5",
          "fide_rating" => "1"
        })

      Repo.insert!(%FidePlayer{
        fide_id: 5,
        name: "Alice",
        standard_rating: 2100,
        rapid_rating: 1900
      })

      assert [%{new: 2100}] =
               RatingRefresh.dry_run(t).proposals |> Enum.filter(&(&1.field == :fide_rating))

      {:ok, t} =
        Tournaments.update_tournament(t, %{
          "rating_list_sequence" => ["national", "fide_rapid", "fide_standard"]
        })

      assert [%{new: 1900, extra: %{fide_rating_source: "rapid"}}] =
               RatingRefresh.dry_run(t).proposals |> Enum.filter(&(&1.field == :fide_rating))
    end
  end

  describe "consistency checks on and off (VCL4THP 138)" do
    setup do
      Meta.put("fide_list_period", Fide.month_of(Date.utc_today()))
      :ok
    end

    test "off silences the automatic notice and leaves the check you ask for" do
      t = tournament()

      {:ok, _} =
        Tournaments.create_player(t.id, %{
          "name" => "Alice",
          "fide_id" => "5",
          "fide_rating" => "1"
        })

      Repo.insert!(%FidePlayer{fide_id: 5, name: "Alice", standard_rating: 2100})

      assert t.rating_checks_enabled
      assert %{changed: 1} = RatingRefresh.notice(t)

      {:ok, off} = Tournaments.update_tournament(t, %{"rating_checks_enabled" => false})
      refute off.rating_checks_enabled
      assert RatingRefresh.notice(off) == nil
      assert %{changed: 1} = RatingRefresh.dry_run(off)
    end
  end

  defp row(ext_id, name, rating) do
    %{
      ext_id: ext_id,
      name: name,
      rating: rating,
      federation: "",
      title: "",
      birth_year: nil,
      fide_id: nil
    }
  end
end
