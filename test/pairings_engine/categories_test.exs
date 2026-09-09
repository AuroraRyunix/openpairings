defmodule PairingsEngine.CategoriesTest do
  @moduledoc """
  Several categories per player, and the single one of them that decides
  pairing.

  The migration half of this is the part that had to be right first: this app
  is deployed and arbiters run events on it while it upgrades, so a round
  paired after the upgrade has to be the round that would have been paired
  before it. That is asserted here twice - once against the migration's own
  SQL, and once against the pairing rule as it stood before 0.53.0.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Categories, Pairing, PlayerStats, Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Tournament}

  defp tournament(attrs) do
    Repo.insert!(
      struct(
        %Tournament{
          name: "Cats",
          type: "swiss",
          rounds_count: 3,
          categories_enabled: true,
          categories: ["-1100", "-1800", "Women"]
        },
        attrs
      )
    )
  end

  # Deliberately a raw struct insert, not `create_player/2`: these tests are
  # about rows in whatever state they are actually in, including the
  # pre-migration state the changeset would repair.
  defp player(t, attrs) do
    Repo.insert!(struct(%Player{tournament_id: t.id, name: "P"}, attrs))
  end

  describe "pairing_category/2" do
    test "the override wins while the player still carries it and the tournament still lists it" do
      t = tournament(%{})
      p = player(t, %{category: "Women", categories: ["-1800", "Women"]})

      assert Categories.pairing_category(t, p) == "Women"
    end

    test "an override the player no longer carries self-heals into the derived answer" do
      t = tournament(%{})
      p = player(t, %{category: "Women", categories: ["-1800"]})

      assert Categories.pairing_category(t, p) == "-1800"
    end

    test "an override the tournament no longer lists self-heals too" do
      t = tournament(%{categories: ["-1800"]})
      p = player(t, %{category: "Women", categories: ["-1800", "Women"]})

      assert Categories.pairing_category(t, p) == "-1800"
    end

    test "with no override it is the FIRST of the player's categories in the tournament's order" do
      t = tournament(%{})

      # Stored in the other order on purpose: the answer is the tournament's
      # order, never the order the row happens to hold.
      p = player(t, %{categories: ["Women", "-1100"]})

      assert Categories.pairing_category(t, p) == "-1100"
    end

    test "a player carrying nothing the tournament lists is Uncategorized" do
      t = tournament(%{})

      assert Categories.pairing_category(t, player(t, %{})) == ""
      assert Categories.pairing_category(t, player(t, %{categories: ["Veterans"]})) == ""
    end

    test "the answer is always \"\" or one of the tournament's own categories" do
      t = tournament(%{})

      rows = [
        %{category: "Women", categories: ["Women"]},
        %{category: "Ghost", categories: ["Ghost"]},
        %{category: "", categories: ["Women", "-1100"]},
        %{category: "Women", categories: []},
        %{category: "", categories: []}
      ]

      for attrs <- rows do
        pool = Categories.pairing_category(t, player(t, attrs))

        assert pool == "" or pool in t.categories,
               "#{inspect(attrs)} produced #{inspect(pool)}, which is not a pool"
      end
    end
  end

  describe "the migration is lossless" do
    # The migration's own UPDATE, character for character. Running the real
    # statement rather than a paraphrase is the point: `json_array()` is
    # there so a category name containing a quote cannot produce invalid
    # JSON, and only the real SQL can show that it does.
    @backfill """
    UPDATE players
       SET categories = json_array(category)
     WHERE category IS NOT NULL AND category <> ''
    """

    test "every row with a category comes out holding exactly that one, quotes and all" do
      t = tournament(%{categories: ["-1100", ~s(He said "hi"), "O'Brien"]})

      rows =
        for c <- ["-1100", ~s(He said "hi"), "O'Brien", "Ghost", ""] do
          {c, player(t, %{category: c, categories: []})}
        end

      Repo.query!(@backfill)

      for {c, p} <- rows do
        reloaded = Repo.get!(Player, p.id)

        assert reloaded.category == c, "the migration must never rewrite `category`"

        assert reloaded.categories == if(c == "", do: [], else: [c]),
               "backfill of #{inspect(c)} produced #{inspect(reloaded.categories)}"
      end
    end

    test "a migrated row pools exactly where the pre-0.53.0 rule pooled it" do
      t = tournament(%{})

      # All three cases the old `category_groups/2` distinguished: a listed
      # category, a category the tournament does not list, and none at all.
      for c <- ["-1100", "Women", "Ghost", ""] do
        p = player(t, %{category: c, categories: []})
        Repo.query!(@backfill)
        p = Repo.get!(Player, p.id)

        assert Categories.pairing_category(t, p) == legacy_pool(t, p),
               "#{inspect(c)} changed pool across the migration"
      end
    end

    # `Pairing.category_groups/2` as it stood before 0.53.0, kept here so the
    # equivalence is asserted against the old rule rather than against a
    # description of it: a named group was `player.category == name`, and
    # everything else - blank, nil, or a name the tournament does not list -
    # fell into the Uncategorized pool.
    defp legacy_pool(tournament, %Player{} = player) do
      named = tournament.categories || []

      if player.category in [nil, ""] or player.category not in named,
        do: "",
        else: player.category
    end

    test "a pair_by_category round is paired identically before and after the backfill" do
      t =
        tournament(%{
          categories: ["A", "B"],
          pair_by_category: true,
          name: "Migration"
        })

      # Pre-migration rows: `category` set, `categories` empty. Pairing them
      # in this state is what the previous release did.
      for {name, rating, cat} <- [
            {"A1", 2000, "A"},
            {"A2", 1900, "A"},
            {"A3", 1800, "A"},
            {"A4", 1700, "A"},
            {"B1", 1600, "B"},
            {"B2", 1500, "B"},
            {"B3", 1400, "B"},
            {"B4", 1300, "B"}
          ] do
        player(t, %{name: name, fide_rating: rating, category: cat, categories: [cat]})
      end

      assert {:ok, round} = Pairing.pair_next_round(t)
      before = boards_by_name(round)

      # Two categories of four, so two boards each. Asserted so the
      # comparison below cannot pass by both sides being empty.
      assert length(before) == 4

      # Same tournament, same players, wound back to an unpaired state - the
      # roster is what the backfill acts on, and the comparison is what the
      # engine does with it.
      Repo.delete_all(
        from p in PairingsEngine.Tournaments.Pairing, where: p.round_id == ^round.id
      )

      Repo.delete_all(from r in PairingsEngine.Tournaments.Round, where: r.id == ^round.id)

      Repo.update_all(from(p in Player, where: p.tournament_id == ^t.id), set: [categories: []])
      Repo.query!(@backfill)

      assert {:ok, round2} = Pairing.pair_next_round(t)
      assert boards_by_name(round2) == before
    end

    defp boards_by_name(round) do
      round = Repo.preload(round, :pairings)
      names = Map.new(Repo.all(Player), &{&1.id, &1.name})

      round.pairings
      |> Enum.sort_by(& &1.board)
      |> Enum.map(fn p ->
        {p.board, Map.get(names, p.white_player_id), Map.get(names, p.black_player_id)}
      end)
    end
  end

  describe "listed_categories/2 and order/2" do
    test "listed_categories orders by the tournament's list and drops what it does not list" do
      t = tournament(%{})
      p = player(t, %{categories: ["Ghost", "Women", "-1100"]})

      assert Categories.listed_categories(t, p) == ["-1100", "Women"]
    end

    test "order/2 keeps unlisted names, after the listed ones, and de-duplicates" do
      t = tournament(%{})

      assert Categories.order(t, ["Women", "Ghost", "-1100", "Women"]) ==
               ["-1100", "Women", "Ghost"]
    end
  end

  describe "Player.changeset/2 keeps the set a set" do
    test "blanks are dropped, names trimmed, duplicates collapsed" do
      t = tournament(%{})

      {:ok, p} =
        Tournaments.create_player(t.id, %{
          "name" => "Set",
          "categories" => ["Women", "", "  Women  ", "-1100"]
        })

      assert p.categories == ["Women", "-1100"]
    end

    test "a writer that sets `category` alone folds it into the set" do
      t = tournament(%{})

      # This is an old JSON backup, a `.swar` file, or any caller written
      # before the field existed. Without the fold, the pairing category
      # would derive to "" and the player would silently change pool.
      {:ok, p} = Tournaments.create_player(t.id, %{"name" => "Old", "category" => "Women"})

      assert p.categories == ["Women"]
      assert Categories.pairing_category(t, p) == "Women"
    end

    test "a writer that sets both is obeyed in both directions" do
      t = tournament(%{})

      {:ok, p} =
        Tournaments.create_player(t.id, %{
          "name" => "Both",
          "category" => "Women",
          "categories" => ["-1100"]
        })

      # Not folded in: the arbiter said which categories the player is in,
      # and re-adding the one they just removed would be fighting them. The
      # now-stale override simply stops applying.
      assert p.categories == ["-1100"]
      assert Categories.pairing_category(t, p) == "-1100"
    end
  end

  describe "PlayerStats.assign_categories/4" do
    @rules %{
      "-1100" => %{"kind" => "elo_below", "value" => 1100},
      "U16" => %{"kind" => "age_below", "value" => 16}
    }

    test "a player under an Elo ceiling AND an age ceiling gets both" do
      p = %Player{name: "Junior", fide_rating: 900, birth_year: 2015}

      assert PlayerStats.assign_categories(p, ["-1100", "U16"], @rules, 2026) == ["-1100", "U16"]
    end

    test "the categories come back in the tournament's order, not the rules' map order" do
      p = %Player{name: "Junior", fide_rating: 900, birth_year: 2015}

      assert PlayerStats.assign_categories(p, ["U16", "-1100"], @rules, 2026) == ["U16", "-1100"]
    end

    test "assign_category/4 is still the head of that list" do
      p = %Player{name: "Junior", fide_rating: 900, birth_year: 2015}

      assert PlayerStats.assign_category(p, ["U16", "-1100"], @rules, 2026) == "U16"
      assert PlayerStats.assign_category(p, ["-1100", "U16"], @rules, 2026) == "-1100"
    end

    test "a category with no rule is never assigned" do
      p = %Player{name: "Junior", fide_rating: 900, birth_year: 2015}

      assert PlayerStats.assign_categories(p, ["-1100", "U16", "Women"], @rules, 2026) ==
               ["-1100", "U16"]
    end
  end

  describe "auto_assign_categories/1 replaces ruled categories and leaves hand-set ones" do
    defp ruled_tournament do
      Repo.insert!(%Tournament{
        name: "Ruled",
        type: "swiss",
        rounds_count: 3,
        categories_enabled: true,
        categories: ["-1100", "-1800", "Women"],
        category_rules: %{
          "-1100" => %{"kind" => "elo_below", "value" => 1100},
          "-1800" => %{"kind" => "elo_below", "value" => 1800}
        }
      })
    end

    test "a hand-set category with no rule survives a re-run" do
      t = ruled_tournament()

      {:ok, p} =
        Tournaments.create_player(t.id, %{
          "name" => "Junior woman",
          "fide_rating" => 900,
          "categories" => ["Women"]
        })

      assert {:ok, %{matched: 1, total: 1}} = Tournaments.auto_assign_categories(t)

      # The rated bracket arrives, the club prize stays.
      assert Repo.get!(Player, p.id).categories == ["-1100", "Women"]
    end

    test "a ruled category the player no longer qualifies for is removed" do
      t = ruled_tournament()

      {:ok, p} =
        Tournaments.create_player(t.id, %{
          "name" => "Improved",
          "fide_rating" => 1500,
          "categories" => ["-1100", "Women"]
        })

      assert {:ok, _} = Tournaments.auto_assign_categories(t)
      assert Repo.get!(Player, p.id).categories == ["-1800", "Women"]
    end

    test "running it twice writes the same rows" do
      t = ruled_tournament()

      {:ok, p} =
        Tournaments.create_player(t.id, %{
          "name" => "Stable",
          "fide_rating" => 900,
          "categories" => ["Women"]
        })

      assert {:ok, _} = Tournaments.auto_assign_categories(t)
      first = Repo.get!(Player, p.id)

      assert {:ok, _} = Tournaments.auto_assign_categories(t)
      second = Repo.get!(Player, p.id)

      assert first.categories == second.categories
      assert first.category == second.category
    end

    test "the pairing-pool override still follows the rules" do
      t = ruled_tournament()

      {:ok, p} =
        Tournaments.create_player(t.id, %{"name" => "Low", "fide_rating" => 900})

      assert {:ok, _} = Tournaments.auto_assign_categories(t)
      assert Repo.get!(Player, p.id).category == "-1100"

      {:ok, _} = Tournaments.update_player(Repo.get!(Player, p.id), %{"fide_rating" => 2400})
      assert {:ok, _} = Tournaments.auto_assign_categories(t)
      assert Repo.get!(Player, p.id).category == ""
    end
  end

  describe "toggle_player_category/4 and set_all_players_category/3" do
    test "a toggle touches one name and leaves the rest of the set alone" do
      t = tournament(%{})

      {:ok, p} =
        Tournaments.create_player(t.id, %{"name" => "Multi", "categories" => ["-1100", "Women"]})

      {:ok, p} = Tournaments.toggle_player_category(t, p, "-1800", true)
      assert p.categories == ["-1100", "-1800", "Women"]

      {:ok, p} = Tournaments.toggle_player_category(t, p, "-1100", false)
      assert p.categories == ["-1800", "Women"]
    end

    test "a name the tournament does not define is refused rather than minted" do
      t = tournament(%{})
      {:ok, p} = Tournaments.create_player(t.id, %{"name" => "Multi"})

      assert {:error, :unknown_category} = Tournaments.toggle_player_category(t, p, "Ghost", true)
      assert {:error, :unknown_category} = Tournaments.set_all_players_category(t, "Ghost", true)
      assert Repo.get!(Player, p.id).categories == []
    end

    test "the bulk version applies to everyone in one go" do
      t = tournament(%{})
      {:ok, a} = Tournaments.create_player(t.id, %{"name" => "A", "categories" => ["-1100"]})
      {:ok, b} = Tournaments.create_player(t.id, %{"name" => "B"})

      assert {:ok, _} = Tournaments.set_all_players_category(t, "Women", true)
      assert Repo.get!(Player, a.id).categories == ["-1100", "Women"]
      assert Repo.get!(Player, b.id).categories == ["Women"]

      assert {:ok, _} = Tournaments.set_all_players_category(t, "Women", false)
      assert Repo.get!(Player, a.id).categories == ["-1100"]
      assert Repo.get!(Player, b.id).categories == []
    end

    test "removing the category the override names leaves the override alone, and it self-heals" do
      t = tournament(%{})

      {:ok, p} =
        Tournaments.create_player(t.id, %{
          "name" => "Override",
          "category" => "Women",
          "categories" => ["-1100", "Women"]
        })

      {:ok, p} = Tournaments.toggle_player_category(t, p, "Women", false)

      assert p.category == "Women", "the override is kept so re-adding restores the placement"
      assert Categories.pairing_category(t, p) == "-1100"

      {:ok, p} = Tournaments.toggle_player_category(t, p, "Women", true)
      assert Categories.pairing_category(t, p) == "Women"
    end
  end
end
