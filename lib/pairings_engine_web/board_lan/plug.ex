defmodule PairingsEngineWeb.BoardLan.Plug do
  @moduledoc """
  What answers on the network listener (`PairingsEngineWeb.BoardLan`): the
  board link, and a 404 for everything else there is.

  This is the whole stack of that port, top to bottom:

    1. local mode, or nothing (a hosted server never starts this, and would
       get a 404 from it if it somehow did);
    2. the caller's address is a private one, or 403;
    3. the request is one of the board link's four, by method and path,
       or 404 - decided here, on a list written out below, before anything
       is parsed;
    4. `X-Forwarded-For` and its relatives are dropped. Nothing stands in
       front of this port, so whatever such a header says, the caller wrote
       it. The rate limits then count the address the connection really
       came from;
    5. the JSON body is read;
    6. `PairingsEngineWeb.BoardLan.Router`, which has those four routes and
       no others, hands it to `PairingsEngineWeb.BoardLinkController`, whose
       own first plug asks for the bearer secret.

  There is no `Plug.Session`, no `:browser` pipeline and so no
  `PairingsEngineWeb.UserAuth.local_owner_session/2` anywhere in that list.
  That plug is what signs the owner in on a desktop copy; it lives in the
  browser pipeline of the other router, and it also insists on a loopback
  caller, which a connection to a network address is not. The sign-in a
  desktop copy skips cannot be skipped here, because it is not here.

  Errors are a code and a sentence. Not a version, not a path, not a stack
  trace: somebody in the hall asked a port a question, and is owed "no".
  """
  @behaviour Plug

  import Plug.Conn

  alias PairingsEngine.Authz
  alias PairingsEngineWeb.BoardLan

  @prefix ["api", "boards", "v1"]

  @parsers Plug.Parsers.init(
             parsers: [:json],
             pass: ["application/json"],
             json_decoder: Phoenix.json_library()
           )

  @router BoardLan.Router.init([])

  # What a proxy would have written, had there been one.
  @proxy_headers ~w(x-forwarded-for x-forwarded-host x-forwarded-proto x-forwarded-port
                    x-real-ip forwarded)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    cond do
      not Authz.local_mode?() ->
        not_found(conn)

      not BoardLan.private_address?(conn.remote_ip) ->
        refuse(conn, 403, "forbidden", "this address answers the hall's own network only")

      not board_route?(conn.method, conn.path_info) ->
        not_found(conn)

      true ->
        serve(conn)
    end
  end

  @doc "Whether `method` and `path_info` are one of the board link's requests."
  def board_route?("GET", @prefix ++ ["link"]), do: true
  def board_route?("POST", @prefix ++ ["box"]), do: true
  def board_route?("GET", @prefix ++ ["tournaments", _id]), do: true
  def board_route?("POST", @prefix ++ ["tournaments", _id, "games"]), do: true
  def board_route?(_method, _path_info), do: false

  defp serve(conn) do
    conn =
      @proxy_headers
      |> Enum.reduce(conn, &delete_req_header(&2, &1))
      |> put_private(:board_lan, true)

    try do
      conn
      |> Plug.Parsers.call(@parsers)
      |> BoardLan.Router.call(@router)
    rescue
      error ->
        case Plug.Exception.status(error) do
          status when status in 400..499 ->
            refuse(conn, status, "invalid_request", "the request could not be read")

          _other ->
            refuse(conn, 500, "server_error", "something went wrong on this side")
        end
    end
  end

  defp not_found(conn), do: refuse(conn, 404, "not_found", "nothing here")

  defp refuse(conn, status, code, detail) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{"error" => code, "detail" => detail}))
    |> halt()
  end
end
