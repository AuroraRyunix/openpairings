defmodule PairingsEngineWeb.LocalOwnerSessionTest do
  @moduledoc """
  Local mode signs you in as the machine's owner, and does so under exactly
  two conditions.

  The negative tests carry more weight than the positive one. A sign-in that
  works is a feature; a sign-in that works somewhere it should not is the
  whole risk of having built this, so "off by default" and "loopback only"
  are asserted directly rather than inferred from the config.
  """
  use PairingsEngineWeb.ConnCase, async: false

  alias PairingsEngine.Accounts
  alias PairingsEngineWeb.UserAuth

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

  defp local_mode(on?), do: Application.put_env(:pairings_engine, :local_mode, on?)

  # `Scope.for_user(nil)` is nil rather than a scope holding no user, so
  # reach for the user through it rather than off it.
  defp signed_in(conn) do
    case conn.assigns.current_scope do
      nil -> nil
      scope -> scope.user
    end
  end

  # The pipeline's own order: session, then the local plug, then the scope.
  defp run(conn, remote_ip) do
    %{conn | remote_ip: remote_ip}
    |> Plug.Test.init_test_session(%{})
    |> UserAuth.local_owner_session([])
    |> UserAuth.fetch_current_scope_for_user([])
  end

  describe "on, from this machine" do
    test "signs in as the local owner without anyone logging in", %{conn: conn} do
      local_mode(true)

      conn = run(conn, {127, 0, 0, 1})

      assert signed_in(conn).email == Accounts.local_owner_email()
      # A real session, not an assign - which is what makes LiveView, sudo
      # mode and logging out work with no further special-casing.
      assert Plug.Conn.get_session(conn, :user_token)
    end

    test "returns the same account on a later run, so tournaments persist", %{conn: conn} do
      local_mode(true)

      first = signed_in(run(conn, {127, 0, 0, 1}))
      second = signed_in(run(build_conn(), {127, 0, 0, 1}))

      assert first.id == second.id
    end

    test "is pre-confirmed, since there is no mailbox to confirm through", %{conn: conn} do
      local_mode(true)

      user = signed_in(run(conn, {127, 0, 0, 1}))
      assert user.confirmed_at
    end

    test "accepts IPv6 loopback and IPv4-mapped IPv6 too", %{conn: conn} do
      local_mode(true)

      for ip <- [{0, 0, 0, 0, 0, 0, 0, 1}, {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}] do
        assert signed_in(run(build_conn(), ip)),
               "#{inspect(ip)} should count as loopback"
      end
    end
  end

  describe "off, or from anywhere else" do
    test "does nothing at all when local mode is off", %{conn: conn} do
      local_mode(false)

      conn = run(conn, {127, 0, 0, 1})

      refute signed_in(conn)
      refute Plug.Conn.get_session(conn, :user_token)
    end

    test "does nothing when the setting is absent entirely", %{conn: conn} do
      Application.delete_env(:pairings_engine, :local_mode)

      refute signed_in(run(conn, {127, 0, 0, 1}))
    end

    test "refuses a non-loopback request even with local mode on", %{conn: conn} do
      local_mode(true)

      # The config pins the listener to loopback, so in a correct run these
      # cannot arrive. This asserts the second, independent guard - the one
      # that still holds if a proxy is put in front or the endpoint config
      # is changed later.
      for ip <- [{10, 0, 0, 5}, {192, 168, 1, 20}, {8, 8, 8, 8}, {0x2001, 0, 0, 0, 0, 0, 0, 1}] do
        conn = run(build_conn(), ip)

        refute signed_in(conn), "#{inspect(ip)} must not be signed in"
        refute Plug.Conn.get_session(conn, :user_token)
      end
    end

    test "ignores X-Forwarded-For, which the client controls", %{conn: conn} do
      local_mode(true)

      conn =
        conn
        |> Plug.Conn.put_req_header("x-forwarded-for", "127.0.0.1")
        |> run({203, 0, 113, 9})

      refute signed_in(conn)
    end

    test "leaves an existing session alone rather than replacing it", %{conn: conn} do
      local_mode(true)
      other = PairingsEngine.AccountsFixtures.user_fixture()
      token = Accounts.generate_user_session_token(other)

      conn =
        %{conn | remote_ip: {127, 0, 0, 1}}
        |> Plug.Test.init_test_session(%{user_token: token})
        |> UserAuth.local_owner_session([])
        |> UserAuth.fetch_current_scope_for_user([])

      assert signed_in(conn).id == other.id
    end
  end

  describe "the owner's address" do
    test "is machine-local and cannot collide with a real one" do
      email = Accounts.local_owner_email()

      assert String.ends_with?(email, ".local")
      assert String.match?(email, ~r/^[^@,;\s]+@[^@,;\s]+$/)
    end
  end
end
