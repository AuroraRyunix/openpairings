defmodule PairingsEngine.KeycloakTest do
  use ExUnit.Case, async: false

  alias PairingsEngine.Keycloak

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

  describe "configured?/0" do
    test "true when both client id and secret are set" do
      assert Keycloak.configured?()
    end

    test "false when the secret is missing" do
      Application.put_env(:pairings_engine, :keycloak, Keyword.put(@config, :client_secret, nil))
      refute Keycloak.configured?()
    end

    test "false when unset entirely" do
      Application.put_env(:pairings_engine, :keycloak, [])
      refute Keycloak.configured?()
    end
  end

  describe "authorize_url/1" do
    test "points at the realm's authorize endpoint with the expected params" do
      url = Keycloak.authorize_url("csrf-state-123")
      uri = URI.parse(url)
      query = URI.decode_query(uri.query)

      assert "#{uri.scheme}://#{uri.host}#{uri.path}" ==
               "https://auth.zerotwo.cloud/realms/zerotwo/protocol/openid-connect/auth"

      assert query["client_id"] == "openpairings"
      assert query["redirect_uri"] == "https://pairings.zerotwo.cloud/auth/keycloak/callback"
      assert query["response_type"] == "code"
      assert query["state"] == "csrf-state-123"
      assert query["scope"] == "openid email profile"
    end
  end

  describe "exchange_code/1" do
    test "posts the code to the token endpoint and returns the tokens" do
      Req.Test.stub(PairingsEngine.KeycloakTest, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/realms/zerotwo/protocol/openid-connect/token"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        form = URI.decode_query(body)

        assert form["grant_type"] == "authorization_code"
        assert form["code"] == "the-code"
        assert form["client_id"] == "openpairings"
        assert form["client_secret"] == "test-secret"

        Req.Test.json(conn, %{"access_token" => "at-123", "id_token" => "it-123"})
      end)

      assert {:ok, %{"access_token" => "at-123", "id_token" => "it-123"}} =
               Keycloak.exchange_code("the-code")
    end

    test "surfaces a rejected exchange as an error tuple, not a crash" do
      Req.Test.stub(PairingsEngine.KeycloakTest, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => "invalid_grant"})
      end)

      assert {:error, {:unexpected_status, 400, %{"error" => "invalid_grant"}}} =
               Keycloak.exchange_code("stale-or-reused-code")
    end
  end

  describe "fetch_userinfo/1" do
    test "sends the access token as a bearer and returns the claims" do
      Req.Test.stub(PairingsEngine.KeycloakTest, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/realms/zerotwo/protocol/openid-connect/userinfo"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer at-123"]

        Req.Test.json(conn, %{"sub" => "abc-123", "email" => "jorian@zerotwo.cloud"})
      end)

      assert {:ok, %{"sub" => "abc-123", "email" => "jorian@zerotwo.cloud"}} =
               Keycloak.fetch_userinfo("at-123")
    end
  end
end
