defmodule PairingsEngineWeb.Plugs.LauncherStats do
  @moduledoc """
  `GET /_launcher/stats`, for the launcher's *Details* panel and
  `openpairings.sh details` and for nothing else. See
  `PairingsEngine.LauncherDetails` and `docs/launcher-details.md`.

  Answered only when all three hold, and a 404 like any missing page
  otherwise - no hint which of the three failed:

    1. this is a desktop copy (`PairingsEngine.Authz.local_mode?/0`). A
       hosted server sits behind a proxy whose requests arrive from
       loopback, so rule 2 alone would mean nothing there;
    2. the peer is this machine, read from the socket and never from a
       forwarded header;
    3. the request carries this start's secret in `x-launcher-token`.

  It sits in the endpoint ahead of the request logger, so a panel left open
  for an afternoon does not write a log line every two seconds into the very
  log the panel is showing.

  It is not on the board network listener (`PairingsEngineWeb.BoardLan`),
  which runs its own plug and router; `PairingsEngineWeb.LauncherStatsTest`
  holds that.
  """
  @behaviour Plug

  import Plug.Conn

  alias PairingsEngine.LauncherDetails
  alias PairingsEngine.LauncherDetails.Stats

  @path ["_launcher", "stats"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: @path} = conn, _opts) do
    if conn.method == "GET" and PairingsEngine.Authz.local_mode?() and loopback?(conn) and
         LauncherDetails.authorized?(given_token(conn)) do
      conn = fetch_query_params(conn)

      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, Phoenix.json_library().encode!(Stats.collect(conn.query_params["lang"])))
      |> halt()
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "Not Found")
      |> halt()
    end
  end

  def call(conn, _opts), do: conn

  defp given_token(conn) do
    case get_req_header(conn, LauncherDetails.header()) do
      [token | _] -> token
      [] -> nil
    end
  end

  defp loopback?(conn) do
    case get_peer_data(conn) do
      %{address: {127, _, _, _}} -> true
      %{address: {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      %{address: {0, 0, 0, 0, 0, 0xFFFF, a, _}} -> div(a, 256) == 127
      _other -> false
    end
  end
end
