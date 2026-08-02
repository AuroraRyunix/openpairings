defmodule PairingsEngineWeb.KeycloakAuthController do
  @moduledoc """
  02cloud SSO (Keycloak) login: `new/2` starts the Authorization Code
  redirect, `callback/2` completes it. See `PairingsEngine.Keycloak` for the
  actual OIDC calls and `docs/AGENTS.md` for the end-to-end flow, including
  why the `@zerotwo.cloud` registration blocklist lives on the *other* side
  of this (`PairingsEngine.Accounts.User`) and not here.
  """
  use PairingsEngineWeb, :controller

  alias PairingsEngine.{Accounts, Keycloak}
  alias PairingsEngineWeb.UserAuth

  @doc """
  Redirects to Keycloak's authorize endpoint with a fresh CSRF `state` stashed
  in the session for `callback/2` to verify.
  """
  def new(conn, _params) do
    if Keycloak.configured?() do
      state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      conn
      |> put_session(:keycloak_state, state)
      |> redirect(external: Keycloak.authorize_url(state))
    else
      conn
      |> put_flash(:error, "Single sign-on isn't configured on this instance.")
      |> redirect(to: ~p"/users/log-in")
    end
  end

  @doc """
  Handles Keycloak's redirect back. Verifies `state`, exchanges the code,
  fetches the identity, and finds-or-creates the local account before logging
  in through the normal session path.
  """
  def callback(conn, %{"error" => _} = params) do
    # The user cancelled at Keycloak, or Keycloak itself rejected the request
    # (e.g. access_denied). Not an application error — just bounce back.
    detail = params["error_description"] || params["error"]

    conn
    |> put_flash(:error, "Single sign-on was cancelled (#{detail}).")
    |> redirect(to: ~p"/users/log-in")
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    expected_state = get_session(conn, :keycloak_state)
    conn = delete_session(conn, :keycloak_state)

    if is_binary(expected_state) and Plug.Crypto.secure_compare(state, expected_state) do
      complete_login(conn, code)
    else
      conn
      |> put_flash(:error, "Single sign-on session expired — please try again.")
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def callback(conn, _params) do
    conn
    |> put_flash(:error, "Single sign-on response was incomplete — please try again.")
    |> redirect(to: ~p"/users/log-in")
  end

  defp complete_login(conn, code) do
    with {:ok, %{"access_token" => access_token}} <- Keycloak.exchange_code(code),
         {:ok, claims} <- Keycloak.fetch_userinfo(access_token),
         {:ok, sub, email} <- identity_from(claims),
         {:ok, user} <- Accounts.find_or_create_from_keycloak(%{sub: sub, email: email}) do
      conn
      |> put_flash(:info, "Welcome!")
      |> UserAuth.log_in_user(user)
    else
      # A userinfo response with neither a usable email nor a username to
      # derive one from, or an {:error, reason} from Keycloak.*/Accounts.*.
      # Must degrade to a flash, never a 500.
      other ->
        require Logger
        Logger.warning("02cloud SSO login failed: #{inspect(other)}")

        conn
        |> put_flash(:error, "Single sign-on failed — please try again or contact support.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # Keycloak omits the `email` claim entirely for a directory account with no
  # `mail` attribute, while still sending `email_verified` — so the presence of
  # the latter proves nothing, and a blank string must be treated as absent.
  #
  # When there's no email we synthesize `<preferred_username>@<sso domain>`.
  # That is safe here specifically *because* the SSO domain is otherwise
  # unreachable: it can't be self-registered, can't be changed to, and can't
  # be used for magic-link or password login (see `User.sso_domain_email?/1`
  # and its call sites). So a synthesized address can never collide with an
  # account someone made by another route, and the fact that it isn't a real
  # mailbox costs nothing — SSO is the only way in for that domain anyway.
  defp identity_from(%{"sub" => sub, "email" => email})
       when is_binary(sub) and is_binary(email) and email != "" do
    {:ok, sub, email}
  end

  defp identity_from(%{"sub" => sub, "preferred_username" => username})
       when is_binary(sub) and is_binary(username) and username != "" do
    {:ok, sub, "#{String.downcase(username)}@#{PairingsEngine.Accounts.User.sso_domain()}"}
  end

  defp identity_from(_), do: {:error, :bad_claims}
end
