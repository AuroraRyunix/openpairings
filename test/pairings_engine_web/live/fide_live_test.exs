defmodule PairingsEngineWeb.FideLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Accounts, Fide, Kbsb}
  alias PairingsEngine.Repo
  alias PairingsEngine.Kbsb.KbsbPlayer

  setup :register_and_log_in_user

  test "renders every outbound connection under the 'Connections' heading", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/fide")

    # Renamed from "Rating lists" when the OpenResults settings landed here.
    # The page stopped being only about rating lists the moment it also held
    # where this machine publishes to.
    assert html =~ "Connections</h1>"
    assert html =~ "FIDE database"
    assert html =~ "Belgian national rating list (KBSB/FRBE)"
    assert html =~ "players in the local database."
    assert html =~ "Public results site (OpenResults)"
  end

  test "the nav still points here", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/fide")

    assert html =~ ~s(href="/fide")
    assert html =~ "Connections"
  end

  describe "the OpenResults settings" do
    alias PairingsEngine.Publishing

    # Saving now tests the connection, so every test in here makes a request
    # whether it means to or not. A default stub keeps a test about token
    # handling from failing on the network; the ones that care about the
    # connection re-stub with what they need.
    setup do
      Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
        Plug.Conn.send_resp(conn, 404, ~s({"error":"not_found"}))
      end)

      :ok
    end

    defp sso_conn(conn) do
      {:ok, user} =
        Accounts.find_or_create_from_keycloak(%{
          sub: "sso-sub-#{System.unique_integer()}",
          email: "sso-user-#{System.unique_integer()}@example.com"
        })

      log_in_user(conn, user)
    end

    test "an ordinary account cannot change where this machine publishes", %{conn: conn} do
      Publishing.put_endpoint("https://openresults.example")
      Publishing.put_token("operators-token")

      {:ok, lv, _html} = live(conn, ~p"/fide")

      # Repointing this at another server would quietly ship player names,
      # ratings and clubs there, so it is an operator's decision rather than
      # an account holder's - and the guard is on the HANDLER, not just the
      # markup, because a hidden button still accepts a crafted event.
      lv
      |> form("form[phx-submit=save_publishing]", %{
        "endpoint" => "https://somewhere-else.example",
        "token" => "attackers-token"
      })
      |> render_submit()

      assert Publishing.endpoint() == "https://openresults.example"
      assert Publishing.token() == "operators-token"
    end

    test "an ordinary account cannot remove the token either", %{conn: conn} do
      Publishing.put_endpoint("https://openresults.example")
      Publishing.put_token("operators-token")

      {:ok, lv, _html} = live(conn, ~p"/fide")

      html = lv |> element("button[phx-click=clear_publishing_token]") |> render_click()

      assert Publishing.token() == "operators-token"
      assert html =~ "limited to SSO-signed-in accounts"
    end

    test "says nothing is published until both halves are set", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/fide")

      assert html =~ "Nothing is published until both an address and a token are set."
    end

    test "saving tests the connection, and says so when it answers", %{conn: conn} do
      Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
        Plug.Conn.send_resp(conn, 404, ~s({"error":"not_found"}))
      end)

      {:ok, lv, _html} = live(sso_conn(conn), ~p"/fide")

      html =
        lv
        |> form("form[phx-submit=save_publishing]", %{
          "endpoint" => "https://openresults.example",
          "token" => "s3cret"
        })
        |> render_submit()

      # "Saved" on its own answers the wrong question. Nobody types an address
      # to find out whether it was stored.
      assert html =~ "the results site answered"
    end

    test "a saved address that does not answer says so, and still saves", %{conn: conn} do
      Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      {:ok, lv, _html} = live(sso_conn(conn), ~p"/fide")

      html =
        lv
        |> form("form[phx-submit=save_publishing]", %{
          "endpoint" => "https://openresults.example",
          "token" => "s3cret"
        })
        |> render_submit()

      assert html =~ "did not answer"
      assert html =~ "refused"

      # Saved anyway: a typo you cannot correct because the form threw it away
      # is worse than one that is stored and reported.
      assert Publishing.endpoint() == "https://openresults.example"
    end

    test "saving half the settings says nothing is published yet", %{conn: conn} do
      {:ok, lv, _html} = live(sso_conn(conn), ~p"/fide")

      html =
        lv
        |> form("form[phx-submit=save_publishing]", %{
          "endpoint" => "https://openresults.example",
          "token" => ""
        })
        |> render_submit()

      assert html =~ "Nothing is published until both"
    end

    test "saving an address normalises it and keeps it", %{conn: conn} do
      {:ok, lv, _html} = live(sso_conn(conn), ~p"/fide")

      lv
      |> form("form[phx-submit=save_publishing]", %{
        "endpoint" => "openresults.example/",
        "token" => "s3cret"
      })
      |> render_submit()

      assert Publishing.endpoint() == "https://openresults.example"
      assert Publishing.token() == "s3cret"
    end

    test "an empty token box keeps the stored token instead of wiping it", %{conn: conn} do
      Publishing.put_endpoint("https://openresults.example")
      Publishing.put_token("keep-me")

      {:ok, lv, _html} = live(sso_conn(conn), ~p"/fide")

      # The token is a secret and is never rendered back, so the box is
      # always empty on load. Treating that as "clear it" would delete a
      # working token every time somebody edited the address beside it.
      lv
      |> form("form[phx-submit=save_publishing]", %{
        "endpoint" => "https://openresults.example",
        "token" => ""
      })
      |> render_submit()

      assert Publishing.token() == "keep-me"
      _ = lv
    end

    test "the token can be removed deliberately", %{conn: conn} do
      Publishing.put_endpoint("https://openresults.example")
      Publishing.put_token("remove-me")

      {:ok, lv, _html} = live(sso_conn(conn), ~p"/fide")

      lv |> element("button[phx-click=clear_publishing_token]") |> render_click()

      refute Publishing.token()
      refute Publishing.configured?()
    end

    test "the stored token is never rendered to the page", %{conn: conn} do
      Publishing.put_endpoint("https://openresults.example")
      Publishing.put_token("super-secret-value")

      {:ok, _lv, html} = live(conn, ~p"/fide")

      refute html =~ "super-secret-value"
      assert html =~ "a token is set"
    end
  end

  test "the KBSB list has no manual file upload any more", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/fide")

    refute html =~ ~s(id="kbsb-import-form")
    refute html =~ "Import file"
    refute html =~ "drag and drop"
  end

  test "searching the local KBSB database returns matches", %{conn: conn} do
    Repo.insert!(%KbsbPlayer{
      national_id: "12345",
      last_name: "Peeters",
      first_name: "Jan",
      national_rating: 1850,
      club_number: 42,
      club_name: "KSK Antwerpen",
      federation: "VSF",
      birth_year: 1990
    })

    {:ok, lv, _html} = live(conn, ~p"/fide")

    # Driven through the actual form element rather than by synthesising the
    # event: `render_change(lv, "kbsb_search", ...)` proves the handler
    # works, not that the PAGE can reach it. The search input once carried
    # phx-change on a bare <input> with no wrapping form, so LiveView sent
    # %{"value" => ...}, the handler never matched, and the whole LiveView
    # crashed and silently reconnected - indistinguishable from "no
    # results". A synthesised event cannot see that; this can.
    html = lv |> form("form.search-wrap", %{"q" => "Peet"}) |> render_change()

    assert html =~ "Peeters"
    assert html =~ "KSK Antwerpen"
  end

  test "an unknown KBSB search query returns no results", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/fide")

    html = lv |> form("form.search-wrap", %{"q" => "Nobody"}) |> render_change()

    refute html =~ "kbsb-result-row"
  end

  describe "FIDE download gated to SSO accounts" do
    test "a plain local account sees the button disabled and can't trigger sync", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/fide")

      assert html =~ "limited to SSO-signed-in accounts"
      assert lv |> element("button[phx-click='sync'][disabled]") |> has_element?()

      html = render_click(lv, "sync", %{})
      assert html =~ "limited to SSO-signed-in accounts"
    end

    test "an SSO account sees the button enabled, no restriction message", %{conn: conn} do
      {:ok, user} =
        Accounts.find_or_create_from_keycloak(%{
          sub: "sso-sub-#{System.unique_integer()}",
          email: "sso-user-#{System.unique_integer()}@example.com"
        })

      conn = log_in_user(conn, user)
      {:ok, lv, html} = live(conn, ~p"/fide")

      refute html =~ "limited to SSO-signed-in accounts"
      refute lv |> element("button[phx-click='sync'][disabled]") |> has_element?()
    end
  end

  describe "top-bar sync freshness strip" do
    test "shows 'never synced' for both lists when neither has synced", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/fide")

      assert html =~ "FIDE: never synced"
      assert html =~ "KBSB: never synced"
    end

    test "shows a relative time once a list has synced", %{conn: conn} do
      Fide.put_last_sync()

      {:ok, _lv, html} = live(conn, ~p"/fide")

      assert html =~ "FIDE: just now"
      assert html =~ "KBSB: never synced"
    end

    test "reflects both lists once both have synced", %{conn: conn} do
      Fide.put_last_sync()
      Kbsb.put_last_sync()

      {:ok, _lv, html} = live(conn, ~p"/fide")

      assert html =~ "FIDE: just now"
      assert html =~ "KBSB: just now"
    end
  end

  describe "KBSB data-platform sync button" do
    setup do
      original = Application.get_env(:pairings_engine, :kbsb)

      on_exit(fn ->
        if original,
          do: Application.put_env(:pairings_engine, :kbsb, original),
          else: Application.delete_env(:pairings_engine, :kbsb)
      end)

      :ok
    end

    test "is offered when the API is configured", %{conn: conn} do
      Application.put_env(:pairings_engine, :kbsb, api_url: "https://kbsb.test", api_key: "k")

      {:ok, _lv, html} = live(conn, ~p"/fide")

      assert html =~ "Sync from data platform"
      assert html =~ "phx-click=\"sync_kbsb_api\""
      # The empty-state copy should point at the button, not at a file.
      assert html =~ "sync it from the data platform to get started"
    end

    # Offering a button whose only possible outcome is an error message is
    # worse than not offering it: the arbiter cannot fix server config from
    # here, so the page tells them what to set instead.
    test "is hidden when it is not configured, with the setting named", %{conn: conn} do
      Application.delete_env(:pairings_engine, :kbsb)

      {:ok, _lv, html} = live(conn, ~p"/fide")

      refute html =~ "Sync from data platform"
      assert html =~ "KBSB_API_URL"
      assert html =~ "no source is configured"
    end
  end
end
