defmodule PairingsEngineWeb.AuditLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest
  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Audit, Pairing, Tournaments}

  setup :register_and_log_in_user

  defp make_tournament(scope) do
    {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Audit T", "type" => "swiss"})
    t
  end

  test "renders audit entries as readable sentences", %{conn: conn, scope: scope} do
    t = make_tournament(scope)

    Audit.log(t.id, scope, "player.created", %{player_id: 1, player_name: "Alice", rating: 1800})
    Audit.log(t.id, scope, "pairing.round_deleted", %{round: 3})

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/audit")

    assert html =~ "Registered player Alice"
    assert html =~ "Unpaired round 3"
    # Acting user shown by email.
    assert html =~ scope.user.email
  end

  test "a machine-wide row (no tournament) never appears on a tournament's own trail", %{
    conn: conn,
    scope: scope
  } do
    t = make_tournament(scope)

    Audit.log(t.id, scope, "player.created", %{player_name: "Alice"})
    Audit.log_system(scope, "backup.downloaded", %{filename: "whole-db.db"})

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/audit")

    assert html =~ "Registered player Alice"
    refute html =~ "whole-db.db"
    refute html =~ "Downloaded a backup"
    # The page still renders normally - a nil-tournament row elsewhere in the
    # table does not raise inside `describe/1` or anything else on this page.
    assert html =~ "1 event total."
  end

  test "the category filter narrows the list", %{conn: conn, scope: scope} do
    t = make_tournament(scope)

    Audit.log(t.id, scope, "player.created", %{player_name: "Alice"})

    Audit.log(t.id, scope, "tournament.settings_updated", %{
      changed_fields: %{"name" => ["A", "B"]}
    })

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/audit")

    html = lv |> element("button", "Players") |> render_click()
    assert html =~ "Registered player Alice"
    refute html =~ "Updated tournament settings"

    html = lv |> element("button", "Settings") |> render_click()
    assert html =~ "Updated tournament settings"
    refute html =~ "Registered player Alice"
  end

  test "a non-collaborator cannot open another user's audit page", %{conn: conn} do
    other = user_scope_fixture()
    {:ok, t} = Tournaments.create_tournament(other, %{"name" => "Not Yours", "type" => "swiss"})

    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/t/#{t.id}/audit")
    end
  end

  test "the top-bar Advanced menu links to both the audit trail and the explain picker", %{
    conn: conn,
    scope: scope
  } do
    t = make_tournament(scope)

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/audit")

    assert html =~ "Advanced"
    assert html =~ ~s(href="/t/#{t.id}/audit")
    assert html =~ ~s(href="/t/#{t.id}/audit/explain")
  end

  test "the sub-nav highlights the current page and links to the other two", %{
    conn: conn,
    scope: scope
  } do
    t = make_tournament(scope)

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/audit")
    assert lv |> element("a.filter-picker", "Audit trail") |> render() =~ "active"
    refute lv |> element("a.filter-picker", "Pairing rationale") |> render() =~ "active"
    refute lv |> element("a.filter-picker", "History") |> render() =~ "active"

    {:ok, lv2, _html2} = live(conn, ~p"/t/#{t.id}/audit/explain")
    assert lv2 |> element("a.filter-picker", "Pairing rationale") |> render() =~ "active"
    refute lv2 |> element("a.filter-picker", "Audit trail") |> render() =~ "active"

    {:ok, lv3, _html3} = live(conn, ~p"/t/#{t.id}/history")
    assert lv3 |> element("a.filter-picker", "History") |> render() =~ "active"
    refute lv3 |> element("a.filter-picker", "Audit trail") |> render() =~ "active"
  end

  test "the explain picker lists exactly the paired rounds", %{conn: conn, scope: scope} do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "RR",
        "type" => "roundrobin",
        "pairing_system" => "round_robin"
      })

    for name <- ~w(Alice Bob Carol Dave) do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => name})
    end

    assert {:ok, _round} = Pairing.pair_next_round(t)

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/audit/explain")

    assert html =~ ~s(href="/t/#{t.id}/pairings/1/explain")
    refute html =~ ~s(href="/t/#{t.id}/pairings/2/explain")
  end

  test "the explain picker shows a message when nothing is paired yet", %{
    conn: conn,
    scope: scope
  } do
    t = make_tournament(scope)

    {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/audit/explain")
    assert html =~ "No rounds have been paired yet"
  end
end
