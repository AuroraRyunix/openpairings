defmodule PairingsEngineWeb.CSPFramingTest do
  @moduledoc """
  `frame-ancestors` is the one directive this app varies by route, so it is
  the one worth pinning from both sides: the read-only public pages must be
  embeddable, and everything else must not be.

  The second half is the half that matters. A regression that opened
  framing app-wide would not break a single feature - it would just quietly
  make every logged-in arbiter clickjackable, and no other test in the
  suite would notice.
  """
  use PairingsEngineWeb.ConnCase, async: false

  alias PairingsEngine.Tournaments

  defp csp(conn), do: conn |> get_resp_header("content-security-policy") |> List.first()

  defp public_tournament do
    {:ok, t} = Tournaments.create_tournament(%{"name" => "Embed Test", "type" => "swiss"})
    {:ok, t} = Tournaments.set_public_pages(t, true)
    t
  end

  describe "the read-only public pages" do
    test "may be framed", %{conn: conn} do
      t = public_tournament()

      for path <- ["/p/#{t.public_slug}/pairings", "/p/#{t.public_slug}/standings"] do
        policy = conn |> get(path) |> csp()

        assert policy =~ "frame-ancestors *",
               "#{path} should be embeddable, got: #{policy}"

        refute policy =~ "frame-ancestors 'none'"
      end
    end

    test "carry no x-frame-options that would override the CSP", %{conn: conn} do
      t = public_tournament()

      assert get_resp_header(get(conn, "/p/#{t.public_slug}/pairings"), "x-frame-options") == []
    end

    test "keep every other directive exactly as the strict policy has it", %{conn: conn} do
      t = public_tournament()
      policy = conn |> get("/p/#{t.public_slug}/pairings") |> csp()

      assert policy =~ "default-src 'self'"
      assert policy =~ "object-src 'none'"
      assert policy =~ "base-uri 'self'"
      assert policy =~ "form-action 'self'"
      assert policy =~ ~r/script-src 'self' 'nonce-[A-Za-z0-9+\/=]+'/
      refute policy =~ "unsafe-eval"
      refute policy =~ "script-src 'self' 'unsafe-inline'"
    end
  end

  describe "everything else stays closed" do
    test "the public REGISTER form is not embeddable - it writes", %{conn: conn} do
      t = public_tournament()
      {:ok, t} = Tournaments.update_tournament(t, %{"registration_open" => true})

      assert conn |> get("/p/#{t.public_slug}/register") |> csp() =~ "frame-ancestors 'none'"
    end

    test "the log-in page is not embeddable", %{conn: conn} do
      assert conn |> get(~p"/users/log-in") |> csp() =~ "frame-ancestors 'none'"
    end

    test "the arbiter tools are not embeddable - they take uploads", %{conn: conn} do
      assert conn |> get(~p"/tools") |> csp() =~ "frame-ancestors 'none'"
    end

    test "mobile result entry is not embeddable - it holds a session", %{conn: conn} do
      assert conn |> get("/m") |> csp() =~ "frame-ancestors 'none'"
    end

    test "the authenticated app is not embeddable", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})

      assert conn |> get(~p"/") |> csp() =~ "frame-ancestors 'none'"
    end
  end

  describe "configuration" do
    setup do
      original = Application.get_env(:pairings_engine, :public_frame_ancestors)
      on_exit(fn -> Application.put_env(:pairings_engine, :public_frame_ancestors, original) end)
      :ok
    end

    test "an origin list restricts embedding to those sites", %{conn: conn} do
      Application.put_env(:pairings_engine, :public_frame_ancestors, "https://club.example")
      t = public_tournament()

      assert conn |> get("/p/#{t.public_slug}/pairings") |> csp() =~
               "frame-ancestors https://club.example"
    end

    test "'none' switches embedding off without touching the router", %{conn: conn} do
      Application.put_env(:pairings_engine, :public_frame_ancestors, "'none'")
      t = public_tournament()

      assert conn |> get("/p/#{t.public_slug}/pairings") |> csp() =~ "frame-ancestors 'none'"
    end

    test "an empty setting falls back to 'none' rather than an invalid header", %{conn: conn} do
      Application.put_env(:pairings_engine, :public_frame_ancestors, "   ")
      t = public_tournament()

      assert conn |> get("/p/#{t.public_slug}/pairings") |> csp() =~ "frame-ancestors 'none'"
    end
  end
end
