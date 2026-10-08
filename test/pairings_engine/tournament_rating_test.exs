defmodule PairingsEngine.TournamentRatingTest do
  @moduledoc """
  The Tournament Rating (TRF26 record 172's six methods, VCL4THP Q145), the
  initial order for players level on it (C.04.2 2.2: rating, FIDE title,
  then alphabetical or another announced criterion - Q146), and a Swiss
  late entrant's pairing number (C.04.2 2.4: "an appropriate TPN" - Q156).
  """
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.NextRoundPreviewFixture

  alias PairingsEngine.{Pairing, Repo, Standings, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Tournament}

  describe "Player.rating/2" do
    setup do
      %{
        both: %Player{fide_rating: 2000, national_rating: 2100, tournament_rating: 2200},
        fide_only: %Player{fide_rating: 1900, national_rating: 0},
        national_only: %Player{fide_rating: 0, national_rating: 1800},
        none: %Player{fide_rating: nil, national_rating: nil}
      }
    end

    test "each method reads its own rating", p do
      expected = %{
        "FIDE" => {2000, 1900, 0, 0},
        "NRO" => {2100, 0, 1800, 0},
        "FIDON" => {2000, 1900, 1800, 0},
        "NIDOF" => {2100, 1900, 1800, 0},
        "HBFN" => {2200, 1900, 1800, 0},
        "OTHER" => {2200, 0, 0, 0}
      }

      for {method, want} <- expected do
        got =
          {Player.rating(p.both, method), Player.rating(p.fide_only, method),
           Player.rating(p.national_only, method), Player.rating(p.none, method)}

        assert got == want, "#{method}: #{inspect(got)}"
      end

      assert Enum.sort(Map.keys(expected)) == Enum.sort(Tournament.rating_methods())
    end

    test "HBFN takes a typed rating below the list ratings as no more than it is", p do
      player = %{p.both | tournament_rating: 1500}
      assert Player.rating(player, "HBFN") == 2100
    end

    test "a tournament stands for its method, and FIDON is the default", p do
      assert Player.rating(p.both, %Tournament{rating_method: "NRO"}) == 2100
      assert Player.rating(p.both, %Tournament{}) == 2000
      assert Player.rating(p.both) == 2000
      assert Player.rating(p.both, nil) == 2000
    end

    test "the tournament refuses a method TRF26 does not have" do
      changeset = Tournament.changeset(%Tournament{}, %{"rating_method" => "ELO"})
      assert {_, _} = changeset.errors[:rating_method]
    end
  end

  describe "initial order (C.04.2 2.2)" do
    test "players level on rating are ordered by FIDE title before their name" do
      players = [
        %Player{id: 1, name: "Aaron", title: "", fide_rating: 2300},
        %Player{id: 2, name: "Bert", title: "FM", fide_rating: 2300},
        %Player{id: 3, name: "Carl", title: "WGM", fide_rating: 2300},
        %Player{id: 4, name: "Dirk", title: "IM", fide_rating: 2300},
        %Player{id: 5, name: "Emil", title: "GM", fide_rating: 2300},
        %Player{id: 6, name: "Zed", title: "", fide_rating: 2400},
        %Player{id: 7, name: "Fons", title: "WCM", fide_rating: 2300},
        %Player{id: 8, name: "Gert", title: "CM", fide_rating: 2300},
        %Player{id: 9, name: "Hans", title: "WIM", fide_rating: 2300},
        %Player{id: 10, name: "Ivo", title: "WFM", fide_rating: 2300}
      ]

      order = players |> Pairing.initial_order(%Tournament{}) |> Enum.map(& &1.name)

      assert order ==
               ~w(Zed Emil Dirk Carl Bert Hans Gert Ivo Fons Aaron)
    end

    test "the TRF's own lower-case title codes rank the same way" do
      assert Player.title_rank(%Player{title: "g"}) == Player.title_rank(%Player{title: "GM"})
      assert Player.title_rank(%Player{title: "wf"}) == Player.title_rank(%Player{title: "WFM"})
      assert Player.title_rank(%Player{title: "AGM"}) == Player.title_rank(%Player{title: ""})
    end

    test "the last criterion can be the FIDE ID or the age instead of the name" do
      players = [
        %Player{id: 1, name: "Anna", fide_id: 300, birth_year: 1990, fide_rating: 2000},
        %Player{id: 2, name: "Bea", fide_id: 100, birth_date: ~D[2001-03-04], fide_rating: 2000},
        %Player{id: 3, name: "Cleo", fide_id: nil, birth_year: 1980, fide_rating: 2000},
        %Player{id: 4, name: "Dora", fide_id: 200, birth_year: nil, fide_rating: 2000}
      ]

      names = fn tiebreak ->
        players
        |> Pairing.initial_order(%Tournament{initial_order_tiebreak: tiebreak})
        |> Enum.map(& &1.name)
      end

      assert names.("name") == ~w(Anna Bea Cleo Dora)
      # Unknown values go last, then by name.
      assert names.("fide_id") == ~w(Bea Dora Anna Cleo)
      assert names.("age_older") == ~w(Cleo Anna Bea Dora)
      assert names.("age_younger") == ~w(Bea Anna Cleo Dora)
    end

    test "the order follows the tournament's rating method" do
      players = [
        %Player{id: 1, name: "Fide", fide_rating: 2200, national_rating: 1900},
        %Player{id: 2, name: "Nat", fide_rating: 2000, national_rating: 2300}
      ]

      assert players |> Pairing.initial_order(%Tournament{}) |> Enum.map(& &1.name) ==
               ~w(Fide Nat)

      assert players
             |> Pairing.initial_order(%Tournament{rating_method: "NRO"})
             |> Enum.map(& &1.name) == ~w(Nat Fide)
    end
  end

  describe "round 1's pairing numbers" do
    test "come from the national rating under NRO" do
      t = plain_tournament(6, %{rating_method: "NRO"})

      # Fixture players are FIDE-rated top-down; give them national ratings
      # the other way round.
      for p <- Tournaments.list_players(t.id) do
        set_player(p, national_rating: 1000 + p.id)
      end

      pair!(t)

      numbers =
        t.id
        |> Tournaments.list_players()
        |> Enum.sort_by(& &1.pairing_number)
        |> Enum.map(& &1.national_rating)

      assert numbers == Enum.sort(numbers, :desc)
    end

    test "come from the typed rating under OTHER, an untyped one counting as none" do
      t = plain_tournament(4, %{rating_method: "OTHER"})
      [p1, p2, p3, p4] = t.id |> Tournaments.list_players() |> Enum.sort_by(& &1.name)

      set_player(p3, tournament_rating: 2500)
      set_player(p2, tournament_rating: 2100)
      set_player(p4, tournament_rating: 2300)

      pair!(t)

      number = fn p -> Repo.get!(Player, p.id).pairing_number end
      assert Enum.map([p3, p4, p2, p1], number) == [1, 2, 3, 4]
    end

    test "under FIDON stay what they always were" do
      t = plain_tournament(6)
      pair!(t)

      assert t.id
             |> Tournaments.list_players()
             |> Enum.sort_by(& &1.name)
             |> Enum.map(& &1.pairing_number) ==
               [1, 2, 3, 4, 5, 6]
    end
  end

  describe "a Swiss late entrant numbered by rating (C.04.2 2.4)" do
    setup do
      t = plain_tournament(8, %{late_entry_numbering: "rating"})

      for _ <- 1..4 do
        pair!(t)
        finish_latest_round(t)
      end

      before = past_boards(t)
      field = t.id |> Tournaments.list_players() |> Map.new(&{&1.id, &1.pairing_number})

      # Between Player 001 (2393) and Player 002 (2386).
      {:ok, late} =
        Tournaments.create_player(t.id, %{
          "name" => "Late Entrant",
          "fide_rating" => 2390,
          "start_round" => 5
        })

      %{t: t, late: late, before: before, field: field}
    end

    test "after round 4 is the number their rating earns, everybody below moving down one",
         %{t: t, late: late, before: before, field: field} do
      pair!(t)

      assert Repo.get!(Player, late.id).pairing_number == 2

      for {id, old} <- field do
        new = Repo.get!(Player, id).pairing_number
        if old == 1, do: assert(new == 1), else: assert(new == old + 1)
      end

      # The rounds already played are not touched: same boards, same players.
      assert Enum.filter(past_boards(t), &(elem(&1, 0) <= 4)) == before
    end

    test "the next-round preview numbers them the same way, in memory only",
         %{t: t, late: late} do
      {:ok, context} = Pairing.preview_context(Repo.reload!(t))

      assert context.history.full_roster[late.id].pairing_number == 2
      assert Repo.get!(Player, late.id).pairing_number == nil
    end

    test "rated below everybody, goes after the field", %{t: t, late: late} do
      set_player(late, fide_rating: 1000)
      pair!(t)
      assert Repo.get!(Player, late.id).pairing_number == 9
    end
  end

  # The default since VCL4THP Q156: by rating. After the field takes an
  # arbiter's choice ("after") or a tournament from before the default
  # ("end", the migration's value); both pair the same.
  for {setting, number} <- [{nil, 1}, {"after", 7}, {"end", 7}] do
    test "a Swiss late entrant rated above the field, late_entry_numbering #{inspect(setting)}, is number #{number}" do
      attrs = if unquote(setting), do: %{late_entry_numbering: unquote(setting)}, else: %{}
      t = plain_tournament(6, attrs)
      pair!(t)
      finish_latest_round(t)

      {:ok, late} =
        Tournaments.create_player(t.id, %{
          "name" => "Late Entrant",
          "fide_rating" => 2700,
          "start_round" => 2
        })

      pair!(t)
      assert Repo.get!(Player, late.id).pairing_number == unquote(number)
    end
  end

  # C.04.7 1.3.1-1.3.2: a late entrant is placed by Article 2, and Group A's
  # last player stays its last player - so one numbered above that player is
  # in Group A, and the line moves down with the player who holds it.
  test "numbered by rating into a Baku event, joins Group A without it growing at the bottom" do
    t =
      plain_tournament(8, %{
        late_entry_numbering: "rating",
        acceleration: "baku",
        initial_colour: "white",
        start_date: "2026-09-01",
        end_date: "2026-09-07",
        round_dates: for(n <- 1..7, do: "2026-09-0#{n}")
      })

    pair!(t)
    finish_latest_round(t)
    assert reload(t).baku_group_a_last == 4
    fourth = t.id |> Pairing.full_roster_players() |> Enum.at(3)

    {:ok, late} =
      Tournaments.create_player(t.id, %{
        "name" => "Late Entrant",
        "fide_rating" => 2700,
        "start_round" => 2
      })

    pair!(t)
    finish_latest_round(t)

    assert Repo.get!(Player, late.id).pairing_number == 1
    assert Repo.get!(Player, fourth.id).pairing_number == 5
    assert reload(t).baku_group_a_last == 5

    roster = Pairing.full_roster_players(t.id)
    group_a = t |> reload() |> Pairing.accelerations(roster, 2) |> Map.keys() |> Enum.sort()
    assert group_a == roster |> Enum.take(5) |> Enum.map(& &1.id) |> Enum.sort()

    pair!(t)
    finish_latest_round(t)

    # Ainalrami's checker replays every round of the exported file and finds
    # each pairing it would have made.
    {:ok, text} = PairingsEngine.TrfExport.export(reload(t))
    assert check_trf(text) == 0
  end

  defp check_trf(text) do
    path = Path.join(System.tmp_dir!(), "rating-method-#{System.unique_integer([:positive])}.trf")
    File.write!(path, text)

    try do
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        ExUnit.CaptureIO.capture_io(fn -> Process.put(:code, Ainalrami.CLI.run(["-c", path])) end)
      end)

      Process.get(:code)
    after
      File.rm(path)
    end
  end

  describe "number_late_entrants/4" do
    test "with nobody numbered is plain 1..N" do
      newcomers = Pairing.initial_order([p(1, 1500), p(2, 2000), p(3, 1800)], %Tournament{})

      assert {numbers, nil} = Pairing.number_late_entrants([], newcomers, %Tournament{}, nil)
      assert Enum.map(numbers, fn {pl, n} -> {pl.id, n} end) == [{2, 1}, {3, 2}, {1, 3}]
    end

    test "two newcomers, a gap left by a deleted player, and Baku's line moving with its player" do
      # Numbers 1, 2, 4, 5 (3 deleted); Group A's last player is number 2.
      numbered = [p(10, 2400, 1), p(11, 2300, 2), p(12, 2100, 4), p(13, 2000, 5)]
      newcomers = Pairing.initial_order([p(20, 2350), p(21, 2050)], %Tournament{})

      {numbers, last} = Pairing.number_late_entrants(numbered, newcomers, %Tournament{}, 2)

      assert numbers |> Enum.map(fn {pl, n} -> {pl.id, n} end) |> Enum.sort() ==
               [{11, 3}, {12, 5}, {13, 7}, {20, 2}, {21, 6}]

      # Player 11 held the line at 2 and now holds it at 3; 20 is in Group A.
      assert last == 3
    end

    test "players already numbered keep their order even when their ratings have changed" do
      # 11 was numbered above 10 and has since dropped below them.
      numbered = [p(11, 1900, 1), p(10, 2100, 2)]
      {numbers, _} = Pairing.number_late_entrants(numbered, [p(20, 2000)], %Tournament{}, nil)

      # Placed above the first numbered player they outrank: 11.
      assert numbers |> Enum.map(fn {pl, n} -> {pl.id, n} end) |> Enum.sort() ==
               [{10, 3}, {11, 2}, {20, 1}]
    end
  end

  describe "the rating-based tie-breaks" do
    test "read the tournament's rating, so unrated is unrated by it" do
      players = [
        %Player{fide_rating: 2000, national_rating: 0},
        %Player{fide_rating: 1800, national_rating: 1700}
      ]

      refute Standings.unrated_present?(players, %Tournament{})
      assert Standings.unrated_present?(players, %Tournament{rating_method: "NRO"})
    end
  end

  describe "the settings" do
    test "freeze with round 1, like the initial colour" do
      t = plain_tournament(4)
      refute :rating_method in Tournaments.locked_fields(t)

      pair!(t)
      locked = Tournaments.locked_fields(reload(t))
      assert :rating_method in locked
      assert :initial_order_tiebreak in locked
    end

    test "travel in a JSON backup" do
      t = plain_tournament(2, %{rating_method: "HBFN", initial_order_tiebreak: "age_older"})
      [p | _] = Tournaments.list_players(t.id)
      set_player(p, tournament_rating: 1999)

      envelope =
        t
        |> reload()
        |> PairingsEngine.TournamentExport.export_tournament()
        |> Jason.encode!()
        |> Jason.decode!()

      [entry] = envelope["tournaments"]
      assert entry["tournament"]["rating_method"] == "HBFN"
      assert entry["tournament"]["initial_order_tiebreak"] == "age_older"
      assert Enum.any?(entry["players"], &(&1["tournament_rating"] == 1999))
    end
  end

  describe "late_entry_numbering on import (VCL4THP Q156)" do
    defp import_scope do
      user =
        Repo.insert!(%PairingsEngine.Accounts.User{
          email: "q156-#{System.unique_integer([:positive])}@example.com",
          confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
        })

      PairingsEngine.Accounts.Scope.for_user(user)
    end

    defp envelope(t),
      do:
        t
        |> PairingsEngine.TournamentExport.export_tournament()
        |> Jason.encode!()
        |> Jason.decode!()

    test "a JSON backup keeps what it says, and one from before the key is grandfathered" do
      for value <- ~w(rating after end) do
        t = plain_tournament(2, %{late_entry_numbering: value})
        {:ok, [copy]} = PairingsEngine.TournamentImport.import(envelope(t), import_scope())
        assert Repo.reload!(copy).late_entry_numbering == value
      end

      old =
        update_in(envelope(plain_tournament(2)), ["tournaments"], fn [entry] ->
          [update_in(entry, ["tournament"], &Map.delete(&1, "late_entry_numbering"))]
        end)

      {:ok, [copy]} = PairingsEngine.TournamentImport.import(old, import_scope())
      assert Repo.reload!(copy).late_entry_numbering == "end"
      assert PairingsEngine.Compliance.check(Repo.reload!(copy)) == []
    end

    test "a TRF, which has no such record, imports as a new tournament: by rating" do
      t =
        plain_tournament(4, %{
          late_entry_numbering: "after",
          start_date: "2026-09-01",
          end_date: "2026-09-07",
          round_dates: for(n <- 1..7, do: "2026-09-0#{n}")
        })

      pair!(t)
      {:ok, text} = PairingsEngine.TrfExport.export(reload(t))
      {:ok, imported, _warnings} = PairingsEngine.TrfImport.import_text(text, import_scope())
      assert Repo.reload!(imported).late_entry_numbering == "rating"
    end
  end

  defp p(id, rating, number \\ nil),
    do: %Player{id: id, name: "P#{id}", fide_rating: rating, pairing_number: number}

  # Every board of every round so far, by player id.
  defp past_boards(t) do
    from(g in PairingsEngine.Tournaments.Pairing,
      join: r in PairingsEngine.Tournaments.Round,
      on: r.id == g.round_id,
      where: r.tournament_id == ^t.id,
      order_by: [r.number, g.board],
      select: {r.number, g.board, g.white_player_id, g.black_player_id, g.result}
    )
    |> Repo.all()
  end
end
