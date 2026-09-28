defmodule PairingsEngineWeb.TournamentDefaultsTest do
  @moduledoc """
  Account → New tournaments, as the "New tournament" form sees it.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Accounts, Tournaments}

  setup :register_and_log_in_user

  defp open_new_form(conn) do
    {:ok, lv, _html} = live(conn, ~p"/")
    lv |> element("button[phx-click='new']") |> render_click()
    lv
  end

  test "with no defaults the form is exactly what it always was", %{conn: conn} do
    lv = open_new_form(conn)

    refute has_element?(lv, "#new-tournament-defaults-note")

    assert has_element?(
             lv,
             "#new-tournament-form input[name='tournament[rounds_count]'][value='9']"
           )
  end

  test "the form starts from the stored defaults, and says so", %{conn: conn, user: user} do
    {:ok, _} =
      Accounts.update_tournament_defaults(user, %{
        "pairing_system" => "round_robin",
        "rounds_count" => "7",
        "standard" => "rapid",
        "city" => "Gent"
      })

    lv = open_new_form(conn)

    assert has_element?(lv, "#new-tournament-defaults-note")

    assert has_element?(
             lv,
             "#new-tournament-form input[name='tournament[rounds_count]'][value='7']"
           )

    assert has_element?(lv, "#new-tournament-form input[name='tournament[city]'][value='Gent']")

    assert has_element?(
             lv,
             "#new-tournament-form select[name='tournament[pairing_system]'] option[value='round_robin'][selected]"
           )

    assert has_element?(
             lv,
             "#new-tournament-form input[name='tournament[standard]'][value='rapid'][checked]"
           )
  end

  test "defaults the form does not show reach the tournament; what it submits wins", %{
    conn: conn,
    user: user,
    scope: scope
  } do
    {:ok, _} =
      Accounts.update_tournament_defaults(user, %{
        "city" => "Gent",
        "federation" => "BEL",
        "organizer" => "KSK Gent",
        "publish_mode" => "timed",
        "publish_delay_minutes" => "10"
      })

    lv = open_new_form(conn)

    lv
    |> form("#new-tournament-form", %{
      "tournament" => %{"name" => "Clubkampioenschap", "city" => "Brugge"}
    })
    |> render_submit()

    [{t, _count, true}] = Tournaments.list_tournaments(scope)
    assert t.name == "Clubkampioenschap"
    assert t.city == "Brugge"
    assert t.federation == "BEL"
    assert t.organizer == "KSK Gent"
    assert t.publish_mode == "timed"
    assert t.publish_delay_minutes == 10
  end

  test "defaults saved in another tab are used without a reload", %{conn: conn, user: user} do
    {:ok, lv, _html} = live(conn, ~p"/")
    {:ok, _} = Accounts.update_tournament_defaults(user, %{"rounds_count" => "5"})

    lv |> element("button[phx-click='new']") |> render_click()

    assert has_element?(
             lv,
             "#new-tournament-form input[name='tournament[rounds_count]'][value='5']"
           )
  end
end
