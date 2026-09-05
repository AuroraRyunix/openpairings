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

  alias PairingsEngine.{Accounts, Audit, Publishing, Tournaments}
  alias PairingsEngine.Federations.BEL.SwarUpload

  setup :register_and_log_in_user

  # The `.swar` link belongs to the Belgian pack and is absent for an account
  # that has not switched it on, so the one test that expects it says so with
  # `@tag :enable_features`. Everything else here runs on a plain account,
  # which is what the default is.
  setup context do
    if context[:enable_features], do: enable_federation_features(context), else: :ok
  end

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

  @tag :enable_features
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

  # Every request in here goes through `Req.Test` (see the
  # `:bel_swar_upload_req_plug` in config/test.exs), which raises rather
  # than falling through to the network whenever a call reaches it with
  # nothing stubbed - so nothing in this describe block can reach
  # frbe-kbsb.be even by mistake. See `SwarUpload`'s moduledoc.
  describe "publishing to the federation's results site" do
    defp stub_swar(fun), do: Req.Test.stub(PairingsEngine.Federations.BEL.SwarUploadTest, fun)

    defp make_admin(user) do
      {:ok, admin} = Accounts.set_role(user.email, "admin")
      admin
    end

    test "absent for an account that has not switched the feature on", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/export")

      refute html =~ "Publish to the federation's results site"
      refute html =~ "swar_publish"
    end

    @tag :enable_features
    test "shown but disabled for an account without the admin role", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/export")

      assert html =~ "Publish to the federation&#39;s results site"
      assert html =~ "Publishing to the federation needs an administrator."

      # The button itself renders `disabled` for a non-admin, which
      # `element/2 |> render_click/1` honours (it raises rather than firing
      # the event) - the same way a browser would refuse the click. The
      # handler's OWN re-check is what a crafted event bypassing the DOM
      # entirely is for, so that is pushed directly here.
      html = render_click(lv, "swar_publish")
      assert html =~ "Publishing to the federation&#39;s results site needs an administrator."

      reloaded = Tournaments.get_tournament!(tournament.id)
      assert reloaded.swar_published_at == nil
      assert Audit.list_for_tournament(tournament.id, actions: ["swar.published"]) == []
    end

    @tag :enable_features
    test "an administrator publishes both steps, the page shows when, and it is audited", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      admin = make_admin(user)
      tournament = create_tournament(scope)

      stub_swar(fn conn ->
        case conn.method do
          "PUT" -> Plug.Conn.send_resp(conn, 200, "")
          "GET" -> Plug.Conn.send_resp(conn, 200, "<html>OK</html>")
        end
      end)

      {:ok, lv, _html} = live(log_in_user(conn, admin), ~p"/t/#{tournament.id}/settings/export")

      html = lv |> element("button[phx-click=swar_publish]") |> render_click()

      assert html =~ "Last published:"
      refute html =~ "Finish indexing"

      reloaded = Tournaments.get_tournament!(tournament.id)
      assert %DateTime{} = reloaded.swar_uploaded_at
      assert %DateTime{} = reloaded.swar_published_at
      assert is_binary(reloaded.swar_guid) and reloaded.swar_guid != ""

      [entry] = Audit.list_for_tournament(tournament.id, actions: ["swar.published"])
      assert entry.action == "swar.published"
      assert entry.details["guid"] == reloaded.swar_guid
      assert entry.user_id == admin.id
    end

    @tag :enable_features
    test "a failed upload is surfaced, changes nothing, and is audited", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      admin = make_admin(user)
      tournament = create_tournament(scope)

      stub_swar(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!([%{"message" => "meta-error", "value" => "bad Guid date"}])
        )
      end)

      {:ok, lv, _html} = live(log_in_user(conn, admin), ~p"/t/#{tournament.id}/settings/export")

      html = lv |> element("button[phx-click=swar_publish]") |> render_click()
      assert html =~ "meta-error: bad Guid date"

      reloaded = Tournaments.get_tournament!(tournament.id)
      assert reloaded.swar_uploaded_at == nil
      assert reloaded.swar_published_at == nil

      [entry] = Audit.list_for_tournament(tournament.id, actions: ["swar.publish_failed"])
      assert entry.details["step"] == "upload"
      assert entry.details["error"] == "meta-error: bad Guid date"
    end

    @tag :enable_features
    test "an upload that lands but is not indexed offers 'Finish indexing', which recovers", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      admin = make_admin(user)
      tournament = create_tournament(scope)

      stub_swar(fn conn ->
        case conn.method do
          "PUT" -> Plug.Conn.send_resp(conn, 200, "")
          "GET" -> Req.Test.transport_error(conn, :timeout)
        end
      end)

      {:ok, lv, _html} = live(log_in_user(conn, admin), ~p"/t/#{tournament.id}/settings/export")

      html = lv |> element("button[phx-click=swar_publish]") |> render_click()
      assert html =~ "Finish indexing"
      assert html =~ "not confirmed it is indexed yet"

      after_upload = Tournaments.get_tournament!(tournament.id)
      assert %DateTime{} = after_upload.swar_uploaded_at
      assert after_upload.swar_published_at == nil
      assert SwarUpload.staged_but_not_indexed?(after_upload)

      stub_swar(fn conn ->
        assert conn.method == "GET"
        Plug.Conn.send_resp(conn, 200, "<html>OK</html>")
      end)

      html = lv |> element("button[phx-click=swar_retry_index]") |> render_click()
      refute html =~ "Finish indexing"
      assert html =~ "Last published:"

      recovered = Tournaments.get_tournament!(tournament.id)
      assert %DateTime{} = recovered.swar_published_at
      refute SwarUpload.staged_but_not_indexed?(recovered)
    end

    @tag :enable_features
    test "the confirmation names the tournament and the federation's site", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      admin = make_admin(user)
      tournament = create_tournament(scope, %{"name" => "Gent Winter Open"})

      {:ok, _lv, html} = live(log_in_user(conn, admin), ~p"/t/#{tournament.id}/settings/export")

      assert html =~ "Gent Winter Open"
      assert html =~ "frbe-kbsb.be"
      assert html =~ "data-confirm="
    end
  end

  describe "the players CSV card" do
    # The download link IS the state: everything the picker does has to end
    # up in this href, because that is all the controller ever sees.
    defp csv_link(lv) do
      [_, href] = Regex.run(~r/href="([^"]*export\/players[^"]*)"/, render(lv))
      href |> String.replace("&amp;", "&") |> URI.decode()
    end

    defp click(lv, event, key) do
      lv
      |> element(~s(button[phx-click="#{event}"][phx-value-key="#{key}"]))
      |> render_click()
    end

    test "offers the standard columns and a link that carries them", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/export")

      assert html =~ "Export players (CSV)"
      assert csv_link(lv) =~ "cols=pairing_number,name,title,fide_rating,national_rating"
      assert csv_link(lv) =~ "delimiter=comma"
      assert csv_link(lv) =~ "sort=seed"
    end

    test "a field can be added and removed", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/export")

      click(lv, "csv_add", "category")
      assert csv_link(lv) =~ "category"

      click(lv, "csv_remove", "category")
      refute csv_link(lv) =~ "category"
    end

    test "a field can be moved, and the link says so", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/export")

      # Default order starts pairing_number,name - move name in front of it.
      click(lv, "csv_up", "name")
      assert csv_link(lv) =~ "cols=name,pairing_number,"

      click(lv, "csv_down", "name")
      assert csv_link(lv) =~ "cols=pairing_number,name,"
    end

    test "the ends of the list cannot be moved off it", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings/export")

      # The first row's "up" and the last row's "down" are disabled, so the
      # list cannot be walked off either end.
      assert html =~ "disabled"
      before = csv_link(lv)
      render_click(lv, "csv_up", %{"key" => "pairing_number"})
      assert csv_link(lv) == before
    end

    test "separator, row order and both toggles reach the link", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/export")

      render_change(lv, "csv_opts", %{
        "delimiter" => "semicolon",
        "sort" => "name",
        "skip_absent" => "true",
        "bom" => "false"
      })

      link = csv_link(lv)
      assert link =~ "delimiter=semicolon"
      assert link =~ "sort=name"
      assert link =~ "skip_absent=1"
      assert link =~ "bom=0"
    end

    test "a crafted key changes nothing", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/export")

      before = csv_link(lv)
      render_click(lv, "csv_add", %{"key" => "not_a_column"})
      render_click(lv, "csv_remove", %{"key" => "Elixir.PairingsEngine"})
      assert csv_link(lv) == before
    end

    test "the link actually downloads a CSV shaped the way the picker says", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      PairingsEngine.Repo.insert!(%PairingsEngine.Tournaments.Player{
        tournament_id: tournament.id,
        name: "Zoe",
        pairing_number: 2
      })

      PairingsEngine.Repo.insert!(%PairingsEngine.Tournaments.Player{
        tournament_id: tournament.id,
        name: "Abe",
        pairing_number: 1
      })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/export")

      render_change(lv, "csv_opts", %{
        "delimiter" => "semicolon",
        "sort" => "name",
        "bom" => "false"
      })

      body = conn |> get(csv_link(lv)) |> response(200)

      assert body =~ "Name;"
      assert body =~ "Abe"
      # Sorted by name, so Abe precedes Zoe even though Zoe has no lower seed.
      assert :binary.match(body, "Abe") < :binary.match(body, "Zoe")
    end
  end
end
