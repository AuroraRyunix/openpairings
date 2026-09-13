defmodule PairingsEngineWeb.UserLive.LoginTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest
  import PairingsEngine.AccountsFixtures

  describe "login page" do
    test "renders login page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Log in"
      assert html =~ "Create an account"
      assert html =~ "Email me a magic link"
    end

    # The landing page is the shop window: it leads with the engine we
    # wrote and does not advertise the third-party one. This is about what
    # a visitor is sold, not about dropping attribution - JaVaFo is still
    # the default engine, and is still credited in the README, the licence
    # notes and the cross-program-agreement docs, where the credit is owed.
    test "leads with our own engine and does not name JaVaFo", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Ainalrami"
      assert html =~ "built in Elixir"
      refute html =~ "JaVaFo"
    end

    test "shows the running app version", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "v#{PairingsEngineWeb.Layouts.app_version()}"
    end
  end

  describe "user login - magic link" do
    test "sends magic link email when user exists", %{conn: conn} do
      user = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", user: %{email: user.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "If your email is in our system"

      assert PairingsEngine.Repo.get_by!(PairingsEngine.Accounts.UserToken, user_id: user.id).context ==
               "login"
    end

    test "does not disclose if user is registered", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", user: %{email: "idonotexist@example.com"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "If your email is in our system"
    end

    test "logs a failed send but shows the SAME generic message - a failure must not be a second, quieter way to leak whether the address exists",
         %{conn: conn} do
      # Before this, the send's result was discarded outright: nothing
      # raised, nothing was logged, and the person who asked for a link had
      # no way to ever learn it was not coming. The flash text is
      # deliberately unchanged on failure (see `deliver_magic_link/2`) -
      # this only adds the log line `registration.ex`'s `do_register/2`
      # already had for the same underlying call.
      # Built BEFORE the adapter is swapped: `user_fixture/1` sends (and
      # reads back) a login email of its own to confirm the account.
      user = user_fixture()

      previous = Application.get_env(:pairings_engine, PairingsEngine.Mailer)

      Application.put_env(:pairings_engine, PairingsEngine.Mailer,
        adapter: PairingsEngine.FailingMailer
      )

      on_exit(fn -> Application.put_env(:pairings_engine, PairingsEngine.Mailer, previous) end)

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, _lv, html} =
            form(lv, "#login_form_magic", user: %{email: user.email})
            |> render_submit()
            |> follow_redirect(conn, ~p"/users/log-in")

          assert html =~ "If your email is in our system"
        end)

      assert log =~ "Failed to send login instructions to #{user.email}"
    end

    test "refuses an @zerotwo.cloud address instead of sending a link - even for a real, SSO-coupled account",
         %{conn: conn} do
      {:ok, user} =
        PairingsEngine.Accounts.find_or_create_from_keycloak(%{
          sub: Ecto.UUID.generate(),
          email: "someone@zerotwo.cloud"
        })

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", user: %{email: user.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "sign in with SSO"
      refute html =~ "If your email is in our system"
      refute PairingsEngine.Repo.get_by(PairingsEngine.Accounts.UserToken, user_id: user.id)
    end

    test "stops sending once one address has been asked for too many links", %{conn: conn} do
      user = user_fixture()
      %{max: max} = PairingsEngine.RateLimit.config(:login_email)

      # The client bucket is keyed on 127.0.0.1 for every test in this file,
      # so reset both ends around this one.
      reset = fn ->
        PairingsEngine.RateLimit.clear(:login_email, user.email)
        PairingsEngine.RateLimit.clear(:login_client, "127.0.0.1")
      end

      reset.()
      on_exit(reset)

      for _ <- 1..max do
        {:ok, lv, _html} = live(conn, ~p"/users/log-in")

        form(lv, "#login_form_magic", user: %{email: user.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")
      end

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", user: %{email: user.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "That&#39;s a lot of log-in links"

      # The point of the limit: no further mail, so no further tokens.
      login_tokens =
        PairingsEngine.Accounts.UserToken
        |> PairingsEngine.Repo.all()
        |> Enum.filter(&(&1.user_id == user.id and &1.context == "login"))

      assert length(login_tokens) == max
    end

    test "the limit is counted per address, not globally", %{conn: conn} do
      first = user_fixture()
      second = user_fixture()
      %{max: max} = PairingsEngine.RateLimit.config(:login_email)

      reset = fn ->
        PairingsEngine.RateLimit.clear(:login_email, first.email)
        PairingsEngine.RateLimit.clear(:login_email, second.email)
        PairingsEngine.RateLimit.clear(:login_client, "127.0.0.1")
      end

      reset.()
      on_exit(reset)

      for _ <- 1..max do
        {:ok, lv, _html} = live(conn, ~p"/users/log-in")

        form(lv, "#login_form_magic", user: %{email: first.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")
      end

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", user: %{email: second.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "If your email is in our system"
    end
  end

  describe "user login - password" do
    test "redirects if user logs in with valid credentials", %{conn: conn} do
      user = user_fixture() |> set_password()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form_password",
          user: %{email: user.email, password: valid_user_password(), remember_me: true}
        )

      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/"
    end

    test "redirects to login page with a flash error if credentials are invalid", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form_password", user: %{email: "test@email.com", password: "123456"})

      render_submit(form, %{user: %{remember_me: true}})

      conn = follow_trigger_action(form, conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "login navigation" do
    test "redirects to registration page when the Register button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Create an account")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/register")

      assert login_html =~ "Create an account"
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      user = user_fixture()
      %{user: user, conn: log_in_user(conn, user)}
    end

    test "shows login page with email filled in", %{conn: conn, user: user} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Re-authenticate to perform sensitive actions"
      refute html =~ "Register"
      assert html =~ "Email me a magic link"

      assert html =~
               ~s(<input type="email" name="user[email]" id="login_form_magic_email" value="#{user.email}")
    end
  end

  describe "mail-adapter notice" do
    # Neither branch shows under the suite's normal config (Swoosh.Adapters.Test,
    # config/test.exs), same as before this existed - so each test swaps in
    # the adapter it means to exercise.
    setup do
      previous = Application.get_env(:pairings_engine, PairingsEngine.Mailer)
      on_exit(fn -> Application.put_env(:pairings_engine, PairingsEngine.Mailer, previous) end)
      :ok
    end

    test "Swoosh.Adapters.Local (dev preview) links to the /dev/mailbox page", %{conn: conn} do
      Application.put_env(:pairings_engine, PairingsEngine.Mailer, adapter: Swoosh.Adapters.Local)

      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Local mail adapter"
      assert html =~ "/dev/mailbox"
      refute html =~ "printed in this computer's terminal"
    end

    test "PairingsEngine.ConsoleMailer (OPENPAIRINGS_LOCAL / Burrito) points at the terminal, not the dev mailbox route that build doesn't have",
         %{conn: conn} do
      # Regression test: `local_mail_adapter?/0` used to match only
      # `Swoosh.Adapters.Local`, so a local/desktop build - which uses
      # ConsoleMailer, never Local - showed NO notice at all here. Someone
      # clicking "Email me a magic link" on a second account, an invited
      # collaborator, or a password reset (the paths ConsoleMailer's own
      # moduledoc says still send mail in that build) saw nothing telling
      # them the link had gone to a terminal instead of an inbox.
      Application.put_env(:pairings_engine, PairingsEngine.Mailer,
        adapter: PairingsEngine.ConsoleMailer
      )

      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "printed in this computer&#39;s terminal"
      refute html =~ "/dev/mailbox"
    end

    test "neither notice shows for a real SMTP adapter", %{conn: conn} do
      Application.put_env(:pairings_engine, PairingsEngine.Mailer,
        adapter: Swoosh.Adapters.SMTP,
        relay: "smtp.gmail.com"
      )

      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      refute html =~ "Local mail adapter"
      refute html =~ "printed in this computer"
    end
  end
end
