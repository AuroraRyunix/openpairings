defmodule PairingsEngineWeb.HelpLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Manual, Tournaments}

  describe "the manual needs no account" do
    test "the contents list every chapter" do
      {:ok, lv, _html} = live(build_conn(), ~p"/help")

      assert has_element?(lv, "#manual-index")
      assert has_element?(lv, "#manual-toc")

      for chapter <- Manual.chapters() do
        assert has_element?(lv, "#manual-toc-#{chapter.slug}[href='/help/#{chapter.slug}']")
        assert has_element?(lv, "#manual-index-#{chapter.slug}[href='/help/#{chapter.slug}']")
      end
    end

    test "a chapter renders with its contents and a pager" do
      [first, second | _] = Manual.chapters()

      {:ok, lv, _html} = live(build_conn(), ~p"/help/#{first.slug}")

      assert has_element?(lv, "#manual-chapter")
      assert has_element?(lv, "#manual-chapter-toc")
      assert has_element?(lv, "#manual-next[href='/help/#{second.slug}']")
      refute has_element?(lv, "#manual-previous")
      assert has_element?(lv, "#manual-toc-#{first.slug}[aria-current='page']")
    end

    test "the last chapter has no next link" do
      last = List.last(Manual.chapters())
      {:ok, lv, _html} = live(build_conn(), ~p"/help/#{last.slug}")

      assert has_element?(lv, "#manual-previous")
      refute has_element?(lv, "#manual-next")
    end

    test "every chapter renders" do
      for chapter <- Manual.chapters() do
        {:ok, lv, _html} = live(build_conn(), ~p"/help/#{chapter.slug}")
        assert has_element?(lv, "#manual-chapter h2.manual-chapter-title")
      end
    end

    test "an unknown chapter goes back to the contents" do
      assert {:error, {:live_redirect, %{to: "/help"}}} =
               live(build_conn(), ~p"/help/no-such-chapter")
    end

    test "the top bar of a signed-out visitor has the Help link" do
      {:ok, lv, _html} = live(build_conn(), ~p"/help")

      assert has_element?(lv, "#topbar-help[href='/help']")
    end
  end

  describe "the Help link in the top bar" do
    setup :register_and_log_in_user

    test "is on the tournaments page and opens the contents", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, "#topbar-help[href='/help']")
    end

    test "opens the chapter that matches the tab inside a tournament", %{conn: conn, scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "Help Test", "type" => "swiss"})

      for {path, chapter} <- [
            {"players", "players-and-ratings"},
            {"pairings", "pairing"},
            {"standings", "standings-and-tiebreaks"},
            {"print", "printing"},
            {"settings", "tournament-setup"}
          ] do
        {:ok, lv, _html} = live(conn, "/t/#{tournament.id}/#{path}")

        assert has_element?(lv, "#topbar-help[href='/help/#{chapter}']"), path
        assert chapter in Manual.slugs()
      end
    end

    test "the manual opens signed in, with the user's own top bar", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/help/pairing")

      assert has_element?(lv, "#manual-chapter")
      assert has_element?(lv, "#topbar-help[aria-current='page']")
    end
  end
end
