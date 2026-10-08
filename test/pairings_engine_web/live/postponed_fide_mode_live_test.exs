defmodule PairingsEngineWeb.PostponedFideModeLiveTest do
  @moduledoc """
  VCL4THP Q169 on the arbiter's screens: in FIDE mode the Export page, the
  TRF downloads, the Standings page and the printed standings refuse while
  a postponed game has no result, and say which game and what to do.
  Recording a game as not played in this event goes through the Level-4
  double confirmation, leaves FIDE mode, and is on the audit trail.
  """
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Audit, Compliance, Repo, Tournaments}
  alias PairingsEngine.Pairing, as: Engine

  setup :register_and_log_in_user

  # One round only, so round 1 is also the last: four players, one game
  # postponed, the other played.
  defp tournament(scope) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Club championship",
        "type" => "swiss",
        "start_date" => "2026-09-01",
        "rounds_count" => "1",
        "round_dates" => ["2026-09-01"],
        "tiebreaks" => ["BH", "SB"],
        "postponed_games" => "true"
      })

    for {name, rating} <- [{"Alice", 2000}, {"Bob", 1900}, {"Carol", 1800}, {"Dave", 1700}] do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => name, "fide_rating" => "#{rating}"})
    end

    {:ok, _} = Engine.pair_next_round(t)
    [postponed, other] = Tournaments.get_round(t.id, 1).pairings
    {:ok, postponed} = Tournaments.update_pairing_result(postponed, "*W")
    {:ok, _} = Tournaments.update_pairing_result(other, "1-0")
    {Tournaments.get_tournament!(t.id), postponed}
  end

  test "the Export page lists the open game, disables both files, and the gate asks twice",
       %{conn: conn, scope: scope} do
    {t, postponed} = tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/export")

    assert has_element?(lv, "#trf-open-postponed-#{postponed.id}", "Alice")
    assert has_element?(lv, "#trf-send[disabled]")
    assert has_element?(lv, "#trf-download-copy[aria-disabled='true']")

    # Cancelling at the first step changes nothing.
    lv |> element("#trf-not-played-#{postponed.id}") |> render_click()
    assert has_element?(lv, "#fide-gate-warn")
    lv |> element("#fide-gate-cancel") |> render_click()
    assert is_nil(Repo.reload!(postponed).not_played_at)
    assert Compliance.fide_mode?(Repo.reload!(t))

    # Staying in FIDE mode at the second step changes nothing either.
    lv |> element("#trf-not-played-#{postponed.id}") |> render_click()
    lv |> element("#fide-gate-continue") |> render_click()
    lv |> element("#fide-gate-stay") |> render_click()
    assert is_nil(Repo.reload!(postponed).not_played_at)

    # Confirmed: recorded, out of FIDE mode, on the trail, and the files go.
    lv |> element("#trf-not-played-#{postponed.id}") |> render_click()
    lv |> element("#fide-gate-continue") |> render_click()
    lv |> element("#fide-gate-confirm") |> render_click()

    assert %DateTime{} = Repo.reload!(postponed).not_played_at
    assert Repo.reload!(t).fide_compliance_lost_round == 1
    refute has_element?(lv, "#trf-open-postponed")
    refute has_element?(lv, "#trf-send[disabled]")

    actions = t.id |> Audit.list_for_tournament() |> Enum.map(& &1.action)
    assert "pairing.postponed_not_played" in actions
    assert "tournament.fide_compliance_lost" in actions
  end

  test "a TRF download and a send are refused with the game named, and nothing is marked",
       %{conn: conn, scope: scope} do
    {t, postponed} = tournament(scope)

    copy = get(conn, ~p"/t/#{t.id}/export/trf?rounds=1")
    assert redirected_to(copy) == ~p"/t/#{t.id}/settings/export"
    assert Phoenix.Flash.get(copy.assigns.flash, :error) =~ "Alice"

    sent = post(conn, ~p"/t/#{t.id}/export/trf", %{"rounds" => "1", "finalise" => "true"})
    assert redirected_to(sent) == ~p"/t/#{t.id}/settings/export"
    assert Phoenix.Flash.get(sent.assigns.flash, :error) =~ "not played in this event"
    assert is_nil(Repo.reload!(postponed).finalised_at)
  end

  test "the final standings are refused on the page and on paper, until the game has a result",
       %{conn: conn, scope: scope} do
    {t, postponed} = tournament(scope)

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/standings")
    assert has_element?(lv, "#final-standings-refused")
    assert has_element?(lv, "#final-standings-refused-game-#{postponed.id}")
    refute has_element?(lv, "#standings-table")

    printed = get(conn, ~p"/t/#{t.id}/print/standings")
    assert html_response(printed, 200) =~ "final-standings-refused"

    {:ok, _} = Tournaments.update_pairing_result(Repo.reload!(postponed), "1/2-1/2")

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/standings")
    refute has_element?(lv, "#final-standings-refused")
    assert has_element?(lv, "#standings-table")

    refute html_response(get(conn, ~p"/t/#{t.id}/print/standings"), 200) =~
             "final-standings-refused"

    assert Compliance.fide_mode?(Repo.reload!(t))
  end
end
