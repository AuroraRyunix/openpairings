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

  describe "Forbidden pairings" do
    test "have moved to their own page, which the Options page points to", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      assert has_element?(
               lv,
               "#restrictions-moved a[href='/t/#{tournament.id}/settings/restrictions']"
             )

      refute has_element?(lv, "#add-forbidden-pairing-form")
    end
  end

  describe "Swiss engine - Ainalrami, named rather than offered" do
    test "the page names the engine, offers no choice, and the copy is accurate", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      assert has_element?(lv, "#swiss-engine-name", "Ainalrami")
      refute html =~ ~s(name="tournament[pairing_engine]")
      assert html =~ "1 February 2026"

      # The copy must be ACCURATE, which is stricter than "cautious".
      assert html =~ "2.5 billion individual pairings"
      refute html =~ "488 million"
      refute html =~ "experimental"
      refute html =~ "2017 rules"
    end

    test "a form that still carries an engine saves everything else", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      render_submit(lv, "save", %{
        "tournament" => %{"name" => "Renamed", "pairing_engine" => "javafo"}
      })

      assert Repo.reload!(tournament).name == "Renamed"
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
      # Outside FIDE mode: in it, the pairing system cannot be unlocked at all
      # (fide_mode_live_test.exs). What is tested here is the Unlock itself.
      {:ok, _} = PairingsEngine.Tournaments.leave_fide_mode(Repo.reload!(tournament))

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
      # Outside FIDE mode: in it, the pairing system cannot be unlocked at all
      # (fide_mode_live_test.exs). What is tested here is the Unlock itself.
      {:ok, _} = PairingsEngine.Tournaments.leave_fide_mode(Repo.reload!(tournament))

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
      # Outside FIDE mode: in it, the pairing system cannot be unlocked at all
      # (fide_mode_live_test.exs). What is tested here is the Unlock itself.
      {:ok, _} = PairingsEngine.Tournaments.leave_fide_mode(Repo.reload!(tournament))

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      render_click(lv, "unlock_field", %{"field" => "pairing_system"})

      render_submit(lv, "save", %{
        "tournament" => %{
          "name" => tournament.name,
          "pairing_system" => "keizer",
          "rr_match_format" => "true"
        }
      })

      # rr_match_format wasn't unlocked, so it must not slip through even
      # though pairing_system, submitted in the same form, was allowed.
      reloaded = Repo.reload!(tournament)
      assert reloaded.pairing_system == "keizer"
      refute reloaded.rr_match_format
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

  describe "round-1 absentees as late entries - switchable until round 1 is paired" do
    defp pair_swiss_round_1(tournament) do
      for {name, rating} <- [{"Alice", 2000}, {"Bob", 1900}, {"Carol", 1800}, {"Dave", 1700}] do
        Tournaments.create_player(tournament.id, %{name: name, fide_rating: rating})
      end

      {:ok, _round} =
        PairingsEngine.Pairing.pair_next_round(Tournaments.get_tournament!(tournament.id))
    end

    defp switch_off_flag(tournament) do
      tournament
      |> Ecto.Changeset.change(round_one_absentees_late: false)
      |> Repo.update!()
    end

    test "shown for a Swiss, hidden for Baku and for a round robin", %{conn: conn, scope: scope} do
      swiss = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{swiss.id}/settings/options")
      assert has_element?(lv, "input[type=checkbox][name='tournament[round_one_absentees_late]']")

      baku = create_tournament(scope, %{"acceleration" => "baku"})
      {:ok, lv, _html} = live(conn, ~p"/t/#{baku.id}/settings/options")
      refute has_element?(lv, "input[name='tournament[round_one_absentees_late]']")

      rr = create_tournament(scope, %{"pairing_system" => "round_robin"})
      {:ok, lv, _html} = live(conn, ~p"/t/#{rr.id}/settings/options")
      refute has_element?(lv, "input[name='tournament[round_one_absentees_late]']")
    end

    test "an older tournament switches it on before round 1, and the change is audited", %{
      conn: conn,
      scope: scope
    } do
      tournament = scope |> create_tournament() |> switch_off_flag()

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      refute has_element?(
               lv,
               "input[type=checkbox][name='tournament[round_one_absentees_late]'][checked]"
             )

      render_submit(lv, "save", %{
        "tournament" => %{"name" => tournament.name, "round_one_absentees_late" => "true"}
      })

      assert Repo.reload!(tournament).round_one_absentees_late

      assert Enum.any?(
               Audit.list_for_tournament(tournament.id, action: "tournament.settings_updated"),
               &Map.has_key?(&1.details["changed_fields"], "round_one_absentees_late")
             )

      render_submit(lv, "save", %{
        "tournament" => %{"name" => tournament.name, "round_one_absentees_late" => "false"}
      })

      refute Repo.reload!(tournament).round_one_absentees_late
    end

    test "disabled with a reason once round 1 is paired, and the server refuses it too", %{
      conn: conn,
      scope: scope
    } do
      tournament = scope |> create_tournament() |> switch_off_flag()
      pair_swiss_round_1(tournament)

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/options")

      assert html =~ ~r/name="tournament\[round_one_absentees_late\]"[^>]*disabled/
      assert has_element?(lv, "#round-one-absentees-late-locked")

      # The disabled checkbox is not sent, but a crafted event is: the page
      # drops it, like every other frozen field.
      render_submit(lv, "save", %{
        "tournament" => %{"name" => tournament.name, "round_one_absentees_late" => "true"}
      })

      refute Repo.reload!(tournament).round_one_absentees_late

      # And the context refuses it outright, whoever calls.
      assert {:error, changeset} =
               Tournaments.update_tournament(
                 Tournaments.get_tournament!(tournament.id),
                 %{"round_one_absentees_late" => "true"}
               )

      assert changeset.errors[:round_one_absentees_late]
      refute Repo.reload!(tournament).round_one_absentees_late
    end
  end
end
