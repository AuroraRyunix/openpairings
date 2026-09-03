defmodule PairingsEngineWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use PairingsEngineWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint PairingsEngineWeb.Endpoint

      use PairingsEngineWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import PairingsEngineWeb.ConnCase
    end
  end

  setup tags do
    PairingsEngine.DataCase.setup_sandbox(tags)

    # The rate-limit counters live in a named ETS table that outlives any one
    # test, so a test that spends a bucket's allowance leaves it spent for
    # everything after it - and a later test asserting "this log-in is still
    # allowed" fails on whichever seed puts it last. Clearing here rather
    # than in each rate-limit test means a new one cannot forget.
    PairingsEngine.RateLimit.clear_all()

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Setup helper that registers and logs in users.

      setup :register_and_log_in_user

  It stores an updated connection and a registered user in the
  test context.
  """
  def register_and_log_in_user(%{conn: conn} = context) do
    user = PairingsEngine.AccountsFixtures.user_fixture()
    scope = PairingsEngine.Accounts.Scope.for_user(user)

    opts =
      context
      |> Map.take([:token_authenticated_at])
      |> Enum.into([])

    %{conn: log_in_user(conn, user, opts), user: user, scope: scope}
  end

  @doc """
  Setup helper that switches every optional federation feature on for the
  user `register_and_log_in_user` just created.

      setup [:register_and_log_in_user, :enable_federation_features]

  Add it to a test (or a `describe` block) that exercises something behind
  `PairingsEngine.Features` - the Belgian rating-list panel, the KBSB
  lookups, the club update, SWAR import/export. The default for a new
  account is nothing enabled, which is the point of the whole design, so
  those controls really are absent without this and a test that forgets it
  fails honestly rather than passing by accident.

  It writes to the database and hands the reloaded user back in the context.
  The page under test builds its own scope from the session token, so it
  sees the update; `scope` in the context is left as it was, since it is used
  to CREATE fixtures rather than to render.
  """
  def enable_federation_features(%{user: user} = context) do
    {:ok, user} = PairingsEngine.Features.set_enabled(user, PairingsEngine.Features.keys())
    Map.put(context, :user, user)
  end

  @doc """
  Logs the given `user` into the `conn`.

  It returns an updated `conn`.
  """
  def log_in_user(conn, user, opts \\ []) do
    token = PairingsEngine.Accounts.generate_user_session_token(user)

    maybe_set_token_authenticated_at(token, opts[:token_authenticated_at])

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  defp maybe_set_token_authenticated_at(_token, nil), do: nil

  defp maybe_set_token_authenticated_at(token, authenticated_at) do
    PairingsEngine.AccountsFixtures.override_token_authenticated_at(token, authenticated_at)
  end
end
