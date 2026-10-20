defmodule PairingsEngineWeb.Plugs.ManubriumDevCors do
  @moduledoc """
  Development only: lets the Manubrium app's web bundle, served by its own
  dev server (Vite, `http://localhost:5173`), call this server's
  `/api/manubrium/v1` from a desktop browser.

  The installed app never needs it - its requests go through the phone's
  native HTTP (CapacitorHttp), which no browser's CORS rule applies to - so
  this exists for the one place a browser stands in for the phone: a
  developer's screen. It answers only for the origins in
  `config :pairings_engine, :manubrium_dev_origins`, which only
  `config/dev.exs` sets. Anywhere else the list is empty and this plug does
  nothing at all.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["api", "manubrium" | _]} = conn, _opts) do
    origins = Application.get_env(:pairings_engine, :manubrium_dev_origins, [])

    case get_req_header(conn, "origin") do
      [origin] when origins != [] ->
        if origin in origins, do: allow(conn, origin), else: conn

      _none ->
        conn
    end
  end

  def call(conn, _opts), do: conn

  defp allow(conn, origin) do
    conn =
      conn
      |> put_resp_header("access-control-allow-origin", origin)
      |> put_resp_header("vary", "origin")

    if conn.method == "OPTIONS" do
      conn
      |> put_resp_header("access-control-allow-methods", "GET, POST, PUT, PATCH, DELETE")
      |> put_resp_header("access-control-allow-headers", "authorization, content-type")
      |> put_resp_header("access-control-max-age", "600")
      |> send_resp(204, "")
      |> halt()
    else
      conn
    end
  end
end
