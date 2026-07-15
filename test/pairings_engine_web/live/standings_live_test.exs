defmodule PairingsEngineWeb.StandingsLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Round, Pairing}

  setup :register_and_log_in_user

  test "the overall Print button links to the (round-less) standings print document", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Standings Print Test", "type" => "swiss"})

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")

    assert html =~ ~s(href="/t/#{tournament.id}/print/standings")
    assert html =~ ~s(target="_blank")
  end

  test "shows a public standings link pointing at the tournament's public slug", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Public Link Test", "type" => "swiss"})

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")

    assert tournament.public_slug
    assert html =~ ~s(href="/p/#{tournament.public_slug}/standings")
    assert html =~ "Public standings link"
  end

  describe "Extra points (SWAR parity #12 XtPts) columns" do
    test "XtPts/Total columns are hidden while count_extra_points is off (the default)", %{
      conn: conn,
      scope: scope
    } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "Extra Points Off", "type" => "swiss"})

      {:ok, _p} =
        Tournaments.create_player(tournament.id, %{"name" => "Alice", "extra_points" => "1.0"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")

      refute html =~ "XtPts"
      refute html =~ "Total"
    end

    test "XtPts/Total columns appear once count_extra_points is on", %{conn: conn, scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "Extra Points On",
          "type" => "swiss",
          "count_extra_points" => "true"
        })

      {:ok, _p} =
        Tournaments.create_player(tournament.id, %{"name" => "Alice", "extra_points" => "1.5"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")

      assert html =~ "XtPts"
      assert html =~ "Total"
      assert html =~ "1.5"
    end
  end

  describe "Manual ranking (SWAR parity #23)" do
    defp two_player_tournament(scope) do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "Manual Ranking Live Test",
          "type" => "swiss"
        })

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

    test "no banner and no controls while manual_ranking is off", %{conn: conn, scope: scope} do
      {tournament, _a, _b, _pairing} = two_player_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")

      refute html =~ "Manual ranking is ON"
      assert html =~ "Enable manual ranking"
      refute html =~ "Disable manual ranking"
    end

    test "enabling seeds manual_rank from the computed order and shows the banner", %{
      conn: conn,
      scope: scope
    } do
      {tournament, a, b, _pairing} = two_player_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/standings")

      html = lv |> element("button", "Enable manual ranking") |> render_click()
      render(lv)

      assert html =~ "Manual ranking is ON"
      refute html =~ "may no longer match"
      assert Repo.reload!(a).manual_rank == 1
      assert Repo.reload!(b).manual_rank == 2
    end

    test "moving a player up/down reorders the table", %{conn: conn, scope: scope} do
      {tournament, a, b, _pairing} = two_player_tournament(scope)
      {:ok, tournament} = Tournaments.enable_manual_ranking(tournament)

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")
      # Alice leads (rank 1) initially.
      assert html =~ ~r/Alice.*Bob/s

      html =
        lv
        |> element("button[phx-value-player_id='#{b.id}'][phx-value-direction='up']")
        |> render_click()

      render(lv)

      assert html =~ ~r/Bob.*Alice/s
      assert Repo.reload!(b).manual_rank == 1
      assert Repo.reload!(a).manual_rank == 2
    end

    test "a result change after seeding shows the stale banner and a re-seed button", %{
      conn: conn,
      scope: scope
    } do
      {tournament, _a, _b, pairing} = two_player_tournament(scope)
      {:ok, tournament} = Tournaments.enable_manual_ranking(tournament)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/standings")

      Tournaments.update_pairing_result(pairing, "0-1")
      html = render(lv)

      assert html =~ "may no longer match"
      assert html =~ "Re-seed from current order"

      html = lv |> element("button", "Re-seed from current order") |> render_click()
      render(lv)

      refute html =~ "may no longer match"
      assert tournament.id
    end

    test "disabling hides the banner and controls again", %{conn: conn, scope: scope} do
      {tournament, _a, _b, _pairing} = two_player_tournament(scope)
      {:ok, tournament} = Tournaments.enable_manual_ranking(tournament)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/standings")

      html = lv |> element("button", "Disable manual ranking") |> render_click()
      render(lv)

      refute html =~ "Manual ranking is ON"
      refute Tournaments.get_authorized_tournament!(scope, tournament.id).manual_ranking
    end
  end
end
