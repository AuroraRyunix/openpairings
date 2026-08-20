defmodule PairingsEngineWeb.FideLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Accounts, Fide, Kbsb}
  alias PairingsEngine.Repo
  alias PairingsEngine.Kbsb.KbsbPlayer

  setup :register_and_log_in_user

  test "renders both the FIDE and KBSB sections under the 'Rating lists' heading", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/fide")

    assert html =~ "Rating lists</h1>"
    assert html =~ "FIDE database"
    assert html =~ "Belgian national rating list (KBSB/FRBE)"
    assert html =~ "players in the local database."
  end

  test "the nav label reads 'Rating lists', not 'FIDE database'", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/fide")

    assert html =~ ~s(href="/fide")
    assert html =~ "Rating lists"
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
    # crashed and silently reconnected — indistinguishable from "no
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
