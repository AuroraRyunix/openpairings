defmodule PairingsEngineWeb.ByeExclusionsLiveTest do
  @moduledoc """
  "No pairing-allocated bye" on the pages: the player form (behind the
  "Bye preferences" switch), the marker in the player list, the
  Pairings page's refusal with its "pair anyway" override, the round's
  explanation, and the note on the Export page. Ainalrami only, so no JVM.
  """
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest
  import PairingsEngineWeb.FideGateHelpers

  alias PairingsEngine.{Audit, Repo, Tournaments}
  alias PairingsEngine.Tournaments.Player

  defp tournament(scope, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(
          %{
            "name" => "Bye exclusions",
            "type" => "swiss",
            "pairing_engine" => "ainalrami",
            "start_date" => "2026-07-01",
            "rounds_count" => "5",
            "round_dates" => List.duplicate("2026-07-01", 5),
            "tiebreaks" => ["BH", "SB"],
            "chief_arbiter" => "Jane Arbiter",
            "federation" => "BEL",
            "rate_of_play" => "90 min + 30 sec/move"
          },
          attrs
        )
      )

    t
  end

  defp player(t, name, attrs \\ %{}) do
    {:ok, p} = Tournaments.create_player(t.id, Map.merge(%{"name" => name}, attrs))
    p
  end

  defp open_edit(conn, t, p) do
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")
    render_click(lv, "edit_player", %{"id" => to_string(p.id)})
    lv
  end

  describe "the player form, with the feature switched on" do
    setup [:register_and_log_in_user, :enable_federation_features]

    test "a tickbox, then all or certain rounds, and the warning every time", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      p = player(t, "Anna")
      lv = open_edit(conn, t, p)

      assert has_element?(lv, "#player-no-bye-toggle")
      refute has_element?(lv, "#player-no-bye-scope")
      refute has_element?(lv, "#player-no-bye-warning")

      lv
      |> form("#player-edit-form", %{"player" => %{"no_bye" => "true"}})
      |> render_change()

      assert has_element?(lv, "#player-no-bye-scope-all[checked]")
      assert has_element?(lv, "#player-no-bye-warning")
      refute has_element?(lv, "#player-no-bye-rounds")
      # Not FIDE-homologated: the general warning, not the stronger one.
      refute has_element?(lv, "#player-no-bye-fide-warning")

      lv
      |> form("#player-edit-form", %{
        "player" => %{"no_bye" => "true", "no_bye_scope" => "rounds"}
      })
      |> render_change()

      assert has_element?(lv, "#player-no-bye-rounds")

      lv
      |> form("#player-edit-form", %{
        "player" => %{"no_bye" => "true", "no_bye_scope" => "rounds", "no_bye_rounds" => "4-2"}
      })
      |> render_submit()

      p = Repo.reload!(p)
      assert p.no_bye
      assert p.no_bye_rounds == "2,3,4"
      assert has_element?(lv, "#player-no-bye-marker-#{p.id}")

      row = t.id |> Audit.list_for_tournament(action: "player.updated") |> List.first()
      assert Map.has_key?(row.details["changed_fields"], "no_bye")
    end

    test "on a FIDE-homologated tournament the stronger warning is shown too", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)

      {:ok, t} =
        Tournaments.update_tournament(t, %{"fide_homologated" => "true"})

      p = player(t, "Anna", %{"no_bye" => "true", "no_bye_scope" => "all"})
      lv = open_edit(conn, t, p)

      assert has_element?(lv, "#player-no-bye-warning")
      assert has_element?(lv, "#player-no-bye-fide-warning")
    end

    test "JaVaFo: not offered, with a one-line reason", %{conn: conn, scope: scope} do
      t = tournament(scope, %{"pairing_engine" => "javafo"})
      p = player(t, "Anna")
      lv = open_edit(conn, t, p)

      assert has_element?(lv, "#player-no-bye-javafo")
      refute has_element?(lv, "#player-no-bye-toggle")
    end

    test "round robin and Keizer: not there at all", %{conn: conn, scope: scope} do
      for system <- ~w(round_robin keizer) do
        t = tournament(scope, %{"pairing_system" => system})
        p = player(t, "Anna", %{"no_bye" => "true", "no_bye_scope" => "all"})
        lv = open_edit(conn, t, p)

        refute has_element?(lv, "#player-no-bye")
        refute has_element?(lv, "#player-no-bye-javafo")
        refute has_element?(lv, "#player-no-bye-marker-#{p.id}")
      end
    end
  end

  describe "the player form, with the feature switched off" do
    setup :register_and_log_in_user

    test "is not offered", %{conn: conn, scope: scope} do
      t = tournament(scope)
      p = player(t, "Anna")
      lv = open_edit(conn, t, p)

      refute has_element?(lv, "#player-no-bye")
    end

    test "but a stored exclusion stays visible and editable", %{conn: conn, scope: scope} do
      t = tournament(scope)
      p = player(t, "Anna", %{"no_bye" => "true", "no_bye_scope" => "all"})
      lv = open_edit(conn, t, p)

      assert has_element?(lv, "#player-no-bye-marker-#{p.id}")
      assert has_element?(lv, "#player-no-bye-toggle")
    end
  end

  describe "pairing with everyone excluded" do
    setup :register_and_log_in_user

    test "names the players, offers the override, pairs with it and records it", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)

      players =
        for {name, rating} <- [{"A", 2000}, {"B", 1900}, {"C", 1800}, {"D", 1700}, {"E", 1600}] do
          player(t, name, %{
            "fide_rating" => "#{rating}",
            "no_bye" => "true",
            "no_bye_scope" => "all"
          })
        end

      lowest = List.last(players)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      render_click(lv, "pair", %{})

      assert has_element?(lv, "#bye-exclusion-block")
      assert has_element?(lv, "#pair-ignoring-bye-exclusion[phx-value-player-id='#{lowest.id}']")
      assert Tournaments.list_rounds(t.id) == []

      # Only the offered player is accepted.
      render_click(lv, "pair_ignoring_bye_exclusion", %{"player-id" => to_string(hd(players).id)})
      assert Tournaments.list_rounds(t.id) == []

      lv |> element("#pair-ignoring-bye-exclusion") |> render_click()
      render(lv)

      refute has_element?(lv, "#bye-exclusion-block")
      assert [round] = Tournaments.list_rounds(t.id)
      [section] = Tournaments.get_round_explanation(t.id, round.number)["sections"]
      assert section["bye_exclusion_lifted"] == lowest.id

      row =
        t.id
        |> Audit.list_for_tournament(action: "pairing.bye_exclusion_overridden")
        |> List.first()

      assert row.details["player_id"] == lowest.id
      assert row.details["round"] == 1

      # The exclusion itself is untouched: lifted for that round only.
      assert Repo.get!(Player, lowest.id).no_bye
    end
  end

  describe "an exclusion that moved the bye" do
    setup :register_and_log_in_user

    test "is explained on the round, noted on the Export page and in the trail", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)

      for {name, rating} <- [{"A", 2000}, {"B", 1900}, {"C", 1800}, {"D", 1700}] do
        player(t, name, %{"fide_rating" => "#{rating}"})
      end

      lowest =
        player(t, "E", %{"fide_rating" => "1600", "no_bye" => "true", "no_bye_scope" => "all"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      render_click(lv, "pair", %{})
      confirm_fide_exit(lv)

      assert [_round] = Tournaments.list_rounds(t.id)

      passed =
        t.id |> Audit.list_for_tournament(action: "pairing.bye_passed_over") |> List.first()

      assert passed.details["player_ids"] == [lowest.id]

      lost =
        t.id
        |> Audit.list_for_tournament(action: "tournament.fide_compliance_lost")
        |> List.first()

      assert lost.details["setting"] == "no_bye"
      assert lost.details["round"] == 1

      {:ok, explain, _html} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")
      assert has_element?(explain, "#bye-exclusion-account", "E was passed over for the bye")

      {:ok, export, _html} = live(conn, ~p"/t/#{t.id}/settings/export")
      assert has_element?(export, "#trf-bye-exclusion-note")
    end
  end
end
