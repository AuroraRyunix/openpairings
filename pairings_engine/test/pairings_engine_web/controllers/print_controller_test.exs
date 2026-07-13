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
