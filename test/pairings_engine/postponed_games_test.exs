defmodule PairingsEngine.PostponedGamesTest do
  @moduledoc """
  Postponed and adjourned games (VCL4THP Q157-169): a board carrying `"*"`,
  result unknown, game still to be played. See `PairingsEngine.PostponedGames`.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{
    Keizer,
    Pairing,
    PostponedGames,
    Repo,
    ResultsImport,
    Snapshot,
    Standings,
    TeamStandings,
    TeamSwiss,
    TrfExport,
    TrfImport,
    Tournaments
  }

  alias PairingsEngine.Tournaments.Tournament

  import PairingsEngine.AccountsFixtures, only: [user_scope_fixture: 0]
  import PairingsEngine.TeamFixtures

  # The engine's own TRF for a round, captured from the telemetry event
  # `Pairing` fires just before it hands the file over - see pairing_test.exs.
  setup do
    handler_id = "postponed-trf-#{inspect(self())}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:pairings_engine, :pairing, :trf_built],
      fn _event, _measurements, meta, _config ->
        Process.put(:trf_events, [meta | Process.get(:trf_events, [])])
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  # Four players, so round 1 is 1-3 and 2-4 (Alice-Carol, Bob-Dave) whatever
  # colours the lot gives. `round_dates` so the TRF export takes it.
  defp tournament(attrs \\ []) do
    t =
      Repo.insert!(
        struct(
          Tournament,
          Map.merge(
            %{
              name: "Club championship",
              type: "swiss",
              rounds_count: 3,
              tiebreaks: ~w(BH SB),
              round_dates: ["2026-09-01", "2026-09-08", "2026-09-15"]
            },
            Map.new(attrs)
          )
        )
      )

    players =
      for {name, rating} <- [{"Alice", 2000}, {"Bob", 1900}, {"Carol", 1800}, {"Dave", 1700}],
          into: %{} do
        {:ok, p} =
          Tournaments.create_player(t.id, %{tournament_id: t.id, name: name, fide_rating: rating})

        {name, p}
      end

    {t, players}
  end

  defp pair!(t, opts \\ []) do
    {:ok, round} = Pairing.pair_next_round(Repo.reload!(t), opts)
    Tournaments.get_round(t.id, round.number)
  end

  defp board_of(round, player) do
    Enum.find(round.pairings, &(player.id in [&1.white_player_id, &1.black_player_id]))
  end

  defp result!(pairing, result, opts \\ []) do
    {:ok, updated} = Tournaments.update_pairing_result(pairing, result, opts)
    updated
  end

  # Every other board of the round, White wins.
  defp white_wins_elsewhere!(round, except) do
    for p <- round.pairings, p.id != except.id, p.black_player_id, do: result!(p, "1-0")
  end

  defp points(t), do: t |> Standings.standings() |> Map.new(&{&1.player.name, &1.points})
  defp tiebreaks(t), do: t |> Standings.standings() |> Map.new(&{&1.player.name, &1.tiebreaks})

  defp trf_for(t, round_number) do
    Process.get(:trf_events, [])
    |> Enum.find(&(&1.tournament_id == t.id and &1.round == round_number))
    |> Map.fetch!(:trf)
  end

  describe "the result state (Q157)" do
    test "a board can be recorded as postponed, and it stays open" do
      {t, %{"Alice" => alice}} = tournament()
      round1 = pair!(t)

      board = round1 |> board_of(alice) |> result!("*")

      assert board.result == "*"
      assert [%{round: 1, pairing: %{id: id}}] = PostponedGames.open_games(t)
      assert id == board.id
    end
  end

  describe "pairing the next round with a postponed game open (Q158, Q167)" do
    test "the game counts as a draw for both players, in the engine's file too" do
      {t, %{"Alice" => alice, "Carol" => carol, "Bob" => bob}} = tournament()
      round1 = pair!(t)
      postponed = round1 |> board_of(alice) |> result!("*")
      white_wins_elsewhere!(round1, postponed)

      assert [%{id: :adjourned_counted_as_draw, round: 1, count: 1}] =
               PostponedGames.pairing_warnings(t)

      assert %{number: 2} = pair!(t)

      # The score the round was paired with: half a point each.
      scores = Standings.player_scores_before_round(t, 2)
      assert scores[alice.id] == 0.5
      assert scores[carol.id] == 0.5

      # And the file the engine was handed says a drawn game - colours and
      # all, since the two have met - with the half point in the score.
      parsed = t |> trf_for(2) |> Ainalrami.Trf.parse()
      by_name = Map.new(parsed.players, &{String.trim(&1.name), &1})

      for name <- ["Alice", "Carol"] do
        [game | _] = by_name[name].games
        assert game.result == "="
        assert game.colour in ["w", "b"]
        assert by_name[name].points == 0.5
      end

      # The ordinary result next to it is untouched.
      assert hd(by_name["Bob"].games).result in ["1", "0"]
      assert bob.id in Enum.map(Tournaments.list_players(t.id), & &1.id)
    end

    test "no provisional score but a draw is possible: the stored value is the only one" do
      {t, %{"Alice" => alice, "Carol" => carol}} = tournament()
      round1 = pair!(t)
      round1 |> board_of(alice) |> result!("*")

      awarded = Standings.pairing_award(board_of(Tournaments.get_round(t.id, 1), alice), 1, t)
      assert awarded == %{alice.id => t.points_draw, carol.id => t.points_draw}
    end

    test "a postponed game from an older round is confirmed before pairing (Q168)" do
      {t, %{"Alice" => alice}} = tournament()
      round1 = pair!(t)
      postponed = round1 |> board_of(alice) |> result!("*")
      white_wins_elsewhere!(round1, postponed)

      round2 = pair!(t)
      for p <- round2.pairings, p.black_player_id, do: result!(p, "1-0")

      assert [%{id: :adjourned_older_round_open, rounds: [1], count: 1}] =
               PostponedGames.pairing_warnings(t)

      assert {:error, {:needs_acknowledgement, [:adjourned_older_round_open]}} =
               Pairing.pair_next_round(Repo.reload!(t))

      refute Tournaments.get_round(t.id, 3)

      assert %{number: 3} = pair!(t, acknowledged: [:adjourned_older_round_open])
    end

    test "a round robin pairs from its schedule, so nothing is asked" do
      {t, _players} = tournament(pairing_system: "round_robin")
      assert PostponedGames.pairing_warnings(t) == []
    end
  end

  describe "missing results at pairing time (Q159, Q160)" do
    test "are refused as always until confirmed, then recorded as postponed" do
      {t, %{"Alice" => alice}} = tournament()
      round1 = pair!(t)
      open = board_of(round1, alice)
      white_wins_elsewhere!(round1, open)

      assert [%{id: :missing_results_recorded_as_adjourned, round: 1, count: 1}] =
               PostponedGames.pairing_warnings(t)

      assert {:error, "Round 1 still has missing results"} =
               Pairing.pair_next_round(Repo.reload!(t))

      assert Repo.reload!(open).result == ""

      assert %{number: 2} = pair!(t, acknowledged: [:missing_results_recorded_as_adjourned])
      assert Repo.reload!(open).result == "*"
    end

    test "a vacated seat is not a game to postpone, so it is not offered" do
      {t, %{"Alice" => alice}} = tournament()
      round1 = pair!(t)
      open = board_of(round1, alice)
      white_wins_elsewhere!(round1, open)

      open
      |> Ecto.Changeset.change(black_player_id: nil)
      |> Repo.update!()

      assert PostponedGames.pairing_warnings(t) == []

      assert {:error, "Round 1 still has missing results"} =
               Pairing.pair_next_round(Repo.reload!(t),
                 acknowledged: [:missing_results_recorded_as_adjourned]
               )
    end
  end

  describe "the real result, entered later (Q162, Q163)" do
    test "two rounds later: the warning fires for a win, and standings and tie-breaks follow" do
      {t, %{"Alice" => alice}} = tournament()
      round1 = pair!(t)
      postponed = round1 |> board_of(alice) |> result!("*")
      white_wins_elsewhere!(round1, postponed)

      round2 = pair!(t)
      for p <- round2.pairings, p.black_player_id, do: result!(p, "1-0")
      round3 = pair!(t, acknowledged: [:adjourned_older_round_open])
      for p <- round3.pairings, p.black_player_id, do: result!(p, "1-0")

      white = Enum.find(Tournaments.list_players(t.id), &(&1.id == postponed.white_player_id))
      black = Enum.find(Tournaments.list_players(t.id), &(&1.id == postponed.black_player_id))
      before_points = points(t)
      before_tiebreaks = tiebreaks(t)

      # A decisive result for a game the next two rounds were paired as a
      # draw: refused, nothing written, until the arbiter confirms.
      assert {:error, {:needs_acknowledgement, [:adjourned_non_draw_result]}} =
               Tournaments.update_pairing_result(postponed, "1-0")

      assert Repo.reload!(postponed).result == "*"
      assert points(t) == before_points

      result!(postponed, "1-0", acknowledged: [:adjourned_non_draw_result])

      after_points = points(t)
      assert after_points[white.name] == before_points[white.name] + 0.5
      assert after_points[black.name] == before_points[black.name] - 0.5

      # Their opponents' Sonneborn-Berger reads the new scores.
      assert tiebreaks(t) != before_tiebreaks
      assert PostponedGames.open_games(t) == []
    end

    test "a draw needs no confirmation: it is what the game counted as" do
      {t, %{"Alice" => alice}} = tournament()
      postponed = t |> pair!() |> board_of(alice) |> result!("*")

      assert result!(postponed, "1/2-1/2").result == "1/2-1/2"
    end

    test "every result that is not a draw for both players is one to confirm" do
      {t, %{"Alice" => alice}} = tournament()
      postponed = t |> pair!() |> board_of(alice) |> result!("*")

      for code <- ~w(1-0 0-1 1/2-0 0-1/2 1-0FF 0-1FF 0-0FF 0-0 1-0U 0-1U) do
        assert {:error, {:needs_acknowledgement, [:adjourned_non_draw_result]}} =
                 Tournaments.update_pairing_result(postponed, code),
               code
      end
    end

    test "the warning reads what is stored, not the struct a page holds" do
      {t, %{"Alice" => alice}} = tournament()
      stale = t |> pair!() |> board_of(alice)
      result!(stale, "*")

      # `stale` still says "", the database says "*".
      assert {:error, {:needs_acknowledgement, [:adjourned_non_draw_result]}} =
               Tournaments.update_pairing_result(stale, "0-1")
    end
  end

  describe "final standings (Q161, Q169)" do
    test "the tournament stays running, not finished, while a game is postponed" do
      {t, %{"Alice" => alice}} = tournament(rounds_count: 1, round_dates: ["2026-09-01"])
      round1 = pair!(t)
      postponed = round1 |> board_of(alice) |> result!("*")
      white_wins_elsewhere!(round1, postponed)

      assert Repo.reload!(t).status == "running"
      refute PostponedGames.final?(t)

      result!(postponed, "1/2-1/2")

      assert Repo.reload!(t).status == "finished"
      assert PostponedGames.final?(t)
    end
  end

  describe "tie-breaks before the result exists" do
    test "a postponed game is a played draw to the tie-breaks, not an unplayed round" do
      {t, %{"Alice" => alice}} = tournament()
      round1 = pair!(t)
      postponed = round1 |> board_of(alice) |> result!("*")
      white_wins_elsewhere!(round1, postponed)
      provisional = tiebreaks(t)

      result!(postponed, "1/2-1/2")

      # Exactly what a real draw gives: no Article 16 dummy, no bye.
      assert tiebreaks(t) == provisional
    end

    test "a norm, a rating estimate or a performance does not count it as played" do
      {t, %{"Alice" => alice}} = tournament()
      t |> pair!() |> board_of(alice) |> result!("*")

      entry = t |> Standings.standings() |> Enum.find(&(&1.player.id == alice.id))
      [game] = entry.games

      assert game.played
      assert game.postponed
      refute Standings.finished_game?(game)
    end
  end

  describe "the TRF (Q164, Q165, Q166)" do
    test "the export writes ? for both players and declares X as a draw" do
      {t, %{"Alice" => alice}} = tournament()
      round1 = pair!(t)
      postponed = round1 |> board_of(alice) |> result!("*")
      white_wins_elsewhere!(round1, postponed)

      {:ok, text} = TrfExport.export(Repo.reload!(t))
      lines = String.split(text, "\r\n")

      [line_162] = Enum.filter(lines, &String.starts_with?(&1, "162"))
      assert line_162 =~ ~r/X\s+0\.5/

      player_lines = Enum.filter(lines, &String.starts_with?(&1, "001"))

      postponed_ranks =
        for id <- [postponed.white_player_id, postponed.black_player_id] do
          Enum.find(Tournaments.list_players(t.id), &(&1.id == id)).pairing_number
        end

      for line <- player_lines do
        rank = line |> String.slice(4, 4) |> String.trim() |> String.to_integer()
        # Round 1's result is column 99.
        result = String.at(line, 98)

        if rank in postponed_ranks do
          assert result == "?"
          assert line |> String.slice(80, 4) |> String.trim() == "0.5"
        else
          assert result in ["1", "0"]
        end
      end
    end

    test "the engine dialect keeps the draw a pairing program reads" do
      {t, %{"Alice" => alice}} = tournament()
      t |> pair!() |> board_of(alice) |> result!("*")

      {:ok, text} = TrfExport.export(Repo.reload!(t), nil, dialect: :engine)

      refute text =~ "?"
    end

    test "importing the exported file keeps the game unknown - postponed, never guessed" do
      {t, %{"Alice" => alice}} = tournament()
      round1 = pair!(t)
      postponed = round1 |> board_of(alice) |> result!("*")
      white_wins_elsewhere!(round1, postponed)
      {:ok, text} = TrfExport.export(Repo.reload!(t))

      assert {:ok, imported, warnings} = TrfImport.import_text(text, user_scope_fixture())

      [round] = Tournaments.list_rounds(imported.id)
      results = round |> Repo.preload(:pairings) |> Map.fetch!(:pairings) |> Enum.map(& &1.result)

      assert Enum.sort(results) == ["*", "1-0"]
      assert %{kind: :postponed_imported, rounds: [1]} in warnings

      # The file's own points column agreed with the draw it counted.
      refute Enum.any?(warnings, &match?(%{kind: :points}, &1))
    end
  end

  describe "team matches" do
    test "a match with a postponed board is not complete, but scores provisionally for pairing" do
      {t, _teams} =
        team_swiss(
          [
            {"Alpha", [2200, 2100]},
            {"Beta", [2000, 1900]},
            {"Gamma", [1800, 1700]},
            {"Delta", [1600, 1500]}
          ],
          rounds: 3
        )

      pair_next!(t)
      [first, second] = t |> TeamStandings.matches() |> Enum.reject(& &1.bye?)

      # Board 1 postponed; board 2 won by team A, whichever colour it had.
      [row1, row2] = first.boards
      result!(row1.pairing, "*")
      a_white? = row2.pairing.white_player_id == row2.a_player_id
      result!(row2.pairing, if(a_white?, do: "1-0", else: "0-1"))

      for %{pairing: p} <- second.boards, do: result!(p, "1/2-1/2")

      match = t |> TeamStandings.matches() |> Enum.find(&(&1.match_id == first.match_id))

      refute match.complete?
      assert match.scored?
      assert match.postponed_boards == 1
      # Board 2 won by team A, board 1 a draw until played: 1.5 - 0.5.
      assert {match.gp_a, match.gp_b} == {1.5, 0.5}
      assert match.mp_a == t.team_match_points_win

      # The next round is paired with that score.
      teams = Tournaments.list_teams(t.id)
      field = Enum.filter(teams, &(&1.pairing_number != nil))
      %{teams: engine_teams} = TeamSwiss.engine_input(Repo.reload!(t), teams, field, 2)
      team_a = Enum.find(teams, &(&1.id == match.team_a_id))
      engine_a = Enum.find(engine_teams, &(&1.tpn == team_a.pairing_number))
      assert engine_a.match_points == t.team_match_points_win

      assert %{number: 2} = pair_next!(t)
    end
  end

  describe "the OpenResults snapshot" do
    test "a postponed board travels with no result and a flag; standings say provisional" do
      {t, %{"Alice" => alice}} = tournament(publish_mode: "immediate")
      round1 = pair!(t)
      postponed = round1 |> board_of(alice) |> result!("*")
      white_wins_elsewhere!(round1, postponed)

      snapshot = Snapshot.build(Repo.reload!(t))
      [round] = snapshot["rounds"]
      board = Enum.find(round["boards"], &(&1["board"] == postponed.board))
      other = Enum.find(round["boards"], &(&1["board"] != postponed.board))

      assert board["result"] == nil
      assert board["postponed"] == true
      refute Map.has_key?(other, "postponed")

      assert snapshot["standings"]["provisional"] == true
      assert snapshot["standings"]["postponed_games"] == 1
    end

    test "final standings carry no provisional flag at all" do
      {t, _players} = tournament(publish_mode: "immediate")
      round1 = pair!(t)
      for p <- round1.pairings, p.black_player_id, do: result!(p, "1-0")

      refute Map.has_key?(Snapshot.build(Repo.reload!(t))["standings"], "provisional")
    end
  end

  describe "the results CSV import" do
    test "a decisive result for a postponed game is refused, and nothing is written" do
      {t, %{"Alice" => alice}} = tournament()
      round1 = pair!(t)
      postponed = round1 |> board_of(alice) |> result!("*")
      other = Enum.find(round1.pairings, &(&1.id != postponed.id))

      assert {:error, [{:postponed_non_draw, board}]} =
               ResultsImport.apply_import(t, 1, [
                 {postponed.board, "1-0"},
                 {other.board, "1-0"}
               ])

      assert board == postponed.board
      assert Repo.reload!(postponed).result == "*"
      assert Repo.reload!(other).result == ""
    end
  end

  describe "Keizer" do
    test "a postponed game is scored as the draw it stands for" do
      white = %{id: 1, start_round: 1}
      game = %{round: 1, white_id: 1, black_id: 2, result: "*"}
      values = %{1 => 40, 2 => 30}

      assert %{class: :draw, points: 15.0} =
               Keizer.score_round(white, 1, %{1 => [game]}, %{}, values)
    end
  end
end
