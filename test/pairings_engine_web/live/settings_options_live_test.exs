defmodule PairingsEngineWeb.SettingsOptionsLiveTest do
  # async: false: sequential SQLite writes plus self-broadcast/render ordering.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Audit, Repo, Tournaments}

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

  describe "Soft rules" do
    test "a forbidden pairing added with \"only if possible\" is listed as a wish", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, a} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})
      {:ok, b} = Tournaments.create_player(tournament.id, %{"name" => "Bob"})

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/options")
      assert html =~ "Only if possible"

      html =
        lv
        |> form("#add-forbidden-pairing-form", %{
          "player_a_id" => to_string(a.id),
          "player_b_id" => to_string(b.id),
          "soft" => "true"
        })
        |> render_submit()

      assert html =~ "if possible</span>"
      assert [fp] = Tournaments.list_forbidden_pairings(tournament.id)
      assert fp.soft
    end

    test "a plain add is still a rule", %{conn: conn, scope: scope} do
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

      refute html =~ "if possible</span>"
      assert [%{soft: false}] = Tournaments.list_forbidden_pairings(tournament.id)
    end

    test "the exclusion form saves the club wish and how hard to try", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      # Ainalrami is the default engine, so the wishes apply: no caveat.
      refute html =~ "kept but not applied"

      lv
      |> form("#exclusion-rules-form", %{
        "tournament" => %{"soft_club_rounds" => "2", "soft_position" => "weak"}
      })
      |> render_submit()

      saved = Tournaments.get_authorized_tournament!(scope, tournament.id)
      assert saved.soft_club_rounds == 2
      assert saved.soft_position == "weak"
    end

    test "a JaVaFo tournament is told its wishes are kept but not applied", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope, %{"pairing_engine" => "javafo"})
      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      assert html =~ "kept but not applied"
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

  describe "Swiss engine - Ainalrami by default, JaVaFo the opt-out" do
    # The direction reversed on 2026-08-25. JaVaFo implements C.04.3 as it
    # stood in 2022 and was never updated for the edition effective
    # 1 February 2026, so it was the default that handed arbiters superseded
    # pairings. The dialog now guards the way OUT, not the way in.
    test "both engines are offered, Ainalrami selected, and the copy is accurate", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      assert html =~ ~s(name="tournament[pairing_engine]")
      assert html =~ "implements the 2026 rules"
      assert html =~ "implements the 2022 rules"

      # The copy must be ACCURATE, which is stricter than "cautious".
      # Understating an engine misleads an arbiter exactly as badly as
      # overselling one, and every claim below was true of the OLD copy and
      # is false now.
      assert html =~ "2.5 billion individual pairings"
      refute html =~ "488 million"
      refute html =~ "experimental"
      refute html =~ "FIDE-endorsed (default)"

      refute html =~ ~r/name="tournament\[pairing_engine\][^>]*disabled/
      assert tournament.pairing_engine == "ainalrami"
    end

    test "selecting JaVaFo asks first, and does not save until confirmed", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      html =
        render_submit(lv, "save", %{
          "tournament" => %{"name" => tournament.name, "pairing_engine" => "javafo"}
        })

      assert html =~ "Switch to JaVaFo?"
      assert html =~ "superseded rules"
      # Nothing written yet - the dialog is a gate, not a notification.
      assert Repo.reload!(tournament).pairing_engine == "ainalrami"

      render_click(lv, "confirm_engine", %{})
      assert Repo.reload!(tournament).pairing_engine == "javafo"
    end

    test "cancelling the dialog leaves the engine alone", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      render_submit(lv, "save", %{
        "tournament" => %{"name" => tournament.name, "pairing_engine" => "javafo"}
      })

      html = render_click(lv, "cancel_engine", %{})

      refute html =~ "Switch to JaVaFo?"
      assert Repo.reload!(tournament).pairing_engine == "ainalrami"
    end

    # The dialog gates the CHANGE, not the value. A tournament already on
    # JaVaFo must be able to edit anything else on this page without the
    # dialog reappearing every time.
    test "editing other settings on a tournament already using JaVaFo does not re-prompt", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope, %{"pairing_engine" => "javafo"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      html =
        render_submit(lv, "save", %{
          "tournament" => %{"name" => "Renamed", "pairing_engine" => "javafo"}
        })

      refute html =~ "Switch to JaVaFo?"
      assert Repo.reload!(tournament).name == "Renamed"
    end

    # Switching back to the current-rules engine needs no ceremony.
    test "switching back to Ainalrami saves immediately", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"pairing_engine" => "javafo"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      html =
        render_submit(lv, "save", %{
          "tournament" => %{"name" => tournament.name, "pairing_engine" => "ainalrami"}
        })

      refute html =~ "Switch to JaVaFo?"
      assert Repo.reload!(tournament).pairing_engine == "ainalrami"
    end

    test "confirming with no pending change is a no-op rather than a crash", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      render_click(lv, "confirm_engine", %{})

      assert Repo.reload!(tournament).pairing_engine == "ainalrami"
    end

    test "a FIDE-homologated tournament states the position on both engines",
         %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, _} =
        Tournaments.update_tournament(tournament, %{
          "fide_homologated" => "true",
          "fide_tournament_id" => "12345"
        })

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      # Neither engine is blocked here, and neither is allowed SILENTLY.
      # The block was removed deliberately (2026-08-21) because the exposure
      # is paperwork rather than pairing quality; what replaced it has to
      # keep saying so.
      refute html =~ ~r/value="ainalrami"[^>]*disabled/s
      refute html =~ ~r/value="javafo"[^>]*disabled/s

      # The note used to rest on OpenPairings' own endorsement. That claim is
      # gone from the whole interface (2026-08-25) - FIDE has said existing
      # endorsements are revoked in the coming Acceptance Cycle, so it was a
      # promise with a shelf life, and the app should not be trading on it.
      # What is left is the thing that is actually true and actually decides
      # the question: which edition of the rules each engine implements.
      refute html =~ "endorse"
      assert html =~ "1 February 2026"
      assert html =~ "2022"
    end

    test "switching a homologated tournament to JaVaFo still asks first", %{
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
          "tournament" => %{"name" => tournament.name, "pairing_engine" => "javafo"}
        })

      assert html =~ "Switch to JaVaFo?"
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
      assert html =~ "hands the new engine a history it did not produce"
      assert html =~ "Unlock"
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

      assert Repo.reload!(tournament).pairing_engine == "ainalrami"
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
      refute html =~ "immediate two-game rematch"

      html = render_click(lv, "locked_hint", %{"field" => "rr_match_format"})
      assert html =~ "immediate two-game rematch"
      assert html =~ "Unlock"

      # Clears on the next unrelated interaction (dirty tracker hook).
      html = render_change(lv, "standard_change", %{"tournament" => %{"standard" => "standard"}})
      refute html =~ "immediate two-game rematch"
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
      refute html =~ "immediate two-game rematch"

      html = render_click(lv, "locked_hint", %{"field" => "swiss_match_format"})
      assert html =~ "immediate two-game rematch"
      assert html =~ "Unlock"

      html = render_change(lv, "standard_change", %{"tournament" => %{"standard" => "standard"}})
      refute html =~ "immediate two-game rematch"
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

  describe "unlocking a locked field - deliberate override" do
    test "Unlock enables the select, and saving through it changes the value and audit-logs the override",
         %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"pairing_system" => "round_robin"})
      pair_round_robin_round_1(tournament)

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/options")
      assert html =~ ~r/name="tournament\[pairing_system\][^>]*disabled/

      html = render_click(lv, "locked_hint", %{"field" => "pairing_system"})
      assert html =~ "Unlock"

      html = render_click(lv, "unlock_field", %{"field" => "pairing_system"})
      refute html =~ ~r/name="tournament\[pairing_system\][^>]*disabled/

      html =
        render_submit(lv, "save", %{
          "tournament" => %{"name" => tournament.name, "pairing_system" => "keizer"}
        })

      assert Repo.reload!(tournament).pairing_system == "keizer"

      # Landed - the field goes right back to frozen, same as any other
      # locked field once round 1 is paired.
      assert html =~ ~r/name="tournament\[pairing_system\][^>]*disabled/

      [entry] =
        Audit.list_for_tournament(tournament.id, action: "tournament.locked_field_changed")

      assert entry.details["field"] == "pairing_system"
      assert entry.details["from"] == "round_robin"
      assert entry.details["to"] == "keizer"
    end

    test "the unlock does not survive a second save - it must be granted again", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope, %{"pairing_system" => "round_robin"})
      pair_round_robin_round_1(tournament)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      render_click(lv, "unlock_field", %{"field" => "pairing_system"})

      render_submit(lv, "save", %{
        "tournament" => %{"name" => tournament.name, "pairing_system" => "keizer"}
      })

      assert Repo.reload!(tournament).pairing_system == "keizer"

      # A second attempt, with no fresh "unlock_field" click, is refused
      # server-side exactly like before it was ever unlocked - the select
      # renders disabled again, and `strip_locked_pairing_fields/2` drops
      # the submitted value.
      render_submit(lv, "save", %{
        "tournament" => %{"name" => tournament.name, "pairing_system" => "swiss"}
      })

      assert Repo.reload!(tournament).pairing_system == "keizer"
    end

    test "unlocking one field doesn't unlock a different one alongside it", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope, %{"pairing_system" => "round_robin"})
      pair_round_robin_round_1(tournament)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      render_click(lv, "unlock_field", %{"field" => "pairing_system"})

      html =
        render_submit(lv, "save", %{
          "tournament" => %{
            "name" => tournament.name,
            "pairing_system" => "keizer",
            "pairing_engine" => "javafo"
          }
        })

      # pairing_engine wasn't unlocked, so it must not slip through even
      # though pairing_system, submitted in the same form, was allowed.
      refute html =~ "Switch to JaVaFo?"
      reloaded = Repo.reload!(tournament)
      assert reloaded.pairing_system == "keizer"
      assert reloaded.pairing_engine != "javafo"
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

      for id <- ~w(pairing-settings-form play-settings-form) do
        assert has_element?(lv, "##{id}"), "expected a form ##{id}"
        assert has_element?(lv, "##{id} button[type=submit]"), "##{id} has no save button"
      end
    end

    test "saving one subject leaves the others alone", %{conn: conn, scope: scope} do
      tournament =
        create_tournament(scope, %{"standard" => "rapid", "rate_of_play" => "45min/end"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      lv
      |> form("#pairing-settings-form", %{"tournament" => %{"acceleration" => "baku"}})
      |> render_submit()

      # The pairing form carries no rate-of-play or standard field at all, so
      # those columns must come through untouched rather than being cast
      # from a blank the other form would have submitted.
      updated = Tournaments.get_authorized_tournament!(scope, tournament.id)
      assert updated.acceleration == "baku"
      assert updated.rate_of_play == "45min/end"
      assert updated.standard == "rapid"
    end

    test "the confirmation lands beside the button that was pressed", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      lv
      |> form("#play-settings-form", %{"tournament" => %{"rate_of_play_other" => "40min+10sec"}})
      |> render_submit()

      assert has_element?(lv, "#play-settings-form .ok-note")
      refute has_element?(lv, "#pairing-settings-form .ok-note")
    end
  end

  describe "the \"locked_hint\" event" do
    # This handler ran `String.to_existing_atom/1` straight on the param, so
    # a crafted event naming a field the page never sends took the sender's
    # own socket down with an ArgumentError.
    test "an unknown field is ignored rather than crashing the socket", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      render_hook(lv, "locked_hint", %{"field" => "not_a_settings_field_at_all"})

      assert Process.alive?(lv.pid)
      assert is_nil(:sys.get_state(lv.pid).socket.assigns.locked_hint)
    end

    test "an atom that exists but this page never offers is ignored too", %{
      conn: conn,
      scope: scope
    } do
      # `to_existing_atom` would have accepted this one happily - the guard
      # is an allowlist of what the markup sends, not of what compiles.
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      render_hook(lv, "locked_hint", %{"field" => "name"})

      assert is_nil(:sys.get_state(lv.pid).socket.assigns.locked_hint)
    end

    test "a field the markup does send still sets the hint", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      render_hook(lv, "locked_hint", %{"field" => "pairing_system"})

      assert :sys.get_state(lv.pid).socket.assigns.locked_hint == :pairing_system
    end
  end
end
