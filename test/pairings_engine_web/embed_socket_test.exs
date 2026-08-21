defmodule PairingsEngineWeb.EmbedSocketTest do
  @moduledoc """
  The embeddable public pages connect their LiveView over `/embed/live`,
  which is declared WITHOUT the session in `connect_info` - see the socket
  declaration in `PairingsEngineWeb.Endpoint` for why (a `SameSite=Lax`
  session cookie is not sent to a cross-site iframe, so the session-bearing
  socket cannot authenticate there and the client retries forever).

  These are guards on the two halves of that arrangement that are easy to
  break silently:

    * the client picks the socket by path, and the regex that does it lives
      in `assets/js/app.js` where no Elixir test would otherwise reach it;
    * the pages that use the cookie-free socket must not depend on the
      session for anything, or they would work when opened directly and
      fail only when embedded - the worst possible failure shape, since
      every local test would pass.
  """
  use PairingsEngineWeb.ConnCase, async: false

  alias PairingsEngine.Tournaments

  @app_js "assets/js/app.js"

  defp public_tournament do
    {:ok, t} = Tournaments.create_tournament(%{"name" => "Embed Socket", "type" => "swiss"})
    {:ok, t} = Tournaments.set_public_pages(t, true)
    t
  end

  describe "the endpoint" do
    test "declares a cookie-free socket for embedded pages" do
      source = File.read!("lib/pairings_engine_web/endpoint.ex")

      assert source =~ ~s(socket "/embed/live"),
             "the embeddable pages need a socket that does not require the session cookie"
    end

    test "the embed socket does not receive the session in connect_info" do
      source = File.read!("lib/pairings_engine_web/endpoint.ex")

      [_before, embed_socket] = String.split(source, ~s(socket "/embed/live"), parts: 2)
      declaration = String.slice(embed_socket, 0, 200)

      refute declaration =~ "session:",
             """
             /embed/live must NOT be given the session in connect_info - that is the
             entire point of it. If the session is passed here, a cross-site iframe
             connects with session: nil, LiveView rejects the connect, and the page
             reload-loops with "WebSocket is closed before the connection is established".
             """
    end
  end

  describe "the client's socket routing" do
    test "sends only the two read-only public pages to /embed/live" do
      js = File.read!(@app_js)

      assert js =~ "/embed/live", "app.js must know about the embed socket"

      # The regex the client actually uses, mirrored here so a change to it
      # has to be a deliberate change to this list too.
      embeddable = ~r{^/p/[^/]+/(pairings|standings)$}

      for path <- ["/p/abc123/pairings", "/p/abc123/standings"] do
        assert Regex.match?(embeddable, path), "#{path} should use the cookie-free socket"
      end

      for path <- [
            "/p/abc123/register",
            "/t/1/players",
            "/",
            "/users/log-in",
            "/users/settings",
            "/tools",
            "/m/results"
          ] do
        refute Regex.match?(embeddable, path),
               "#{path} must keep the session-bearing socket - it is not embeddable"
      end
    end
  end

  describe "the embeddable pages themselves" do
    test "render fully with no session at all", %{conn: conn} do
      t = public_tournament()

      # A cross-site iframe sends no cookies, so the request arrives with an
      # empty session. These pages must not care.
      for path <- ["/p/#{t.public_slug}/pairings", "/p/#{t.public_slug}/standings"] do
        html =
          conn
          |> Plug.Test.init_test_session(%{})
          |> get(path)
          |> html_response(200)

        assert html =~ t.name,
               "#{path} must render its content without a session - it is embedded cross-site"
      end
    end
  end
end
