defmodule PairingsEngineWeb.MovedNoticeTest do
  use PairingsEngineWeb.ConnCase, async: false

  setup %{conn: conn} do
    previous = Application.get_env(:pairings_engine, :host_policy)
    on_exit(fn -> Application.put_env(:pairings_engine, :host_policy, previous) end)
    %{conn: conn}
  end

  defp policy(moved_to) do
    base = Application.get_env(:pairings_engine, :host_policy) || []
    Application.put_env(:pairings_engine, :host_policy, Keyword.put(base, :moved_to, moved_to))
  end

  defp page(conn, host),
    do: conn |> Map.put(:host, host) |> get(~p"/users/log-in") |> html_response(200)

  test "no banner unless a move is configured", %{conn: conn} do
    policy(nil)
    refute page(conn, "pairings.zerotwo.cloud") =~ ~s(id="moved-notice")
  end

  test "the old address gets the banner, the new one is spared", %{conn: conn} do
    policy("pairings.cloud")

    html = page(conn, "pairings.zerotwo.cloud")
    assert html =~ ~s(id="moved-notice")
    assert html =~ ~s(href="https://pairings.cloud")

    refute page(build_conn(), "pairings.cloud") =~ ~s(id="moved-notice")
  end
end
