defmodule PairingsEngineWeb.AccountControllerTest do
  use PairingsEngineWeb.ConnCase, async: false

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Accounts, RateLimit, Tournaments}
  alias PairingsEngine.Accounts.Scope

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

  describe "POST /users/preferences/appearance" do
    test "updates a theme the account already stores", %{conn: conn} do
      user = user_fixture()
      {:ok, user} = Accounts.update_user_preferences(user, %{"theme" => "light"})

      conn =
        conn |> log_in_user(user) |> post(~p"/users/preferences/appearance", %{"theme" => "dark"})

      assert response(conn, 204)
      assert Accounts.get_user!(user.id).theme == "dark"
    end

    # "Each device decides" is chosen on the account page; a top-bar pick on
    # one device must not quietly turn it into "every device follows this".
    test "does not start storing one the account leaves to each device", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/users/preferences/appearance", %{"accent" => "rose"})

      assert response(conn, 204)
      assert Accounts.get_user!(user.id).accent == nil
    end

    test "ignores a value the app does not know", %{conn: conn} do
      user = user_fixture()
      {:ok, user} = Accounts.update_user_preferences(user, %{"accent" => "green"})

      conn |> log_in_user(user) |> post(~p"/users/preferences/appearance", %{"accent" => "evil"})

      assert Accounts.get_user!(user.id).accent == "green"
    end

    test "answers a signed-out call quietly, with no flash left behind", %{conn: conn} do
      conn = post(conn, ~p"/users/preferences/appearance", %{"theme" => "dark"})

      assert response(conn, 204)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == nil
    end
  end

  describe "GET /users/settings/export" do
    test "hands over a zip of the account and every tournament", %{conn: conn} do
      user = user_fixture()
      {:ok, user} = Accounts.update_user_profile(user, %{"display_name" => "Jan"})
      scope = Scope.for_user(user)

      {:ok, t} =
        Tournaments.create_tournament(scope, %{"name" => "Zomer Open", "rounds_count" => 5})

      {:ok, binned} =
        Tournaments.create_tournament(scope, %{"name" => "Old", "rounds_count" => 3})

      {:ok, _} = Tournaments.soft_delete_tournament(binned)

      conn = conn |> log_in_user(user) |> get(~p"/users/settings/export")

      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/zip"
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ ~s(filename="openpairings-account-)

      {:ok, files} = :zip.unzip(response(conn, 200), [:memory])
      files = Map.new(files, fn {name, data} -> {to_string(name), data} end)

      account = Jason.decode!(files["account.json"])
      assert account["account"]["email"] == user.email
      assert account["account"]["display_name"] == "Jan"

      assert Map.has_key?(files, "tournaments/#{t.id}-zomer-open.json")
      assert Map.has_key?(files, "recycle-bin/#{binned.id}-old.json")

      # Each one is the ordinary backup, importable as it stands.
      envelope = Jason.decode!(files["tournaments/#{t.id}-zomer-open.json"])
      assert envelope["format"] == PairingsEngine.TournamentExport.format()
      assert [%{"tournament" => %{"name" => "Zomer Open"}}] = envelope["tournaments"]
    end

    test "asks for a recent sign-in first", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> log_in_user(user, token_authenticated_at: @stale)
        |> get(~p"/users/settings/export")

      assert redirected_to(conn) == "/users/settings#your-data"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Confirm it's you"
    end

    test "does not on a local install, where there is no sign-in to repeat", %{conn: conn} do
      Application.put_env(:pairings_engine, :local_mode, true)
      user = user_fixture()

      conn =
        conn
        |> log_in_user(user, token_authenticated_at: @stale)
        |> get(~p"/users/settings/export")

      assert response(conn, 200)
    end

    test "is rate limited per account", %{conn: conn} do
      user = user_fixture()
      key = Integer.to_string(user.id)
      for _ <- 1..5, do: RateLimit.record(:account_export, key)

      conn = conn |> log_in_user(user) |> get(~p"/users/settings/export")

      assert redirected_to(conn) == "/users/settings#your-data"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "several times"
    end

    test "needs a login", %{conn: conn} do
      conn = get(conn, ~p"/users/settings/export")
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "POST /users/settings/delete" do
    test "deletes the account, signs out and clears the remember-me cookie", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/users/settings/delete", %{"account" => %{"confirm" => user.email}})

      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      refute Accounts.get_user_by_email(user.email)
    end

    test "checks the typed address again", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/users/settings/delete", %{"account" => %{"confirm" => "yes"}})

      assert redirected_to(conn) == "/users/settings#delete-account"
      assert Accounts.get_user_by_email(user.email)
    end

    test "checks the recent sign-in again", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> log_in_user(user, token_authenticated_at: @stale)
        |> post(~p"/users/settings/delete", %{"account" => %{"confirm" => user.email}})

      assert redirected_to(conn) == "/users/settings#delete-account"
      assert Accounts.get_user_by_email(user.email)
    end

    test "checks ownership again", %{conn: conn} do
      user = user_fixture()

      {:ok, _} =
        Tournaments.create_tournament(Scope.for_user(user), %{"name" => "M", "rounds_count" => 3})

      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/users/settings/delete", %{"account" => %{"confirm" => user.email}})

      assert redirected_to(conn) == "/users/settings#delete-account"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "still owns tournaments"
      assert Accounts.get_user_by_email(user.email)
    end

    test "does nothing on a local install", %{conn: conn} do
      Application.put_env(:pairings_engine, :local_mode, true)
      user = user_fixture()

      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/users/settings/delete", %{"account" => %{"confirm" => user.email}})

      assert redirected_to(conn) == ~p"/users/settings"
      assert Accounts.get_user_by_email(user.email)
    end
  end
end
