defmodule PairingsEngine.RatingRefreshTest do
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Fide, Meta, RatingRefresh, Tournaments}
  alias PairingsEngine.Fide.FidePlayer
  alias PairingsEngine.Tournaments.Player
  alias PairingsEngine.Federations.BEL.Member
  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.AccountsFixtures

  setup do
    user = AccountsFixtures.user_fixture()
    scope = Scope.for_user(user)

    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "RR Test", "type" => "swiss"})

    # The local list is the current month's, as after a sync.
    Meta.put("fide_list_period", Fide.month_of(Date.utc_today()))

    %{tournament: tournament}
  end

  describe "dry_run/1" do
    test "no players: zero-everything summary", %{tournament: tournament} do
      assert %{proposals: [], checked: 0, changed: 0, unmatched: 0, list_status: :ok} =
               RatingRefresh.dry_run(tournament)
    end

    test "proposes a fide_rating change and counts it, leaves unchanged fields alone", %{
      tournament: tournament
    } do
      {:ok, player} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Alice",
          "fide_id" => "555555",
          "fide_rating" => "1900"
        })

      Repo.insert!(%FidePlayer{
        fide_id: 555_555,
        name: "Alice",
        standard_rating: 2100,
        title: ""
      })

      summary = RatingRefresh.dry_run(tournament)

      assert summary.checked == 1
      assert summary.changed == 1
      assert summary.unmatched == 0

      assert [%RatingRefresh{player: %{id: id}, field: :fide_rating, old: 1900, new: 2100}] =
               summary.proposals

      assert id == player.id
    end

    test "a rapid tournament proposes the FIDE record's rapid rating, not standard", %{
      tournament: standard_tournament
    } do
      {:ok, tournament} = Tournaments.update_tournament(standard_tournament, %{standard: "rapid"})

      {:ok, player} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Frank",
          "fide_id" => "77",
          "fide_rating" => "1500"
        })

      Repo.insert!(%FidePlayer{
        fide_id: 77,
        name: "Frank",
        standard_rating: 2000,
        rapid_rating: 1950,
        blitz_rating: 1900,
        title: ""
      })

      assert [%RatingRefresh{player: %{id: id}, field: :fide_rating, old: 1500, new: 1950}] =
               RatingRefresh.dry_run(tournament).proposals

      assert id == player.id
    end

    test "a blitz tournament falls back to standard_rating when the player has no blitz rating yet",
         %{tournament: standard_tournament} do
      {:ok, tournament} = Tournaments.update_tournament(standard_tournament, %{standard: "blitz"})

      {:ok, _player} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Grace",
          "fide_id" => "88",
          "fide_rating" => "1500"
        })

      Repo.insert!(%FidePlayer{
        fide_id: 88,
        name: "Grace",
        standard_rating: 2000,
        rapid_rating: 1950,
        blitz_rating: nil,
        title: ""
      })

      assert [%RatingRefresh{field: :fide_rating, old: 1500, new: 2000}] =
               RatingRefresh.dry_run(tournament).proposals
    end

    test "proposes a title only when the FIDE record actually has one", %{tournament: tournament} do
      {:ok, _player} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Bob",
          "fide_id" => "42",
          "fide_rating" => "1800",
          "title" => "FM"
        })

      # FIDE row matches on rating (no change) and carries no title.
      Repo.insert!(%FidePlayer{fide_id: 42, name: "Bob", standard_rating: 1800, title: ""})

      assert RatingRefresh.dry_run(tournament).proposals == []

      Repo.update_all(FidePlayer, set: [title: "IM"])

      assert [%RatingRefresh{field: :title, old: "FM", new: "IM"}] =
               RatingRefresh.dry_run(tournament).proposals
    end

    # `national_rating` is an import/manual-entry artifact, not something
    # OpenPairings keeps in sync - a bulk button rewriting it made it look
    # like there is a live national-rating system here. Clubs, the part of
    # the KBSB list that IS worth refreshing, moved to `ClubRefresh`.
    test "never proposes a national_rating change, even when KBSB disagrees", %{
      tournament: tournament
    } do
      {:ok, _player} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Carla",
          "national_id" => "12345",
          "national_rating" => "1600"
        })

      Repo.insert!(%Member{national_id: "12345", last_name: "Carla", national_rating: 1750})

      assert %{proposals: [], changed: 0} = RatingRefresh.dry_run(tournament)
    end

    # A national id is no longer a match of any kind here, so a player
    # carrying only one is "unmatched" - the summary counts FIDE matches.
    test "a player with only a national id counts as unmatched", %{tournament: tournament} do
      {:ok, _player} =
        Tournaments.create_player(tournament.id, %{"name" => "Carla", "national_id" => "12345"})

      Repo.insert!(%Member{national_id: "12345", last_name: "Carla", national_rating: 1750})

      assert %{unmatched: 1, checked: 1} = RatingRefresh.dry_run(tournament)
    end

    test "a player with no matching id (or no id at all) counts as unmatched, no proposals", %{
      tournament: tournament
    } do
      {:ok, _no_id} = Tournaments.create_player(tournament.id, %{"name" => "NoIds"})

      {:ok, _wrong_id} =
        Tournaments.create_player(tournament.id, %{"name" => "Ghost", "fide_id" => "999999"})

      summary = RatingRefresh.dry_run(tournament)
      assert summary.checked == 2
      assert summary.changed == 0
      assert summary.unmatched == 2
      assert summary.proposals == []
    end

    test "a matched player with no differing fields is not counted as a change", %{
      tournament: tournament
    } do
      {:ok, _player} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Dara",
          "fide_id" => "7",
          "fide_rating" => "2000"
        })

      Repo.insert!(%FidePlayer{fide_id: 7, name: "Dara", standard_rating: 2000, title: ""})

      summary = RatingRefresh.dry_run(tournament)
      assert summary.changed == 0
      assert summary.unmatched == 0
      assert summary.proposals == []
    end
  end

  describe "apply/2" do
    test "writes all proposed changes in one transaction", %{tournament: tournament} do
      {:ok, player} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Eve",
          "fide_id" => "9",
          "fide_rating" => "1700",
          "national_id" => "99999",
          "national_rating" => "1650"
        })

      Repo.insert!(%FidePlayer{fide_id: 9, name: "Eve", standard_rating: 1900, title: "WIM"})
      Repo.insert!(%Member{national_id: "99999", last_name: "Eve", national_rating: 1720})

      %{proposals: proposals} = RatingRefresh.dry_run(tournament)
      assert length(proposals) == 2

      # Both proposals belong to the same player (Eve), so `apply/2` groups
      # them into a single update.
      assert {:ok, [_]} = RatingRefresh.apply(tournament, proposals)

      updated = Tournaments.get_player!(player.tournament_id, player.id)
      assert updated.fide_rating == 1900
      assert updated.title == "WIM"

      # Untouched, despite the KBSB row saying 1720.
      assert updated.national_rating == 1650
    end

    test "empty proposal list is a no-op", %{tournament: tournament} do
      assert RatingRefresh.apply(tournament, []) == {:ok, []}
    end
  end

  describe "which list the check uses (VCL4THP 137)" do
    test "the start date picks the month; an event of more than 30 days uses the check date" do
      today = ~D[2026-11-20]
      t = %{start_date: "2026-09-12", end_date: "2026-09-14"}

      assert RatingRefresh.reference_date(t, today) == ~D[2026-09-12]

      long = %{start_date: "2026-09-12", end_date: "2026-11-15"}
      assert RatingRefresh.reference_date(long, today) == today

      assert RatingRefresh.reference_date(%{start_date: "", end_date: ""}, today) == today

      future = %{start_date: "2027-01-02", end_date: "2027-01-03"}
      assert RatingRefresh.reference_date(future, today) == today
    end

    test "the list of the tournament's own month is compared", %{tournament: tournament} do
      Meta.put("fide_list_period", "2026-09")
      t = %{tournament | start_date: "2026-09-12", end_date: "2026-09-14"}

      assert %{list_status: :ok, required_period: "2026-09", local_period: "2026-09"} =
               RatingRefresh.dry_run(t, ~D[2026-09-20])
    end

    test "a later list than the tournament's proposes nothing", %{tournament: tournament} do
      {:ok, _} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Alice",
          "fide_id" => "555555",
          "fide_rating" => "1900"
        })

      Repo.insert!(%FidePlayer{fide_id: 555_555, name: "Alice", standard_rating: 2100})

      Meta.put("fide_list_period", "2026-11")
      t = %{tournament | start_date: "2026-09-12", end_date: "2026-09-14"}

      summary = RatingRefresh.dry_run(t, ~D[2026-11-20])
      assert summary.list_status == :local_newer
      assert summary.proposals == []
      assert summary.checked == 1
    end

    test "an older list than the tournament's is reported so it can be updated first", %{
      tournament: tournament
    } do
      Meta.put("fide_list_period", "2026-08")
      t = %{tournament | start_date: "2026-09-12", end_date: "2026-09-14"}

      assert %{list_status: :local_older, proposals: []} =
               RatingRefresh.dry_run(t, ~D[2026-09-20])
    end

    test "no list at all", %{tournament: tournament} do
      Meta.delete("fide_list_period")
      assert %{list_status: :no_list, proposals: []} = RatingRefresh.dry_run(tournament)
    end
  end

  describe "source of an applied rating (VCL4THP 134)" do
    test "applying a rating records its list, month and printed value", %{tournament: tournament} do
      {:ok, player} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Alice",
          "fide_id" => "555555",
          "fide_rating" => "1900"
        })

      Repo.insert!(%FidePlayer{fide_id: 555_555, name: "Alice", standard_rating: 2100})

      assert {:ok, _} =
               RatingRefresh.apply(tournament, RatingRefresh.dry_run(tournament).proposals)

      updated = Tournaments.get_player!(player.tournament_id, player.id)
      assert updated.fide_rating == 2100
      assert updated.fide_rating_source == "standard"
      assert updated.fide_rating_period == Fide.month_of(Date.utc_today())
      assert updated.fide_rating_listed == 2100
      refute Player.rating_manual?(updated)
    end

    test "a rapid tournament that falls back to the Standard rating says Standard", %{
      tournament: standard_tournament
    } do
      {:ok, tournament} = Tournaments.update_tournament(standard_tournament, %{standard: "rapid"})

      {:ok, player} =
        Tournaments.create_player(tournament.id, %{"name" => "Frank", "fide_id" => "77"})

      Repo.insert!(%FidePlayer{fide_id: 77, name: "Frank", standard_rating: 2000})
      {:ok, _} = RatingRefresh.apply(tournament, RatingRefresh.dry_run(tournament).proposals)

      assert Tournaments.get_player!(player.tournament_id, player.id).fide_rating_source ==
               "standard"
    end

    test "a later hand edit keeps the source and marks the rating as modified", %{
      tournament: tournament
    } do
      {:ok, player} =
        Tournaments.create_player(tournament.id, %{"name" => "Alice", "fide_id" => "555555"})

      Repo.insert!(%FidePlayer{fide_id: 555_555, name: "Alice", standard_rating: 2100})
      {:ok, _} = RatingRefresh.apply(tournament, RatingRefresh.dry_run(tournament).proposals)

      {:ok, edited} =
        Tournaments.update_player(
          Tournaments.get_player!(player.tournament_id, player.id),
          %{"fide_rating" => "2150"}
        )

      assert edited.fide_rating == 2150
      assert edited.fide_rating_source == "standard"
      assert edited.fide_rating_listed == 2100
      assert Player.rating_manual?(edited)
    end

    test "a rating typed by hand has no source, and that absence is what marks it", %{
      tournament: tournament
    } do
      {:ok, player} =
        Tournaments.create_player(tournament.id, %{"name" => "Bob", "fide_rating" => "1500"})

      assert player.fide_rating_source == nil
      assert Player.rating_manual?(player)

      {:ok, unrated} = Tournaments.create_player(tournament.id, %{"name" => "Cy"})
      refute Player.rating_manual?(unrated)
    end

    test "a source that is not one of the three lists is dropped", %{tournament: tournament} do
      {:ok, player} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Dee",
          "fide_rating" => "1500",
          "fide_rating_source" => "made-up",
          "fide_rating_period" => "last week"
        })

      assert player.fide_rating_source == nil
      assert player.fide_rating_period == nil
    end
  end

  describe "choosing which proposals to apply (VCL4THP 144)" do
    test "only the selected proposals are written", %{tournament: tournament} do
      {:ok, alice} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Alice",
          "fide_id" => "1",
          "fide_rating" => "1000"
        })

      {:ok, bob} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Bob",
          "fide_id" => "2",
          "fide_rating" => "1000"
        })

      Repo.insert!(%FidePlayer{fide_id: 1, name: "Alice", standard_rating: 1100})
      Repo.insert!(%FidePlayer{fide_id: 2, name: "Bob", standard_rating: 1200})

      summary = RatingRefresh.dry_run(tournament)
      assert length(summary.proposals) == 2

      chosen = RatingRefresh.select(summary, ["#{bob.id}:fide_rating"])
      assert [%RatingRefresh{new: 1200}] = chosen
      assert {:ok, [_]} = RatingRefresh.apply(tournament, chosen)

      assert Tournaments.get_player!(alice.tournament_id, alice.id).fide_rating == 1000
      assert Tournaments.get_player!(bob.tournament_id, bob.id).fide_rating == 1200
      assert RatingRefresh.select(summary, []) == []
    end
  end

  describe "notice/1 (VCL4THP 140)" do
    test "says so when a player's rating differs from the list in use", %{tournament: tournament} do
      {:ok, _} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Alice",
          "fide_id" => "555555",
          "fide_rating" => "1900"
        })

      Repo.insert!(%FidePlayer{fide_id: 555_555, name: "Alice", standard_rating: 2100})

      assert %{changed: 1} = RatingRefresh.notice(tournament)
    end

    test "is silent when nothing differs, when there is no list, or when it is not comparable",
         %{tournament: tournament} do
      assert RatingRefresh.notice(tournament) == nil

      {:ok, _} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Alice",
          "fide_id" => "555555",
          "fide_rating" => "2100"
        })

      Repo.insert!(%FidePlayer{fide_id: 555_555, name: "Alice", standard_rating: 2100})
      assert RatingRefresh.notice(tournament) == nil

      Meta.delete("fide_list_period")
      assert RatingRefresh.notice(tournament) == nil
    end
  end
end
