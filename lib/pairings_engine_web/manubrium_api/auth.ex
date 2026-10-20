defmodule PairingsEngineWeb.ManubriumApi.Auth do
  @moduledoc """
  The bearer check in front of every Manubrium API route but the connect
  trade (`PairingsEngine.Manubrium.authenticate/1`). No session, no cookie,
  no CSRF token: the token is the credential, sent on every request.

  The token, then the budget - the board link's order
  (`PairingsEngineWeb.BoardLinkController`): a refused token is counted
  against the client address (`:manubrium_auth`), an accepted one against
  its own device (`:manubrium_api`), so one phone gone wrong is throttled
  without the hall's other phones noticing, and a hall full of phones on one
  address never locks a right token out.

  Sets `conn.assigns.device` and `conn.assigns.current_scope` (the
  device's account), which is everything the controllers use.
  """
  @behaviour Plug

  import Plug.Conn

  alias PairingsEngine.{Manubrium, RateLimit}
  alias PairingsEngineWeb.ManubriumApi.Reply

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    address = PairingsEngineWeb.ClientIp.get(conn)

    with {:ok, token} <- bearer(conn),
         {:ok, device} <- Manubrium.authenticate(token),
         key = Integer.to_string(device.id),
         true <- RateLimit.allow?(:manubrium_api, key) || :rate_limited do
      RateLimit.record(:manubrium_api, key)

      conn
      |> assign(:device, device)
      |> assign(:current_scope, Manubrium.scope(device))
    else
      :rate_limited ->
        conn
        |> put_resp_header("retry-after", "60")
        |> Reply.error(429, "rate_limited", "Too many requests from this phone. Wait a minute.")

      _refused ->
        if RateLimit.allow?(:manubrium_auth, address) do
          RateLimit.record(:manubrium_auth, address)

          Reply.error(
            conn,
            401,
            "unauthorized",
            "This phone is not connected, or its connection was withdrawn. Connect it again from the account page."
          )
        else
          conn
          |> put_resp_header("retry-after", "600")
          |> Reply.error(429, "rate_limited", "Too many refused requests from this address.")
        end
    end
  end

  @doc "The bearer token in `conn`'s Authorization header, if any."
  def bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      ["bearer " <> token] -> {:ok, String.trim(token)}
      _missing -> :error
    end
  end
end
