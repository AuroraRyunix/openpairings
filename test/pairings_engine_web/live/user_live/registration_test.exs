defmodule PairingsEngineWeb.UserLive.RegistrationTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest
  import PairingsEngine.AccountsFixtures

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Create an account"
      assert html =~ "Log in"
    end

    # The landing page is the shop window: it leads with the engine we
    # wrote and does not advertise the third-party one. This is about what
    # a visitor is sold, not about dropping attribution - JaVaFo is still
    # the default engine, and is still credited in the README, the licence
    # notes and the cross-program-agreement docs, where the credit is owed.
    test "leads with our own engine and does not name JaVaFo", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Ainalrami"
      assert html =~ "built in Elixir"
      refute html =~ "JaVaFo"
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/register")
        |> follow_redirect(conn, ~p"/")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(user: %{"email" => "with spaces"})

      assert result =~ "Create an account"
      assert result =~ "must have the @ sign and no spaces"
    end
  end

  describe "register user" do
    test "creates account but does not log in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()
      form = form(lv, "#registration_form", user: valid_user_attributes(email: email))

      {:ok, _lv, html} =
        render_submit(form)
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~
               ~r/An email was sent to .*, please access it to confirm your account/
    end

    test "logs the failure and tells the user, rather than claiming the email was sent, when it fails to send",
         %{conn: conn} do
      # This branch of `do_register/2` already existed and already did the
      # right thing - unlike the three sibling call sites this audit found
      # discarding the same kind of result - but nothing exercised it before.
      previous = Application.get_env(:pairings_engine, PairingsEngine.Mailer)

      Application.put_env(:pairings_engine, PairingsEngine.Mailer,
        adapter: PairingsEngine.FailingMailer
      )

      on_exit(fn -> Application.put_env(:pairings_engine, PairingsEngine.Mailer, previous) end)

      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()
      form = form(lv, "#registration_form", user: valid_user_attributes(email: email))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, _lv, html} =
            render_submit(form)
            |> follow_redirect(conn, ~p"/users/log-in")

          assert html =~ "we could not send the email"
          refute html =~ "please access it to confirm your account"
        end)

      assert log =~ "Failed to send login instructions to #{email}"
      # The account itself was still created - only the mail failed.
      assert PairingsEngine.Accounts.get_user_by_email(email)
    end

    test "renders errors for duplicated email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      user = user_fixture(%{email: "test@email.com"})

      result =
        lv
        |> form("#registration_form",
          user: %{"email" => user.email}
        )
        |> render_submit()

      assert result =~ "has already been taken"
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Log in button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Log in")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert login_html =~ "Log in"
    end
  end
end
