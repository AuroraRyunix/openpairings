defmodule PairingsEngine.Federations.BEL.PlayerDataRefreshTest do
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.Tournaments
  alias PairingsEngine.Federations.BEL.PlayerDataRefresh
  alias PairingsEngine.Federations.BEL.Member
  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.AccountsFixtures

  setup do
    user = AccountsFixtures.user_fixture()
    scope = Scope.for_user(user)

    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "CR Test", "type" => "swiss"})

    %{tournament: tournament}
  end

  # The club tests below predate the other fields; a name-matched player
  # now also gets the matricule filled in, which is not what they are about.
  defp club_only(proposals), do: Enum.filter(proposals, &(&1.field in [:club, :club_number]))

  describe "dry_run/1" do
    test "no players: zero-everything summary", %{tournament: tournament} do
      assert PlayerDataRefresh.dry_run(tournament) == %{
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

      Repo.insert!(%Member{
        national_id: "12345",
        last_name: "Mover",
        club_name: "New Club",
        club_number: 401
      })

      summary = PlayerDataRefresh.dry_run(tournament)

      assert %{checked: 1, changed: 1, unmatched: 0} = summary

      assert [
               %PlayerDataRefresh{field: :club, old: "Old Club", new: "New Club"},
               %PlayerDataRefresh{field: :club_number, old: 111, new: 401}
             ] = summary.proposals
    end

    test "a pasted row is saved without its tab, and its comma tidied", %{tournament: tournament} do
      {:ok, p} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Holovatyi ,Toma",
          "national_id" => "-66002\t",
          "club" => " ninklijke\t"
        })

      assert p.national_id == "-66002"
      assert p.name == "Holovatyi, Toma"
      assert p.club == "ninklijke"
    end

    test "a tab stored before the trim still finds its KBSB row", %{tournament: tournament} do
      {:ok, p} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Fisyuk, Semyon",
          "national_id" => "-14996",
          "club" => "ninklijke Waregemse",
          "club_number" => 465
        })

      Repo.update_all(
        from(x in PairingsEngine.Tournaments.Player, where: x.id == ^p.id),
        set: [national_id: "-14996\t"]
      )

      Repo.insert!(%Member{
        national_id: "-14996",
        last_name: "Fisyuk",
        club_name: "Koninklijke Waregemse",
        club_number: 313
      })

      assert %{changed: 1, unmatched: 0, proposals: proposals} =
               PlayerDataRefresh.dry_run(tournament)

      assert Enum.any?(proposals, &(&1.field == :club and &1.new == "Koninklijke Waregemse"))
    end

    test "a player already on the right club produces no proposals", %{tournament: tournament} do
      {:ok, _p} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Settled",
          "national_id" => "22222",
          "club" => "Same Club",
          "club_number" => 401
        })

      Repo.insert!(%Member{
        national_id: "22222",
        last_name: "Settled",
        club_name: "Same Club",
        club_number: 401
      })

      assert %{proposals: [], checked: 1, changed: 0, unmatched: 0} =
               PlayerDataRefresh.dry_run(tournament)
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

      Repo.insert!(%Member{national_id: "33333", last_name: "Guest", club_name: ""})

      assert %{proposals: [], changed: 0, unmatched: 0} = PlayerDataRefresh.dry_run(tournament)
    end

    # The case the KBSB data platform's REST API cannot serve at all: it has
    # no by-FIDE-id club route, and its FIDE table carries no club.
    test "falls back to FIDE id when the player has no matricule", %{tournament: tournament} do
      {:ok, _p} =
        Tournaments.create_player(tournament.id, %{"name" => "FideOnly", "fide_id" => 255_424})

      Repo.insert!(%Member{
        national_id: "44444",
        last_name: "FideOnly",
        fide_id: 255_424,
        club_name: "Found By Fide",
        club_number: 401
      })

      summary = PlayerDataRefresh.dry_run(tournament)

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

      Repo.insert!(%Member{
        national_id: "55555",
        last_name: "Both",
        club_name: "By National",
        club_number: 1
      })

      Repo.insert!(%Member{
        national_id: "66666",
        last_name: "Other",
        fide_id: 999_111,
        club_name: "By Fide",
        club_number: 2
      })

      summary = PlayerDataRefresh.dry_run(tournament)
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
               PlayerDataRefresh.dry_run(tournament)
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

      Repo.insert!(%Member{
        national_id: "12345",
        last_name: "Mover",
        club_name: "New Club",
        club_number: 401
      })

      summary = PlayerDataRefresh.dry_run(tournament)
      assert {:ok, _} = PlayerDataRefresh.apply(tournament, summary.proposals)

      reloaded = Tournaments.get_player!(tournament.id, player.id)
      assert reloaded.club == "New Club"
      assert reloaded.club_number == 401
      assert reloaded.fide_rating == 2000, "a club refresh must not touch ratings"
    end

    test "applying an empty proposal list is a no-op, not an error", %{tournament: tournament} do
      assert {:ok, _} = PlayerDataRefresh.apply(tournament, [])
    end
  end

  # The case both id lookups miss entirely, and the common one at a club
  # event: a player typed in at the desk with no matricule and no FIDE id.
  describe "matching by name and birth year" do
    defp typed_in(tournament, name, attrs \\ %{}) do
      {:ok, player} =
        Tournaments.create_player(tournament.id, Map.merge(%{"name" => name}, attrs))

      player
    end

    defp listed(attrs) do
      Repo.insert!(struct(%Member{national_id: "n#{System.unique_integer([:positive])}"}, attrs))
    end

    test "matches a player carrying no ids at all", %{tournament: tournament} do
      typed_in(tournament, "Janssens, Karel")

      listed(%{
        last_name: "Janssens",
        first_name: "Karel",
        club_name: "KSK Rochade",
        club_number: 401
      })

      assert %{proposals: proposals, changed: 1, unmatched: 0} =
               PlayerDataRefresh.dry_run(tournament)

      assert [%{field: :club, new: "KSK Rochade", via: :name}, %{field: :club_number, new: 401}] =
               club_only(proposals)
    end

    test "an accent typed off is still the same player", %{tournament: tournament} do
      typed_in(tournament, "Hendricks, Bjorn")

      listed(%{
        last_name: "Hendricks",
        first_name: "Björn",
        club_name: "Rokade",
        club_number: 812
      })

      assert [%{field: :club, new: "Rokade", via: :name} | _] =
               club_only(PlayerDataRefresh.dry_run(tournament).proposals)
    end

    test "refuses to choose between two namesakes with no birth year to separate them", %{
      tournament: tournament
    } do
      typed_in(tournament, "Peeters, Jan")
      listed(%{last_name: "Peeters", first_name: "Jan", club_name: "Club A", birth_year: 1970})
      listed(%{last_name: "Peeters", first_name: "Jan", club_name: "Club B", birth_year: 1995})

      assert %{proposals: [], changed: 0, unmatched: 1} = PlayerDataRefresh.dry_run(tournament)
    end

    test "a birth year picks the right namesake", %{tournament: tournament} do
      typed_in(tournament, "Peeters, Jan", %{"birth_year" => "1995"})
      listed(%{last_name: "Peeters", first_name: "Jan", club_name: "Club A", birth_year: 1970})
      listed(%{last_name: "Peeters", first_name: "Jan", club_name: "Club B", birth_year: 1995})

      assert [%{field: :club, new: "Club B", via: :name}] =
               club_only(PlayerDataRefresh.dry_run(tournament).proposals)
    end

    test "a lone namesake whose birth year disagrees is a different person", %{
      tournament: tournament
    } do
      typed_in(tournament, "Peeters, Jan", %{"birth_year" => "1995"})
      listed(%{last_name: "Peeters", first_name: "Jan", club_name: "Club A", birth_year: 1970})

      assert %{proposals: [], unmatched: 1} = PlayerDataRefresh.dry_run(tournament)
    end

    # The API mirror carries deceased members on purpose (filtering the
    # export would break its incremental mode). A name is the wrong key to
    # resolve onto one: the player at the board is the living namesake.
    test "a deceased namesake is not a name match", %{tournament: tournament} do
      typed_in(tournament, "Janssens, Karel")
      listed(%{last_name: "Janssens", first_name: "Karel", club_name: "Ghost FC", died: true})

      assert %{proposals: [], unmatched: 1} = PlayerDataRefresh.dry_run(tournament)
    end

    test "but an exact id still resolves a deceased member", %{tournament: tournament} do
      typed_in(tournament, "Janssens, Karel", %{"national_id" => "77777"})

      Repo.insert!(%Member{
        national_id: "77777",
        last_name: "Janssens",
        club_name: "Ghost FC",
        club_number: 9,
        died: true
      })

      assert [%{field: :club, new: "Ghost FC", via: :national_id} | _] =
               club_only(PlayerDataRefresh.dry_run(tournament).proposals)
    end

    test "an id still wins over the name, and is reported as such", %{tournament: tournament} do
      typed_in(tournament, "Janssens, Karel", %{"national_id" => "55555"})

      Repo.insert!(%Member{
        national_id: "55555",
        last_name: "Janssens",
        first_name: "Karel",
        club_name: "By Id",
        club_number: 1
      })

      listed(%{last_name: "Janssens", first_name: "Karel", club_name: "By Name", club_number: 2})

      assert [%{field: :club, new: "By Id", via: :national_id} | _] =
               PlayerDataRefresh.dry_run(tournament).proposals
    end
  end

  # Everything the button proposes beyond the club. Each source is local:
  # the KBSB rows are inserted as the sync would, the FIDE rows as the FIDE
  # sync would.
  describe "the other fields" do
    alias PairingsEngine.Fide.FidePlayer

    defp player(tournament, attrs) do
      {:ok, player} = Tournaments.create_player(tournament.id, attrs)
      player
    end

    defp fields(summary), do: Enum.map(summary.proposals, & &1.field)

    defp only(summary, field) do
      case Enum.filter(summary.proposals, &(&1.field == field)) do
        [one] -> one
        [] -> nil
      end
    end

    test "sex from the KBSB list, for a member with no FIDE record", %{tournament: t} do
      player(t, %{"name" => "Claes, Lien", "national_id" => "1001"})
      Repo.insert!(%Member{national_id: "1001", last_name: "Claes", first_name: "Lien", sex: "w"})

      assert %{field: :sex, old: "", new: "w", source: :kbsb, via: :national_id} =
               only(PlayerDataRefresh.dry_run(t), :sex)
    end

    test "title from the FIDE list", %{tournament: t} do
      player(t, %{"name" => "Titled, Tom", "fide_id" => 201_001})
      Repo.insert!(%FidePlayer{fide_id: 201_001, name: "Titled, Tom", title: "IM"})

      assert %{field: :title, old: "", new: "IM", source: :fide, via: :fide_id} =
               only(PlayerDataRefresh.dry_run(t), :title)
    end

    # The rule the moduledoc gives for sex, birth year and federation: the
    # rating report is checked against FIDE's record, so FIDE's answer wins.
    test "FIDE wins over KBSB on sex, birth year and federation", %{tournament: t} do
      player(t, %{"name" => "Both, Bo", "national_id" => "1002", "fide_id" => 201_002})

      Repo.insert!(%Member{
        national_id: "1002",
        last_name: "Both",
        first_name: "Bo",
        fide_id: 201_002,
        sex: "m",
        birth_year: 1980,
        federation: "V"
      })

      Repo.insert!(%FidePlayer{
        fide_id: 201_002,
        name: "Both, Bo",
        sex: "F",
        birth_year: 1981,
        federation: "NED"
      })

      summary = PlayerDataRefresh.dry_run(t)
      assert %{new: "w", source: :fide} = only(summary, :sex)
      assert %{new: 1981, source: :fide} = only(summary, :birth_year)
      assert %{new: "NED", source: :fide} = only(summary, :federation)
    end

    test "the KBSB wing letter is never offered as a federation", %{tournament: t} do
      player(t, %{"name" => "Wing, Wim", "national_id" => "1003"})

      Repo.insert!(%Member{
        national_id: "1003",
        last_name: "Wing",
        first_name: "Wim",
        federation: "V"
      })

      assert only(PlayerDataRefresh.dry_run(t), :federation) == nil
    end

    test "never proposes clearing what a list merely does not mention", %{tournament: t} do
      player(t, %{
        "name" => "Kept, Kim",
        "national_id" => "1004",
        "fide_id" => 201_004,
        "sex" => "m",
        "title" => "FM",
        "birth_year" => "1990",
        "federation" => "BEL",
        "club" => "Typed Club",
        "club_number" => 77
      })

      Repo.insert!(%Member{
        national_id: "1004",
        last_name: "Kept",
        first_name: "Kim",
        fide_id: 201_004,
        club_name: "",
        club_number: nil,
        sex: nil,
        birth_year: nil,
        affiliated: nil
      })

      Repo.insert!(%FidePlayer{fide_id: 201_004, name: "Kept, Kim", sex: "", title: ""})

      assert %{proposals: [], changed: 0, unmatched: 0} = PlayerDataRefresh.dry_run(t)
    end

    test "ratings are never proposed, whatever the lists say", %{tournament: t} do
      player(t, %{
        "name" => "Rated, Rik",
        "national_id" => "1005",
        "fide_id" => 201_005,
        "fide_rating" => 1500,
        "national_rating" => 1400
      })

      Repo.insert!(%Member{
        national_id: "1005",
        last_name: "Rated",
        first_name: "Rik",
        fide_id: 201_005,
        national_rating: 1900,
        sex: "m"
      })

      Repo.insert!(%FidePlayer{
        fide_id: 201_005,
        name: "Rated, Rik",
        standard_rating: 2100,
        rapid_rating: 2050,
        blitz_rating: 2000
      })

      summary = PlayerDataRefresh.dry_run(t)
      assert :sex in fields(summary)

      for rating <- [:fide_rating, :national_rating, :tournament_rating, :period_ratings] do
        refute rating in fields(summary)
      end
    end

    # One tick, both halves: selecting the club selects the number with it,
    # so the preview cannot write a name from one club and a number from
    # another.
    test "club name and number are selected and applied as one", %{tournament: t} do
      p =
        player(t, %{
          "name" => "Pair, Piet",
          "national_id" => "1006",
          "club" => "Old",
          "club_number" => 1
        })

      Repo.insert!(%Member{
        national_id: "1006",
        last_name: "Pair",
        first_name: "Piet",
        club_name: "New",
        club_number: 2,
        sex: "m"
      })

      summary = PlayerDataRefresh.dry_run(t)
      club = only(summary, :club)
      number = only(summary, :club_number)
      assert club.id == number.id

      chosen = PlayerDataRefresh.select(summary, [club.id])
      assert Enum.map(chosen, & &1.field) == [:club, :club_number]

      assert {:ok, _} = PlayerDataRefresh.apply(t, chosen)
      reloaded = Tournaments.get_player!(t.id, p.id)
      assert {reloaded.club, reloaded.club_number, reloaded.sex} == {"New", 2, ""}
    end

    test "the KBSB name is proposed when the spelling differs, not for comma spacing", %{
      tournament: t
    } do
      player(t, %{"name" => "Hendricks, Bjorn", "national_id" => "1007"})
      player(t, %{"name" => "Spaced ,Sam", "national_id" => "1008"})

      Repo.insert!(%Member{national_id: "1007", last_name: "Hendricks", first_name: "Björn"})
      Repo.insert!(%Member{national_id: "1008", last_name: "Spaced", first_name: "Sam"})

      summary = PlayerDataRefresh.dry_run(t)

      assert [%{field: :name, old: "Hendricks, Bjorn", new: "Hendricks, Björn"}] =
               summary.proposals
    end

    test "a missing FIDE id is filled in, unless another player already has it", %{tournament: t} do
      player(t, %{"name" => "Linked, Lea", "national_id" => "1009"})
      player(t, %{"name" => "Twin, Tia", "national_id" => "1010"})
      player(t, %{"name" => "Holder, Hugo", "fide_id" => 201_010})

      Repo.insert!(%Member{
        national_id: "1009",
        last_name: "Linked",
        first_name: "Lea",
        fide_id: 201_009
      })

      Repo.insert!(%Member{
        national_id: "1010",
        last_name: "Twin",
        first_name: "Tia",
        fide_id: 201_010
      })

      proposals = PlayerDataRefresh.dry_run(t).proposals |> Enum.filter(&(&1.field == :fide_id))
      assert [%{new: 201_009}] = proposals
    end

    test "affiliation from the KBSB list, only where the list states it", %{tournament: t} do
      player(t, %{"name" => "Lapsed, Lou", "national_id" => "1011"})

      Repo.insert!(%Member{
        national_id: "1011",
        last_name: "Lapsed",
        first_name: "Lou",
        affiliated: false
      })

      assert %{old: true, new: false, source: :kbsb} =
               only(PlayerDataRefresh.dry_run(t), :affiliated)
    end
  end

  describe "a full birth date" do
    alias PairingsEngine.Fide.FidePlayer

    test "is left alone when the list's year agrees with it", %{tournament: t} do
      {:ok, _} =
        Tournaments.create_player(t.id, %{
          "name" => "Dated, Dirk",
          "fide_id" => 202_001,
          "birth_year" => "1990",
          "birth_date" => "1990-06-15"
        })

      Repo.insert!(%FidePlayer{fide_id: 202_001, name: "Dated, Dirk", birth_year: 1990})

      assert %{proposals: []} = PlayerDataRefresh.dry_run(t)
    end

    test "goes with the old year when the list disagrees, and the preview says so", %{
      tournament: t
    } do
      {:ok, p} =
        Tournaments.create_player(t.id, %{
          "name" => "Dated, Dora",
          "fide_id" => 202_002,
          "birth_year" => "1990",
          "birth_date" => "1990-06-15"
        })

      Repo.insert!(%FidePlayer{fide_id: 202_002, name: "Dated, Dora", birth_year: 1991})

      summary = PlayerDataRefresh.dry_run(t)
      assert [%{field: :birth_year, old: ~D[1990-06-15], new: 1991}] = summary.proposals

      assert {:ok, _} = PlayerDataRefresh.apply(t, summary.proposals)
      reloaded = Tournaments.get_player!(t.id, p.id)
      assert {reloaded.birth_year, reloaded.birth_date} == {1991, nil}
    end
  end
end
