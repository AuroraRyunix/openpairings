defmodule PairingsEngineWeb.UserLive.SettingsTest do
  use PairingsEngineWeb.ConnCase, async: false

  alias PairingsEngine.{Accounts, Tournaments}
  alias PairingsEngine.Accounts.UserToken
  alias PairingsEngine.Repo
  import Phoenix.LiveViewTest
  import PairingsEngine.AccountsFixtures

  @stale DateTime.add(DateTime.utc_now(:second), -30, :minute)

  setup do
    previous = Application.get_env(:pairings_engine, :local_mode)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:pairings_engine, :local_mode)
        value -> Application.put_env(:pairings_engine, :local_mode, value)
      end
    end)

    :ok
  end

  defp stale_conn(conn, user),
    do: log_in_user(conn, user, token_authenticated_at: @stale)

  describe "Settings page" do
    test "renders every section for a hosted account", %{conn: conn} do
      {:ok, lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      for id <- ~w(profile security preferences new-tournaments features your-data delete-account) do
        assert has_element?(lv, "section##{id}"), "missing section ##{id}"
      end

      assert has_element?(lv, "#email_form")
      assert has_element?(lv, "#password_form")
      assert html =~ "Change Email"
      assert html =~ "Save Password"
    end

    test "redirects if user is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/users/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end

    # The page used to be `require_sudo_mode` as a whole. Now it opens, and
    # only the sections that can lock somebody out or carry data away ask
    # for a recent sign-in - in place of their controls.
    test "opens without a recent sign-in, with the dangerous controls locked", %{conn: conn} do
      {:ok, lv, _html} = conn |> stale_conn(user_fixture()) |> live(~p"/users/settings")

      assert has_element?(lv, "#security-locked a[href='/users/log-in']")
      assert has_element?(lv, "#data-locked")
      assert has_element?(lv, "#delete-locked")
      refute has_element?(lv, "#email_form")
      refute has_element?(lv, "#password_form")
      refute has_element?(lv, "#download-data")
      refute has_element?(lv, "#delete-account-form")

      # ...while the harmless ones are just there.
      assert has_element?(lv, "#profile-form")
      assert has_element?(lv, "#preferences-form")
      assert has_element?(lv, "#defaults-form")
      assert has_element?(lv, "#features-form")
    end

    test "an address on the 02cloud domain has no address or password form", %{conn: conn} do
      {:ok, user} =
        Accounts.find_or_create_from_keycloak(%{
          sub: "sub-#{System.unique_integer([:positive])}",
          email: "someone#{System.unique_integer([:positive])}@zerotwo.cloud"
        })

      {:ok, lv, html} = conn |> log_in_user(user) |> live(~p"/users/settings")

      assert has_element?(lv, "#acct-sso-managed")
      assert has_element?(lv, "#acct-sso-badge")
      refute has_element?(lv, "#email_form")
      refute has_element?(lv, "#password_form")
      assert html =~ "managed by 02cloud"
      # Sessions and the rest still work for them.
      assert has_element?(lv, "#session-list")
      assert has_element?(lv, "#delete-account")
    end

    test "on a local install there is nothing to sign in to and nothing to delete", %{
      conn: conn
    } do
      Application.put_env(:pairings_engine, :local_mode, true)
      {:ok, lv, _html} = conn |> stale_conn(user_fixture()) |> live(~p"/users/settings")

      refute has_element?(lv, "section#security")
      refute has_element?(lv, "section#delete-account")
      # No sign-in to repeat on a local install, so the download is not locked.
      assert has_element?(lv, "#download-data")
      assert has_element?(lv, "#preferences-form")
    end
  end

  describe "profile" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "saves a display name and says so beside the button", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv
      |> form("#profile-form", %{"user" => %{"display_name" => "  Jan   Peeters "}})
      |> render_submit()

      assert Accounts.get_user!(user.id).display_name == "Jan Peeters"
      assert has_element?(lv, "#profile-saved")
      assert has_element?(lv, ".acct-who-name", "Jan Peeters")
    end

    test "an empty name clears it", %{conn: conn, user: user} do
      {:ok, _} = Accounts.update_user_profile(user, %{"display_name" => "Jan"})
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv |> form("#profile-form", %{"user" => %{"display_name" => "   "}}) |> render_submit()

      assert Accounts.get_user!(user.id).display_name == nil
    end

    test "refuses control characters", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      html =
        lv
        |> form("#profile-form", %{"user" => %{"display_name" => "Jan\u0007"}})
        |> render_submit()

      assert html =~ "must not contain control characters"
      assert Accounts.get_user!(user.id).display_name == nil
    end
  end

  describe "preferences" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "choosing a theme stores it and applies it in this browser", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv
      |> form("#preferences-form", %{"prefs" => %{"theme" => "dark", "accent" => ""}})
      |> render_change()

      assert Accounts.get_user!(user.id).theme == "dark"
      assert_push_event(lv, "pe:apply-appearance", %{theme: "dark"})
      assert has_element?(lv, "#preferences-saved")
    end

    test "choosing an accent stores it", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv
      |> form("#preferences-form", %{"prefs" => %{"theme" => "", "accent" => "violet"}})
      |> render_change()

      assert Accounts.get_user!(user.id).accent == "violet"
      assert_push_event(lv, "pe:apply-appearance", %{accent: "violet"})
    end

    test "\"This device decides\" clears the stored value", %{conn: conn, user: user} do
      {:ok, _} = Accounts.update_user_preferences(user, %{"theme" => "paper"})
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv
      |> form("#preferences-form", %{"prefs" => %{"theme" => "", "accent" => ""}})
      |> render_change()

      assert Accounts.get_user!(user.id).theme == nil
    end

    test "a theme that does not exist is refused", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      render_change(lv, "save_preferences", %{"prefs" => %{"theme" => "nord"}})

      assert Accounts.get_user!(user.id).theme == nil
    end

    test "choosing a language stores it and reloads the page in it", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv
      |> form("#preferences-form", %{
        "prefs" => %{"locale" => "nl", "theme" => "", "accent" => ""}
      })
      |> render_change()

      assert Accounts.get_user!(user.id).locale == "nl"
      assert_redirect(lv, "/users/settings#preferences")
    end
  end

  describe "defaults for new tournaments" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "saves them", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv
      |> form("#defaults-form", %{
        "defaults" => %{
          "pairing_system" => "round_robin",
          "rounds_count" => "7",
          "city" => " Gent ",
          "federation" => "bel",
          "publish_mode" => "manual"
        }
      })
      |> render_submit()

      defaults = Accounts.get_user!(user.id).tournament_defaults
      assert defaults.pairing_system == "round_robin"
      assert defaults.rounds_count == 7
      assert defaults.city == "Gent"
      assert defaults.federation == "BEL"
      assert has_element?(lv, "#defaults-saved")
    end

    test "shows what is wrong and stores nothing", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      html =
        lv
        |> form("#defaults-form", %{"defaults" => %{"federation" => "BE1"}})
        |> render_submit()

      assert html =~ "three-letter FIDE federation code"
      assert Accounts.get_user!(user.id).tournament_defaults == nil
    end

    test "the delay field appears only with the pairings step", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")
      refute has_element?(lv, "#defaults_publish_delay_minutes")

      for mode <- ~w(pairings results standings) do
        lv
        |> form("#defaults-form", %{"defaults" => %{"publish_mode" => mode}})
        |> render_change()

        assert has_element?(lv, "#defaults_publish_delay_minutes")
      end

      lv
      |> form("#defaults-form", %{"defaults" => %{"publish_mode" => "manual"}})
      |> render_change()

      refute has_element?(lv, "#defaults_publish_delay_minutes")
    end

    test "Clear all empties them", %{conn: conn, user: user} do
      {:ok, _} = Accounts.update_tournament_defaults(user, %{"city" => "Gent"})
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv |> element("#clear-defaults") |> render_click()

      refute PairingsEngine.Accounts.TournamentDefaults.any?(
               Accounts.get_user!(user.id).tournament_defaults
             )
    end
  end

  describe "update email form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the user email", %{conn: conn, user: user} do
      new_email = unique_user_email()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => new_email}
        })
        |> render_submit()

      assert result =~ "A link to confirm your email"
      assert has_element?(lv, "#email-saved")
      assert Accounts.get_user_by_email(user.email)
    end

    test "shows an error and logs it, rather than claiming success, when the confirmation email fails to send",
         %{conn: conn} do
      # Regression test: this handler used to call
      # `Accounts.deliver_user_update_email_instructions/3` and discard the
      # result, so "A link ... has been sent" showed even when the send
      # failed. Unlike the log-in form's resend, there is no enumeration
      # concern here - the user is already logged into their own account -
      # so this can and should say so.
      previous = Application.get_env(:pairings_engine, PairingsEngine.Mailer)

      Application.put_env(:pairings_engine, PairingsEngine.Mailer,
        adapter: PairingsEngine.FailingMailer
      )

      on_exit(fn -> Application.put_env(:pairings_engine, PairingsEngine.Mailer, previous) end)

      new_email = unique_user_email()
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result =
            lv
            |> form("#email_form", %{"user" => %{"email" => new_email}})
            |> render_submit()

          assert result =~ "We could not send the confirmation email"
          refute result =~ "A link to confirm your email"
        end)

      assert log =~ "Failed to send update-email instructions to #{new_email}"
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#email_form")
        |> render_change(%{
          "action" => "update_email",
          "user" => %{"email" => "with spaces"}
        })

      assert result =~ "Change Email"
      assert result =~ "must have the @ sign and no spaces"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => user.email}
        })
        |> render_submit()

      assert result =~ "Change Email"
      assert result =~ "did not change"
    end

    test "is rate limited per account", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      for _ <- 1..5 do
        lv
        |> form("#email_form", %{"user" => %{"email" => unique_user_email()}})
        |> render_submit()
      end

      html =
        lv
        |> form("#email_form", %{"user" => %{"email" => unique_user_email()}})
        |> render_submit()

      assert html =~ "Several confirmation links went out just now"
      assert Accounts.get_user!(user.id).email == user.email
    end
  end

  describe "without a recent sign-in" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: stale_conn(conn, user), user: user}
    end

    # The forms are not rendered, but an event is whatever the socket sends.
    test "a crafted email change is refused", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      html = render_hook(lv, "update_email", %{"user" => %{"email" => unique_user_email()}})

      assert html =~ "Confirm it&#39;s you first"
      refute html =~ "A link to confirm your email"
      assert Accounts.get_user!(user.id).email == user.email
    end

    test "a crafted password change is refused", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      html =
        render_hook(lv, "update_password", %{
          "user" => %{
            "password" => "a brand new password",
            "password_confirmation" => "a brand new password"
          }
        })

      assert html =~ "Confirm it&#39;s you first"
    end
  end

  describe "update password form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the user password", %{conn: conn, user: user} do
      new_password = valid_user_password()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      form =
        form(lv, "#password_form", %{
          "user" => %{
            "email" => user.email,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      render_submit(form)

      new_password_conn = follow_trigger_action(form, conn)

      assert redirected_to(new_password_conn) == ~p"/users/settings"

      assert get_session(new_password_conn, :user_token) != get_session(conn, :user_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Password updated successfully"

      assert Accounts.get_user_by_email_and_password(user.email, new_password)
    end

    test "says \"Set a password\" to an account that has none", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/settings")
      assert html =~ "Set a password"
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#password_form")
        |> render_change(%{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })

      assert result =~ "Save Password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#password_form", %{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })
        |> render_submit()

      assert result =~ "Save Password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end
  end

  describe "sessions" do
    @iphone "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    defp session_row(token) do
      Repo.get_by!(UserToken, token: token, context: "session")
    end

    test "lists every signed-in browser, this one marked", %{conn: conn, user: user} do
      other = Accounts.generate_user_session_token(user, @iphone)
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      this = session_row(get_session(conn, :user_token))
      assert has_element?(lv, "#session-#{this.id}", "This browser")
      assert has_element?(lv, "#session-#{session_row(other).id}", "Safari on iPhone")
      refute has_element?(lv, "#revoke-session-#{this.id}")
    end

    test "signs one other browser out", %{conn: conn, user: user} do
      other = Accounts.generate_user_session_token(user, @iphone)
      row = session_row(other)
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv |> element("#revoke-session-#{row.id}") |> render_click()

      refute Accounts.get_user_by_session_token(other)
      assert Accounts.get_user_by_session_token(get_session(conn, :user_token))
      refute has_element?(lv, "#session-#{row.id}")
    end

    test "signs every other browser out, and keeps this one", %{conn: conn, user: user} do
      a = Accounts.generate_user_session_token(user, @iphone)

      b =
        Accounts.generate_user_session_token(user, "Mozilla/5.0 (Windows NT 10.0) Firefox/130.0")

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv |> element("#revoke-other-sessions") |> render_click()

      refute Accounts.get_user_by_session_token(a)
      refute Accounts.get_user_by_session_token(b)
      assert Accounts.get_user_by_session_token(get_session(conn, :user_token))
      refute has_element?(lv, "#revoke-other-sessions")
    end

    test "cannot reach another account's session by id", %{conn: conn} do
      stranger = user_fixture()
      theirs = Accounts.generate_user_session_token(stranger)
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      render_hook(lv, "revoke_session", %{"id" => to_string(session_row(theirs).id)})

      assert Accounts.get_user_by_session_token(theirs)
    end

    test "cannot end this browser's own session from the list", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")
      this = session_row(get_session(conn, :user_token))

      html = render_hook(lv, "revoke_session", %{"id" => to_string(this.id)})

      assert html =~ "That is this browser"
      assert Accounts.get_user_by_session_token(get_session(conn, :user_token))
    end

    test "without a recent sign-in the buttons are gone and the events refused", %{user: user} do
      conn = stale_conn(build_conn(), user)
      other = Accounts.generate_user_session_token(user, @iphone)
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      refute has_element?(lv, "#revoke-other-sessions")
      refute has_element?(lv, "#revoke-session-#{session_row(other).id}")

      render_hook(lv, "revoke_other_sessions", %{})
      render_hook(lv, "revoke_session", %{"id" => to_string(session_row(other).id)})

      assert Accounts.get_user_by_session_token(other)
    end
  end

  describe "deleting the account" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "is blocked while the account owns a tournament", %{conn: conn, user: user} do
      {:ok, _t} =
        Tournaments.create_tournament(Accounts.Scope.for_user(user), %{
          "name" => "Mine",
          "rounds_count" => 5
        })

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      assert has_element?(lv, "#delete-blocked", "owns 1 tournament")
      refute has_element?(lv, "#delete-account-form")
    end

    test "keeps the button disabled until the address is typed", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")
      assert has_element?(lv, "#delete-account-button[disabled]")

      lv
      |> form("#delete-account-form", %{
        "account" => %{"confirm" => "  #{String.upcase(user.email)} "}
      })
      |> render_change()

      refute has_element?(lv, "#delete-account-button[disabled]")
    end

    test "a wrong address is refused", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      html = render_hook(lv, "delete_account", %{"account" => %{"confirm" => "nope"}})

      assert html =~ "Type your email address exactly"
      assert Accounts.get_user!(user.id)
    end

    test "deletes the account and signs out", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      form = form(lv, "#delete-account-form", %{"account" => %{"confirm" => user.email}})
      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Your account has been deleted"
      refute Accounts.get_user_by_email(user.email)
    end
  end

  describe "confirm email" do
    setup %{conn: conn} do
      user = user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{conn: log_in_user(conn, user), token: token, email: email, user: user}
    end

    test "updates the user email once", %{conn: conn, user: user, token: token, email: email} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")

      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"info" => message} = flash
      assert message == "Email changed successfully."
      refute Accounts.get_user_by_email(user.email)
      assert Accounts.get_user_by_email(email)

      # use confirm token again
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
    end

    test "does not update email with invalid token", %{conn: conn, user: user} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/oops")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
      assert Accounts.get_user_by_email(user.email)
    end

    test "redirects if user is not logged in", %{token: token} do
      conn = build_conn()
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => message} = flash
      assert message == "You must log in to access this page."
    end
  end
end
