defmodule PairingsEngineWeb.SettingsDatesLiveTest do
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.Tournaments

  setup :register_and_log_in_user

  defp create_tournament(scope, attrs) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Dates LV Test", "type" => "swiss", "rounds_count" => "5"}, attrs)
      )

    tournament
  end

  test "shows the weekday for a filled-in round date and the round labels", %{
    conn: conn,
    scope: scope
  } do
    tournament =
      create_tournament(scope, %{"rounds_count" => "2", "round_dates" => ["2026-07-13", ""]})

    # 2026-07-13 is a Monday.
    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/dates")

    assert html =~ "Round 1"
    assert html =~ "Monday"
    assert html =~ "Round 2"
  end

  test "renders exactly one list row per round", %{conn: conn, scope: scope} do
    tournament = create_tournament(scope, %{"rounds_count" => "7"})

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/dates")

    assert html |> String.split(~s(class="set-row")) |> length() == 8
    assert html |> String.split(~s(name="tournament[round_dates][]")) |> length() == 8
  end

  test "'Fill sequentially from round 1' sets round N = round 1's date + (N-1) days", %{
    conn: conn,
    scope: scope
  } do
    tournament = create_tournament(scope, %{"rounds_count" => "3"})

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/dates")

    # Simulates typing round 1's date in — there's no separate "start
    # date" field to seed from any more, so the live phx-change tracking
    # (rd_update/2) is what makes round 1's own unsaved value visible to
    # the fill helper at all.
    lv
    |> form("form[phx-submit=save]", %{
      "tournament" => %{"round_dates" => ["2026-07-13", "", ""]}
    })
    |> render_change()

    lv |> element("button", "Fill sequentially from round 1") |> render_click()

    lv |> form("form[phx-submit=save]", %{}) |> render_submit()

    render(lv)

    tournament = Tournaments.get_authorized_tournament!(scope, tournament.id)
    assert tournament.round_dates == ["2026-07-13", "2026-07-14", "2026-07-15"]
    # And the derived start/end date follow along automatically.
    assert tournament.start_date == "2026-07-13"
    assert tournament.end_date == "2026-07-15"
  end

  test "the derived start/end date preview updates live as round dates are typed, before saving",
       %{conn: conn, scope: scope} do
    tournament = create_tournament(scope, %{"rounds_count" => "2"})

    {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/dates")
    assert html =~ "No dates set yet"

    html =
      lv
      |> form("form[phx-submit=save]", %{
        "tournament" => %{"round_dates" => ["2026-07-13", "2026-07-20"]}
      })
      |> render_change()

    assert html =~ "2026-07-13 → 2026-07-20"

    # Not saved yet — the tournament record itself is untouched.
    tournament = Tournaments.get_authorized_tournament!(scope, tournament.id)
    assert tournament.start_date == ""
  end
end
