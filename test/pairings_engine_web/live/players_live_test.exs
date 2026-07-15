defmodule PairingsEngineWeb.PlayersLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Fide.FidePlayer
  alias PairingsEngine.Kbsb.KbsbPlayer

  setup :register_and_log_in_user

  test "print player list / player cards links open the roster-wide documents in a new tab", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Players Print Test", "type" => "swiss"})

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

    assert html =~ ~s(href="/t/#{tournament.id}/print/players")
    assert html =~ ~s(href="/t/#{tournament.id}/print/cards")
    assert html =~ "Print player list"
    assert html =~ "Print player cards"
    assert html =~ ~s(target="_blank")
  end

  test "the FIDE database tab is hidden once inside a tournament", %{conn: conn, scope: scope} do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "No FIDE Tab Here", "type" => "swiss"})

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

    refute html =~ ~s(href="/fide")
  end

  test "Ctrl+I hint and hook are wired on the page header, so the shortcut works even with zero players",
       %{
         conn: conn,
         scope: scope
       } do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Empty Roster", "type" => "swiss"})

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

    assert html =~ ~s(phx-hook="AddPlayerShortcut")
    assert html =~ "Ctrl+I"
  end

  describe "player registration modal (double-click to edit)" do
    setup %{scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "Modal Test", "type" => "swiss"})

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

    test "Cancel closes the modal via close_edit", %{
      conn: conn,
      tournament: tournament,
      player: player
    } do
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

    test "a category not in the tournament's category list is preserved as a selectable option",
         %{
           conn: conn,
           scope: scope
         } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "Cat Test",
          "type" => "swiss",
          "categories" => ["U18", "U20"]
        })

      {:ok, player} =
        Tournaments.create_player(tournament.id, %{"name" => "Bob", "category" => "Legacy"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      html = render_click(lv, "edit_player", %{"id" => to_string(player.id)})

      assert html =~ ~s(value="Legacy")
      assert html =~ "Legacy"
    end
  end

  describe "players card modal (right-click)" do
    setup %{scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "Card Modal Test", "type" => "swiss"})

      {:ok, player} = Tournaments.create_player(tournament.id, %{"name" => "Carol"})
      %{tournament: tournament, player: player}
    end

    test "does not rely on onclick stopPropagation either", %{
      conn: conn,
      tournament: tournament,
      player: player
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      html = render_click(lv, "show_card", %{"id" => to_string(player.id)})
      assert html =~ "<h2>Players Card</h2>"
      refute html =~ "stopPropagation"
      assert html =~ ~s(phx-click-away="close_card")
    end

    test "Exit closes the card via close_card", %{
      conn: conn,
      tournament: tournament,
      player: player
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "show_card", %{"id" => to_string(player.id)})
      html = lv |> element("button", "Exit") |> render_click()

      refute html =~ "<h2>Players Card</h2>"
      refute html =~ ~s(phx-click-away="close_card")
    end
  end

  describe "KBSB autofill (add-player form)" do
    setup %{scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "KBSB Add Test",
          "type" => "swiss",
          "start_date" => "2026-07-15"
        })

      Repo.insert!(%KbsbPlayer{
        national_id: "12345",
        last_name: "Peeters",
        first_name: "Jan",
        national_rating: 1850,
        fide_id: nil,
        club_number: 42,
        club_name: "KSK Antwerpen",
        federation: "VSF",
        birth_year: 1990
      })

      %{tournament: tournament}
    end

    test "entering a known national id fills national rating and other blank fields", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "add", %{})
      html = render_change(lv, "lookup_kbsb_add", %{"player" => %{"national_id" => "12345"}})

      assert html =~ ~s(value="1850")
      assert html =~ ~s(value="VSF")
      assert html =~ ~s(value="1990")
      assert html =~ ~s(value="KSK Antwerpen")
      assert html =~ "Peeters, Jan"
    end

    test "an unknown national id leaves the form untouched", %{conn: conn, tournament: tournament} do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "add", %{})
      html = render_change(lv, "lookup_kbsb_add", %{"player" => %{"national_id" => "no-such-id"}})

      refute html =~ "Peeters"
    end

    test "picking a FIDE search result also fills in the matching KBSB row by FIDE id", %{
      conn: conn,
      tournament: tournament
    } do
      Repo.insert!(%FidePlayer{
        fide_id: 555_555,
        name: "Peeters, Jan",
        federation: "BEL",
        birth_year: 1990,
        title: "",
        standard_rating: 1900
      })

      Repo.update_all(
        from(k in KbsbPlayer, where: k.national_id == "12345"),
        set: [fide_id: 555_555]
      )

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "add", %{})
      render_change(lv, "search", %{"q" => "555555"})
      html = render_click(lv, "pick", %{"fide-id" => "555555"})

      # FIDE fields...
      assert html =~ ~s(value="555555")
      assert html =~ ~s(value="1900")
      # ...and the cross-referenced KBSB fields.
      assert html =~ ~s(value="12345")
      assert html =~ ~s(value="1850")
      assert html =~ ~s(value="KSK Antwerpen")
    end
  end

  describe "KBSB autofill (edit modal)" do
    setup %{scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "KBSB Edit Test", "type" => "swiss"})

      {:ok, player} =
        Tournaments.create_player(tournament.id, %{"name" => "Alice", "national_id" => "12345"})

      Repo.insert!(%KbsbPlayer{
        national_id: "12345",
        last_name: "Peeters",
        first_name: "Jan",
        national_rating: 1850,
        fide_id: 555_555,
        club_number: 42,
        club_name: "KSK Antwerpen",
        federation: "VSF",
        birth_year: 1990
      })

      %{tournament: tournament, player: player}
    end

    test "the KBSB refresh button fills national rating, club, federation, birth year and fide id",
         %{
           conn: conn,
           tournament: tournament,
           player: player
         } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(player.id)})
      html = lv |> element("button", "KBSB") |> render_click()

      assert html =~ ~s(value="1850")
      assert html =~ ~s(value="VSF")
      assert html =~ ~s(value="KSK Antwerpen")
      assert html =~ ~s(value="1990")
      assert html =~ ~s(value="555555")
    end

    test "does not clobber an existing FIDE id already on the form", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, other} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Bob",
          "national_id" => "12345",
          "fide_id" => "9",
          "fide_rating" => "1000"
        })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(other.id)})
      html = lv |> element("button", "KBSB") |> render_click()

      # The pre-existing FIDE id (9) wins — KBSB only fills FIDE id when blank.
      assert html =~ ~s(value="9")
      refute html =~ ~s(value="555555")
    end

    test "shows an error when the National ID field is blank", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, blank} = Tournaments.create_player(tournament.id, %{"name" => "NoId"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(blank.id)})
      html = lv |> element("button", "KBSB") |> render_click()

      assert html =~ "Enter a National ID first"
    end

    test "shows an error when no KBSB row matches", %{conn: conn, tournament: tournament} do
      {:ok, unknown} =
        Tournaments.create_player(tournament.id, %{"name" => "Ghost", "national_id" => "no-match"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(unknown.id)})
      html = lv |> element("button", "KBSB") |> render_click()

      assert html =~ "No matching KBSB player found"
    end
  end

  describe "bulk rating refresh (Refresh ratings button)" do
    setup %{scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "Refresh Test", "type" => "swiss"})

      %{tournament: tournament}
    end

    test "no players registered shows the empty-diff message", %{conn: conn, tournament: tournament} do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      html = lv |> element("button", "Refresh ratings") |> render_click()

      assert html =~ "Everything up to date"
      assert html =~ "0 players checked"
    end

    test "shows the diff table and applies changes on Apply", %{conn: conn, tournament: tournament} do
      {:ok, player} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Alice",
          "fide_id" => "555555",
          "fide_rating" => "1900"
        })

      Repo.insert!(%FidePlayer{
        fide_id: 555_555,
        name: "Alice",
        federation: "BEL",
        title: "IM",
        standard_rating: 2100
      })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      html = lv |> element("button", "Refresh ratings") |> render_click()

      assert html =~ "FIDE rating"
      assert html =~ "1900"
      assert html =~ "2100"
      assert html =~ "Title"
      assert html =~ "1 player checked"
      assert html =~ "1 change"

      lv |> element("button", "Apply") |> render_click()
      # This click both writes (via RatingRefresh.apply/2) and broadcasts —
      # synchronize before asserting so the reload always lands before we look.
      html = render(lv)

      refute html =~ "phx-click-away=\"close_rating_refresh\""

      updated = Tournaments.get_player!(player.id)
      assert updated.fide_rating == 2100
      assert updated.title == "IM"
    end

    test "Cancel closes the modal without writing anything", %{conn: conn, tournament: tournament} do
      {:ok, player} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Bob",
          "fide_id" => "42",
          "fide_rating" => "1500"
        })

      Repo.insert!(%FidePlayer{fide_id: 42, name: "Bob", standard_rating: 1800})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      lv |> element("button", "Refresh ratings") |> render_click()
      html = lv |> element("button", "Cancel") |> render_click()

      refute html =~ "phx-click-away=\"close_rating_refresh\""
      assert Tournaments.get_player!(player.id).fide_rating == 1500
    end
  end

  describe "setup-completion gate" do
    test "adding a player is blocked, with a banner, when the tournament is missing a start date",
         %{conn: conn, scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "No Start Date", "type" => "swiss"})

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

      assert html =~ "Finish the tournament setup"
      assert html =~ ~s(href="/t/#{tournament.id}/settings")

      button = lv |> element("button", "Add player")
      assert render(button) =~ "disabled"

      html = render_click(lv, "add", %{})
      assert html =~ "Finish the tournament setup"
      refute html =~ ~s(name="player[name]")

      html = render_click(lv, "save", %{"player" => %{"name" => "Sneaky"}})
      assert html =~ "Finish the tournament setup"
      assert Tournaments.list_players(tournament.id) == []
    end

    test "adding a player is allowed once the tournament setup is complete", %{
      conn: conn,
      scope: scope
    } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "Complete Setup",
          "type" => "swiss",
          "start_date" => "2026-07-15"
        })

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

      refute html =~ "Finish the tournament setup"

      button = lv |> element("button", "Add player")
      refute render(button) =~ "disabled"

      html = render_click(lv, "add", %{})
      assert html =~ ~s(name="player[name]")

      html = lv |> form("form", %{"player" => %{"name" => "New Player"}}) |> render_submit()

      assert html =~ "New Player"

      # create_player broadcasts :players on the tournament's topic, which
      # this `lv` is subscribed to — drain the self-broadcast before
      # teardown (same race as the other PlayersLive save tests above).
      render(lv)

      assert Enum.any?(Tournaments.list_players(tournament.id), &(&1.name == "New Player"))
    end
  end
end
