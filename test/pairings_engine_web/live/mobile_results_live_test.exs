defmodule PairingsEngineWeb.MobileResultsLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest
  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Audit, Mobile, Tournaments}
  alias PairingsEngineWeb.AuditLive
  alias PairingsEngine.Pairing, as: Engine

  defp enrolled_conn(conn, tournament) do
    {:ok, enrollment} = Mobile.create_enrollment(tournament.id)
    init_test_session(conn, %{mobile_enrollment_id: enrollment.id})
  end

  defp paired_tournament do
    scope = user_scope_fixture()

    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Mobile T", "type" => "swiss"})

    {:ok, _white} =
      Tournaments.create_player(tournament.id, %{
        "name" => "White Player",
        "fide_rating" => "2000"
      })

    {:ok, _black} =
      Tournaments.create_player(tournament.id, %{
        "name" => "Black Player",
        "fide_rating" => "1900"
      })

    assert {:ok, _round} = Engine.pair_next_round(tournament)
    tournament
  end

  @tag :javafo
  test "shows each player's rating and their score entering the round", %{conn: conn} do
    tournament = paired_tournament()
    conn = enrolled_conn(conn, tournament)

    {:ok, _lv, html} = live(conn, ~p"/m/results")

    assert html =~ "2000"
    assert html =~ "1900"
    assert html =~ "0 pts"
  end

  @tag :javafo
  test "locking blocks result entry until unlocked again", %{conn: conn} do
    tournament = paired_tournament()
    conn = enrolled_conn(conn, tournament)

    {:ok, lv, html} = live(conn, ~p"/m/results")
    refute html =~ "locked - tap the lock to enter results"

    pairing = tournament.id |> Tournaments.get_round(1) |> Map.fetch!(:pairings) |> hd()

    lv |> element("button.mobile-lock-btn") |> render_click()
    assert render(lv) =~ "locked - tap the lock to enter results"

    # The result buttons are also `disabled` while locked (Phoenix.LiveViewTest
    # itself refuses to click a disabled element, mirroring a real browser) -
    # send the event directly to exercise the actual server-side guard.
    render_click(lv, "set_result", %{"id" => to_string(pairing.id), "result" => "1-0"})

    assert Tournaments.get_round(tournament.id, 1).pairings
           |> Enum.find(&(&1.id == pairing.id))
           |> Map.fetch!(:result) == ""

    lv |> element("button.mobile-lock-btn") |> render_click()

    render_click(lv, "set_result", %{"id" => to_string(pairing.id), "result" => "1-0"})

    assert Tournaments.get_round(tournament.id, 1).pairings
           |> Enum.find(&(&1.id == pairing.id))
           |> Map.fetch!(:result) == "1-0"
  end

  describe "extra results (forfeits/asymmetric codes, behind \"More…\")" do
    @tag :javafo
    test "the extra codes are hidden until \"More…\" is tapped, then settable", %{conn: conn} do
      tournament = paired_tournament()
      conn = enrolled_conn(conn, tournament)

      {:ok, lv, html} = live(conn, ~p"/m/results")
      pairing = tournament.id |> Tournaments.get_round(1) |> Map.fetch!(:pairings) |> hd()

      refute html =~ "1-0 FF"

      html = lv |> element("button.mobile-more") |> render_click()
      assert html =~ "1-0 FF"
      assert html =~ "0-0 FF"

      render_click(lv, "set_result", %{"id" => to_string(pairing.id), "result" => "1-0FF"})

      assert Tournaments.get_round(tournament.id, 1).pairings
             |> Enum.find(&(&1.id == pairing.id))
             |> Map.fetch!(:result) == "1-0FF"
    end

    @tag :javafo
    test "a board already carrying an extra-code result shows its panel without a tap", %{
      conn: conn
    } do
      tournament = paired_tournament()
      round = Tournaments.get_round(tournament.id, 1)
      pairing = hd(round.pairings)
      Tournaments.update_pairing_result(pairing, "0-0FF")

      conn = enrolled_conn(conn, tournament)
      {:ok, _lv, html} = live(conn, ~p"/m/results")

      assert html =~ "0-0 FF (double forfeit)"
    end
  end

  describe "audit trail" do
    @tag :javafo
    test "entering a result from a phone writes an audit row (previously wrote nothing at all)",
         %{conn: conn} do
      tournament = paired_tournament()
      {:ok, enrollment} = Mobile.create_enrollment(tournament.id, label: "Board 3 tablet")
      conn = init_test_session(conn, %{mobile_enrollment_id: enrollment.id})

      {:ok, lv, _html} = live(conn, ~p"/m/results")

      round = Tournaments.get_round(tournament.id, 1)
      pairing = hd(round.pairings)

      render_click(lv, "set_result", %{"id" => to_string(pairing.id), "result" => "1-0"})

      [entry] = Audit.list_for_tournament(tournament.id)
      assert entry.action == "pairing.result_entered"
      assert entry.user_id == nil
      assert entry.details["via"] == "mobile"
      assert entry.details["enrollment_id"] == enrollment.id
      assert entry.details["enrollment_label"] == "Board 3 tablet"

      assert AuditLive.describe(entry.action, entry.details) =~
               ~s(via phone, "Board 3 tablet")
    end

    @tag :javafo
    test "a phone with no label is still identifiable, by enrollment id", %{conn: conn} do
      tournament = paired_tournament()
      {:ok, enrollment} = Mobile.create_enrollment(tournament.id)
      conn = init_test_session(conn, %{mobile_enrollment_id: enrollment.id})

      {:ok, lv, _html} = live(conn, ~p"/m/results")

      round = Tournaments.get_round(tournament.id, 1)
      pairing = hd(round.pairings)

      render_click(lv, "set_result", %{"id" => to_string(pairing.id), "result" => "1/2-1/2"})

      [entry] = Audit.list_for_tournament(tournament.id)

      assert AuditLive.describe(entry.action, entry.details) =~
               "via phone, enrollment ##{enrollment.id}"
    end
  end
end
