defmodule PairingsEngineWeb.SettingsOptionsLiveTest do
  # async: false: sequential SQLite writes plus self-broadcast/render ordering.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Tournaments}

  setup :register_and_log_in_user

  defp create_tournament(scope, attrs \\ %{}) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Options LV Test", "type" => "swiss", "rounds_count" => "5"}, attrs)
      )

    tournament
  end

  describe "Rate of play — dependent on Type (standard)" do
    test "the active rate-of-play list matches the tournament's standard on load", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope, %{"standard" => "blitz"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      assert html =~ "5min/end+2sec/move from move 1"
      refute html =~ "150min/end"
    end

    test "switching Type swaps the Rate of play option list", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"standard" => "standard"})

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/options")
      assert html =~ "150min/end"
      refute html =~ "59min/end"

      html =
        lv
        |> element("select[name='tournament[standard]']")
        |> render_change(%{"tournament" => %{"standard" => "rapid"}})

      assert html =~ "59min/end"
      refute html =~ "150min/end"
    end

    test "switching Type keeps the current rate of play if it's on the new list, else clears it",
         %{
           conn: conn,
           scope: scope
         } do
      tournament =
        create_tournament(scope, %{"standard" => "rapid", "rate_of_play" => "45min/end"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      html =
        lv
        |> element("select[name='tournament[standard]']")
        |> render_change(%{"tournament" => %{"standard" => "blitz"}})

      refute html =~ "45min/end"

      lv
      |> element("select[name='tournament[standard]']")
      |> render_change(%{"tournament" => %{"standard" => "rapid"}})

      lv
      |> form("form[phx-submit=save]", %{"tournament" => %{"rate_of_play" => "59min/end"}})
      |> render_submit()

      render(lv)

      assert Tournaments.get_authorized_tournament!(scope, tournament.id).rate_of_play ==
               "59min/end"
    end

    test "a stored rate_of_play not on any preset list is offered as an extra option", %{
      conn: conn,
      scope: scope
    } do
      tournament =
        create_tournament(scope, %{
          "standard" => "standard",
          "rate_of_play" => "40min/40moves+finish (SWAR import)"
        })

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      assert html =~ "40min/40moves+finish (SWAR import)"
    end
  end

  describe "\"Pair by\" rating type" do
    test "no longer offers the \"No rating (random order)\" option", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      refute html =~ "No rating (random order)"
      assert html =~ "FIDE rating"
      assert html =~ "National rating"
    end
  end

  describe "Forbidden pairings (scroll-jump regression)" do
    test "adding a forbidden pairing does not show the stale/'updated elsewhere' banner", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, a} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})
      {:ok, b} = Tournaments.create_player(tournament.id, %{"name" => "Bob"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      html =
        lv
        |> form("#add-forbidden-pairing-form", %{
          "player_a_id" => to_string(a.id),
          "player_b_id" => to_string(b.id)
        })
        |> render_submit()

      refute html =~ "updated elsewhere"

      html = render(lv)
      refute html =~ "updated elsewhere"
      assert html =~ "Alice"
      assert html =~ "Bob"
    end

    test "removing a forbidden pairing does not show the stale banner either", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, a} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})
      {:ok, b} = Tournaments.create_player(tournament.id, %{"name" => "Bob"})
      {:ok, fp} = Tournaments.add_forbidden_pairing(tournament, a.id, b.id)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      lv |> element(~s(button[phx-value-id="#{fp.id}"])) |> render_click()

      html = render(lv)
      refute html =~ "updated elsewhere"
    end
  end

  describe "Club/federation exclusions" do
    test "saving an \"all\" club rule persists it and updates the excluded-pair hint", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, _a} =
        Tournaments.create_player(tournament.id, %{"name" => "Alice", "club" => "Chess Club"})

      {:ok, _b} =
        Tournaments.create_player(tournament.id, %{"name" => "Bob", "club" => "Chess Club"})

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/options")
      assert html =~ "0 pair(s) currently excluded"

      html =
        lv
        |> form("#exclusion-rules-form", %{"tournament" => %{"club_exclusion" => "all"}})
        |> render_submit()

      assert html =~ "1 pair(s) currently excluded"
      assert Tournaments.get_authorized_tournament!(scope, tournament.id).club_exclusion == "all"

      render(lv)
    end

    test "the \"listed\" club/federation text inputs only render once their mode is selected", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      refute html =~ "Clubs (comma-separated)"

      html =
        lv
        |> element("select[name='tournament[club_exclusion]']")
        |> render_change(%{"tournament" => %{"club_exclusion" => "listed"}})

      assert html =~ "Clubs (comma-separated)"
    end

    test "a \"listed\" federation rule with a normalized list excludes only the matching pair", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, _a} =
        Tournaments.create_player(tournament.id, %{"name" => "Alice", "federation" => "BEL"})

      {:ok, _b} =
        Tournaments.create_player(tournament.id, %{"name" => "Bob", "federation" => "BEL"})

      {:ok, _c} =
        Tournaments.create_player(tournament.id, %{"name" => "Carol", "federation" => "NED"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      lv
      |> element("select[name='tournament[fed_exclusion]']")
      |> render_change(%{"tournament" => %{"fed_exclusion" => "listed"}})

      html =
        lv
        |> form("#exclusion-rules-form", %{
          "tournament" => %{"fed_exclusion" => "listed", "fed_exclusion_list" => " bel , FRA"}
        })
        |> render_submit()

      assert html =~ "1 pair(s) currently excluded"

      tournament = Tournaments.get_authorized_tournament!(scope, tournament.id)
      assert tournament.fed_exclusion == "listed"
      assert tournament.fed_exclusion_list == "bel, FRA"

      render(lv)
    end
  end

  describe "rr_match_format — locked once round 1 has been paired" do
    defp pair_round_robin_round_1(tournament) do
      Tournaments.create_player(tournament.id, %{name: "Alice", fide_rating: 2000})
      Tournaments.create_player(tournament.id, %{name: "Bob", fide_rating: 1900})
      Tournaments.create_player(tournament.id, %{name: "Carol", fide_rating: 1800})
      Tournaments.create_player(tournament.id, %{name: "Dave", fide_rating: 1700})

      {:ok, _round} =
        PairingsEngine.Pairing.pair_next_round(Tournaments.get_tournament!(tournament.id))
    end

    test "the checkbox is enabled before any round is paired, disabled after round 1", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope, %{"pairing_system" => "round_robin"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/options")
      refute html =~ ~r/name="tournament\[rr_match_format\][^>]*disabled/

      pair_round_robin_round_1(tournament)

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/options")
      assert html =~ ~r/name="tournament\[rr_match_format\][^>]*disabled/
      refute html =~ "Locked - cannot be changed"

      html = render_click(lv, "locked_hint", %{"field" => "rr_match_format"})
      assert html =~ "Locked - cannot be changed after round 1 has been paired."

      # Clears on the next unrelated interaction (dirty tracker hook).
      html = render_change(lv, "standard_change", %{"tournament" => %{"standard" => "standard"}})
      refute html =~ "Locked - cannot be changed"
    end

    test "a submitted change to rr_match_format is dropped server-side once locked", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope, %{"pairing_system" => "round_robin"})
      pair_round_robin_round_1(tournament)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      render_submit(lv, "save", %{
        "tournament" => %{"name" => tournament.name, "rr_match_format" => "true"}
      })

      refute Repo.reload!(tournament).rr_match_format
    end
  end

  describe "swiss_match_format — locked once round 1 (match 1) has been paired" do
    defp pair_swiss_match_1(tournament) do
      Tournaments.create_player(tournament.id, %{name: "Alice", fide_rating: 2000})
      Tournaments.create_player(tournament.id, %{name: "Bob", fide_rating: 1900})
      Tournaments.create_player(tournament.id, %{name: "Carol", fide_rating: 1800})
      Tournaments.create_player(tournament.id, %{name: "Dave", fide_rating: 1700})

      {:ok, _round} =
        PairingsEngine.Pairing.pair_next_round(Tournaments.get_tournament!(tournament.id))
    end

    @tag :javafo
    test "the checkbox is enabled before any round is paired, disabled after match 1", %{
      conn: conn,
      scope: scope
    } do
      tournament =
        create_tournament(scope, %{
          "pairing_system" => "swiss",
          "rounds_count" => "4",
          "swiss_match_format" => "true"
        })

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/options")
      refute html =~ ~r/name="tournament\[swiss_match_format\][^>]*disabled/

      pair_swiss_match_1(tournament)

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/options")
      assert html =~ ~r/name="tournament\[swiss_match_format\][^>]*disabled/
      refute html =~ "Locked - cannot be changed"

      html = render_click(lv, "locked_hint", %{"field" => "swiss_match_format"})
      assert html =~ "Locked - cannot be changed after round 1 has been paired."

      html = render_change(lv, "standard_change", %{"tournament" => %{"standard" => "standard"}})
      refute html =~ "Locked - cannot be changed"
    end

    @tag :javafo
    test "a submitted change to swiss_match_format is dropped server-side once locked", %{
      conn: conn,
      scope: scope
    } do
      tournament =
        create_tournament(scope, %{
          "pairing_system" => "swiss",
          "rounds_count" => "4",
          "swiss_match_format" => "true"
        })

      pair_swiss_match_1(tournament)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      render_submit(lv, "save", %{
        "tournament" => %{"name" => tournament.name, "swiss_match_format" => "false"}
      })

      assert Repo.reload!(tournament).swiss_match_format
    end
  end

  describe "Public pairings publish mode card" do
    test "defaults to Immediately and renders every mode option", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      assert html =~ "Public pairings"
      assert html =~ "Publish each round"
      assert html =~ "Immediately"
      assert html =~ "Manually"
      assert html =~ "After a delay"
      assert html =~ "On the round&#39;s own date"
    end

    test "switching to manual mode saves it", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      lv
      |> form("form[phx-submit=save]", %{"tournament" => %{"publish_mode" => "manual"}})
      |> render_submit()

      assert Tournaments.get_authorized_tournament!(scope, tournament.id).publish_mode == "manual"
    end

    test "switching to timed mode with a delay saves both fields", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      # The "Delay (minutes)" field only renders once the mode select is
      # actually switched to "timed" (see the "field is hidden by default"
      # / "appears live" tests below) — flip it first so the form the
      # submit below reads from actually has the field in it.
      lv
      |> element("select[name='tournament[publish_mode]']")
      |> render_change(%{"tournament" => %{"publish_mode" => "timed"}})

      lv
      |> form("form[phx-submit=save]", %{
        "tournament" => %{"publish_mode" => "timed", "publish_delay_minutes" => "20"}
      })
      |> render_submit()

      updated = Tournaments.get_authorized_tournament!(scope, tournament.id)
      assert updated.publish_mode == "timed"
      assert updated.publish_delay_minutes == 20
    end

    test "the \"Delay (minutes)\" field is hidden by default (mode is Immediately)", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      refute html =~ "Delay (minutes)"
    end

    test "the \"Delay (minutes)\" field appears live when the mode is switched to 'timed', and hides again when switched away",
         %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      html =
        lv
        |> element("select[name='tournament[publish_mode]']")
        |> render_change(%{"tournament" => %{"publish_mode" => "timed"}})

      assert html =~ "Delay (minutes)"

      html =
        lv
        |> element("select[name='tournament[publish_mode]']")
        |> render_change(%{"tournament" => %{"publish_mode" => "manual"}})

      refute html =~ "Delay (minutes)"
    end

    test "a tournament already saved in 'timed' mode shows the Delay field on initial render", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, _updated} =
        Tournaments.update_tournament(tournament, %{
          "publish_mode" => "timed",
          "publish_delay_minutes" => "15"
        })

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      assert html =~ "Delay (minutes)"
    end
  end
end
