defmodule PairingsEngineWeb.PhoneLan.Plug do
  @moduledoc """
  What answers on the phones' network listener (`PairingsEngineWeb.PhoneLan`):
  Manubrium's pages, and a 404 for everything else there is.

  Top to bottom:

    1. local mode, or nothing;
    2. the caller's address is a private one, or 403;
    3. the request is on the list below, by method and path, or 404 -
       decided here, before anything is parsed or any session is read;
    4. `X-Forwarded-For` and its relatives are dropped: nothing stands in
       front of this port, so whatever such a header says, the caller wrote
       it;
    5. the request is marked (`conn.private.phone_lan`), so `Plug.SSL` lets
       plain http through (`PhoneLan.lan_request?/1`), and the session
       cookie loses its `Secure` flag on the way out - a phone keeps no
       `Secure` cookie from an http page, and a desktop build sets one;
    6. the ordinary endpoint, which runs the request through the router's
       `/m` routes like any other.

  The desk pages are not on the list, and if one were asked for anyway the
  browser pipeline's sign-in (`UserAuth.local_owner_session/2`) insists on a
  loopback caller, which a network caller is not.
  """
  @behaviour Plug

  import Plug.Conn

  alias PairingsEngine.Authz
  alias PairingsEngineWeb.BoardLan

  @proxy_headers ~w(x-forwarded-for x-forwarded-host x-forwarded-proto x-forwarded-port
                    x-real-ip forwarded)

  @session_cookie "_pairings_engine_key"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    cond do
      not Authz.local_mode?() ->
        not_found(conn)

      not BoardLan.private_address?(conn.remote_ip) ->
        conn |> send_resp(403, "This address answers the hall's own network only.") |> halt()

      conn.method == "GET" and conn.path_info == [] ->
        conn |> put_resp_header("location", "/m") |> send_resp(302, "") |> halt()

      not phone_route?(conn.method, conn.path_info) ->
        not_found(conn)

      true ->
        serve(conn)
    end
  end

  @doc "Whether `method` and `path_info` are something a phone may ask this listener."
  def phone_route?("GET", ["m"]), do: true
  def phone_route?("POST", ["m"]), do: true
  def phone_route?("GET", ["m", "e", _token]), do: true
  def phone_route?("POST", ["m", "e", _token]), do: true
  def phone_route?("GET", ["m", "leave"]), do: true
  def phone_route?("GET", ["m", "results"]), do: true
  def phone_route?("GET", ["m", "sw.js"]), do: true
  def phone_route?("POST", ["m", "sync"]), do: true

  # The Manubrium app's API: bearer tokens, no session, every verb it uses.
  def phone_route?(method, ["api", "manubrium", "v1" | rest])
      when method in ~w(GET POST PUT PATCH DELETE),
      do: rest != []

  def phone_route?(method, ["live", t]) when method in ["GET", "POST"],
    do: t in ~w(websocket longpoll)

  def phone_route?("GET", ["assets" | rest]), do: rest != []
  def phone_route?("GET", ["fonts" | rest]), do: rest != []
  def phone_route?("GET", ["images", "manubrium", _file]), do: true
  def phone_route?("GET", ["favicon.ico"]), do: true
  def phone_route?(_method, _path_info), do: false

  defp serve(conn) do
    conn =
      @proxy_headers
      |> Enum.reduce(conn, &delete_req_header(&2, &1))
      |> put_private(:phone_lan, true)
      |> register_before_send(&insecure_session_cookie/1)

    PairingsEngineWeb.Endpoint.call(conn, PairingsEngineWeb.Endpoint.init([]))
  end

  # Registered before the endpoint's own `Plug.Session`, so it runs after it
  # (before-send callbacks run newest first) and sees the cookie it set.
  defp insecure_session_cookie(conn) do
    case conn.resp_cookies do
      %{@session_cookie => cookie} ->
        %{
          conn
          | resp_cookies: Map.put(conn.resp_cookies, @session_cookie, Map.delete(cookie, :secure))
        }

      _none ->
        conn
    end
  end

  defp not_found(conn), do: conn |> send_resp(404, "Not found.") |> halt()
end
