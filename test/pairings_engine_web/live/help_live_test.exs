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
        assert has_element?(lv, "#manual-chapter h1#manual-chapter-title")
        assert has_element?(lv, "#manual-chapter-body")

        for %{id: id} <- chapter.toc do
          assert has_element?(lv, "#manual-chapter-toc a[href='##{id}']"),
                 "#{chapter.slug}: #{id}"
        end
      end
    end

    test "a chapter has a breadcrumb back to the contents" do
      {:ok, lv, _html} = live(build_conn(), ~p"/help/pairing")

      assert has_element?(lv, "#manual-chapter nav.manual-breadcrumb a[href='/help']")
    end

    test "a screenshot not taken yet shows its placeholder with the file name" do
      {chapter, figure} =
        Enum.find(Manual.figures(), fn {_c, f} -> not f.present? end) ||
          flunk("every screenshot exists; nothing left to check the placeholder with")

      {:ok, lv, _html} = live(build_conn(), ~p"/help/#{chapter.slug}")

      assert has_element?(
               lv,
               "figure##{figure.id}.is-missing .manual-figure-placeholder",
               figure.file
             )

      assert has_element?(lv, "figure##{figure.id} figcaption", figure.number)
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

  describe "search" do
    test "typing in the search box lists the matching sections, matches marked" do
      {:ok, lv, _html} = live(build_conn(), ~p"/help/pairing")

      lv |> form("#manual-search", search: %{q: "Berger"}) |> render_change()

      assert_patch(lv, "/help?q=Berger")
      assert has_element?(lv, "#manual-results")
      assert has_element?(lv, "#manual-result-0 mark", "Berger")
      refute has_element?(lv, "#manual-chapter")
    end

    test "a result opens its chapter at the section" do
      [first | _] = Manual.search("Berger")
      {:ok, lv, _html} = live(build_conn(), ~p"/help?q=Berger")

      href =
        if first.section_id,
          do: "/help/#{first.chapter.slug}##{first.section_id}",
          else: "/help/#{first.chapter.slug}"

      assert has_element?(lv, "#manual-result-0[href='#{href}']")
    end

    test "nothing found says so" do
      {:ok, lv, _html} = live(build_conn(), ~p"/help?q=zzqqxxnothing")

      assert has_element?(lv, "#manual-no-results")
    end

    test "clearing the search goes back to the contents" do
      {:ok, lv, _html} = live(build_conn(), ~p"/help?q=Berger")

      lv |> form("#manual-search", search: %{q: ""}) |> render_change()

      assert_patch(lv, "/help")
      assert has_element?(lv, "#manual-index")
    end
  end

  describe "the ? beside a page's title" do
    setup :register_and_log_in_user

    test "opens the manual at the section about that page", %{conn: conn, scope: scope} do
      {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Help Test", "type" => "swiss"})

      for {path, topic} <- [
            {"players", :players},
            {"pairings", :pairings},
            {"standings", :standings},
            {"settings/fide", :fide_settings},
            {"settings/export", :trf_export}
          ] do
        {:ok, lv, _html} = live(conn, "/t/#{t.id}/#{path}")
        href = PairingsEngineWeb.Components.ManualLink.path(topic)

        assert has_element?(lv, "#manual-link-#{topic}[href='#{href}']"), path
      end
    end

    test "on the Teams page and the TRF import", %{conn: conn, scope: scope} do
      {:ok, t} =
        Tournaments.create_tournament(scope, %{
          "name" => "League",
          "type" => "team-roundrobin",
          "pairing_system" => "round_robin",
          "rounds_count" => "3"
        })

      {:ok, lv, _html} = live(conn, "/t/#{t.id}/teams")
      assert has_element?(lv, "#manual-link-teams")

      {:ok, lv, _html} = live(conn, ~p"/")
      render_click(lv, "import_trf", %{})
      assert has_element?(lv, "#manual-link-trf_import")
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
