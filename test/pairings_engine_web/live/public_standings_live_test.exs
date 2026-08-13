defmodule PairingsEngineWeb.PublicStandingsLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Round, Pairing}

  # No login — the public page needs no `register_and_log_in_user` setup.
  defp two_player_tournament do
    {:ok, tournament} =
      Tournaments.create_tournament(%{"name" => "Public Manual Ranking Test", "type" => "swiss"})

    {:ok, tournament} = Tournaments.set_public_pages(tournament, true)

    a = Repo.insert!(%Player{tournament_id: tournament.id, name: "Alice", fide_rating: 2000})
    b = Repo.insert!(%Player{tournament_id: tournament.id, name: "Bob", fide_rating: 1900})

    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})

    pairing =
      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: a.id,
        black_player_id: b.id,
        result: "1-0"
      })

    {tournament, a, b, pairing}
  end

  test "shows the tournament's standings without login", %{conn: conn} do
    {tournament, _a, _b, _pairing} = two_player_tournament()

    {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/standings")

    assert html =~ "Alice"
    assert html =~ "Bob"
  end

  describe "minimal public layout (no app chrome)" do
    test "has no tournament tabs, accent picker, or sign-in link - just the brand and theme switch",
         %{conn: conn} do
      {tournament, _a, _b, _pairing} = two_player_tournament()

      {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/standings")

      refute html =~ "accent-picker"
      refute html =~ "topbar-signin"
      assert html =~ "theme-picker"
      assert html =~ "OpenPairings"
    end

    test "shows the arbiter and tempo when set, nothing extra when blank", %{conn: conn} do
      {tournament, _a, _b, _pairing} = two_player_tournament()

      {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/standings")
      refute html =~ "Arbiter:"
      refute html =~ "Tempo:"

      {:ok, tournament} =
        Tournaments.update_tournament(tournament, %{
          "chief_arbiter" => "Cornet, Luc",
          "rate_of_play" => "90 min + 30 sec/move"
        })

      {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/standings")
      assert html =~ "Arbiter: Cornet, Luc"
      assert html =~ "Tempo: 90 min + 30 sec/move"
    end
  end

  describe "Category column — shows on the public page too, whenever the tournament has >= 1 category" do
    test "hidden when the tournament has no categories defined", %{conn: conn} do
      {tournament, _a, _b, _pairing} = two_player_tournament()

      {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/standings")

      refute html =~ "<th>Category</th>"
    end

    test "shows the assigned category per player, dash for unassigned", %{conn: conn} do
      {:ok, tournament} =
        Tournaments.create_tournament(%{
          "name" => "Public Categories Test",
          "type" => "swiss",
          "categories" => ["Open", "U18"]
        })

      {:ok, tournament} = Tournaments.set_public_pages(tournament, true)

      Repo.insert!(%Player{
        tournament_id: tournament.id,
        name: "Alice",
        fide_rating: 2000,
        category: "Open"
      })

      Repo.insert!(%Player{tournament_id: tournament.id, name: "Bob", fide_rating: 1900})

      {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/standings")

      assert html =~ "<th>Category</th>"
      assert html =~ "Open"
    end

    test "shows on the Keizer ladder too", %{conn: conn} do
      {:ok, tournament} =
        Tournaments.create_tournament(%{
          "name" => "Public Keizer Categories Test",
          "type" => "swiss",
          "pairing_system" => "keizer",
          "categories" => ["Open"]
        })

      {:ok, tournament} = Tournaments.set_public_pages(tournament, true)

      Repo.insert!(%Player{
        tournament_id: tournament.id,
        name: "Alice",
        fide_rating: 2000,
        category: "Open"
      })

      {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/standings")

      assert html =~ "<th>Category</th>"
      assert html =~ "Open"
    end
  end

  describe "Manual ranking (SWAR parity #23)" do
    test "no banner while manual_ranking is off", %{conn: conn} do
      {tournament, _a, _b, _pairing} = two_player_tournament()

      {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/standings")

      refute html =~ "Manual ranking is ON"
    end

    test "shows the banner (read-only, no controls) once manual ranking is on", %{conn: conn} do
      {tournament, _a, _b, _pairing} = two_player_tournament()
      {:ok, tournament} = Tournaments.enable_manual_ranking(tournament)

      {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/standings")

      assert html =~ "Manual ranking is ON"
      refute html =~ "phx-click=\"manual_move\""
      refute html =~ "Re-seed from current order"
    end

    test "shows the stale note once a result changes after seeding", %{conn: conn} do
      {tournament, _a, _b, pairing} = two_player_tournament()
      {:ok, tournament} = Tournaments.enable_manual_ranking(tournament)

      {:ok, lv, _html} = live(conn, ~p"/p/#{tournament.public_slug}/standings")

      Tournaments.update_pairing_result(pairing, "0-1")
      html = render(lv)

      assert html =~ "may no longer match"
    end
  end
end
