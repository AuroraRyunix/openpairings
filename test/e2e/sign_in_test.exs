defmodule PairingsEngineWeb.E2E.SignInTest do
  use PairingsEngineWeb.E2ECase

  test "signs in with a password and lands on the tournament list", %{conn: conn} do
    {conn, _user} = sign_in(conn)

    conn
    |> assert_path("/")
    |> assert_has("body .phx-connected")
  end

  test "a wrong password stays on the login page and says so", %{conn: conn} do
    user = user_fixture() |> set_password()

    conn
    |> visit("/users/log-in")
    |> assert_has("body .phx-connected")
    |> click("summary", "Use a password instead")
    |> within("#login_form_password", fn conn ->
      conn
      |> fill_in("Email", with: user.email)
      |> fill_in("Password", with: "not the password")
      |> click_button("Log in only this time")
    end)
    |> assert_path("/users/log-in")
    |> assert_has("#flash-error")
  end
end
