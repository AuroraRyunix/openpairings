defmodule PairingsEngineWeb.SettingsExportLiveTest do
  @moduledoc """
  The "Export / backup" settings page - split out from
  `SettingsTournamentLive` on 2026-08-29. That page never had tests of its
  own for this card (the actual export bytes are covered end-to-end by
  `PairingsEngineWeb.ExportControllerTest`), so everything here is new:
  the tab is reachable, and moving the card did not break what it links to.
  """
  # async: false: sequential SQLite writes, same rationale as the other
  # Settings LiveView tests.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Publishing, Tournaments}

  setup :register_and_log_in_user

  defp create_tournament(scope, attrs \\ %{}) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Export LV Test", "type" => "swiss", "rounds_count" => "5"}, attrs)
      )

    tournament
  end

  test "reachable from the Settings subnav", %{conn: conn, scope: scope} do
    tournament = create_tournament(scope)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")

    assert html =~ ~s(href="/t/#{tournament.id}/settings/export")
  end

  test "shows the JSON and .swar export links, and both still actually export", %{
    conn: conn,
    scope: scope
  } do
    tournament = create_tournament(scope)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/export")

    assert html =~ "Export / backup"
    assert html =~ "Export full backup (JSON)"
    assert html =~ "Export .swar (v7, experimental)"
    assert html =~ ~s(href="/t/#{tournament.id}/export/json")
    assert html =~ ~s(href="/t/#{tournament.id}/export/swar")

    # The card only moved pages - what it links to still has to work.
    json_conn = get(conn, ~p"/t/#{tournament.id}/export/json")
    assert response_content_type(json_conn, :json) =~ "application/json"
    assert %{"format" => "openpairings-export"} = json_conn |> response(200) |> Jason.decode!()

    swar_conn = get(conn, ~p"/t/#{tournament.id}/export/swar")
    [content_type] = get_resp_header(swar_conn, "content-type")
    assert content_type =~ "application/octet-stream"
    response(swar_conn, 200)
  end

  test "the publishing-key warning only shows once this tournament has actually published", %{
    conn: conn,
    scope: scope
  } do
    tournament = create_tournament(scope)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/export")
    refute html =~ "carries this tournament&#39;s publishing key"

    Publishing.put_endpoint("https://openresults.example/")
    Publishing.put_token("s3cret")
    # The request goes out from a Task, not from the test's own process, so a
    # stub owned by this process would never be found - same reason the
    # Results-site tests share theirs.
    Req.Test.set_req_test_to_shared(%{})

    Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
      Req.Test.json(conn, %{"ok" => true})
    end)

    {:ok, tournament} = Tournaments.set_publish_to_openresults(tournament, true)
    {:ok, _} = Publishing.publish(tournament)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/export")
    assert html =~ "carries this tournament&#39;s publishing key"
  end
end
