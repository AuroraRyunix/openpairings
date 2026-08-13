defmodule PairingsEngineWeb.ArchiveLiveTest do
  @moduledoc """
  The archive UI: the Tournaments-page panel and actions, and the read-only
  treatment inside an archived tournament.
  """
  # async: false: sequential SQLite writes plus self-broadcast/render ordering.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Tournaments}

  setup :register_and_log_in_user

  defp create_tournament(scope, attrs \\ %{}) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Archive UI Test", "type" => "swiss", "rounds_count" => "3"}, attrs)
      )

    tournament
  end

  describe "Tournaments page — archiving" do
    test "an Archive button is offered for an owned tournament", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "Archive"
      assert html =~ tournament.name
    end

    test "clicking Archive moves it out of the main list and into the Archived panel", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, lv, html} = live(conn, ~p"/")
      refute html =~ "<h2>Archived</h2>"

      html =
        lv
        |> element(~s(button[phx-click="archive_tournament"][phx-value-id="#{tournament.id}"]))
        |> render_click()

      assert html =~ "<h2>Archived</h2>"
      assert html =~ "archived"
      assert Repo.reload!(tournament).archived_at
    end

    test "Unarchive brings it back to the main list", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, _} = Tournaments.archive_tournament(tournament)

      {:ok, lv, html} = live(conn, ~p"/")
      assert html =~ "<h2>Archived</h2>"

      html =
        lv
        |> element(~s(button[phx-click="unarchive_tournament"][phx-value-id="#{tournament.id}"]))
        |> render_click()

      refute html =~ "<h2>Archived</h2>"
      refute Repo.reload!(tournament).archived_at
    end

    test "the Archived panel is absent entirely when nothing is archived", %{
      conn: conn,
      scope: scope
    } do
      create_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/")

      refute html =~ "<h2>Archived</h2>"
    end

    test "the archive panel is separate from the recycle bin, and says so", %{
      conn: conn,
      scope: scope
    } do
      archived = create_tournament(scope, %{"name" => "Archived One"})
      binned = create_tournament(scope, %{"name" => "Binned One"})
      {:ok, _} = Tournaments.archive_tournament(archived)
      {:ok, _} = Tournaments.soft_delete_tournament(binned)

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "<h2>Archived</h2>"
      assert html =~ "<h2>Recycle bin</h2>"
      assert html =~ "nothing here is ever purged automatically"
    end

    test "archiving is audit-logged", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> element(~s(button[phx-click="archive_tournament"][phx-value-id="#{tournament.id}"]))
      |> render_click()

      actions =
        tournament.id
        |> PairingsEngine.Audit.list_for_tournament()
        |> Enum.map(& &1.action)

      assert "tournament.archived" in actions
    end
  end

  describe "inside an archived tournament" do
    test "every page carries the read-only banner", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, _} = Tournaments.archive_tournament(tournament)

      for path <- [
            ~p"/t/#{tournament.id}/players",
            ~p"/t/#{tournament.id}/pairings",
            ~p"/t/#{tournament.id}/standings",
            ~p"/t/#{tournament.id}/settings"
          ] do
        {:ok, _lv, html} = live(conn, path)
        assert html =~ "This tournament is archived", "expected the banner on #{path}"
        assert html =~ "archived-banner"
      end
    end

    test "a live tournament carries no banner", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

      refute html =~ "archived-banner"
    end

    test "the Pairings page hides the pair button", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, _} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})
      {:ok, _} = Tournaments.create_player(tournament.id, %{"name" => "Bob"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")
      assert html =~ ~s(phx-click="pair")

      {:ok, _} = Tournaments.archive_tournament(tournament)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")
      refute html =~ ~s(phx-click="pair")
    end

    test "the Standings page hides the manual-ranking controls", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, _} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")
      assert html =~ "Enable manual ranking"

      {:ok, _} = Tournaments.archive_tournament(tournament)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")
      refute html =~ "Enable manual ranking"
    end

    test "a settings save is refused rather than silently applied", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, _} = Tournaments.archive_tournament(tournament)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

      lv
      |> form("form[phx-submit=save]", %{"tournament" => %{"venue" => "Some Hall"}})
      |> render_submit()

      assert Repo.reload!(tournament).venue == ""
    end

    test "a manual-ranking event queued from a stale tab flashes instead of crashing", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, _} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})

      # Open the page while still live, so the controls are present...
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/standings")

      # ...then archive underneath it and fire the event anyway.
      {:ok, _} = Tournaments.archive_tournament(tournament)

      html = render_click(lv, "enable_manual_ranking", %{})

      assert html =~ "archived"
      refute Repo.reload!(tournament).manual_ranking
    end
  end

  describe "an archived tournament stays readable" do
    test "its public pages keep serving", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, tournament} = Tournaments.set_public_pages(tournament, true)
      {:ok, tournament} = Tournaments.archive_tournament(tournament)

      {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/standings")

      assert html =~ tournament.name
      # The read-only banner is an arbiter-facing thing; the public page has
      # no concept of editing, so it must not leak it.
      refute html =~ "archived-banner"
    end

    test "its JSON export still downloads", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, _} = Tournaments.archive_tournament(tournament)

      conn = get(conn, ~p"/t/#{tournament.id}/export/json")

      assert conn.status == 200
    end
  end
end
