defmodule PairingsEngineWeb.Plugs.ManubriumDevCorsTest do
  @moduledoc """
  The development-only CORS allowance for the Manubrium app's web bundle:
  inert unless `:manubrium_dev_origins` is set (only config/dev.exs sets
  it), and then only for those origins and only under `/api/manubrium`.
  """
  use PairingsEngineWeb.ConnCase, async: false

  @origin "http://localhost:5173"

  defp with_origins(origins) do
    previous = Application.get_env(:pairings_engine, :manubrium_dev_origins)
    Application.put_env(:pairings_engine, :manubrium_dev_origins, origins)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:pairings_engine, :manubrium_dev_origins)
        value -> Application.put_env(:pairings_engine, :manubrium_dev_origins, value)
      end
    end)
  end

  test "outside development nothing is allowed", %{conn: conn} do
    conn = conn |> put_req_header("origin", @origin) |> get("/api/manubrium/v1/me")

    assert conn.status == 401
    assert get_resp_header(conn, "access-control-allow-origin") == []
  end

  test "a listed origin gets its preflight and its header", %{conn: conn} do
    with_origins([@origin])

    preflight =
      conn |> put_req_header("origin", @origin) |> options("/api/manubrium/v1/tournaments")

    assert preflight.status == 204
    assert get_resp_header(preflight, "access-control-allow-origin") == [@origin]
    assert [headers] = get_resp_header(preflight, "access-control-allow-headers")
    assert headers =~ "authorization"

    real = build_conn() |> put_req_header("origin", @origin) |> get("/api/manubrium/v1/me")
    assert get_resp_header(real, "access-control-allow-origin") == [@origin]
  end

  test "another origin, or another path, gets nothing", %{conn: conn} do
    with_origins([@origin])

    other =
      conn |> put_req_header("origin", "http://evil.test") |> get("/api/manubrium/v1/me")

    assert get_resp_header(other, "access-control-allow-origin") == []

    desk = build_conn() |> put_req_header("origin", @origin) |> get("/api/boards/v1/link")
    assert get_resp_header(desk, "access-control-allow-origin") == []
  end
end
