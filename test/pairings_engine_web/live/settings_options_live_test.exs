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

  describe "Rate of play - dependent on Type (standard)" do
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
      |> form("#play-settings-form", %{"tournament" => %{"rate_of_play" => "59min/end"}})
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
    # The select is gone entirely: `rating_type` was stored, validated and
    # exported but never read - pairing order comes from
    # `Tournaments.Player.rating/1`, which never consulted it - so the
    # choice it offered had no effect. See the migration
    # 20260820120000_drop_tournament_rating_type.
    test "is not offered at all, because it never did anything", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      refute html =~ "Pair by"
      refute html =~ "tournament[rating_type]"
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
      assert html =~ "0 pairs currently excluded"

      html =
        lv
        |> form("#exclusion-rules-form", %{"tournament" => %{"club_exclusion" => "all"}})
        |> render_submit()

      assert html =~ "1 pair currently excluded"
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

      assert html =~ "1 pair currently excluded"

      tournament = Tournaments.get_authorized_tournament!(scope, tournament.id)
      assert tournament.fed_exclusion == "listed"
      assert tournament.fed_exclusion_list == "bel, FRA"

      render(lv)
    end
  end

  describe "Swiss engine - JaVaFo by default, Ainalrami opt-in" do
    test "both engines are offered, JaVaFo selected, and the beta caveats are stated", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      assert html =~ ~s(name="tournament[pairing_engine]")
      assert html =~ "JaVaFo - FIDE-endorsed (default)"
      assert html =~ "Ainalrami (experimental)"

      # The copy must be ACCURATE, which is a stricter test than "cautious".
      # It previously claimed a handful of known disagreements remained and
      # that forbidden pairings, exclusions and acceleration were not
      # implemented. Both had stopped being true, and understating an engine
      # misleads an arbiter exactly as badly as overselling one.
      assert html =~ "the safe choice for a FIDE-rated tournament"
      assert html =~ "Swiss only"
      assert html =~ "zero disagreements"
      refute html =~ "handful of known disagreements"
      refute html =~ "does not yet implement"

      # Nothing is disabled or locked on a fresh tournament.
      refute html =~ ~r/name="tournament\[pairing_engine\][^>]*disabled/
      assert tournament.pairing_engine == "javafo"
    end

    test "selecting Ainalrami asks first, and does not save until confirmed", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      html =
        render_submit(lv, "save", %{
          "tournament" => %{"name" => tournament.name, "pairing_engine" => "ainalrami"}
        })

      assert html =~ "Switch to Ainalrami?"
      assert html =~ "Experimental, but plausibly better"
      # Nothing written yet - the dialog is a gate, not a notification.
      assert Repo.reload!(tournament).pairing_engine == "javafo"

      render_click(lv, "confirm_engine", %{})
      assert Repo.reload!(tournament).pairing_engine == "ainalrami"
    end

    test "cancelling the dialog leaves the engine alone", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      render_submit(lv, "save", %{
        "tournament" => %{"name" => tournament.name, "pairing_engine" => "ainalrami"}
      })

      html = render_click(lv, "cancel_engine", %{})

      refute html =~ "Switch to Ainalrami?"
      assert Repo.reload!(tournament).pairing_engine == "javafo"
    end

    # The dialog gates the CHANGE, not the value. A tournament already on
    # Ainalrami must be able to edit anything else on this page without the
    # dialog reappearing every time.
    test "editing other settings on a tournament already using Ainalrami does not re-prompt", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, tournament} =
        Tournaments.update_tournament(tournament, %{"pairing_engine" => "ainalrami"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      html =
        render_submit(lv, "save", %{
          "tournament" => %{"name" => "Renamed", "pairing_engine" => "ainalrami"}
        })

      refute html =~ "Switch to Ainalrami?"
      assert Repo.reload!(tournament).name == "Renamed"
    end

    # Switching BACK needs no ceremony: JaVaFo is the default and the
    # FIDE-endorsed one, so there is nothing to warn about.
    test "switching back to JaVaFo saves immediately", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, tournament} =
        Tournaments.update_tournament(tournament, %{"pairing_engine" => "ainalrami"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      html =
        render_submit(lv, "save", %{
          "tournament" => %{"name" => tournament.name, "pairing_engine" => "javafo"}
        })

      refute html =~ "Switch to Ainalrami?"
      assert Repo.reload!(tournament).pairing_engine == "javafo"
    end

    test "confirming with no pending change is a no-op rather than a crash", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      render_click(lv, "confirm_engine", %{})

      assert Repo.reload!(tournament).pairing_engine == "javafo"
    end

    test "on a FIDE-homologated tournament the Ainalrami option is visibly unavailable, with the reason",
         %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, _} =
        Tournaments.update_tournament(tournament, %{
          "fide_homologated" => "true",
          "fide_tournament_id" => "12345"
        })

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      # Selectable, and warned about. The block was removed deliberately
      # (2026-08-21): the exposure is paperwork, not pairing quality, and
      # refusing outright asserted a judgement the measurements do not
      # support. What must never happen is it being allowed SILENTLY.
      assert html =~ "Ainalrami (experimental)"
      refute html =~ ~r/value="ainalrami"[^>]*disabled/s
      assert html =~ "endorsed by FIDE on the basis that it pairs"
    end

    test "saving Ainalrami on a homologated tournament warns in the dialog, then allows it", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, _} =
        Tournaments.update_tournament(tournament, %{
          "fide_homologated" => "true",
          "fide_tournament_id" => "12345"
        })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      html =
        render_submit(lv, "save", %{
          "tournament" => %{"name" => tournament.name, "pairing_engine" => "ainalrami"}
        })

      # The dialog carries the homologation-specific warning ON TOP of the
      # ordinary one, and still nothing is written until it is confirmed.
      assert html =~ "Switch to Ainalrami?"
      assert html =~ "This tournament is FIDE-homologated"
      assert html =~ "not produced by the engine that endorsement"
      assert Repo.reload!(tournament).pairing_engine == "javafo"

      render_click(lv, "confirm_engine", %{})
      assert Repo.reload!(tournament).pairing_engine == "ainalrami"
    end

    test "the select is disabled once round 1 has been paired, and explains why on click", %{
      conn: conn,
      scope: scope
    } do
      # Deliberately a round robin: it pairs without JaVaFo, so this test
      # runs anywhere. The lock is on the field, not on the pairing system.
      tournament = create_tournament(scope, %{"pairing_system" => "round_robin"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/options")
      refute html =~ ~r/name="tournament\[pairing_engine\][^>]*disabled/

      pair_round_robin_round_1(tournament)

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/options")
      assert html =~ ~r/name="tournament\[pairing_engine\][^>]*disabled/

      html = render_click(lv, "locked_hint", %{"field" => "pairing_engine"})
      assert html =~ "Locked - cannot be changed after round 1 has been paired."
    end

    test "a submitted change to pairing_engine is dropped server-side once locked", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope, %{"pairing_system" => "round_robin"})
      pair_round_robin_round_1(tournament)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      render_submit(lv, "save", %{
        "tournament" => %{"name" => tournament.name, "pairing_engine" => "ainalrami"}
      })

      assert Repo.reload!(tournament).pairing_engine == "javafo"
    end
  end

  describe "rr_match_format - locked once round 1 has been paired" do
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

  describe "swiss_match_format - locked once round 1 (match 1) has been paired" do
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
      |> form("#publish-settings-form", %{"tournament" => %{"publish_mode" => "manual"}})
      |> render_submit()

      assert Tournaments.get_authorized_tournament!(scope, tournament.id).publish_mode == "manual"
    end

    test "switching to timed mode with a delay saves both fields", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      # The "Delay (minutes)" field only renders once the mode select is
      # actually switched to "timed" (see the "field is hidden by default"
      # / "appears live" tests below) - flip it first so the form the
      # submit below reads from actually has the field in it.
      lv
      |> element("select[name='tournament[publish_mode]']")
      |> render_change(%{"tournament" => %{"publish_mode" => "timed"}})

      lv
      |> form("#publish-settings-form", %{
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

  # The page used to be one long form with a single "Save settings" button
  # underneath everything, so changing a select near the top meant scrolling
  # past every other setting to commit it, and the resulting "Saved." said
  # nothing about which of those settings had been written.
  describe "each subject saves on its own" do
    test "every subject has its own form and its own save button", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      for id <- ~w(pairing-settings-form play-settings-form publish-settings-form) do
        assert has_element?(lv, "##{id}"), "expected a form ##{id}"
        assert has_element?(lv, "##{id} button[type=submit]"), "##{id} has no save button"
      end
    end

    test "saving one subject leaves the others alone", %{conn: conn, scope: scope} do
      tournament =
        create_tournament(scope, %{"standard" => "rapid", "rate_of_play" => "45min/end"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      lv
      |> form("#publish-settings-form", %{"tournament" => %{"publish_mode" => "manual"}})
      |> render_submit()

      # The publish form carries no rate-of-play or engine field at all, so
      # those columns must come through untouched rather than being cast
      # from a blank the other form would have submitted.
      updated = Tournaments.get_authorized_tournament!(scope, tournament.id)
      assert updated.publish_mode == "manual"
      assert updated.rate_of_play == "45min/end"
      assert updated.standard == "rapid"
      assert updated.pairing_engine == "javafo"
    end

    test "the confirmation lands beside the button that was pressed", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      lv
      |> form("#publish-settings-form", %{"tournament" => %{"publish_mode" => "manual"}})
      |> render_submit()

      assert has_element?(lv, "#publish-settings-form .ok-note")
      refute has_element?(lv, "#pairing-settings-form .ok-note")
      refute has_element?(lv, "#play-settings-form .ok-note")
    end
  end
end
