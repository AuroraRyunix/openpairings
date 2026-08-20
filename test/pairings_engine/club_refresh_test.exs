defmodule PairingsEngine.ClubRefreshTest do
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{ClubRefresh, Tournaments}
  alias PairingsEngine.Kbsb.KbsbPlayer
  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.AccountsFixtures

  setup do
    user = AccountsFixtures.user_fixture()
    scope = Scope.for_user(user)

    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "CR Test", "type" => "swiss"})

    %{tournament: tournament}
  end

  describe "dry_run/1" do
    test "no players: zero-everything summary", %{tournament: tournament} do
      assert ClubRefresh.dry_run(tournament) == %{
               proposals: [],
               checked: 0,
               changed: 0,
               unmatched: 0
             }
    end

    test "proposes name and number together when the club has changed", %{tournament: tournament} do
      {:ok, _p} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Mover",
          "national_id" => "12345",
          "club" => "Old Club",
          "club_number" => 111
        })

      Repo.insert!(%KbsbPlayer{
        national_id: "12345",
        last_name: "Mover",
        club_name: "New Club",
        club_number: 401
      })

      summary = ClubRefresh.dry_run(tournament)

      assert %{checked: 1, changed: 1, unmatched: 0} = summary

      assert [
               %ClubRefresh{field: :club, old: "Old Club", new: "New Club"},
               %ClubRefresh{field: :club_number, old: 111, new: 401}
             ] = summary.proposals
    end

    test "a player already on the right club produces no proposals", %{tournament: tournament} do
      {:ok, _p} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Settled",
          "national_id" => "22222",
          "club" => "Same Club",
          "club_number" => 401
        })

      Repo.insert!(%KbsbPlayer{
        national_id: "22222",
        last_name: "Settled",
        club_name: "Same Club",
        club_number: 401
      })

      assert %{proposals: [], checked: 1, changed: 0, unmatched: 0} =
               ClubRefresh.dry_run(tournament)
    end

    # The reason the feature can be run without fear: it adds and corrects,
    # it never deletes. An arbiter who typed a club for an unaffiliated
    # guest keeps it.
    test "never proposes clearing a club the KBSB row has no entry for", %{
      tournament: tournament
    } do
      {:ok, _p} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Guest",
          "national_id" => "33333",
          "club" => "Typed By Hand"
        })

      Repo.insert!(%KbsbPlayer{national_id: "33333", last_name: "Guest", club_name: ""})

      assert %{proposals: [], changed: 0, unmatched: 0} = ClubRefresh.dry_run(tournament)
    end

    # The case the KBSB data platform's REST API cannot serve at all: it has
    # no by-FIDE-id club route, and its FIDE table carries no club.
    test "falls back to FIDE id when the player has no matricule", %{tournament: tournament} do
      {:ok, _p} =
        Tournaments.create_player(tournament.id, %{"name" => "FideOnly", "fide_id" => 255_424})

      Repo.insert!(%KbsbPlayer{
        national_id: "44444",
        last_name: "FideOnly",
        fide_id: 255_424,
        club_name: "Found By Fide",
        club_number: 401
      })

      summary = ClubRefresh.dry_run(tournament)

      assert %{changed: 1, unmatched: 0} = summary
      assert Enum.any?(summary.proposals, &(&1.field == :club and &1.new == "Found By Fide"))
    end

    test "national id wins over FIDE id when both are set and both match", %{
      tournament: tournament
    } do
      {:ok, _p} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Both",
          "national_id" => "55555",
          "fide_id" => 999_111
        })

      Repo.insert!(%KbsbPlayer{
        national_id: "55555",
        last_name: "Both",
        club_name: "By National",
        club_number: 1
      })

      Repo.insert!(%KbsbPlayer{
        national_id: "66666",
        last_name: "Other",
        fide_id: 999_111,
        club_name: "By Fide",
        club_number: 2
      })

      summary = ClubRefresh.dry_run(tournament)
      assert Enum.any?(summary.proposals, &(&1.field == :club and &1.new == "By National"))
      refute Enum.any?(summary.proposals, &(&1.new == "By Fide"))
    end

    test "a player with no id, or an id not on the list, counts as unmatched", %{
      tournament: tournament
    } do
      {:ok, _} = Tournaments.create_player(tournament.id, %{"name" => "NoIds"})

      {:ok, _} =
        Tournaments.create_player(tournament.id, %{"name" => "Unknown", "national_id" => "77777"})

      assert %{proposals: [], checked: 2, changed: 0, unmatched: 2} =
               ClubRefresh.dry_run(tournament)
    end
  end

  describe "apply/2" do
    test "writes both fields and leaves everything else alone", %{tournament: tournament} do
      {:ok, player} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Mover",
          "national_id" => "12345",
          "club" => "Old Club",
          "club_number" => 111,
          "fide_rating" => 2000
        })

      Repo.insert!(%KbsbPlayer{
        national_id: "12345",
        last_name: "Mover",
        club_name: "New Club",
        club_number: 401
      })

      summary = ClubRefresh.dry_run(tournament)
      assert {:ok, _} = ClubRefresh.apply(tournament, summary.proposals)

      reloaded = Tournaments.get_player!(tournament.id, player.id)
      assert reloaded.club == "New Club"
      assert reloaded.club_number == 401
      assert reloaded.fide_rating == 2000, "a club refresh must not touch ratings"
    end

    test "applying an empty proposal list is a no-op, not an error", %{tournament: tournament} do
      assert {:ok, _} = ClubRefresh.apply(tournament, [])
    end
  end
end
