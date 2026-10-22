defmodule PairingsEngineWeb.E2ECase do
  @moduledoc """
  The browser tests (test/e2e): PhoenixTest's pipeline API, driving a real
  Chromium through Playwright against a real listener, with the database in
  the SQL Sandbox exactly as in any other test.

  Tagged `:e2e` and excluded from a plain `mix test`; `mix test.e2e` runs
  them and nothing else. See docs/e2e.md for the why and the how.

  Never `async: true`: the sandbox is shared with every process the browser
  wakes - the LiveViews, the controllers - and shared mode only works when
  nothing else is running beside it. The suite runs one case at a time
  anyway (test_helper.exs says why).
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      use PhoenixTest.Playwright.Case, async: false

      use PairingsEngineWeb, :verified_routes

      import PairingsEngine.AccountsFixtures
      import PairingsEngineWeb.E2ECase

      @moduletag :e2e
    end
  end

  setup_all do
    if Application.get_env(:phoenix_test, :base_url) do
      :ok
    else
      raise """
      The browser tests need a listening endpoint and Playwright, which only
      `mix test.e2e` starts (it sets E2E=1 for test/test_helper.exs). See docs/e2e.md.
      """
    end
  end

  @doc """
  A confirmed account with a password, signed in through the login page the
  way a person would: the password form behind "Use a password instead".
  Returns the session and the user.
  """
  def sign_in(conn, user \\ nil) do
    user =
      user ||
        PairingsEngine.AccountsFixtures.user_fixture()
        |> PairingsEngine.AccountsFixtures.set_password()

    conn =
      conn
      |> PhoenixTest.visit("/users/log-in")
      |> PhoenixTest.assert_has("body .phx-connected")
      |> PhoenixTest.Playwright.click("summary", "Use a password instead")
      |> PhoenixTest.within("#login_form_password", fn conn ->
        conn
        |> PhoenixTest.fill_in("Email", with: user.email)
        |> PhoenixTest.fill_in("Password",
          with: PairingsEngine.AccountsFixtures.valid_user_password()
        )
        |> PhoenixTest.click_button("Log in only this time")
      end)
      # The click returns before the form's full-page POST has; the session
      # cookie exists only once the redirect has landed.
      |> PhoenixTest.refute_has("#login_form_password")
      |> PhoenixTest.assert_has("body .phx-connected")

    {conn, user}
  end
end
