defmodule PairingsEngineWeb.UserSessionController do
  use PairingsEngineWeb, :controller

  alias PairingsEngine.Accounts
  alias PairingsEngine.RateLimit
  alias PairingsEngineWeb.{ClientIp, UserAuth}

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, "User confirmed successfully.")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
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
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # email + password login
  defp create(conn, %{"user" => user_params}, info) do
    %{"email" => email, "password" => password} = user_params
    limits = rate_limits(conn, email)

    cond do
      # Counted before the password is ever checked, and on the same two
      # buckets the magic-link form uses: per address, so a list cannot be
      # walked against one account, and per client, so one client cannot
      # walk a list of addresses.
      #
      # This route had no ceiling at all except bcrypt's own cost, while
      # every other unauthenticated endpoint in the app - mobile enrolment,
      # magic link, registration, the FIDE lookup - was given one
      # deliberately. Passwords are the secondary path here, behind SSO and
      # magic links, but secondary is not unused.
      #
      # Refused BEFORE `get_user_by_email_and_password/2` runs, so a
      # throttled attempt costs no bcrypt round and cannot be timed to
      # distinguish a real account from a missing one.
      not Enum.all?(limits, fn {bucket, key} -> RateLimit.allow?(bucket, key) end) ->
        conn
        |> put_flash(:error, "Too many sign-in attempts. Try again in a few minutes.")
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
          "@#{PairingsEngine.Accounts.User.sso_domain()} accounts sign in with SSO."
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
        |> put_flash(:error, "Invalid email or password")
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # Deliberately the same shape as `PairingsEngineWeb.UserLive.Login`'s own
  # `rate_limits/2` - the same two buckets, keyed the same way. Two sign-in
  # doors onto the same accounts should not have two different ceilings.
  #
  # The client key comes from `ClientIp`, not `conn.remote_ip`: behind a
  # reverse proxy the peer address is the proxy's, identical for every
  # visitor, so thirty wrong passwords from anywhere would lock password
  # login for the whole site. `RateLimit`'s moduledoc says as much, and
  # every other caller already obeys it.
  defp rate_limits(conn, email) do
    recipient = email |> to_string() |> String.trim() |> String.downcase()

    case ClientIp.get(conn) do
      nil -> [{:login_email, recipient}]
      ip -> [{:login_email, recipient}, {:login_client, ip}]
    end
  end

  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)
    {:ok, {_user, expired_tokens}} = Accounts.update_user_password(user, user_params)

    # disconnect all existing LiveViews with old sessions
    UserAuth.disconnect_sessions(expired_tokens)

    conn
    |> put_session(:user_return_to, ~p"/users/settings")
    |> create(params, "Password updated successfully!")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
