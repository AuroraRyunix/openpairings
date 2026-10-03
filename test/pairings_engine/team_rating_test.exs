defmodule PairingsEngine.TeamRatingTest do
  @moduledoc """
  A team's rating and the order of the teams it gives (docs/team-tournaments.md,
  "Team rating"): the Olympiad rule by default (Olympiad Pairing Rules Art.
  3.1), the first boards, the whole roster, a rating typed in, and seeding
  by it when round 1 is paired.
  """
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{Repo, Tournaments}

  defp rating(t, name) do
    team = t.id |> Tournaments.list_teams() |> Enum.find(&(&1.name == name))
    Tournaments.team_rating(Repo.reload!(t), team)
  end

  defp order(t), do: t.id |> Tournaments.list_teams() |> Enum.map(& &1.name)

  defp set_method(t, method) do
    {:ok, t} = Tournaments.update_tournament(t, %{"team_rating_method" => method})
    t
  end

  describe "the methods" do
    # Board order deliberately not rating order: the Olympiad rule takes the
    # highest-rated players wherever they sit.
    setup do
      {t, _} =
        team_round_robin(
          [
            {"A", [1800, 2400, 2000, 2200, 2300]},
            {"B", [2100, 2100]},
            {"C", [0, 2000, 0, 1900]}
          ],
          boards: 4
        )

      %{t: t}
    end

    test "Olympiad (the default): the average of the four highest-rated players", %{t: t} do
      assert t.team_rating_method == "olympiad"
      # 2400, 2300, 2200, 2000.
      assert rating(t, "A") == 2225.0
      # Fewer players than boards: a missing player counts as an unrated
      # one, 1400, over four.
      assert rating(t, "B") == (2100 + 2100 + 1400 + 1400) / 4
      # Unrated players count 1400.
      assert rating(t, "C") == (2000 + 1900 + 1400 + 1400) / 4
    end

    test "first boards: the first four in board order", %{t: t} do
      t = set_method(t, "first_boards")
      assert rating(t, "A") == (1800 + 2400 + 2000 + 2200) / 4
      assert rating(t, "B") == (2100 + 2100 + 1400 + 1400) / 4
    end

    test "roster: every player on the roster", %{t: t} do
      t = set_method(t, "roster")
      assert rating(t, "A") == (1800 + 2400 + 2000 + 2200 + 2300) / 5
      assert rating(t, "B") == 2100.0
    end

    test "manual: only a typed rating; a typed rating wins under every method", %{t: t} do
      t = set_method(t, "manual")
      assert rating(t, "A") == 0.0

      team = t.id |> Tournaments.list_teams() |> Enum.find(&(&1.name == "B"))
      {:ok, _} = Tournaments.update_team(team, %{"rating_override" => "2345"})
      assert rating(t, "B") == 2345.0

      t = set_method(t, "olympiad")
      assert rating(t, "B") == 2345.0
      assert Tournaments.team_rating_display(t, Repo.reload!(team)) == 2345
    end

    test "a typed rating is a rating", %{t: t} do
      team = hd(Tournaments.list_teams(t.id))
      assert {:error, _} = Tournaments.update_team(team, %{"rating_override" => "-5"})
      assert {:error, _} = Tournaments.update_team(team, %{"rating_override" => "5000"})
      assert {:ok, cleared} = Tournaments.update_team(team, %{"rating_override" => ""})
      assert cleared.rating_override == nil
    end
  end

  describe "ordering the teams" do
    test "Order by rating: highest first; the next player's rating, then the name, break a tie" do
      {t, _} =
        team_round_robin(
          [
            # 2000 average over two boards each, all three.
            {"Zeta", [2000, 2000, 1500]},
            {"Alpha", [2000, 2000, 1400]},
            {"Beta", [2000, 2000, 1400]},
            {"Top", [2500, 2500]}
          ],
          boards: 2
        )

      {:ok, _} = Tournaments.seed_teams_by_rating(t)
      assert order(t) == ~w(Top Zeta Alpha Beta)
    end

    test "the tie-break's reserve counts 1400 when unrated or missing" do
      {t, _} =
        team_round_robin(
          [
            {"Zed", [2000, 2000, 0]},
            {"Yes", [2000, 2000, 1500]},
            {"Abe", [2000, 2000]},
            {"Low", [2000, 2000, 1300]}
          ],
          boards: 2
        )

      {:ok, _} = Tournaments.seed_teams_by_rating(t)
      # Reserve 1500, then Abe and Zed level on 1400 (name), then 1300.
      assert order(t) == ~w(Yes Abe Zed Low)
    end

    test "a team with no players can be seeded by a typed rating" do
      {t, [_a, b]} = team_round_robin([{"A", [1900, 1900]}, {"B", []}], boards: 2)
      {:ok, _} = Tournaments.update_team(b, %{"rating_override" => "2000"})
      {:ok, _} = Tournaments.seed_teams_by_rating(t)
      assert order(t) == ~w(B A)
    end

    test "round 1 seeds by rating unless the teams were ordered by hand" do
      {t, _} =
        team_swiss([{"Low", [1500, 1500]}, {"High", [2200, 2200]}, {"Mid", [1800, 1800]}],
          boards: 2,
          rounds: 2,
          teams_ordered_by_hand: false
        )

      pair_next!(t)

      numbers = t.id |> Tournaments.list_teams() |> Map.new(&{&1.name, &1.pairing_number})
      assert numbers == %{"High" => 1, "Mid" => 2, "Low" => 3}
    end

    test "a team moved by hand keeps the order the arbiter set" do
      {t, _} =
        team_swiss([{"Low", [1500, 1500]}, {"High", [2200, 2200]}, {"Mid", [1800, 1800]}],
          boards: 2,
          rounds: 2,
          teams_ordered_by_hand: false
        )

      mid = t.id |> Tournaments.list_teams() |> Enum.find(&(&1.name == "Mid"))
      {:ok, _} = Tournaments.move_team(t, mid, :up)
      assert Repo.reload!(t).teams_ordered_by_hand

      pair_next!(Repo.reload!(t))

      numbers = t.id |> Tournaments.list_teams() |> Map.new(&{&1.name, &1.pairing_number})
      assert numbers == %{"Low" => 1, "Mid" => 2, "High" => 3}
    end

    test "Order by rating hands the order back to the rating" do
      {t, _} =
        team_round_robin([{"Low", [1500]}, {"High", [2200]}],
          boards: 1,
          teams_ordered_by_hand: false
        )

      low = t.id |> Tournaments.list_teams() |> hd()
      {:ok, _} = Tournaments.move_team(t, low, :down)
      assert Repo.reload!(t).teams_ordered_by_hand

      {:ok, _} = Tournaments.seed_teams_by_rating(Repo.reload!(t))
      refute Repo.reload!(t).teams_ordered_by_hand
      assert order(t) == ~w(High Low)
    end
  end

  describe "where the rating shows" do
    test "the TRF 310 record's strength factor" do
      {t, _} =
        team_round_robin([{"A", [2400, 2200]}, {"B", [2000, 1900]}],
          boards: 2,
          round_dates: ~w(2026-10-01)
        )

      t = pair_all!(t)

      for p <- Tournaments.get_round(t.id, 1).pairings,
          do: {:ok, _} = Tournaments.update_pairing_result(p, "1/2-1/2")

      {:ok, text} = PairingsEngine.TrfExport.export(Repo.reload!(t))

      strengths =
        text
        |> String.split(["\r\n", "\n"])
        |> Enum.filter(&String.starts_with?(&1, "310 "))
        |> Enum.map(&(&1 |> String.slice(47, 6) |> String.trim()))

      assert strengths == ["2300", "1950"]
    end

    test "the published snapshot" do
      {t, _} = team_round_robin([{"A", [2400, 2200]}, {"B", []}], boards: 2)
      snapshot = PairingsEngine.Snapshot.build(Repo.reload!(t))
      ratings = Map.new(snapshot["teams"], &{&1["name"], &1["rating"]})
      assert ratings == %{"A" => 2300, "B" => nil}
    end
  end
end
