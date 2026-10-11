defmodule PairingsEngine.TrfImportWithdrawnTest do
  @moduledoc """
  A TRF cannot say "withdrew" (audit 2026-10, finding F6). The import reads
  the file for what a withdrawal looks like - played earlier, nothing in
  the trailing rounds, rounds still to pair - names those players in its
  report, and withdraws the ones the arbiter ticks.
  """

  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Pairing, Repo, Tournaments, TrfExport, TrfImport}
  alias PairingsEngine.Tournaments.Tournament

  ## ---------- the rule, on a file's parsed data ----------

  defp game(opponent, result \\ "1"), do: %{opponent_rank: opponent, result: result, colour: "w"}
  defp bye(code), do: %{opponent_rank: nil, result: code, colour: nil}
  @blank %{opponent_rank: nil, result: nil, colour: nil}

  defp data(rounds, games_by_rank) do
    %{
      tournament: %{number_of_rounds: rounds},
      players:
        for {rank, games} <- games_by_rank do
          %{rank: rank, name: "Player #{rank} ", games: games}
        end
    }
  end

  defp swiss, do: %Tournament{pairing_system: "swiss", type: "swiss"}

  defp looks(data, tournament \\ swiss(), paired) do
    for w <- TrfImport.looks_withdrawn(data, tournament, paired), do: {w.rank, w.trailing}
  end

  describe "looks_withdrawn/3" do
    test "played earlier, nothing since: listed, with how long and a suggestion" do
      file =
        data(5, %{
          1 => [game(2), game(3), game(4)],
          2 => [game(1), @blank, @blank],
          3 => [game(4), game(1), bye("Z")],
          4 => [game(3), game(2), game(1)]
        })

      assert [
               %{rank: 2, name: "Player 2", last_round: 1, trailing: 2, suggested: true},
               %{rank: 3, name: "Player 3", last_round: 2, trailing: 1, suggested: false}
             ] = TrfImport.looks_withdrawn(file, swiss(), 3)
    end

    test "a late entrant - blank at the start, games at the end - is not" do
      file = data(5, %{1 => [game(2), game(3)], 2 => [game(1), game(3)], 3 => [@blank, game(1)]})
      assert looks(file, 2) == []
    end

    test "a player with nothing at all is not: they may not have arrived yet" do
      file = data(5, %{1 => [game(2), game(2)], 2 => [game(1), game(1)], 3 => [@blank, @blank]})
      assert looks(file, 2) == []

      # ...and neither is a games list too short to say anything.
      file = data(5, %{1 => [game(2), game(2)], 2 => [game(1), game(1)], 3 => []})
      assert looks(file, 2) == []
    end

    test "a bye that pays, or that the pairing gave, is not nothing" do
      for code <- ~w(H F U) do
        file =
          data(5, %{1 => [game(2), game(2)], 2 => [game(1), game(1)], 3 => [game(1), bye(code)]})

        assert looks(file, 2) == [], code
      end

      # The ways an absence is written are.
      for code <- ["Z", "-", "0", " ", ""] do
        file =
          data(5, %{1 => [game(2), game(2)], 2 => [game(1), game(1)], 3 => [game(1), bye(code)]})

        assert looks(file, 2) == [{3, 1}], inspect(code)
      end
    end

    test "a forfeit is a game: the player was paired" do
      file =
        data(5, %{
          1 => [game(2), game(3, "+")],
          2 => [game(1), game(1)],
          3 => [game(1), game(1, "-")]
        })

      assert looks(file, 2) == []
    end

    test "a bye asked for in the round about to be paired means they are still there" do
      file =
        data(5, %{
          1 => [game(2), game(2)],
          2 => [game(1), game(1)],
          3 => [game(1), @blank, bye("H")]
        })

      assert looks(file, 2) == []
    end

    test "a finished event has nobody left to pair, so nobody is listed" do
      file = data(2, %{1 => [game(2), game(2)], 2 => [game(1), game(1)], 3 => [game(1), @blank]})
      assert looks(file, 2) == []

      # A file that does not say how many rounds there are cannot be called
      # finished.
      assert looks(put_in(file, [:tournament, :number_of_rounds], nil), 2) == [{3, 1}]
    end

    test "not for a round robin, and not for teams" do
      file = data(5, %{1 => [game(2), game(2)], 2 => [game(1), game(1)], 3 => [game(1), @blank]})
      assert looks(file, 2) == [{3, 1}]
      assert looks(file, %Tournament{pairing_system: "round_robin", type: "swiss"}, 2) == []
      assert looks(file, %Tournament{pairing_system: "swiss", type: "team-swiss"}, 2) == []
    end
  end

  ## ---------- through a real export and import ----------

  defp tournament(rounds) do
    dates = for r <- 1..rounds, do: Date.to_iso8601(Date.add(~D[2026-08-01], (r - 1) * 7))

    {:ok, t} =
      Tournaments.create_tournament(%{
        "name" => "Withdrawn #{System.unique_integer([:positive])}",
        "type" => "swiss",
        "city" => "Pelt",
        "federation" => "BEL",
        "chief_arbiter" => "Arbiter, Test",
        "rounds_count" => rounds,
        "start_date" => hd(dates),
        "end_date" => List.last(dates),
        "round_dates" => dates
      })

    for {rating, i} <- Enum.with_index([2400, 2300, 2200, 2100, 2000, 1900], 1) do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => "P0#{i}", "fide_rating" => rating})
    end

    t
  end

  defp fresh(t), do: Tournaments.get_tournament!(t.id)
  defp player(t, name), do: Enum.find(Tournaments.list_players(t.id), &(&1.name == name))

  defp play_round(t) do
    {:ok, round} = Pairing.pair_next_round(fresh(t))

    for b <- Repo.preload(round, :pairings).pairings, b.black_player_id do
      {:ok, _} = Tournaments.update_pairing_result(b, "1-0", [])
    end

    round
  end

  # `rounds` rounds played, P06 withdrawn after the first.
  defp exported(rounds_count, rounds) do
    t = tournament(rounds_count)
    play_round(t)
    {:ok, _} = Tournaments.update_player(player(t, "P06"), %{"status" => "withdrawn"})
    for _ <- 2..rounds//1, do: play_round(t)
    {:ok, text} = TrfExport.export(fresh(t))
    text
  end

  defp seated(t, number) do
    round = t.id |> Tournaments.get_round(number) |> Repo.preload(:pairings)
    name = Map.new(Tournaments.list_players(t.id), &{&1.id, &1.name})

    for b <- round.pairings, id <- [b.white_player_id, b.black_player_id], id, do: name[id]
  end

  describe "the review" do
    test "names the player who withdrew, and after one round suggests nothing" do
      assert {:ok, report} = TrfImport.review(exported(4, 2))

      assert [%{name: "P06", last_round: 1, trailing: 1, suggested: false}] =
               report.looks_withdrawn

      # Something to show the arbiter, whatever else the file needs.
      refute TrfImport.report_empty?(report)
    end

    test "after two rounds of nothing the tick is suggested" do
      assert {:ok, report} = TrfImport.review(exported(5, 3))
      assert [%{name: "P06", trailing: 2, suggested: true}] = report.looks_withdrawn
    end

    test "a finished tournament lists nobody" do
      assert {:ok, report} = TrfImport.review(exported(2, 2))
      assert report.looks_withdrawn == []
    end

    test "writes nothing: the review is rolled back" do
      text = exported(4, 2)
      before = Repo.aggregate(Tournament, :count)
      assert {:ok, _report} = TrfImport.review(text)
      assert Repo.aggregate(Tournament, :count) == before
    end
  end

  describe "the import" do
    test "unticked, the player is active and the next round pairs them - as the file says" do
      text = exported(4, 2)
      assert {:ok, copy, report} = TrfImport.import_with_report(text)

      assert [%{name: "P06", withdrawn: false}] = report.looks_withdrawn
      assert player(copy, "P06").status == "active"

      assert [%{"name" => "P06", "withdrawn" => false, "trailing_rounds" => 1, "last_round" => 1}] =
               fresh(copy).import_findings["looks_withdrawn"]

      {:ok, _} = Pairing.pair_next_round(fresh(copy))
      assert "P06" in seated(copy, 3)
    end

    test "ticked, the player is withdrawn, the choice is kept, and no round pairs them" do
      text = exported(4, 2)
      {:ok, review} = TrfImport.review(text)
      [%{rank: rank}] = review.looks_withdrawn

      assert {:ok, copy, report} = TrfImport.import_with_report(text, nil, withdraw: [rank])
      assert [%{name: "P06", withdrawn: true}] = report.looks_withdrawn
      assert player(copy, "P06").status == "withdrawn"

      assert [%{"name" => "P06", "rank" => ^rank, "withdrawn" => true, "suggested" => false}] =
               fresh(copy).import_findings["looks_withdrawn"]

      {:ok, _} = Pairing.pair_next_round(fresh(copy))
      refute "P06" in seated(copy, 3)
      assert length(seated(copy, 3)) == 5
    end

    test "only a player the report lists can be withdrawn this way" do
      text = exported(4, 2)
      {:ok, review} = TrfImport.review(text)
      [%{rank: listed}] = review.looks_withdrawn
      other = Enum.find(1..6, &(&1 != listed))

      assert {:ok, copy, report} = TrfImport.import_with_report(text, nil, withdraw: [other, 99])
      assert [%{withdrawn: false}] = report.looks_withdrawn
      assert Enum.all?(Tournaments.list_players(copy.id), &(&1.status == "active"))
    end

    test "import_text/2 is what it was: nobody is withdrawn without being asked" do
      assert {:ok, copy, _warnings} = TrfImport.import_text(exported(4, 2))
      assert player(copy, "P06").status == "active"
    end
  end
end
