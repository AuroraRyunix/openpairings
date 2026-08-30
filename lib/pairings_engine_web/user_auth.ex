defmodule PairingsEngineWeb.UserAuth do
  use PairingsEngineWeb, :verified_routes

  import Bitwise, only: [>>>: 2]
  import Plug.Conn
  import Phoenix.Controller

  alias PairingsEngine.{Accounts, Tournaments}
  alias PairingsEngine.Accounts.Scope

  # Make the remember me cookie valid for 14 days. This should match
  # the session validity setting in UserToken.
  @max_cookie_age_in_days 14
  @remember_me_cookie "_pairings_engine_web_user_remember_me"
  @remember_me_options [
    sign: true,
    max_age: @max_cookie_age_in_days * 24 * 60 * 60,
    same_site: "Lax"
  ]

  # How old the session token should be before a new one is issued. When a request is made
  # with a session token older than this value, then a new session token will be created
  # and the session and remember-me cookies (if set) will be updated with the new token.
  # Lowering this value will result in more tokens being created by active users. Increasing
  # it will result in less time before a session token expires for a user to get issued a new
  # token. This can be set to a value greater than `@max_cookie_age_in_days` to disable
  # the reissuing of tokens completely.
  @session_reissue_age_in_days 7

  @doc """
  Logs the user in.

  Redirects to the session's `:user_return_to` path
  or falls back to the `signed_in_path/1`.
  """
  def log_in_user(conn, user, params \\ %{}) do
    user_return_to = get_session(conn, :user_return_to)

    # Resolve any tournaments shared with this email before an invite had a
    # matching account - see `PairingsEngine.Tournaments.link_pending_collaborators/1`.
    Tournaments.link_pending_collaborators(user)

    conn
    |> create_or_extend_session(user, params)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  @doc """
  Logs the user out.

  It clears all session data for safety. See renew_session.
  """
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      PairingsEngineWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session(nil)
    |> delete_resp_cookie(@remember_me_cookie, @remember_me_options)
    |> redirect(to: ~p"/")
  end

  @doc """
  In local mode, signs the visitor in as the machine's owner.

  A local run is one person on their own computer. There is no one to tell
  apart from anyone else, so there is no login: the first request
  establishes a session for `PairingsEngine.Accounts.local_owner!/0` and
  every page just works.

  ## It is a real session, not a bypass

  This does not skip authentication - it performs it. A genuine session
  token is issued through `create_or_extend_session/3`, exactly as a
  magic-link login would, so everything downstream is unchanged: the scope,
  sudo mode, token expiry, LiveView's `on_mount`, logging out. Nothing else
  in the app learns that local mode exists, which is the point. A flag
  threaded through the auth checks themselves would be a second code path
  through the part of the app that must not have two.

  ## Two independent conditions, and both must hold

  1. `:local_mode` is set, which only `config/runtime.exs` does, only when
     `OPENPAIRINGS_LOCAL` is set.
  2. **The request came from loopback.** Checked here, per request, against
     `conn.remote_ip`.

  The second is not redundant. Local mode already pins the listener to
  127.0.0.1, so in a correctly configured run nothing else can reach this
  at all - but "correctly configured" is the assumption a bypass must not
  rest on. A reverse proxy in front of the app, a future change to how the
  endpoint is built, a deployment that sets the variable by mistake: each
  of those breaks the config-level guarantee, and this check survives all
  three. `X-Forwarded-For` is deliberately NOT consulted - that header is
  attacker-controlled, and the whole question here is which machine the
  connection physically came from.

  Placed before `fetch_current_scope_for_user/2` in the browser pipeline,
  and does nothing at all when a session already exists, so an explicit log
  out stays logged out until the next fresh session.
  """
  def local_owner_session(conn, _opts) do
    if local_mode?() and loopback?(conn.remote_ip) and get_session(conn, :user_token) == nil do
      create_or_extend_session(conn, Accounts.local_owner!(), %{})
    else
      conn
    end
  end

  defp local_mode?, do: PairingsEngine.Authz.local_mode?()

  # IPv4 127.0.0.0/8, IPv6 ::1, and IPv4-mapped IPv6 (::ffff:127.0.0.1),
  # which is what a dual-stack listener reports for a v4 loopback client.
  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0xFFFF, ab, _cd}) when ab >>> 8 == 127, do: true
  defp loopback?(_), do: false

  @doc """
  Authenticates the user by looking into the session and remember me token.

  Will reissue the session token if it is older than the configured age.
  """
  def fetch_current_scope_for_user(conn, _opts) do
    with {token, conn} <- ensure_user_token(conn),
         {user, token_inserted_at} <- Accounts.get_user_by_session_token(token) do
      conn
      |> assign(:current_scope, Scope.for_user(user))
      |> maybe_reissue_user_session_token(user, token_inserted_at)
    else
      nil -> assign(conn, :current_scope, Scope.for_user(nil))
    end
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, conn |> put_token_in_session(token) |> put_session(:user_remember_me, true)}
      else
        nil
      end
    end
  end

  # Reissue the session token if it is older than the configured reissue age.
  defp maybe_reissue_user_session_token(conn, user, token_inserted_at) do
    token_age = DateTime.diff(DateTime.utc_now(:second), token_inserted_at, :day)

    if token_age >= @session_reissue_age_in_days do
      create_or_extend_session(conn, user, %{})
    else
      conn
    end
  end

  # This function is the one responsible for creating session tokens
  # and storing them safely in the session and cookies. It may be called
  # either when logging in, during sudo mode, or to renew a session which
  # will soon expire.
  #
  # When the session is created, rather than extended, the renew_session
  # function will clear the session to avoid fixation attacks. See the
  # renew_session function to customize this behaviour.
  defp create_or_extend_session(conn, user, params) do
    token = Accounts.generate_user_session_token(user)
    remember_me = get_session(conn, :user_remember_me)

    conn
    |> renew_session(user)
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params, remember_me)
  end

  # Do not renew session if the user is already logged in
  # to prevent CSRF errors or data being lost in tabs that are still open
  defp renew_session(conn, user) when conn.assigns.current_scope.user.id == user.id do
    conn
  end

  # This function renews the session ID and erases the whole
  # session to avoid fixation attacks. If there is any data
  # in the session you may want to preserve after log in/log out,
  # you must explicitly fetch the session data before clearing
  # and then immediately set it after clearing, for example:
  #
  #     defp renew_session(conn, _user) do
  #       delete_csrf_token()
  #       preferred_locale = get_session(conn, :preferred_locale)
  #
  #       conn
  #       |> configure_session(renew: true)
  #       |> clear_session()
  #       |> put_session(:preferred_locale, preferred_locale)
  #     end
  #
  # The comment above is not a suggestion this app declined - it is a
  # description of a bug this app had. `PairingsEngineWeb.Plugs.Locale`
  # really does keep the chosen language in the session, so clearing the
  # session on log in threw it away, and the language picker is rendered in
  # the topbar of the log-in page itself. Choosing Nederlands and then
  # signing in - a first-class flow, not a corner - dropped the visitor back
  # into English.
  #
  # `locale_test.exs` missed it because its end-to-end tests log in during
  # `setup` and only switch language afterwards, so the pick-then-log-in
  # order was never exercised.
  defp renew_session(conn, _user) do
    delete_csrf_token()
    locale = get_session(conn, PairingsEngineWeb.Locale.session_key())

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> maybe_restore_locale(locale)
  end

  defp maybe_restore_locale(conn, nil), do: conn

  defp maybe_restore_locale(conn, locale),
    do: put_session(conn, PairingsEngineWeb.Locale.session_key(), locale)

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}, _),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, token, _params, true),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, _token, _params, _), do: conn

  defp write_remember_me_cookie(conn, token) do
    conn
    |> put_session(:user_remember_me, true)
    |> put_resp_cookie(@remember_me_cookie, token, @remember_me_options)
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, user_session_topic(token))
  end

  @doc """
  Disconnects existing sockets for the given tokens.
  """
  def disconnect_sessions(tokens) do
    Enum.each(tokens, fn %{token: token} ->
      PairingsEngineWeb.Endpoint.broadcast(user_session_topic(token), "disconnect", %{})
    end)
  end

  defp user_session_topic(token), do: "users_sessions:#{Base.url_encode64(token)}"

  @doc """
  Handles mounting and authenticating the current_scope in LiveViews.

  ## `on_mount` arguments

    * `:mount_current_scope` - Assigns current_scope
      to socket assigns based on user_token, or nil if
      there's no user_token or no matching user.

    * `:require_authenticated` - Authenticates the user from the session,
      and assigns the current_scope to socket assigns based
      on user_token.
      Redirects to login page if there's no logged user.

  ## Examples

  Use the `on_mount` lifecycle macro in LiveViews to mount or authenticate
  the `current_scope`:

      defmodule PairingsEngineWeb.PageLive do
        use PairingsEngineWeb, :live_view

        on_mount {PairingsEngineWeb.UserAuth, :mount_current_scope}
        ...
      end

  Or use the `live_session` of your router to invoke the on_mount callback:

      live_session :authenticated, on_mount: [{PairingsEngineWeb.UserAuth, :require_authenticated}] do
        live "/profile", ProfileLive, :index
      end
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope && socket.assigns.current_scope.user do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
  end

  # Sends a local install's visitor home instead of to a sign-in or sign-up
  # page that cannot do anything for them.
  #
  # A local install has exactly one owner and signs them in on sight
  # (`local_owner_session/2`), so `/users/log-in` has nobody to log in and
  # `/users/register` would create a second account that `local_owner!/0`
  # will never choose - unreachable except by a log out that has no button.
  # `/users/settings` offers change-email and change-password for an account
  # nobody signs into, and mails its confirmation to a terminal window.
  #
  # The links to all three are already hidden. This is the other half: a
  # bookmark, a typed URL or a stale link must not land somewhere that looks
  # functional and is not. Same argument the log-out link was removed under -
  # a control that visibly does nothing is worse than no control.
  #
  # Not a 404. The page exists on a hosted install and the visitor has done
  # nothing wrong; they are simply on a build where it means nothing.
  def on_mount(:reject_in_local_mode, _params, session, socket) do
    if PairingsEngine.Authz.local_mode?() do
      {:halt, Phoenix.LiveView.redirect(mount_current_scope(socket, session), to: ~p"/")}
    else
      {:cont, mount_current_scope(socket, session)}
    end
  end

  def on_mount(:require_sudo_mode, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if Accounts.sudo_mode?(socket.assigns.current_scope.user, -10) do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must re-authenticate to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
  end

  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      {user, _} =
        if user_token = session["user_token"] do
          Accounts.get_user_by_session_token(user_token)
        end || {nil, nil}

      Scope.for_user(user)
    end)
  end

  @doc "Returns the path to redirect to after log in."
  # the user was already logged in, redirect to settings
  def signed_in_path(%Plug.Conn{assigns: %{current_scope: %Scope{user: %Accounts.User{}}}}) do
    ~p"/users/settings"
  end

  def signed_in_path(_), do: ~p"/"

  @doc """
  Plug for routes that require the user to be authenticated.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/users/log-in")
      |> halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
