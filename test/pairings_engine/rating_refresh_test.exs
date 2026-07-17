defmodule PairingsEngine.RatingRefreshTest do
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{RatingRefresh, Tournaments}
  alias PairingsEngine.Fide.FidePlayer
  alias PairingsEngine.Kbsb.KbsbPlayer
  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.AccountsFixtures

  setup do
    user = AccountsFixtures.user_fixture()
    scope = Scope.for_user(user)
    {:ok, tournament} = Tournaments.create_tournament(scope, %{"name" => "RR Test", "type" => "swiss"})
    %{tournament: tournament}
  end

  describe "dry_run/1" do
    test "no players: zero-everything summary", %{tournament: tournament} do
      assert RatingRefresh.dry_run(tournament) == %{
               proposals: [],
               checked: 0,
               changed: 0,
               unmatched: 0
             }
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

    test "proposes a national_rating change from the KBSB list", %{tournament: tournament} do
      {:ok, _player} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Carla",
          "national_id" => "12345",
          "national_rating" => "1600"
        })

      Repo.insert!(%KbsbPlayer{national_id: "12345", last_name: "Carla", national_rating: 1750})

      assert [%RatingRefresh{field: :national_rating, old: 1600, new: 1750}] =
               RatingRefresh.dry_run(tournament).proposals
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
      Repo.insert!(%KbsbPlayer{national_id: "99999", last_name: "Eve", national_rating: 1720})

      %{proposals: proposals} = RatingRefresh.dry_run(tournament)
      assert length(proposals) == 3

      # All three proposals belong to the same player (Eve), so `apply/2`
      # groups them into a single update.
      assert {:ok, [_]} = RatingRefresh.apply(tournament, proposals)

      updated = Tournaments.get_player!(player.tournament_id, player.id)
      assert updated.fide_rating == 1900
      assert updated.title == "WIM"
      assert updated.national_rating == 1720
    end

    test "empty proposal list is a no-op", %{tournament: tournament} do
      assert RatingRefresh.apply(tournament, []) == {:ok, []}
    end
  end
end
