defmodule PairingsEngineWeb.SettingsScoringLiveTest do
  # async: false: sequential SQLite writes plus self-broadcast/render ordering.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Tournaments}

  setup :register_and_log_in_user

  defp create_tournament(scope, attrs \\ %{}) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Scoring LV Test", "type" => "swiss", "rounds_count" => "5"}, attrs)
      )

    tournament
  end

  defp pair_round_robin_round_1(tournament) do
    Tournaments.create_player(tournament.id, %{name: "Alice", fide_rating: 2000})
    Tournaments.create_player(tournament.id, %{name: "Bob", fide_rating: 1900})
    Tournaments.create_player(tournament.id, %{name: "Carol", fide_rating: 1800})
    Tournaments.create_player(tournament.id, %{name: "Dave", fide_rating: 1700})

    {:ok, _round} =
      PairingsEngine.Pairing.pair_next_round(Tournaments.get_tournament!(tournament.id))
  end

  describe "Points" do
    test "saves points_win/draw/loss and bye_value", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/scoring")

      lv
      |> form("form[phx-submit=save]", %{
        "tournament" => %{
          "points_win" => "3",
          "points_draw" => "1",
          "points_loss" => "0",
          "bye_value" => "1"
        }
      })
      |> render_submit()

      updated = Tournaments.get_authorized_tournament!(scope, tournament.id)
      assert updated.points_win == 3.0
      assert updated.points_draw == 1.0
      assert updated.points_loss == 0.0
      assert updated.bye_value == 1.0
    end
  end

  describe "abs_value/abs_jusque/abs_nbfois (SWAR's \"Pt ABSENT\") - settable, locked once round 1 has been paired" do
    test "settable on a brand-new (non-SWAR) tournament before any round is paired", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope, %{"pairing_system" => "round_robin"})
      assert tournament.abs_value == nil

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/scoring")
      refute html =~ ~r/name="tournament\[abs_value\][^>]*disabled/

      render_submit(lv, "save", %{
        "tournament" => %{
          "abs_value" => "0.5",
          "abs_jusque" => "7",
          "abs_nbfois" => "2"
        }
      })

      updated = Tournaments.get_authorized_tournament!(scope, tournament.id)
      assert updated.abs_value == 0.5
      assert updated.abs_jusque == 7
      assert updated.abs_nbfois == 2
    end

    test "clearing back to blank stores nil for all three fields", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"pairing_system" => "round_robin"})

      {:ok, tournament} =
        Tournaments.update_tournament(tournament, %{
          "abs_value" => "0.5",
          "abs_jusque" => "7",
          "abs_nbfois" => "2"
        })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/scoring")

      render_submit(lv, "save", %{
        "tournament" => %{
          "abs_value" => "",
          "abs_jusque" => "",
          "abs_nbfois" => ""
        }
      })

      updated = Tournaments.get_authorized_tournament!(scope, tournament.id)
      assert updated.abs_value == nil
      assert updated.abs_jusque == nil
      assert updated.abs_nbfois == nil
    end

    test "the fields are enabled before any round is paired, disabled after round 1", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope, %{"pairing_system" => "round_robin"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/scoring")
      refute html =~ ~r/name="tournament\[abs_value\][^>]*disabled/
      refute html =~ ~r/name="tournament\[abs_jusque\][^>]*disabled/
      refute html =~ ~r/name="tournament\[abs_nbfois\][^>]*disabled/

      pair_round_robin_round_1(tournament)

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/scoring")
      assert html =~ ~r/name="tournament\[abs_value\][^>]*disabled/
      assert html =~ ~r/name="tournament\[abs_jusque\][^>]*disabled/
      assert html =~ ~r/name="tournament\[abs_nbfois\][^>]*disabled/
      refute html =~ "Locked - cannot be changed"

      html = render_click(lv, "locked_hint", %{"field" => "abs_scoring"})
      assert html =~ "Locked - cannot be changed after round 1 has been paired."
    end

    test "a submitted change is dropped server-side once locked, even with the disabled attribute bypassed",
         %{conn: conn, scope: scope} do
      tournament = create_tournament(scope, %{"pairing_system" => "round_robin"})
      pair_round_robin_round_1(tournament)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/scoring")

      render_submit(lv, "save", %{
        "tournament" => %{
          "abs_value" => "0.5",
          "abs_jusque" => "7",
          "abs_nbfois" => "2"
        }
      })

      updated = Repo.reload!(tournament)
      assert updated.abs_value == nil
      assert updated.abs_jusque == nil
      assert updated.abs_nbfois == nil
    end
  end

  describe "absent_counts_as_vur - massive warning" do
    test "an untouched tournament shows no warning", %{conn: conn, scope: scope} do
      # It fires on CHANGE, not on state. While the default was off those
      # were the same test; now that it is on, tying the warning to the
      # ticked box would shout at every arbiter opening a fresh tournament
      # about a setting they never touched.
      tournament = create_tournament(scope)
      assert tournament.absent_counts_as_vur

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/scoring")

      refute html =~ "setting-warning"
      refute html =~ "changes FIDE tiebreak results"
    end

    test "moving it away from what is saved warns immediately, before saving", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/scoring")

      html = render_click(lv, "vur_toggle", %{})

      assert html =~ "setting-warning"
      assert html =~ "changes FIDE tiebreak results"
      # Not saved yet - only the live preview flipped.
      assert Repo.reload!(tournament).absent_counts_as_vur
    end

    test "putting it back where it was clears the warning", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/scoring")

      render_click(lv, "vur_toggle", %{})
      html = render_click(lv, "vur_toggle", %{})

      refute html =~ "setting-warning"
    end

    test "saving with the box checked persists it", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/scoring")

      lv
      |> form("form[phx-submit=save]", %{
        "tournament" => %{"absent_counts_as_vur" => "true"}
      })
      |> render_submit()

      assert Tournaments.get_authorized_tournament!(scope, tournament.id).absent_counts_as_vur
    end
  end
end
