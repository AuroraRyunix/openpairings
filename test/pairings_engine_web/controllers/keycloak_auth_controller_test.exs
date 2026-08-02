defmodule PairingsEngineWeb.KeycloakAuthControllerTest do
  use PairingsEngineWeb.ConnCase

  import PairingsEngine.AccountsFixtures
  alias PairingsEngine.Accounts

  @config [
    issuer: "https://auth.zerotwo.cloud/realms/zerotwo",
    client_id: "openpairings",
    client_secret: "test-secret",
    redirect_uri: "https://pairings.zerotwo.cloud/auth/keycloak/callback"
  ]

  setup do
    previous = Application.get_env(:pairings_engine, :keycloak)
    Application.put_env(:pairings_engine, :keycloak, @config)
    on_exit(fn -> Application.put_env(:pairings_engine, :keycloak, previous) end)
    :ok
  end

  describe "GET /auth/keycloak" do
    test "redirects to the Keycloak authorize endpoint with a state in the session", %{
      conn: conn
    } do
      conn = get(conn, ~p"/auth/keycloak")

      assert redirected_to(conn, 302) =~
               "https://auth.zerotwo.cloud/realms/zerotwo/protocol/openid-connect/auth"

      assert get_session(conn, :keycloak_state)
    end

    test "flashes and redirects to login when SSO isn't configured", %{conn: conn} do
      Application.put_env(:pairings_engine, :keycloak, [])

      conn = get(conn, ~p"/auth/keycloak")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "isn't configured"
    end
  end

  describe "GET /auth/keycloak/callback" do
    test "logs in an existing account coupled by email, and stamps keycloak_sub", %{conn: conn} do
      user = user_fixture()
      stub_token_and_userinfo(sub: "sub-existing", email: user.email)

      conn =
        conn
        |> init_test_session(%{keycloak_state: "known-state"})
        |> get(~p"/auth/keycloak/callback", %{"code" => "the-code", "state" => "known-state"})

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)

      reloaded = Accounts.get_user!(user.id)
      assert reloaded.keycloak_sub == "sub-existing"
    end

    test "creates and logs in a brand-new account for a first-time identity", %{conn: conn} do
      stub_token_and_userinfo(sub: "sub-new", email: "new.person@zerotwo.cloud")

      conn =
        conn
        |> init_test_session(%{keycloak_state: "known-state"})
        |> get(~p"/auth/keycloak/callback", %{"code" => "the-code", "state" => "known-state"})

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)
      assert Accounts.get_user_by_keycloak_sub("sub-new")
    end

    test "rejects a mismatched state instead of completing login", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{keycloak_state: "the-real-state"})
        |> get(~p"/auth/keycloak/callback", %{"code" => "irrelevant", "state" => "attacker-state"})

      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)
    end

    test "synthesizes an @sso-domain email and logs in when the directory account has none",
         %{conn: conn} do
      # A real AD account with no `mail` attribute: Keycloak sends `sub` and
      # even `email_verified`, but no `email` at all — this is exactly what
      # `administrator` returned in production (2026-07-25).
      Req.Test.stub(PairingsEngine.KeycloakTest, fn conn ->
        case conn.request_path do
          "/realms/zerotwo/protocol/openid-connect/token" ->
            Req.Test.json(conn, %{"access_token" => "at-no-email"})

          "/realms/zerotwo/protocol/openid-connect/userinfo" ->
            Req.Test.json(conn, %{
              "sub" => "sub-no-email",
              "preferred_username" => "administrator",
              "email_verified" => true
            })
        end
      end)

      conn =
        conn
        |> init_test_session(%{keycloak_state: "known-state"})
        |> get(~p"/auth/keycloak/callback", %{"code" => "the-code", "state" => "known-state"})

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)

      user = Accounts.get_user_by_keycloak_sub("sub-no-email")
      assert user.email == "administrator@zerotwo.cloud"
    end

    test "treats a blank email the same as a missing one (still synthesizes, doesn't crash)", %{
      conn: conn
    } do
      Req.Test.stub(PairingsEngine.KeycloakTest, fn conn ->
        case conn.request_path do
          "/realms/zerotwo/protocol/openid-connect/token" ->
            Req.Test.json(conn, %{"access_token" => "at-blank-email"})

          "/realms/zerotwo/protocol/openid-connect/userinfo" ->
            Req.Test.json(conn, %{
              "sub" => "sub-blank-email",
              "email" => "",
              "preferred_username" => "aurasan$"
            })
        end
      end)

      conn =
        conn
        |> init_test_session(%{keycloak_state: "known-state"})
        |> get(~p"/auth/keycloak/callback", %{"code" => "the-code", "state" => "known-state"})

      assert redirected_to(conn) == ~p"/"
      user = Accounts.get_user_by_keycloak_sub("sub-blank-email")
      assert user.email == "aurasan$@zerotwo.cloud"
    end

    test "flashes and redirects when neither email nor a username can be found", %{conn: conn} do
      Req.Test.stub(PairingsEngine.KeycloakTest, fn conn ->
        case conn.request_path do
          "/realms/zerotwo/protocol/openid-connect/token" ->
            Req.Test.json(conn, %{"access_token" => "at-nothing"})

          "/realms/zerotwo/protocol/openid-connect/userinfo" ->
            Req.Test.json(conn, %{"sub" => "sub-nothing"})
        end
      end)

      conn =
        conn
        |> init_test_session(%{keycloak_state: "known-state"})
        |> get(~p"/auth/keycloak/callback", %{"code" => "the-code", "state" => "known-state"})

      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Single sign-on failed"
    end

    test "surfaces Keycloak-side cancellation without hitting the token endpoint", %{conn: conn} do
      conn =
        get(conn, ~p"/auth/keycloak/callback", %{
          "error" => "access_denied",
          "error_description" => "User cancelled"
        })

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "cancelled"
    end
  end

  defp stub_token_and_userinfo(sub: sub, email: email) do
    Req.Test.stub(PairingsEngine.KeycloakTest, fn conn ->
      case conn.request_path do
        "/realms/zerotwo/protocol/openid-connect/token" ->
          Req.Test.json(conn, %{"access_token" => "at-#{sub}"})

        "/realms/zerotwo/protocol/openid-connect/userinfo" ->
          Req.Test.json(conn, %{"sub" => sub, "email" => email})
      end
    end)
  end
end
