defmodule PairingsEngineWeb.SettingsTiebreakPickerTest do
  # async: false: sequential SQLite writes, like the other Settings LiveView tests.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Standings, Tournaments}

  setup :register_and_log_in_user

  defp create_tournament(scope) do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Picker",
        "type" => "swiss",
        "rounds_count" => "5"
      })

    tournament
  end

  test "the picker offers every C.07 tie-break, in groups", %{conn: conn, scope: scope} do
    tournament = create_tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

    for code <- ~w(AOB AOB/F APPO APRO ARO/C2 BWG DE/P FB/M2 PS/C1 PTP REP RTNG/R SB/C2 STD
                   TPN/R TPR KS/L-2) do
      assert has_element?(lv, ~s(select[name="code"] optgroup option[value="#{code}"]))
    end

    assert has_element?(lv, ~s(select[name="code"] optgroup[label="Rating-based"]))
    assert has_element?(lv, ~s(select[name="code"] optgroup[label="Buchholz"]))
  end

  test "adding a tie-break from a group puts it in the list and takes it out of the picker", %{
    conn: conn,
    scope: scope
  } do
    tournament = create_tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

    lv |> element(~s(select[name="code"])) |> render_change(%{"code" => "FB/C1"})

    assert has_element?(lv, "#tiebreak-editor", "Fore Buchholz Cut-1")
    refute has_element?(lv, ~s(select[name="code"] option[value="FB/C1"]))
  end

  test "the unrated rating and the shared place are saved with the tie-breaks", %{
    conn: conn,
    scope: scope
  } do
    tournament = create_tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

    assert has_element?(lv, "#tiebreak-unrated-rating")
    refute has_element?(lv, "#shared-places[checked]")

    lv |> element(~s(select[name="code"])) |> render_change(%{"code" => "TPR"})

    lv
    |> form("#tournament-settings-form", %{
      "tournament" => %{"tiebreak_unrated_rating" => "1300", "shared_places" => "true"}
    })
    |> render_submit()

    saved = Tournaments.get_tournament!(tournament.id)
    assert "TPR" in saved.tiebreaks
    assert saved.tiebreak_unrated_rating == 1300
    assert saved.shared_places == true
    assert Standings.dropped_tiebreaks(saved) == []

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")
    assert has_element?(lv, "#shared-places[checked]")
    assert has_element?(lv, ~s(#tiebreak-unrated-rating[value="1300"]))
  end

  test "players level at the end show a shared place on the standings page", %{
    conn: conn,
    scope: scope
  } do
    tournament = create_tournament(scope)
    {:ok, _} = Tournaments.update_tournament(tournament, %{shared_places: true, tiebreaks: []})

    for name <- ~w(Alice Bob Carol) do
      {:ok, _} = Tournaments.create_player(tournament.id, %{"name" => name})
    end

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")
    assert html =~ "1="
  end
end
