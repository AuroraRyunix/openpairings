defmodule PairingsEngineWeb.NormsLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.Tournaments

  setup :register_and_log_in_user

  test "renders download links for all four forms and lists players", %{conn: conn, scope: scope} do
    {:ok, tournament} = Tournaments.create_tournament(scope, %{"name" => "Norms LV", "type" => "swiss"})
    {:ok, _player} = Tournaments.create_player(tournament.id, %{"name" => "Doe, Jane"})

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/norms")

    assert html =~ "Norms &amp; FIDE reports"
    assert html =~ ~s(href="/t/#{tournament.id}/norms/it3")
    assert html =~ ~s(action="/t/#{tournament.id}/norms/fa1")
    assert html =~ ~s(href="/t/#{tournament.id}/norms/it4")
    assert html =~ "Doe, Jane"
    assert html =~ "No players have a claimed title yet"
  end

  test "editing a player's norm data persists it and it then shows up as an IT4 candidate", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} = Tournaments.create_tournament(scope, %{"name" => "Norms LV", "type" => "swiss"})
    {:ok, player} = Tournaments.create_player(tournament.id, %{"name" => "Doe, Jane"})

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/norms")

    lv |> element("button", "Edit norm data") |> render_click()

    html =
      lv
      |> form("form[phx-submit=save_norm]", %{
        "player" => %{
          "norm_data" => %{
            "title_claimed" => "IM",
            "norm_description" => "IM norm",
            "medal_percent" => "",
            "event_group" => "",
            "fed_participating" => "",
            "fed_members" => "",
            "remarks" => ""
          }
        }
      })
      |> render_submit()

    refute html =~ "No players have a claimed title yet"
    assert html =~ "IM norm"

    updated = Tournaments.get_player!(player.id)
    assert updated.norm_data["title_claimed"] == "IM"
  end
end
