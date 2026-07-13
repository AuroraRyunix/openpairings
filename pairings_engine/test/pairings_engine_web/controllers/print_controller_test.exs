defmodule PairingsEngineWeb.PrintControllerTest do
  use PairingsEngineWeb.ConnCase

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Round, Pairing}

  setup :register_and_log_in_user

  # 4 players, 2 rounds, mirrors the Standings fixture:
  #   R1: A (w) 1-0 B    C (w) ½-½ D
  #   R2: C (w) 0-1 A    B (w) 1-0 D
  # After R1: A=1, C=0.5, D=0.5, B=0
  # After R2: A=2, B=1,  C=0.5, D=0.5
  defp fixture(scope) do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Print Test", "type" => "swiss", "rounds_count" => "3"})

    [a, b, c, d] =
      for {name, rating, number} <- [{"A", 2000, 1}, {"B", 1800, 2}, {"C", 1700, 3}, {"D", 1600, 4}] do
        Repo.insert!(%Player{
          tournament_id: tournament.id,
          name: name,
          fide_rating: rating,
          pairing_number: number
        })
      end

    r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})
    r2 = Repo.insert!(%Round{tournament_id: tournament.id, number: 2, status: "finished"})

    Repo.insert!(%Pairing{round_id: r1.id, board: 1, white_player_id: a.id, black_player_id: b.id, result: "1-0"})
    Repo.insert!(%Pairing{round_id: r1.id, board: 2, white_player_id: c.id, black_player_id: d.id, result: "1/2-1/2"})
    Repo.insert!(%Pairing{round_id: r2.id, board: 1, white_player_id: c.id, black_player_id: a.id, result: "0-1"})
    Repo.insert!(%Pairing{round_id: r2.id, board: 2, white_player_id: b.id, black_player_id: d.id, result: "1-0"})

    {tournament, %{a: a, b: b, c: c, d: d}}
  end

  # A Keizer tournament, one round paired — enough to exercise
  # PairingsEngine.Keizer.standings/1's rank/value/points/raw_points shape
  # from the print document.
  defp keizer_fixture(scope) do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Keizer Print Test",
        "type" => "swiss",
        "pairing_system" => "keizer",
        "rounds_count" => "3",
        "tiebreaks" => ["BH", "SB"]
      })

    for {name, rating} <- [{"A", 2000}, {"B", 1900}, {"C", 1800}, {"D", 1700}] do
      {:ok, _} = Tournaments.create_player(tournament.id, %{"name" => name, "fide_rating" => to_string(rating)})
    end

    {:ok, _round} = PairingsEngine.Pairing.pair_next_round(tournament)

    tournament
  end

  describe "pairing_list/2" do
    test "?round=1 renders round 1's board pairings, not round 2's", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/pairings?round=1")

      html = html_response(conn, 200)
      assert html =~ "Pairings — round 1"
      assert html =~ "A"
      assert html =~ "B"
      # Round 2's pairing (C vs A on board 1) should not appear as a row —
      # C only appears paired with D on round 1's board 2.
      refute html =~ "round 2"
    end

    test "?round=2 renders round 2's board pairings", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/pairings?round=2")

      html = html_response(conn, 200)
      assert html =~ "Pairings — round 2"
    end

    test "omitting ?round defaults to round 1", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/pairings")

      assert html_response(conn, 200) =~ "Pairings — round 1"
    end

    test "an unpaired round 404s", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/pairings?round=3")

      assert conn.status == 404
    end

    test "a board involving a player with a fixed_board override is annotated", %{conn: conn, scope: scope} do
      {tournament, %{a: a}} = fixture(scope)
      a |> Ecto.Changeset.change(fixed_board: 5) |> Repo.update!()

      conn = get(conn, ~p"/t/#{tournament.id}/print/pairings?round=1")

      html = html_response(conn, 200)
      assert html =~ "(table 5)"
    end

    test "a board with no fixed_board players has no annotation", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/pairings?round=2")

      refute html_response(conn, 200) =~ "(table"
    end
  end

  describe "standings/2" do
    test "without ?round, prints current (overall) standings", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/standings")

      html = html_response(conn, 200)
      assert html =~ "Standings after round 2"
      # A leads overall with 2.0 points after both rounds.
      assert html =~ ~r/A.*?<strong>2\.0<\/strong>/s
    end

    test "?round=1 prints standings as they stood after round 1 only", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/standings?round=1")

      html = html_response(conn, 200)
      assert html =~ "Standings after round 1"
      # After round 1 alone: A has 1.0 (not 2.0, which only holds once
      # round 2's result is counted).
      assert html =~ ~r/A.*?<strong>1\.0<\/strong>/s
      refute html =~ ~r/A.*?<strong>2\.0<\/strong>/s
    end

    test "?round=2 matches the overall standings once all paired rounds are included", %{
      conn: conn,
      scope: scope
    } do
      {tournament, _players} = fixture(scope)

      overall = get(conn, ~p"/t/#{tournament.id}/print/standings") |> html_response(200)
      as_of_2 = get(conn, ~p"/t/#{tournament.id}/print/standings?round=2") |> html_response(200)

      assert overall == as_of_2
    end

    test "a round that hasn't been paired yet 404s", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/standings?round=3")

      assert conn.status == 404
    end

    test "a tournament with no categories renders byte-identical to before (no Category column/tables)", %{
      conn: conn,
      scope: scope
    } do
      {tournament, _players} = fixture(scope)

      html = get(conn, ~p"/t/#{tournament.id}/print/standings") |> html_response(200)

      refute html =~ "Category"
      refute html =~ ">Category:"
    end

    test "a tournament with categories gets a Category column and one table per category", %{
      conn: conn,
      scope: scope
    } do
      {tournament, %{a: a, b: b, c: c, d: d}} = fixture(scope)

      {:ok, tournament} = Tournaments.update_tournament(tournament, %{"categories" => ["Open", "Women"]})
      a |> Ecto.Changeset.change(category: "Open") |> Repo.update!()
      b |> Ecto.Changeset.change(category: "Women") |> Repo.update!()
      c |> Ecto.Changeset.change(category: "Open") |> Repo.update!()
      Ecto.Changeset.change(d) |> Repo.update!()

      html = get(conn, ~p"/t/#{tournament.id}/print/standings") |> html_response(200)

      assert html =~ "<th>Category</th>"
      assert html =~ "Category: Open"
      assert html =~ "Category: Women"

      # D has no category, so it appears in the main table but in neither
      # category sub-table.
      [_main, rest] = String.split(html, "Category: Open", parts: 2)
      [open_table, women_and_after] = String.split(rest, "Category: Women", parts: 2)
      assert open_table =~ "A"
      assert open_table =~ "C"
      refute open_table =~ ">B<"
      assert women_and_after =~ "B"
      refute women_and_after =~ ">D<"
    end

    test "a keizer tournament prints the ladder table (Value/Keizer pts/Score), not FIDE points/tiebreak columns", %{
      conn: conn,
      scope: scope
    } do
      tournament = keizer_fixture(scope)

      html = get(conn, ~p"/t/#{tournament.id}/print/standings") |> html_response(200)

      assert html =~ "<th class=\"num\">Value</th>"
      assert html =~ "<th class=\"num\">Keizer pts</th>"
      assert html =~ "<th class=\"num\">Score</th>"

      # Not the FIDE-tiebreak standings table: no "Pts" column header, and
      # none of the tournament's configured tiebreak codes as a column.
      refute html =~ "<th class=\"num\">Pts</th>"
      refute html =~ "<th class=\"num\">BH</th>"
      refute html =~ "<th class=\"num\">SB</th>"
    end
  end

  describe "result_cards/2" do
    test "?round=1 renders one card per board of round 1, skipping byes", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/results?round=1")

      html = html_response(conn, 200)
      assert html =~ "Result cards — round 1"
      assert html =~ "A"
      assert html =~ "B"
      assert html =~ "C"
      assert html =~ "D"
      assert html =~ "1 &ndash; 0"
      assert html =~ "other: ............"
    end

    test "?round=2 renders round 2's cards, not round 1's", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/results?round=2")

      assert html_response(conn, 200) =~ "Result cards — round 2"
    end

    test "omitting ?round defaults to the latest paired round", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/results")

      # Fixture has rounds 1 and 2 paired — the latest paired round is 2.
      assert html_response(conn, 200) =~ "Result cards — round 2"
    end

    test "an unpaired round 404s", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/results?round=3")

      assert conn.status == 404
    end

    test "a bye board is skipped", %{conn: conn, scope: scope} do
      {tournament, %{a: a}} = fixture(scope)
      r3 = Repo.insert!(%Round{tournament_id: tournament.id, number: 3, status: "playing"})
      Repo.insert!(%Pairing{round_id: r3.id, board: 1, white_player_id: a.id, black_player_id: nil, result: "bye"})

      conn = get(conn, ~p"/t/#{tournament.id}/print/results?round=3")

      html = html_response(conn, 200)
      refute html =~ ~s(class="result-card")
    end

    test "a board involving a player with a fixed_board override is annotated", %{conn: conn, scope: scope} do
      {tournament, %{a: a}} = fixture(scope)
      a |> Ecto.Changeset.change(fixed_board: 5) |> Repo.update!()

      conn = get(conn, ~p"/t/#{tournament.id}/print/results?round=1")

      html = html_response(conn, 200)
      assert html =~ "(table 5)"
    end

    # Eight compact cards per A4 page (down from three tall ones) — see
    # `@result_cards_css`: `.result-card:nth-child(8n)` forces the page
    # break every 8th card instead of every 3rd.
    test "cards are laid out eight to a page", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/results?round=1")

      html = html_response(conn, 200)
      assert html =~ "nth-child(8n)"
    end
  end

  describe "crosstable/2" do
    test "renders one row per player with rank, name and points", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/crosstable")

      html = html_response(conn, 200)
      assert html =~ "Cross table"
      assert html =~ "A"
      assert html =~ "B"
      assert html =~ "C"
      assert html =~ "D"
      # A won both games, so total points after round 2 is 2.0.
      assert html =~ ~r/A.*?<strong>2\.0<\/strong>/s
    end

    test "shows a compact result code once a result exists", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/crosstable")

      html = html_response(conn, 200)
      # A (pairing_number 1) beat B (pairing_number 2) as white in round 1 —
      # B's row shows a loss ("0") against opponent #1 as black.
      assert html =~ "1b0"
    end
  end

  describe "crosstable/2 — round robin players×players grid" do
    # Round-robin tournament, `cycles` cycles, 4 rated players (Alice=2000,
    # Bob=1900, Carol=1800, Dave=1700 -> frozen pairing numbers 1..4). Round
    # 1 is the FIDE Berger table's {1,4} (Alice white vs Dave) and {2,3}
    # (Bob white vs Carol) — see PairingsEngine.RoundRobinTest, which
    # verifies this exact table against the published FIDE N=4 annex.
    defp round_robin_fixture(scope, cycles) do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "RR Print Test",
          "type" => "swiss",
          "pairing_system" => "round_robin",
          "rr_cycles" => to_string(cycles),
          "rounds_count" => "12"
        })

      players =
        for {name, rating} <- [{"Alice", 2000}, {"Bob", 1900}, {"Carol", 1800}, {"Dave", 1700}], into: %{} do
          {:ok, p} = Tournaments.create_player(tournament.id, %{"name" => name, "fide_rating" => to_string(rating)})
          {name, p}
        end

      {tournament, players}
    end

    # Pairs the next round and enters `results` — a `%{{white_name,
    # black_name} => result}` map matched against the round's actual
    # pairings by player id (order-independent lookup, since which pair
    # lands on which board isn't asserted here).
    defp pair_and_score(tournament, players_by_name, results) do
      {:ok, round} = PairingsEngine.Pairing.pair_next_round(tournament)
      round = Repo.preload(round, :pairings)
      by_id = Map.new(players_by_name, fn {name, p} -> {p.id, name} end)

      Enum.each(round.pairings, fn pairing ->
        white_name = Map.fetch!(by_id, pairing.white_player_id)
        black_name = Map.fetch!(by_id, pairing.black_player_id)

        case Map.get(results, {white_name, black_name}) do
          nil -> :ok
          result -> {:ok, _} = Tournaments.update_pairing_result(pairing, result)
        end
      end)

      round
    end

    test "single round robin: grid headers are pairing numbers, cells show each side's result", %{
      conn: conn,
      scope: scope
    } do
      {tournament, players} = round_robin_fixture(scope, 1)

      pair_and_score(tournament, players, %{
        {"Alice", "Dave"} => "1-0",
        {"Bob", "Carol"} => "1/2-1/2"
      })

      html = get(conn, ~p"/t/#{tournament.id}/print/crosstable") |> html_response(200)

      assert html =~ "Cross table"
      assert html =~ ~s(class="crosstable rr-crosstable")

      # Column headers are the four players' pairing numbers, 1..4.
      for n <- 1..4, do: assert(html =~ "<th class=\"num\">#{n}</th>")

      # Diagonal is hatched out, once per player (the CSS block itself also
      # mentions "rr-diag" once in its selector, so match the cell's actual
      # class attribute rather than the bare substring).
      assert (html |> String.split(~s(class="num rr-diag")) |> length()) - 1 == 4

      # Alice (row) beat Dave (col) as White -> "1" in Alice's row under
      # Dave's column; from Dave's row the same game reads as a loss ("0").
      assert html =~ ~r/Alice<\/strong><\/td>.*?<td class="num">1<\/td>/s
      assert html =~ ~r/Dave<\/strong><\/td>.*?<td class="num">0<\/td>/s

      # Bob vs Carol drew -> "½" appears from both sides.
      assert html =~ "½"
    end

    test "double round robin shows both cycles' results space-separated, first cycle first", %{
      conn: conn,
      scope: scope
    } do
      {tournament, players} = round_robin_fixture(scope, 2)

      # Round 1 (cycle 1): Alice white beats Dave.
      pair_and_score(tournament, players, %{{"Alice", "Dave"} => "1-0", {"Bob", "Carol"} => "1-0"})
      # Round 2.
      pair_and_score(tournament, players, %{{"Dave", "Carol"} => "1-0", {"Alice", "Bob"} => "1-0"})
      # Round 3.
      pair_and_score(tournament, players, %{{"Bob", "Dave"} => "1-0", {"Carol", "Alice"} => "1-0"})
      # Round 4 (cycle 2, colours reversed vs round 1): Dave white vs Alice
      # black — Alice wins again, this time as Black.
      pair_and_score(tournament, players, %{{"Dave", "Alice"} => "0-1", {"Carol", "Bob"} => "0-1"})

      html = get(conn, ~p"/t/#{tournament.id}/print/crosstable") |> html_response(200)

      # Alice beat Dave in both cycle 1 (as White) and cycle 2 (as Black) ->
      # her cell against Dave shows both results, cycle 1 first.
      assert html =~ ~r/Alice<\/strong><\/td>.*?<td class="num">1 1<\/td>/s
      # Dave lost both -> "0 0" from his row.
      assert html =~ ~r/Dave<\/strong><\/td>.*?<td class="num">0 0<\/td>/s
    end

    test "a forfeit shows +/- rather than a played result", %{conn: conn, scope: scope} do
      {tournament, players} = round_robin_fixture(scope, 1)

      pair_and_score(tournament, players, %{{"Alice", "Dave"} => "1-0FF", {"Bob", "Carol"} => "1-0"})

      html = get(conn, ~p"/t/#{tournament.id}/print/crosstable") |> html_response(200)

      assert html =~ ~r/Alice<\/strong><\/td>.*?<td class="num">\+<\/td>/s
      assert html =~ ~r/Dave<\/strong><\/td>.*?<td class="num">-<\/td>/s
    end

    test "an odd player count's structural bye isn't a column, but its points still count", %{
      conn: conn,
      scope: scope
    } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "RR Odd Print Test",
          "type" => "swiss",
          "pairing_system" => "round_robin",
          "rr_cycles" => "1",
          "rounds_count" => "12"
        })

      players =
        for {name, rating} <- [
              {"Alice", 2000},
              {"Bob", 1900},
              {"Carol", 1800},
              {"Dave", 1700},
              {"Eve", 1600}
            ],
            into: %{} do
          {:ok, p} = Tournaments.create_player(tournament.id, %{"name" => name, "fide_rating" => to_string(rating)})
          {name, p}
        end

      # Alice (highest rated, pairing number 1) sits out round 1's
      # structural bye (see PairingsEngine.RoundRobinTest) — no result to
      # enter for her.
      {:ok, round} = PairingsEngine.Pairing.pair_next_round(tournament)
      round = Repo.preload(round, :pairings)
      assert length(round.pairings) == 2

      by_id = Map.new(players, fn {name, p} -> {p.id, name} end)
      results = %{{"Bob", "Carol"} => "1-0", {"Dave", "Eve"} => "1-0"}

      Enum.each(round.pairings, fn pairing ->
        key = {Map.fetch!(by_id, pairing.white_player_id), Map.fetch!(by_id, pairing.black_player_id)}
        if result = results[key], do: Tournaments.update_pairing_result(pairing, result)
      end)

      html = get(conn, ~p"/t/#{tournament.id}/print/crosstable") |> html_response(200)

      # Only 5 real players get a column — no 6th column for the phantom
      # player that the odd-count bye mechanism uses internally.
      assert html =~ "<th class=\"num\">5</th>"
      refute html =~ "<th class=\"num\">6</th>"

      # Alice played no game this round (she had the bye), so her total is
      # exactly the bye's point value (0.0, "requested-zero") — the bye
      # doesn't show as a column, but it's still folded into her Pts total.
      assert html =~ ~r/Alice<\/strong><\/td>.*?<strong>0\.0<\/strong>/s
    end
  end

  describe "player_list/2 and player_cards/2" do
    test "player_list renders the roster regardless of rounds", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/players")

      html = html_response(conn, 200)
      assert html =~ "Registered players (4)"
    end

    test "player_cards renders one card per player with the full round list", %{conn: conn, scope: scope} do
      {tournament, _players} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/print/cards")

      html = html_response(conn, 200)
      assert html =~ "Player cards"
      # rounds_count is 3 on the fixture tournament, so each card lists 3 rows.
      assert html =~ ~r/class="num">3<\/td>/
    end
  end
end
