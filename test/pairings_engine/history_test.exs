defmodule PairingsEngine.HistoryTest do
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{History, Repo}
  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}

  defp tournament(attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Tournament{
          name: "History Data Test",
          type: "swiss",
          rounds_count: 3,
          tiebreaks: ~w(BH SB)
        },
        attrs
      )
    )
  end

  defp player(t, name, rating \\ 2000) do
    Repo.insert!(%Player{tournament_id: t.id, name: name, fide_rating: rating})
  end

  defp round(t, number), do: Repo.insert!(%Round{tournament_id: t.id, number: number})

  defp game(round, board, white, black, result) do
    Repo.insert!(%Pairing{
      round_id: round.id,
      board: board,
      white_player_id: white && white.id,
      black_player_id: black && black.id,
      result: result
    })
  end

  describe "standings_evolution/1" do
    test "returns empty for a tournament with nothing paired" do
      assert History.standings_evolution(tournament()) == {[], []}
    end

    test "tracks each player's rank round by round" do
      t = tournament()
      a = player(t, "Alice", 2200)
      b = player(t, "Bob", 2100)
      c = player(t, "Carol", 2000)
      d = player(t, "Dave", 1900)

      r1 = round(t, 1)
      game(r1, 1, a, b, "0-1")
      game(r1, 2, c, d, "1-0")

      r2 = round(t, 2)
      game(r2, 1, b, c, "1-0")
      game(r2, 2, a, d, "1-0")

      {rounds, series} = History.standings_evolution(t)

      assert rounds == [1, 2]
      assert length(series) == 4

      # Bob won both — top after round 2.
      bob = Enum.find(series, &(&1.name == "Bob"))
      assert bob.final_rank == 1
      assert Enum.map(bob.points, & &1.round) == [1, 2]
      assert List.last(bob.points).points == 2.0

      # Series come back ordered by final rank, so the caller can rely on it.
      assert Enum.map(series, & &1.final_rank) == Enum.sort(Enum.map(series, & &1.final_rank))
    end

    test "a rank actually changes across rounds when players overtake" do
      t = tournament()
      a = player(t, "Alice", 2200)
      b = player(t, "Bob", 2100)

      r1 = round(t, 1)
      game(r1, 1, a, b, "1-0")

      r2 = round(t, 2)
      game(r2, 1, b, a, "1-0")

      {_rounds, series} = History.standings_evolution(t)

      alice = Enum.find(series, &(&1.name == "Alice"))

      # Alice led after round 1 (1.0 vs 0.0), then Bob levelled — the whole
      # point of the bump chart is that this movement is visible.
      assert [%{round: 1, rank: 1, points: 1.0}, %{round: 2} = after_two] = alice.points
      assert after_two.points == 1.0
    end

    test "computes each round through_round, not retrospectively" do
      t = tournament()
      a = player(t, "Alice", 2200)
      b = player(t, "Bob", 2100)

      r1 = round(t, 1)
      game(r1, 1, a, b, "1-0")

      r2 = round(t, 2)
      game(r2, 1, a, b, "1-0")

      {_rounds, series} = History.standings_evolution(t)
      alice = Enum.find(series, &(&1.name == "Alice"))

      # After round 1 Alice has 1 point, not the 2 she finishes on — the
      # figures are the ones that stood at the time.
      assert Enum.map(alice.points, & &1.points) == [1.0, 2.0]
    end

    test "a player with no ranked appearance in a round simply has no point there" do
      t = tournament()
      a = player(t, "Alice")
      b = player(t, "Bob")

      r1 = round(t, 1)
      game(r1, 1, a, b, "1-0")

      {_rounds, series} = History.standings_evolution(t)

      # Every returned point must correspond to a real round.
      for s <- series, p <- s.points do
        assert p.round in [1]
        assert is_integer(p.rank)
      end
    end
  end

  describe "pairing_network/1" do
    test "returns no nodes or edges for an unpaired tournament" do
      assert %{nodes: [], edges: []} = History.pairing_network(tournament())
    end

    test "builds one undirected edge per pair, with the rounds they met in" do
      t = tournament()
      a = player(t, "Alice")
      b = player(t, "Bob")

      r1 = round(t, 1)
      game(r1, 1, a, b, "1-0")

      r2 = round(t, 2)
      # Same pair, colours reversed — one edge, met twice.
      game(r2, 1, b, a, "1-0")

      %{nodes: nodes, edges: edges} = History.pairing_network(t)

      assert [edge] = edges
      assert Enum.sort([edge.a, edge.b]) == Enum.sort([a.id, b.id])
      assert edge.rounds == [1, 2]
      assert edge.count == 2

      assert length(nodes) == 2
      assert Enum.all?(nodes, &(&1.games == 2))
    end

    test "a bye or vacated seat is not an edge" do
      t = tournament()
      a = player(t, "Alice")
      b = player(t, "Bob")
      c = player(t, "Carol")

      r1 = round(t, 1)
      game(r1, 1, a, b, "1-0")
      # A pairing-allocated bye: one seat empty. Drawing an edge for this
      # would connect a player to nothing.
      game(r1, 2, c, nil, "bye")

      %{nodes: nodes, edges: edges} = History.pairing_network(t)

      assert length(edges) == 1
      assert Enum.map(nodes, & &1.name) |> Enum.sort() == ["Alice", "Bob"]
      refute Enum.any?(nodes, &(&1.name == "Carol"))
    end

    test "nodes carry a game count and come back in a stable order" do
      t = tournament()
      a = player(t, "Zoe")
      b = player(t, "Adam")
      c = player(t, "Mia")

      r1 = round(t, 1)
      game(r1, 1, a, b, "1-0")

      r2 = round(t, 2)
      game(r2, 1, a, c, "1-0")

      %{nodes: nodes} = History.pairing_network(t)

      # Alphabetical, so a re-render can't reshuffle the ring.
      assert Enum.map(nodes, & &1.name) == ["Adam", "Mia", "Zoe"]

      zoe = Enum.find(nodes, &(&1.name == "Zoe"))
      assert zoe.games == 2
    end

    test "only this tournament's games are included" do
      t = tournament()
      other = tournament(%{name: "Other"})

      a = player(t, "Alice")
      b = player(t, "Bob")
      x = player(other, "Xavier")
      y = player(other, "Yara")

      game(round(t, 1), 1, a, b, "1-0")
      game(round(other, 1), 1, x, y, "1-0")

      %{nodes: nodes, edges: edges} = History.pairing_network(t)

      assert length(edges) == 1
      assert Enum.map(nodes, & &1.name) |> Enum.sort() == ["Alice", "Bob"]
    end
  end
end
