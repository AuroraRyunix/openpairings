defmodule PairingsEngineWeb.UserSessionController do
  use PairingsEngineWeb, :controller

  alias PairingsEngine.Accounts
  alias PairingsEngine.RateLimit
  alias PairingsEngineWeb.{ClientIp, UserAuth}

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, gettext("User confirmed successfully."))
  end

  def create(conn, params) do
    create(conn, params, gettext("Welcome back!"))
  end

  # magic link login
  defp create(conn, %{"user" => %{"token" => token} = user_params}, info) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      _ ->
        conn
        |> put_flash(:error, gettext("The link is invalid or it has expired."))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # email + password login
  defp create(conn, %{"user" => user_params}, info) do
    %{"email" => email, "password" => password} = user_params
    limits = rate_limits(conn, email)

    cond do
      # Counted before the password is ever checked, per {address, client}
      # so a list cannot be walked against one account from one place, and
      # per client so one client cannot walk a list of addresses.
      #
      # NOT per address alone. That bucket used to be shared with the
      # magic-link form and checked here first, which made it a lock anyone
      # could turn: five wrong passwords - or five log-in links requested -
      # for somebody else's address, and that somebody could not sign in for
      # a quarter of an hour, correct password and all. A guesser spread
      # over many addresses still meets bcrypt's cost and SSO-first habits;
      # an arbiter locked out on round day meets only us.
      #
      # Refused BEFORE `get_user_by_email_and_password/2` runs, so a
      # throttled attempt costs no bcrypt round and cannot be timed to
      # distinguish a real account from a missing one.
      not Enum.all?(limits, fn {bucket, key} -> RateLimit.allow?(bucket, key) end) ->
        conn
        |> put_flash(:error, gettext("Too many sign-in attempts. Try again in a few minutes."))
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/users/log-in")

      # The SSO-only domain is exactly that: an account there exists solely
      # because 02cloud SSO created it, so a local password must never be an
      # alternative way in - otherwise setting one in Settings would quietly
      # route around the directory (and around its MFA). Unlike the generic
      # branch below this says so plainly, which leaks nothing: the rule is a
      # property of the domain, identical for addresses that exist and ones
      # that don't, so it can't be used to probe for accounts.
      PairingsEngine.Accounts.User.sso_domain_email?(email) ->
        conn
        |> put_flash(
          :error,
          gettext("@%{domain} accounts sign in with SSO.",
            domain: PairingsEngine.Accounts.User.sso_domain()
          )
        )
        |> redirect(to: ~p"/users/log-in")

      user = Accounts.get_user_by_email_and_password(email, password) ->
        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      true ->
        # Recorded here and not on the success branch: a correct password is
        # not an attempt worth counting, and an arbiter signing in and out
        # during their own tournament must not run themselves out of
        # allowance. Counted for every failure whether or not the address
        # exists, since a limit that applied only to real accounts would
        # answer "does this address exist?".
        Enum.each(limits, fn {bucket, key} -> RateLimit.record(bucket, key) end)

        # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
        conn
        |> put_flash(:error, gettext("Invalid email or password"))
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # Password attempts only. The magic-link and registration forms keep
  # `:login_email`, keyed by recipient, because they SEND mail; nothing here
  # sends any, so nothing here needs a key the victim cannot get away from.
  #
  # The client key comes from `ClientIp`, not `conn.remote_ip`: behind a
  # reverse proxy the peer address is the proxy's, identical for every
  # visitor, so thirty wrong passwords from anywhere would lock password
  # login for the whole site. `RateLimit`'s moduledoc says as much, and
  # every other caller already obeys it.
  defp rate_limits(conn, email) do
    address = email |> to_string() |> String.trim() |> String.downcase()
    ip = ClientIp.get(conn)

    [{:login_password, "#{ip} #{address}"}, {:login_client, ip}]
  end

  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user

    with true <- Accounts.sudo_mode?(user),
         {:ok, {_user, expired_tokens}} <- Accounts.update_user_password(user, user_params) do
      # disconnect all existing LiveViews with old sessions
      UserAuth.disconnect_sessions(expired_tokens)

      conn
      |> put_session(:user_return_to, ~p"/users/settings")
      |> create(params, gettext("Password updated successfully!"))
    else
      false ->
        conn
        |> put_flash(:error, gettext("You must re-authenticate to access this page."))
        |> redirect(to: ~p"/users/log-in")

      _invalid ->
        conn
        |> put_flash(:error, gettext("The password could not be changed. Try again."))
        |> redirect(to: ~p"/users/settings")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, gettext("Logged out successfully."))
    |> UserAuth.log_out_user()
  end
end
