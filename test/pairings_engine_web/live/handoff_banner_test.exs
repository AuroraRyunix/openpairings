defmodule PairingsEngineWeb.HandoffBannerTest do
  @moduledoc """
  The handed-off banner, rendered in the app layout so it cannot be forgotten
  on one page.

  It matters more than the archive banner it sits beside. An arbiter looking
  at an archived tournament knows they archived it; an arbiter looking at a
  handed-off one may be looking at a copy of an event somebody else is
  running right now, and the only thing on the screen that says so is this.
  """
  # async: false: sequential SQLite writes, same as the archive UI suite.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.Tournaments

  setup :register_and_log_in_user

  defp create_tournament(scope, attrs \\ %{}) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Handoff UI Test", "type" => "swiss", "rounds_count" => "3"}, attrs)
      )

    tournament
  end

  test "every page of a handed-off tournament carries the banner", %{conn: conn, scope: scope} do
    tournament = create_tournament(scope)
    {:ok, _} = Tournaments.hand_off(tournament, "the club laptop")

    for path <- [
          ~p"/t/#{tournament.id}/players",
          ~p"/t/#{tournament.id}/pairings",
          ~p"/t/#{tournament.id}/standings",
          ~p"/t/#{tournament.id}/settings"
        ] do
      {:ok, _lv, html} = live(conn, path)

      assert html =~ "handed off", "expected the banner on #{path}"
      assert html =~ "archived-banner"
    end
  end

  test "it says where the tournament went, and when", %{conn: conn, scope: scope} do
    tournament = create_tournament(scope)
    {:ok, handed} = Tournaments.hand_off(tournament, "the club laptop")

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

    assert html =~ "the club laptop"
    assert html =~ Calendar.strftime(handed.handed_off_at, "%Y-%m-%d %H:%M UTC")
    assert html =~ "read-only"
  end

  test "a blank destination still produces a whole sentence", %{conn: conn, scope: scope} do
    tournament = create_tournament(scope)
    {:ok, _} = Tournaments.hand_off(tournament, "   ")

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

    assert html =~ "handed off to another copy"
  end

  test "a live tournament carries no banner at all", %{conn: conn, scope: scope} do
    tournament = create_tournament(scope)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

    refute html =~ "archived-banner"
    refute html =~ "handed off"
  end

  test "the banner goes away the moment the tournament comes back", %{conn: conn, scope: scope} do
    tournament = create_tournament(scope)
    {:ok, handed} = Tournaments.hand_off(tournament, "the club laptop")
    {:ok, _} = Tournaments.take_back(handed, handed.handoff_token)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

    refute html =~ "archived-banner"
  end

  test "a destination an arbiter typed is escaped, not rendered as markup", %{
    conn: conn,
    scope: scope
  } do
    # `handed_off_to` is free text that arrives from another machine's
    # payload as readily as from a form.
    tournament = create_tournament(scope)
    {:ok, _} = Tournaments.hand_off(tournament, "<script>alert(1)</script>")

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

    refute html =~ "<script>alert(1)</script>"
    assert html =~ "&lt;script&gt;"
  end
end
