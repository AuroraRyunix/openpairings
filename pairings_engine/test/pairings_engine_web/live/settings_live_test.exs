defmodule PairingsEngineWeb.SettingsLiveTest do
  # `async: false`: like PairingsEngine.TournamentsTest and friends, several
  # tests here do a handful of sequential writes (tournament + players +
  # forbidden pairings/categories) against SQLite's single writer, and the
  # "self-broadcast" regression tests specifically rely on PubSub delivery
  # ordering relative to `render/1`, which is easiest to reason about
  # without other async tests' writes interleaving.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.Tournaments

  setup :register_and_log_in_user

  defp create_tournament(scope, attrs \\ %{}) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Settings LV Test", "type" => "swiss", "rounds_count" => "5"}, attrs)
      )

    tournament
  end

  describe "Rate of play — dependent on Type (standard)" do
    test "the active rate-of-play list matches the tournament's standard on load", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"standard" => "blitz"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      # A blitz-only option is offered...
      assert html =~ "5min/end+2sec/move from move 1"
      # ...but a standard-only one (that doesn't also appear on the blitz
      # list) is not.
      refute html =~ "150min/end"
    end

    test "switching Type swaps the Rate of play option list", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"standard" => "standard"})

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")
      assert html =~ "150min/end"
      refute html =~ "59min/end"

      html =
        lv
        |> element("select[name='tournament[standard]']")
        |> render_change(%{"tournament" => %{"standard" => "rapid"}})

      assert html =~ "59min/end"
      refute html =~ "150min/end"
    end

    test "switching Type keeps the current rate of play if it's on the new list, else clears it", %{
      conn: conn,
      scope: scope
    } do
      # "10min/end" appears on both the rapid... (no, only blitz/rapid share
      # nothing verbatim) — use a value unique to rapid vs one unique to
      # blitz to prove both branches.
      tournament = create_tournament(scope, %{"standard" => "rapid", "rate_of_play" => "45min/end"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

      # "45min/end" only exists on the rapid list — switching to blitz must
      # clear the selection (fall back to the blank option) rather than
      # silently keep an option that no longer exists on the rendered list.
      html =
        lv
        |> element("select[name='tournament[standard]']")
        |> render_change(%{"tournament" => %{"standard" => "blitz"}})

      refute html =~ "45min/end"

      # Switching back to rapid, the value is gone (it was cleared), so the
      # blank option is what's active — saving now should persist blank.
      lv
      |> element("select[name='tournament[standard]']")
      |> render_change(%{"tournament" => %{"standard" => "rapid"}})

      lv
      |> form("form[phx-submit=save]", %{"tournament" => %{"rate_of_play" => "59min/end"}})
      |> render_submit()

      assert Tournaments.get_authorized_tournament!(scope, tournament.id).rate_of_play == "59min/end"
    end

    test "a stored rate_of_play not on any preset list (e.g. from SWAR import) is offered as an extra option instead of silently dropped",
         %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"standard" => "standard", "rate_of_play" => "40min/40moves+finish (SWAR import)"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      assert html =~ "40min/40moves+finish (SWAR import)"
    end
  end

  describe "Round dates" do
    test "shows the weekday for a filled-in round date and the round labels", %{conn: conn, scope: scope} do
      tournament =
        create_tournament(scope, %{"rounds_count" => "2", "round_dates" => ["2026-07-13", ""]})

      # 2026-07-13 is a Monday.
      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

      assert html =~ "Round 1"
      assert html =~ "Monday"
      assert html =~ "Round 2"
    end

    test "'Fill sequentially from start date' sets round N = start date + (N-1) days", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"rounds_count" => "3", "start_date" => "2026-07-13"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

      lv |> element("button", "Fill sequentially from start date") |> render_click()

      lv |> form("form[phx-submit=save]", %{}) |> render_submit()

      tournament = Tournaments.get_authorized_tournament!(scope, tournament.id)
      assert tournament.round_dates == ["2026-07-13", "2026-07-14", "2026-07-15"]
    end
  end

  describe "Categories" do
    test "adds a category, rejects a blank or duplicate name, and removes one", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

      html = lv |> form("#add-category-form", %{"name" => "U18"}) |> render_submit()
      assert html =~ "U18"
      assert Tournaments.get_authorized_tournament!(scope, tournament.id).categories == ["U18"]

      html = lv |> form("#add-category-form", %{"name" => "  "}) |> render_submit()
      assert html =~ "Enter a category name"

      html = lv |> form("#add-category-form", %{"name" => "U18"}) |> render_submit()
      assert html =~ "already exists"
      assert Tournaments.get_authorized_tournament!(scope, tournament.id).categories == ["U18"]

      lv |> element(~s(button[phx-value-name="U18"]), "Remove") |> render_click()
      assert Tournaments.get_authorized_tournament!(scope, tournament.id).categories == []
    end
  end

  describe "Forbidden pairings (scroll-jump regression)" do
    # Previously, `add_forbidden_pairing`/`remove_forbidden_pairing` wrote
    # through `PairingsEngine.Tournaments` (which broadcasts `:settings` on
    # the tournament's PubSub topic like every write does), and the
    # `settings_dirty_tracker` hook had already flagged the page `dirty`
    # for that very same event — so when the self-broadcast echoed back,
    # the page unconditionally rendered the "updated elsewhere" banner
    # right under the header, which read as the page jumping to the top.
    # It's a false positive: nothing actually changed out from under this
    # session, this session caused it.
    test "adding a forbidden pairing does not show the stale/'updated elsewhere' banner", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, a} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})
      {:ok, b} = Tournaments.create_player(tournament.id, %{"name" => "Bob"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

      html =
        lv
        |> form("#add-forbidden-pairing-form", %{"player_a_id" => to_string(a.id), "player_b_id" => to_string(b.id)})
        |> render_submit()

      refute html =~ "updated elsewhere"

      # Force any pending self-broadcast in the LiveView's mailbox to be
      # processed before asserting again.
      html = render(lv)
      refute html =~ "updated elsewhere"
      assert html =~ "Alice"
      assert html =~ "Bob"
    end

    test "removing a forbidden pairing does not show the stale banner either", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, a} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})
      {:ok, b} = Tournaments.create_player(tournament.id, %{"name" => "Bob"})
      {:ok, fp} = Tournaments.add_forbidden_pairing(tournament, a.id, b.id)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

      lv |> element(~s(button[phx-value-id="#{fp.id}"])) |> render_click()

      html = render(lv)
      refute html =~ "updated elsewhere"
    end

    test "a genuine concurrent change from another session while dirty still shows the stale banner", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

      # Mark the page dirty the same way any in-progress edit would (e.g.
      # reordering a tiebreak), without saving.
      lv |> element("button", "Reset to FIDE default") |> render_click()

      # A real external change — bumps `updated_at` on the tournaments row
      # itself, unlike the forbidden-pairings child-table writes above.
      {:ok, _updated} = Tournaments.update_tournament(tournament, %{"venue" => "Somewhere else"})

      html = render(lv)
      assert html =~ "updated elsewhere"
    end
  end
end
