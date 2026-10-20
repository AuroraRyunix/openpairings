defmodule PairingsEngineWeb.UserLive.SettingsManubriumTest do
  @moduledoc "The account page's Manubrium app section: connecting a phone, and signing one out."
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.Manubrium

  setup :register_and_log_in_user

  defp connected_phone(scope) do
    {:ok, %{secret: secret}} = Manubrium.create_connect_code(scope, "http://test")
    {:ok, device, token} = Manubrium.redeem(secret, %{"name" => "Pixel of Anna"}, "10.2.2.2")
    {device, token}
  end

  test "says when no phone is connected, and is in the rail", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/users/settings")

    assert has_element?(view, "#manubrium")
    assert has_element?(view, "#manubrium-device-none")
    assert has_element?(view, ~s(a[href="#manubrium"]))
  end

  test "Connect a phone shows a one-time code for this server", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/users/settings")

    view |> element("#manubrium-connect-button") |> render_click()

    assert has_element?(view, "#manubrium-connect-qr svg")
    link = view |> element("#manubrium-connect-link") |> render()
    assert link =~ "manubrium://connect?"
    assert link =~ URI.encode_www_form(PairingsEngineWeb.Endpoint.url())
    refute has_element?(view, "#manubrium-connect-button")

    view |> element("#manubrium-connect-close") |> render_click()
    refute has_element?(view, "#manubrium-connect")
  end

  test "lists the account's phones, and Sign out cuts one off", %{conn: conn, scope: scope} do
    {device, token} = connected_phone(scope)
    {theirs, _token} = connected_phone(PairingsEngine.AccountsFixtures.user_scope_fixture())

    {:ok, view, _html} = live(conn, ~p"/users/settings")

    assert view |> element("#manubrium-device-#{device.id}") |> render() =~ "Pixel of Anna"
    assert view |> element("#manubrium-device-meta-#{device.id}") |> render() =~ device.token_hint
    refute has_element?(view, "#manubrium-device-#{theirs.id}")

    view |> element("#manubrium-device-revoke-#{device.id}") |> render_click()

    refute has_element?(view, "#manubrium-device-#{device.id}")
    assert has_element?(view, "#manubrium-device-none")
    assert Manubrium.authenticate(token) == :error
  end

  test "another account's phone cannot be signed out from here", %{conn: conn} do
    {theirs, token} = connected_phone(PairingsEngine.AccountsFixtures.user_scope_fixture())

    {:ok, view, _html} = live(conn, ~p"/users/settings")
    render_click(view, "revoke_manubrium_device", %{"id" => to_string(theirs.id)})

    assert {:ok, _device} = Manubrium.authenticate(token)
  end
end
