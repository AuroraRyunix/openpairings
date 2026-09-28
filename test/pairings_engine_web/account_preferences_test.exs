defmodule PairingsEngineWeb.AccountPreferencesTest do
  @moduledoc """
  Preferences stored on the account reaching a browser: the language by the
  session (`Plugs.AccountLocale`, `LocaleController`), the theme and accent
  by attributes on `<html>` (`AccountPreferences.html_attrs/1`), and the
  device label in the sessions list (`UserAgent`).
  """
  use PairingsEngineWeb.ConnCase, async: false

  import PairingsEngine.AccountsFixtures
  import Phoenix.LiveViewTest

  alias PairingsEngine.Accounts
  alias PairingsEngineWeb.{AccountPreferences, UserAgent}

  describe "language stored on the account" do
    test "wins over the browser's on the next page", %{conn: conn} do
      user = user_fixture()
      {:ok, user} = Accounts.update_user_preferences(user, %{"locale" => "nl"})

      conn =
        conn
        |> log_in_user(user)
        |> put_req_header("accept-language", "en-GB,en;q=0.9")
        |> get(~p"/changelog")

      assert get_session(conn, "locale") == "nl"
      assert html_response(conn, 200) =~ ~s(lang="nl")
    end

    test "an account without one leaves the browser's choice alone", %{conn: conn} do
      conn =
        conn
        |> log_in_user(user_fixture())
        |> put_req_header("accept-language", "nl-BE")
        |> get(~p"/changelog")

      assert get_session(conn, "locale") == "nl"
    end

    test "the top-bar switch stores the pick on the account", %{conn: conn} do
      user = user_fixture()
      conn |> log_in_user(user) |> get(~p"/locale/nl?redirect_to=/")

      assert Accounts.get_user!(user.id).locale == "nl"
    end

    test "the switch still works signed out, and stores nothing", %{conn: conn} do
      conn = get(conn, ~p"/locale/nl?redirect_to=/changelog")
      assert get_session(conn, "locale") == "nl"
    end

    test "a pick made on this device is not undone by the account's old one", %{conn: conn} do
      user = user_fixture()
      {:ok, user} = Accounts.update_user_preferences(user, %{"locale" => "nl"})

      conn = conn |> log_in_user(user) |> get(~p"/locale/en?redirect_to=/changelog")
      conn = conn |> recycle() |> get(~p"/changelog")

      assert get_session(conn, "locale") == "en"
    end

    test "reaches the LiveView too", %{conn: conn} do
      user = user_fixture()
      {:ok, user} = Accounts.update_user_preferences(user, %{"locale" => "nl"})

      {:ok, _lv, html} = conn |> log_in_user(user) |> live(~p"/users/settings")

      assert html =~ "Voorkeuren"
    end
  end

  describe "html_attrs/1" do
    test "carries only what the account stores" do
      user = user_fixture()
      scope = Accounts.Scope.for_user(user)
      assert AccountPreferences.html_attrs(scope) == %{}
      assert AccountPreferences.html_attrs(nil) == %{}

      {:ok, user} = Accounts.update_user_preferences(user, %{"theme" => "board"})

      assert AccountPreferences.html_attrs(Accounts.Scope.for_user(user)) == %{
               "data-account-theme" => "board"
             }

      {:ok, user} = Accounts.update_user_preferences(user, %{"accent" => "cyan"})

      assert %{"data-account-accent" => "cyan"} =
               AccountPreferences.html_attrs(Accounts.Scope.for_user(user))
    end

    test "never writes a value the page does not know, whatever the row says" do
      user = %{user_fixture() | theme: "nord", accent: "javascript:"}
      assert AccountPreferences.html_attrs(Accounts.Scope.for_user(user)) == %{}
    end
  end

  describe "sessions remember the browser" do
    test "logging in records the user-agent on the session", %{conn: conn} do
      user = user_fixture() |> set_password()

      conn
      |> put_req_header(
        "user-agent",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) Firefox/131.0"
      )
      |> post(~p"/users/log-in", %{
        "user" => %{"email" => user.email, "password" => valid_user_password()}
      })

      assert [session] = Accounts.list_user_sessions(user)
      assert UserAgent.parse(session.user_agent) == {"Firefox", "macOS"}
    end

    test "the label is crude but right for the common browsers" do
      assert UserAgent.parse(nil) == {nil, nil}

      assert UserAgent.parse(
               "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Safari/537.36 Edg/129.0"
             ) == {"Edge", "Windows"}

      assert UserAgent.parse(
               "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Mobile Safari/537.36"
             ) == {"Chrome", "Android"}

      assert UserAgent.mobile?(
               "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) Safari/604.1"
             )

      refute UserAgent.mobile?("Mozilla/5.0 (X11; Linux x86_64) Firefox/131.0")
    end
  end
end
