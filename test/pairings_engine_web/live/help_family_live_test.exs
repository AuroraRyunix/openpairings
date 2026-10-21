defmodule PairingsEngineWeb.HelpFamilyLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.Manual.Family

  defp dutch_conn, do: Plug.Test.init_test_session(build_conn(), %{"locale" => "nl"})

  defp conn_for("nl"), do: dutch_conn()
  defp conn_for(_), do: build_conn()

  for locale <- ["en", "nl"] do
    describe "the other programs, #{locale}" do
      test "the sidebar and the index list every program, with its mark" do
        {:ok, lv, html} = live(conn_for(unquote(locale)), ~p"/help")

        assert has_element?(lv, "#part-other")
        assert has_element?(lv, "#manual-index-other")

        for program <- Family.programs() do
          assert has_element?(
                   lv,
                   "#manual-toc-other-#{program.slug}[href='/help/other/#{program.slug}']"
                 )

          assert has_element?(
                   lv,
                   "#manual-index-other-#{program.slug}[href='/help/other/#{program.slug}']"
                 )

          assert has_element?(lv, "#manual-index-other-#{program.slug} .manual-mark")
          assert has_element?(lv, "#manual-toc-other-#{program.slug} .manual-mark")
        end

        heading = if unquote(locale) == "nl", do: "Andere programma", else: "Other programs"
        assert html =~ heading
      end

      test "every page of every program renders" do
        conn = conn_for(unquote(locale))

        for program <- Family.programs(unquote(locale)), page <- program.pages do
          {:ok, lv, _html} = live(conn, Family.path(page))

          assert has_element?(lv, "#manual-program-head")
          assert has_element?(lv, "#manual-chapter-body")
          assert has_element?(lv, "#manual-program-source[href='#{program.github_url}']")

          if program.releases_url,
            do:
              assert(has_element?(lv, "#manual-program-releases[href='#{program.releases_url}']")),
            else: refute(has_element?(lv, "#manual-program-releases"))
        end
      end

      test "a program's own page opens with the introduction; its other pages do not" do
        conn = conn_for(unquote(locale))

        for program <- Family.programs(unquote(locale)) do
          [first | rest] = program.pages
          {:ok, lv, _html} = live(conn, Family.path(first))
          assert has_element?(lv, "#manual-program-intro p")

          for page <- rest do
            {:ok, lv, _html} = live(conn, Family.path(page))
            refute has_element?(lv, "#manual-program-intro")
          end
        end
      end
    end
  end

  test "the section sits below the parts of the manual" do
    {:ok, _lv, html} = live(build_conn(), ~p"/help")
    assert :binary.match(html, "part-manubrium") < :binary.match(html, "part-other")
  end

  test "OpenResults publishes no releases, so it gets no download button" do
    {:ok, lv, _} = live(build_conn(), ~p"/help/other/openresults")
    refute has_element?(lv, "#manual-program-releases")
    assert has_element?(lv, "#manual-program-source")
  end

  test "the breadcrumb leads back to the list of programs" do
    {:ok, lv, _} = live(build_conn(), ~p"/help/other/polis")
    assert has_element?(lv, ".manual-breadcrumb a[href='/help#manual-index-other']")
  end

  test "a single-page program has no row of pages" do
    {:ok, lv, _} = live(build_conn(), ~p"/help/other/nunki")
    refute has_element?(lv, "#manual-program-pages")
  end

  test "a program without Dutch says so on the Dutch side only" do
    {:ok, lv, _} = live(dutch_conn(), ~p"/help/other/nunki")
    assert has_element?(lv, "#manual-english-only")

    {:ok, lv, _} = live(build_conn(), ~p"/help/other/nunki")
    refute has_element?(lv, "#manual-english-only")

    {:ok, lv, _} = live(dutch_conn(), ~p"/help/other/alnasl")
    refute has_element?(lv, "#manual-english-only")
  end

  test "Alnasl's chapters have a pager, a nested list and a row of pages" do
    {:ok, lv, _} = live(build_conn(), ~p"/help/other/alnasl")
    assert has_element?(lv, "#manual-toc-other-alnasl-pages")
    assert has_element?(lv, "#manual-program-page-overview[aria-current='page']")

    assert has_element?(
             lv,
             "#manual-program-page-boards-and-ports[href='/help/other/alnasl/boards-and-ports']"
           )

    refute has_element?(lv, "#manual-program-page-boards-and-ports[aria-current]")
    assert has_element?(lv, "#manual-next[href='/help/other/alnasl/boards-and-ports']")
    refute has_element?(lv, "#manual-previous")

    {:ok, lv, _} = live(build_conn(), ~p"/help/other/alnasl/boards-and-ports")
    assert has_element?(lv, "#manual-previous[href='/help/other/alnasl']")
  end

  test "an unknown program or page goes back to the contents" do
    assert {:error, {:live_redirect, %{to: "/help"}}} = live(build_conn(), "/help/other/nope")

    assert {:error, {:live_redirect, %{to: "/help"}}} =
             live(build_conn(), "/help/other/nunki/nope")
  end

  test "a search finds a family page and links to it" do
    {:ok, lv, _} = live(build_conn(), ~p"/help?q=announcer")
    assert has_element?(lv, "#manual-results")
    assert has_element?(lv, "#manual-results a[href^='/help/other/nunki']")
  end

  test "links inside a page that point at the program's repository are absolute" do
    {:ok, lv, _} = live(build_conn(), ~p"/help/other/nunki")

    assert has_element?(
             lv,
             "#manual-chapter-body a[href^='https://github.com/teapot-chess/Nunki/blob/main/']"
           )
  end
end
