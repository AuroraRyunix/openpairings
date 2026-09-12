defmodule PairingsEngineWeb.StandingsLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Audit, Publishing, Repo, Tournaments}
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

  test "shows a public link on the results site once the tournament publishes", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Public Link Test", "type" => "swiss"})

    # An unpublished tournament has no public page anywhere, so there is
    # nothing to offer.
    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")
    refute html =~ "Public page"

    Publishing.put_endpoint("https://results.example.org")
    {:ok, tournament} = Tournaments.set_publish_to_openresults(tournament, true)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")

    assert html =~ "Public page"
    assert html =~ "https://results.example.org/t/#{tournament.public_slug}"
    # Never back to the machine running the round.
    refute html =~ "/p/#{tournament.public_slug}"
  end

  describe "Category column - shown whenever the tournament has >= 1 category, print already did this" do
    test "hidden when the tournament has no categories defined", %{conn: conn, scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "No Categories", "type" => "swiss"})

      {:ok, _p} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")

      refute html =~ ~r/<th>\s*Category\s*<\/th>/
    end

    test "shows the assigned category per player, unconditionally - not gated by the Players Display panel's tick",
         %{conn: conn, scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "Has Categories",
          "type" => "swiss",
          "categories" => ["Open", "U18"]
        })

      {:ok, alice} =
        Tournaments.create_player(tournament.id, %{"name" => "Alice", "category" => "Open"})

      {:ok, _bob} = Tournaments.create_player(tournament.id, %{"name" => "Bob"})

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")

      assert html =~ ~r/<th>\s*Category\s*<\/th>/
      assert html =~ "Open"
      # Bob has no category assigned - shows the same "-" print already uses.
      assert html =~ "-"

      # Not tied to the "cat" Players-grid preference - even an explicit,
      # empty preference list (everything toggleable hidden) still shows it.
      html = render_hook(lv, "columns_loaded", %{"columns" => []})
      assert html =~ ~r/<th>\s*Category\s*<\/th>/
      assert html =~ "Open"
      assert Enum.find(Tournaments.list_players(tournament.id), &(&1.id == alice.id))
    end

    test "shows on the Keizer ladder too", %{conn: conn, scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "Keizer Categories",
          "type" => "swiss",
          "pairing_system" => "keizer",
          "categories" => ["Open"]
        })

      {:ok, _p} =
        Tournaments.create_player(tournament.id, %{"name" => "Alice", "category" => "Open"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")

      assert html =~ ~r/<th>\s*Category\s*<\/th>/
      assert html =~ "Open"
    end
  end

  describe "Category column - chips carry each category's in-category place, prize places highlighted" do
    defp category_places_tournament(scope) do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "Category Places",
          "type" => "swiss",
          "categories" => ["Open"],
          "category_prizes" => %{"Open" => 1}
        })

      # Rating order decides the computed rank with no results entered yet:
      # Alice (2000) 1st, Bob (1900) 2nd, both in "Open".
      a =
        Repo.insert!(%Player{
          tournament_id: tournament.id,
          name: "Alice",
          fide_rating: 2000,
          category: "Open",
          categories: ["Open"]
        })

      b =
        Repo.insert!(%Player{
          tournament_id: tournament.id,
          name: "Bob",
          fide_rating: 1900,
          category: "Open",
          categories: ["Open"]
        })

      {tournament, a, b}
    end

    test "each chip shows the category and the player's place in it", %{conn: conn, scope: scope} do
      {tournament, _a, _b} = category_places_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")

      assert html =~ "Open · 1"
      assert html =~ "Open · 2"
    end

    test "a place within the configured prize count is marked, one beyond it is not", %{
      conn: conn,
      scope: scope
    } do
      {tournament, _a, _b} = category_places_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")

      assert html =~ ~r/pe-cat-chip is-prize">\s*Open · 1/
      refute html =~ ~r/pe-cat-chip is-prize">\s*Open · 2/
    end
  end

  describe "Category selector - filters the table, keeps the choice in the URL" do
    test "the selector is hidden when the tournament has no categories", %{
      conn: conn,
      scope: scope
    } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "No Categories", "type" => "swiss"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")

      refute html =~ ~s(name="category")
    end

    test "choosing a category filters the table, renumbers 1..n, and updates the URL", %{
      conn: conn,
      scope: scope
    } do
      {tournament, _a, _b} = category_places_tournament(scope)

      {:ok, third} =
        Tournaments.create_player(tournament.id, %{"name" => "Carol", "fide_rating" => 1800})

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")
      assert html =~ "Carol"

      html = lv |> element(~s(select[name="category"])) |> render_change(%{"category" => "Open"})

      assert html =~ "Open - 1 prize"
      assert html =~ "Alice"
      assert html =~ "Bob"
      refute html =~ "Carol"
      refute html =~ third.name
      assert_patch(lv, ~p"/t/#{tournament.id}/standings?category=Open")
    end

    test "the choice survives a fresh page load via the URL query param", %{
      conn: conn,
      scope: scope
    } do
      {tournament, _a, _b} = category_places_tournament(scope)

      {:ok, _third} =
        Tournaments.create_player(tournament.id, %{"name" => "Carol", "fide_rating" => 1800})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/standings?category=Open")

      assert html =~ "Open - 1 prize"
      assert html =~ "Alice"
      refute html =~ "Carol"
    end

    test "an unknown category in the URL falls back to All players instead of crashing", %{
      conn: conn,
      scope: scope
    } do
      {tournament, _a, _b} = category_places_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/standings?category=Ghost")

      assert html =~ "Alice"
      refute html =~ "Open - "
    end

    test "picking 'All players' clears the filter and the URL param", %{conn: conn, scope: scope} do
      {tournament, _a, _b} = category_places_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/standings?category=Open")

      lv |> element(~s(select[name="category"])) |> render_change(%{"category" => ""})

      assert_patch(lv, ~p"/t/#{tournament.id}/standings")
    end

    test "the selector and place column also work on the Keizer ladder", %{
      conn: conn,
      scope: scope
    } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "Keizer Category Places",
          "type" => "swiss",
          "pairing_system" => "keizer",
          "categories" => ["Open"],
          "category_prizes" => %{"Open" => 1}
        })

      Repo.insert!(%Player{
        tournament_id: tournament.id,
        name: "Alice",
        fide_rating: 2000,
        category: "Open",
        categories: ["Open"]
      })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/standings")

      html = lv |> element(~s(select[name="category"])) |> render_change(%{"category" => "Open"})

      assert html =~ "Open - 1 prize"
      assert html =~ "Alice"
    end
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

  describe "column visibility follows the Players page's Display panel (shared localStorage prefs)" do
    defp tiebreak_tournament(scope) do
      Tournaments.create_tournament(scope, %{
        "name" => "Column Sync Test",
        "type" => "swiss",
        "tiebreaks" => ["BH", "SB"]
      })
    end

    test "before the ColumnPrefs hook reports back, every optional column still shows (no regression for a first-time visitor)",
         %{conn: conn, scope: scope} do
      {:ok, tournament} = tiebreak_tournament(scope)
      {:ok, _p} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")

      assert html =~ "We"
      assert html =~ "W-We"
      assert html =~ ~r/>\s*BH\s*</
      assert html =~ ~r/>\s*SB\s*</
    end

    test "hiding 'we'/'wmwe' on the Players page hides We/W-We here too", %{
      conn: conn,
      scope: scope
    } do
      {:ok, tournament} = tiebreak_tournament(scope)
      {:ok, _p} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/standings")

      # Everything the Players Display panel currently offers, minus we/wmwe -
      # mirrors what a real localStorage payload looks like (the full
      # persisted list, not just a diff).
      columns =
        ~w(title birth_year federation fide_id fide_rating national_rating club cl games pts xtpts ptot pr)

      html = render_hook(lv, "columns_loaded", %{"columns" => columns})

      refute html =~ "We</th>"
      refute html =~ "W-We</th>"
      # Tiebreak columns aren't in that list either, so they hide too.
      refute html =~ ~r/>\s*BH\s*</
      refute html =~ ~r/>\s*SB\s*</
    end

    test "a tiebreak code with no Players-grid equivalent always shows, preference or not", %{
      conn: conn,
      scope: scope
    } do
      # KS, not MP: the code needs to be one with no grid column AND one this
      # installation can actually calculate. MP used to serve here, which is
      # how a column of permanent noughts came to be asserted as correct.
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "Koya RR",
          "type" => "roundrobin",
          "tiebreaks" => ["KS"]
        })

      {:ok, _p} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")
      assert html =~ ~r/>\s*KS\s*</

      # Even with an explicit, empty preference list (everything toggleable
      # hidden), KS has no grid column to defer to, so it stays.
      html = render_hook(lv, "columns_loaded", %{"columns" => []})
      assert html =~ ~r/>\s*KS\s*</
    end

    test "a tie-break nothing here can calculate is dropped and explained", %{
      conn: conn,
      scope: scope
    } do
      # The FIDE team-event default set names MP, GP and BB. Team standings
      # are not built, so `tiebreak/4`'s catch-all answered 0.0 for every
      # player and the page showed three columns of noughts that separated
      # nobody and said nothing about why.
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "Team RR",
          "type" => "team-roundrobin",
          "tiebreaks" => ["MP", "BH"]
        })

      {:ok, _p} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")

      refute html =~ ~r/>\s*MP\s*</
      assert html =~ "MP is not being used."
      assert html =~ "needs team standings"
      # The calculable one beside it is untouched.
      assert html =~ ~r/>\s*BH\s*</
    end

    test "the Sex column follows the same 'sex' preference as the Players page, showing FIDE's M/F letters",
         %{conn: conn, scope: scope} do
      {:ok, tournament} = tiebreak_tournament(scope)
      {:ok, _p} = Tournaments.create_player(tournament.id, %{"name" => "Alice", "sex" => "w"})

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")

      # No preference recorded yet - shows like every other optional column.
      assert html =~ "<th>Sex</th>"
      assert html =~ ">F<"

      html = render_hook(lv, "columns_loaded", %{"columns" => []})
      refute html =~ "<th>Sex</th>"

      html = render_hook(lv, "columns_loaded", %{"columns" => ["sex"]})
      assert html =~ "<th>Sex</th>"
      assert html =~ ">F<"
    end

    test "malformed columns_loaded params are ignored instead of crashing the page", %{
      conn: conn,
      scope: scope
    } do
      {:ok, tournament} = tiebreak_tournament(scope)
      {:ok, _p} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/standings")

      html = render_hook(lv, "columns_loaded", %{})
      assert html =~ "We"
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

  describe "the 'Standings after round K' control beside Public page" do
    # The control only exists while there IS a public page to change.
    defp public_tournament(scope, name) do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => name, "type" => "swiss"})

      PairingsEngine.Publishing.put_endpoint("https://results.example.org")
      {:ok, tournament} = Tournaments.set_publish_to_openresults(tournament, true)
      tournament
    end

    test "shows 'Standings after round 0' beside Public page before any round has results, public by default",
         %{conn: conn, scope: scope} do
      tournament = public_tournament(scope, "Starting Rank")
      assert tournament.standings_through == 0

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")

      assert html =~ "Public page"
      assert has_element?(lv, "#standings-toggle-0.is-public")
      assert html =~ "Standings after round 0"
    end

    test "not shown for a tournament that does not publish", %{conn: conn, scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "Private", "type" => "swiss"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/standings")

      refute has_element?(lv, "#standings-toggle-0")
    end

    test "still targets round 0 while round 1 is paired but not yet complete", %{
      conn: conn,
      scope: scope
    } do
      tournament = public_tournament(scope, "Already Paired")

      a = Repo.insert!(%Player{tournament_id: tournament.id, name: "Alice"})
      b = Repo.insert!(%Player{tournament_id: tournament.id, name: "Bob"})
      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: a.id,
        black_player_id: b.id,
        result: ""
      })

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")

      assert html =~ "Public page"
      # Round 1 isn't complete yet (no result), so the latest COMPLETE round
      # is still 0 - unlike the old flag, which vanished the instant a round
      # was merely paired, this control stays and keeps naming round 0.
      assert has_element?(lv, "#standings-toggle-0")
    end

    test "moves to round 1 once round 1 is complete and its own pairings are public", %{
      conn: conn,
      scope: scope
    } do
      tournament = public_tournament(scope, "Round One Complete")

      a = Repo.insert!(%Player{tournament_id: tournament.id, name: "Alice"})
      b = Repo.insert!(%Player{tournament_id: tournament.id, name: "Bob"})
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      round =
        Repo.insert!(%Round{
          tournament_id: tournament.id,
          number: 1,
          status: "finished",
          published_at: now
        })

      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: a.id,
        black_player_id: b.id,
        result: "1-0"
      })

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")

      assert html =~ "Standings after round 1"
      refute has_element?(lv, "#standings-toggle-1[disabled]")
    end

    test "publishing the entry list persists, survives a reload, and is audited", %{
      conn: conn,
      scope: scope
    } do
      tournament = public_tournament(scope, "Toggle Persists")
      {:ok, tournament} = Tournaments.unpublish_standings_through(tournament, 0)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/standings")
      assert has_element?(lv, "#standings-toggle-0:not(.is-public)")

      html = lv |> element("#standings-toggle-0") |> render_click()

      assert html =~ ~s(id="standings-toggle-0" role="switch" aria-checked="true")
      assert Tournaments.get_authorized_tournament!(scope, tournament.id).standings_through == 0

      assert [log] = Audit.list_for_tournament(tournament.id, action: "standings.published")
      assert log.details["through_round"] == 0

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")
      assert html =~ ~s(id="standings-toggle-0" role="switch" aria-checked="true")
    end

    test "unpublishing the entry list persists, survives a reload, and is audited", %{
      conn: conn,
      scope: scope
    } do
      tournament = public_tournament(scope, "Toggle Back")
      assert tournament.standings_through == 0

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/standings")
      assert has_element?(lv, "#standings-toggle-0.is-public")

      html = lv |> element("#standings-toggle-0") |> render_click()

      assert html =~ ~s(id="standings-toggle-0" role="switch" aria-checked="false")
      assert Tournaments.get_authorized_tournament!(scope, tournament.id).standings_through == nil

      assert [log] = Audit.list_for_tournament(tournament.id, action: "standings.unpublished")
      assert log.details["from_round"] == 0

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")
      assert html =~ ~s(id="standings-toggle-0" role="switch" aria-checked="false")
    end

    test "the unpublish confirm names the entry list, not a round number", %{
      conn: conn,
      scope: scope
    } do
      tournament = public_tournament(scope, "Confirm Text")

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/standings")

      html = render(lv)
      assert html =~ "Hide the entry list from the public page again?"
    end

    test "immediate mode shows the control locked and public", %{conn: conn, scope: scope} do
      tournament = public_tournament(scope, "Immediate Mode")
      {:ok, _tournament} = Tournaments.update_tournament(tournament, %{publish_mode: "immediate"})

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")

      assert has_element?(lv, "#standings-toggle-0.is-locked[disabled]")
      assert html =~ "Change that in Settings"
      refute has_element?(lv, "[phx-click='publish_standings']")
      refute has_element?(lv, "[phx-click='unpublish_standings']")
    end
  end
end
