defmodule PairingsEngineWeb.PlayersLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.Tournaments

  setup :register_and_log_in_user

  test "print player list / player cards links open the roster-wide documents in a new tab", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} = Tournaments.create_tournament(scope, %{"name" => "Players Print Test", "type" => "swiss"})

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

    assert html =~ ~s(href="/t/#{tournament.id}/print/players")
    assert html =~ ~s(href="/t/#{tournament.id}/print/cards")
    assert html =~ "Print player list"
    assert html =~ "Print player cards"
    assert html =~ ~s(target="_blank")
  end

  test "the FIDE database tab is hidden once inside a tournament", %{conn: conn, scope: scope} do
    {:ok, tournament} = Tournaments.create_tournament(scope, %{"name" => "No FIDE Tab Here", "type" => "swiss"})

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

    refute html =~ ~s(href="/fide")
  end

  test "Ctrl+I hint and hook are wired on the page header, so the shortcut works even with zero players", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} = Tournaments.create_tournament(scope, %{"name" => "Empty Roster", "type" => "swiss"})

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

    assert html =~ ~s(phx-hook="AddPlayerShortcut")
    assert html =~ "Ctrl+I"
  end

  describe "player registration modal (double-click to edit)" do
    setup %{scope: scope} do
      {:ok, tournament} = Tournaments.create_tournament(scope, %{"name" => "Modal Test", "type" => "swiss"})
      {:ok, player} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})
      %{tournament: tournament, player: player}
    end

    test "does not rely on onclick stopPropagation, which blocks phx-click delegation", %{
      conn: conn,
      tournament: tournament,
      player: player
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      html = lv |> element("tr[data-player-id='#{player.id}']") |> render()
      # sanity: the row exists before we push the dblclick-equivalent event
      assert html =~ "Alice"

      html = render_click(lv, "edit_player", %{"id" => to_string(player.id)})
      assert html =~ "Player registration"
      refute html =~ "stopPropagation"
      assert html =~ ~s(phx-click-away="close_edit")
    end

    test "Cancel closes the modal via close_edit", %{conn: conn, tournament: tournament, player: player} do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(player.id)})
      html = lv |> element("button", "Cancel") |> render_click()

      refute html =~ "Player registration"
    end

    test "shows a Fixed table number input instead of the old Special Table checkbox", %{
      conn: conn,
      tournament: tournament,
      player: player
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      html = render_click(lv, "edit_player", %{"id" => to_string(player.id)})

      assert html =~ "Fixed table"
      assert html =~ ~s(name="player[fixed_board]")
      refute html =~ "Special Table"
    end

    test "saving a fixed_board value round-trips it and derives special_table", %{
      conn: conn,
      tournament: tournament,
      player: player
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(player.id)})

      lv
      |> form("form", player: %{"name" => "Alice", "fixed_board" => "7"})
      |> render_submit()

      # update_player/2 broadcasts on the tournament topic and this `lv` is
      # subscribed to its own tournament (see PlayersLive's mount) —
      # render_submit/1 only waits for the direct reply to the "save" event,
      # not for that self-broadcast's handle_info reload, which lands in the
      # mailbox microseconds later and runs its own Repo query. Draining it
      # with a synchronous render/1 before the test (and this `lv`'s
      # teardown) proceeds avoids racing that query against the test process
      # supervisor killing `lv` mid-query — which, on SQLite's single-writer
      # file, can wedge the shared sandbox connection for later tests with a
      # spurious `Database busy` (see the same fix in sharing_test.exs).
      render(lv)

      updated = Tournaments.get_player!(player.id)
      assert updated.fixed_board == 7
      assert updated.special_table == true
    end

    test "the absent_rounds field accepts the forgiving grammar and normalizes it on save", %{
      conn: conn,
      tournament: tournament,
      player: player
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(player.id)})

      lv
      |> form("form", player: %{"name" => "Alice", "absent_rounds" => "2-4;1"})
      |> render_submit()

      # Same self-broadcast race as the "saving a fixed_board value" test
      # above — drain it before the test (and `lv`'s teardown) proceeds.
      render(lv)

      updated = Tournaments.get_player!(player.id)
      assert updated.absent_rounds == "1,2,3,4"
    end

    test "a category not in the tournament's category list is preserved as a selectable option", %{
      conn: conn,
      scope: scope
    } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "Cat Test",
          "type" => "swiss",
          "categories" => ["U18", "U20"]
        })

      {:ok, player} = Tournaments.create_player(tournament.id, %{"name" => "Bob", "category" => "Legacy"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      html = render_click(lv, "edit_player", %{"id" => to_string(player.id)})

      assert html =~ ~s(value="Legacy")
      assert html =~ "Legacy"
    end
  end

  describe "players card modal (right-click)" do
    setup %{scope: scope} do
      {:ok, tournament} = Tournaments.create_tournament(scope, %{"name" => "Card Modal Test", "type" => "swiss"})
      {:ok, player} = Tournaments.create_player(tournament.id, %{"name" => "Carol"})
      %{tournament: tournament, player: player}
    end

    test "does not rely on onclick stopPropagation either", %{conn: conn, tournament: tournament, player: player} do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      html = render_click(lv, "show_card", %{"id" => to_string(player.id)})
      assert html =~ "<h2>Players Card</h2>"
      refute html =~ "stopPropagation"
      assert html =~ ~s(phx-click-away="close_card")
    end

    test "Exit closes the card via close_card", %{conn: conn, tournament: tournament, player: player} do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "show_card", %{"id" => to_string(player.id)})
      html = lv |> element("button", "Exit") |> render_click()

      refute html =~ "<h2>Players Card</h2>"
      refute html =~ ~s(phx-click-away="close_card")
    end
  end
end
