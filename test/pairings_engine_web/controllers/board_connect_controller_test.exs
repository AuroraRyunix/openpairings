defmodule PairingsEngineWeb.BoardConnectControllerTest do
  @moduledoc """
  The account flow of the board link as a box and a browser meet it:
  the consent page, Allow and Cancel, and the grant traded for a code
  (docs/board-link-api.md, "Connecting an account").
  """
  use PairingsEngineWeb.ConnCase, async: false

  import PairingsEngine.AccountsFixtures
  import PairingsEngine.BoardLinkFixtures

  alias PairingsEngine.{BoardLink, RateLimit}

  @return_to "https://hall.example.org/setup/openpairings/callback"

  # Refused grants count against the test client's address, which every
  # other board test shares.
  setup do
    RateLimit.clear(:board_link_auth, "127.0.0.1")
    on_exit(fn -> RateLimit.clear(:board_link_auth, "127.0.0.1") end)
  end

  defp connect_path(params) do
    ~p"/boards/connect?#{Map.merge(%{"return_to" => @return_to, "state" => "s-123", "box" => "Alnasl - Hall A"}, params)}"
  end

  defp query_of(location), do: location |> URI.parse() |> Map.get(:query) |> URI.decode_query()

  describe "the consent page" do
    test "asks a signed-out visitor to sign in, and remembers where they were", %{conn: conn} do
      conn = get(conn, connect_path(%{}))

      assert redirected_to(conn) == ~p"/users/log-in"
      assert get_session(conn, :user_return_to) =~ "/boards/connect?"
      assert get_session(conn, :user_return_to) =~ "state=s-123"
    end

    test "says which box asks and, above all, where the browser goes", %{conn: conn} do
      user = user_fixture()
      conn = conn |> log_in_user(user) |> get(connect_path(%{}))
      html = html_response(conn, 200)

      assert html =~ "hall.example.org"
      assert html =~ "Alnasl - Hall A"
      assert html =~ ~s(id="board-connect-allow")
      assert html =~ ~s(id="board-connect-cancel")

      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "form-action 'self' https://hall.example.org"
    end

    test "a desktop copy's box on this computer, in plain http, port and all", %{conn: conn} do
      conn =
        conn
        |> log_in_user(user_fixture())
        |> get(
          connect_path(%{"return_to" => "http://127.0.0.1:4041/setup/openpairings/callback"})
        )

      html = html_response(conn, 200)
      assert html =~ "127.0.0.1:4041"
      assert html =~ ~s(id="board-connect-plain")
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "form-action 'self' http://127.0.0.1:4041"
    end

    test "refuses a return address that is not an http(s) web address", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())

      for bad <- [
            "javascript:alert(1)",
            "ftp://hall.example.org/x",
            "data:text/html,hi",
            "//hall.example.org/x",
            "https://user:pw@hall.example.org/x",
            "https://hall.example.org/x#frag",
            "https://hall example.org/x",
            "https://hall.example.org;x/",
            String.duplicate("https://a.org/", 200)
          ] do
        response = conn |> get(connect_path(%{"return_to" => bad})) |> html_response(400)
        assert response =~ ~s(id="board-connect-invalid"), bad
      end

      assert conn |> get(~p"/boards/connect") |> html_response(400)
    end

    test "shows a full account as full", %{conn: conn} do
      user = user_fixture()
      scope = PairingsEngine.Accounts.Scope.for_user(user)
      for n <- 1..8, do: {:ok, _, _} = BoardLink.connect(scope, label: "box #{n}")

      html = conn |> log_in_user(user) |> get(connect_path(%{})) |> html_response(200)
      assert html =~ ~s(id="board-connect-full")
    end
  end

  describe "Allow and Cancel" do
    test "Allow makes an account code and sends the grant back with the state", %{conn: conn} do
      user = user_fixture()
      scope = PairingsEngine.Accounts.Scope.for_user(user)
      fixture = paired_tournament(scope)

      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/boards/connect", %{
          "return_to" => @return_to <> "?keep=1",
          "state" => "s-123",
          "box" => "Alnasl - Hall A",
          "decision" => "allow"
        })

      location = redirected_to(conn, 302)
      assert String.starts_with?(location, @return_to <> "?")
      query = query_of(location)
      assert query["state"] == "s-123"
      assert query["keep"] == "1"
      assert is_binary(query["grant"])

      assert [link] = BoardLink.list_account_links(scope)
      assert link.label == "Alnasl - Hall A"

      # The box trades the grant for the code, without a session.
      answer =
        build_conn()
        |> post(~p"/api/boards/v1/grant", %{"grant" => query["grant"]})
        |> json_response(200)

      assert %{"code" => code, "kind" => "account"} = answer
      [root, secret] = String.split(code, "#")
      assert String.ends_with?(root, "/api/boards/v1")
      assert String.starts_with?(secret, "oplu_")

      # ...and the code works like any other.
      listing =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> secret)
        |> get(~p"/api/boards/v1/link")
        |> json_response(200)

      assert listing["kind"] == "account"
      assert [%{"id" => id}] = listing["tournaments"]
      assert id == fixture.tournament.id

      # Once.
      assert %{"error" => "invalid_grant"} =
               build_conn()
               |> post(~p"/api/boards/v1/grant", %{"grant" => query["grant"]})
               |> json_response(401)
    end

    test "Cancel makes nothing and says so", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/boards/connect", %{
          "return_to" => @return_to,
          "state" => "s-9",
          "decision" => "deny"
        })

      assert %{"error" => "denied", "state" => "s-9"} = query_of(redirected_to(conn, 302))
      refute Map.has_key?(query_of(redirected_to(conn, 302)), "grant")
      assert BoardLink.list_account_links(PairingsEngine.Accounts.Scope.for_user(user)) == []
    end

    test "a full account is sent back with the reason", %{conn: conn} do
      user = user_fixture()
      scope = PairingsEngine.Accounts.Scope.for_user(user)
      for n <- 1..8, do: {:ok, _, _} = BoardLink.connect(scope, label: "box #{n}")

      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/boards/connect", %{
          "return_to" => @return_to,
          "state" => "s",
          "decision" => "allow"
        })

      assert %{"error" => "too_many_codes"} = query_of(redirected_to(conn, 302))
    end

    test "a bad return address is not redirected to, even on Allow", %{conn: conn} do
      conn =
        conn
        |> log_in_user(user_fixture())
        |> post(~p"/boards/connect", %{
          "return_to" => "javascript:alert(1)",
          "decision" => "allow"
        })

      assert html_response(conn, 400) =~ ~s(id="board-connect-invalid")
    end

    test "Allow needs a signed-in account", %{conn: conn} do
      conn =
        post(conn, ~p"/boards/connect", %{"return_to" => @return_to, "decision" => "allow"})

      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "the grant endpoint" do
    test "an expired or unknown grant is the same 401", %{conn: conn} do
      assert %{"error" => "invalid_grant"} =
               conn
               |> post(~p"/api/boards/v1/grant", %{"grant" => String.duplicate("b", 43)})
               |> json_response(401)

      assert %{"error" => "invalid_grant"} =
               build_conn() |> post(~p"/api/boards/v1/grant", %{}) |> json_response(401)
    end

    test "refused grants are rationed per address, like refused codes", %{conn: conn} do
      address = "127.0.0.1"
      for _ <- 1..30, do: RateLimit.record(:board_link_auth, address)

      conn = post(conn, ~p"/api/boards/v1/grant", %{"grant" => String.duplicate("c", 43)})
      assert %{"error" => "rate_limited"} = json_response(conn, 429)
      assert get_resp_header(conn, "retry-after") == ["600"]
    end
  end
end
