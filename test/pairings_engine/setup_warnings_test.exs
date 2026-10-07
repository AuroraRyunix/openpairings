defmodule PairingsEngine.SetupWarningsTest do
  @moduledoc """
  VCL4THP Q62: the setup says, before round 1, when the rounds cannot be
  finished within the pairing rules for the players entered.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Tournament}

  defp swiss(rounds),
    do: %Tournament{pairing_system: "swiss", rounds_count: rounds, type: "swiss"}

  describe "Tournament.setup_warnings/2" do
    test "a Swiss with as many rounds as it can pair is fine" do
      assert Tournament.setup_warnings(swiss(7), 8) == []
      assert Tournament.setup_warnings(swiss(7), 7) == []
      assert Tournament.setup_warnings(swiss(5), 100) == []
    end

    test "a Swiss with more rounds than opponents warns, counting the odd player's bye" do
      assert [%{code: :swiss_rounds, max: 7, rounds: 8, players: 8}] =
               Tournament.setup_warnings(swiss(8), 8)

      # Seven players: seven rounds are possible, each sitting out once.
      assert Tournament.setup_warnings(swiss(7), 7) == []
      assert [%{code: :swiss_rounds, max: 7}] = Tournament.setup_warnings(swiss(8), 7)
    end

    test "nothing is said before there are two players" do
      assert Tournament.setup_warnings(swiss(9), 0) == []
      assert Tournament.setup_warnings(swiss(9), 1) == []
    end

    test "a round robin must match the schedule's length" do
      rr = fn rounds, cycles ->
        %Tournament{
          pairing_system: "round_robin",
          rounds_count: rounds,
          rr_cycles: cycles,
          rr_match_format: false,
          type: "swiss"
        }
      end

      assert Tournament.setup_warnings(rr.(5, 1), 6) == []
      assert Tournament.setup_warnings(rr.(10, 2), 6) == []
      assert [%{code: :round_robin_short, needed: 5}] = Tournament.setup_warnings(rr.(4, 1), 6)
      assert [%{code: :round_robin_short, needed: 10}] = Tournament.setup_warnings(rr.(5, 2), 6)
      assert [%{code: :round_robin_long, needed: 5}] = Tournament.setup_warnings(rr.(9, 1), 6)
    end

    test "teams and Keizer are not judged" do
      assert Tournament.setup_warnings(%{swiss(9) | type: "team-swiss"}, 4) == []
      assert Tournament.setup_warnings(%{swiss(9) | pairing_system: "keizer"}, 4) == []
    end
  end

  describe "Tournaments.setup_warnings/1" do
    test "counts only the players still in the event" do
      t = Repo.insert!(%Tournament{name: "Warn", type: "swiss", rounds_count: 4})

      for n <- 1..5 do
        Repo.insert!(%Player{
          tournament_id: t.id,
          name: "P#{n}",
          status: if(n == 5, do: "withdrawn", else: "active")
        })
      end

      # Four active players: at most three rounds.
      assert [%{code: :swiss_rounds, max: 3, players: 4}] = Tournaments.setup_warnings(t)
    end
  end
end
