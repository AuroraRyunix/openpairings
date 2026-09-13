defmodule PairingsEngineWeb.TeamSwissLiveTest do
  @moduledoc """
  The pages team Swiss and the initial colour touch: Settings - Options (the
  initial-colour setting and its lock), Pairings (the colour line and the
  matches), Standings (the team table) and Teams (which notice shows).
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{Pairing, Repo, Tournaments}

  setup :register_and_log_in_user

  defp teams(n), do: for(i <- 1..n, do: {"T#{i}", [2000 - i * 10, 1990 - i * 10]})

  defp swiss(scope, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Colour LV", "type" => "swiss", "rounds_count" => "5"}, attrs)
      )

    for {name, rating} <- [{"Alice", 2000}, {"Bob", 1900}, {"Carol", 1800}, {"Dave", 1700}] do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => name, "fide_rating" => "#{rating}"})
    end

    t
  end

  describe "Settings - Options: initial colour" do
    test "offers drawn by lot, White and Black, and saves a choice", %{conn: conn, scope: scope} do
      t = swiss(scope)
      {:ok, lv, html} = live(conn, ~p"/t/#{t.id}/settings/options")

      assert html =~ "Initial colour"
      assert has_element?(lv, "#initial-colour-select option[value='lot'][selected]")
      assert has_element?(lv, "#initial-colour-select option[value='white']")
      assert has_element?(lv, "#initial-colour-select option[value='black']")
      refute has_element?(lv, "#initial-colour-status")

      lv
      |> form("#pairing-settings-form", %{"tournament" => %{"initial_colour" => "black"}})
      |> render_submit()

      assert Repo.reload!(t).initial_colour == "black"
      assert render(lv) =~ "Initial colour: Black, set by the arbiter"
    end

    test "after round 1 it shows the draw and is locked", %{conn: conn, scope: scope} do
      t = swiss(scope)
      {:ok, _} = Pairing.pair_next_round(t)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/options")

      assert has_element?(lv, "#initial-colour-select[disabled]")
      assert has_element?(lv, "#initial-colour-status", "Initial colour: drawn by lot: White")

      # A crafted save cannot change it.
      lv
      |> form("#pairing-settings-form")
      |> render_submit(%{"tournament" => %{"initial_colour" => "black"}})

      assert Repo.reload!(t).initial_colour == "lot"
    end
  end

  describe "Pairings" do
    test "shows the drawn initial colour once round 1 is paired", %{conn: conn, scope: scope} do
      t = swiss(scope)
      {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings")
      refute html =~ "Initial colour:"

      {:ok, _} = Pairing.pair_next_round(t)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      assert has_element?(lv, "#initial-colour", "Initial colour: drawn by lot: White")
    end

    test "a team Swiss lists its matches and the bye", %{conn: conn, scope: scope} do
      {t, _} = team_swiss(teams(3), user_id: scope.user.id)
      {:ok, _} = Pairing.pair_next_round(t)

      {:ok, lv, html} = live(conn, ~p"/t/#{t.id}/pairings")

      assert has_element?(lv, "#team-matches")
      assert html =~ "pairing-allocated bye, scored as a drawn match"
    end
  end

  describe "Standings" do
    test "a team Swiss paired by teams shows the team table", %{conn: conn, scope: scope} do
      {t, _} = team_swiss(teams(4), user_id: scope.user.id)
      {:ok, _} = Pairing.pair_next_round(t)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/standings")
      assert has_element?(lv, "#team-standings")
    end

    test "a team Swiss paired player by player keeps the individual table", %{
      conn: conn,
      scope: scope
    } do
      {t, _} = team_swiss(teams(4), user_id: scope.user.id, team_pairing_mode: "players")
      {:ok, _} = Pairing.pair_next_round(t)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/standings")
      refute has_element?(lv, "#team-standings")
    end
  end

  describe "Teams" do
    test "a team Swiss paired by teams shows no not-by-team notice", %{conn: conn, scope: scope} do
      {t, _} = team_swiss(teams(4), user_id: scope.user.id)
      {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/teams")

      refute html =~ "pairs player by player"
      refute html =~ "Not paired by team"
    end

    test "an old team Swiss says it carries on player by player", %{conn: conn, scope: scope} do
      {t, _} = team_swiss(teams(4), user_id: scope.user.id, team_pairing_mode: "players")
      {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/teams")

      assert html =~ "This team Swiss pairs player by player"
    end
  end
end
