defmodule PairingsEngineWeb.ListDeclutterTest do
  # The Tournaments list and the Players page, decluttered: More menus that
  # show a caret and no ellipsis, a row menu instead of a row of buttons, an
  # Import menu, translated status badges, a club cell that carries its full
  # name, and the grid's instructions behind a closed disclosure.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.Tournaments

  setup :register_and_log_in_user

  @club "Koninklijke Waregemse Schaakvereniging Luctor et Emergo"

  describe "the Tournaments list" do
    test "each row has one closed More menu holding every action", %{conn: conn, scope: scope} do
      {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Row Menu", "type" => "swiss"})
      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, "#tournament-menu-#{t.id}.pe-dropdown")
      refute has_element?(lv, "#tournament-menu-#{t.id}[open]")
      # The summary is the arrow-only button: text, no ellipsis icon.
      assert has_element?(lv, "#tournament-menu-toggle-#{t.id}", "More")

      refute has_element?(
               lv,
               "#tournament-menu-toggle-#{t.id} svg, #tournament-menu-toggle-#{t.id} span[class*=hero]"
             )

      for id <- ["export", "duplicate", "handoff", "archive", "delete"] do
        assert has_element?(lv, "#tournament-menu-#{t.id} [role=menuitem]#" <> "#{id}-#{t.id}")
      end

      # Destructive one last, in danger style, after a divider.
      assert has_element?(lv, "#tournament-menu-#{t.id} hr + button.is-danger#delete-#{t.id}")
      # The name still opens the tournament.
      assert has_element?(lv, ~s(#tournament-row-#{t.id} a[href="/t/#{t.id}/players"]))
      # No loose action buttons left in the row.
      refute has_element?(lv, "#tournament-row-#{t.id} > td > button")
    end

    test "the row menu's actions still work", %{conn: conn, scope: scope} do
      {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Copy Me", "type" => "swiss"})
      {:ok, lv, _html} = live(conn, ~p"/")

      lv |> element("#duplicate-#{t.id}") |> render_click()
      assert render(lv) =~ "Copy Me"
    end

    test "the top bar is New tournament, an Import menu and Export all", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, "button.pe-btn.primary", "New tournament")
      assert has_element?(lv, "#import-menu.pe-dropdown")
      refute has_element?(lv, "#import-menu[open]")
      assert has_element?(lv, "#export-all-link")

      for id <- ["import-backup-button", "receive-handoff-button", "import-trf-button"] do
        assert has_element?(lv, "#import-menu [role=menuitem]##{id}")
      end

      # Not loose in the bar any more.
      refute has_element?(lv, ".page-header > .actions > button", "Import TRF file")
    end

    test "an import from the menu opens its form, whose file input stays mounted", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      lv |> element("#import-trf-button") |> render_click()
      assert has_element?(lv, "#trf-import-form input[type=file]")

      lv |> element("#import-backup-button") |> render_click()
      assert has_element?(lv, "#backup-import-form input[type=file]")
    end

    test "the status badge is translated", %{conn: conn, scope: scope} do
      {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Badge", "type" => "swiss"})

      {:ok, _lv, html} = live(conn, ~p"/")
      assert html =~ ~r/<span class="badge muted">\s*setup\s*<\/span>/

      conn = get(conn, ~p"/locale/nl?redirect_to=/")
      {:ok, lv, _html} = live(conn, ~p"/")
      assert has_element?(lv, "#tournament-row-#{t.id} .badge", "opstart")
      refute has_element?(lv, "#tournament-row-#{t.id} .badge", "setup")
    end
  end

  describe "the Archived table" do
    test "each archived row has the same closed More menu, destructive item last", %{
      conn: conn,
      scope: scope
    } do
      {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Shelved", "type" => "swiss"})
      {:ok, _} = Tournaments.archive_tournament(t)
      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, "#archived-tournament-menu-#{t.id}.pe-dropdown")
      refute has_element?(lv, "#archived-tournament-menu-#{t.id}[open]")
      assert has_element?(lv, "#archived-tournament-menu-toggle-#{t.id}", "More")

      for id <- ["archived-export", "unarchive", "archived-delete"] do
        assert has_element?(
                 lv,
                 "#archived-tournament-menu-#{t.id} [role=menuitem]#" <> "#{id}-#{t.id}"
               )
      end

      assert has_element?(
               lv,
               "#archived-tournament-menu-#{t.id} hr + button.is-danger#archived-delete-#{t.id}"
             )

      # No loose buttons left in the row.
      refute has_element?(lv, ~s(tr td > button[phx-click="unarchive_tournament"]))
    end

    test "Unarchive from the menu still works", %{conn: conn, scope: scope} do
      {:ok, t} =
        Tournaments.create_tournament(scope, %{"name" => "Back Again", "type" => "swiss"})

      {:ok, _} = Tournaments.archive_tournament(t)
      {:ok, lv, _html} = live(conn, ~p"/")

      lv |> element("#unarchive-#{t.id}") |> render_click()
      refute has_element?(lv, "#archived-tournament-menu-#{t.id}")
      assert has_element?(lv, "#tournament-menu-#{t.id}")
    end
  end

  describe "the Players page" do
    setup %{scope: scope} do
      {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Players", "type" => "swiss"})
      {:ok, _} = Tournaments.create_player(t.id, %{name: "Alice", club: @club})
      {:ok, t: t}
    end

    test "the More menu is the caret and the word, no ellipsis icon", %{conn: conn, t: t} do
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")

      assert has_element?(lv, "#players-more-menu > summary", "More")
      refute has_element?(lv, "#players-more-menu > summary svg")
      refute has_element?(lv, "#players-more-menu > summary [class*=ellipsis]")
    end

    test "the club cell carries the full name as its title", %{conn: conn, t: t} do
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")

      assert has_element?(lv, ~s(#players-table td[data-col=club] .club-cell[title="#{@club}"]))
    end

    test "the grid's instructions are behind a disclosure, closed by default", %{conn: conn, t: t} do
      {:ok, lv, html} = live(conn, ~p"/t/#{t.id}/players")

      assert has_element?(lv, "details#players-grid-help")
      refute has_element?(lv, "details#players-grid-help[open]")
      assert has_element?(lv, "#players-grid-help > summary#players-grid-help-toggle[aria-label]")
      assert has_element?(lv, "#players-grid-help #players-grid-keys")
      # The old always-visible paragraph above the table is gone.
      refute html =~ ~s(<p class="hint" style="padding: 12px 16px 0")
      # The Display panel is untouched.
      assert has_element?(lv, "aside.display-panel")
    end
  end
end
