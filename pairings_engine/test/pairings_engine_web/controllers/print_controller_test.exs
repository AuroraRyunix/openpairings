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
      for {name, rating} <- [{"A", 2000}, {"B", 1800}, {"C", 1700}, {"D", 1600}] do
        Repo.insert!(%Player{tournament_id: tournament.id, name: name, fide_rating: rating})
      end

    r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})
    r2 = Repo.insert!(%Round{tournament_id: tournament.id, number: 2, status: "finished"})

    Repo.insert!(%Pairing{round_id: r1.id, board: 1, white_player_id: a.id, black_player_id: b.id, result: "1-0"})
    Repo.insert!(%Pairing{round_id: r1.id, board: 2, white_player_id: c.id, black_player_id: d.id, result: "1/2-1/2"})
    Repo.insert!(%Pairing{round_id: r2.id, board: 1, white_player_id: c.id, black_player_id: a.id, result: "0-1"})
    Repo.insert!(%Pairing{round_id: r2.id, board: 2, white_player_id: b.id, black_player_id: d.id, result: "1-0"})

    {tournament, %{a: a, b: b, c: c, d: d}}
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
